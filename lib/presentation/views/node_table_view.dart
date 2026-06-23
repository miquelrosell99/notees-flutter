import 'package:flutter/material.dart';

import '../../data/models/node.dart';

/// Simple table view for a collection of nodes.
class NodeTableView extends StatelessWidget {
  const NodeTableView({
    super.key,
    required this.nodes,
    required this.onNodeTap,
  });

  final List<Node> nodes;
  final ValueChanged<Node> onNodeTap;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;

    return SingleChildScrollView(
      scrollDirection: Axis.horizontal,
      child: DataTable(
        columns: const [
          DataColumn(label: Text('Name')),
          DataColumn(label: Text('Type')),
          DataColumn(label: Text('Modified')),
        ],
        rows: nodes.map((node) {
          return DataRow(
            cells: [
              DataCell(
                Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Icon(
                      _iconForNode(node),
                      size: 18,
                      color: colors.onSurfaceVariant,
                    ),
                    const SizedBox(width: 8),
                    Flexible(child: Text(node.displayName)),
                  ],
                ),
                onTap: () => onNodeTap(node),
              ),
              DataCell(Text(_typeLabel(node))),
              DataCell(Text(_formatDate(node.writeDate))),
            ],
          );
        }).toList(),
      ),
    );
  }

  String _typeLabel(Node node) {
    if (node.isJournal) return 'Journal';
    if (node.isTask) return 'Task';
    if (node.isPage) return 'Page';
    return 'Block';
  }

  String _formatDate(String? date) {
    if (date == null || date.isEmpty) return '-';
    final parsed = DateTime.tryParse(date);
    if (parsed == null) return date;
    return '${parsed.year}-${parsed.month.toString().padLeft(2, '0')}-${parsed.day.toString().padLeft(2, '0')}';
  }

  IconData _iconForNode(Node node) {
    if (node.isJournal) return Icons.calendar_today_outlined;
    if (node.isTask) return Icons.check_circle_outline;
    return node.icon?.isNotEmpty == true ? Icons.description_outlined : Icons.description_outlined;
  }
}
