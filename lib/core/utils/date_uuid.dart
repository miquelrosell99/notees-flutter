/// Deterministic UUIDs for date-based journal nodes.
///
/// These match the web app's date-to-UUID encoding so daily/monthly/yearly
/// journals resolve to the same UUID on every client.
library;

String _pad4(int value) => value.toString().padLeft(4, '0');

String _pad2(int value) => value.toString().padLeft(2, '0');

/// Returns the deterministic UUID for a daily journal node.
///
/// Pattern: `00000000-0000-0000-00dd-YYYYMMDD0000`
String dateToDayUuid(DateTime date) {
  final suffix = '${_pad4(date.year)}${_pad2(date.month)}${_pad2(date.day)}0000';
  return '00000000-0000-0000-00dd-$suffix';
}

/// Returns the deterministic UUID for a monthly journal node.
///
/// Pattern: `00000000-0000-0000-00aa-YYYYMM000000`
String dateToMonthUuid(DateTime date) {
  final suffix = '${_pad4(date.year)}${_pad2(date.month)}000000';
  return '00000000-0000-0000-00aa-$suffix';
}

/// Returns the deterministic UUID for a yearly journal node.
///
/// Pattern: `00000000-0000-0000-00bb-YYYY00000000`
String dateToYearUuid(DateTime date) {
  final suffix = '${_pad4(date.year)}00000000';
  return '00000000-0000-0000-00bb-$suffix';
}

/// Reverse of the deterministic journal UUID encoders.
///
/// Returns the date represented by a daily, monthly, or yearly journal UUID,
/// or `null` if [uuid] does not match any known journal pattern.
///
/// Supports both the legacy mobile prefixes (`00mm`, `00yy`) and the current
/// server prefixes (`00dd`, `00aa`, `00bb`) for day/month/year journals.
DateTime? journalDateFromUuid(String uuid) {
  final clean = uuid.replaceAll('-', '');
  if (clean.length < 28) return null;
  // The fourth UUID group occupies characters 16-19 in the dash-free form.
  final prefix = clean.substring(16, 20);
  final suffix = clean.substring(20);
  try {
    if (prefix == '00dd' && suffix.length >= 8) {
      final year = int.parse(suffix.substring(0, 4));
      final month = int.parse(suffix.substring(4, 6));
      final day = int.parse(suffix.substring(6, 8));
      return DateTime(year, month, day);
    }
    if ((prefix == '00mm' || prefix == '00aa') && suffix.length >= 6) {
      final year = int.parse(suffix.substring(0, 4));
      final month = int.parse(suffix.substring(4, 6));
      return DateTime(year, month);
    }
    if ((prefix == '00yy' || prefix == '00bb') && suffix.length >= 4) {
      final year = int.parse(suffix.substring(0, 4));
      return DateTime(year);
    }
  } catch (_) {}
  return null;
}

final RegExp _isoDatePattern = RegExp(r'^(\d{4})-(\d{2})-(\d{2})$');

/// Strict `YYYY-MM-DD` parse with real-calendar validation (leap years
/// included) — the port of `parseIsoDate` in the monorepo's
/// `packages/domain/src/dates.ts` (PC6 normalize-on-write, §34.57).
/// Datetimes are rejected: date-node ids address whole days; time-of-day
/// has nowhere to go. Returns null on any deviation (callers ride the value
/// through untouched).
DateTime? parseIsoDateStrict(String isoDate) {
  final match = _isoDatePattern.firstMatch(isoDate.trim());
  if (match == null) return null;
  final year = int.tryParse(match.group(1)!);
  final month = int.tryParse(match.group(2)!);
  final day = int.tryParse(match.group(3)!);
  if (year == null || month == null || day == null) return null;
  // Days in month via the day-before-first-of-next-month trick (UTC, pure).
  final daysInMonth = DateTime.utc(year, month + 1, 0).day;
  if (month < 1 || month > 12 || day < 1 || day > daysInMonth) return null;
  return DateTime.utc(year, month, day);
}

/// The deterministic day-node id for a well-formed `YYYY-MM-DD` string, or
/// null when [isoDate] is not a real calendar day (PC6 normalize-on-write:
/// a well-formed string rewrites to `{"nodeId": <day chain node>}`; anything
/// else rides through as authored).
String? dayUuidFromIsoDate(String isoDate) {
  final parsed = parseIsoDateStrict(isoDate);
  return parsed == null ? null : dateToDayUuid(parsed);
}

/// Date-node precision, finest-claimed-first ordered: year < month < day
/// (SCHEMA.md "Dates"; the PG6 datePrecision ceiling ranks on this order).
enum DateNodePrecision { year, month, day }

/// A parsed date-node id: the precision plus the calendar components.
class ParsedDateNodeId {
  const ParsedDateNodeId({
    required this.precision,
    required this.year,
    required this.month,
    required this.day,
  });

  final DateNodePrecision precision;
  final int year;
  final int month;
  final int day;
}

const _dateUuidMinYear = 1900;
const _dateUuidMaxYear = 2200;

/// v1 `parse_date_uuid` port (monorepo `packages/domain/src/dates.ts`
/// `parseDateNodeId`): extract precision + date components from a date-node
/// id, or null when the id is not a date UUID (or falls outside the v1
/// 1900..2200 window). Round-trips with the deterministic encoders above.
ParsedDateNodeId? parseDateNodeId(String id) {
  if (id.length != 36) return null;
  const dayPrefix = '00000000-0000-0000-00dd-';
  const monthPrefix = '00000000-0000-0000-00aa-';
  const yearPrefix = '00000000-0000-0000-00bb-';
  int? read(String data, int start, int end) {
    final slice = data.substring(start, end);
    final value = int.tryParse(slice);
    // int.tryParse accepts a leading +/-; the digit-only shape check matters
    // (the TS port tests /^\d+$/ before Number()).
    if (value == null) return null;
    for (var i = 0; i < slice.length; i++) {
      final code = slice.codeUnitAt(i);
      if (code < 0x30 || code > 0x39) return null;
    }
    return value;
  }

  final data = id.substring(24); // trailing 12-digit payload
  if (id.startsWith(dayPrefix)) {
    final year = read(data, 0, 4);
    final month = read(data, 4, 6);
    final day = read(data, 6, 8);
    if (year != null &&
        month != null &&
        day != null &&
        year >= _dateUuidMinYear &&
        year <= _dateUuidMaxYear &&
        month >= 1 &&
        month <= 12 &&
        day >= 1 &&
        day <= 31) {
      return ParsedDateNodeId(
        precision: DateNodePrecision.day,
        year: year,
        month: month,
        day: day,
      );
    }
    return null;
  }
  if (id.startsWith(monthPrefix)) {
    final year = read(data, 0, 4);
    final month = read(data, 4, 6);
    if (year != null &&
        month != null &&
        year >= _dateUuidMinYear &&
        year <= _dateUuidMaxYear &&
        month >= 1 &&
        month <= 12) {
      return ParsedDateNodeId(
        precision: DateNodePrecision.month,
        year: year,
        month: month,
        day: 1,
      );
    }
    return null;
  }
  if (id.startsWith(yearPrefix)) {
    final year = read(data, 0, 4);
    if (year != null &&
        year >= _dateUuidMinYear &&
        year <= _dateUuidMaxYear) {
      return ParsedDateNodeId(
        precision: DateNodePrecision.year,
        year: year,
        month: 1,
        day: 1,
      );
    }
  }
  return null;
}
