import './hlc.dart';
import './operation_envelope.dart';

/// Request body for `POST /api/relay/v2/batch` (WIRE.md).
class RelayBatchRequest {
  const RelayBatchRequest({required this.envelopes});

  final List<OperationEnvelope> envelopes;

  Map<String, dynamic> toJson() => {
        'envelopes': envelopes.map((e) => e.toJson()).toList(),
      };
}

/// Response body for `POST /api/relay/v2/batch` (WIRE.md).
///
/// Duplicate envelope ids are silently ignored server-side (idempotent
/// retry), so [savedIds] may omit ids that were sent.
class RelayBatchResponse {
  const RelayBatchResponse({
    required this.savedCount,
    required this.savedIds,
  });

  final int savedCount;
  final List<String> savedIds;

  factory RelayBatchResponse.fromJson(Map<String, dynamic> json) =>
      RelayBatchResponse(
        savedCount: (json['savedCount'] as num?)?.toInt() ?? 0,
        savedIds: (json['savedIds'] as List<dynamic>? ?? const [])
            .cast<String>(),
      );
}

/// Request body for `POST /api/relay/v2/catch-up` (WIRE.md).
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
        'workspaceId': workspaceId,
        'afterSeq': afterSeq,
        'limit': limit,
      };
}

/// Response body for `POST /api/relay/v2/catch-up` (WIRE.md).
class CatchUpResponse {
  const CatchUpResponse({
    required this.envelopes,
    required this.nextAfterSeq,
    required this.hasMore,
    required this.restoreEpoch,
    this.totalRemaining = 0,
  });

  final List<OperationEnvelope> envelopes;

  /// Cursor to adopt and pass back as `afterSeq`. Still set on the final
  /// page (`hasMore == false`) to the last envelope's seq; null only when the
  /// page is empty.
  final int? nextAfterSeq;
  final bool hasMore;
  final int restoreEpoch;

  /// Number of envelopes with a seq greater than the request's `afterSeq`
  /// (including this page) — lets the UI render global catch-up progress.
  final int totalRemaining;

  factory CatchUpResponse.fromJson(Map<String, dynamic> json) => CatchUpResponse(
        envelopes: (json['envelopes'] as List<dynamic>? ?? const [])
            .map((e) => OperationEnvelope.fromJson(e as Map<String, dynamic>))
            .toList(),
        nextAfterSeq: (json['nextAfterSeq'] as num?)?.toInt(),
        hasMore: json['hasMore'] as bool? ?? false,
        restoreEpoch: (json['restoreEpoch'] as num?)?.toInt() ?? 0,
        totalRemaining: (json['totalRemaining'] as num?)?.toInt() ?? 0,
      );
}

/// Response body for `GET /api/relay/v2/snapshot` (metadata only — the blob
/// is served as a raw binary body by `GET /api/relay/v2/snapshot/data`).
class LatestSnapshotResponse {
  const LatestSnapshotResponse({
    required this.snapshotId,
    required this.hlc,
    required this.hasSnapshot,
    required this.restoreEpoch,
    this.upToSeq,
  });

  final String? snapshotId;
  final Hlc hlc;
  final bool hasSnapshot;
  final int restoreEpoch;

  /// Highest envelope seq covered by the snapshot; post-restore catch-up
  /// resumes from it. Null for snapshots recorded before the seq cursor
  /// existed — catch up from `0` and rely on operation-id dedupe.
  final int? upToSeq;

  factory LatestSnapshotResponse.fromJson(Map<String, dynamic> json) =>
      LatestSnapshotResponse(
        snapshotId: json['snapshotId'] as String?,
        hlc: Hlc.fromJson(json['hlc'] as Map<String, dynamic>),
        hasSnapshot: json['hasSnapshot'] as bool? ?? false,
        restoreEpoch: (json['restoreEpoch'] as num?)?.toInt() ?? 0,
        upToSeq: (json['upToSeq'] as num?)?.toInt(),
      );
}
