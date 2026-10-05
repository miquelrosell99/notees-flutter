import 'dart:async';
import 'dart:convert';

import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart';
import 'package:sqflite_sqlcipher/sqflite.dart';

import '../../core/constants/system.dart';
import '../../core/utils/ast_builder.dart';
import '../../core/utils/uuid7.dart';
import '../../data/local/app_database.dart';
import '../../data/models/node.dart';
import '../../data/repositories/node_cache_repository.dart';
import '../../data/repositories/relay_client.dart';
import '../../data/repositories/relay_outbox_repository.dart';
import '../../data/repositories/relay_ws_client.dart';
import '../../data/repositories/sync_watermark_repository.dart';
import '../models/relay/hlc.dart';
import '../models/relay/operation_envelope.dart';
import '../models/relay/operation_payloads.dart';
import '../models/relay/property_value_shapes.dart';
import '../models/relay/store_errors.dart';
import '../models/sync_v2.dart';
import './hlc_clock.dart';
import './relay_appliers.dart';

/// Exception thrown when the sync protocol encounters an unrecoverable error.
class SyncV2Exception implements Exception {
  const SyncV2Exception(this.message);

  final String message;

  @override
  String toString() => 'SyncV2Exception: $message';
}

/// Client-side relay sync orchestrator.
///
/// Keeps the same public surface as the old vector-clock sync service but
/// internally generates operation-relay envelopes and talks to
/// `/api/relay/v2/*` (WIRE.md).
class SyncV2Service {
  SyncV2Service({
    required AppDatabase database,
    required this.dio,
    required this._clientId,
    this.serverless = false,
  }) : _database = database,
       _outbox = RelayOutboxRepository(database),
       _watermarks = SyncWatermarkRepository(database),
       _cache = NodeCacheRepository(database),
       _clock = HlcClock(),
       _relay = RelayClient(dio: dio);

  final AppDatabase _database;
  final RelayOutboxRepository _outbox;
  final SyncWatermarkRepository _watermarks;
  final NodeCacheRepository _cache;
  final HlcClock _clock;
  final RelayClient _relay;
  final Dio dio;
  final String _clientId;

  /// Optional catch-up progress listener, invoked once per catch-up page
  /// with the envelopes applied so far and the total expected
  /// (applied + the server's totalRemaining).
  void Function(SyncPullProgress progress)? onPullProgress;

  /// Test hook: overrides the WS connector used by [startRealtime] so tests
  /// can script fake connections without a live socket.
  WsConnector? wsConnectorOverride;

  RelayWsClient? _ws;
  bool _pullInFlight = false;
  final _wsBuffer = <_WsOpsFrame>[];

  /// Bumped on every start/stop so a start whose workspace lookup finishes
  /// after a stop can no-op (start→stop→start is safe mid-flight).
  int _realtimeGeneration = 0;

  /// Frame-triggered work (hello pulls, buffer drains, acks) kicked off
  /// unawaited from the WS callbacks. [stopRealtime] waits for these so a
  /// stop (or logout/teardown) never leaves callbacks running against
  /// torn-down state.
  final _pendingWsWork = <Future<void>>[];

  /// Last realtime error (fail-loud framing, relay error frames, transport
  /// failures). Exposed for the sync-status surface; the client
  /// auto-reconnects transport failures, so this is informational.
  String? lastRealtimeError;

  /// Optional listener fired with [lastRealtimeError] on every WS error.
  void Function(String error)? onRealtimeError;

  /// Offline (local-only) mode: the service never talks to the network.
  /// [pull] is a no-op and [flush] applies pending outbox envelopes to the
  /// local cache instead of pushing them; the rows stay in the outbox so a
  /// later server attach flushes them through the normal path.
  final bool serverless;

  /// The authenticated user's uuid, used as the relay envelope actor id.
  /// Null until the auth layer wires in the signed-in user.
  String? _actorId;

  String get clientId => _clientId;

  /// The actor id stamped on produced envelopes: the authenticated user's
  /// uuid once known, otherwise the per-install device [clientId]. The web
  /// client uses the user's uuid from `/auth/me`; matching it keeps
  /// actor-keyed state (e.g. favorites) consistent across devices.
  String get actorId => _actorId ?? _clientId;

  /// Whether [actorId] is a real authenticated user id rather than the
  /// device client id fallback.
  bool get hasUserActor => _actorId != null;

  /// Wires the authenticated user's uuid in as the relay actor id. Called by
  /// the auth layer after login/session restore; pass `null` on logout.
  /// [clientId] remains the HLC device identity regardless.
  set actorId(String? value) => _actorId = value;

  /// Local derived cache populated by pull sync.
  NodeCacheRepository get cache => _cache;

  static const _workspaceIdKey = 'current_workspace_id';
  static const _pushChunkSize = 100;

  Future<void> setWorkspaceId(String workspaceId) async {
    final db = await _database.database;
    await db.insert('sync_state', {
      'key': _workspaceIdKey,
      'value': workspaceId,
    }, conflictAlgorithm: ConflictAlgorithm.replace);
  }

  Future<String?> getWorkspaceId() async {
    final db = await _database.database;
    final rows = await db.query(
      'sync_state',
      columns: ['value'],
      where: 'key = ?',
      whereArgs: [_workspaceIdKey],
      limit: 1,
    );
    if (rows.isEmpty) return null;
    return rows.first['value'] as String?;
  }

  /// Reads a single node from the local cache, if available.
  Future<Node?> getCachedNode(String uuid) => _cache.getByUuid(uuid);

