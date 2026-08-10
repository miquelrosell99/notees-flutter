import 'hlc.dart';
import 'operation_envelope.dart';

/// Request body for `POST /api/relay/batch`.
class RelayBatchRequest {
  const RelayBatchRequest({required this.envelopes});

  final List<OperationEnvelope> envelopes;

  Map<String, dynamic> toJson() => {
        'envelopes': envelopes.map((e) => e.toJson()).toList(),
      };
}

/// Response body for `POST /api/relay/batch`.
class RelayBatchResponse {
  const RelayBatchResponse({
    required this.savedCount,
    required this.savedIds,
  });

  final int savedCount;
  final List<String> savedIds;

  factory RelayBatchResponse.fromJson(Map<String, dynamic> json) =>
      RelayBatchResponse(
        savedCount: json['saved_count'] as int,
        savedIds: (json['saved_ids'] as List<dynamic>).cast<String>(),
      );
}

/// Request body for `POST /api/relay/catch-up`.
class CatchUpRequest {
  const CatchUpRequest({
    required this.workspaceId,
    required this.hlc,
    this.afterId,
    this.limit = 1000,
  });

  final String workspaceId;
  final Hlc hlc;
  final String? afterId;
  final int limit;

  Map<String, dynamic> toJson() => {
        'workspace_id': workspaceId,
        'hlc': hlc.toJson(),
        if (afterId != null) 'after_id': afterId,
        'limit': limit,
      };
}

/// Response body for `POST /api/relay/catch-up`.
class CatchUpResponse {
  const CatchUpResponse({
    required this.envelopes,
    required this.nextAfterId,
    required this.hasMore,
    required this.restoreEpoch,
  });

  final List<OperationEnvelope> envelopes;
  final String? nextAfterId;
  final bool hasMore;
  final int restoreEpoch;

  factory CatchUpResponse.fromJson(Map<String, dynamic> json) => CatchUpResponse(
        envelopes: (json['envelopes'] as List<dynamic>)
            .map((e) => OperationEnvelope.fromJson(e as Map<String, dynamic>))
            .toList(),
        nextAfterId: json['next_after_id'] as String?,
        hasMore: json['has_more'] as bool,
        restoreEpoch: json['restore_epoch'] as int,
      );
}

/// Response body for `GET /api/relay/snapshot`.
class LatestSnapshotResponse {
  const LatestSnapshotResponse({
    required this.snapshotId,
    required this.workspaceId,
    required this.hlc,
    required this.dataBase64,
    required this.hasSnapshot,
    required this.restoreEpoch,
  });

  final String? snapshotId;
  final String workspaceId;
  final Hlc hlc;
  final String? dataBase64;
  final bool hasSnapshot;
  final int restoreEpoch;

  factory LatestSnapshotResponse.fromJson(Map<String, dynamic> json) =>
      LatestSnapshotResponse(
        snapshotId: json['snapshot_id'] as String?,
        workspaceId: json['workspace_id'] as String,
        hlc: Hlc.fromJson(json['hlc'] as Map<String, dynamic>),
        dataBase64: json['data_base64'] as String?,
        hasSnapshot: json['has_snapshot'] as bool,
        restoreEpoch: json['restore_epoch'] as int,
      );
}
