import 'package:flutter/material.dart';
import 'package:material_design_icons_flutter/material_design_icons_flutter.dart';

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
      NodeViewMode.list => MdiIcons.viewList,
      NodeViewMode.card => MdiIcons.viewGrid,
      NodeViewMode.table => MdiIcons.tableRow,
      NodeViewMode.kanban => MdiIcons.viewDashboardVariant,
      NodeViewMode.calendar => MdiIcons.calendarMonth,
    };
  }
}
