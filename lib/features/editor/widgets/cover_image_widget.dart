import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:flutter/material.dart';

import '../../../data/repositories/asset_repository.dart';
import '../../../domain/services/local_asset_store.dart';

/// Cover thumbnail shown at the top right of the page header, resolved from
/// the page's `cover` system property (an asset node uuid). Mirrors the web
/// client's CoverImage element in NodeView.
///
/// Resolution follows the same local-first path as [AssetBlockWidget]: blobs
/// captured in local mode are read from the on-device [LocalAssetStore];
/// otherwise the image is downloaded through the authenticated Dio client.
/// Non-image assets and resolution failures render nothing (no broken-image
/// icon) because covers are purely decorative.
class CoverImageWidget extends StatefulWidget {
  const CoverImageWidget({
    super.key,
    required this.dio,
    required this.assetUuid,
    this.width = 160,
    this.height = 108,
  });

  final Dio dio;
  final String assetUuid;
  final double width;
  final double height;

  @override
  State<CoverImageWidget> createState() => _CoverImageWidgetState();
}

class _CoverImageWidgetState extends State<CoverImageWidget> {
  Uint8List? _imageBytes;
  bool _loading = true;

  @override
  void initState() {
    super.initState();
    _loadImage();
  }

  @override
  void didUpdateWidget(CoverImageWidget oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.assetUuid != widget.assetUuid) {
      _loadImage();
    }
  }

  Future<void> _loadImage() async {
    // Callers (initState / didUpdateWidget) are always followed by a build,
    // so the reset needs no setState.
    _imageBytes = null;
    _loading = true;
    try {
      // Local-first: blobs captured in local mode live in the on-device asset
      // store keyed by content hash.
      final store = LocalAssetStore();
      final local = await store.readMetadata(widget.assetUuid);
      if (local != null && local.category == 'image') {
        final bytes = await store.readBytes(local.assetHash);
        if (!mounted) return;
        setState(() {
          _imageBytes = bytes;
          _loading = false;
        });
        return;
      }

      final repo = AssetRepository(dio: widget.dio);
      final info = await repo.fetchAssetInfo(widget.assetUuid);
      if (info.category != 'image') {
        if (!mounted) return;
        setState(() => _loading = false);
        return;
      }
      final url =
          '${widget.dio.options.baseUrl}${repo.assetUrl(widget.assetUuid)}';
      final response = await widget.dio.get<List<int>>(
        url,
        options: Options(responseType: ResponseType.bytes),
      );
      if (!mounted) return;
      setState(() {
        _imageBytes = Uint8List.fromList(response.data!);
        _loading = false;
      });
    } catch (_) {
      if (!mounted) return;
      setState(() {
        _imageBytes = null;
        _loading = false;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final bytes = _imageBytes;
    if (_loading || bytes == null) return const SizedBox.shrink();
    final colors = Theme.of(context).colorScheme;
    // Zero-elevation card styling: 20px radius with a subtle outline.
    return Container(
      width: widget.width,
      height: widget.height,
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(20),
        border: Border.all(
          color: colors.outline.withAlpha((0.10 * 255).round()),
        ),
      ),
      child: ClipRRect(
        borderRadius: BorderRadius.circular(20),
        child: Image.memory(bytes, fit: BoxFit.cover),
      ),
    );
  }
}
