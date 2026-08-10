import 'package:flutter_test/flutter_test.dart';
import 'package:notees/core/utils/date_uuid.dart';

void main() {
  group('date UUID helpers', () {
    test('dateToDayUuid produces the expected pattern', () {
      final uuid = dateToDayUuid(DateTime(2026, 8, 9));
      expect(uuid, '00000000-0000-0000-00dd-202608090000');
    });

    test('dateToMonthUuid produces the expected pattern', () {
      final uuid = dateToMonthUuid(DateTime(2026, 8, 9));
      expect(uuid, '00000000-0000-0000-00mm-202608000000');
    });

    test('dateToYearUuid produces the expected pattern', () {
      final uuid = dateToYearUuid(DateTime(2026, 8, 9));
      expect(uuid, '00000000-0000-0000-00yy-202600000000');
    });

    test('outputs are valid UUID length and format', () {
      final day = dateToDayUuid(DateTime(2026, 12, 31));
      expect(day.length, 36);
      expect(day.split('-').length, 5);
    });
  });
}
