import 'package:flutter_test/flutter_test.dart';
import 'package:notees/domain/query/query_placeholders.dart';

/// The placeholder pins — the port of `packages/query/test/placeholders.test.ts`:
/// period bounds, `{today}` in timestamp vs value positions, unknown tokens
/// passing through verbatim, pinned `now`.
void main() {
  // A Wednesday (2026-11-04 is a Wednesday) so the ISO-week arms have a
  // fixed Monday/Sunday. Local-time fields: the TS reference reads the
  // machine-local calendar day.
  final wednesday = DateTime(2026, 11, 4, 15, 30);
  final options = CompileOptions(now: DateTime(2026, 11, 4, 15, 30));

  group('placeholderStartDate / placeholderEndDate', () {
    test('{today} is the current local day on both ends', () {
      expect(placeholderStartDate('{today}', options), '2026-11-04');
      expect(placeholderEndDate('{today}', options), '2026-11-04');
    });

    test('{this_week} is the ISO Monday .. Sunday', () {
      expect(placeholderStartDate('{this_week}', options), '2026-11-02');
      expect(placeholderEndDate('{this_week}', options), '2026-11-08');
    });

    test('{this_month} is the first .. last day of the month', () {
      expect(placeholderStartDate('{this_month}', options), '2026-11-01');
      expect(placeholderEndDate('{this_month}', options), '2026-11-30');
    });

    test('{this_year} is January 1 .. December 31', () {
      expect(placeholderStartDate('{this_year}', options), '2026-01-01');
      expect(placeholderEndDate('{this_year}', options), '2026-12-31');
    });

    test('unknown tokens return null', () {
      expect(placeholderStartDate('{banana}', options), isNull);
      expect(placeholderEndDate('2026-11-04', options), isNull);
    });

    test('a plain date is not a placeholder', () {
      expect(placeholderStartDate('2026-11-04', options), isNull);
    });
  });

  group('localDayBoundaryUtc (via resolveTimestampPlaceholder)', () {
    test('after resolves to the local day start in UTC', () {
      final local = DateTime(2026, 11, 4);
      final expected = local.toUtc().toIso8601String();
      expect(
        resolveTimestampPlaceholder('{today}', 'after', options),
        expected,
      );
    });

    test('before resolves to the local day end (23:59:59.999) in UTC', () {
      final localEnd = DateTime(2026, 11, 4, 23, 59, 59, 999);
      expect(
        resolveTimestampPlaceholder('{today}', 'before', options),
        localEnd.toUtc().toIso8601String(),
      );
    });

    test('non-placeholder input passes through verbatim', () {
      expect(
        resolveTimestampPlaceholder('2026-11-04T10:00:00.000Z', 'after', options),
        '2026-11-04T10:00:00.000Z',
      );
      expect(
        resolveTimestampPlaceholder('{banana}', 'before', options),
        '{banana}',
      );
    });

    test('the UTC offset is honored (CEST +2 in July)', () {
      final summer = DateTime(2026, 7, 15, 12);
      final options = CompileOptions(now: summer);
      expect(
        resolveTimestampPlaceholder('{today}', 'after', options),
        DateTime(2026, 7, 15).toUtc().toIso8601String(),
      );
    });
  });

  group('resolveValuePlaceholder', () {
    test('resolves to the period start as a plain date', () {
      expect(resolveValuePlaceholder('{today}', options), '2026-11-04');
      expect(resolveValuePlaceholder('{this_month}', options), '2026-11-01');
      expect(resolveValuePlaceholder('{banana}', options), '{banana}');
      expect(resolveValuePlaceholder('2026-11-04', options), '2026-11-04');
    });
  });

  group('resolvePeriodBounds', () {
    test('today spans the local day in UTC', () {
      final bounds = resolvePeriodBounds('today', options);
      expect(bounds.from, DateTime(2026, 11, 4).toUtc().toIso8601String());
      expect(bounds.to,
          DateTime(2026, 11, 4, 23, 59, 59, 999).toUtc().toIso8601String());
    });

    test('the period names map to their tokens', () {
      final byName = resolvePeriodBounds('this_week', options);
      final byToken = resolvePeriodBounds('{this_week}', options);
      expect(byName, byToken);
      expect(byName.from, DateTime(2026, 11, 2).toUtc().toIso8601String());
      expect(byName.to,
          DateTime(2026, 11, 8, 23, 59, 59, 999).toUtc().toIso8601String());
    });

    test('unknown periods fail loud', () {
      expect(() => resolvePeriodBounds('someday', options), throwsFormatException);
    });
  });

  group('resolveDayBounds', () {
    test('a placeholder resolves to the period days', () {
      final bounds = resolveDayBounds('{this_week}', options);
      expect(bounds.from, DateTime(2026, 11, 2).toUtc().toIso8601String());
      expect(bounds.to,
          DateTime(2026, 11, 8, 23, 59, 59, 999).toUtc().toIso8601String());
    });

    test('a plain YYYY-MM-DD resolves to that local day', () {
      final bounds = resolveDayBounds('2026-11-04', options);
      expect(bounds.from, DateTime(2026, 11, 4).toUtc().toIso8601String());
      expect(bounds.to,
          DateTime(2026, 11, 4, 23, 59, 59, 999).toUtc().toIso8601String());
    });

    test('a full instant collapses to instant equality', () {
      const instant = '2026-11-04T10:00:00.000Z';
      final bounds = resolveDayBounds(instant, options);
      expect(bounds.from, instant);
      expect(bounds.to, instant);
    });
  });

  group('isoDate', () {
    test('pads to YYYY-MM-DD', () {
      expect(isoDate(wednesday), '2026-11-04');
      expect(isoDate(DateTime(2026, 1, 2)), '2026-01-02');
    });
  });
}
