import 'package:flutter_test/flutter_test.dart';
import 'package:notees/features/editor/widgets/journal_calendar_picker.dart';

void main() {
  group('calendarWeekdayLabel', () {
    test('maps every day index (0 = Sunday)', () {
      expect(calendarWeekdayLabel(0), 'S');
      expect(calendarWeekdayLabel(1), 'M');
      expect(calendarWeekdayLabel(2), 'T');
      expect(calendarWeekdayLabel(3), 'W');
      expect(calendarWeekdayLabel(4), 'T');
      expect(calendarWeekdayLabel(5), 'F');
      expect(calendarWeekdayLabel(6), 'S');
    });

    test('wraps out-of-range indexes', () {
      expect(calendarWeekdayLabel(7), 'S');
    });
  });

  group('calendarLeadingPadding', () {
    test('Sunday-first grid: a Sunday-start month has no padding', () {
      // 2026-11-01 is a Sunday.
      expect(calendarLeadingPadding(2026, 11, 0), 0);
    });

    test('Monday-first grid: a Monday-start month has no padding', () {
      // 2026-06-01 is a Monday.
      expect(calendarLeadingPadding(2026, 6, 1), 0);
    });

    test('Sunday-first grid: Monday lands in the second column', () {
      expect(calendarLeadingPadding(2026, 6, 0), 1);
    });

    test('Saturday-first grid: Monday follows two weekend columns', () {
      expect(calendarLeadingPadding(2026, 6, 6), 2);
    });
  });
}
