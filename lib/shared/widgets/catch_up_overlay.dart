import 'package:material_ui/material_ui.dart';
import 'package:material_design_icons_flutter/material_design_icons_flutter.dart';
import 'package:provider/provider.dart';

import '../../features/home/providers/sync_status_provider.dart';

/// The bootstrap "Catching up…" surface, the counterpart of the web client's
/// ConnectingScreen during the workspace connect: an opaque full-screen
/// layer (logo + label + progress) stacked above the app shell so the user
/// cannot interact with half-synced content while the first pull after a
/// workspace session runs. Rendered only while [SyncStatusProvider] shows
/// the overlay; passes [child] through untouched otherwise.
class CatchUpOverlay extends StatelessWidget {
  const CatchUpOverlay({super.key, required this.child});

  final Widget child;

  @override
  Widget build(BuildContext context) {
    final status = context.watch<SyncStatusProvider>();
    if (!status.showCatchUpOverlay) return child;

    final fraction = status.fraction;
    final theme = Theme.of(context);
    return Stack(
      children: [
        child,
        Positioned.fill(
          child: AbsorbPointer(
            child: ColoredBox(
              color: theme.colorScheme.surface,
              child: SafeArea(
                child: Column(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    Container(
                      width: 80,
                      height: 80,
                      decoration: BoxDecoration(
                        color: theme.colorScheme.primaryContainer,
                        borderRadius: BorderRadius.circular(20),
                      ),
                      child: Icon(
                        MdiIcons.noteTextOutline,
                        size: 40,
                        color: theme.colorScheme.onPrimaryContainer,
                      ),
                    ),
                    const SizedBox(height: 24),
                    Text(
                      'Notees',
                      style: theme.textTheme.headlineSmall?.copyWith(
                            fontWeight: FontWeight.w600,
                          ),
                    ),
                    const SizedBox(height: 32),
                    SizedBox(
                      width: 200,
                      child: fraction != null
                          ? LinearProgressIndicator(value: fraction)
                          : const SizedBox(
                              width: 24,
                              height: 24,
                              child: Center(
                                child: CircularProgressIndicator(
                                  strokeWidth: 2.5,
                                ),
                              ),
                            ),
                    ),
                    const SizedBox(height: 16),
                    Text(
                      status.progressLabel ?? 'Catching up…',
                      style: theme.textTheme.bodyMedium,
                    ),
                  ],
                ),
              ),
            ),
          ),
        ),
      ],
    );
  }
}
