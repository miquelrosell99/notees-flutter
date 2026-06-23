import 'package:flutter/material.dart';

/// Available ways to display a collection of nodes in the mobile app.
enum NodeViewMode {
  list,
  card,
  table,
  kanban,
  calendar,
}

extension NodeViewModeExt on NodeViewMode {
  String get label {
    return switch (this) {
      NodeViewMode.list => 'List',
      NodeViewMode.card => 'Cards',
      NodeViewMode.table => 'Table',
      NodeViewMode.kanban => 'Kanban',
      NodeViewMode.calendar => 'Calendar',
    };
  }

  IconData get icon {
    return switch (this) {
      NodeViewMode.list => Icons.list,
      NodeViewMode.card => Icons.grid_view,
      NodeViewMode.table => Icons.table_rows,
      NodeViewMode.kanban => Icons.view_kanban,
      NodeViewMode.calendar => Icons.calendar_month,
    };
  }
}