  /// Enqueues a new operation as a relay envelope in the local outbox.
  Future<OperationIntent> enqueue({
    required String type,
    required String nodeUuid,
    String? parentUuid,
    String? afterUuid,
    int? newIndex,
    List<Map<String, dynamic>>? contentAst,
    String? name,
    String? classUuid,
    String? tagUuid,
    List<String>? classUuids,
    List<String>? tagUuids,
    bool? isDeleted,
    Map<String, dynamic>? properties,
    String? propertyUuid,
    dynamic propertyValue,
    String? completionId,
    String? completionStatus,
    String? completedAt,
    String? scheduledDate,
    String? deadlineDate,
    bool isPage = false,
    bool isTask = false,
    bool isDaily = false,
    bool isMonthly = false,
    bool isYearly = false,
    List<String>? favoriteNodeUuids,
  }) async {
    final workspaceId = await getWorkspaceId();
    if (workspaceId == null) {
      throw const SyncV2Exception('No workspace configured');
    }

    // Guard: an op that would miss a field the v2 registry requires (null
    // content, or a missing property/tag/class target) is rejected by the
    // relay with 422 and would sit in the quarantine forever. Skip it
    // instead and surface via the log.
    final producesNullContent =
        (type == 'update_content' && contentAst == null) ||
        (type == 'update_node' && name == null) ||
        (type == 'set_property' && propertyUuid == null) ||
        ((type == 'add_tag' || type == 'remove_tag') && tagUuid == null) ||
        ((type == 'add_class' || type == 'remove_class') && classUuid == null);
    if (producesNullContent) {
      debugPrint(
        'SyncV2Service: skipping $type for $nodeUuid with null content '
        '(would be rejected by the server)',
      );
      return OperationIntent(
        type: type,
        clientId: _clientId,
        seq: 0,
        nodeUuid: nodeUuid,
      );
    }

    final op = OperationIntent(
      type: type,
      clientId: _clientId,
      seq: 0,
      nodeUuid: nodeUuid,
      parentUuid: parentUuid,
      afterUuid: afterUuid,
      newIndex: newIndex,
      contentAst: contentAst,
      name: name,
      classUuid: classUuid,
      tagUuid: tagUuid,
      classUuids: classUuids,
      tagUuids: tagUuids,
      isDeleted: isDeleted,
      properties: properties,
      propertyUuid: propertyUuid,
      propertyValue: propertyValue,
      completionId: completionId,
      completionStatus: completionStatus,
      completedAt: completedAt,
      scheduledDate: scheduledDate,
      deadlineDate: deadlineDate,
      isPage: isPage,
      isTask: isTask,
      isDaily: isDaily,
      isMonthly: isMonthly,
      isYearly: isYearly,
      favoriteNodeUuids: favoriteNodeUuids,
    );
    // §34.65 (owner rule, web `unassignClass` parity): authored values that
    // merely MIRROR the departing class's binding defaults carry no user
    // data — the user never put anything in that property. Sweep them with
    // explicit property.unset envelopes (enqueued BEFORE the membership
    // remove so they apply first — every client converges); values that
    // differ from the default survive, marked unbound. Edge recorded in the
    // web port: a value explicitly set TO the default is indistinguishable
    // without a provenance flag.
    if (type == 'remove_class') {
      await _sweepDefaultMirrors(nodeUuid: nodeUuid, classId: classUuid!);
    }
    final envelope = await _intentToEnvelope(op, workspaceId);
    await _outbox.enqueue(envelope);
    return op;
  }

  /// The §34.65 default-mirror sweep: for every binding of [classId] with a
  /// stored default, unset the node's authored rows whose value JSON-text
  /// equals the default's JSON-text (the web's decodeDefault string quirk —
  /// see [NodeCacheRepository.classPropertyDefaultsOf]). PG5 rows unset by
  /// element id (writer-minted uuid), positional rows by idx.
  Future<void> _sweepDefaultMirrors({
    required String nodeUuid,
    required String classId,
  }) async {
    // Web `unassignClass` parity: nothing to sweep (or unassign) when the
    // node does not carry the class.
    final carried = await _cache.nodeClassIdsOf(nodeUuid);
    if (carried == null || !carried.contains(classId)) return;
    final bindings = await _cache.classPropertyDefaultsOf(classId);
    if (bindings.isEmpty) return;
    final authored = (await _cache.getEffectiveProperties(nodeUuid))
        .where((row) => row.source == 'authored');
    for (final binding in bindings) {
      final defaultJson = jsonEncode(binding.defaultValue);
      for (final row in authored) {
        if (row.propertySchemaId != binding.propertySchemaId) continue;
        if (jsonEncode(row.value) != defaultJson) continue;
        final payload = <String, dynamic>{
          'objectId': nodeUuid,
          'propertySchemaId': binding.propertySchemaId,
        };
        if (isUuidLike(row.elementId)) {
          payload['elementId'] = row.elementId;
        } else {
          payload['idx'] = row.idx;
        }
        OperationPayloads.validatePayload('property.unset', payload);
        final envelope = await _buildEnvelope(
          opType: 'property.unset',
          payload: payload,
          affectedNodeIds: [nodeUuid],
        );
        await _outbox.enqueue(envelope);
      }
    }
  }

