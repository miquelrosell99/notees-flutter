import 'dart:io';
import 'dart:typed_data';

import 'package:dio/dio.dart';

import '../../domain/models/relay/hlc.dart';
import '../../domain/models/relay/operation_envelope.dart';
import '../../domain/models/relay/relay_requests.dart';

/// HTTP client for the Notees operation-relay endpoints (protocol v2,
/// `WIRE.md` — base path `/api/relay/v2`).
///
/// The caller is expected to supply a [Dio] instance whose base URL already
/// includes `/api` (e.g. `https://notees.example.com/api`). All methods here
/// use paths relative to that base. The relay authenticates with a single-user
/// API key: the `X-API-Key` header is attached by `RelayApiKeyInterceptor`
/// in `api_client.dart` (wired per active server); when no key is stored the
/// request goes out without the header and the server's 401 surfaces.
class RelayClient {
  RelayClient({required this.dio});

  final Dio dio;

  static const _batchPath = '/relay/v2/batch';
  static const _catchUpPath = '/relay/v2/catch-up';
  static const _snapshotPath = '/relay/v2/snapshot';
  static const _snapshotDataPath = '/relay/v2/snapshot/data';
  static const _snapshotPartPath = '/relay/v2/snapshot/data/part';
  static const _snapshotCommitPath = '/relay/v2/snapshot/data/commit';

