import 'package:intl/intl.dart';

import '../../data/models/node.dart';
import './ast_stringifier.dart';
import './date_uuid.dart';

/// Max length of a derived display name (`DISPLAY_NAME_MAX` in
/// `packages/domain/src/node.ts`).
const displayNameMax = 80;

/// Display-name derivation (SCHEMA.md "title-is-content", 2026-10-01
/// lockstep with `packages/domain/src/node.ts` deriveDisplayName): a node's
/// title IS its own text content — there is no separate name field for any
/// node (pages, blocks AND classes); the display name is the content
/// excerpt. Callers fall back to a human "Untitled" label when this returns
/// "".
///
/// [contentSource] is the serialized content document (the node `name`
/// slot). Date nodes carry the raw YYYYMMDD-style label as their content;
/// display formats it per the web default shape (zero-padded segments
/// dropped): 20290000 → 2029, 20290600 → 2029/06, 20290627 → 2029/06/27.
String deriveDisplayName(dynamic contentSource) {
  final excerpt = astToPlainText(contentSource).trim();
  if (excerpt.isEmpty) return '';
  final dateFormatted = formatDateNodeName(excerpt);
  final name = dateFormatted ?? excerpt;
  return name.length <= displayNameMax
      ? name
      : name.substring(0, displayNameMax);
}

/// Formats a raw date-node name; null when the name is not the YYYYMMDD
/// shape. Mirrors `formatDateNodeName` in `packages/domain/src/node.ts`:
/// non-digits are stripped first, so punctuated labels ("2029-06-27")
/// format too. The class check is deliberately NOT required: an 8-digit
/// label is unambiguous.
String? formatDateNodeName(String name) {
  final digits = name.replaceAll(RegExp(r'\D'), '');
  if (!RegExp(r'^\d{8}$').hasMatch(digits)) return null;
  final year = digits.substring(0, 4);
  final month = digits.substring(4, 6);
  final day = digits.substring(6, 8);
  if (month == '00') return year;
  if (day == '00') return '$year/$month';
  return '$year/$month/$day';
}

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