  /// Sends pending relay envelopes to the server and updates local state.
  ///
  /// A 200 acks the whole chunk (WIRE.md: duplicate ids are silently
  /// ignored, so savedIds may omit resent ids). v2 wire error codes decide
  /// retry vs quarantine: `validation_failed`/`not_found` are permanent
  /// (quarantine), `unauthenticated`/`forbidden`/`rate_limited`/`conflict`
  /// retry with backoff, and `idempotency_replay` means the server already
  /// holds the chunk — it is treated as acked. Typed applier failures
  /// ([StoreError]: cycles, guards, validation) quarantine with the typed
  /// reason instead of retrying forever.
  ///
  /// Returns a list of errors for operations that need retry or quarantine.
  Future<List<String>> flush() async {
    final pending = await _outbox.pending();
    if (pending.isEmpty) return [];

    if (serverless) {
      await _flushServerless(pending);
      return const [];
    }

    final errors = <String>[];
    for (var i = 0; i < pending.length; i += _pushChunkSize) {
      final end = i + _pushChunkSize < pending.length
          ? i + _pushChunkSize
          : pending.length;
      final chunk = pending.sublist(i, end);
      final ids = chunk.map((p) => p.id).toList();
      final envelopes = chunk.map((p) => p.envelope).toList();

      await _outbox.markInFlight(ids);
      try {
        await _relay.pushBatch(envelopes);
        await _applyLocalAndRecord(envelopes);
        await _outbox.removeAll(ids);
      } on DioException catch (e) {
        final wireError = RelayWireError.tryParse(e);
        final status = e.response?.statusCode;
        // The quarantine/retry reason carries the stable machine code.
        final error = wireError != null
            ? '${wireError.code}: ${wireError.message}'
            : e.message ?? 'Relay push failed';
        switch (wireError?.code) {
          case 'idempotency_replay':
            // The server already persisted these envelopes (the original ack
            // was lost); adopt them like a normal ack.
            await _applyLocalAndRecord(envelopes);
            await _outbox.removeAll(ids);
          case 'validation_failed':
          case 'not_found':
            await _quarantine(ids, error);
            errors.add(error);
          case 'unauthenticated':
          case 'forbidden':
          case 'rate_limited':
          case 'conflict':
            for (final p in chunk) {
              await _outbox.markRetry(id: p.id, error: error);
            }
            errors.add(error);
          default:
            if (status == 401 || status == 403) {
              // Auth errors are retryable; the token may be refreshed before
              // the next flush attempt. Do not quarantine them.
              for (final p in chunk) {
                await _outbox.markRetry(id: p.id, error: error);
              }
              errors.add(error);
            } else if (status != null && status >= 400 && status < 500) {
              await _quarantine(ids, error);
              errors.add(error);
            } else {
              for (final p in chunk) {
                await _outbox.markRetry(id: p.id, error: error);
              }
              errors.add(error);
            }
        }
      } on StoreError catch (e) {
        // A typed applier failure is permanent for this op: quarantine with
        // the typed reason (e.g. CycleError) rather than retrying forever.
        final error = e.toString();
        await _quarantine(ids, error);
        errors.add(error);
      } catch (e) {
        final error = e.toString();
        for (final p in chunk) {
          await _outbox.markRetry(id: p.id, error: error);
        }
        errors.add(error);
      }
    }

    if (await _cache.shouldReindexSearch()) {
      await _cache.reindexAll();
    }
    return errors;
  }

  /// Applies locally produced envelopes to the cache right away so local
  /// edits (page titles, new pages) are visible without waiting for the next
  /// pull echo, and records them as locally applied. Re-application of the
  /// echo is safe: appliers are row-LWW / first-create-wins idempotent.
  Future<void> _applyLocalAndRecord(List<OperationEnvelope> envelopes) async {
    final appliers = RelayAppliers(_cache);
    for (final envelope in envelopes) {
      await appliers.apply(envelope);
    }
    await _recordOperations(envelopes, isLocal: true);
    await _updatePushWatermark(envelopes);
  }

  /// Pulls server-side relay envelopes since the last pull and applies them
  /// to the local node cache.
  ///
  /// Catch-up is driven by the server-assigned seq cursor persisted in
  /// `sync_watermark.cursor_seq`; the HLC watermark is only kept for
  /// snapshot-freshness decisions and for advancing the local HLC clock used
  /// when producing new operations. `restoreEpoch` changes wipe the derived
  /// state and resync from seq 0 (pending outbox ops survive and are
  /// re-pushed after the catch-up, mirroring the v2 engine's park/resync).
  /// Per-page progress is reported through [onPullProgress].
  Future<void> pull() async {
    if (serverless) return;
    final workspaceId = await getWorkspaceId();
    if (workspaceId == null) return;
    _pullInFlight = true;
    try {
      await _pullGeneration(workspaceId, requeuePending: true);
    } finally {
      _pullInFlight = false;
      // Frames buffered while catch-up ran apply now; id-dedupe makes the
      // overlap harmless.
      await _drainWsBuffer();
    }
  }

