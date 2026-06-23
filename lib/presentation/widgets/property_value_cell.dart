import 'package:flutter/material.dart';

import '../../data/models/property.dart';

/// Displays a property value (read-only for now).
class PropertyValueCell extends StatelessWidget {
  const PropertyValueCell({
    super.key,
    required this.property,
    required this.values,
  });

  final Property property;
  final List<dynamic> values;

  @override
  Widget build(BuildContext context) {
    final display = _displayValue();
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          property.name,
          style: Theme.of(context).textTheme.labelSmall?.copyWith(
                color: Theme.of(context).colorScheme.onSurfaceVariant,
              ),
        ),
        const SizedBox(height: 4),
        Text(
          display.isEmpty ? '—' : display,
          style: Theme.of(context).textTheme.bodyMedium,
        ),
      ],
    );
  }

  String _displayValue() {
    if (values.isEmpty) return '';

    switch (property.type) {
      case 'selection':
        return values.map((v) {
          final lineId = v is Map ? v['selection_line_id'] ?? v['id'] : v;
          final option = property.options.firstWhere(
            (o) => o.id == lineId,
            orElse: () => SelectionOption(id: lineId as int? ?? 0, name: 'Unknown'),
          );
          return option.name;
        }).join(', ');
      case 'boolean':
        return values.first.toString();
      case 'date':
        return values.map((v) => v.toString()).join(', ');
      case 'node':
      case 'image':
      case 'text':
        return values.map((v) {
          if (v is Map) return v['target_node_id']?.toString() ?? v.toString();
          return v.toString();
        }).join(', ');
      default:
        return values.map((v) => v.toString()).join(', ');
    }
  }
}
