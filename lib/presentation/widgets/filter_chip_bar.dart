import 'package:flutter/material.dart';

import '../../domain/models/search_filters.dart';

/// Horizontal scrollable bar that displays active search filters as deletable chips.
class FilterChipBar extends StatelessWidget {
  const FilterChipBar({
    super.key,
    required this.filters,
    required this.onChanged,
  });

  final SearchFilters filters;
  final ValueChanged<SearchFilters> onChanged;

  @override
  Widget build(BuildContext context) {
    final chips = _buildChips();
    if (chips.isEmpty) return const SizedBox.shrink();

    return SizedBox(
      height: 44,
      child: ListView.separated(
        scrollDirection: Axis.horizontal,
        padding: const EdgeInsets.symmetric(horizontal: 16),
        itemCount: chips.length,
        separatorBuilder: (_, index) => const SizedBox(width: 8),
        itemBuilder: (_, index) => chips[index],
      ),
    );
  }

  List<Widget> _buildChips() {
    final chips = <Widget>[];

    if (filters.nodeType != NodeType.any) {
      chips.add(_FilterChip(
        label: filters.nodeType.label,
        onDeleted: () => onChanged(filters.copyWith(nodeType: NodeType.any)),
      ));
    }

    if (filters.taskState != TaskState.any) {
      chips.add(_FilterChip(
        label: filters.taskState == TaskState.open ? 'Open tasks' : 'Completed tasks',
        onDeleted: () => onChanged(filters.copyWith(taskState: TaskState.any)),
      ));
    }

    if (filters.dateFrom != null || filters.dateTo != null) {
      final label = filters.dateFrom != null && filters.dateTo != null
          ? '${_formatDate(filters.dateFrom!)} – ${_formatDate(filters.dateTo!)}'
          : filters.dateFrom != null
              ? 'From ${_formatDate(filters.dateFrom!)}'
              : 'Until ${_formatDate(filters.dateTo!)}';
      chips.add(_FilterChip(
        label: label,
        onDeleted: () => onChanged(filters.copyWith(dateFrom: null, dateTo: null)),
      ));
    }

    if (filters.sortBy != SortBy.relevance) {
      chips.add(_FilterChip(
        label: filters.sortBy.label,
        onDeleted: () => onChanged(filters.copyWith(sortBy: SortBy.relevance)),
      ));
    }

    return chips;
  }

  String _formatDate(DateTime date) {
    return '${date.year}-${date.month.toString().padLeft(2, '0')}-${date.day.toString().padLeft(2, '0')}';
  }
}

class _FilterChip extends StatelessWidget {
  const _FilterChip({
    required this.label,
    required this.onDeleted,
  });

  final String label;
  final VoidCallback onDeleted;

  @override
  Widget build(BuildContext context) {
    return Chip(
      label: Text(label),
      deleteIcon: const Icon(Icons.close, size: 18),
      onDeleted: onDeleted,
      padding: EdgeInsets.zero,
    );
  }
}
