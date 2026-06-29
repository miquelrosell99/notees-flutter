import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:image_picker/image_picker.dart';
import 'package:provider/provider.dart';

import '../../core/constants/system.dart';
import '../../core/utils/color_presets.dart';
import '../../data/repositories/asset_repository.dart';
import '../../data/repositories/node_repository.dart';
import '../../domain/services/quick_capture.dart';
import '../providers/auth_provider.dart';
import '../providers/connectivity_provider.dart';
import '../providers/settings_provider.dart';
import 'audio_recorder_sheet.dart';

/// Bottom sheet for creating a quick note. Saves immediately if online, or
/// queues for sync if offline.
class QuickCaptureSheet extends StatefulWidget {
  const QuickCaptureSheet({
    super.key,
    this.initialText = '',
    this.onSaved,
  });

  final String initialText;
  final VoidCallback? onSaved;

  @override
  State<QuickCaptureSheet> createState() => _QuickCaptureSheetState();
}

class _QuickCaptureSheetState extends State<QuickCaptureSheet> {
  late final TextEditingController _controller;
  String _selectedColor = ColorPresets.defaultHex;
  bool _isSaving = false;

  @override
  void initState() {
    super.initState();
    _controller = TextEditingController(text: widget.initialText);
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  Future<void> _save(AuthProvider auth) async {
    final text = _controller.text.trim();
    if (text.isEmpty) return;
    HapticFeedback.lightImpact();
    if (auth.dio != null) {
      final settings = context.read<SettingsProvider>();
      final destination = settings.quickCaptureDestination;
      final parentUuid = await _resolveParentUuid(auth, destination);
      await QuickCaptureService(
        dio: auth.dio!,
        syncService: auth.syncService,
      ).save(
        text,
        color: _selectedColor,
        parentUuid: parentUuid,
      );
    }
    if (mounted) {
      Navigator.of(context).pop();
      widget.onSaved?.call();
    }
  }

  Future<String?> _resolveParentUuid(
    AuthProvider auth,
    QuickCaptureDestination destination,
  ) async {
    if (auth.dio == null) return null;
    final repo = NodeRepository(dio: auth.dio!, syncService: auth.syncService);
    return resolveQuickCaptureParentUuid(
      repository: repo,
      destination: destination,
    );
  }

  Future<void> _capturePhoto(AuthProvider auth, ImageSource source) async {
    if (auth.dio == null) return;

    final picker = ImagePicker();
    final image = await picker.pickImage(source: source);
    if (image == null) return;

    setState(() => _isSaving = true);
    try {
      final text = _controller.text.trim();
      final noteName = text.isEmpty ? 'Photo note' : text;

      final repo = NodeRepository(dio: auth.dio!, syncService: auth.syncService);
      final block = await repo.createInboxBlock(
        name: noteName,
        color: _selectedColor,
      );

      await AssetRepository(dio: auth.dio!).uploadFile(
        File(image.path),
        parentUuid: block.uuid,
      );

      if (mounted) {
        Navigator.of(context).pop();
        widget.onSaved?.call();
      }
    } catch (e) {
      if (mounted) {
        setState(() => _isSaving = false);
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Photo note failed: $e')),
        );
      }
    }
  }

