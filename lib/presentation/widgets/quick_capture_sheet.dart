import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';

import '../../data/repositories/asset_repository.dart';
import '../../data/repositories/node_repository.dart';
import '../../domain/services/quick_capture.dart';
import '../providers/auth_provider.dart';
import '../providers/connectivity_provider.dart';
import 'audio_recorder_sheet.dart';

/// Bottom sheet for creating a quick note. Saves immediately if online, or
/// queues for sync if offline.
class QuickCaptureSheet extends StatelessWidget {
  const QuickCaptureSheet({
    super.key,
    this.initialText = '',
    this.onSaved,
  });

  final String initialText;
  final VoidCallback? onSaved;

  @override
  Widget build(BuildContext context) {
    final controller = TextEditingController(text: initialText);
    final auth = context.read<AuthProvider>();
    final isOnline = context.watch<ConnectivityProvider>().online;

    Future<void> save() async {
      final text = controller.text.trim();
      if (text.isEmpty) return;
      HapticFeedback.lightImpact();
      if (auth.dio != null) {
        await QuickCaptureService(
          dio: auth.dio!,
          syncService: auth.syncService,
        ).save(text);
      }
      if (context.mounted) {
        Navigator.of(context).pop();
        onSaved?.call();
      }
    }

    Future<void> recordAudio() async {
      if (auth.dio == null) return;
      final file = await showModalBottomSheet<File>(
        context: context,
        isScrollControlled: true,
        shape: const RoundedRectangleBorder(
          borderRadius: BorderRadius.vertical(top: Radius.circular(28)),
        ),
        builder: (ctx) => const AudioRecorderSheet(),
      );
      if (file == null) return;

      try {
        final journal = await NodeRepository(dio: auth.dio!, syncService: auth.syncService).getOrCreateDailyJournal(DateTime.now());
        await AssetRepository(dio: auth.dio!).uploadFile(file, parentUuid: journal.uuid);
        if (context.mounted) {
          Navigator.of(context).pop();
          onSaved?.call();
        }
      } catch (e) {
        if (context.mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(content: Text('Audio upload failed: $e')),
          );
        }
      }
    }

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
          const SizedBox(height: 16),
          TextField(
            controller: controller,
            autofocus: true,
            textInputAction: TextInputAction.done,
            maxLines: 4,
            minLines: 1,
            decoration: const InputDecoration(hintText: 'What is on your mind?'),
            onSubmitted: (_) => save(),
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
          Row(
            children: [
              Expanded(
                child: FilledButton.icon(
                  onPressed: save,
                  icon: const Icon(Icons.save_outlined),
                  label: const Text('Save'),
                ),
              ),
              const SizedBox(width: 12),
              IconButton.filledTonal(
                onPressed: recordAudio,
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
