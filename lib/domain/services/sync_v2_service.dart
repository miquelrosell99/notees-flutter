import 'dart:convert';

import 'package:dio/dio.dart';
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
import 'hlc_clock.dart';
import 'relay_appliers.dart';

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

  String get clientId => _clientId;

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
  Future<void> pull() async {
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

    var lastReceived =
        await _watermarks.getReceived(workspaceId) ?? const Hlc(physical: 0, logical: 0);
    final snapshotIsNewer =
        snapshot.hasSnapshot && snapshot.hlc.compareTo(lastReceived) > 0;
    if (snapshotIsNewer &&
        snapshot.dataBase64 != null &&
        snapshot.dataBase64!.isNotEmpty) {
      final bytes = base64Decode(snapshot.dataBase64!);
      await _cache.restoreFromSnapshot(bytes, workspaceId);
      lastReceived = snapshot.hlc;
      await _watermarks.setReceived(
        workspaceId,
        lastReceived,
        restoreEpoch: snapshot.restoreEpoch,
      );
    }

    final allEnvelopes = <OperationEnvelope>[];
    String? afterId;
    while (true) {
      final response = await _relay.catchUp(
        workspaceId: workspaceId,
        hlc: lastReceived,
        afterId: afterId,
      );
      allEnvelopes.addAll(response.envelopes);
      if (!response.hasMore) break;
      afterId = response.nextAfterId;
      if (afterId == null) break;
    }

    if (allEnvelopes.isNotEmpty) {
      allEnvelopes.sort((a, b) {
        final cmp = a.hlc.compareTo(b.hlc);
        if (cmp != 0) return cmp;
        return a.id.compareTo(b.id);
      });

      final appliers = RelayAppliers(_cache);
      var maxHlc = lastReceived;
      for (final envelope in allEnvelopes) {
        await appliers.apply(envelope);
        await _recordOperations([envelope], isLocal: false);
        if (envelope.hlc.compareTo(maxHlc) > 0) {
          maxHlc = envelope.hlc;
        }
      }
      await _watermarks.setReceived(
        workspaceId,
        maxHlc,
        restoreEpoch: snapshot.restoreEpoch,
      );
      _clock.update(maxHlc);
    }

    if (await _cache.shouldReindexSearch()) {
      await _cache.reindexAll();
    }
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
        if (op.isPage && !classIds.contains(SystemClassUuids.page)) {
          classIds.add(SystemClassUuids.page);
        }
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
          newIndex: op.newIndex,
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
      actorId: _clientId,
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
