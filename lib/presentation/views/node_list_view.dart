import 'package:flutter/material.dart';

import '../../data/models/node.dart';

/// Reusable list view for a collection of nodes.
class NodeListView extends StatelessWidget {
  const NodeListView({
    super.key,
    required this.nodes,
    required this.onNodeTap,
    this.footer,
    this.shrinkWrap = false,
  });

  final List<Node> nodes;
  final ValueChanged<Node> onNodeTap;
  final Widget? footer;
  final bool shrinkWrap;

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
        return ListTile(
          leading: Icon(
            _iconForNode(node),
            color: colors.onSurfaceVariant,
          ),
          title: Text(node.displayName),
          trailing: Icon(Icons.chevron_right, color: colors.onSurfaceVariant),
          onTap: () => onNodeTap(node),
        );
      },
    );
  }

  IconData _iconForNode(Node node) {
    if (node.isJournal) return Icons.calendar_today_outlined;
    if (node.isTask) return Icons.check_circle_outline;
    return node.icon?.isNotEmpty == true ? Icons.description_outlined : Icons.description_outlined;
  }
}
