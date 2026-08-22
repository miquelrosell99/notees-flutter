import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:cryptography/cryptography.dart';
import 'package:dio/dio.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

import '../../core/constants/system.dart';
import '../../core/utils/ast_builder.dart';
import '../../core/utils/uuid7.dart';
import '../models/relay/operation_payloads.dart';
import './sync_v2_service.dart';

/// Metadata sidecar for a locally stored asset, mirroring the server's
/// `node_asset` row. The Flutter applier intentionally ignores `asset.upload`
/// (no local asset table), so local-mode rendering and the server-attach
/// upload read this sidecar instead.
class LocalAssetInfo {
  const LocalAssetInfo({
    required this.nodeId,
    required this.assetHash,
    required this.mimeType,
    required this.sizeBytes,
    required this.originalName,
  });

  final String nodeId;
  final String assetHash;
  final String mimeType;
  final int sizeBytes;
  final String originalName;

  /// Mirrors the server's asset categories (`image/`, `audio/`, else file).
  String get category {
    if (mimeType.startsWith('image/')) return 'image';
    if (mimeType.startsWith('audio/')) return 'audio';
    return 'file';
  }

  Map<String, dynamic> toJson() => {
        'nodeId': nodeId,
        'assetHash': assetHash,
        'mimeType': mimeType,
        'sizeBytes': sizeBytes,
        'originalName': originalName,
      };

  factory LocalAssetInfo.fromJson(Map<String, dynamic> json) => LocalAssetInfo(
        nodeId: json['nodeId'] as String,
        assetHash: json['assetHash'] as String,
        mimeType: json['mimeType'] as String,
        sizeBytes: json['sizeBytes'] as int,
        originalName: json['originalName'] as String,
      );
}

/// On-device asset blob store for local (serverless) mode, mirroring the web
/// client's `frontend/src/features/assets/api/localAssets.ts`.
///
/// Blobs are stored content-addressed by SHA-256 hex digest as files under
/// `asset_blobs/` in the app documents directory; per-node metadata lives in
/// `asset_blobs/meta/<nodeId>.json` sidecars. Because the operation log stays
/// the source of truth (see [LocalAssetService]), attaching a server later
/// replays the ops unchanged and only the blob bytes need uploading.
class LocalAssetStore {
  /// Test override; defaults to the app documents directory.
  LocalAssetStore({this._baseDirectory});

  final Directory? _baseDirectory;

  Future<Directory> _blobDir() async {
    final base = _baseDirectory ?? await getApplicationDocumentsDirectory();
    return Directory(p.join(base.path, 'asset_blobs')).create(recursive: true);
  }

  Future<Directory> _metaDir() async =>
      Directory(p.join((await _blobDir()).path, 'meta')).create(recursive: true);

  /// SHA-256 hex digest; matches the server's `hashlib.sha256().hexdigest()`.
  static Future<String> hashBytes(Uint8List bytes) async {
    final digest = await Sha256().hash(bytes);
    return digest.bytes
        .map((b) => b.toRadixString(16).padLeft(2, '0'))
        .join();
  }

  /// Stores [bytes] under their content hash and returns the hash.
  Future<String> putBytes(Uint8List bytes) async {
    final hash = await hashBytes(bytes);
    final file = File(p.join((await _blobDir()).path, hash));
    if (!file.existsSync()) {
      await file.writeAsBytes(bytes, flush: true);
    }
    return hash;
  }

  /// The blob file for [hash], or null when no local copy exists.
  Future<File?> blobFile(String hash) async {
    final file = File(p.join((await _blobDir()).path, hash));
    return file.existsSync() ? file : null;
  }

  Future<Uint8List?> readBytes(String hash) async {
    final file = await blobFile(hash);
    return file?.readAsBytes();
  }

  Future<void> deleteBlob(String hash) async {
    final file = await blobFile(hash);
    if (file != null) await file.delete();
  }

  Future<void> saveMetadata(LocalAssetInfo info) async {
    final file = File(p.join((await _metaDir()).path, '${info.nodeId}.json'));
    await file.writeAsString(jsonEncode(info.toJson()), flush: true);
  }

  /// Metadata for the asset node [nodeId], or null when it was not captured
  /// locally (e.g. a server-uploaded asset).
  Future<LocalAssetInfo?> readMetadata(String nodeId) async {
    final file = File(p.join((await _metaDir()).path, '$nodeId.json'));
    if (!file.existsSync()) return null;
    final json = jsonDecode(await file.readAsString()) as Map<String, dynamic>;
    return LocalAssetInfo.fromJson(json);
  }

  /// All locally captured asset metadata, used by the server-attach upload.
  Future<List<LocalAssetInfo>> listMetadata() async {
    final dir = await _metaDir();
    final assets = <LocalAssetInfo>[];
    await for (final entry in dir.list()) {
      if (entry is! File || !entry.path.endsWith('.json')) continue;
      try {
        final json =
            jsonDecode(await entry.readAsString()) as Map<String, dynamic>;
        assets.add(LocalAssetInfo.fromJson(json));
      } on FormatException {
        // Skip corrupt sidecars instead of failing the whole listing.
        continue;
      }
    }
    return assets;
  }
}

