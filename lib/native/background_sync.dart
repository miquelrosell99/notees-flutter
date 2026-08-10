import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:workmanager/workmanager.dart';

import '../core/api/api_client.dart';
import '../core/constants/system.dart';
import '../core/secure/secure_storage.dart';
import '../core/utils/client_id.dart';
import '../data/local/app_database.dart';
import '../data/models/node.dart';
import '../data/repositories/node_repository.dart';
import '../data/repositories/server_repository.dart';
import '../domain/models/search_filters.dart';
import '../domain/services/offline_queue.dart';
import '../domain/services/sync_v2_service.dart';
import 'reminder_service.dart';
import 'widget_service.dart';

/// Unique identifier for the background sync Workmanager task.
const _backgroundSyncTask = 'notees.backgroundSync';

/// Unique identifier for the boot reschedule Workmanager task.
const _rescheduleRemindersTask = 'notees.rescheduleReminders';

/// Unique identifier for the widget data refresh Workmanager task.
const _widgetUpdateTask = 'notees.widgetUpdate';

/// Unique identifier for the widget "complete task" Workmanager task.
const _widgetCompleteTask = 'notees.widgetCompleteTask';

/// Unique name for the periodic sync work request.
const _periodicSyncName = 'notees-periodic-sync';

/// Unique name for the boot reschedule work request.
const _rescheduleRemindersName = 'notees-boot-reschedule-reminders';

/// Top-level callback invoked by the Android Workmanager in a background
/// isolate. It drains the offline queue against the active server.
@pragma('vm:entry-point')
void _backgroundSyncCallback() {
  Workmanager().executeTask((task, inputData) async {
    try {
      final prefs = await SharedPreferences.getInstance();

      // Widget tasks can run even while the local DB is encrypted because they
      // either only read from the server or fall back to REST mutations.
      if (task == _widgetUpdateTask) {
        await _updateWidgetData(prefs);
        return Future.value(true);
      }
      if (task == _widgetCompleteTask) {
        final uuid = inputData?['uuid'] as String?;
        if (uuid != null && uuid.isNotEmpty) {
          await _completeTaskFromWidget(prefs, uuid);
        }
        return Future.value(true);
      }

      // Background isolates cannot access an in-memory encryption key, so skip
      // all local-DB work while encryption is enabled.
      if (prefs.getBool('encryption_enabled') ?? false) {
        return Future.value(true);
      }

      const secureStorage = SecureStorage();
      final serverRepository = ServerRepository(prefs: prefs);
      final activeServer = await serverRepository.getActiveServer();
      if (activeServer == null) {
        return Future.value(true);
      }

      final dio = createApiClient(
        baseUrl: activeServer.url,
        secureStorage: secureStorage,
        trustSelfSigned: activeServer.trustSelfSigned,
        cookieJar: await sharedCookieJar(),
      );
      final clientId = await getClientId(prefs);
      final syncService = SyncV2Service(
        database: AppDatabase(),
        dio: dio,
        clientId: clientId,
      );

      if (task == _rescheduleRemindersTask) {
        await _rescheduleTaskReminders(dio: dio, syncService: syncService);
        return Future.value(true);
      }

      final queue = OfflineQueue(
        database: AppDatabase(),
        syncService: syncService,
      );
      await queue.process();
      await syncService.flush();
      await syncService.pull();
      await _updateWidgetData(prefs);

      return Future.value(true);
    } on DioException {
      // Network/server errors are expected in the background; retry later.
      return Future.value(false);
    } catch (_) {
      return Future.value(false);
    }
  });
}

/// Fetches open tasks with future due dates and re-schedules local reminders.
///
/// Called after device boot so exact alarms that were cleared by the system are
/// restored.
Future<void> _rescheduleTaskReminders({
  required Dio dio,
  required SyncV2Service syncService,
}) async {
  try {
    final repo = NodeRepository(dio: dio, syncService: syncService);
    final now = DateTime.now();
    final filters = SearchFilters(
      nodeType: NodeType.task,
      taskState: TaskState.open,
      dateFrom: now,
      sortBy: SortBy.dueDate,
      limit: 500,
    );
    final tasks = await repo.searchWithFilters(filters);

    for (final task in tasks) {
      final due = _taskDueDate(task);
      if (due != null && !due.isBefore(DateTime(now.year, now.month, now.day))) {
        await ReminderService.instance.scheduleTaskReminder(
          task.uuid,
          task.displayName,
          due,
        );
      }
    }
  } on Exception catch (e, stack) {
    debugPrint('Failed to reschedule reminders: $e\n$stack');
  }
}

DateTime? _taskDueDate(Node node) {
  return _extractDate(node.properties[SystemPropertyUuids.taskDeadline]) ??
      _extractDate(node.properties['due_date']) ??
      _extractDate(node.properties['deadline']);
}

