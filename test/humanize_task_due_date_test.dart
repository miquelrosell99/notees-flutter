import 'package:flutter_test/flutter_test.dart';
import 'package:notees/presentation/widgets/task_row.dart';

void main() {
  group('humanizeTaskDueDate', () {
    // 2026-08-22 is a Saturday.
    final now = DateTime(2026, 8, 22);

    test('returns Today for the current day', () {
      expect(humanizeTaskDueDate(now, now: now), 'Today');
    });

    test('returns Tomorrow for the next day', () {
      expect(humanizeTaskDueDate(now.add(const Duration(days: 1)), now: now), 'Tomorrow');
    });

    test('returns Yesterday for the previous day', () {
      expect(humanizeTaskDueDate(now.subtract(const Duration(days: 1)), now: now), 'Yesterday');
    });

    test('returns the weekday name within the coming week', () {
      expect(humanizeTaskDueDate(now.add(const Duration(days: 3)), now: now), 'Tuesday');
      expect(humanizeTaskDueDate(now.add(const Duration(days: 6)), now: now), 'Friday');
    });

    test('returns a short date beyond the coming week', () {
      expect(humanizeTaskDueDate(now.add(const Duration(days: 7)), now: now), 'Aug 29');
      expect(humanizeTaskDueDate(now.subtract(const Duration(days: 5)), now: now), 'Aug 17');
    });

    test('includes the year for dates in another year', () {
      final endOfYear = DateTime(2026, 12, 28);
      expect(humanizeTaskDueDate(DateTime(2027, 1, 10), now: endOfYear), 'Jan 10, 2027');
    });

    test('ignores the time of day', () {
      expect(humanizeTaskDueDate(DateTime(2026, 8, 22, 23, 59), now: now), 'Today');
    });
  });
}
