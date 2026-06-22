import 'package:flutter/material.dart';

import '../../domain/models/search_filters.dart';

/// Immich-style slide-up bottom sheet for editing search filters.
///
/// Shows sections for node type, task state, date range, and sort order.
/// Returns the updated [SearchFilters] when the user taps "Apply".
class FilterBottomSheet extends StatefulWidget {
  const FilterBottomSheet({
    super.key,
    required this.initialFilters,
  });

  final SearchFilters initialFilters;

  static Future<SearchFilters?> show(BuildContext context, SearchFilters filters) {
    return showModalBottomSheet<SearchFilters>(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder: (context) => FilterBottomSheet(initialFilters: filters),
    );
  }

  @override
  State<FilterBottomSheet> createState() => _FilterBottomSheetState();
}

class _FilterBottomSheetState extends State<FilterBottomSheet> {
  late SearchFilters _filters;

  @override
  void initState() {
    super.initState();
    _filters = widget.initialFilters;
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colors = theme.colorScheme;

    return DraggableScrollableSheet(
      initialChildSize: 0.65,
      minChildSize: 0.4,
      maxChildSize: 0.9,
      expand: false,
      builder: (context, scrollController) {
        return Container(
          decoration: BoxDecoration(
            color: colors.surface,
            borderRadius: const BorderRadius.vertical(top: Radius.circular(24)),
          ),
          child: Column(
            children: [
              _buildHandle(colors),
              Expanded(
                child: ListView(
                  controller: scrollController,
                  padding: const EdgeInsets.fromLTRB(20, 8, 20, 20),
                  children: [
                    Text(
                      'Advanced filters',
                      style: theme.textTheme.titleLarge?.copyWith(
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                    const SizedBox(height: 24),
                    _SectionTitle('Node type'),
                    const SizedBox(height: 8),
                    Wrap(
                      spacing: 8,
                      runSpacing: 8,
                      children: NodeType.values.map(_buildNodeTypeChip).toList(),
                    ),
                    const SizedBox(height: 24),
                    _SectionTitle('Task state'),
                    const SizedBox(height: 8),
                    Wrap(
                      spacing: 8,
                      runSpacing: 8,
                      children: TaskState.values.map(_buildTaskStateChip).toList(),
                    ),
                    const SizedBox(height: 24),
                    _SectionTitle('Date range'),
                    const SizedBox(height: 8),
                    _buildDateRangeTile(context),
                    const SizedBox(height: 24),
                    _SectionTitle('Sort by'),
                    const SizedBox(height: 8),
                    _buildSortDropdown(),
                  ],
                ),
              ),
              _buildFooter(colors),
            ],
          ),
        );
      },
    );
  }

  Widget _buildHandle(ColorScheme colors) {
    return Center(
      child: Container(
        margin: const EdgeInsets.only(top: 12, bottom: 8),
        width: 40,
        height: 4,
        decoration: BoxDecoration(
          color: colors.outline.withAlpha((0.3 * 255).round()),
          borderRadius: BorderRadius.circular(2),
        ),
      ),
    );
  }

  Widget _buildNodeTypeChip(NodeType type) {
    final selected = _filters.nodeType == type;
    return ChoiceChip(
      label: Text(type.label),
      selected: selected,
      onSelected: (_) => setState(() => _filters = _filters.copyWith(nodeType: type)),
    );
  }

  Widget _buildTaskStateChip(TaskState state) {
    final selected = _filters.taskState == state;
    final label = state == TaskState.any
        ? 'Any'
        : state == TaskState.open
            ? 'Open'
            : 'Completed';
    return ChoiceChip(
      label: Text(label),
      selected: selected,
      onSelected: (_) => setState(() => _filters = _filters.copyWith(taskState: state)),
    );
  }

  Widget _buildDateRangeTile(BuildContext context) {
    final from = _filters.dateFrom;
    final to = _filters.dateTo;
    final label = from == null && to == null
        ? 'Any date'
        : from != null && to != null
            ? '${_formatDate(from)} – ${_formatDate(to)}'
            : from != null
                ? 'From ${_formatDate(from)}'
                : 'Until ${_formatDate(to!)}';

    return ListTile(
      contentPadding: EdgeInsets.zero,
      title: Text(label),
      trailing: const Icon(Icons.calendar_today),
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(12),
        side: BorderSide(
          color: Theme.of(context).colorScheme.outline.withAlpha((0.2 * 255).round()),
        ),
      ),
      onTap: () => _pickDateRange(context),
    );
  }

  Future<void> _pickDateRange(BuildContext context) async {
    final now = DateTime.now();
    final picked = await showDateRangePicker(
      context: context,
      firstDate: DateTime(now.year - 10),
      lastDate: DateTime(now.year + 1),
      initialDateRange: _filters.dateFrom != null && _filters.dateTo != null
          ? DateTimeRange(start: _filters.dateFrom!, end: _filters.dateTo!)
          : DateTimeRange(start: now, end: now),
    );
    if (picked != null) {
      setState(() {
        _filters = _filters.copyWith(
          dateFrom: picked.start,
          dateTo: picked.end,
        );
      });
    }
  }

  Widget _buildSortDropdown() {
    return DropdownButtonFormField<SortBy>(
      initialValue: _filters.sortBy,
      decoration: const InputDecoration(
        border: OutlineInputBorder(),
        contentPadding: EdgeInsets.symmetric(horizontal: 16, vertical: 12),
      ),
      items: SortBy.values
          .map(
            (sort) => DropdownMenuItem(
              value: sort,
              child: Text(sort.label),
            ),
          )
          .toList(),
      onChanged: (value) {
        if (value != null) {
          setState(() => _filters = _filters.copyWith(sortBy: value));
        }
      },
    );
  }

  Widget _buildFooter(ColorScheme colors) {
    return SafeArea(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Row(
          children: [
            TextButton(
              onPressed: () => setState(() => _filters = const SearchFilters()),
              child: const Text('Reset'),
            ),
            const Spacer(),
            FilledButton(
              onPressed: () => Navigator.of(context).pop(_filters),
              child: const Text('Apply'),
            ),
          ],
        ),
      ),
    );
  }

  String _formatDate(DateTime date) {
    return '${date.year}-${date.month.toString().padLeft(2, '0')}-${date.day.toString().padLeft(2, '0')}';
  }
}

class _SectionTitle extends StatelessWidget {
  const _SectionTitle(this.text);

  final String text;

  @override
  Widget build(BuildContext context) {
    return Text(
      text,
      style: Theme.of(context).textTheme.titleSmall?.copyWith(
            fontWeight: FontWeight.w600,
            color: Theme.of(context).colorScheme.onSurfaceVariant,
          ),
    );
  }
}
