/// Recurrence rule expansion for task reminders.
///
/// Mirrors the server-side helpers in `app/features/tasks/service.py`: the
/// rule JSON stored by `task.setRecurrence` uses the `TaskRecurrence` entity
/// field names (snake_case), and occurrence computation follows the same
/// semantics so local reminders fire on the same dates the server would
/// generate.
library;

/// Recurrence rule attached to a task node.
///
/// Parsed from the JSON payload of `task.setRecurrence`:
/// `{rule_type, interval, weekdays, day_of_month, week_of_month, month,
/// end_after_count, end_date, active}`.
class RecurrenceRule {
  const RecurrenceRule({
    this.ruleType = 'daily',
    this.interval = 1,
    this.weekdays,
    this.dayOfMonth,
    this.weekOfMonth,
    this.month,
    this.endAfterCount,
    this.endDate,
    this.active = true,
  });

  factory RecurrenceRule.fromJson(Map<String, dynamic> json) {
    return RecurrenceRule(
      ruleType: (json['rule_type'] as String? ?? 'daily').toLowerCase(),
      interval: (json['interval'] as num?)?.toInt() ?? 1,
      weekdays: (json['weekdays'] as List<dynamic>?)
          ?.map((d) => (d as num).toInt())
          .toList(),
      dayOfMonth: (json['day_of_month'] as num?)?.toInt(),
      weekOfMonth: (json['week_of_month'] as num?)?.toInt(),
      month: (json['month'] as num?)?.toInt(),
      endAfterCount: (json['end_after_count'] as num?)?.toInt(),
      endDate: _parseDate(json['end_date'] as String?),
      active: json['active'] as bool? ?? true,
    );
  }

  /// Recurrence type: daily, weekday, weekly, monthly, yearly.
  final String ruleType;

  /// Number of periods between occurrences (minimum 1).
  final int interval;

  /// ISO weekdays (1=Monday .. 7=Sunday) for weekly/monthly rules.
  final List<int>? weekdays;

  /// Day of the month for monthly/yearly rules.
  final int? dayOfMonth;

  /// Nth occurrence of a weekday in the month; -1 for last, 1-4 otherwise.
  final int? weekOfMonth;

  /// Month for yearly rules.
  final int? month;

  /// Stop recurrence after this many completions.
  final int? endAfterCount;

  /// Stop recurrence after this date (inclusive), date-only.
  final DateTime? endDate;

  final bool active;
}

/// Computes the next occurrence strictly after [after] for [rule].
///
/// Returns null if the rule type is not supported.
DateTime? nextOccurrence(RecurrenceRule rule, DateTime after) {
  final interval = rule.interval < 1 ? 1 : rule.interval;
  switch (rule.ruleType) {
    case 'daily':
      return DateTime(after.year, after.month, after.day + interval);
    case 'weekday':
      return _nextWeekday(after);
    case 'weekly':
      return _nextWeekly(after, interval, rule.weekdays);
    case 'monthly':
      return _nextMonthly(
        after,
        interval,
        rule.dayOfMonth,
        rule.weekOfMonth,
        rule.weekdays,
      );
    case 'yearly':
      return _nextYearly(after, interval, rule.month, rule.dayOfMonth);
  }
  return null;
}

/// Whether the recurrence should stop based on the completion count or the
/// end date. Mirrors the server's `has_ended`.
bool hasEnded(RecurrenceRule rule, int completedCount, DateTime currentDate) {
  final endAfterCount = rule.endAfterCount;
  if (endAfterCount != null && completedCount >= endAfterCount) return true;
  final endDate = rule.endDate;
  if (endDate != null &&
      _dateOnly(currentDate).isAfter(_dateOnly(endDate))) {
    return true;
  }
  return false;
}

/// Expands [rule] into up to [count] occurrence dates starting at [first]
/// (inclusive), each computed from the previous one.
///
/// [completedCount] is the number of completions already recorded, used to
/// honor `end_after_count`. Inactive rules and exhausted end conditions
/// yield an empty list.
List<DateTime> occurrenceSeries(
  RecurrenceRule rule,
  DateTime first, {
  int count = 5,
  int completedCount = 0,
}) {
  if (!rule.active || count <= 0) return const [];
  final dates = <DateTime>[];
  var current = first;
  while (dates.length < count) {
    if (hasEnded(rule, completedCount + dates.length, current)) break;
    dates.add(current);
    final next = nextOccurrence(rule, current);
    // Defensive: a rule that does not advance would loop forever.
    if (next == null || !next.isAfter(current)) break;
    current = next;
  }
  return dates;
}

DateTime _nextWeekday(DateTime d) {
  var next = DateTime(d.year, d.month, d.day + 1);
  while (next.weekday >= DateTime.saturday) {
    next = DateTime(next.year, next.month, next.day + 1);
  }
  return next;
}

