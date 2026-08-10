import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../providers/settings_provider.dart';
import 'quick_capture_sheet.dart';

/// Minimal floating capture sheet used by the in-app floating bubble.
///
/// Wraps [QuickCaptureSheet] in a compact dialog so it can be opened from the
/// bubble without taking over the full screen.
class FloatingCaptureSheet extends StatelessWidget {
  const FloatingCaptureSheet({
    super.key,
    this.onSaved,
  });

  final VoidCallback? onSaved;

  @override
  Widget build(BuildContext context) {
    final settings = context.read<SettingsProvider>();
    final defaultType = settings.floatingCaptureBubbleDefaultType;

    return Dialog(
      insetPadding: const EdgeInsets.symmetric(horizontal: 20, vertical: 48),
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(28),
      ),
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 480),
        child: ClipRRect(
          borderRadius: BorderRadius.circular(28),
          child: QuickCaptureSheet(
            initialType: defaultType,
            onSaved: onSaved,
          ),
        ),
      ),
    );
  }
}
