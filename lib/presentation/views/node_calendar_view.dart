import 'package:flutter/material.dart';

import '../../data/models/node.dart';
import 'node_list_view.dart';
import '_view_helpers.dart';

/// Calendar view for a collection of nodes.
///
/// Shows a month grid and places nodes on the date defined by a selected
/// date property (e.g. `write_date`, `task_scheduled`). Tapping a day opens
/// a list of nodes for that date.
class NodeCalendarView extends StatefulWidget {
  const NodeCalendarView({
    super.key,
    required this.nodes,
    required this.onNodeTap,
    this.favoriteUuids,
    this.onFavoriteToggle,
  });

  final List<Node> nodes;
  final ValueChanged<Node> onNodeTap;
  final Set<String>? favoriteUuids;
  final ValueChanged<Node>? onFavoriteToggle;

  @override
  State<NodeCalendarView> createState() => _NodeCalendarViewState();
}

class _NodeCalendarViewState extends State<NodeCalendarView> {
  DateTime _focusedMonth = DateTime.now();
  String? _dateKey;

  List<String> get _availableKeys => collectDatePropertyKeys(widget.nodes);

  @override
  void initState() {
    super.initState();
    _applyDefaultKey();
    _focusedMonth = DateTime(_focusedMonth.year, _focusedMonth.month);
  }

  @override
  void didUpdateWidget(covariant NodeCalendarView oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.nodes != oldWidget.nodes) {
      _applyDefaultKey();
    }
  }

  void _applyDefaultKey() {
    final available = _availableKeys;
    if (available.isEmpty) {
      _dateKey = null;
      return;
    }
    if (_dateKey != null && available.contains(_dateKey)) return;
    final preferred = available.firstWhere(
      (k) => k == 'task_scheduled' || k == 'write_date',
      orElse: () => available.first,
    );
    _dateKey = preferred;
  }

  void _previousMonth() {
    setState(() {
      _focusedMonth = DateTime(_focusedMonth.year, _focusedMonth.month - 1);
    });
  }

  void _nextMonth() {
    setState(() {
      _focusedMonth = DateTime(_focusedMonth.year, _focusedMonth.month + 1);
    });
  }

  Map<DateTime, List<Node>> _buildDateMap() {
    final key = _dateKey;
    final map = <DateTime, List<Node>>{};
    for (final node in widget.nodes) {
      final date = key == null ? null : dateForNode(node, key);
      if (date != null) {
        final day = DateTime(date.year, date.month, date.day);
        map.putIfAbsent(day, () => []).add(node);
      }
    }
    return map;
  }

  Future<void> _openDateKeySelector() async {
    final available = _availableKeys;
    if (available.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('No date properties available')),
      );
      return;
    }

    final result = await showModalBottomSheet<String>(
      context: context,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(28)),
      ),
      builder: (ctx) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(20, 16, 20, 8),
              child: Text(
                'Date property',
                style: Theme.of(context).textTheme.titleMedium?.copyWith(
                      fontWeight: FontWeight.w600,
                    ),
              ),
            ),
            ...available.map((key) {
              final selected = key == _dateKey;
              return ListTile(
                title: Text(propertyDisplayName(key)),
                trailing: selected ? Icon(Icons.check, color: Theme.of(context).colorScheme.primary) : null,
                onTap: () => Navigator.of(ctx).pop(key),
              );
            }),
          ],
        ),
      ),
    );

    if (result != null) {
      setState(() => _dateKey = result);
    }
  }

  void _openDaySheet(DateTime date, List<Node> nodes) {
    final formatted = '${date.year.toString().padLeft(4, '0')}-'
        '${date.month.toString().padLeft(2, '0')}-'
        '${date.day.toString().padLeft(2, '0')}';
    showModalBottomSheet(
      context: context,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(28)),
      ),
      builder: (ctx) => SafeArea(
        child: Padding(
          padding: const EdgeInsets.symmetric(vertical: 16),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Padding(
                padding: const EdgeInsets.fromLTRB(20, 8, 20, 12),
                child: Row(
                  children: [
                    Text(
                      formatted,
                      style: Theme.of(context).textTheme.titleMedium?.copyWith(
                            fontWeight: FontWeight.w600,
                          ),
                    ),
                    const Spacer(),
                    Text(
                      '${nodes.length} items',
                      style: Theme.of(context).textTheme.labelMedium?.copyWith(
                            color: Theme.of(context).colorScheme.onSurfaceVariant,
                          ),
                    ),
                  ],
                ),
              ),
              Flexible(
                child: NodeListView(
                  nodes: nodes,
                  onNodeTap: (node) {
                    Navigator.of(ctx).pop();
                    widget.onNodeTap(node);
                  },
                  shrinkWrap: true,
                  favoriteUuids: widget.favoriteUuids,
                  onFavoriteToggle: widget.onFavoriteToggle,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    final dateMap = _buildDateMap();

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 8, 8, 0),
          child: Row(
            children: [
              Text(
                '${_monthName(_focusedMonth.month)} ${_focusedMonth.year}',
                style: Theme.of(context).textTheme.titleMedium?.copyWith(
                      fontWeight: FontWeight.w600,
                    ),
              ),
              const Spacer(),
              IconButton(
                icon: const Icon(Icons.chevron_left),
                tooltip: 'Previous month',
                onPressed: _previousMonth,
              ),
              IconButton(
                icon: const Icon(Icons.chevron_right),
                tooltip: 'Next month',
                onPressed: _nextMonth,
              ),
              IconButton(
                icon: const Icon(Icons.calendar_today_outlined),
                tooltip: 'Select date property',
                onPressed: _openDateKeySelector,
              ),
            ],
          ),
        ),
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
          child: Row(
            children: ['M', 'T', 'W', 'T', 'F', 'S', 'S'].map((d) {
              return Expanded(
                child: Center(
                  child: Text(
                    d,
                    style: Theme.of(context).textTheme.labelSmall?.copyWith(
                          color: colors.onSurfaceVariant,
                          fontWeight: FontWeight.w600,
                        ),
                  ),
                ),
              );
            }).toList(),
          ),
        ),
        Expanded(
          child: _buildMonthGrid(context, dateMap),
        ),
      ],
    );
  }

  Widget _buildMonthGrid(BuildContext context, Map<DateTime, List<Node>> dateMap) {
    final firstDay = DateTime(_focusedMonth.year, _focusedMonth.month, 1);
    // Monday-based week: subtract (weekday - 1) days.
    final startOffset = firstDay.weekday - 1;
    final startDate = firstDay.subtract(Duration(days: startOffset));
    final daysInMonth = _daysInMonth(_focusedMonth.year, _focusedMonth.month);
    final totalCells = ((startOffset + daysInMonth) / 7).ceil() * 7;

    return GridView.builder(
      padding: const EdgeInsets.all(12),
      gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
        crossAxisCount: 7,
        childAspectRatio: 0.85,
      ),
      itemCount: totalCells,
      itemBuilder: (context, index) {
        final date = startDate.add(Duration(days: index));
        final inMonth = date.month == _focusedMonth.month;
        final nodes = dateMap[DateTime(date.year, date.month, date.day)] ?? [];
        return _DayCell(
          date: date,
          inMonth: inMonth,
          nodes: nodes,
          onTap: nodes.isEmpty ? null : () => _openDaySheet(date, nodes),
        );
      },
    );
  }

  String _monthName(int month) {
    return switch (month) {
      1 => 'January',
      2 => 'February',
      3 => 'March',
      4 => 'April',
      5 => 'May',
      6 => 'June',
      7 => 'July',
      8 => 'August',
      9 => 'September',
      10 => 'October',
      11 => 'November',
      12 => 'December',
      _ => '',
    };
  }

  int _daysInMonth(int year, int month) {
    return DateTime(year, month + 1, 0).day;
  }
}

