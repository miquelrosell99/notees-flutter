import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:home_widget/home_widget.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../core/constants/system.dart';
import '../core/utils/node_display_name.dart';
import '../data/models/node.dart';
import '../data/models/property.dart';
import '../data/repositories/node_repository.dart';
import '../domain/models/search_filters.dart';

/// Flutter side of the Android home-screen widgets (today's tasks, favorites,
/// and the Inbox page preview).
///
/// Keeps small JSON snapshots in [SharedPreferences] where the native
/// [AppWidgetProvider]s can read them, and asks the native side to redraw the
/// widgets via [home_widget].
class WidgetService {
  WidgetService._();

  static const _tasksKey = 'notees.widget_tasks';
  static const _updatedAtKey = 'notees.widget_tasks_updated_at';
  static const _favoritesKey = 'notees.widget_favorites';
  static const _inboxBlocksKey = 'notees.widget_inbox_blocks';
  static const _providerName = 'TaskWidgetProvider';
  static const _qualifiedAndroidName = 'com.notees.notees.TaskWidgetProvider';
  static const _favoritesProviderName = 'FavoritesWidgetProvider';
  static const _favoritesQualifiedAndroidName =
      'com.notees.notees.FavoritesWidgetProvider';
  static const _pageProviderName = 'PageWidgetProvider';
  static const _pageQualifiedAndroidName =
      'com.notees.notees.PageWidgetProvider';

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

  /// Persists the favorite pages and triggers a widget redraw.
  static Future<void> saveFavorites(List<Node> favorites) async {
    final prefs = await SharedPreferences.getInstance();
    final payload = favorites.map((node) {
      return <String, String>{
        'uuid': node.uuid,
        'displayName': resolveNodeDisplayName(node),
      };
    }).toList();

    await prefs.setString(_favoritesKey, jsonEncode(payload));
    await updateWidgets();
  }

  /// Persists the Inbox page's first blocks for the page-preview widget and
  /// triggers a widget redraw.
  static Future<void> saveInboxBlocks(List<Node> blocks) async {
    final prefs = await SharedPreferences.getInstance();
    final payload = blocks.map((block) {
      return <String, String>{
        'uuid': block.uuid,
        'displayName': resolveNodeDisplayName(block),
      };
    }).toList();

    await prefs.setString(_inboxBlocksKey, jsonEncode(payload));
    await updateWidgets();
  }

  /// Clears cached widget data (e.g. when the user signs out).
  static Future<void> clearWidgetData() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.remove(_tasksKey);
    await prefs.remove(_updatedAtKey);
    await prefs.remove(_favoritesKey);
    await prefs.remove(_inboxBlocksKey);
    await updateWidgets();
  }

  /// Refreshes the favorites and Inbox widget snapshots from [repo].
  ///
  /// Best effort: each snapshot is independent and failures are logged, not
  /// rethrown, so a locked or empty local cache never breaks the caller.
  static Future<void> refreshSnapshots(NodeRepository repo) async {
    try {
      await saveFavorites(await loadFavoritesFromRepo(repo));
    } catch (e, stack) {
      debugPrint('Favorites widget refresh failed: $e\n$stack');
    }
    try {
      await saveInboxBlocks(await loadInboxBlocksFromRepo(repo));
    } catch (e, stack) {
      debugPrint('Inbox widget refresh failed: $e\n$stack');
    }
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

  /// Fetches the user's favorite pages from the local cache.
  static Future<List<Node>> loadFavoritesFromRepo(NodeRepository repo) {
    return repo.fetchFavorites(limit: 10);
  }

  /// Fetches the first blocks of the Inbox page from the local cache.
  static Future<List<Node>> loadInboxBlocksFromRepo(NodeRepository repo) async {
    final content = await repo.fetchInboxContent();
    return content.node.children.take(10).toList();
  }

  /// Asks the native widget providers to redraw all widget instances.
  static Future<void> updateWidgets() async {
    const providers = [
      (_providerName, _qualifiedAndroidName),
      (_favoritesProviderName, _favoritesQualifiedAndroidName),
      (_pageProviderName, _pageQualifiedAndroidName),
    ];
    for (final (name, qualifiedName) in providers) {
      try {
        await HomeWidget.updateWidget(
          name: name,
          qualifiedAndroidName: qualifiedName,
        );
      } on Exception catch (e, stack) {
        debugPrint('Failed to update widgets: $e\n$stack');
      }
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
