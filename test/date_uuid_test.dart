import 'package:flutter_test/flutter_test.dart';
import 'package:notees/core/utils/date_uuid.dart';

void main() {
  group('date UUID helpers', () {
    test('dateToDayUuid produces the expected pattern', () {
      final uuid = dateToDayUuid(DateTime(2026, 8, 9));
      expect(uuid, '00000000-0000-0000-00dd-202608090000');
    });

    test('dateToMonthUuid produces the expected server pattern', () {
      final uuid = dateToMonthUuid(DateTime(2026, 8, 9));
      expect(uuid, '00000000-0000-0000-00aa-202608000000');
    });

    test('dateToYearUuid produces the expected server pattern', () {
      final uuid = dateToYearUuid(DateTime(2026, 8, 9));
      expect(uuid, '00000000-0000-0000-00bb-202600000000');
    });

    test('outputs are valid UUID length and format', () {
      final day = dateToDayUuid(DateTime(2026, 12, 31));
      expect(day.length, 36);
      expect(day.split('-').length, 5);
    });

    test('journalDateFromUuid parses day UUIDs', () {
      final date = journalDateFromUuid('00000000-0000-0000-00dd-202608090000');
      expect(date, DateTime(2026, 8, 9));
    });

    test('journalDateFromUuid parses month UUIDs with server prefix', () {
      final date = journalDateFromUuid('00000000-0000-0000-00aa-202608000000');
      expect(date, DateTime(2026, 8));
    });

    test('journalDateFromUuid parses year UUIDs with server prefix', () {
      final date = journalDateFromUuid('00000000-0000-0000-00bb-202600000000');
      expect(date, DateTime(2026));
    });

    test('journalDateFromUuid returns null for non-journal UUIDs', () {
      expect(journalDateFromUuid('00000000-0000-0000-0001-000000000001'), isNull);
      expect(journalDateFromUuid('not-a-uuid'), isNull);
    });

    test('dateChainParentId round-trips with the encoders', () {
      final day = dateToDayUuid(DateTime(2026, 8, 9));
      final month = dateToMonthUuid(DateTime(2026, 8, 9));
      final year = dateToYearUuid(DateTime(2026, 8, 9));
      expect(dateChainParentId(day), month);
      expect(dateChainParentId(month), year);
      // The year node is locked to the workspace root.
      expect(dateChainParentId(year), isNull);
    });

    test('dateChainClassId returns the precision system class', () {
      expect(
        dateChainClassId(dateToDayUuid(DateTime(2026, 8, 9))),
        '00000000-0000-0000-0001-000000000005',
      );
      expect(
        dateChainClassId(dateToMonthUuid(DateTime(2026, 8, 9))),
        '00000000-0000-0000-0001-000000000004',
      );
      expect(
        dateChainClassId(dateToYearUuid(DateTime(2026, 8, 9))),
        '00000000-0000-0000-0001-000000000003',
      );
    });

    test('dateChain helpers return null for non-date ids', () {
      expect(
        dateChainParentId('00000000-0000-0000-0001-000000000001'),
        isNull,
      );
      expect(dateChainParentId('not-a-uuid'), isNull);
      expect(dateChainClassId('00000000-0000-0000-0001-000000000001'), isNull);
      expect(dateChainClassId('not-a-uuid'), isNull);
    });
  });
}