class _DayCell extends StatelessWidget {
  const _DayCell({
    required this.date,
    required this.inMonth,
    required this.nodes,
    this.onTap,
  });

  final DateTime date;
  final bool inMonth;
  final List<Node> nodes;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    final isToday = _isToday(date);

    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(12),
      child: Container(
        margin: const EdgeInsets.all(2),
        decoration: BoxDecoration(
          color: isToday ? colors.primaryContainer.withAlpha((0.35 * 255).round()) : null,
          borderRadius: BorderRadius.circular(12),
          border: Border.all(
            color: isToday ? colors.primary : colors.outlineVariant.withAlpha((0.3 * 255).round()),
            width: isToday ? 1.5 : 0.5,
          ),
        ),
        child: Column(
          children: [
            Padding(
              padding: const EdgeInsets.only(top: 4),
              child: Text(
                '${date.day}',
                style: Theme.of(context).textTheme.bodySmall?.copyWith(
                      color: inMonth ? colors.onSurface : colors.onSurfaceVariant.withAlpha((0.6 * 255).round()),
                      fontWeight: isToday ? FontWeight.w700 : FontWeight.w500,
                    ),
              ),
            ),
            if (nodes.isNotEmpty) ...[
              const SizedBox(height: 2),
              Flexible(
                child: Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 4),
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Flexible(
                        child: Text(
                          '${nodes.length}',
                          style: Theme.of(context).textTheme.labelSmall?.copyWith(
                                color: colors.primary,
                                fontWeight: FontWeight.w700,
                              ),
                        ),
                      ),
                      if (nodes.length <= 3)
                        Row(
                          mainAxisAlignment: MainAxisAlignment.center,
                          children: nodes.take(3).map((_) {
                            return Container(
                              width: 4,
                              height: 4,
                              margin: const EdgeInsets.symmetric(horizontal: 1),
                              decoration: BoxDecoration(
                                color: colors.primary,
                                shape: BoxShape.circle,
                              ),
                            );
                          }).toList(),
                        ),
                    ],
                  ),
                ),
              ),
            ],
          ],
        ),
      ),
    );
  }

  bool _isToday(DateTime d) {
    final now = DateTime.now();
    return d.year == now.year && d.month == now.month && d.day == now.day;
  }
}
