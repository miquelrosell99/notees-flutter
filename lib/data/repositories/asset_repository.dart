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

class Asset {
  Asset({
    required this.uuid,
    required this.nodeUuid,
    required this.filename,
    required this.contentType,
    required this.category,
    required this.sizeBytes,
    required this.url,
    this.iv,
  });

  final String uuid;
  final String nodeUuid;
  final String filename;
  final String contentType;
  final String category;
  final int sizeBytes;
  final String url;

  /// Server-side E2EE metadata (plan 05): b64u of the 12-byte GCM nonce for
  /// sealed bytes (blob layout `tag‖ct`, see asset_crypto.dart). Null means
  /// the asset is plaintext and every path behaves as before.
  final String? iv;

  factory Asset.fromJson(Map<String, dynamic> json) => Asset(
        uuid: json['uuid'] as String,
        nodeUuid: json['node_uuid'] as String? ?? json['node_id'].toString(),
        filename: json['filename'] as String,
        contentType: json['content_type'] as String,
        category: json['category'] as String,
        sizeBytes: json['size_bytes'] as int,
        url: json['url'] as String,
        iv: json['iv'] as String?,
      );
}

class AssetRepository {
  AssetRepository({required this.dio});

  final Dio dio;

  /// Uploads [file] as an asset block. When the custody cache holds the
  /// active workspace's key, the bytes are sealed first (fresh IV, blob =
  /// tag‖ct) and the upload declares itself (`encrypted`, declared
  /// `mimeType`, `iv`) so the server stores the declared type instead of
  /// magic-byte sniffing (plan 05). Keyless sessions keep the historical
  /// plaintext path (`iv NULL`, sniffed server-side).
  Future<Asset> uploadFile(
    File file, {
    String? parentUuid,
    String? existingNodeUuid,
    String? content,
  }) async {
    final fields = <String, dynamic>{
      if (parentUuid != null) 'parent_uuid': parentUuid,
      if (existingNodeUuid != null) 'existing_node_uuid': existingNodeUuid,
      if (content != null) 'content': content,
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
      '/assets/upload',
      data: formData,
    );
    return Asset.fromJson(response.data!);
  }

  /// Downloads the bytes of asset [uuid]. When the asset is sealed (its info
  /// carries [iv]) the bytes are opened with the custody cache's active
  /// workspace key; a sealed asset without a key throws [StateError] and a
  /// wrong-key/tampered blob lets the GCM authenticity error propagate —
  /// both land in the caller's existing error UI, never a corrupted render.
  Future<Uint8List> downloadBytes(String uuid, {required String? iv}) async {
    final response = await dio.get<List<int>>(
      assetUrl(uuid),
      options: Options(responseType: ResponseType.bytes),
    );
    final bytes = Uint8List.fromList(response.data!);
    if (iv == null) return bytes;
    final key = activeWorkspaceKey;
    if (key == null) {
      throw StateError(
        'asset is encrypted; unlock the workspace (password sign-in) to view it',
      );
    }
    return decryptAssetBytes(key, Uint8List.fromList(b64uDecode(iv)), bytes);
  }

  Future<List<Asset>> fetchAssets({int page = 1, int pageSize = 50}) async {
    final response = await dio.get<Map<String, dynamic>>(
      '/assets/',
      queryParameters: {'page': page, 'page_size': pageSize},
    );
    final data = response.data;
    if (data == null) return [];
    final items = (data['assets'] ?? data['items']) as List<dynamic>? ?? [];
    return items.map((e) => Asset.fromJson(e as Map<String, dynamic>)).toList();
  }

  Future<Asset> fetchAssetInfo(String uuid) async {
    final response = await dio.get<Map<String, dynamic>>('/assets/$uuid/info');
    return Asset.fromJson(response.data!);
  }

  String assetUrl(String uuid) => '/assets/$uuid';

  Future<void> deleteAsset(String uuid) async {
    await dio.delete('/assets/$uuid');
  }
}
