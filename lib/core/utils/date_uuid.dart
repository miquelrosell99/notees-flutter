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
