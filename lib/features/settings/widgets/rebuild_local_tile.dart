import 'package:material_ui/material_ui.dart';
import 'package:material_design_icons_flutter/material_design_icons_flutter.dart';
import 'package:provider/provider.dart';

import '../../auth/providers/auth_provider.dart';

/// Settings → Sync trigger for the offline local-first derived rebuild
/// (`SyncV2Service.rebuildLocalDerivedState` — a mobile-only capability; the
/// web client has no local archive and no manual rebuild). Confirms first,
/// shows a busy state, and surfaces the replay count or the error.
class RebuildLocalTile extends StatefulWidget {
  const RebuildLocalTile({super.key});

  @override
  State<RebuildLocalTile> createState() => _RebuildLocalTileState();
}

class _RebuildLocalTileState extends State<RebuildLocalTile> {
  bool _busy = false;

  Future<void> _confirmAndRebuild() async {
    final confirmed = await showModalBottomSheet<bool>(
      context: context,
      showDragHandle: true,
      builder: (_) => const RebuildConfirmSheet(),
    );
    if (confirmed != true || !mounted) return;
    setState(() => _busy = true);
    final messenger = ScaffoldMessenger.of(context);
    try {
      final auth = context.read<AuthProvider>();
      final sync = auth.syncService;
      if (sync == null) throw StateError('Sync service not available');
      final replayed = await sync.rebuildLocalDerivedState();
      if (!mounted) return;
      messenger.showSnackBar(
        SnackBar(
          content: Text(
            'Local data rebuilt — $replayed operations replayed',
          ),
        ),
      );
    } catch (e) {
      if (!mounted) return;
      messenger.showSnackBar(
        SnackBar(content: Text('Rebuild failed: $e')),
      );
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return ListTile(
      leading: Icon(MdiIcons.databaseRefreshOutline),
      title: const Text('Rebuild local data'),
      subtitle: const Text(
        'Replay the local operation log to repair the local database',
      ),
      trailing: _busy
          ? const SizedBox(
              width: 20,
              height: 20,
              child: CircularProgressIndicator(strokeWidth: 2),
            )
          : Icon(MdiIcons.chevronRight),
      onTap: _busy ? null : _confirmAndRebuild,
    );
  }
}

/// The rebuild confirmation — pure presentation (returns true to rebuild).
class RebuildConfirmSheet extends StatelessWidget {
  const RebuildConfirmSheet({super.key});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return SafeArea(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(20, 0, 20, 16),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('Rebuild local data?', style: theme.textTheme.titleMedium),
            const SizedBox(height: 8),
            Text(
              'Rebuilds the local derived data from the local operation log. '
              'Safe: it keeps unsynced changes. It may take a while on large '
              'workspaces.',
              style: theme.textTheme.bodySmall
                  ?.copyWith(color: theme.colorScheme.onSurfaceVariant),
            ),
            const SizedBox(height: 16),
            Row(
              mainAxisAlignment: MainAxisAlignment.end,
              children: [
                TextButton(
                  onPressed: () => Navigator.of(context).pop(false),
                  child: const Text('Cancel'),
                ),
                const SizedBox(width: 8),
                FilledButton(
                  onPressed: () => Navigator.of(context).pop(true),
                  child: const Text('Rebuild'),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}
