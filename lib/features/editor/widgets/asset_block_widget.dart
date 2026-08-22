import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:material_design_icons_flutter/material_design_icons_flutter.dart';
import 'package:path_provider/path_provider.dart';
import 'package:url_launcher/url_launcher.dart';

import '../../../data/repositories/asset_repository.dart';
import '../../../domain/services/local_asset_store.dart';

/// Renders an asset block inside the native editor.
///
/// Assets captured in local (serverless) mode are stored on-device in the
/// [LocalAssetStore] keyed by content hash and rendered from disk. Otherwise
/// images are downloaded through the authenticated Dio client and shown from
/// memory, audio files are downloaded to a temporary file and opened with the
/// system player, and other files show a generic tile.
class AssetBlockWidget extends StatefulWidget {
  const AssetBlockWidget({
    super.key,
    required this.dio,
    required this.uuid,
    this.filename,
  });

  final Dio dio;
  final String uuid;
  final String? filename;

  @override
  State<AssetBlockWidget> createState() => _AssetBlockWidgetState();
}

class _AssetBlockWidgetState extends State<AssetBlockWidget> {
  Asset? _asset;
  Uint8List? _imageBytes;
  String? _audioPath;
  String? _localFilePath;
  bool _loading = true;
  String? _error;

  @override
  void initState() {
    super.initState();
    _loadAsset();
  }

  Future<void> _loadAsset() async {
    try {
      // Local-first: blobs captured in local mode live in the on-device asset
      // store keyed by content hash; when a copy exists, render it from disk
      // instead of hitting the server URL.
      final store = LocalAssetStore();
      final local = await store.readMetadata(widget.uuid);
      final localFile =
          local == null ? null : await store.blobFile(local.assetHash);
      if (local != null && localFile != null) {
        _localFilePath = localFile.path;
        if (local.category == 'image') {
          _imageBytes = await localFile.readAsBytes();
        } else if (local.category == 'audio') {
          _audioPath = localFile.path;
        }
        if (!mounted) return;
        setState(() {
          _asset = Asset(
            uuid: widget.uuid,
            nodeUuid: widget.uuid,
            filename: local.originalName,
            contentType: local.mimeType,
            category: local.category,
            sizeBytes: local.sizeBytes,
            url: localFile.path,
          );
          _loading = false;
        });
        return;
      }

      final repo = AssetRepository(dio: widget.dio);
      final info = await repo.fetchAssetInfo(widget.uuid);
      final url = '${widget.dio.options.baseUrl}${repo.assetUrl(widget.uuid)}';

      if (info.category == 'image') {
        final response = await widget.dio.get<List<int>>(
          url,
          options: Options(responseType: ResponseType.bytes),
        );
        _imageBytes = Uint8List.fromList(response.data!);
      } else if (info.category == 'audio') {
        final tempDir = await getTemporaryDirectory();
        final name = info.filename;
        final ext = name.contains('.') ? name.split('.').last : 'm4a';
        final path = '${tempDir.path}/notees_asset_${widget.uuid}.$ext';
        await widget.dio.download(url, path);
        _audioPath = path;
      }

      if (!mounted) return;
      setState(() {
        _asset = info;
        _loading = false;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _error = e.toString();
        _loading = false;
      });
    }
  }

  Future<void> _playAudio() async {
    final path = _audioPath;
    if (path == null) return;
    final uri = Uri.file(path);
    if (await canLaunchUrl(uri)) {
      await launchUrl(uri, mode: LaunchMode.externalApplication);
    }
  }

  Future<void> _openFile() async {
    final localPath = _localFilePath;
    final Uri uri;
    if (localPath != null) {
      uri = Uri.file(localPath);
    } else {
      final repo = AssetRepository(dio: widget.dio);
      final url = '${widget.dio.options.baseUrl}${repo.assetUrl(widget.uuid)}';
      uri = Uri.parse(url);
    }
    if (await canLaunchUrl(uri)) {
      await launchUrl(uri, mode: LaunchMode.externalApplication);
    }
  }

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;

    if (_loading) {
      return const Padding(
        padding: EdgeInsets.symmetric(vertical: 12),
        child: Center(
          child: SizedBox(
            width: 20,
            height: 20,
            child: CircularProgressIndicator(strokeWidth: 2),
          ),
        ),
      );
    }

    if (_error != null) {
      return Padding(
        padding: const EdgeInsets.symmetric(vertical: 8),
        child: Text(
          'Could not load asset: $_error',
          style: TextStyle(color: colors.error),
        ),
      );
    }

    final name = widget.filename ?? _asset?.filename ?? 'Asset';

    if (_imageBytes != null) {
      return Padding(
        padding: const EdgeInsets.symmetric(vertical: 8),
        child: ClipRRect(
          borderRadius: BorderRadius.circular(12),
          child: Image.memory(
            _imageBytes!,
            fit: BoxFit.cover,
            width: double.infinity,
          ),
        ),
      );
    }

    if (_audioPath != null) {
      return ListTile(
        contentPadding: EdgeInsets.zero,
        leading: Icon(MdiIcons.musicNote, color: colors.primary),
        title: Text(
          name,
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
        ),
        subtitle: const Text('Audio recording'),
        trailing: IconButton(
          icon: Icon(MdiIcons.playCircle),
          tooltip: 'Play audio',
          onPressed: _playAudio,
        ),
      );
    }

    return ListTile(
      contentPadding: EdgeInsets.zero,
      leading: Icon(MdiIcons.fileDocument, color: colors.onSurfaceVariant),
      title: Text(
        name,
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
      ),
      trailing: IconButton(
        icon: Icon(MdiIcons.openInNew),
        tooltip: 'Open file',
        onPressed: _openFile,
      ),
    );
  }
}