  Future<void> _pullGeneration(
    String workspaceId, {
    required bool requeuePending,
    int depth = 0,
  }) async {
    final snapshot = await _relay.latestSnapshot(workspaceId);
    var localEpoch = await _watermarks.getRestoreEpoch(workspaceId);

    var resynced = false;
    if (snapshot.restoreEpoch != localEpoch) {
      // Server restored/rebuilt: park unsent ops (the outbox survives the
      // wipe), drop the derived state, and resync from seq 0.
      await _cache.clear();
      await _watermarks.resetWorkspace(workspaceId);
      await _watermarks.setReceived(
        workspaceId,
        const Hlc(physical: 0, logical: 0),
        restoreEpoch: snapshot.restoreEpoch,
        cursorSeq: 0,
      );
      localEpoch = snapshot.restoreEpoch;
      resynced = true;
    }

    // If the class or property-schema cache is empty (e.g. after a schema
    // migration that added the tables), force a fresh snapshot restore so
    // metadata gets populated.
    if (await _cache.classCacheCount() == 0 ||
        await _cache.propertySchemaCacheCount() == 0) {
      await _watermarks.resetWorkspace(workspaceId);
    }

    var cursorSeq = await _watermarks.getCursorSeq(workspaceId);
    var lastReceived =
        await _watermarks.getReceived(workspaceId) ??
        const Hlc(physical: 0, logical: 0);
    // Snapshot freshness is decided by the seq cursor (SPEC §2.1); the HLC
    // comparison is only a fallback for snapshots recorded before the seq
    // cursor existed (upToSeq == null).
    final snapshotIsNewer =
        snapshot.hasSnapshot &&
        (snapshot.upToSeq != null
            ? snapshot.upToSeq! > cursorSeq
            : snapshot.hlc.compareTo(lastReceived) > 0);
    // The blob is fetched only when the metadata probe says the snapshot is
    // worth restoring — `GET /relay/v2/snapshot` is metadata-only, so
    // the probe stays cheap on large workspaces.
    if (snapshotIsNewer) {
      final bytes = await _relay.latestSnapshotData(workspaceId);
      if (bytes != null && bytes.isNotEmpty) {
        await _cache.restoreFromSnapshot(bytes, workspaceId);
        lastReceived = snapshot.hlc;
        // Snapshots recorded before the seq cursor existed report null; catch
        // up from 0 and rely on operation-id dedupe.
        cursorSeq = snapshot.upToSeq ?? 0;
        await _watermarks.setReceived(
          workspaceId,
          lastReceived,
          restoreEpoch: snapshot.restoreEpoch,
          cursorSeq: cursorSeq,
        );
      }
    }

    // Apply and persist the cursor page by page: a mid-page throw then only
    // re-fetches the remaining pages, and already-recorded envelope ids are
    // deduped on apply.
    final appliers = RelayAppliers(_cache);
    var maxHlc = lastReceived;
    var appliedOps = 0;
    while (true) {
      final response = await _relay.catchUp(
        workspaceId: workspaceId,
        afterSeq: cursorSeq,
      );
      if (response.restoreEpoch != localEpoch) {
        // The server restored mid-pull: wipe and run one fresh generation.
        if (depth >= 1) {
          throw const SyncV2Exception(
            'restoreEpoch changed repeatedly during pull',
          );
        }
        await _pullGeneration(
          workspaceId,
          requeuePending: requeuePending,
          depth: depth + 1,
        );
        return;
      }
      if (response.envelopes.isNotEmpty) {
        final stats = await _applyServerEnvelopes(appliers, response.envelopes);
        appliedOps += stats.applied;
        if (stats.maxHlc.compareTo(maxHlc) > 0) maxHlc = stats.maxHlc;
      }
      onPullProgress?.call(
        SyncPullProgress(
          applied: appliedOps,
          total: appliedOps + response.totalRemaining,
        ),
      );
      final next = response.nextAfterSeq;
      if (next != null) cursorSeq = next;
      await _watermarks.setReceived(
        workspaceId,
        maxHlc,
        restoreEpoch: localEpoch,
        cursorSeq: cursorSeq,
      );
      // On the final page nextAfterSeq is still set to the last envelope's
      // seq, so the cursor persisted above covers the tail. A null cursor
      // with hasMore would loop forever; break defensively.
      if (!response.hasMore || next == null) break;
    }
    _clock.update(maxHlc);

    if (await _cache.shouldReindexSearch()) {
      await _cache.reindexAll();
    }

    if (resynced && requeuePending) {
      // The outbox survived the wipe: push the parked local ops, then pull
      // once more to fold their echoes into the rebuilt state.
      await flush();
      await _pullGeneration(workspaceId, requeuePending: false, depth: depth);
    }
  }

  /// Shared remote-apply path (catch-up pages and buffered WS ops frames):
  /// dedupe against envelopes already applied from the server, apply through
  /// the v2 appliers, record, and track the HLC watermark. Locally produced
  /// envelopes (is_local = 1) are NOT deduped here: they are applied to the
  /// cache on flush, and re-applying the echo is harmless — the appliers are
  /// row-LWW / first-create-wins idempotent.
  Future<_ApplyStats> _applyServerEnvelopes(
    RelayAppliers appliers,
    List<OperationEnvelope> envelopes,
  ) async {
    var applied = 0;
    var maxHlc = const Hlc(physical: 0, logical: 0);
    final knownIds = await _appliedOperationIds(
      envelopes.map((e) => e.id).toList(),
    );
    for (final envelope in envelopes) {
      if (knownIds.contains(envelope.id)) continue;
      try {
        final didApply = await appliers.apply(envelope);
        await _recordOperations([envelope], isLocal: false);
        if (didApply) applied++;
      } on StoreError catch (e) {
        // Typed applier failure (cycle, move guard, placement CHECK,
        // payload validation): fail loud, and do NOT consume the
        // envelope id — a later pull re-applies it, and a wipe resyncs
        // the prefix deterministically (mirrors the v2 store, where a
        // thrown apply rolls back with the dedupe record).
        debugPrint(
          'SyncV2Service: skipping ${envelope.id} (${envelope.opType}): $e',
        );
        continue;
      }
      if (envelope.hlc.compareTo(maxHlc) > 0) {
        maxHlc = envelope.hlc;
      }
    }
    return (applied: applied, maxHlc: maxHlc);
  }

  // --- realtime acceleration path (WIRE.md §2) -------------------------------

