import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:image_picker/image_picker.dart';
import 'package:material_design_icons_flutter/material_design_icons_flutter.dart';
import 'package:provider/provider.dart';

import '../../core/constants/capture_types.dart';
import '../../core/constants/system.dart';
import '../../core/utils/color_presets.dart';
import '../../data/repositories/asset_repository.dart';
import '../../data/repositories/node_repository.dart';
import '../../domain/services/quick_capture.dart';
import '../providers/auth_provider.dart';
import '../providers/connectivity_provider.dart';
import '../providers/settings_provider.dart';
import 'audio_recorder_sheet.dart';
import 'node_picker.dart';

enum _CaptureType {
  note,
  task,
  voice,
  photo,
  journal,
}

/// Bottom sheet for creating a quick note, task, journal entry, voice memo, or
/// photo. Saves immediately if online, or queues for sync if offline.
class QuickCaptureSheet extends StatefulWidget {
  const QuickCaptureSheet({
    super.key,
    this.initialText = '',
    this.imagePath,
    this.initialType = QuickCaptureType.note,
    this.onSaved,
  });

  final String initialText;
  final String? imagePath;
  final QuickCaptureType initialType;
  final VoidCallback? onSaved;

  @override
  State<QuickCaptureSheet> createState() => _QuickCaptureSheetState();
}

class _QuickCaptureSheetState extends State<QuickCaptureSheet> {
  late final TextEditingController _controller;
  _CaptureType _type = _CaptureType.note;
  String _selectedColor = ColorPresets.defaultHex;
  bool _isSaving = false;
  File? _imageFile;

  @override
  void initState() {
    super.initState();
    _controller = TextEditingController(text: widget.initialText);
    _type = _mapCaptureType(widget.initialType);
    if (widget.imagePath != null && widget.imagePath!.isNotEmpty) {
      _imageFile = File(widget.imagePath!);
      _type = _CaptureType.photo;
    }
  }

