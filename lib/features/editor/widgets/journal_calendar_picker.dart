import 'package:flutter/material.dart';
import 'package:material_design_icons_flutter/material_design_icons_flutter.dart';
import 'package:flutter/services.dart';

/// Narrow weekday label for the calendar grid header. [index] follows the
/// Material convention (0 = Sunday, 6 = Saturday); the app is English-only,
/// so single letters are used.
String calendarWeekdayLabel(int index) {
  return switch (index % 7) {
    DateTime.monday => 'M',
    DateTime.tuesday => 'T',
    DateTime.wednesday => 'W',
    DateTime.thursday => 'T',
    DateTime.friday => 'F',
    DateTime.saturday => 'S',
    _ => 'S', // Sunday (index 0)
  };
}

/// Number of empty cells before the 1st of [month] in a month grid whose
/// first column is [firstDayOfWeek] (Material convention: 0 = Sunday).
int calendarLeadingPadding(int year, int month, int firstDayOfWeek) {
  final firstWeekday = DateTime(year, month, 1).weekday; // 1 = Monday
  return (firstWeekday - firstDayOfWeek + 7) % 7;
}

/// Month-grid calendar for jumping to a daily journal, mirroring the web
/// client's CalendarPopup: weekday header, chevron month paging, a dot on
/// days whose daily note already exists, and the current day highlighted.
class JournalCalendarPicker extends StatefulWidget {
  const JournalCalendarPicker({
    super.key,
    required this.initialDate,
    required this.highlightedDates,
    required this.onDateChanged,
  });

  final DateTime initialDate;
  final Set<DateTime> highlightedDates;
  final ValueChanged<DateTime> onDateChanged;

  @override
  State<JournalCalendarPicker> createState() => JournalCalendarPickerState();
}

class JournalCalendarPickerState extends State<JournalCalendarPicker> {
  late DateTime _focusedMonth = DateTime(
    widget.initialDate.year,
    widget.initialDate.month,
  );

  /// Resets the grid to the current month (the sheet's "Today" shortcut).
  void jumpToCurrentMonth() {
    final now = DateTime.now();
    if (now.year == _focusedMonth.year && now.month == _focusedMonth.month) {
      return;
    }
    setState(() => _focusedMonth = DateTime(now.year, now.month));
  }

  bool _hasEntry(DateTime date) {
    return widget.highlightedDates.contains(DateTime(date.year, date.month, date.day));
  }

  void _shiftMonth(int delta) {
    HapticFeedback.lightImpact();
    setState(() {
      _focusedMonth = DateTime(_focusedMonth.year, _focusedMonth.month + delta);
    });
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colors = theme.colorScheme;
    final firstDayOfWeek =
        Localizations.of<MaterialLocalizations>(context, MaterialLocalizations)
            ?.firstDayOfWeekIndex ??
        0;

    final daysInMonth = DateUtils.getDaysInMonth(_focusedMonth.year, _focusedMonth.month);
    final leadingPadding = calendarLeadingPadding(
      _focusedMonth.year,
      _focusedMonth.month,
      firstDayOfWeek,
    );

    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 20),
          child: Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              IconButton(
                icon: Icon(MdiIcons.chevronLeft),
                tooltip: 'Previous month',
                onPressed: () => _shiftMonth(-1),
              ),
              Text(
                '${_monthName(_focusedMonth.month)} ${_focusedMonth.year}',
                style: theme.textTheme.titleMedium?.copyWith(
                  fontWeight: FontWeight.w600,
                ),
              ),
              IconButton(
                icon: Icon(MdiIcons.chevronRight),
                tooltip: 'Next month',
                onPressed: () => _shiftMonth(1),
              ),
            ],
          ),
        ),
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 12),
          child: Row(
            children: [
              for (var i = 0; i < 7; i++)
                Expanded(
                  child: Center(
                    child: Text(
                      calendarWeekdayLabel((firstDayOfWeek + i) % 7),
                      style: theme.textTheme.labelSmall?.copyWith(
                            color: colors.onSurfaceVariant,
                            fontWeight: FontWeight.w600,
                          ),
                    ),
                  ),
                ),
            ],
          ),
        ),
        const SizedBox(height: 8),
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 12),
          child: GridView.count(
            shrinkWrap: true,
            crossAxisCount: 7,
            childAspectRatio: 1,
            physics: const NeverScrollableScrollPhysics(),
            children: [
              for (var i = 0; i < leadingPadding; i++) const SizedBox.shrink(),
              for (var day = 1; day <= daysInMonth; day++)
                _buildDayCell(day, colors, theme),
            ],
          ),
        ),
        const SizedBox(height: 12),
        Row(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Container(
              width: 8,
              height: 8,
              decoration: BoxDecoration(
                color: colors.primary,
                shape: BoxShape.circle,
              ),
            ),
            const SizedBox(width: 6),
            Text(
              'Has entry',
              style: theme.textTheme.bodySmall,
            ),
          ],
        ),
        const SizedBox(height: 8),
      ],
    );
  }

  Widget _buildDayCell(int day, ColorScheme colors, ThemeData theme) {
    final date = DateTime(_focusedMonth.year, _focusedMonth.month, day);
    final hasEntry = _hasEntry(date);
    final isToday = DateUtils.isSameDay(date, DateTime.now());

    return InkWell(
      onTap: () => widget.onDateChanged(date),
      borderRadius: BorderRadius.circular(20),
      child: Container(
        margin: const EdgeInsets.all(2),
        decoration: BoxDecoration(
          color: isToday ? colors.primaryContainer : null,
          borderRadius: BorderRadius.circular(20),
        ),
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Text(
              '$day',
              style: theme.textTheme.bodyMedium?.copyWith(
                    color: isToday
                        ? colors.onPrimaryContainer
                        : colors.onSurface,
                    fontWeight: isToday ? FontWeight.w700 : FontWeight.w500,
                  ),
            ),
            if (hasEntry)
              Container(
                width: 5,
                height: 5,
                margin: const EdgeInsets.only(top: 2),
                decoration: BoxDecoration(
                  color: colors.primary,
                  shape: BoxShape.circle,
                ),
              ),
          ],
        ),
      ),
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
}
