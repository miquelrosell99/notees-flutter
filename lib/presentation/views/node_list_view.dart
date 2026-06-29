import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../data/models/node.dart';

/// Reusable list view for a collection of nodes.
class NodeListView extends StatelessWidget {
  const NodeListView({
    super.key,
    required this.nodes,
    required this.onNodeTap,
    this.footer,
    this.shrinkWrap = false,
    this.favoriteUuids,
    this.onFavoriteToggle,
  });

  final List<Node> nodes;
  final ValueChanged<Node> onNodeTap;
  final Widget? footer;
  final bool shrinkWrap;
  final Set<String>? favoriteUuids;
  final ValueChanged<Node>? onFavoriteToggle;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;

    return ListView.builder(
      padding: const EdgeInsets.symmetric(vertical: 8),
      shrinkWrap: shrinkWrap,
      physics: shrinkWrap ? const NeverScrollableScrollPhysics() : null,
      itemCount: nodes.length + (footer != null ? 1 : 0),
      itemBuilder: (context, index) {
        if (footer != null && index == nodes.length) {
          return footer!;
        }
        final node = nodes[index];
        final isFavorite = favoriteUuids?.contains(node.uuid) ?? false;
        return ListTile(
          leading: Icon(
            _iconForNode(node),
            color: colors.onSurfaceVariant,
          ),
          title: Text(node.displayName),
          trailing: _buildTrailing(context, node, isFavorite, colors),
          onTap: () => onNodeTap(node),
        );
      },
    );
  }

  Widget _buildTrailing(BuildContext context, Node node, bool isFavorite, ColorScheme colors) {
    final toggle = onFavoriteToggle;
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        if (toggle != null)
          IconButton(
            icon: Icon(
              isFavorite ? Icons.star : Icons.star_border,
              color: isFavorite ? colors.primary : colors.onSurfaceVariant,
            ),
            tooltip: isFavorite ? 'Remove favorite' : 'Add favorite',
            onPressed: () {
              HapticFeedback.lightImpact();
              toggle(node);
            },
          ),
        Icon(Icons.chevron_right, color: colors.onSurfaceVariant),
      ],
    );
  }

  IconData _iconForNode(Node node) {
    if (node.isJournal) return Icons.calendar_today_outlined;
    if (node.isTask) return Icons.check_circle_outline;
    return node.icon?.isNotEmpty == true ? Icons.description_outlined : Icons.description_outlined;
  }
}
