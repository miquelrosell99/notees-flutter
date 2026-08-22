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
    this.afterSeq = 0,
    this.limit = 1000,
  });

  final String workspaceId;

  /// Exclusive lower bound on the server-assigned envelope sequence number.
  /// `0` fetches from the beginning.
  final int afterSeq;
  final int limit;

  Map<String, dynamic> toJson() => {
        'workspace_id': workspaceId,
        'after_seq': afterSeq,
        'limit': limit,
      };
}

/// Response body for `POST /api/relay/catch-up`.
class CatchUpResponse {
  const CatchUpResponse({
    required this.envelopes,
    required this.nextAfterSeq,
    required this.hasMore,
    required this.restoreEpoch,
  });

  final List<OperationEnvelope> envelopes;

  /// Cursor to adopt and pass back as `after_seq`. Still set on the final
  /// page (`hasMore == false`) to the last envelope's seq; null only when the
  /// page is empty.
  final int? nextAfterSeq;
  final bool hasMore;
  final int restoreEpoch;

  factory CatchUpResponse.fromJson(Map<String, dynamic> json) => CatchUpResponse(
        envelopes: (json['envelopes'] as List<dynamic>)
            .map((e) => OperationEnvelope.fromJson(e as Map<String, dynamic>))
            .toList(),
        nextAfterSeq: json['next_after_seq'] as int?,
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
    this.upToSeq,
  });

  final String? snapshotId;
  final String workspaceId;
  final Hlc hlc;
  final String? dataBase64;
  final bool hasSnapshot;
  final int restoreEpoch;

  /// Highest envelope seq covered by the snapshot; post-restore catch-up
  /// resumes from it. Null for snapshots recorded before the seq cursor
  /// existed — catch up from `0` and rely on operation-id dedupe.
  final int? upToSeq;

  factory LatestSnapshotResponse.fromJson(Map<String, dynamic> json) =>
      LatestSnapshotResponse(
        snapshotId: json['snapshot_id'] as String?,
        workspaceId: json['workspace_id'] as String,
        hlc: Hlc.fromJson(json['hlc'] as Map<String, dynamic>),
        dataBase64: json['data_base64'] as String?,
        hasSnapshot: json['has_snapshot'] as bool,
        restoreEpoch: json['restore_epoch'] as int,
        upToSeq: json['up_to_seq'] as int?,
      );
}
