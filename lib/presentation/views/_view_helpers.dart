import 'package:flutter/material.dart';

import '../../data/models/node.dart';

/// Shared formatting and extraction helpers for node collection views.

/// Returns all non-empty property keys found across [nodes].
List<String> collectPropertyKeys(List<Node> nodes) {
  final keys = <String>{};
  for (final node in nodes) {
    for (final entry in node.properties.entries) {
      if (_isNotEmpty(entry.value)) {
        keys.add(entry.key);
      }
    }
  }
  return keys.toList()..sort();
}

bool _isNotEmpty(dynamic value) {
  if (value == null) return false;
  if (value is String) return value.isNotEmpty;
  if (value is List) return value.isNotEmpty;
  if (value is Map) return value.isNotEmpty;
  return true;
}

/// Returns a readable label for a raw property key.
String propertyDisplayName(String key) {
  // Keys are often property UUIDs or snake_case names.
  if (key.contains('_') || key.contains(' ')) {
    final cleaned = key
        .replaceAll('_', ' ')
        .replaceAll(RegExp(r'\s+'), ' ')
        .trim();
    if (cleaned.isEmpty) return key;
    return cleaned.split(' ').map(_capitalize).join(' ');
  }
  return key;
}

String _capitalize(String word) {
  if (word.isEmpty) return word;
  return '${word[0].toUpperCase()}${word.substring(1).toLowerCase()}';
}

/// Formats a property value for display in table/kanban cells.
String formatPropertyValue(dynamic value) {
  if (value == null) return '-';
  if (value is String) {
    if (value.isEmpty) return '-';
    final date = DateTime.tryParse(value);
    if (date != null) {
      return '${date.year.toString().padLeft(4, '0')}-'
          '${date.month.toString().padLeft(2, '0')}-'
          '${date.day.toString().padLeft(2, '0')}';
    }
    return value;
  }
  if (value is bool) return value ? 'Yes' : 'No';
  if (value is num) return value.toString();
  if (value is List) {
    if (value.isEmpty) return '-';
    return value.map(formatPropertyValue).join(', ');
  }
  if (value is Map<String, dynamic>) {
    for (final key in const ['name', 'display_name', 'value', 'value_text', 'label']) {
      if (value.containsKey(key) && value[key] != null) {
        return formatPropertyValue(value[key]);
      }
    }
  }
  return value.toString();
}

/// Extracts a groupable string value for a property key.
String groupValueFor(Node node, String key) {
  final value = node.properties[key];
  return formatPropertyValue(value);
}

/// Extracts a [DateTime] from a property value, or null if not a date.
DateTime? extractDate(dynamic value) {
  if (value == null) return null;
  if (value is DateTime) return value;
  if (value is String) {
    if (value.isEmpty) return null;
    return DateTime.tryParse(value);
  }
  if (value is num) {
    final ms = value is int ? value : (value * 1000).round();
    return DateTime.fromMillisecondsSinceEpoch(ms);
  }
  return null;
}

/// Returns candidate date property keys found in [nodes].
List<String> collectDatePropertyKeys(List<Node> nodes) {
  final keys = <String>{};
  for (final node in nodes) {
    for (final entry in node.properties.entries) {
      if (extractDate(entry.value) != null) {
        keys.add(entry.key);
      }
    }
  }
  // Always offer built-in date fields if present on any node.
  for (final node in nodes) {
    if (node.writeDate?.isNotEmpty == true) keys.add('write_date');
    if (node.createDate?.isNotEmpty == true) keys.add('create_date');
  }
  return keys.toList()..sort();
}

/// Returns the date value for a node using the given property key.
DateTime? dateForNode(Node node, String key) {
  if (key == 'write_date') return extractDate(node.writeDate);
  if (key == 'create_date') return extractDate(node.createDate);
  return extractDate(node.properties[key]);
}

IconData iconForNode(Node node) {
  if (node.isJournal) return Icons.calendar_today_outlined;
  if (node.isTask) return Icons.check_circle_outline;
  return node.icon?.isNotEmpty == true ? Icons.description_outlined : Icons.description_outlined;
}

String typeLabel(Node node) {
  if (node.isJournal) return 'Journal';
  if (node.isTask) return 'Task';
  if (node.isPage) return 'Page';
  return 'Block';
}