DateTime _nextWeekly(DateTime d, int interval, List<int>? weekdays) {
  if (weekdays == null || weekdays.isEmpty) {
    return DateTime(d.year, d.month, d.day + 7 * interval);
  }
  final sortedDays = List<int>.from(weekdays)..sort();
  // Search up to interval+1 weeks to find the next matching weekday.
  for (var weekOffset = 0; weekOffset < interval + 2; weekOffset++) {
    final base = DateTime(d.year, d.month, d.day + 7 * weekOffset);
    for (final day in sortedDays) {
      final candidate = _adjustToWeekday(base, day);
      if (candidate.isAfter(d)) {
        // When weekOffset is less than interval-1, only accept days that are
        // at least interval weeks away from the base date.
        final weeksApart = _dateOnly(candidate).difference(_dateOnly(d)).inDays ~/ 7;
        if (weeksApart >= interval - 1) return candidate;
      }
    }
  }
  // Fallback: same weekday as the base date, interval weeks later.
  return DateTime(d.year, d.month, d.day + 7 * interval);
}

/// Returns the date of [targetIsoWeekday] in the same week as [d]
/// (Dart weekday: Monday=1, Sunday=7, matching the ISO convention).
DateTime _adjustToWeekday(DateTime d, int targetIsoWeekday) {
  final delta = targetIsoWeekday - d.weekday;
  return DateTime(d.year, d.month, d.day + delta);
}

DateTime _nextMonthly(
  DateTime d,
  int interval,
  int? dayOfMonth,
  int? weekOfMonth,
  List<int>? weekdays,
) {
  if (weekOfMonth != null && weekdays != null && weekdays.isNotEmpty) {
    return _nextMonthlyByWeekday(d, interval, weekOfMonth, weekdays);
  }
  final targetDay = dayOfMonth ?? d.day;
  final (year, month) = _addMonths(d.year, d.month, interval);
  final lastDay = _lastDayOfMonth(year, month);
  return DateTime(year, month, targetDay < lastDay ? targetDay : lastDay);
}

DateTime _nextMonthlyByWeekday(
  DateTime d,
  int interval,
  int weekOfMonth,
  List<int> weekdays,
) {
  final (year, month) = _addMonths(d.year, d.month, interval);
  final sortedDays = List<int>.from(weekdays)..sort();

  final candidates = <DateTime>[];
  for (final targetDay in sortedDays) {
    final candidate = _nthWeekdayOfMonth(year, month, targetDay, weekOfMonth);
    if (candidate != null) candidates.add(candidate);
  }

  if (candidates.isEmpty) {
    // Fallback to the last matching weekday of the month.
    final candidate = _nthWeekdayOfMonth(year, month, sortedDays.first, -1);
    if (candidate != null) return candidate;
    // Unreachable for valid ISO weekdays; keep the day-based behavior.
    return _nextMonthly(d, interval, null, null, null);
  }

  return candidates.reduce((a, b) => a.isBefore(b) ? a : b);
}

/// Returns the Nth occurrence of [isoWeekday] in the given month.
///
/// [n] > 0 counts from the start of the month; [n] == -1 returns the last
/// occurrence. Returns null if it does not exist.
DateTime? _nthWeekdayOfMonth(int year, int month, int isoWeekday, int n) {
  final lastDay = _lastDayOfMonth(year, month);
  final matches = <DateTime>[
    for (var day = 1; day <= lastDay; day++)
      if (DateTime(year, month, day).weekday == isoWeekday)
        DateTime(year, month, day),
  ];
  if (matches.isEmpty) return null;
  if (n == -1) return matches.last;
  if (n > 0 && n <= matches.length) return matches[n - 1];
  return null;
}

DateTime _nextYearly(DateTime d, int interval, int? month, int? dayOfMonth) {
  final targetMonth = month ?? d.month;
  final targetDay = dayOfMonth ?? d.day;
  final year = d.year + interval;
  final lastDay = _lastDayOfMonth(year, targetMonth);
  return DateTime(year, targetMonth, targetDay < lastDay ? targetDay : lastDay);
}

/// Adds [months] to (year, month), wrapping December to January.
(int, int) _addMonths(int year, int month, int months) {
  final total = year * 12 + (month - 1) + months;
  return (total ~/ 12, total % 12 + 1);
}

int _lastDayOfMonth(int year, int month) {
  // Day 0 of the next month is the last day of this one.
  return DateTime(year, month + 1, 0).day;
}

DateTime _dateOnly(DateTime d) => DateTime(d.year, d.month, d.day);

DateTime? _parseDate(String? value) {
  if (value == null || value.isEmpty) return null;
  return DateTime.tryParse(value);
}
