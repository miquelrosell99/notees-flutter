import 'package:flutter/material.dart';

import '../../data/models/node.dart';
import 'node_calendar_view.dart';
import 'node_card_view.dart';
import 'node_kanban_view.dart';
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
    this.favoriteIds,
    this.onFavoriteToggle,
  });

  final NodeViewMode mode;
  final List<Node> nodes;
  final ValueChanged<Node> onNodeTap;
  final String emptyMessage;
  final Widget? footer;
  final Set<int>? favoriteIds;
  final ValueChanged<Node>? onFavoriteToggle;

  @override
  Widget build(BuildContext context) {
    if (nodes.isEmpty) {
      return Center(child: Text(emptyMessage));
    }

    switch (mode) {
      case NodeViewMode.list:
        return NodeListView(
          nodes: nodes,
          onNodeTap: onNodeTap,
          footer: footer,
          favoriteIds: favoriteIds,
          onFavoriteToggle: onFavoriteToggle,
        );
      case NodeViewMode.card:
        return NodeCardView(
          nodes: nodes,
          onNodeTap: onNodeTap,
          favoriteIds: favoriteIds,
          onFavoriteToggle: onFavoriteToggle,
        );
      case NodeViewMode.table:
        return NodeTableView(
          nodes: nodes,
          onNodeTap: onNodeTap,
          favoriteIds: favoriteIds,
          onFavoriteToggle: onFavoriteToggle,
        );
      case NodeViewMode.kanban:
        return NodeKanbanView(
          nodes: nodes,
          onNodeTap: onNodeTap,
          favoriteIds: favoriteIds,
          onFavoriteToggle: onFavoriteToggle,
        );
      case NodeViewMode.calendar:
        return NodeCalendarView(
          nodes: nodes,
          onNodeTap: onNodeTap,
          favoriteIds: favoriteIds,
          onFavoriteToggle: onFavoriteToggle,
        );
    }
  }
}