  /// Starts the realtime WebSocket acceleration path for the current
  /// workspace. [apiKey] authenticates the handshake (the per-server key the
  /// Dio layer already attaches as `X-API-Key`).
  ///
  /// Every (re)connect sends a fresh `hello`: a restoreEpoch change or a
  /// `latestSeq` ahead of the cursor triggers a catch-up pull; `ops` frames
  /// buffer while a pull runs and drain through the same apply path as
  /// catch-up (op-id dedupe makes the overlap harmless). Live frames never
  /// advance the seq cursor — the socket is an accelerator only; a dropped
  /// socket is indistinguishable from a delayed one and the cursor covers
  /// the gap on the next pull.
  void startRealtime({required String apiKey}) {
    if (serverless) return;
    final generation = ++_realtimeGeneration;
    final baseUrl = dio.options.baseUrl;
    getWorkspaceId().then((workspaceId) {
      // Stopped (or restarted) while the workspace lookup was in flight.
      if (generation != _realtimeGeneration) return;
      if (workspaceId == null || _ws != null) return;
      final client = RelayWsClient(
        url: buildRelayWsUrl(baseUrl, workspaceId, apiKey),
        connector: wsConnectorOverride,
        onHello: (hello) {
          _runWsWork(_onWsHello(hello, workspaceId));
        },
        onOps: (envelopes, seqs) {
          _onRemoteOps(envelopes, seqs);
        },
        onAck: (savedIds) {
          _runWsWork(_onWsAck(savedIds));
        },
        onError: (error) {
          lastRealtimeError = error.toString();
          onRealtimeError?.call(lastRealtimeError!);
          debugPrint('SyncV2Service: realtime error: $error');
        },
      );
      _ws = client;
      client.start();
    });
  }

  /// Stops the realtime stream (clean close, no reconnect) and drops any
  /// buffered frames.
  Future<void> stopRealtime() async {
    // Invalidate any start whose workspace lookup is still in flight.
    _realtimeGeneration++;
    _wsBuffer.clear();
    final client = _ws;
    _ws = null;
    if (client != null) {
      await client.stop();
    }
    // Drain work queued by in-flight frames: a stop (logout, workspace
    // switch, teardown) must never leave callbacks running against state
    // that has been closed behind them.
    final pending = _pendingWsWork.toList(growable: false);
    if (pending.isNotEmpty) {
      await Future.wait(pending);
    }
  }

  /// Runs [work] kicked off by a WS frame, tracking it for
  /// [stopRealtime]'s drain.
  void _runWsWork(Future<void> work) {
    _pendingWsWork.add(work);
    work.whenComplete(() => _pendingWsWork.remove(work));
  }

  Future<void> _onWsHello(WsHelloInfo hello, String workspaceId) async {
    final localEpoch = await _watermarks.getRestoreEpoch(workspaceId);
    final cursor = await _watermarks.getCursorSeq(workspaceId);
    if (hello.restoreEpoch != localEpoch) {
      // The server restored/rebuilt: wipe + resync from 0 (the outbox is
      // parked and re-pushed after the catch-up), then the pull's finally
      // drains the frame buffer.
      await _resyncFromEpochChange(workspaceId, hello.restoreEpoch);
    } else if (hello.latestSeq > cursor) {
      // Behind: catch up over HTTP from the seq cursor.
      await pull();
    } else {
      await _drainWsBuffer();
    }
  }

  /// Server restoreEpoch changed (advertised by a WS hello): park unsent
  /// ops (the outbox survives), wipe the derived state, and resync from
  /// seq 0. Mirrors the v2 engine's resyncFromEpochChange.
  Future<void> _resyncFromEpochChange(String workspaceId, int newEpoch) async {
    await _cache.clear();
    await _watermarks.resetWorkspace(workspaceId);
    await _watermarks.setReceived(
      workspaceId,
      const Hlc(physical: 0, logical: 0),
      restoreEpoch: newEpoch,
      cursorSeq: 0,
    );
    await _pullGeneration(workspaceId, requeuePending: true);
  }

  void _onRemoteOps(
    List<Map<String, dynamic>> envelopes,
    Map<String, int> seqs,
  ) {
    if (envelopes.isEmpty) return;
    _wsBuffer.add((envelopes: envelopes, seqs: seqs));
    if (!_pullInFlight) {
      unawaited(_drainWsBuffer());
    }
  }

  Future<void> _drainWsBuffer() async {
    if (_pullInFlight) return;
    while (_wsBuffer.isNotEmpty && !_pullInFlight) {
      final frame = _wsBuffer.removeAt(0);
      try {
        final envelopes = [
          for (final raw in frame.envelopes)
            OperationEnvelope.fromJson(raw),
        ];
        final stats = await _applyServerEnvelopes(
          RelayAppliers(_cache),
          envelopes,
        );
        if (stats.maxHlc.physical > 0) {
          _clock.update(stats.maxHlc);
        }
      } on FormatException catch (e) {
        // Unparseable frame: drop the remaining buffer — unapplied frames
        // never advanced the cursor, so the next pull re-fetches them
        // through catch-up (v1 buffer-drop semantics).
        _wsBuffer.clear();
        debugPrint('SyncV2Service: dropping WS buffer after $e');
        return;
      }
    }
  }

  Future<void> _onWsAck(List<String> savedIds) async {
    // Server acks ids pushed over the socket (a no-op for HTTP-pushed ids).
    await _outbox.removeByEnvelopeIds(savedIds);
  }

  /// Builds a v2 derived-state snapshot from the local cache and uploads it
  /// to the relay (`PUT /snapshot/data`). Explicit/manual only — settings
  /// surfaces the trigger; the client never auto-uploads on pull. The
  /// covering HLC is the pushed watermark (falling back to received).
  Future<void> uploadSnapshot() async {
    if (serverless) return;
    final workspaceId = await getWorkspaceId();
    if (workspaceId == null) return;
    final bytes = await _cache.buildV2SnapshotBytes(workspaceId);
    if (bytes == null || bytes.isEmpty) return;
    final hlc = await _watermarks.getPushed(workspaceId) ??
        await _watermarks.getReceived(workspaceId) ??
        const Hlc(physical: 0, logical: 0);
    await _relay.uploadSnapshot(
      workspaceId: workspaceId,
      bytes: bytes,
      hlc: hlc,
    );
  }

