import 'dart:convert';

import 'package:dio/dio.dart';

import '../../data/local/app_database.dart';
import '../../data/models/node.dart';
import '../../data/repositories/node_cache_repository.dart';
import '../../data/repositories/sync_outbox_repository.dart';
import '../models/sync_v1.dart';
import '../models/sync_v2.dart';

/// API client for the v2 vector-clock sync endpoint.
class SyncV2Client {
  SyncV2Client({required this.dio});

  final Dio dio;

  Future<SyncBatchResponse> sendBatch(SyncBatchRequest request) async {
    final response = await dio.post<Map<String, dynamic>>(
      '/sync/batch',
      data: request.toJson(),
    );
    final data = response.data;
    if (data == null) {
      throw const SyncV2Exception('Empty sync response');
    }
    return SyncBatchResponse.fromJson(data);
  }
}

/// Exception thrown when the sync protocol encounters an unrecoverable error.
class SyncV2Exception implements Exception {
  const SyncV2Exception(this.message);

  final String message;

  @override
  String toString() => 'SyncV2Exception: $message';
}

/// Client-side v2 sync orchestrator.
///
/// Owns the local outbox, client sequence counter, acked version vector, and
/// local node cache. Callers enqueue [OperationIntent]s and periodically
/// [flush]. Server changes are pulled via [pull] and applied to the local cache.
class SyncV2Service {
  SyncV2Service({
    required AppDatabase database,
    required this.dio,
    required String clientId,
  })  : _outbox = SyncOutboxRepository(database),
        _vectorStore = VectorClockStore(database),
        _cache = NodeCacheRepository(database),
        _clientId = clientId;

  final SyncOutboxRepository _outbox;
  final VectorClockStore _vectorStore;
  final NodeCacheRepository _cache;
  final Dio dio;
  final String _clientId;

  String get clientId => _clientId;

  static const _ackedVectorKey = 'sync_v2_acked_vector';
  static const _clientSeqKey = 'sync_v2_client_seq';

  /// Returns the next sequence number for this client and persists it.
  Future<int> nextSeq() async {
    final raw = await _vectorStore.read(_clientSeqKey);
    final seq = raw != null ? (int.tryParse(raw) ?? 0) : 0;
    final next = seq + 1;
    await _vectorStore.write(_clientSeqKey, next.toString());
    return next;
  }

  /// Enqueues a new operation for the next sync batch.
  Future<OperationIntent> enqueue({
    required String type,
    required String nodeUuid,
    String? parentUuid,
    String? afterUuid,
    List<Map<String, dynamic>>? contentAst,
    String? name,
    String? classUuid,
    String? tagUuid,
    List<String>? classUuids,
    List<String>? tagUuids,
    bool? isDeleted,
    Map<String, dynamic>? properties,
    bool isPage = false,
    bool isTask = false,
    bool isDaily = false,
    bool isMonthly = false,
    bool isYearly = false,
  }) async {
    final op = OperationIntent(
      type: type,
      clientId: _clientId,
      seq: await nextSeq(),
      nodeUuid: nodeUuid,
      parentUuid: parentUuid,
      afterUuid: afterUuid,
      contentAst: contentAst,
      name: name,
      classUuid: classUuid,
      tagUuid: tagUuid,
      classUuids: classUuids,
      tagUuids: tagUuids,
      isDeleted: isDeleted,
      properties: properties,
      isPage: isPage,
      isTask: isTask,
      isDaily: isDaily,
      isMonthly: isMonthly,
      isYearly: isYearly,
    );
    await _outbox.enqueue(op);
    return op;
  }

  /// Returns the last server-confirmed version vector.
  Future<BaseVector> getAckedVector() async {
    final raw = await _vectorStore.read(_ackedVectorKey);
    if (raw == null || raw.isEmpty) return {};
    final decoded = jsonDecode(raw) as Map<String, dynamic>;
    return decoded.map(
      (nodeUuid, vector) => MapEntry(
        nodeUuid,
        (vector as Map<String, dynamic>).map(
          (clientId, seq) => MapEntry(clientId, seq as int),
        ),
      ),
    );
  }

  Future<void> _setAckedVector(BaseVector vector) async {
    await _vectorStore.write(_ackedVectorKey, jsonEncode(vector));
  }

  /// Sends pending operations to the server and updates local state.
  ///
  /// Returns a list of errors for operations that should be retried later.
  Future<List<String>> flush() async {
    final pending = await _outbox.pending();
    if (pending.isEmpty) return [];

    final ops = pending.map((p) => p.operation).toList();
    final baseVector = await getAckedVector();

    try {
      final client = SyncV2Client(dio: dio);
      final response = await client.sendBatch(
        SyncBatchRequest(ops: ops, baseVector: baseVector),
      );

      // Success: remove sent ops and update acked vectors.
      await _outbox.removeAll(pending.map((p) => p.id).toList());
      await _setAckedVector(response.newVectors);
      return [];
    } on DioException catch (e) {
      final status = e.response?.statusCode;
      final data = e.response?.data;

      if (status == 409 && data is Map<String, dynamic>) {
        final conflict = SyncConflictResponse.fromJson(data);
        await _setAckedVector(conflict.serverVectors);
        // Server wins: drop any pending ops that touch stale nodes and pull
        // the authoritative server state.
        await _outbox.removeByNodeUuids(conflict.staleNodes);
        await pull();
        return [
          'Sync conflict resolved for ${conflict.staleNodes.join(', ')}',
        ];
      }

      final error = e.message ?? 'Sync request failed';
      await _markPendingRetry(pending, error);
      return [error];
    } catch (e) {
      final error = e.toString();
      await _markPendingRetry(pending, error);
      return [error];
    }
  }

  /// Pulls server-side node changes since the last pull and updates the local
  /// node cache. This uses the v1 timestamp-based sync endpoint with no client
  /// changes, which is effectively a read-only pull.
  Future<void> pull() async {
    final lastSync = await _cache.getLastSync();
    final request = SyncRequest(
      lastSync: lastSync != null ? DateTime.parse(lastSync) : null,
      clientNodes: const [],
    );

    final response = await dio.post<Map<String, dynamic>>(
      '/sync',
      data: request.toJson(),
    );

    final data = response.data;
    if (data == null) return;
    final syncResponse = SyncResponse.fromJson(data);

    // Apply server node snapshots.
    final nodes = syncResponse.serverNodes.map(_serverNodeToNode).toList();
    await _cache.upsertMany(nodes);

    // Apply deletions.
    if (syncResponse.deletedNodeUuids.isNotEmpty) {
      await _cache.deleteByUuids(syncResponse.deletedNodeUuids);
    }

    await _cache.setLastSync(syncResponse.serverTime);
  }

  Node _serverNodeToNode(ServerNodeState state) {
    return Node(
      id: state.version,
      uuid: state.uuid,
      name: state.name ?? '',
      displayName: state.name ?? '',
      parentUuid: state.parentId,
      sequence: state.sequence ?? 0.0,
      isDeleted: state.isDeleted,
      writeDate: state.writeDate,
    );
  }

  Future<void> _markPendingRetry(
    List<PendingSyncOp> pending,
    String error,
  ) async {
    final nextRetry = DateTime.now().add(const Duration(seconds: 5));
    for (final op in pending) {
      await _outbox.markRetry(
        id: op.id,
        error: error,
        nextRetryAt: nextRetry,
      );
    }
  }
}
