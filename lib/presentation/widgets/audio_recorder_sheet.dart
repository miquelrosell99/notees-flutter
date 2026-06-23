import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:path_provider/path_provider.dart';
import 'package:record/record.dart';

/// Bottom sheet that records audio and returns the recorded [File].
class AudioRecorderSheet extends StatefulWidget {
  const AudioRecorderSheet({super.key});

  @override
  State<AudioRecorderSheet> createState() => _AudioRecorderSheetState();
}

class _AudioRecorderSheetState extends State<AudioRecorderSheet> {
  final _recorder = AudioRecorder();
  bool _isRecording = false;
  bool _hasRecording = false;
  String? _path;
  String? _error;
  Duration _duration = Duration.zero;
  Timer? _timer;

  @override
  void dispose() {
    _timer?.cancel();
    _recorder.dispose();
    super.dispose();
  }

  Future<void> _toggleRecording() async {
    if (_isRecording) {
      await _stopRecording();
      return;
    }

    final hasPermission = await _recorder.hasPermission();
    if (!hasPermission) {
      setState(() => _error = 'Microphone permission denied');
      return;
    }

    final tempDir = await getTemporaryDirectory();
    final path =
        '${tempDir.path}/notees_audio_${DateTime.now().millisecondsSinceEpoch}.m4a';

    await _recorder.start(const RecordConfig(), path: path);

    setState(() {
      _isRecording = true;
      _hasRecording = false;
      _path = path;
      _error = null;
      _duration = Duration.zero;
    });

    _timer?.cancel();
    _timer = Timer.periodic(const Duration(seconds: 1), (_) {
      setState(() => _duration += const Duration(seconds: 1));
    });
  }

  Future<void> _stopRecording() async {
    final path = await _recorder.stop();
    _timer?.cancel();
    setState(() {
      _isRecording = false;
      _hasRecording = true;
      _path = path;
    });
  }

  void _discard() {
    final path = _path;
    if (path != null) {
      File(path).deleteSync();
    }
    Navigator.of(context).pop();
  }

  void _confirm() {
    final path = _path;
    if (path == null || !File(path).existsSync()) {
      Navigator.of(context).pop();
      return;
    }
    Navigator.of(context).pop(File(path));
  }

  String _formatDuration(Duration duration) {
    final minutes = duration.inMinutes.toString().padLeft(2, '0');
    final seconds = (duration.inSeconds % 60).toString().padLeft(2, '0');
    return '$minutes:$seconds';
  }

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;

    return SafeArea(
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(
              'Audio note',
              style: Theme.of(context).textTheme.titleLarge,
            ),
            const SizedBox(height: 24),
            if (_isRecording) ...[
              Text(
                _formatDuration(_duration),
                style: Theme.of(context).textTheme.headlineSmall,
              ),
              const SizedBox(height: 8),
              Text(
                'Recording…',
                style: TextStyle(color: colors.error),
              ),
            ] else if (_hasRecording) ...[
              const Icon(Icons.check_circle, size: 48),
              const SizedBox(height: 8),
              Text(
                'Recorded ${_formatDuration(_duration)}',
                style: Theme.of(context).textTheme.titleMedium,
              ),
            ] else ...[
              Text(
                'Tap the microphone to start recording',
                style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                      color: colors.onSurfaceVariant,
                    ),
              ),
            ],
            if (_error != null) ...[
              const SizedBox(height: 12),
              Text(
                _error!,
                style: TextStyle(color: colors.error),
                textAlign: TextAlign.center,
              ),
            ],
            const SizedBox(height: 24),
            Row(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                if (_hasRecording)
                  TextButton.icon(
                    onPressed: _discard,
                    icon: const Icon(Icons.delete_outline),
                    label: const Text('Discard'),
                  )
                else
                  const SizedBox(width: 64),
                const SizedBox(width: 16),
                FloatingActionButton(
                  onPressed: _toggleRecording,
                  backgroundColor: _isRecording ? colors.error : colors.primary,
                  child: Icon(
                    _isRecording ? Icons.stop : Icons.mic,
                    color: _isRecording ? colors.onError : colors.onPrimary,
                  ),
                ),
                const SizedBox(width: 16),
                if (_hasRecording)
                  FilledButton(
                    onPressed: _confirm,
                    child: const Text('Use'),
                  )
                else
                  const SizedBox(width: 64),
              ],
            ),
            const SizedBox(height: 16),
          ],
        ),
      ),
    );
  }
}