  /// Ids from [ids] already recorded as applied from the server.
  Future<Set<String>> _appliedOperationIds(List<String> ids) async {
    if (ids.isEmpty) return const {};
    final db = await _database.database;
    final placeholders = ids.map((_) => '?').join(',');
    final rows = await db.rawQuery(
      'SELECT id FROM relay_operations WHERE is_local = 0 AND id IN ($placeholders)',
      ids,
    );
    return rows.map((r) => r['id'] as String).toSet();
  }

  /// Serverless flush: applies pending envelopes to the local derived cache
  /// without pushing them anywhere.
  ///
  /// Envelopes already recorded as locally applied (`is_local = 1`) are
  /// skipped, so repeated flushes are cheap no-ops. The rows stay in the
  /// outbox (state `pending`) so a later server attach pushes them through
  /// the normal path.
  Future<void> _flushServerless(List<PendingRelayEnvelope> pending) async {
    final known = await _localOperationIds(
      pending.map((p) => p.envelope.id).toList(),
    );
    final fresh = pending.where((p) => !known.contains(p.envelope.id)).toList();
    if (fresh.isEmpty) return;

    final appliers = RelayAppliers(_cache);
    final envelopes = <OperationEnvelope>[];
    for (final entry in fresh) {
      await appliers.apply(entry.envelope);
      envelopes.add(entry.envelope);
    }
    await _recordOperations(envelopes, isLocal: true);

    if (await _cache.shouldReindexSearch()) {
      await _cache.reindexAll();
    }
  }

  /// Ids from [ids] already recorded as applied locally (serverless mode).
  Future<Set<String>> _localOperationIds(List<String> ids) async {
    if (ids.isEmpty) return const {};
    final db = await _database.database;
    final placeholders = ids.map((_) => '?').join(',');
    final rows = await db.rawQuery(
      'SELECT id FROM relay_operations WHERE is_local = 1 AND id IN ($placeholders)',
      ids,
    );
    return rows.map((r) => r['id'] as String).toSet();
  }

  /// Builds a relay envelope for a raw [opType]/[payload]: fresh id, the
  /// advanced local HLC, the current workspace. Shared by [emitLocal] and
  /// the §34.65 default-mirror sweep.
  Future<OperationEnvelope> _buildEnvelope({
    required String opType,
    required Map<String, dynamic> payload,
    required List<String> affectedNodeIds,
  }) async {
    final workspaceId = await getWorkspaceId();
    if (workspaceId == null) {
      throw const SyncV2Exception('No workspace configured');
    }
    return OperationEnvelope(
      id: Uuid7.generate(),
      workspaceId: workspaceId,
      actorId: actorId,
      deviceId: _clientId,
      client: 'flutter',
      hlc: _clock.advance(),
      affectedNodeIds: affectedNodeIds,
      opType: opType,
      payload: payload,
      timestamp: DateTime.now().toUtc().toIso8601String(),
    );
  }

  /// Builds a relay envelope for a raw [opType]/[payload], enqueues it in the
  /// outbox, applies it to the local cache and records it as locally applied.
  ///
  /// Used by the local workspace seed, which needs op types [enqueue] does
  /// not model plus immediate cache application. A later serverless [flush]
  /// skips the envelope via operation-id dedupe; after a server attach, flush
  /// pushes the still-pending outbox row.
  Future<OperationEnvelope> emitLocal({
    required String opType,
    required Map<String, dynamic> payload,
    required List<String> affectedNodeIds,
  }) async {
    final envelope = await _buildEnvelope(
      opType: opType,
      payload: payload,
      affectedNodeIds: affectedNodeIds,
    );
    await _outbox.enqueue(envelope);
    await RelayAppliers(_cache).apply(envelope);
    await _recordOperations([envelope], isLocal: true);
    return envelope;
  }

  /// User-defined class ORDER (class.reorder, display-only LWW-by-arrival):
  /// writes the node's full ordered member list; the applier keeps ordered
  /// members first and appends any unlisted present members sorted by id
  /// (`WorkspaceClient.reorderClasses` parity). Applied locally, push kicked
  /// off on the next flush.
  Future<OperationEnvelope> reorderClasses({
    required String objectId,
    required List<String> classIds,
  }) =>
      emitLocal(
        opType: 'class.reorder',
        payload: OperationPayloads.classReorder(
          objectId: objectId,
          classIds: classIds,
        ),
        affectedNodeIds: [objectId],
      );

  /// §34.90 bullet-button writes: sets a property value at [idx] (0 = the
  /// single-value slot). Applied locally, push kicked off on the next flush
  /// (`enqueue`'s set_property intent only addresses idx 0 and cannot carry
  /// the multi_select array shape; these ride emitLocal like reorderClasses).
  Future<OperationEnvelope> setPropertyValue({
    required String objectId,
    required String propertySchemaId,
    required dynamic value,
    int idx = 0,
  }) =>
      emitLocal(
        opType: 'property.set',
        payload: OperationPayloads.propertySet(
          objectId: objectId,
          propertySchemaId: propertySchemaId,
          value: value,
          idx: idx,
        ),
        affectedNodeIds: [objectId],
      );

  /// §34.90 bullet-button writes: clears the property slot at [idx] (the
  /// "None" row of the value-display sheet).
  Future<OperationEnvelope> unsetPropertyValue({
    required String objectId,
    required String propertySchemaId,
    int idx = 0,
  }) =>
      emitLocal(
        opType: 'property.unset',
        payload: OperationPayloads.propertyUnset(
          objectId: objectId,
          propertySchemaId: propertySchemaId,
          idx: idx,
        ),
        affectedNodeIds: [objectId],
      );