DateTime? _extractDate(dynamic value) {
  if (value == null) return null;
  if (value is DateTime) return value;
  if (value is String) {
    final parsed = DateTime.tryParse(value);
    if (parsed != null) return parsed;
  }
  return null;
}

/// Fetches today's open tasks from the server and writes them to the widget
/// cache so the home-screen widget can display them.
Future<void> _updateWidgetData(SharedPreferences prefs) async {
  try {
    final serverRepository = ServerRepository(prefs: prefs);
    final activeServer = await serverRepository.getActiveServer();
    if (activeServer == null) {
      await WidgetService.clearWidgetData();
      return;
    }

    const secureStorage = SecureStorage();
    final dio = createApiClient(
      baseUrl: activeServer.url,
      secureStorage: secureStorage,
      trustSelfSigned: activeServer.trustSelfSigned,
      cookieJar: await sharedCookieJar(),
    );
    final clientId = await getClientId(prefs);
    // Background isolates cannot open an encrypted SQLCipher database, so fall
    // back to a stateless REST client for widget data refreshes.
    final encryptionEnabled = prefs.getBool('encryption_enabled') ?? false;
    final syncService = encryptionEnabled
        ? null
        : SyncV2Service(
            database: AppDatabase(),
            dio: dio,
            clientId: clientId,
          );
    final repo = NodeRepository(dio: dio, syncService: syncService);
    final tasks = await WidgetService.loadTodayTasksFromRepo(repo);
    await WidgetService.saveTodayTasks(tasks);
  } on DioException catch (e) {
    debugPrint('Widget update network error: $e');
  } on Exception catch (e, stack) {
    debugPrint('Widget update failed: $e\n$stack');
  }
}

/// Completes a task after the user taps a widget checkbox, then refreshes the
/// widget data so the completed task disappears.
Future<void> _completeTaskFromWidget(SharedPreferences prefs, String uuid) async {
  try {
    final serverRepository = ServerRepository(prefs: prefs);
    final activeServer = await serverRepository.getActiveServer();
    if (activeServer == null) return;

    const secureStorage = SecureStorage();
    final dio = createApiClient(
      baseUrl: activeServer.url,
      secureStorage: secureStorage,
      trustSelfSigned: activeServer.trustSelfSigned,
      cookieJar: await sharedCookieJar(),
    );
    final clientId = await getClientId(prefs);
    // When local DB encryption is enabled the background isolate cannot access
    // the SQLCipher key, so fall back to direct REST calls.
    final encryptionEnabled = prefs.getBool('encryption_enabled') ?? false;
    final syncService = encryptionEnabled
        ? null
        : SyncV2Service(
            database: AppDatabase(),
            dio: dio,
            clientId: clientId,
          );
    final repo = NodeRepository(dio: dio, syncService: syncService);
    await WidgetService.completeTask(repo, uuid);
    await syncService?.flush();
    await _updateWidgetData(prefs);
  } on DioException catch (e) {
    debugPrint('Complete task from widget network error: $e');
  } on Exception catch (e, stack) {
    debugPrint('Complete task from widget failed: $e\n$stack');
  }
}

/// Schedules and manages background sync on mobile.
class BackgroundSync {
  BackgroundSync._();

  static bool _initialized = false;

  /// Must be called once before [runApp].
  ///
  /// No-op on platforms without a Workmanager implementation (desktop, web).
  static Future<void> initialize() async {
    if (_initialized) return;
    if (defaultTargetPlatform != TargetPlatform.android &&
        defaultTargetPlatform != TargetPlatform.iOS) {
      return;
    }
    await Workmanager().initialize(_backgroundSyncCallback);
    _initialized = true;
  }

  /// Returns whether [initialize] completed successfully.
  static bool get isInitialized => _initialized;

  /// Registers a 15-minute periodic sync task that only runs when online.
  static Future<void> registerPeriodic() async {
    await Workmanager().registerPeriodicTask(
      _periodicSyncName,
      _backgroundSyncTask,
      frequency: const Duration(minutes: 15),
      constraints: Constraints(
        networkType: NetworkType.connected,
      ),
      existingWorkPolicy: ExistingPeriodicWorkPolicy.keep,
    );
  }

  /// Cancels the periodic sync task.
  static Future<void> cancel() async {
    await Workmanager().cancelByUniqueName(_periodicSyncName);
  }

  /// Schedules a one-off task that re-schedules pending task reminders.
  ///
  /// Called from [BootReceiver] after the device finishes booting. The work
  /// must be a one-off request because periodic work cannot be triggered from
  /// a broadcast receiver without an existing periodic schedule.
  static Future<void> scheduleReminderReschedule() async {
    await Workmanager().registerOneOffTask(
      _rescheduleRemindersName,
      _rescheduleRemindersTask,
      existingWorkPolicy: ExistingWorkPolicy.keep,
    );
  }
}
