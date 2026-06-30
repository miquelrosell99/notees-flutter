import 'package:flutter/material.dart';
import 'package:material_design_icons_flutter/material_design_icons_flutter.dart';
import 'package:flutter/services.dart';

import '../../data/models/node.dart';
import '../widgets/fleet_card.dart';
import '_view_helpers.dart';

/// Kanban view for a collection of nodes.
///
/// Groups nodes by a selected property value and displays draggable-style
/// columns. Tapping a card opens the node editor.
class NodeKanbanView extends StatefulWidget {
  const NodeKanbanView({
    super.key,
    required this.nodes,
    required this.onNodeTap,
    this.favoriteUuids,
    this.onFavoriteToggle,
  });

  final List<Node> nodes;
  final ValueChanged<Node> onNodeTap;
  final Set<String>? favoriteUuids;
  final ValueChanged<Node>? onFavoriteToggle;

  @override
  State<NodeKanbanView> createState() => _NodeKanbanViewState();
}

class _NodeKanbanViewState extends State<NodeKanbanView> {
  String? _groupByKey;

  List<String> get _availableKeys => collectPropertyKeys(widget.nodes);

  @override
  void initState() {
    super.initState();
    _applyDefaultGroup();
  }

  @override
  void didUpdateWidget(covariant NodeKanbanView oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.nodes != oldWidget.nodes) {
      _applyDefaultGroup();
    }
  }

  void _applyDefaultGroup() {
    final available = _availableKeys;
    if (available.isEmpty) {
      _groupByKey = null;
      return;
    }
    // Prefer a known status-like property, otherwise keep current if still valid.
    if (_groupByKey != null && available.contains(_groupByKey)) return;
    final statusLike = available.firstWhere(
      (k) => k.toLowerCase().contains('status') || k.toLowerCase().contains('state'),
      orElse: () => available.first,
    );
    _groupByKey = statusLike;
  }

  Map<String, List<Node>> _buildGroups() {
    final key = _groupByKey;
    if (key == null) {
      return {'All': widget.nodes};
    }
    final groups = <String, List<Node>>{};
    for (final node in widget.nodes) {
      final value = groupValueFor(node, key);
      groups.putIfAbsent(value, () => []).add(node);
    }
    // Stable ordering: preserve original node order within each group.
    for (final list in groups.values) {
      list.sort((a, b) => widget.nodes.indexOf(a).compareTo(widget.nodes.indexOf(b)));
    }
    return groups;
  }

  Future<void> _openGroupSelector() async {
    final available = _availableKeys;
    if (available.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('No grouping properties available')),
      );
      return;
    }

    final result = await showModalBottomSheet<String>(
      context: context,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(28)),
      ),
      builder: (ctx) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(20, 16, 20, 8),
              child: Text(
                'Group by',
                style: Theme.of(context).textTheme.titleMedium?.copyWith(
                      fontWeight: FontWeight.w600,
                    ),
              ),
            ),
            ...available.map((key) {
              final selected = key == _groupByKey;
              return ListTile(
                title: Text(propertyDisplayName(key)),
                trailing: selected ? Icon(MdiIcons.check, color: Theme.of(context).colorScheme.primary) : null,
                onTap: () => Navigator.of(ctx).pop(key),
              );
            }),
          ],
        ),
      ),
    );

    if (result != null) {
      setState(() => _groupByKey = result);
    }
  }

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    final groups = _buildGroups();
    final groupKeys = groups.keys.toList();

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 8, 8, 0),
          child: Row(
            children: [
              Text(
                _groupByKey == null
                    ? '${widget.nodes.length} items'
                    : 'Grouped by ${propertyDisplayName(_groupByKey!)}',
                style: Theme.of(context).textTheme.labelMedium?.copyWith(
                      color: colors.onSurfaceVariant,
                    ),
              ),
              const Spacer(),
              IconButton(
                icon: Icon(MdiIcons.folderMultipleOutline),
                tooltip: 'Group by property',
                onPressed: _openGroupSelector,
              ),
            ],
          ),
        ),
        Expanded(
          child: ListView.separated(
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
            scrollDirection: Axis.horizontal,
            itemCount: groupKeys.length,
            separatorBuilder: (_, _) => const SizedBox(width: 12),
            itemBuilder: (context, index) {
              final key = groupKeys[index];
              final nodes = groups[key]!;
              return _KanbanColumn(
                title: key,
                count: nodes.length,
                nodes: nodes,
                onNodeTap: widget.onNodeTap,
                favoriteUuids: widget.favoriteUuids,
                onFavoriteToggle: widget.onFavoriteToggle,
              );
            },
          ),
        ),
      ],
    );
  }
}