  /// Rewrites the workspace (and optionally actor) id of all locally produced
  /// relay state: pending outbox envelopes, recorded operations and
  /// favorites. Called when a local profile attaches a server, so the
  /// accumulated outbox maps onto the server workspace and its actor.
  Future<void> remapWorkspace(
    String fromWorkspaceId,
    String toWorkspaceId, {
    String? actorId,
  }) async {
    final db = await _database.database;

    // Outbox rows embed the workspace/actor ids inside the envelope JSON;
    // rewrite row by row instead of relying on SQLite JSON1 availability.
    final rows = await db.query(
      'relay_outbox',
      columns: ['id', 'envelope_json'],
    );
    for (final row in rows) {
      final envelopeJson =
          jsonDecode(row['envelope_json'] as String) as Map<String, dynamic>;
      if (envelopeJson['workspaceId'] != fromWorkspaceId) continue;
      envelopeJson['workspaceId'] = toWorkspaceId;
      if (actorId != null) envelopeJson['actorId'] = actorId;
      await db.update(
        'relay_outbox',
        {'envelope_json': jsonEncode(envelopeJson)},
        where: 'id = ?',
        whereArgs: [row['id']],
      );
    }

    final operationValues = <String, dynamic>{'workspace_id': toWorkspaceId};
    if (actorId != null) operationValues['actor_id'] = actorId;
    await db.update(
      'relay_operations',
      operationValues,
      where: 'workspace_id = ?',
      whereArgs: [fromWorkspaceId],
    );

    final favoriteValues = <String, dynamic>{'workspace_id': toWorkspaceId};
    if (actorId != null) favoriteValues['actor_id'] = actorId;
    await db.update(
      'user_favorite',
      favoriteValues,
      where: 'workspace_id = ?',
      whereArgs: [fromWorkspaceId],
    );
  }

  /// Maps a local [OperationIntent] to a v2 relay envelope (WIRE.md +
  /// `op-types.ts`). v1 intents with no v2 home (restore, favorites, task
  /// completions) throw [UnsupportedError] — fail loud rather than silently
  /// dropping or emitting a v1 op the relay would 422.
  Future<OperationEnvelope> _intentToEnvelope(
    OperationIntent op,
    String workspaceId,
  ) async {
    final id = Uuid7.generate();
    final hlc = _clock.advance();
    final affectedNodeIds = op.type == 'reorder_favorites'
        ? (op.favoriteNodeUuids ?? const <String>[])
        : [op.nodeUuid, if (op.parentUuid != null) op.parentUuid!];
    final timestamp = DateTime.now().toUtc().toIso8601String();

    late final String opType;
    late final Map<String, dynamic> payload;

    switch (op.type) {
      case 'create':
        final classIds = List<String>.from(op.classUuids ?? []);
        if (op.isTask && !classIds.contains(SystemClassUuids.task)) {
          classIds.add(SystemClassUuids.task);
        }
        if (op.isDaily && !classIds.contains(SystemClassUuids.day)) {
          classIds.add(SystemClassUuids.day);
        }
        if (op.isMonthly && !classIds.contains(SystemClassUuids.month)) {
          classIds.add(SystemClassUuids.month);
        }
        if (op.isYearly && !classIds.contains(SystemClassUuids.year)) {
          classIds.add(SystemClassUuids.year);
        }
        // Render bit (Revision 11): root and journal creates present as
        // main (document chrome); a parented non-journal node stays inline
        // (the applier would default the same from placement, but the
        // intent states it explicitly so the payload is self-describing).
        final presentAsMain =
            op.isPage ||
            op.isDaily ||
            op.isMonthly ||
            op.isYearly ||
            op.parentUuid == null;
        // Title-is-content: `name` is only the initial text content when no
        // explicit contentAst is given (the builder wraps it in a single
        // text token; the editor path pre-parses markdown-ish markers here).
        final contentAst =
            op.contentAst ??
            (op.name != null ? AstBuilder.parseInline(op.name!) : null);
        // v1 create also carried a zero-padded child `index` and `color`;
        // v2 object.create has no position slot (sibling order rides
        // object.move) and no color slot (color rides object.update).
        opType = 'object.create';
        payload = OperationPayloads.objectCreate(
          objectId: op.nodeUuid,
          presentAsMain: presentAsMain,
          classIds: classIds,
          tagIds: op.tagUuids,
          contentAst: contentAst,
          parentId: op.parentUuid,
        );
      case 'update_content':
        opType = 'object.update';
        payload = OperationPayloads.objectUpdate(
          objectId: op.nodeUuid,
          contentAst: op.contentAst,
        );
      case 'update_node':
        // Title-is-content: the protocol has no object `name` field, so a
        // rename is a contentAst replacement (the title IS the content).
        opType = 'object.update';
        payload = OperationPayloads.objectUpdate(
          objectId: op.nodeUuid,
          contentAst: AstBuilder.parseInline(op.name!),
        );
      case 'update_icon':
        opType = 'object.update';
        payload = OperationPayloads.objectUpdate(
          objectId: op.nodeUuid,
          icon: op.propertyValue as String?,
        );
      case 'update_color':
        // §34.43 tri-state: "absent" never reaches this case (the caller
        // omits the color argument and no op is enqueued); a queued op with
        // a null propertyValue is an EXPLICIT CLEAR — the payload builder
        // turns it into `"color": null`, and the outbox envelope JSON keeps
        // the key through an offline round-trip.
        opType = 'object.update';
        payload = OperationPayloads.objectUpdate(
          objectId: op.nodeUuid,
          color: op.propertyValue as String?,
        );
      case 'delete':
        // v1 node.delete was a hard delete; v2 carries that as
        // object.delete with permanent: true.
        opType = 'object.delete';
        payload = OperationPayloads.objectDelete(
          objectId: op.nodeUuid,
          permanent: true,
        );
      case 'archive':
        // v2 has no archive op; the soft tombstone (permanent: false) is the
        // recoverable-delete equivalent of v1's node.archive (trash).
        opType = 'object.delete';
        payload = OperationPayloads.objectDelete(
          objectId: op.nodeUuid,
          permanent: false,
        );
      case 'restore':
        throw UnsupportedError(
          'restore has no v2 op (Phase A gap): the v2 M1 registry has no '
          'un-delete; object.delete is one-way',
        );
      case 'move':
        // v1 ordered children with a zero-padded newIndex position; v2
        // orders by parentId + afterId (server-side fractional allocator).
        opType = 'object.move';
        payload = OperationPayloads.objectMove(
          objectId: op.nodeUuid,
          parentId: op.parentUuid,
          afterId: op.afterUuid,
        );
      case 'set_property':
        opType = 'property.set';
        payload = OperationPayloads.propertySet(
          objectId: op.nodeUuid,
          propertySchemaId: op.propertyUuid ?? '',
          value: op.propertyValue,
        );
      case 'add_class':
        // v2 has no class.assign op: class membership is an add-wins OR-Set
        // seeded by re-issuing object.create with the classIds to add (the
        // server keeps the tree untouched on a re-create).
        opType = 'object.create';
        payload = OperationPayloads.objectCreate(
          objectId: op.nodeUuid,
          classIds: [op.classUuid ?? ''],
        );
      case 'remove_class':
        // Class membership removal (class.unassign): the OR-Set remove
        // complement of the re-issued object.create add carrier.
        opType = 'class.unassign';
        payload = OperationPayloads.classUnassign(
          objectId: op.nodeUuid,
          classId: op.classUuid ?? '',
        );
      case 'add_tag':
        // v2 has no tag.assign op: tag membership is an add-wins OR-Set
        // seeded by re-issuing object.create with the tagIds to add (the
        // server keeps the tree untouched on a re-create).
        opType = 'object.create';
        payload = OperationPayloads.objectCreate(
          objectId: op.nodeUuid,
          tagIds: [op.tagUuid ?? ''],
        );
      case 'remove_tag':
        // Tag removal (2026-10-01 lockstep): the OR-Set remove complement
        // of the re-issued object.create add carrier.
        opType = 'tag.unassign';
        payload = OperationPayloads.tagUnassign(
          objectId: op.nodeUuid,
          tagId: op.tagUuid ?? '',
        );
      case 'add_favorite':
      case 'remove_favorite':
      case 'reorder_favorites':
        throw UnsupportedError(
          '${op.type} has no v2 op (Phase A gap): favorites were dropped '
          'from the v2 M1 registry',
        );
      case 'task_record_completion':
      case 'task_delete_completion':
        throw UnsupportedError(
          '${op.type} has no v2 op (Phase A gap): task completions were '
          'dropped from the v2 M1 registry',
        );
      default:
        throw SyncV2Exception('Unsupported operation type: ${op.type}');
    }

    return OperationEnvelope(
      id: id,
      workspaceId: workspaceId,
      actorId: actorId,
      deviceId: _clientId,
      client: 'flutter',
      hlc: hlc,
      affectedNodeIds: affectedNodeIds,
      opType: opType,
      payload: payload,
      timestamp: timestamp,
    );
  }

