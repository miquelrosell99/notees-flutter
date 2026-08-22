import 'package:intl/intl.dart';

import '../../data/models/node.dart';
import './date_uuid.dart';

/// Returns a human-readable label for [node], using the user's [dateFormat]
/// preference when the node is a journal.
///
/// Journal nodes always resolve to their canonical date label. Non-journal
/// nodes fall back to [Node.displayName], then to "Untitled".
String resolveNodeDisplayName(Node node, {String? dateFormat}) {
  final date = journalDateFromUuid(node.uuid);
  if (date != null) {
    if (node.isMonthly) {
      if (dateFormat != null) {
        return _formatMonthWithSettings(date, dateFormat);
      }
      return DateFormat.yMMMM().format(date);
    }
    if (node.isYearly) {
      // Mirrors the web client's formatYear: always the 4-digit year,
      // regardless of the date-format preference.
      return DateFormat.y().format(date);
    }
    if (dateFormat != null) {
      return _formatWithSettings(date, dateFormat);
    }
    return DateFormat.yMMMMEEEEd().format(date);
  }

  if (node.displayName.isNotEmpty) return node.displayName;

  return 'Untitled';
}

/// Format [date] using one of the supported date-format patterns.
///
/// Mirrors [SettingsProvider.dateFormat] so journal labels stay consistent
/// with the rest of the app without introducing a circular import.
String _formatWithSettings(DateTime date, String format) {
  final year = date.year.toString();
  final month = date.month.toString().padLeft(2, '0');
  final day = date.day.toString().padLeft(2, '0');

  return switch (format) {
    'YYYY/MM/DD' => '$year/$month/$day',
    'YYYY-MM-DD' => '$year-$month-$day',
    'DD/MM/YYYY' => '$day/$month/$year',
    'DD-MM-YYYY' => '$day-$month-$year',
    'MM/DD/YYYY' => '$month/$day/$year',
    'MM-DD-YYYY' => '$month-$day-$year',
    _ => '$year/$month/$day',
  };
}

/// Format a month journal label using one of the supported date-format
/// patterns.
///
/// Mirrors the web client's `formatMonth` (settingsStore.ts): the separator
/// comes from the format ('/' when the format contains '/', else '-'), and
/// the year leads when the format starts with 'YYYY'.
String _formatMonthWithSettings(DateTime date, String format) {
  final year = date.year.toString();
  final month = date.month.toString().padLeft(2, '0');
  final separator = format.contains('/') ? '/' : '-';
  return format.startsWith('YYYY') ? '$year$separator$month' : '$month$separator$year';
}