class _KanbanColumn extends StatelessWidget {
  const _KanbanColumn({
    required this.title,
    required this.count,
    required this.nodes,
    required this.onNodeTap,
    this.favoriteUuids,
    this.onFavoriteToggle,
  });

  final String title;
  final int count;
  final List<Node> nodes;
  final ValueChanged<Node> onNodeTap;
  final Set<String>? favoriteUuids;
  final ValueChanged<Node>? onFavoriteToggle;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;

    return Container(
      width: 260,
      decoration: BoxDecoration(
        color: colors.surfaceContainerHighest.withAlpha((0.4 * 255).round()),
        borderRadius: BorderRadius.circular(16),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 12, 16, 8),
            child: Row(
              children: [
                Expanded(
                  child: Text(
                    title,
                    style: Theme.of(context).textTheme.titleSmall?.copyWith(
                          fontWeight: FontWeight.w600,
                        ),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
                Container(
                  padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
                  decoration: BoxDecoration(
                    color: colors.surfaceContainerHighest,
                    borderRadius: BorderRadius.circular(12),
                  ),
                  child: Text(
                    '$count',
                    style: Theme.of(context).textTheme.labelSmall?.copyWith(
                          color: colors.onSurfaceVariant,
                          fontWeight: FontWeight.w600,
                        ),
                  ),
                ),
              ],
            ),
          ),
          Expanded(
            child: ListView.builder(
              padding: const EdgeInsets.fromLTRB(12, 0, 12, 12),
              itemCount: nodes.length,
              itemBuilder: (context, index) {
                final node = nodes[index];
                return Padding(
                  padding: const EdgeInsets.only(bottom: 8),
                  child: _KanbanCard(
                    node: node,
                    onTap: () => onNodeTap(node),
                    isFavorite: favoriteUuids?.contains(node.uuid) ?? false,
                    onFavoriteToggle: onFavoriteToggle == null
                        ? null
                        : () => onFavoriteToggle!(node),
                  ),
                );
              },
            ),
          ),
        ],
      ),
    );
  }
}

class _KanbanCard extends StatelessWidget {
  const _KanbanCard({
    required this.node,
    required this.onTap,
    this.isFavorite = false,
    this.onFavoriteToggle,
  });

  final Node node;
  final VoidCallback onTap;
  final bool isFavorite;
  final VoidCallback? onFavoriteToggle;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;

    return FleetCard(
      onTap: onTap,
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Icon(
                  iconForNode(node),
                  size: 18,
                  color: colors.onSurfaceVariant,
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    node.displayName,
                    style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                          fontWeight: FontWeight.w600,
                        ),
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
                if (onFavoriteToggle != null)
                  IconButton(
                    icon: Icon(
                      isFavorite ? MdiIcons.star : MdiIcons.starOutline,
                      size: 18,
                      color: isFavorite ? colors.primary : colors.onSurfaceVariant,
                    ),
                    tooltip: isFavorite ? 'Remove favorite' : 'Add favorite',
                    onPressed: () {
                      HapticFeedback.lightImpact();
                      onFavoriteToggle?.call();
                    },
                  ),
              ],
            ),
            if (node.classes.isNotEmpty || node.tags.isNotEmpty) ...[
              const SizedBox(height: 8),
              _buildChips(context, colors),
            ],
          ],
        ),
      ),
    );
  }

  Widget _buildChips(BuildContext context, ColorScheme colors) {
    final chips = <Widget>[];
    if (node.isTask) {
      chips.add(_Chip('Task', colors.primaryContainer, colors.onPrimaryContainer));
    }
    if (node.isJournal) {
      chips.add(_Chip('Journal', colors.secondaryContainer, colors.onSecondaryContainer));
    }
    if (node.classes.isNotEmpty) {
      chips.add(_Chip('${node.classes.length}', colors.surfaceContainerHighest, colors.onSurfaceVariant));
    }

    return Wrap(
      spacing: 6,
      runSpacing: 6,
      children: chips,
    );
  }
}

class _Chip extends StatelessWidget {
  const _Chip(this.label, this.backgroundColor, this.foregroundColor);

  final String label;
  final Color backgroundColor;
  final Color foregroundColor;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
      decoration: BoxDecoration(
        color: backgroundColor,
        borderRadius: BorderRadius.circular(12),
      ),
      child: Text(
        label,
        style: Theme.of(context).textTheme.labelSmall?.copyWith(
              color: foregroundColor,
              fontWeight: FontWeight.w500,
            ),
      ),
    );
  }
}