  Future<void> _recordOperations(
    List<OperationEnvelope> envelopes, {
    required bool isLocal,
  }) async {
    if (envelopes.isEmpty) return;
    final db = await _database.database;
    final batch = db.batch();
    for (final envelope in envelopes) {
      batch.insert('relay_operations', {
        'id': envelope.id,
        'workspace_id': envelope.workspaceId,
        'actor_id': envelope.actorId,
        'hlc_physical': envelope.hlc.physical,
        'hlc_logical': envelope.hlc.logical,
        'affected_node_ids': jsonEncode(envelope.affectedNodeIds),
        'op_type': envelope.opType,
        'payload': jsonEncode(envelope.payload),
        'timestamp': envelope.timestamp,
        'is_local': isLocal ? 1 : 0,
      }, conflictAlgorithm: ConflictAlgorithm.replace);
    }
    await batch.commit(noResult: true);
  }

  Future<void> _updatePushWatermark(List<OperationEnvelope> envelopes) async {
    if (envelopes.isEmpty) return;
    final workspaceId = envelopes.first.workspaceId;
    var maxHlc = envelopes.first.hlc;
    for (final envelope in envelopes) {
      if (envelope.hlc.compareTo(maxHlc) > 0) {
        maxHlc = envelope.hlc;
      }
    }
    final current = await _watermarks.getPushed(workspaceId);
    if (current == null || maxHlc.compareTo(current) > 0) {
      await _watermarks.setPushed(workspaceId, maxHlc);
    }
  }

  Future<void> _quarantine(List<int> ids, String error) async {
    if (ids.isEmpty) return;
    // Surface quarantined ops instead of dropping them silently; they stay
    // in `relay_outbox` with state = 'quarantined' for inspection, and the
    // error is also returned to flush() callers.
    debugPrint(
      'SyncV2Service: quarantining ${ids.length} operation(s) after a '
      'permanent push failure: $error',
    );
    final db = await _database.database;
    await db.update(
      'relay_outbox',
      {'state': 'quarantined', 'last_error': error, 'next_retry_at': null},
      where: 'id IN (${ids.map((_) => '?').join(', ')})',
      whereArgs: ids,
    );
  }
}


/// Apply outcome of a server envelope batch.
typedef _ApplyStats = ({int applied, Hlc maxHlc});

/// One buffered realtime `ops` frame.
typedef _WsOpsFrame =
    ({List<Map<String, dynamic>> envelopes, Map<String, int> seqs});
