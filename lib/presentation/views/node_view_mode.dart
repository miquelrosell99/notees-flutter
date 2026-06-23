import 'package:flutter/material.dart';

/// Available ways to display a collection of nodes in the mobile app.
enum NodeViewMode {
  list,
  card,
  table,
}

extension NodeViewModeExt on NodeViewMode {
  String get label {
    switch (this) {
      case NodeViewMode.list:
        return 'List';
      case NodeViewMode.card:
        return 'Cards';
      case NodeViewMode.table:
        return 'Table';
    }
  }

  IconData get icon {
    switch (this) {
      case NodeViewMode.list:
        return Icons.list;
      case NodeViewMode.card:
        return Icons.grid_view;
      case NodeViewMode.table:
        return Icons.table_rows;
    }
  }
}
