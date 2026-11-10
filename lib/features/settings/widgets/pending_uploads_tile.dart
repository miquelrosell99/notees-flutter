import 'package:material_ui/material_ui.dart';
import 'package:material_design_icons_flutter/material_design_icons_flutter.dart';
import 'package:provider/provider.dart';

import '../../../data/local/app_database.dart';
import '../../../data/repositories/pending_asset_repository.dart';
import '../../../domain/services/pending_asset_service.dart';
import '../../auth/providers/auth_provider.dart';

/// Settings → Sync tile surfacing the background-asset queue: "N uploads
/// waiting / M failed", tapping into the dead-letter sheet (retry-now /
/// discard). Counts reload after every sheet close and on retry/discard.
class PendingUploadsTile extends StatefulWidget {
  const PendingUploadsTile({super.key});

  @override
  State<PendingUploadsTile> createState() => _PendingUploadsTileState();
}

class _PendingUploadsTileState extends State<PendingUploadsTile> {
  Future<({int pending, int failed})> _countsFuture = Future.value(
    (pending: 0, failed: 0),
  );

  @override
  void initState() {
    super.initState();
    _refresh();
  }

  void _refresh() {
    setState(() {
      _countsFuture = PendingAssetRepository(AppDatabase()).counts();
    });
  }

  Future<void> _open() async {
    final auth = context.read<AuthProvider>();
    final service = PendingAssetService(
      database: AppDatabase(),
      dio: auth.dio!,
      syncService: auth.syncService,
    );
    final failed = await service.failedItems();
    final counts = await _countsFuture;
    if (!mounted) return;
    await showModalBottomSheet<void>(
      context: context,
      showDragHandle: true,
      builder: (_) => PendingUploadsSheet(
        pendingCount: counts.pending,
        failed: failed,
        onRetry: (id) async {
          await service.retryNow(id);
          // Best-effort immediate retry; the regular drains cover the rest.
          await service.drain();
        },
        onDiscard: service.discard,
      ),
    );
    _refresh();
  }

  @override
  Widget build(BuildContext context) {
    return FutureBuilder<({int pending, int failed})>(
      future: _countsFuture,
      builder: (context, snapshot) {
        final counts = snapshot.data;
        final pending = counts?.pending ?? 0;
        final failed = counts?.failed ?? 0;
        return ListTile(
          leading: Icon(MdiIcons.clockOutline),
          title: const Text('Pending uploads'),
          subtitle: Text(
            failed > 0
                ? '$pending waiting — $failed failed'
                : pending > 0
                    ? '$pending uploads waiting'
                    : 'Nothing waiting to upload',
          ),
          trailing:
              pending > 0 || failed > 0 ? Icon(MdiIcons.chevronRight) : null,
          onTap: pending > 0 || failed > 0 ? _open : null,
        );
      },
    );
  }
}

/// The dead-letter view: the waiting count plus the failed items with
/// retry-now / discard actions. Pure presentation — the tile supplies data
/// and callbacks.
class PendingUploadsSheet extends StatelessWidget {
  const PendingUploadsSheet({
    super.key,
    required this.pendingCount,
    required this.failed,
    required this.onRetry,
    required this.onDiscard,
  });

  final int pendingCount;
  final List<PendingAssetRow> failed;
  final Future<void> Function(String id) onRetry;
  final Future<void> Function(String id) onDiscard;

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
            Text('Pending uploads', style: theme.textTheme.titleMedium),
            const SizedBox(height: 8),
            Text(
              pendingCount > 0
                  ? '$pendingCount upload(s) waiting — they upload '
                      'automatically in the background.'
                  : 'Nothing waiting to upload.',
              style: theme.textTheme.bodySmall
                  ?.copyWith(color: theme.colorScheme.onSurfaceVariant),
            ),
            if (failed.isNotEmpty) ...[
              const SizedBox(height: 16),
              Text('Failed', style: theme.textTheme.titleSmall),
              const SizedBox(height: 4),
              Flexible(
                child: ListView(
                  shrinkWrap: true,
                  children: [
                    for (final item in failed)
                      Row(
                        children: [
                          Expanded(
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Text(
                                  item.originalName,
                                  style: theme.textTheme.bodyMedium,
                                  overflow: TextOverflow.ellipsis,
                                ),
                                Text(
                                  item.lastError ?? 'Upload failed',
                                  style: theme.textTheme.bodySmall?.copyWith(
                                    color: theme.colorScheme.error,
                                  ),
                                  overflow: TextOverflow.ellipsis,
                                ),
                              ],
                            ),
                          ),
                          TextButton(
                            onPressed: () => onRetry(item.id),
                            child: const Text('Retry'),
                          ),
                          TextButton(
                            onPressed: () => onDiscard(item.id),
                            child: const Text('Discard'),
                          ),
                        ],
                      ),
                  ],
                ),
              ),
            ],
          ],
        ),
      ),
    );
  }
}
