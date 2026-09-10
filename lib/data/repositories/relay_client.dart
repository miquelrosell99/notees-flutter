import 'dart:typed_data';

import 'package:dio/dio.dart';

import '../../domain/models/relay/operation_envelope.dart';
import '../../domain/models/relay/relay_requests.dart';

/// HTTP client for the Notees operation-relay endpoints.
///
/// The caller is expected to supply a [Dio] instance whose base URL already
/// includes `/api` (e.g. `https://notees.example.com/api`). All methods here
/// use paths relative to that base.
class RelayClient {
  RelayClient({required this.dio});

  final Dio dio;

  static const _batchPath = '/relay/batch';
  static const _catchUpPath = '/relay/catch-up';
  static const _snapshotPath = '/relay/snapshot';
  static const _snapshotDataPath = '/relay/snapshot/data';

  /// Push a batch of operation envelopes to the relay.
  ///
  /// Envelopes are plaintext JSON on the wire; confidentiality comes from the
  /// transport layer (TLS/Tailscale), not from the envelope itself.
  Future<RelayBatchResponse> pushBatch(List<OperationEnvelope> envelopes) async {
    final response = await dio.post<Map<String, dynamic>>(
      _batchPath,
      data: RelayBatchRequest(envelopes: envelopes).toJson(),
    );
    final data = response.data;
    if (data == null) {
      throw const RelayException('Empty relay batch response');
    }
    return RelayBatchResponse.fromJson(data);
  }

  /// Pull operation envelopes with a server-assigned seq greater than
  /// [afterSeq] for [workspaceId].
  ///
  /// Envelopes arrive in ascending seq order. Adopt [CatchUpResponse.nextAfterSeq]
  /// as the cursor for the next page (and as the stored cursor on the final
  /// page). The server caps [limit] to 10,000.
  Future<CatchUpResponse> catchUp({
    required String workspaceId,
    int afterSeq = 0,
    int limit = 1000,
  }) async {
    final response = await dio.post<Map<String, dynamic>>(
      _catchUpPath,
      data: CatchUpRequest(
        workspaceId: workspaceId,
        afterSeq: afterSeq,
        limit: limit,
      ).toJson(),
    );
    final data = response.data;
    if (data == null) {
      throw const RelayException('Empty relay catch-up response');
    }
    return CatchUpResponse.fromJson(data);
  }

  /// Fetch the newest derived-state snapshot for [workspaceId].
  Future<LatestSnapshotResponse> latestSnapshot(String workspaceId) async {
    final response = await dio.get<Map<String, dynamic>>(
      _snapshotPath,
      queryParameters: {'workspace_id': workspaceId},
    );
    final data = response.data;
    if (data == null) {
      throw const RelayException('Empty relay snapshot response');
    }
    return LatestSnapshotResponse.fromJson(data);
  }

  /// Fetch the newest snapshot's blob for [workspaceId] as raw bytes.
  ///
  /// Returns null when the workspace has no snapshot (404). Call only after
  /// [latestSnapshot] reports `hasSnapshot` and the metadata says the
  /// snapshot is worth restoring — the blob can be large.
  Future<Uint8List?> latestSnapshotData(String workspaceId) async {
    try {
      final response = await dio.get<List<int>>(
        _snapshotDataPath,
        queryParameters: {'workspace_id': workspaceId},
        options: Options(responseType: ResponseType.bytes),
      );
      final data = response.data;
      if (data == null) return null;
      return Uint8List.fromList(data);
    } on DioException catch (err) {
      if (err.response?.statusCode == 404) return null;
      rethrow;
    }
  }
}

class RelayException implements Exception {
  const RelayException(this.message);

  final String message;

  @override
  String toString() => 'RelayException: $message';
}
