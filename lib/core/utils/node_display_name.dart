import 'package:intl/intl.dart';

import '../../data/models/node.dart';
import 'date_uuid.dart';

/// Returns a human-readable label for [node], using the user's [dateFormat]
/// preference when the node is a journal whose resolved name is blank.
///
/// Falls back to "Untitled" for non-journal nodes with no display name.
String resolveNodeDisplayName(Node node, {String? dateFormat}) {
  if (node.displayName.isNotEmpty) return node.displayName;

  final date = journalDateFromUuid(node.uuid);
  if (date != null) {
    if (dateFormat != null) {
      return _formatWithSettings(date, dateFormat);
    }
    return DateFormat.yMMMMEEEEd().format(date);
  }

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
