import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:home_widget/home_widget.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../core/constants/system.dart';
import '../data/models/node.dart';
import '../data/models/property.dart';
import '../data/repositories/node_repository.dart';
import '../domain/models/search_filters.dart';

/// Flutter side of the Android home-screen "today's tasks" widget.
///
/// Keeps a small JSON snapshot of today's open tasks in [SharedPreferences]
/// where the native [AppWidgetProvider] can read it, and asks the native side
/// to redraw the widget via [home_widget].
class WidgetService {
  WidgetService._();

  static const _tasksKey = 'notees.widget_tasks';
  static const _updatedAtKey = 'notees.widget_tasks_updated_at';
  static const _providerName = 'TaskWidgetProvider';
  static const _qualifiedAndroidName = 'com.notees.notees.TaskWidgetProvider';

  /// Persists today's tasks and triggers a widget redraw.
  static Future<void> saveTodayTasks(List<Node> tasks) async {
    final prefs = await SharedPreferences.getInstance();
    final payload = tasks.map((task) {
      return {
        'uuid': task.uuid,
        'displayName': task.displayName,
        'dueDate': _taskDueDate(task)?.toIso8601String().split('T').first,
      };
    }).toList();

    await prefs.setString(_tasksKey, jsonEncode(payload));
    await prefs.setInt(_updatedAtKey, DateTime.now().millisecondsSinceEpoch);
    await updateWidgets();
  }

  /// Clears cached widget data (e.g. when the user signs out).
  static Future<void> clearWidgetData() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.remove(_tasksKey);
    await prefs.remove(_updatedAtKey);
    await updateWidgets();
  }

  /// Fetches today's open tasks from the server.
  static Future<List<Node>> loadTodayTasksFromRepo(NodeRepository repo) async {
    final now = DateTime.now();
    final today = DateTime(now.year, now.month, now.day);
    return repo.searchWithFilters(
      const SearchFilters(
        nodeType: NodeType.task,
        taskState: TaskState.open,
        sortBy: SortBy.dueDate,
        limit: 50,
      ).copyWith(dateFrom: today, dateTo: today),
    );
  }

  /// Asks the native widget provider to redraw all widget instances.
  static Future<void> updateWidgets() async {
    try {
      await HomeWidget.updateWidget(
        name: _providerName,
        qualifiedAndroidName: _qualifiedAndroidName,
      );
    } on Exception catch (e, stack) {
      debugPrint('Failed to update widgets: $e\n$stack');
    }
  }

  /// Toggles a task to the "Done" status option.
  ///
  /// Mirrors the completion logic in [TasksScreen] but works in the background
  /// so the widget checkbox can complete tasks without launching the UI.
  static Future<void> completeTask(NodeRepository repo, String uuid) async {
    final properties = await repo.fetchNodeProperties(uuid);
    final statusValue = properties.cast<NodePropertyValue?>().firstWhere(
          (p) => p?.property.uuid == SystemPropertyUuids.taskStatus,
          orElse: () => null,
        );

    if (statusValue == null) {
      throw StateError('Task status property not found');
    }

    var statusProperty = statusValue.property;
    if (statusProperty.options.isEmpty) {
      final available = await repo.fetchAvailableProperties(uuid);
      for (final p in available) {
        if (p.uuid == statusProperty.uuid) {
          statusProperty = p;
          break;
        }
      }
    }

    if (statusProperty.options.isEmpty) {
      throw StateError('Task status options not found');
    }

    final currentOption = statusValue.values.isNotEmpty
        ? _currentOption(statusValue.values.first, statusProperty.options)
        : null;
    final isClosed = currentOption != null && TaskStatuses.closed.contains(currentOption.name);
    final targetName = isClosed ? 'Pending' : 'Done';
    final targetOption = statusProperty.options.firstWhere(
      (o) => o.name == targetName,
      orElse: () => throw StateError('Option "$targetName" not found'),
    );

    await repo.setNodeProperty(uuid, statusProperty.uuid, targetOption.uuid);
  }

  static SelectionOption? _currentOption(dynamic value, List<SelectionOption> options) {
    final uuid = switch (value) {
      String s => s,
      Map<String, dynamic> m => m['selection_line_uuid'] as String?,
      _ => null,
    };
    if (uuid == null || uuid.isEmpty) return null;
    for (final o in options) {
      if (o.uuid == uuid) return o;
    }
    return null;
  }

  static DateTime? _taskDueDate(Node node) {
    return _extractDate(node.properties[SystemPropertyUuids.taskDeadline]) ??
        _extractDate(node.properties['due_date']) ??
        _extractDate(node.properties['deadline']);
  }

  static DateTime? _extractDate(dynamic value) {
    if (value == null) return null;
    if (value is DateTime) return value;
    if (value is String) {
      final parsed = DateTime.tryParse(value);
      if (parsed != null) return parsed;
    }
    return null;
  }
}
