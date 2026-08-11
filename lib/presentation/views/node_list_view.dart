import 'package:flutter/material.dart';
import 'package:material_design_icons_flutter/material_design_icons_flutter.dart';
import 'package:flutter/services.dart';

import '../../core/utils/node_display_name.dart';
import '../../core/utils/node_icon.dart';
import '../../data/models/node.dart';

/// Reusable list view for a collection of nodes.
class NodeListView extends StatelessWidget {
  const NodeListView({
    super.key,
    required this.nodes,
    required this.onNodeTap,
    this.onNodeLongPress,
    this.footer,
    this.shrinkWrap = false,
    this.favoriteUuids,
    this.onFavoriteToggle,
    this.onArchive,
    this.archiveLabel = 'Archive',
    this.dateFormat,
    this.continuous = false,
  });

  final List<Node> nodes;
  final ValueChanged<Node> onNodeTap;
  final ValueChanged<Node>? onNodeLongPress;
  final Widget? footer;
  final bool shrinkWrap;
  final Set<String>? favoriteUuids;
  final ValueChanged<Node>? onFavoriteToggle;

  /// Called when the user swipes left to archive a node.
  final ValueChanged<Node>? onArchive;

  /// Label shown under the archive swipe action.
  final String archiveLabel;

  /// Optional user date-format preference; used to format journal dates.
  final String? dateFormat;

  /// When true, the list has no outer padding and items are separated by
  /// hairline dividers. Useful for placing the list inside a [FleetCard].
  final bool continuous;

  @override
  Widget build(BuildContext context) {
    final itemCount = nodes.length + (footer != null ? 1 : 0);

    return ListView.builder(
      padding: continuous ? EdgeInsets.zero : const EdgeInsets.symmetric(vertical: 8),
      shrinkWrap: shrinkWrap,
      physics: shrinkWrap ? const NeverScrollableScrollPhysics() : null,
      itemCount: itemCount,
      itemBuilder: _buildItem,
    );
  }

  Widget _buildItem(BuildContext context, int index) {
    final itemCount = nodes.length + (footer != null ? 1 : 0);

    if (footer != null && index == itemCount - 1) {
      return footer!;
    }
    final node = nodes[index];
    final tile = _buildTile(context, node);
    final wrapped = _maybeWrapDismissible(context, node, tile);
    if (!continuous || (index == nodes.length - 1 && footer == null)) {
      return wrapped;
    }
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        wrapped,
        const Divider(height: 1),
      ],
    );
  }

  Widget _buildTile(BuildContext context, Node node) {
    final colors = Theme.of(context).colorScheme;
    final isFavorite = favoriteUuids?.contains(node.uuid) ?? false;
    return ListTile(
      leading: NodeIcon(
        iconField: node.icon,
        fallbackIcon: _iconForNode(node),
        fallbackColor: colors.onSurfaceVariant,
      ),
      title: Text(resolveNodeDisplayName(node, dateFormat: dateFormat)),
      trailing: _buildTrailing(context, node, isFavorite, colors),
      onTap: () => onNodeTap(node),
      onLongPress: onNodeLongPress == null ? null : () => onNodeLongPress!(node),
    );
  }

  Widget _maybeWrapDismissible(BuildContext context, Node node, Widget child) {
    final canPin = onFavoriteToggle != null;
    final canArchive = onArchive != null;
    if (!canPin && !canArchive) return child;

    final direction = canPin && canArchive
        ? DismissDirection.horizontal
        : canPin
            ? DismissDirection.startToEnd
            : DismissDirection.endToStart;
    final colors = Theme.of(context).colorScheme;
    final isFavorite = favoriteUuids?.contains(node.uuid) ?? false;

    return Dismissible(
      key: ValueKey('node-list-${node.uuid}'),
      direction: direction,
      confirmDismiss: (d) async {
        HapticFeedback.lightImpact();
        if (d == DismissDirection.startToEnd && canPin) {
          onFavoriteToggle!(node);
        } else if (canArchive) {
          onArchive!(node);
        }
        return false;
      },
      background: _SwipeBackground(
        alignment: Alignment.centerLeft,
        icon: isFavorite ? MdiIcons.starOff : MdiIcons.star,
        label: isFavorite ? 'Unpin' : 'Pin',
        color: colors.primaryContainer,
        foregroundColor: colors.onPrimaryContainer,
      ),
      secondaryBackground: _SwipeBackground(
        alignment: Alignment.centerRight,
        icon: MdiIcons.archiveOutline,
        label: archiveLabel,
        color: colors.errorContainer,
        foregroundColor: colors.onErrorContainer,
      ),
      child: child,
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
              isFavorite ? MdiIcons.star : MdiIcons.starOutline,
              color: isFavorite ? colors.primary : colors.onSurfaceVariant,
            ),
            tooltip: isFavorite ? 'Remove favorite' : 'Add favorite',
            onPressed: () {
              HapticFeedback.lightImpact();
              toggle(node);
            },
          ),
        Icon(MdiIcons.chevronRight, color: colors.onSurfaceVariant),
      ],
    );
  }

  IconData _iconForNode(Node node) {
    if (node.isJournal) return MdiIcons.calendarOutline;
    if (node.isTask) return MdiIcons.checkCircleOutline;
    return node.icon?.isNotEmpty == true ? MdiIcons.fileDocumentOutline : MdiIcons.fileDocumentOutline;
  }
}

class _SwipeBackground extends StatelessWidget {
  const _SwipeBackground({
    required this.alignment,
    required this.icon,
    required this.label,
    required this.color,
    required this.foregroundColor,
  });

  final Alignment alignment;
  final IconData icon;
  final String label;
  final Color color;
  final Color foregroundColor;

  @override
  Widget build(BuildContext context) {
    return Container(
      color: color,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 20),
        child: Row(
          mainAxisAlignment: alignment == Alignment.centerLeft
              ? MainAxisAlignment.start
              : MainAxisAlignment.end,
          children: [
            Icon(icon, color: foregroundColor, size: 20),
            const SizedBox(width: 8),
            Text(
              label,
              style: Theme.of(context).textTheme.labelLarge?.copyWith(
                    color: foregroundColor,
                    fontWeight: FontWeight.w600,
                  ),
            ),
          ],
        ),
      ),
    );
  }
}
