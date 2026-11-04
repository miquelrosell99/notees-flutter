/// Query compile-time placeholders — the `{today}`-style date tokens, a
/// strict port of `packages/query/src/placeholders.ts`.
///
/// A placeholder is an ordinary string in the AST, resolved to a concrete
/// date at COMPILE time against the run clock ([PlaceholderContext.now]),
/// so a saved view authored with `{today}` re-evaluates against the day it
/// runs on. Anything outside the known set is left verbatim — a literal
/// "{banana}" value stays a literal (compile never crashes on foreign
/// data).
library;

/// The supported placeholder tokens, in picker order.
const List<String> queryPlaceholders = [
  '{today}',
  '{this_week}',
  '{this_month}',
  '{this_year}',
];

/// The compile clock — tests pin `now`; runtime defaults to the current
/// instant. [selfNodeId] (the query's hosting page) rides the same options
/// bag: the `self` member target mode resolves against it at compile time
/// and FAILS LOUD without it.
class CompileOptions {
  const CompileOptions({this.now, this.selfNodeId});

  final DateTime? now;
  final String? selfNodeId;
}

/// The placeholder clock subset (placeholders.ts `PlaceholderContext`).
typedef PlaceholderContext = CompileOptions;

String _pad(int value) => value.toString().padLeft(2, '0');

/// `YYYY-MM-DD` for a DateTime's own calendar day (its local fields, exactly
/// like the TS `isoDate` reads `getFullYear()`/`getMonth()`/`getDate()`).
String isoDate(DateTime date) =>
    '${date.year}-${_pad(date.month)}-${_pad(date.day)}';

DateTime _now(PlaceholderContext context) =>
    context.now ?? DateTime.now();

/// The UTC instant of a calendar day's boundary (00:00 for the start,
/// 23:59:59.999 for the end), as an ISO-8601 string comparable
/// lexicographically with the UTC `created_at` wire format. The TS
/// `localDayBoundaryUtc` builds the boundary in LOCAL time and converts to
/// UTC — the caller passes the local calendar fields, so the conversion
/// here is exactly `DateTime(y, m, d, …).toUtc()`.
String _localDayBoundaryUtc(String iso, {required bool end}) {
  final parts = iso.split('-');
  final year = int.parse(parts[0]);
  final month = int.parse(parts[1]);
  final day = int.parse(parts[2]);
  final boundary = end
      ? DateTime(year, month, day, 23, 59, 59, 999)
      : DateTime(year, month, day);
  return boundary.toUtc().toIso8601String();
}

/// The placeholder's period-start date, or null when the token is not one.
String? placeholderStartDate(String token, [PlaceholderContext context = const CompileOptions()]) {
  final now = _now(context);
  switch (token) {
    case '{today}':
      return isoDate(now);
    case '{this_week}':
      // ISO-8601 week: Monday is day 1 (DateTime.weekday); the TS reads
      // getDay() (Sunday at 0) — the offsets agree.
      final monday = now.subtract(Duration(days: now.weekday - 1));
      return isoDate(monday);
    case '{this_month}':
      return '${now.year}-${_pad(now.month)}-01';
    case '{this_year}':
      return '${now.year}-01-01';
    default:
      return null;
  }
}

/// The placeholder's period-end date, or null when the token is not one.
String? placeholderEndDate(String token, [PlaceholderContext context = const CompileOptions()]) {
  final now = _now(context);
  switch (token) {
    case '{today}':
      return isoDate(now);
    case '{this_week}':
      final monday = now.subtract(Duration(days: now.weekday - 1));
      return isoDate(monday.add(const Duration(days: 6)));
    case '{this_month}':
      // The day 0 of next month is the last day of this one.
      return isoDate(DateTime(now.year, now.month + 1, 0));
    case '{this_year}':
      return '${now.year}-12-31';
    default:
      return null;
  }
}

/// Resolve a placeholder in a TIMESTAMP position (`date` condition
/// after/before and the comparison ops): the period's local day start for
/// after (inclusive floor), local day end for before (inclusive ceiling),
/// each expressed in UTC. Non-placeholder input is returned as-is.
String resolveTimestampPlaceholder(
  String value,
  String direction,
  PlaceholderContext context,
) {
  final resolved = direction == 'after'
      ? placeholderStartDate(value, context)
      : placeholderEndDate(value, context);
  if (resolved == null) return value;
  return _localDayBoundaryUtc(resolved, end: direction == 'before');
}

/// Resolve a placeholder in a PROPERTY-VALUE position: the period start as
/// a plain `YYYY-MM-DD` date (the shape a hand-typed date would have).
/// Non-placeholder input is returned as-is.
String resolveValuePlaceholder(String value, PlaceholderContext context) =>
    placeholderStartDate(value, context) ?? value;

/// The token form of the relative periods.
const Map<String, String> periodTokens = {
  'today': '{today}',
  'this_week': '{this_week}',
  'this_month': '{this_month}',
  'this_year': '{this_year}',
};

/// The UTC bounds of a relative period: the period's local day-start and
/// day-end, each a UTC ISO-8601 string comparable lexicographically with
/// the `created_at` wire format.
({String from, String to}) resolvePeriodBounds(
  String period,
  PlaceholderContext context,
) {
  final token = periodTokens[period] ?? period;
  final start = placeholderStartDate(token, context);
  final end = placeholderEndDate(token, context);
  if (start == null || end == null) {
    throw FormatException('query: unknown date period "$period"');
  }
  return (
    from: _localDayBoundaryUtc(start, end: false),
    to: _localDayBoundaryUtc(end, end: true),
  );
}

/// The DAY bounds behind the day-granular equality (the date condition's
/// eq/neq ops): a `{today}`-style token resolves to that period's local
/// day; a plain `YYYY-MM-DD` date to that local day; anything else (a full
/// ISO instant) to the instant itself (equality collapses to instant
/// equality).
({String from, String to}) resolveDayBounds(
  String value,
  PlaceholderContext context,
) {
  final start = placeholderStartDate(value, context);
  if (start != null) {
    final end = placeholderEndDate(value, context)!;
    return (
      from: _localDayBoundaryUtc(start, end: false),
      to: _localDayBoundaryUtc(end, end: true),
    );
  }
  if (RegExp(r'^\d{4}-\d{2}-\d{2}$').hasMatch(value)) {
    return (
      from: _localDayBoundaryUtc(value, end: false),
      to: _localDayBoundaryUtc(value, end: true),
    );
  }
  return (from: value, to: value);
}
