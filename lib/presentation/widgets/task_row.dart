import 'package:flutter/material.dart';
import 'package:material_design_icons_flutter/material_design_icons_flutter.dart';

/// Humanizes a task due date relative to today: 'Today', 'Tomorrow',
/// the weekday name within the coming week, otherwise a short date.
String humanizeTaskDueDate(DateTime date, {DateTime? now}) {
  final reference = now ?? DateTime.now();
  final today = DateTime(reference.year, reference.month, reference.day);
  final day = DateTime(date.year, date.month, date.day);
  final diff = day.difference(today).inDays;
  if (diff == 0) return 'Today';
  if (diff == 1) return 'Tomorrow';
  if (diff == -1) return 'Yesterday';
  if (diff > 1 && diff < 7) return _weekdayName(day.weekday);
  final month = _shortMonthName(day.month);
  if (day.year == reference.year) return '$month ${day.day}';
  return '$month ${day.day}, ${day.year}';
}

String _weekdayName(int weekday) {
  return switch (weekday) {
    DateTime.monday => 'Monday',
    DateTime.tuesday => 'Tuesday',
    DateTime.wednesday => 'Wednesday',
    DateTime.thursday => 'Thursday',
    DateTime.friday => 'Friday',
    DateTime.saturday => 'Saturday',
    _ => 'Sunday',
  };
}

String _shortMonthName(int month) {
  return switch (month) {
    1 => 'Jan',
    2 => 'Feb',
    3 => 'Mar',
    4 => 'Apr',
    5 => 'May',
    6 => 'Jun',
    7 => 'Jul',
    8 => 'Aug',
    9 => 'Sep',
    10 => 'Oct',
    11 => 'Nov',
    _ => 'Dec',
  };
}

/// A single task row with a circular completion checkbox, an animated
/// completion state (strikethrough + muted color), and a humanized
/// due-date pill.
///
/// Tapping the checkbox flips the local visual state immediately, starts
/// [onToggleComplete] so the parent can persist in the background, and —
/// after the animation (~200 ms) plus a short hold (~300 ms) — calls
/// [onAnimatedOut] so the parent can remove the row without a full reload.
/// If the persist reports failure, the row reverts its visual state instead
/// of animating out (provided the parent skipped removal).
class TaskRow extends StatefulWidget {
  const TaskRow({
    super.key,
    required this.title,
    required this.completed,
    this.dueDate,
    this.selectionMode = false,
    this.selected = false,
    this.onToggleComplete,
    this.onAnimatedOut,
    this.onToggleSelected,
    this.onTap,
    this.onLongPress,
    this.onShowDetails,
  });

  final String title;

  /// Whether the task is completed when the row first renders.
  final bool completed;

  final DateTime? dueDate;

  /// When true, the checkbox toggles multi-select instead of completion.
  final bool selectionMode;
  final bool selected;

  /// Fired immediately when the completion checkbox is tapped. Returns
  /// whether the persist succeeded; on failure the row reverts its
  /// visual state.
  final Future<bool> Function()? onToggleComplete;

  /// Fired after the completion animation finishes.
  final VoidCallback? onAnimatedOut;

  final VoidCallback? onToggleSelected;
  final VoidCallback? onTap;
  final VoidCallback? onLongPress;
  final VoidCallback? onShowDetails;

  @override
  State<TaskRow> createState() => _TaskRowState();
}

class _TaskRowState extends State<TaskRow> {
  late bool _animatedCompleted = widget.completed;
  bool _animatingOut = false;

  @override
  void didUpdateWidget(covariant TaskRow oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.completed != widget.completed && !_animatingOut) {
      _animatedCompleted = widget.completed;
    }
  }

  void _handleCheckTap() {
    if (widget.selectionMode) {
      widget.onToggleSelected?.call();
      return;
    }
    final persist = widget.onToggleComplete;
    if (_animatingOut || persist == null) return;
    setState(() {
      _animatedCompleted = !_animatedCompleted;
      _animatingOut = true;
    });
    persist().then((success) {
      // Revert only when the row is still around, i.e. the parent skipped
      // removal because the persist failed.
      if (!mounted || success) return;
      setState(() {
        _animatedCompleted = widget.completed;
        _animatingOut = false;
      });
    });
    Future.delayed(const Duration(milliseconds: 500), () {
      if (!mounted) return;
      widget.onAnimatedOut?.call();
    });
  }

  bool _isOverdue() {
    final due = widget.dueDate;
    if (due == null || _animatedCompleted) return false;
    final now = DateTime.now();
    final today = DateTime(now.year, now.month, now.day);
    return DateTime(due.year, due.month, due.day).isBefore(today);
  }

  Widget _buildCheckbox(ColorScheme colors, bool checked) {
    return SizedBox(
      width: 44,
      height: 44,
      child: InkWell(
        customBorder: const CircleBorder(),
        onTap: _handleCheckTap,
        child: Center(
          child: AnimatedContainer(
            duration: const Duration(milliseconds: 200),
            curve: Curves.easeInOutCubic,
            width: 22,
            height: 22,
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              color: checked ? colors.primary : Colors.transparent,
              border: Border.all(
                color: checked ? colors.primary : colors.onSurfaceVariant,
                width: 2,
              ),
            ),
            child: checked
                ? Icon(Icons.check, size: 14, color: colors.onPrimary)
                : null,
          ),
        ),
      ),
    );
  }

  Widget _buildDuePill(ThemeData theme, ColorScheme colors) {
    final overdue = _isOverdue();
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
      decoration: BoxDecoration(
        color: colors.surfaceContainerHighest,
        borderRadius: BorderRadius.circular(8),
      ),
      child: Text(
        humanizeTaskDueDate(widget.dueDate!),
        style: theme.textTheme.labelSmall?.copyWith(
          fontWeight: FontWeight.w600,
          color: overdue ? colors.error : colors.onSurfaceVariant,
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colors = theme.colorScheme;
    final checked = widget.selectionMode ? widget.selected : _animatedCompleted;

    return InkWell(
      onTap: widget.onTap,
      onLongPress: widget.onLongPress,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
        child: Row(
          children: [
            _buildCheckbox(colors, checked),
            const SizedBox(width: 4),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  AnimatedDefaultTextStyle(
                    duration: const Duration(milliseconds: 200),
                    curve: Curves.easeInOutCubic,
                    style: (theme.textTheme.bodyLarge ?? const TextStyle()).copyWith(
                      fontWeight: FontWeight.w400,
                      color: _animatedCompleted
                          ? colors.onSurfaceVariant
                          : colors.onSurface,
                      decoration: _animatedCompleted
                          ? TextDecoration.lineThrough
                          : TextDecoration.none,
                      decorationColor: colors.onSurfaceVariant,
                    ),
                    child: Text(
                      widget.title,
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                    ),
                  ),
                  if (widget.dueDate != null) ...[
                    const SizedBox(height: 6),
                    _buildDuePill(theme, colors),
                  ],
                ],
              ),
            ),
            if (!widget.selectionMode && widget.onShowDetails != null)
              IconButton(
                icon: Icon(MdiIcons.informationOutline, color: colors.onSurfaceVariant),
                tooltip: 'Details',
                onPressed: widget.onShowDetails,
              ),
          ],
        ),
      ),
    );
  }
}