/// Local-mode asset operations: store bytes in the [LocalAssetStore], then
/// emit the exact operation sequence the server emits for an upload
/// (`node.create` for a new block, `class.assign` for a conversion, then
/// `asset.upload`) so a later server attach replays them unchanged.
class LocalAssetService {
  LocalAssetService(this._sync, {LocalAssetStore? store})
      : store = store ?? LocalAssetStore();

  final SyncV2Service _sync;
  final LocalAssetStore store;

  /// Uploads [file] as an asset in local mode and returns its metadata.
  Future<LocalAssetInfo> upload(
    File file, {
    String? parentUuid,
    String? existingNodeUuid,
    String? content,
    String? mimeType,
  }) async {
    final bytes = await file.readAsBytes();
    final originalName = p.basename(file.path);
    final mime = mimeType ?? mimeTypeForPath(file.path);
    final assetHash = await store.putBytes(bytes);
    final nodeId = existingNodeUuid ?? Uuid7.generate();
    final info = LocalAssetInfo(
      nodeId: nodeId,
      assetHash: assetHash,
      mimeType: mime,
      sizeBytes: bytes.length,
      originalName: originalName,
    );

    try {
      if (existingNodeUuid != null) {
        await _sync.emitLocal(
          opType: 'class.assign',
          payload: OperationPayloads.classAssign(
            nodeId: nodeId,
            classId: SystemClassUuids.asset,
          ),
          affectedNodeIds: [nodeId, SystemClassUuids.asset],
        );
      } else {
        await _sync.emitLocal(
          opType: 'node.create',
          payload: OperationPayloads.nodeCreate(
            nodeId: nodeId,
            kind: 'block',
            parentId: parentUuid,
            classIds: [SystemClassUuids.asset],
            initialContent: AstBuilder.parseInline(
              content ?? p.basenameWithoutExtension(originalName),
            ),
          ),
          affectedNodeIds: [nodeId],
        );
      }
      await _sync.emitLocal(
        opType: 'asset.upload',
        payload: <String, dynamic>{
          'assetId': nodeId,
          'nodeId': nodeId,
          'assetHash': assetHash,
          'mimeType': mime,
          'sizeBytes': bytes.length,
          'originalName': originalName,
        },
        affectedNodeIds: [nodeId],
      );
      await store.saveMetadata(info);
    } catch (_) {
      // Roll back the blob so no orphan bytes are left behind, mirroring the
      // server's `delete_asset` on failure and the web client's rollback.
      await store.deleteBlob(assetHash);
      rethrow;
    }
    return info;
  }

  /// Uploads the bytes of every locally stored asset to a freshly attached
  /// server, against the asset nodes the replayed ops created. Mirrors the
  /// web client's adoption step (`defaultUploadAssetBytes` in
  /// `frontend/src/core/adoption.ts`): one upload per distinct content hash,
  /// posted as multipart with `existing_node_uuid`. Returns per-asset errors;
  /// failures do not abort the remaining uploads.
  Future<List<String>> uploadPendingAssets(Dio dio) async {
    final errors = <String>[];
    final seenHashes = <String>{};
    for (final asset in await store.listMetadata()) {
      // Content-addressed: one upload per distinct hash is enough.
      if (!seenHashes.add(asset.assetHash)) continue;
      try {
        final bytes = await store.readBytes(asset.assetHash);
        if (bytes == null) {
          throw StateError('asset bytes missing locally (hash ${asset.assetHash})');
        }
        final formData = FormData.fromMap(<String, dynamic>{
          'file': MultipartFile.fromBytes(
            bytes,
            filename: asset.originalName,
            contentType: DioMediaType.parse(asset.mimeType),
          ),
        });
        // `existing_node_uuid` is a query parameter in the FastAPI signature
        // (only `content` is a Form field), so it cannot go in the form body.
        await dio.post<Map<String, dynamic>>(
          '/assets/upload',
          data: formData,
          queryParameters: {'existing_node_uuid': asset.nodeId},
        );
      } catch (e) {
        errors.add('${asset.nodeId}: $e');
      }
    }
    return errors;
  }

  /// Best-effort MIME type from the file extension; image_picker and the
  /// recorder do not always report one. Only the `image/`/`audio/` prefix
  /// matters for categorization.
  static String mimeTypeForPath(String path) {
    return switch (p.extension(path).toLowerCase()) {
      '.png' => 'image/png',
      '.jpg' || '.jpeg' => 'image/jpeg',
      '.gif' => 'image/gif',
      '.webp' => 'image/webp',
      '.heic' => 'image/heic',
      '.m4a' => 'audio/mp4',
      '.mp3' => 'audio/mpeg',
      '.wav' => 'audio/wav',
      '.ogg' => 'audio/ogg',
      '.aac' => 'audio/aac',
      _ => 'application/octet-stream',
    };
  }
}