  /// Push a batch of operation envelopes to the relay.
  ///
  /// Envelopes are plaintext JSON on the wire; confidentiality comes from the
  /// transport layer (TLS/Tailscale), not from the envelope itself.
  Future<RelayBatchResponse> pushBatch(
    List<OperationEnvelope> envelopes,
  ) async {
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

  /// Fetches the workspace's E2EE wrapped key (user-custody surface,
  /// `GET /workspaces/:id/key`). Returns null when the server holds no key
  /// (404 — key existence is not revealed to non-members either). A 403
  /// (API-key principal — keys are user custody, not operator) propagates.
  Future<String?> fetchWorkspaceKey(String workspaceId) async {
    try {
      final response = await dio.get<Map<String, dynamic>>(
        '/workspaces/$workspaceId/key',
      );
      final data = response.data;
      if (data == null) {
        throw const RelayException('Empty workspace key response');
      }
      return data['wrappedKey'] as String?;
    } on DioException catch (err) {
      if (err.response?.statusCode == 404) return null;
      rethrow;
    }
  }

  /// Stores the workspace's E2EE wrapped key (`PUT /workspaces/:id/key`).
  /// First write wins server-side: a 409 means a concurrent device stored
  /// its key first — the caller re-fetches and adopts the winner (plan-02
  /// semantics, never a blind upsert that would split the workspace's keys).
  Future<void> storeWorkspaceKey(
    String workspaceId,
    String wrappedKey,
  ) async {
    await dio.put<void>(
      '/workspaces/$workspaceId/key',
      data: {'wrappedKey': wrappedKey},
    );
  }

  /// Fetch the newest derived-state snapshot for [workspaceId].
  Future<LatestSnapshotResponse> latestSnapshot(String workspaceId) async {
    final response = await dio.get<Map<String, dynamic>>(
      _snapshotPath,
      queryParameters: {'workspaceId': workspaceId},
    );
    final data = response.data;
    if (data == null) {
      throw const RelayException('Empty relay snapshot response');
    }
    return LatestSnapshotResponse.fromJson(data);
  }

  /// Upload a client-produced snapshot for [workspaceId] (WIRE.md:
  /// `PUT /snapshot/data` with the covering HLC as query parameters).
  /// [sealed] declares the body a SEALED image; the flag rides the snapshot
  /// row and is served back as `sealed` in `GET /snapshot` meta (the restore
  /// contract). Callers: the explicit Settings trigger and the pull-time
  /// auto-upload (`maybeUploadSnapshot` parity), both through the service's
  /// file-based pipeline ([uploadSnapshotFile]).
  Future<void> uploadSnapshot({
    required String workspaceId,
    required Uint8List bytes,
    required Hlc hlc,
    bool sealed = false,
  }) async {
    await dio.put<List<int>>(
      _snapshotDataPath,
      queryParameters: {
        'workspaceId': workspaceId,
        'physical': hlc.physical,
        'logical': hlc.logical,
        if (sealed) 'sealed': '1',
      },
      data: bytes,
      options: Options(
        contentType: 'application/octet-stream',
        responseType: ResponseType.bytes,
      ),
    );
  }

  /// File-based variant of [uploadSnapshot] for the snapshot pipeline:
  /// streams the file at [path] as the PUT body without loading it into
  /// RAM (the image can be tens of MB; sealed snapshots up to 48 MiB ride
  /// this single-body path — WIRE.md).
  Future<void> uploadSnapshotFile({
    required String workspaceId,
    required String path,
    required Hlc hlc,
    bool sealed = false,
  }) async {
    final file = File(path);
    final length = await file.length();
    await dio.put<void>(
      _snapshotDataPath,
      queryParameters: {
        'workspaceId': workspaceId,
        'physical': hlc.physical,
        'logical': hlc.logical,
        if (sealed) 'sealed': '1',
      },
      data: file.openRead(),
      options: Options(
        contentType: 'application/octet-stream',
        headers: {Headers.contentLengthHeader: length},
      ),
    );
  }

  /// `PUT /snapshot/data/part` — stage one chunk of a multipart snapshot
  /// upload (WIRE.md). [uploadId] is a client-generated uuid; [index] is
  /// zero-based and stages exactly once (a duplicate index is 422).
  Future<void> uploadSnapshotPart({
    required String workspaceId,
    required String uploadId,
    required int index,
    required Uint8List bytes,
  }) async {
    // 201 returns {upload, index} (WIRE.md).
    await dio.put<Map<String, dynamic>>(
      _snapshotPartPath,
      queryParameters: {
        'workspaceId': workspaceId,
        'upload': uploadId,
        'index': index,
      },
      data: bytes,
      options: Options(
        contentType: 'application/octet-stream',
      ),
    );
  }

  /// `POST /snapshot/data/commit` — concatenate the upload's staged parts
  /// 0..[parts]-1, run the relay's sanity gate, and store the checkpoint
  /// with the same `sealed` flag semantics as the single PUT (WIRE.md).
  Future<void> commitSnapshot({
    required String workspaceId,
    required String uploadId,
    required int parts,
    required Hlc hlc,
    bool sealed = false,
  }) async {
    await dio.post<void>(
      _snapshotCommitPath,
      queryParameters: {
        'workspaceId': workspaceId,
        'physical': hlc.physical,
        'logical': hlc.logical,
        'upload': uploadId,
        'parts': parts,
        if (sealed) 'sealed': '1',
      },
    );
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
        queryParameters: {'workspaceId': workspaceId},
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

  /// Streams the newest snapshot's blob for [workspaceId] straight into
  /// [destinationPath] — the memory-flat counterpart of
  /// [latestSnapshotData] for first-sync restores, where the blob can be
  /// hundreds of MB (the file-based pipeline never holds it all in RAM).
  ///
  /// Chunks are written as they arrive; the written length is verified
  /// against content-length when the server sends one. Non-2xx responses
  /// throw [RelayException]; a partial file is deleted on failure.
  Future<void> downloadSnapshotData({
    required String workspaceId,
    required String destinationPath,
  }) async {
    final Response<dynamic> response;
    try {
      response = await dio.get<dynamic>(
        _snapshotDataPath,
        queryParameters: {'workspaceId': workspaceId},
        options: Options(responseType: ResponseType.stream),
      );
    } on DioException catch (err) {
      final status = err.response?.statusCode;
      if (status != null && (status < 200 || status >= 300)) {
        throw RelayException('snapshot download failed with status $status');
      }
      rethrow;
    }

    final status = response.statusCode;
    if (status != null && (status < 200 || status >= 300)) {
      throw RelayException('snapshot download failed with status $status');
    }

    final data = response.data;
    // Interceptor-served (or otherwise pre-buffered) payloads have no live
    // stream to drain — write them out directly.
    if (data is List<int>) {
      await File(destinationPath).writeAsBytes(data, flush: true);
      return;
    }
    final Stream<Uint8List> stream;
    final int? contentLength;
    if (data is ResponseBody) {
      stream = data.stream;
      contentLength = _contentLengthOf(data.headers);
    } else if (data is Stream<Uint8List>) {
      stream = data;
      contentLength = null;
    } else {
      throw RelayException(
        'snapshot download returned an unexpected payload '
        '(${data.runtimeType})',
      );
    }

    final file = File(destinationPath);
    final raf = await file.open(mode: FileMode.write);
    var written = 0;
    try {
      await for (final chunk in stream) {
        await raf.writeFrom(chunk);
        written += chunk.length;
      }
      if (contentLength != null && written != contentLength) {
        throw RelayException(
          'snapshot download incomplete: wrote $written of '
          '$contentLength bytes',
        );
      }
    } catch (_) {
      try {
        await file.delete();
      } catch (_) {
        // Best-effort cleanup of the partial download.
      }
      rethrow;
    } finally {
      await raf.close();
    }
  }

  static int? _contentLengthOf(Map<String, List<String>> headers) {
    for (final entry in headers.entries) {
      if (entry.key.toLowerCase() == 'content-length' &&
          entry.value.isNotEmpty) {
        return int.tryParse(entry.value.first);
      }
    }
    return null;
  }
}

class RelayException implements Exception {
  const RelayException(this.message);

  final String message;

  @override
  String toString() => 'RelayException: $message';
}

/// Parsed v2 wire error envelope (WIRE.md):
/// `{"error": {"code", "message", "status"}}` with stable machine codes.
class RelayWireError {
  const RelayWireError({
    required this.code,
    required this.message,
    required this.status,
  });

  final String code;
  final String message;
  final int status;

  /// Extracts the wire error from a failed request, or null when the body
  /// does not carry the envelope shape.
  static RelayWireError? tryParse(DioException error) {
    final data = error.response?.data;
    if (data is Map<String, dynamic>) {
      final err = data['error'];
      if (err is Map<String, dynamic> && err['code'] is String) {
        return RelayWireError(
          code: err['code'] as String,
          message: err['message'] as String? ?? err['code'] as String,
          status:
              (err['status'] as num?)?.toInt() ??
              error.response?.statusCode ??
              0,
        );
      }
    }
    return null;
  }

  @override
  String toString() => 'RelayWireError($code, $status): $message';
}
