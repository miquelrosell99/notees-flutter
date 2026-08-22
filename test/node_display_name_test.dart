import 'package:flutter_test/flutter_test.dart';
import 'package:notees/core/utils/date_uuid.dart';
import 'package:notees/core/utils/node_display_name.dart';
import 'package:notees/data/models/node.dart';

void main() {
  Node journalNode({
    required DateTime date,
    bool monthly = false,
    bool yearly = false,
  }) {
    final uuid = yearly
        ? dateToYearUuid(date)
        : monthly
            ? dateToMonthUuid(date)
            : dateToDayUuid(date);
    return Node(
      id: 0,
      uuid: uuid,
      name: '',
      displayName: '',
      isPage: true,
      isDaily: !monthly && !yearly,
      isMonthly: monthly,
      isYearly: yearly,
    );
  }

  final date = DateTime(2026, 8, 22);

  group('resolveNodeDisplayName journals', () {
    test('daily journals follow the user date format', () {
      final node = journalNode(date: date);
      expect(
        resolveNodeDisplayName(node, dateFormat: 'YYYY/MM/DD'),
        '2026/08/22',
      );
      expect(
        resolveNodeDisplayName(node, dateFormat: 'DD-MM-YYYY'),
        '22-08-2026',
      );
      expect(
        resolveNodeDisplayName(node, dateFormat: 'MM/DD/YYYY'),
        '08/22/2026',
      );
    });

    test('monthly journals follow the user date format', () {
      final node = journalNode(date: date, monthly: true);
      // Year-first formats keep the year first, with the format's separator.
      expect(
        resolveNodeDisplayName(node, dateFormat: 'YYYY/MM/DD'),
        '2026/08',
      );
      expect(
        resolveNodeDisplayName(node, dateFormat: 'YYYY-MM-DD'),
        '2026-08',
      );
      // Day/month-first formats put the month first.
      expect(
        resolveNodeDisplayName(node, dateFormat: 'DD/MM/YYYY'),
        '08/2026',
      );
      expect(
        resolveNodeDisplayName(node, dateFormat: 'DD-MM-YYYY'),
        '08-2026',
      );
      expect(
        resolveNodeDisplayName(node, dateFormat: 'MM/DD/YYYY'),
        '08/2026',
      );
      expect(
        resolveNodeDisplayName(node, dateFormat: 'MM-DD-YYYY'),
        '08-2026',
      );
    });

    test('monthly journals fall back to the long month name without a format',
        () {
      final node = journalNode(date: date, monthly: true);
      expect(resolveNodeDisplayName(node), 'August 2026');
    });

    test('yearly journals are always the 4-digit year', () {
      final node = journalNode(date: date, yearly: true);
      expect(resolveNodeDisplayName(node, dateFormat: 'DD/MM/YYYY'), '2026');
      expect(resolveNodeDisplayName(node), '2026');
    });
  });

  group('resolveNodeDisplayName pages', () {
    test('falls back to displayName, then Untitled', () {
      final named = Node(
        id: 0,
        uuid: 'f47ac10b-58cc-4372-a567-0e02b2c3d479',
        name: '',
        displayName: 'Shopping',
        isPage: true,
      );
      expect(resolveNodeDisplayName(named), 'Shopping');

      final unnamed = Node(
        id: 0,
        uuid: 'f47ac10b-58cc-4372-a567-0e02b2c3d479',
        name: '',
        displayName: '',
        isPage: true,
      );
      expect(resolveNodeDisplayName(unnamed), 'Untitled');
    });
  });
}