  _CaptureType _mapCaptureType(QuickCaptureType type) {
    return switch (type) {
      QuickCaptureType.note => _CaptureType.note,
      QuickCaptureType.task => _CaptureType.task,
      QuickCaptureType.voice => _CaptureType.voice,
      QuickCaptureType.photo => _CaptureType.photo,
      QuickCaptureType.journal => _CaptureType.journal,
    };
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  Future<void> _saveNote(AuthProvider auth) async {
    final text = _controller.text.trim();
    if (text.isEmpty) return;
    HapticFeedback.lightImpact();
    if (auth.dio != null) {
      final settings = context.read<SettingsProvider>();
      final destination = settings.quickCaptureDestination;
      final parentUuid = await _resolveParentUuid(auth, destination);
      if (!mounted) return;
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

  Future<void> _saveTask(AuthProvider auth) async {
    final text = _controller.text.trim();
    if (text.isEmpty) return;
    HapticFeedback.lightImpact();
    if (auth.dio != null) {
      final settings = context.read<SettingsProvider>();
      final destination = settings.quickCaptureDestination;
      final parentUuid = await _resolveParentUuid(auth, destination);
      if (!mounted) return;
      await QuickCaptureService(
        dio: auth.dio!,
        syncService: auth.syncService,
      ).save(
        text,
        isTask: true,
        color: _selectedColor,
        parentUuid: parentUuid,
      );
    }
    if (mounted) {
      Navigator.of(context).pop();
      widget.onSaved?.call();
    }
  }

  Future<void> _saveJournal(AuthProvider auth) async {
    final text = _controller.text.trim();
    if (text.isEmpty || auth.dio == null) return;
    HapticFeedback.lightImpact();

    setState(() => _isSaving = true);
    try {
      final repo = NodeRepository(dio: auth.dio!, syncService: auth.syncService);
      final journal = await repo.getOrCreateDailyJournal(DateTime.now());
      if (!mounted) return;
      await QuickCaptureService(
        dio: auth.dio!,
        syncService: auth.syncService,
      ).save(
        text,
        color: _selectedColor,
        parentUuid: journal.uuid,
      );
      if (mounted) {
        Navigator.of(context).pop();
        widget.onSaved?.call();
      }
    } catch (e) {
      if (mounted) {
        setState(() => _isSaving = false);
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Journal entry failed: $e')),
        );
      }
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
    if (image == null || !mounted) return;

    setState(() {
      _isSaving = true;
      _imageFile = File(image.path);
    });

    try {
      final text = _controller.text.trim();
      final noteName = text.isEmpty ? 'Photo note' : text;

      final repo = NodeRepository(dio: auth.dio!, syncService: auth.syncService);
      final block = await repo.createInboxBlock(
        name: noteName,
        color: _selectedColor,
      );

      await AssetRepository(dio: auth.dio!).uploadFile(
        _imageFile!,
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

  Future<void> _saveSharedImageToInbox(AuthProvider auth) async {
    if (auth.dio == null || _imageFile == null) return;
    setState(() => _isSaving = true);
    try {
      final settings = context.read<SettingsProvider>();
      final destination = settings.quickCaptureDestination;
      final parentUuid = await _resolveParentUuid(auth, destination);
      if (!mounted) return;
      await _uploadImageToParent(auth, parentUuid ?? SystemPageUuids.inbox);
    } catch (e) {
      if (mounted) {
        setState(() => _isSaving = false);
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Image save failed: $e')),
        );
      }
    }
  }

  Future<void> _saveSharedImageToJournal(AuthProvider auth) async {
    if (auth.dio == null || _imageFile == null) return;
    setState(() => _isSaving = true);
    try {
      final repo = NodeRepository(dio: auth.dio!, syncService: auth.syncService);
      final journal = await repo.getOrCreateDailyJournal(DateTime.now());
      if (!mounted) return;
      await _uploadImageToParent(auth, journal.uuid);
    } catch (e) {
      if (mounted) {
        setState(() => _isSaving = false);
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Image save failed: $e')),
        );
      }
    }
  }

  Future<void> _attachSharedImageToPage(AuthProvider auth) async {
    if (auth.dio == null || _imageFile == null) return;
    if (!mounted) return;
    final page = await NodePicker.show(context, mode: NodePickerMode.page);
    if (page == null || !mounted) return;

    setState(() => _isSaving = true);
    try {
      final text = _controller.text.trim();
      await AssetRepository(dio: auth.dio!).uploadFile(
        _imageFile!,
        existingNodeUuid: page.uuid,
        content: text.isEmpty ? null : text,
      );
      if (mounted) {
        Navigator.of(context).pop();
        widget.onSaved?.call();
      }
    } catch (e) {
      if (mounted) {
        setState(() => _isSaving = false);
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Attach failed: $e')),
        );
      }
    }
  }

  Future<void> _uploadImageToParent(AuthProvider auth, String parentUuid) async {
    final text = _controller.text.trim();
    final repo = NodeRepository(dio: auth.dio!, syncService: auth.syncService);
    final block = await repo.createInboxBlock(
      name: text.isEmpty ? 'Photo note' : text,
      color: _selectedColor,
      parentUuid: parentUuid,
    );
    await AssetRepository(dio: auth.dio!).uploadFile(
      _imageFile!,
      parentUuid: block.uuid,
    );
    if (mounted) {
      Navigator.of(context).pop();
      widget.onSaved?.call();
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
              leading: Icon(MdiIcons.cameraOutline),
              title: const Text('Take a photo'),
              onTap: () {
                Navigator.of(ctx).pop();
                _capturePhoto(auth, ImageSource.camera);
              },
            ),
            ListTile(
              leading: Icon(MdiIcons.imageMultipleOutline),
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

  void _onTypeChanged(_CaptureType type) {
    HapticFeedback.lightImpact();
    setState(() => _type = type);
  }

  Future<void> _onPrimaryAction(AuthProvider auth) async {
    switch (_type) {
      case _CaptureType.note:
        await _saveNote(auth);
      case _CaptureType.task:
        await _saveTask(auth);
      case _CaptureType.journal:
        await _saveJournal(auth);
      case _CaptureType.voice:
        await _recordAudio(auth);
      case _CaptureType.photo:
        _showImageSourcePicker(auth);
    }
  }

  String _typeLabel(_CaptureType type) {
    return switch (type) {
      _CaptureType.note => 'Note',
      _CaptureType.task => 'Task',
      _CaptureType.voice => 'Voice',
      _CaptureType.photo => 'Photo',
      _CaptureType.journal => 'Journal',
    };
  }

  IconData _typeIcon(_CaptureType type) {
    return switch (type) {
      _CaptureType.note => MdiIcons.noteTextOutline,
      _CaptureType.task => MdiIcons.checkCircleOutline,
      _CaptureType.voice => MdiIcons.microphone,
      _CaptureType.photo => MdiIcons.cameraOutline,
      _CaptureType.journal => MdiIcons.bookOpenOutline,
    };
  }

  @override
  Widget build(BuildContext context) {
    final auth = context.read<AuthProvider>();
    final isOnline = context.watch<ConnectivityProvider>().online;
    final showTextField = _type != _CaptureType.voice && _type != _CaptureType.photo;
    final title = switch (_type) {
      _CaptureType.note => 'Quick note',
      _CaptureType.task => 'Quick task',
      _CaptureType.voice => 'Voice memo',
      _CaptureType.photo => 'Photo note',
      _CaptureType.journal => 'Journal entry',
    };

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
          SingleChildScrollView(
            scrollDirection: Axis.horizontal,
            child: Row(
              children: _CaptureType.values.map((type) {
                final selected = _type == type;
                return Padding(
                  padding: const EdgeInsets.only(right: 8),
                  child: ChoiceChip(
                    label: Text(_typeLabel(type)),
                    avatar: Icon(_typeIcon(type), size: 18),
                    selected: selected,
                    onSelected: (_) => _onTypeChanged(type),
                  ),
                );
              }).toList(),
            ),
          ),
          const SizedBox(height: 16),
          Text(title, style: Theme.of(context).textTheme.titleLarge),
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
          if (showTextField)
            TextField(
              controller: _controller,
              autofocus: true,
              textInputAction: TextInputAction.done,
              maxLines: 4,
              minLines: 1,
              decoration: const InputDecoration(hintText: 'What is on your mind?'),
              onSubmitted: (_) => _onPrimaryAction(auth),
            )
          else if (_imageFile != null)
            ClipRRect(
              borderRadius: BorderRadius.circular(20),
              child: Image.file(
                _imageFile!,
                height: 240,
                width: double.infinity,
                fit: BoxFit.cover,
              ),
            )
          else
            Container(
              height: 120,
              decoration: BoxDecoration(
                borderRadius: BorderRadius.circular(20),
                color: Theme.of(context).colorScheme.surfaceContainerHighest,
              ),
              child: Center(
                child: Icon(
                  _type == _CaptureType.photo ? MdiIcons.imageOutline : MdiIcons.microphone,
                  size: 48,
                  color: Theme.of(context).colorScheme.onSurfaceVariant,
                ),
              ),
            ),
          const SizedBox(height: 12),
          if (_type == _CaptureType.note || _type == _CaptureType.task)
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
          else if (_imageFile != null)
            Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                FilledButton.icon(
                  onPressed: isOnline ? () => _saveSharedImageToInbox(auth) : null,
                  icon: Icon(MdiIcons.inboxArrowDownOutline),
                  label: const Text('Save to Inbox'),
                ),
                const SizedBox(height: 8),
                FilledButton.icon(
                  onPressed: isOnline ? () => _saveSharedImageToJournal(auth) : null,
                  icon: Icon(MdiIcons.bookOpenOutline),
                  label: const Text("Save to today's journal"),
                ),
                const SizedBox(height: 8),
                FilledButton.icon(
                  onPressed: isOnline ? () => _attachSharedImageToPage(auth) : null,
                  icon: Icon(MdiIcons.fileDocumentOutline),
                  label: const Text('Attach to page'),
                ),
              ],
            )
          else
            Row(
              children: [
                Expanded(
                  child: FilledButton.icon(
                    onPressed: () => _onPrimaryAction(auth),
                    icon: Icon(_typeIcon(_type)),
                    label: Text(_primaryLabel(_type)),
                  ),
                ),
                if (_type == _CaptureType.note || _type == _CaptureType.task) ...[
                  const SizedBox(width: 12),
                  IconButton.filledTonal(
                    onPressed: isOnline ? () => _showImageSourcePicker(auth) : null,
                    icon: Icon(MdiIcons.cameraOutline),
                    tooltip: 'Add photo',
                  ),
                  const SizedBox(width: 12),
                  IconButton.filledTonal(
                    onPressed: () => _recordAudio(auth),
                    icon: Icon(MdiIcons.microphone),
                    tooltip: 'Record audio note',
                  ),
                ],
              ],
            ),
          const SizedBox(height: 24),
        ],
      ),
    );
  }

  String _primaryLabel(_CaptureType type) {
    return switch (type) {
      _CaptureType.note => 'Save',
      _CaptureType.task => 'Add task',
      _CaptureType.voice => 'Record',
      _CaptureType.photo => 'Choose photo',
      _CaptureType.journal => 'Add to journal',
    };
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
