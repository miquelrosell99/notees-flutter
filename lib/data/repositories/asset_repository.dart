// ignore_for_file: use_null_aware_elements

import 'dart:io';
import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:path/path.dart' as p;

import '../../core/crypto/crypto_custody.dart';
import '../../domain/models/relay/asset_crypto.dart';
import '../../domain/models/relay/payload_crypto.dart'
    show b64uDecode, b64uEncode;
import '../../domain/services/local_asset_store.dart'
    show LocalAssetService;

/// One asset row as the shipped server routes report it (camelCase,
/// `GET /api/assets/:id/info` shape; the upload response adds nothing else
/// the client reads). The server no longer categorizes or urls assets —
/// [category] is derived client-side from the mime type (the same
/// image/audio/file split as `LocalAssetInfo.category`).
class Asset {
  Asset({
    required this.assetId,
    required this.filename,
    required this.mimeType,
    required this.sizeBytes,
    this.hash,
    this.iv,
  });

  final String assetId;

  /// sha256 hex of the stored bytes (content address), when known.
  final String? hash;
  final String filename;
  final String mimeType;
  final int sizeBytes;

  /// Server-side E2EE metadata (plan 05): b64u of the 12-byte GCM nonce for
  /// sealed bytes (blob layout `tag‖ct`, see asset_crypto.dart). Null means
  /// the asset is plaintext and every path behaves as before.
  final String? iv;

  /// image / audio / file — derived from [mimeType].
  String get category {
    if (mimeType.startsWith('image/')) return 'image';
    if (mimeType.startsWith('audio/')) return 'audio';
    return 'file';
  }

  factory Asset.fromJson(Map<String, dynamic> json) => Asset(
        assetId: json['assetId'] as String,
        hash: json['hash'] as String?,
        filename: json['originalName'] as String? ??
            json['assetId'] as String? ??
            'asset',
        mimeType: json['mimeType'] as String? ?? 'application/octet-stream',
        sizeBytes: (json['size'] as num?)?.toInt() ?? 0,
        iv: json['iv'] as String?,
      );
}

/// The asset REST channel against the shipped server routes: `POST
/// /api/assets` (multipart CAS upload), `GET /api/assets/:id` (bytes, Range
/// capable), `GET /api/assets/:id/info`, `GET /api/assets` (index). Plan-05
/// sealing rides this transport: keyed sessions seal at upload and declare
/// (`encrypted` / `mimeType` / `iv`), sealed downloads open through the
/// custody cache's active workspace key.
class AssetRepository {
  AssetRepository({required this.dio});

  final Dio dio;

  /// Uploads [file] to CAS. When [existingNodeUuid] or [parentUuid] is
  /// given, the upload is attached to that object server-side (the
  /// `objectId` multipart field); both spell "attach to this node" — the
  /// block itself is created by the node-creation path, not the upload.
  ///
  /// When the custody cache holds the active workspace's key, the bytes are
  /// sealed first (fresh IV, blob = tag‖ct) and the upload declares itself
  /// so the server stores the declared type instead of magic-byte sniffing.
  /// Keyless sessions keep the plaintext path (`iv NULL`, sniffed
  /// server-side).
  Future<Asset> uploadFile(
    File file, {
    String? parentUuid,
    String? existingNodeUuid,
  }) async {
    final objectId = existingNodeUuid ?? parentUuid;
    final fields = <String, dynamic>{
      if (objectId != null) 'objectId': objectId,
    };
    final key = activeWorkspaceKey;
    late final MultipartFile part;
    if (key == null) {
      part = await MultipartFile.fromFile(file.path);
    } else {
      final plain = await file.readAsBytes();
      final sealed = await encryptAssetBytes(key, plain);
      final mime = LocalAssetService.mimeTypeForPath(file.path);
      fields['encrypted'] = '1';
      fields['mimeType'] = mime;
      fields['iv'] = b64uEncode(sealed.iv);
      part = MultipartFile.fromBytes(
        sealed.blob,
        filename: p.basename(file.path),
        contentType: DioMediaType.parse(mime),
      );
    }
    final formData = FormData.fromMap(<String, dynamic>{'file': part, ...fields});
    final response = await dio.post<Map<String, dynamic>>(
      '/api/assets',
      data: formData,
    );
    return Asset.fromJson(response.data!);
  }

  /// Downloads the bytes of asset [assetId]. The IV resolves from [iv] (when
  /// the caller already fetched /info), then the `x-notees-asset-iv`
  /// response header the sealed download rides, then a /info fallback
  /// (hash-addressed downloads carry no header). A resolved IV opens the
  /// bytes through the custody cache's active workspace key; a sealed asset
  /// without a key throws [StateError] and a wrong-key/tampered blob lets
  /// the GCM authenticity error propagate — both land in the caller's
  /// existing error UI, never a corrupted render.
  Future<Uint8List> downloadBytes(String assetId, {String? iv}) async {
    final response = await dio.get<List<int>>(
      assetUrl(assetId),
      options: Options(responseType: ResponseType.bytes),
    );
    final bytes = Uint8List.fromList(response.data!);
    var resolvedIv = iv ?? response.headers.value('x-notees-asset-iv');
    resolvedIv ??= await fetchAssetIv(assetId);
    if (resolvedIv == null) return bytes;
    final key = activeWorkspaceKey;
    if (key == null) {
      throw StateError(
        'asset is encrypted; unlock the workspace (password sign-in) to view it',
      );
    }
    return decryptAssetBytes(
      key,
      Uint8List.fromList(b64uDecode(resolvedIv)),
      bytes,
    );
  }

  /// The asset's `iv` metadata (null = plaintext), or null when /info does
  /// not resolve (e.g. a hash-addressed download whose row is gone).
  Future<String?> fetchAssetIv(String assetId) async {
    try {
      final response =
          await dio.get<Map<String, dynamic>>('${assetUrl(assetId)}/info');
      return response.data?['iv'] as String?;
    } on DioException catch (error) {
      if (error.response?.statusCode == 404) return null;
      rethrow;
    }
  }

  /// The workspace asset index, newest first (server default limit 100).
  Future<List<Asset>> fetchAssets({int limit = 100}) async {
    final response = await dio.get<Map<String, dynamic>>(
      '/api/assets',
      queryParameters: {'limit': limit},
    );
    final data = response.data;
    if (data == null) return [];
    final items = (data['assets'] ?? data['items']) as List<dynamic>? ?? [];
    return items.map((e) => Asset.fromJson(e as Map<String, dynamic>)).toList();
  }

  /// The asset's metadata (`GET /api/assets/:id/info`), incl. `iv`.
  Future<Asset> fetchAssetInfo(String assetId) async {
    final response =
        await dio.get<Map<String, dynamic>>('${assetUrl(assetId)}/info');
    return Asset.fromJson(response.data!);
  }

  String assetUrl(String assetId) => '/api/assets/$assetId';
}
