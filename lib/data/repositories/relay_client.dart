import 'package:dio/dio.dart';

import '../../domain/models/relay/hlc.dart';
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

  /// Push a batch of encrypted operation envelopes to the relay.
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

  /// Pull operation envelopes newer than [hlc] for [workspaceId].
  ///
  /// Pagination uses [afterId] (the id of the last envelope from the previous
  /// page). The server caps [limit] to 10,000.
  Future<CatchUpResponse> catchUp({
    required String workspaceId,
    required Hlc hlc,
    String? afterId,
    int limit = 1000,
  }) async {
    final response = await dio.post<Map<String, dynamic>>(
      _catchUpPath,
      data: CatchUpRequest(
        workspaceId: workspaceId,
        hlc: hlc,
        afterId: afterId,
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
}

class RelayException implements Exception {
  const RelayException(this.message);

  final String message;

  @override
  String toString() => 'RelayException: $message';
}
