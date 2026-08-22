import 'package:flutter_test/flutter_test.dart';
import 'package:notees/domain/services/recurrence_expansion.dart';

void main() {
  group('RecurrenceRule.fromJson', () {
    test('parses the task.setRecurrence rule shape', () {
      final rule = RecurrenceRule.fromJson({
        'rule_type': 'weekly',
        'interval': 2,
        'weekdays': [1, 5],
        'day_of_month': 15,
        'week_of_month': -1,
        'month': 6,
        'end_after_count': 10,
        'end_date': '2026-12-31',
        'active': true,
      });

      expect(rule.ruleType, 'weekly');
      expect(rule.interval, 2);
      expect(rule.weekdays, [1, 5]);
      expect(rule.dayOfMonth, 15);
      expect(rule.weekOfMonth, -1);
      expect(rule.month, 6);
      expect(rule.endAfterCount, 10);
      expect(rule.endDate, DateTime(2026, 12, 31));
      expect(rule.active, isTrue);
    });

    test('defaults match the server entity', () {
      final rule = RecurrenceRule.fromJson(const {});

      expect(rule.ruleType, 'daily');
      expect(rule.interval, 1);
      expect(rule.weekdays, isNull);
      expect(rule.active, isTrue);
    });
  });

  group('nextOccurrence', () {
    test('daily advances by interval days', () {
      final daily = RecurrenceRule.fromJson(const {'rule_type': 'daily'});
      expect(
        nextOccurrence(daily, DateTime(2026, 8, 22)),
        DateTime(2026, 8, 23),
      );

      final everyThreeDays = RecurrenceRule.fromJson(
        const {'rule_type': 'daily', 'interval': 3},
      );
      expect(
        nextOccurrence(everyThreeDays, DateTime(2026, 8, 22)),
        DateTime(2026, 8, 25),
      );
    });

    test('weekday skips the weekend', () {
      final rule = RecurrenceRule.fromJson(const {'rule_type': 'weekday'});
      // Friday -> Monday.
      expect(
        nextOccurrence(rule, DateTime(2026, 8, 21)),
        DateTime(2026, 8, 24),
      );
      // Saturday -> Monday.
      expect(
        nextOccurrence(rule, DateTime(2026, 8, 22)),
        DateTime(2026, 8, 24),
      );
    });

    test('weekly without weekdays repeats the same weekday', () {
      final rule = RecurrenceRule.fromJson(
        const {'rule_type': 'weekly', 'interval': 2},
      );
      expect(
        nextOccurrence(rule, DateTime(2026, 8, 22)),
        DateTime(2026, 9, 5),
      );
    });

    test('weekly with weekdays picks the next matching weekday', () {
      final rule = RecurrenceRule.fromJson(
        const {'rule_type': 'weekly', 'weekdays': [1]},
      );
      // Friday -> next Monday.
      expect(
        nextOccurrence(rule, DateTime(2026, 8, 21)),
        DateTime(2026, 8, 24),
      );
    });

    test('weekly with interval skips weeks before accepting a weekday', () {
      final rule = RecurrenceRule.fromJson(
        const {'rule_type': 'weekly', 'interval': 2, 'weekdays': [1, 5]},
      );
      // Biweekly from Monday: the Friday four days later is too close.
      expect(
        nextOccurrence(rule, DateTime(2026, 8, 24)),
        DateTime(2026, 8, 31),
      );
    });

    test('monthly clamps the day to short months', () {
      final rule = RecurrenceRule.fromJson(
        const {'rule_type': 'monthly', 'day_of_month': 31},
      );
      // 2026 is not a leap year: January 31 -> February 28.
      expect(
        nextOccurrence(rule, DateTime(2026, 1, 31)),
        DateTime(2026, 2, 28),
      );
    });

    test('monthly by weekday resolves the last Friday of the month', () {
      final rule = RecurrenceRule.fromJson(
        const {'rule_type': 'monthly', 'week_of_month': -1, 'weekdays': [5]},
      );
      expect(
        nextOccurrence(rule, DateTime(2026, 8, 28)),
        DateTime(2026, 9, 25),
      );
    });

    test('yearly clamps February 29 on non-leap years', () {
      final rule = RecurrenceRule.fromJson(
        const {'rule_type': 'yearly', 'month': 2, 'day_of_month': 29},
      );
      expect(
        nextOccurrence(rule, DateTime(2026, 2, 28)),
        DateTime(2027, 2, 28),
      );
    });

    test('unsupported rule types return null', () {
      final rule = RecurrenceRule.fromJson(const {'rule_type': 'hourly'});
      expect(nextOccurrence(rule, DateTime(2026, 8, 22)), isNull);
    });
  });

  group('occurrenceSeries', () {
    test('expands a daily rule into count upcoming dates', () {
      final rule = RecurrenceRule.fromJson(const {'rule_type': 'daily'});
      final series = occurrenceSeries(rule, DateTime(2026, 8, 22), count: 5);

      expect(series, [
        DateTime(2026, 8, 22),
        DateTime(2026, 8, 23),
        DateTime(2026, 8, 24),
        DateTime(2026, 8, 25),
        DateTime(2026, 8, 26),
      ]);
    });

    test('stops at the end date (inclusive)', () {
      final rule = RecurrenceRule.fromJson(
        const {'rule_type': 'daily', 'end_date': '2026-08-24'},
      );
      final series = occurrenceSeries(rule, DateTime(2026, 8, 22), count: 5);

      expect(series, [
        DateTime(2026, 8, 22),
        DateTime(2026, 8, 23),
        DateTime(2026, 8, 24),
      ]);
    });

    test('honors end_after_count given prior completions', () {
      final rule = RecurrenceRule.fromJson(
        const {'rule_type': 'daily', 'end_after_count': 2},
      );
      expect(
        occurrenceSeries(rule, DateTime(2026, 8, 22), count: 5),
        [DateTime(2026, 8, 22), DateTime(2026, 8, 23)],
      );
      // One completion already recorded: only one occurrence remains.
      expect(
        occurrenceSeries(rule, DateTime(2026, 8, 22), count: 5, completedCount: 1),
        [DateTime(2026, 8, 22)],
      );
      // All completions consumed: nothing remains.
      expect(
        occurrenceSeries(rule, DateTime(2026, 8, 22), count: 5, completedCount: 2),
        isEmpty,
      );
    });

    test('inactive rules expand to nothing', () {
      final rule = RecurrenceRule.fromJson(
        const {'rule_type': 'daily', 'active': false},
      );
      expect(occurrenceSeries(rule, DateTime(2026, 8, 22)), isEmpty);
    });

    test('unsupported rule types yield only the seed date', () {
      final rule = RecurrenceRule.fromJson(const {'rule_type': 'hourly'});
      expect(
        occurrenceSeries(rule, DateTime(2026, 8, 22), count: 5),
        [DateTime(2026, 8, 22)],
      );
    });
  });

  group('hasEnded', () {
    test('matches the server semantics', () {
      final rule = RecurrenceRule.fromJson(
        const {'rule_type': 'daily', 'end_after_count': 3, 'end_date': '2026-08-24'},
      );
      expect(hasEnded(rule, 0, DateTime(2026, 8, 24)), isFalse);
      expect(hasEnded(rule, 0, DateTime(2026, 8, 25)), isTrue);
      expect(hasEnded(rule, 3, DateTime(2026, 8, 22)), isTrue);
    });
  });
}
