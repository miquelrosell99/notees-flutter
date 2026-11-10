import 'package:material_ui/material_ui.dart';
import 'package:material_design_icons_flutter/material_design_icons_flutter.dart';
import 'package:provider/provider.dart';

import '../../features/auth/providers/auth_provider.dart';
import '../../features/home/providers/sync_status_provider.dart';

/// The bootstrap "Catching up…" surface, the counterpart of the web client's
/// ConnectingScreen during the workspace connect: an opaque full-screen
/// layer (logo + label + progress) stacked above the app shell so the user
/// cannot interact with half-synced content while the first pull after a
/// workspace session runs. Rendered only while [SyncStatusProvider] shows
/// the overlay; passes [child] through untouched otherwise.
///
/// On a pull failure the surface switches to error mode: the error text
/// with Retry (re-runs the workspace-entry pull) and Dismiss (hides the
/// overlay) — a surfaced failure stays until the user picks one.
class CatchUpOverlay extends StatelessWidget {
  const CatchUpOverlay({super.key, required this.child});

  final Widget child;

  @override
  Widget build(BuildContext context) {
    final status = context.watch<SyncStatusProvider>();
    if (!status.showCatchUpOverlay) return child;

    final theme = Theme.of(context);
    final error = status.pullError;
    return Stack(
      children: [
        child,
        Positioned.fill(
          // Blocks interaction with the half-synced shell while catching up;
          // error mode stays interactive — its Retry/Dismiss are the exits.
          child: AbsorbPointer(
            absorbing: error == null,
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
                    if (error != null) ...[
                      _ErrorBody(
                        error: error,
                        onRetry: () => context
                            .read<AuthProvider>()
                            .retryWorkspacePull(),
                        onDismiss: status.dismissError,
                      ),
                    ] else ...[
                      _ProgressBody(status: status),
                    ],
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

class _ProgressBody extends StatelessWidget {
  const _ProgressBody({required this.status});

  final SyncStatusProvider status;

  @override
  Widget build(BuildContext context) {
    final fraction = status.fraction;
    final theme = Theme.of(context);
    return Column(
      children: [
        SizedBox(
          width: 200,
          child: fraction != null
              ? LinearProgressIndicator(value: fraction)
              : const SizedBox(
                  width: 24,
                  height: 24,
                  child: Center(
                    child: CircularProgressIndicator(strokeWidth: 2.5),
                  ),
                ),
        ),
        const SizedBox(height: 16),
        Text(
          status.progressLabel ?? 'Catching up…',
          style: theme.textTheme.bodyMedium,
        ),
      ],
    );
  }
}

class _ErrorBody extends StatelessWidget {
  const _ErrorBody({
    required this.error,
    required this.onRetry,
    required this.onDismiss,
  });

  final String error;
  final VoidCallback onRetry;
  final VoidCallback onDismiss;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 32),
      child: Column(
        children: [
          Icon(
            MdiIcons.cloudAlertOutline,
            size: 32,
            color: theme.colorScheme.error,
          ),
          const SizedBox(height: 12),
          Text(
            'Sync failed',
            style: theme.textTheme.titleMedium?.copyWith(
                  fontWeight: FontWeight.w600,
                ),
          ),
          const SizedBox(height: 8),
          Text(
            error,
            textAlign: TextAlign.center,
            style: theme.textTheme.bodySmall?.copyWith(
                  color: theme.colorScheme.onSurfaceVariant,
                ),
          ),
          const SizedBox(height: 24),
          Row(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              OutlinedButton.icon(
                onPressed: onRetry,
                icon: const Icon(Icons.refresh, size: 18),
                label: const Text('Retry'),
              ),
              const SizedBox(width: 12),
              TextButton(
                onPressed: onDismiss,
                child: const Text('Dismiss'),
              ),
            ],
          ),
        ],
      ),
    );
  }
}
