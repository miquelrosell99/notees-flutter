import 'package:flutter/material.dart';

import '../views/node_view_mode.dart';

/// Bottom sheet for selecting a node collection view mode.
class ViewModeSheet extends StatelessWidget {
  const ViewModeSheet({
    super.key,
    required this.selected,
  });

  final NodeViewMode selected;

  static Future<NodeViewMode?> show(BuildContext context, NodeViewMode selected) {
    return showModalBottomSheet<NodeViewMode>(
      context: context,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(28)),
      ),
      builder: (context) => ViewModeSheet(selected: selected),
    );
  }

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;

    return SafeArea(
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 16),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(20, 8, 20, 16),
              child: Text(
                'View as',
                style: Theme.of(context).textTheme.titleMedium?.copyWith(
                      fontWeight: FontWeight.w600,
                    ),
              ),
            ),
            ...NodeViewMode.values.map((mode) {
              final isSelected = mode == selected;
              return ListTile(
                leading: Icon(
                  mode.icon,
                  color: isSelected ? colors.primary : colors.onSurfaceVariant,
                ),
                title: Text(
                  mode.label,
                  style: TextStyle(
                    color: isSelected ? colors.primary : null,
                    fontWeight: isSelected ? FontWeight.w600 : null,
                  ),
                ),
                trailing: isSelected
                    ? Icon(Icons.check, color: colors.primary)
                    : null,
                onTap: () => Navigator.of(context).pop(mode),
              );
            }),
          ],
        ),
      ),
    );
  }
}