  Future<void> _recordAudio(AuthProvider auth) async {
    if (auth.dio == null) return;
    final settings = context.read<SettingsProvider>();
    final destination = settings.quickCaptureDestination;

    final file = await showModalBottomSheet<File>(
      context: context,
      isScrollControlled: true,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(28)),
      ),
      builder: (ctx) => const AudioRecorderSheet(),
    );
    if (file == null || !mounted) return;

    try {
      final parentUuid = await _resolveParentUuid(auth, destination);
      if (!mounted) return;
      await QuickCaptureService(
        dio: auth.dio!,
        syncService: auth.syncService,
      ).uploadAsset(file, parentUuid: parentUuid ?? SystemPageUuids.inbox);
      if (mounted) {
        Navigator.of(context).pop();
        widget.onSaved?.call();
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Audio upload failed: $e')),
        );
      }
    }
  }

  void _showImageSourcePicker(AuthProvider auth) {
    HapticFeedback.lightImpact();
    showModalBottomSheet(
      context: context,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(28)),
      ),
      builder: (ctx) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            ListTile(
              leading: const Icon(Icons.camera_alt_outlined),
              title: const Text('Take a photo'),
              onTap: () {
                Navigator.of(ctx).pop();
                _capturePhoto(auth, ImageSource.camera);
              },
            ),
            ListTile(
              leading: const Icon(Icons.photo_library_outlined),
              title: const Text('Choose from gallery'),
              onTap: () {
                Navigator.of(ctx).pop();
                _capturePhoto(auth, ImageSource.gallery);
              },
            ),
          ],
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final auth = context.read<AuthProvider>();
    final isOnline = context.watch<ConnectivityProvider>().online;

    return Padding(
      padding: EdgeInsets.only(
        bottom: MediaQuery.of(context).viewInsets.bottom,
        left: 20,
        right: 20,
        top: 20,
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Center(
            child: Container(
              width: 32,
              height: 4,
              margin: const EdgeInsets.only(bottom: 16),
              decoration: BoxDecoration(
                borderRadius: BorderRadius.circular(2),
                color: Theme.of(context).colorScheme.onSurfaceVariant.withAlpha((0.35 * 255).round()),
              ),
            ),
          ),
          Text('Quick note', style: Theme.of(context).textTheme.titleLarge),
          const SizedBox(height: 4),
          Consumer<SettingsProvider>(
            builder: (context, settings, _) => Text(
              'Saved to ${quickCaptureDestinationLabel(settings.quickCaptureDestination)}',
              style: Theme.of(context).textTheme.bodySmall?.copyWith(
                    color: Theme.of(context).colorScheme.onSurfaceVariant,
                  ),
            ),
          ),
          const SizedBox(height: 16),
          TextField(
            controller: _controller,
            autofocus: true,
            textInputAction: TextInputAction.done,
            maxLines: 4,
            minLines: 1,
            decoration: const InputDecoration(hintText: 'What is on your mind?'),
            onSubmitted: (_) => _save(auth),
          ),
          const SizedBox(height: 12),
          _ColorPicker(
            selectedColor: _selectedColor,
            onColorSelected: (color) => setState(() => _selectedColor = color),
          ),
          const SizedBox(height: 8),
          if (!isOnline)
            Text(
              'You are offline. This note will be saved when you reconnect.',
              style: Theme.of(context).textTheme.bodySmall?.copyWith(
                    color: Theme.of(context).colorScheme.onSurfaceVariant,
                  ),
            ),
          const SizedBox(height: 20),
          if (_isSaving)
            const Center(child: CircularProgressIndicator())
          else
            Row(
              children: [
                Expanded(
                  child: FilledButton.icon(
                    onPressed: () => _save(auth),
                    icon: const Icon(Icons.save_outlined),
                    label: const Text('Save'),
                  ),
                ),
                const SizedBox(width: 12),
                IconButton.filledTonal(
                  onPressed: isOnline ? () => _showImageSourcePicker(auth) : null,
                  icon: const Icon(Icons.camera_alt_outlined),
                  tooltip: 'Add photo',
                ),
                const SizedBox(width: 12),
                IconButton.filledTonal(
                  onPressed: () => _recordAudio(auth),
                  icon: const Icon(Icons.mic),
                  tooltip: 'Record audio note',
                ),
              ],
            ),
          const SizedBox(height: 24),
        ],
      ),
    );
  }
}

class _ColorPicker extends StatelessWidget {
  const _ColorPicker({
    required this.selectedColor,
    required this.onColorSelected,
  });

  final String selectedColor;
  final ValueChanged<String> onColorSelected;

  @override
  Widget build(BuildContext context) {
    return SingleChildScrollView(
      scrollDirection: Axis.horizontal,
      child: Row(
        children: [
          _ColorButton(
            color: ColorPresets.fromHex(ColorPresets.defaultHex),
            label: 'Default',
            isSelected: selectedColor == ColorPresets.defaultHex,
            onTap: () => onColorSelected(ColorPresets.defaultHex),
          ),
          ...ColorPresets.entries.map((entry) {
            final (hex, label) = entry;
            return _ColorButton(
              color: ColorPresets.fromHex(hex),
              label: label,
              isSelected: selectedColor == hex,
              onTap: () => onColorSelected(hex),
            );
          }),
        ],
      ),
    );
  }
}

class _ColorButton extends StatelessWidget {
  const _ColorButton({
    required this.color,
    required this.label,
    required this.isSelected,
    required this.onTap,
  });

  final Color color;
  final String label;
  final bool isSelected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(right: 10),
      child: Tooltip(
        message: label,
        child: ConstrainedBox(
          constraints: const BoxConstraints(minWidth: 48, minHeight: 48),
          child: InkWell(
            onTap: () {
              HapticFeedback.lightImpact();
              onTap();
            },
            borderRadius: BorderRadius.circular(18),
            child: Center(
              child: Container(
                width: 32,
                height: 32,
                decoration: BoxDecoration(
                  color: color,
                  shape: BoxShape.circle,
                  border: Border.all(
                    color: isSelected
                        ? Theme.of(context).colorScheme.primary
                        : Theme.of(context).colorScheme.outline.withAlpha((0.2 * 255).round()),
                    width: isSelected ? 3 : 1,
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}
