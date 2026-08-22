import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:go_router/go_router.dart';
import 'package:material_design_icons_flutter/material_design_icons_flutter.dart';
import 'package:provider/provider.dart';

import '../../../core/routing/router.dart';
import '../../../core/utils/node_display_name.dart';
import '../../../core/utils/node_icon.dart';
import '../../../data/models/node.dart';
import '../../../data/repositories/node_repository.dart';
import '../../../native/widget_service.dart';
import '../../settings/providers/settings_provider.dart';
import '../../../shared/widgets/fleet_card.dart';

/// Modal bottom sheet that mirrors the web sidebar: favorites, recent pages,
/// and the archive. All sections are backed by the local node cache through
/// [NodeRepository]; there is no mobile data source for "shared with me" yet.
class BrowsePanel extends StatefulWidget {
  const BrowsePanel({super.key, required this.repository});

  final NodeRepository repository;

  /// Opens the panel as a modal bottom sheet with haptic feedback.
  static Future<void> show(BuildContext context, NodeRepository repository) {
    HapticFeedback.lightImpact();
    return showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      showDragHandle: true,
      builder: (_) => BrowsePanel(repository: repository),
    );
  }

  @override
  State<BrowsePanel> createState() => _BrowsePanelState();
}

class _BrowsePanelState extends State<BrowsePanel> {
  late Future<_BrowseData> _future;

  @override
  void initState() {
    super.initState();
    _future = _load();
  }

  Future<_BrowseData> _load() async {
    final repo = widget.repository;
    // Fetch 10 so the favorites home-screen widget snapshot (saved below)
    // holds more than the five rows shown here.
    final favorites = await _guarded(() => repo.fetchFavorites(limit: 10));
    final recent = await _guarded(() => repo.fetchRecentPages(limit: 5));
    final archived = await _guarded(() async {
      final nodes = await repo.fetchArchived();
      return nodes.take(5).toList();
    });
    // Keep the favorites home-screen widget in sync with what the user sees.
    unawaited(WidgetService.saveFavorites(favorites));
    return _BrowseData(
      favorites: favorites.take(5).toList(),
      recent: recent,
      archived: archived,
    );
  }

  /// Section queries are best-effort: a section whose cache query fails shows
  /// as empty instead of breaking the whole panel.
  Future<List<Node>> _guarded(Future<List<Node>> Function() query) async {
    try {
      return await query();
    } catch (_) {
      return const [];
    }
  }

  @override
  Widget build(BuildContext context) {
    final dateFormat = context.watch<SettingsProvider>().dateFormat;
    return SafeArea(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 0, 16, 24),
        child: FutureBuilder<_BrowseData>(
          future: _future,
          builder: (context, snapshot) {
            final data = snapshot.data;
            if (data == null) {
              return const SizedBox(
                height: 160,
                child: Center(child: CircularProgressIndicator()),
              );
            }
            final cards = <Widget>[
              if (data.favorites.isNotEmpty)
                _BrowseCard(
                  icon: MdiIcons.star,
                  title: 'Favorites',
                  nodes: data.favorites,
                  dateFormat: dateFormat,
                  highlightIcon: true,
                ),
              if (data.recent.isNotEmpty)
                _BrowseCard(
                  icon: MdiIcons.clockOutline,
                  title: 'Recent',
                  nodes: data.recent,
                  dateFormat: dateFormat,
                ),
              if (data.archived.isNotEmpty)
                _BrowseCard(
                  icon: MdiIcons.archiveOutline,
                  title: 'Archive',
                  nodes: data.archived,
                  dateFormat: dateFormat,
                ),
            ];
            if (cards.isEmpty) {
              return const SizedBox(
                height: 160,
                child: Center(child: Text('Nothing to browse yet')),
              );
            }
            return ListView.separated(
              shrinkWrap: true,
              itemCount: cards.length,
              separatorBuilder: (context, index) => const SizedBox(height: 12),
              itemBuilder: (context, index) => cards[index],
            );
          },
        ),
      ),
    );
  }
}

class _BrowseData {
  const _BrowseData({
    required this.favorites,
    required this.recent,
    required this.archived,
  });

  final List<Node> favorites;
  final List<Node> recent;
  final List<Node> archived;
}

/// One browse section: a titled card with a handful of page rows.
class _BrowseCard extends StatelessWidget {
  const _BrowseCard({
    required this.icon,
    required this.title,
    required this.nodes,
    required this.dateFormat,
    this.highlightIcon = false,
  });

  final IconData icon;
  final String title;
  final List<Node> nodes;
  final String dateFormat;

  /// Renders the section icon in the accent color (favorites only).
  final bool highlightIcon;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colors = theme.colorScheme;
    return FleetCard(
      padding: const EdgeInsets.symmetric(vertical: 4),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 12, 16, 4),
            child: Row(
              children: [
                Icon(
                  icon,
                  size: 18,
                  color: highlightIcon ? colors.primary : colors.onSurfaceVariant,
                ),
                const SizedBox(width: 8),
                Text(
                  title,
                  style: theme.textTheme.titleSmall?.copyWith(
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ],
            ),
          ),
          for (final node in nodes)
            _BrowseRow(node: node, dateFormat: dateFormat),
        ],
      ),
    );
  }
}

/// A single page row: node icon plus display name; tap opens the editor.
class _BrowseRow extends StatelessWidget {
  const _BrowseRow({required this.node, required this.dateFormat});

  final Node node;
  final String dateFormat;

  @override
  Widget build(BuildContext context) {
    return InkWell(
      onTap: () {
        HapticFeedback.lightImpact();
        // Capture the router before popping: the sheet's context is
        // deactivated once the sheet closes.
        final router = GoRouter.of(context);
        Navigator.of(context).pop();
        router.push('${Routes.editor}/${node.uuid}');
      },
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
        child: Row(
          children: [
            NodeIcon(iconField: node.icon, size: 18),
            const SizedBox(width: 10),
            Expanded(
              child: Text(
                resolveNodeDisplayName(node, dateFormat: dateFormat),
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
              ),
            ),
          ],
        ),
      ),
    );
  }
}
