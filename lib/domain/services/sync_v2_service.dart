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
import '../../data/repositories/sync_watermark_repository.dart';
import '../models/relay/hlc.dart';
import '../models/relay/operation_envelope.dart';
import '../models/relay/operation_payloads.dart';
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
/// internally generates operation-relay envelopes and talks to `/api/relay/*`.
class SyncV2Service {
  SyncV2Service({
    required AppDatabase database,
    required this.dio,
    required this._clientId,
    this.serverless = false,
  })  : _database = database,
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
    await db.insert(
      'sync_state',
      {'key': _workspaceIdKey, 'value': workspaceId},
      conflictAlgorithm: ConflictAlgorithm.replace,
    );
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

    // Guard: a content op with a null AST omits the `content` key on the
    // wire, the server rejects it with 422, and the op would sit in the
    // quarantine forever. Skip it instead and surface via the log.
    final producesNullContent = (type == 'update_content' && contentAst == null) ||
        (type == 'update_node' && name == null);
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
    final envelope = await _intentToEnvelope(op, workspaceId);
    await _outbox.enqueue(envelope);
    return op;
  }

  /// Sends pending relay envelopes to the server and updates local state.
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
      final end =
          i + _pushChunkSize < pending.length ? i + _pushChunkSize : pending.length;
      final chunk = pending.sublist(i, end);
      final ids = chunk.map((p) => p.id).toList();

      await _outbox.markInFlight(ids);
      try {
        final envelopes = chunk.map((p) => p.envelope).toList();
        await _relay.pushBatch(envelopes);
        await _recordOperations(envelopes, isLocal: true);
        await _updatePushWatermark(envelopes);
        await _outbox.removeAll(ids);
      } on DioException catch (e) {
        final status = e.response?.statusCode;
        final error = e.message ?? 'Relay push failed';
        if (status == 401 || status == 403) {
          // Auth errors are retryable; the token may be refreshed before the
          // next flush attempt. Do not quarantine them.
          for (final p in chunk) {
            await _outbox.markRetry(
              id: p.id,
              error: error,
            );
          }
          errors.add(error);
        } else if (status != null && status >= 400 && status < 500) {
          await _quarantine(ids, error);
          errors.add(error);
        } else {
          for (final p in chunk) {
            await _outbox.markRetry(
              id: p.id,
              error: error,
            );
          }
          errors.add(error);
        }
      } catch (e) {
        final error = e.toString();
        for (final p in chunk) {
          await _outbox.markRetry(
            id: p.id,
            error: error,
          );
        }
        errors.add(error);
      }
    }
    return errors;
  }

  /// Pulls server-side relay envelopes since the last pull and applies them to
  /// the local node cache.
  ///
  /// Catch-up is driven by the server-assigned seq cursor persisted in
  /// `sync_watermark.cursor_seq`; the HLC watermark is only kept for
  /// snapshot-freshness decisions and for advancing the local HLC clock used
  /// when producing new operations.
  Future<void> pull() async {
    if (serverless) return;
    final workspaceId = await getWorkspaceId();
    if (workspaceId == null) return;

    final snapshot = await _relay.latestSnapshot(workspaceId);
    final localEpoch = await _watermarks.getRestoreEpoch(workspaceId);

    if (snapshot.restoreEpoch != localEpoch) {
      await _cache.clear();
      await _watermarks.resetWorkspace(workspaceId);
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
        await _watermarks.getReceived(workspaceId) ?? const Hlc(physical: 0, logical: 0);
    // Snapshot freshness is decided by the seq cursor (SPEC §2.1); the HLC
    // comparison is only a fallback for snapshots recorded before the seq
    // cursor existed (upToSeq == null).
    final snapshotIsNewer = snapshot.hasSnapshot &&
        (snapshot.upToSeq != null
            ? snapshot.upToSeq! > cursorSeq
            : snapshot.hlc.compareTo(lastReceived) > 0);
    if (snapshotIsNewer &&
        snapshot.dataBase64 != null &&
        snapshot.dataBase64!.isNotEmpty) {
      final bytes = base64Decode(snapshot.dataBase64!);
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

    // Apply and persist the cursor page by page: a mid-page throw then only
    // re-fetches the remaining pages, and already-recorded envelope ids are
    // deduped on apply.
    final appliers = RelayAppliers(_cache);
    var maxHlc = lastReceived;
    while (true) {
      final response = await _relay.catchUp(
        workspaceId: workspaceId,
        afterSeq: cursorSeq,
      );
      if (response.envelopes.isNotEmpty) {
        // Dedupe against envelopes already applied from the server (a
        // crashed pull, or a snapshot with a null upToSeq). Locally produced
        // envelopes (is_local = 1) are NOT deduped here: they were never
        // applied to the cache and must still be applied when echoed back.
        final knownIds = await _appliedOperationIds(
          response.envelopes.map((e) => e.id).toList(),
        );
        for (final envelope in response.envelopes) {
          if (knownIds.contains(envelope.id)) continue;
          await appliers.apply(envelope);
          await _recordOperations([envelope], isLocal: false);
          if (envelope.hlc.compareTo(maxHlc) > 0) {
            maxHlc = envelope.hlc;
          }
        }
      }
      final next = response.nextAfterSeq;
      if (next != null) cursorSeq = next;
      await _watermarks.setReceived(
        workspaceId,
        maxHlc,
        restoreEpoch: snapshot.restoreEpoch,
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

  /// Builds a relay envelope for a raw [opType]/[payload], enqueues it in the
  /// outbox, applies it to the local cache and records it as locally applied.
  ///
  /// Used by the local workspace seed, which needs op types [enqueue] does
  /// not model (`class.create`) plus immediate cache application. A later
  /// serverless [flush] skips the envelope via operation-id dedupe; after a
  /// server attach, flush pushes the still-pending outbox row.
  Future<OperationEnvelope> emitLocal({
    required String opType,
    required Map<String, dynamic> payload,
    required List<String> affectedNodeIds,
  }) async {
    final workspaceId = await getWorkspaceId();
    if (workspaceId == null) {
      throw const SyncV2Exception('No workspace configured');
    }
    final envelope = OperationEnvelope(
      id: Uuid7.generate(),
      workspaceId: workspaceId,
      actorId: actorId,
      hlc: _clock.advance(),
      affectedNodeIds: affectedNodeIds,
      opType: opType,
      payload: payload,
      timestamp: DateTime.now().toUtc().toIso8601String(),
    );
    await _outbox.enqueue(envelope);
    await RelayAppliers(_cache).apply(envelope);
    await _recordOperations([envelope], isLocal: true);
    return envelope;
  }

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
    final rows = await db.query('relay_outbox', columns: ['id', 'envelope_json']);
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

  Future<OperationEnvelope> _intentToEnvelope(
    OperationIntent op,
    String workspaceId,
  ) async {
    final id = Uuid7.generate();
    final hlc = _clock.advance();
    final affectedNodeIds = op.type == 'reorder_favorites'
        ? (op.favoriteNodeUuids ?? const <String>[])
        : [
            op.nodeUuid,
            if (op.parentUuid != null) op.parentUuid!,
          ];
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
        final kind = (op.isPage || op.isDaily || op.isMonthly || op.isYearly)
            ? 'page'
            : 'block';
        final initialContent = op.contentAst ??
            (op.name != null ? AstBuilder.parseInline(op.name!) : null);
        opType = 'node.create';
        payload = OperationPayloads.nodeCreate(
          nodeId: op.nodeUuid,
          kind: kind,
          parentId: op.parentUuid,
          classIds: classIds,
          color: op.properties?['color'] as String?,
          initialContent: initialContent,
          index: op.newIndex == null ? null : _formatPosition(op.newIndex!),
        );
      case 'update_content':
        opType = 'node.updateContent';
        payload = OperationPayloads.nodeUpdateContent(
          nodeId: op.nodeUuid,
          content: op.contentAst,
        );
      case 'update_node':
        opType = 'node.updateContent';
        payload = OperationPayloads.nodeUpdateContent(
          nodeId: op.nodeUuid,
          content:
              op.name != null ? AstBuilder.parseInline(op.name!) : null,
        );
      case 'update_icon':
        opType = 'node.updateIcon';
        payload = OperationPayloads.nodeUpdateIcon(
          nodeId: op.nodeUuid,
          icon: op.propertyValue as String?,
        );
      case 'update_color':
        opType = 'node.updateColor';
        payload = OperationPayloads.nodeUpdateColor(
          nodeId: op.nodeUuid,
          color: op.propertyValue as String?,
        );
      case 'delete':
        opType = 'node.delete';
        payload = OperationPayloads.nodeDelete(nodeId: op.nodeUuid);
      case 'archive':
        opType = 'node.archive';
        payload = OperationPayloads.nodeArchive(nodeId: op.nodeUuid);
      case 'restore':
        opType = 'node.restore';
        payload = OperationPayloads.nodeRestore(nodeId: op.nodeUuid);
      case 'move':
        opType = 'node.move';
        payload = OperationPayloads.nodeMove(
          nodeId: op.nodeUuid,
          newParentId: op.parentUuid,
          newIndex: op.newIndex == null ? null : _formatPosition(op.newIndex!),
        );
      case 'set_property':
        opType = 'property.set';
        payload = OperationPayloads.propertySet(
          propertyValueId: Uuid7.generate(),
          nodeId: op.nodeUuid,
          schemaId: op.propertyUuid ?? '',
          value: op.propertyValue,
        );
      case 'add_tag':
        opType = 'class.assign';
        payload = OperationPayloads.classAssign(
          nodeId: op.nodeUuid,
          classId: op.tagUuid ?? '',
        );
      case 'remove_tag':
        opType = 'class.unassign';
        payload = OperationPayloads.classUnassign(
          nodeId: op.nodeUuid,
          classId: op.tagUuid ?? '',
        );
      case 'add_favorite':
        opType = 'user.favorite.add';
        payload = OperationPayloads.userFavoriteAdd(nodeId: op.nodeUuid);
      case 'remove_favorite':
        opType = 'user.favorite.remove';
        payload = OperationPayloads.userFavoriteRemove(nodeId: op.nodeUuid);
      case 'reorder_favorites':
        opType = 'user.favorite.reorder';
        payload = OperationPayloads.userFavoriteReorder(
          nodeIds: op.favoriteNodeUuids ?? const <String>[],
        );
      case 'task_record_completion':
        opType = 'task.recordCompletion';
        payload = OperationPayloads.taskRecordCompletion(
          nodeId: op.nodeUuid,
          completionId: op.completionId ?? Uuid7.generate(),
          completedAt: op.completedAt ?? DateTime.now().toUtc().toIso8601String(),
          scheduledDate: op.scheduledDate,
          deadlineDate: op.deadlineDate,
          status: op.completionStatus ?? 'done',
        );
      case 'task_delete_completion':
        opType = 'task.deleteCompletion';
        payload = OperationPayloads.taskDeleteCompletion(
          nodeId: op.nodeUuid,
          completionId: op.completionId ?? '',
        );
      default:
        throw SyncV2Exception('Unsupported operation type: ${op.type}');
    }

    return OperationEnvelope(
      id: id,
      workspaceId: workspaceId,
      actorId: actorId,
      hlc: hlc,
      affectedNodeIds: affectedNodeIds,
      opType: opType,
      payload: payload,
      timestamp: timestamp,
    );
  }

  /// Child positions are stored as zero-padded strings on the server
  /// (`node_child_order.position` is TEXT, ordered lexicographically);
  /// matches the web client's `padStart(10, '0')` format.
  static String _formatPosition(int index) => index.toString().padLeft(10, '0');

  Future<void> _recordOperations(
    List<OperationEnvelope> envelopes, {
    required bool isLocal,
  }) async {
    if (envelopes.isEmpty) return;
    final db = await _database.database;
    final batch = db.batch();
    for (final envelope in envelopes) {
      batch.insert(
        'relay_operations',
        {
          'id': envelope.id,
          'workspace_id': envelope.workspaceId,
          'actor_id': envelope.actorId,
          'hlc_physical': envelope.hlc.physical,
          'hlc_logical': envelope.hlc.logical,
          'affected_node_ids': jsonEncode(envelope.affectedNodeIds),
          'op_type': envelope.opType,
          'payload': jsonEncode(envelope.payload),
          'timestamp': envelope.timestamp ??
              DateTime.now().toUtc().toIso8601String(),
          'is_local': isLocal ? 1 : 0,
        },
        conflictAlgorithm: ConflictAlgorithm.replace,
      );
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
      {
        'state': 'quarantined',
        'last_error': error,
        'next_retry_at': null,
      },
      where: 'id IN (${ids.map((_) => '?').join(', ')})',
      whereArgs: ids,
    );
  }
}
