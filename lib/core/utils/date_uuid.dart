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
/// Pattern: `00000000-0000-0000-00mm-YYYYMM000000`
String dateToMonthUuid(DateTime date) {
  final suffix = '${_pad4(date.year)}${_pad2(date.month)}000000';
  return '00000000-0000-0000-00mm-$suffix';
}

/// Returns the deterministic UUID for a yearly journal node.
///
/// Pattern: `00000000-0000-0000-00yy-YYYY00000000`
String dateToYearUuid(DateTime date) {
  final suffix = '${_pad4(date.year)}00000000';
  return '00000000-0000-0000-00yy-$suffix';
}

/// Reverse of the deterministic journal UUID encoders.
///
/// Returns the date represented by a daily, monthly, or yearly journal UUID,
/// or `null` if [uuid] does not match any known journal pattern.
///
/// Supports both the legacy mobile prefixes (`00mm`, `00yy`) and the current
/// server prefixes (`00aa`, `00bb`) for month/year journals.
DateTime? journalDateFromUuid(String uuid) {
  final clean = uuid.replaceAll('-', '');
  if (clean.length < 28) return null;
  final prefix = clean.substring(18, 22);
  final suffix = clean.substring(22);
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
