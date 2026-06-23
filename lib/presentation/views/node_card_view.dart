import 'package:flutter/material.dart';

import '../../data/models/node.dart';
import '../widgets/fleet_card.dart';

/// Card grid view for a collection of nodes.
class NodeCardView extends StatelessWidget {
  const NodeCardView({
    super.key,
    required this.nodes,
    required this.onNodeTap,
    this.favoriteIds,
    this.onFavoriteToggle,
  });

  final List<Node> nodes;
  final ValueChanged<Node> onNodeTap;
  final Set<int>? favoriteIds;
  final ValueChanged<Node>? onFavoriteToggle;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;

    return GridView.builder(
      padding: const EdgeInsets.all(16),
      gridDelegate: const SliverGridDelegateWithMaxCrossAxisExtent(
        maxCrossAxisExtent: 220,
        mainAxisSpacing: 12,
        crossAxisSpacing: 12,
        childAspectRatio: 1.1,
      ),
      itemCount: nodes.length,
      itemBuilder: (context, index) {
        final node = nodes[index];
        final isFavorite = favoriteIds?.contains(node.id) ?? false;
        return FleetCard(
          onTap: () => onNodeTap(node),
          child: Padding(
            padding: const EdgeInsets.all(16),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Icon(
                      _iconForNode(node),
                      color: colors.onSurfaceVariant,
                      size: 28,
                    ),
                    const Spacer(),
                    if (onFavoriteToggle != null)
                      IconButton(
                        icon: Icon(
                          isFavorite ? Icons.star : Icons.star_border,
                          color: isFavorite ? colors.primary : colors.onSurfaceVariant,
                        ),
                        tooltip: isFavorite ? 'Remove favorite' : 'Add favorite',
                        onPressed: () => onFavoriteToggle!(node),
                      ),
                  ],
                ),
                const SizedBox(height: 12),
                Expanded(
                  child: Text(
                    node.displayName,
                    style: Theme.of(context).textTheme.titleSmall?.copyWith(
                          fontWeight: FontWeight.w600,
                        ),
                    maxLines: 3,
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
                if (node.classes.isNotEmpty || node.tags.isNotEmpty)
                  Padding(
                    padding: const EdgeInsets.only(top: 8),
                    child: _buildChips(context, node, colors),
                  ),
              ],
            ),
          ),
        );
      },
    );
  }

  Widget _buildChips(BuildContext context, Node node, ColorScheme colors) {
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

  IconData _iconForNode(Node node) {
    if (node.isJournal) return Icons.calendar_today_outlined;
    if (node.isTask) return Icons.check_circle_outline;
    return node.icon?.isNotEmpty == true ? Icons.description_outlined : Icons.description_outlined;
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
