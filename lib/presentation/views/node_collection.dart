import 'package:flutter/material.dart';

import '../../data/models/node.dart';
import 'node_card_view.dart';
import 'node_list_view.dart';
import 'node_table_view.dart';
import 'node_view_mode.dart';

/// Dispatcher widget that renders a collection of nodes according to the
/// selected view mode.
class NodeCollection extends StatelessWidget {
  const NodeCollection({
    super.key,
    required this.mode,
    required this.nodes,
    required this.onNodeTap,
    this.emptyMessage = 'No items',
    this.footer,
  });

  final NodeViewMode mode;
  final List<Node> nodes;
  final ValueChanged<Node> onNodeTap;
  final String emptyMessage;
  final Widget? footer;

  @override
  Widget build(BuildContext context) {
    if (nodes.isEmpty) {
      return Center(child: Text(emptyMessage));
    }

    switch (mode) {
      case NodeViewMode.list:
        return NodeListView(nodes: nodes, onNodeTap: onNodeTap, footer: footer);
      case NodeViewMode.card:
        return NodeCardView(nodes: nodes, onNodeTap: onNodeTap);
      case NodeViewMode.table:
        return NodeTableView(nodes: nodes, onNodeTap: onNodeTap);
    }
  }
}
