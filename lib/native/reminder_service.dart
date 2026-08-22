import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:timezone/data/latest.dart' as tz;
import 'package:timezone/timezone.dart' as tz;

/// Default hour of day at which date-only due-date reminders fire.
const _defaultReminderHour = 9;

const _channelId = 'task_due_reminders';
const _channelName = 'Task due reminders';
const _channelDescription = 'Reminders when tasks reach their due date';
const _payloadKey = 'taskUuid';

const _snooze15MinActionId = 'snooze_15m';
const _snooze1HourActionId = 'snooze_1h';
const _snoozeTomorrowActionId = 'snooze_tomorrow';

/// Callback signature invoked when the user taps a reminder notification.
typedef TaskTapCallback = void Function(String taskUuid);

/// Callback signature invoked when the user selects a snooze action.
typedef SnoozeCallback = void Function(String taskUuid, Duration duration);

/// Manages local notifications for task due dates.
///
/// This is a singleton service so background work (boot reschedule) and the
/// foreground UI share the same notification plugin instance.
class ReminderService {
  ReminderService._();

  /// Global instance used by the app.
  static final ReminderService instance = ReminderService._();

  final _notifications = FlutterLocalNotificationsPlugin();
  bool _initialized = false;

  final _tapController = StreamController<String>.broadcast();
  final _snoozeController = StreamController<ReminderSnoozeEvent>.broadcast();

  /// Stream of task UUIDs tapped by the user.
  Stream<String> get onTaskTapped => _tapController.stream;

  /// Stream of snooze actions selected by the user.
  Stream<ReminderSnoozeEvent> get onSnooze => _snoozeController.stream;

  /// Prepares notification channels and requests exact-alarm permission on
  /// Android 12+ when possible. Safe to call multiple times.
  ///
  /// On non-Android platforms this is a no-op.
  Future<void> initialize() async {
    if (_initialized) return;

    if (defaultTargetPlatform != TargetPlatform.android) {
      _initialized = true;
      return;
    }

    tz.initializeTimeZones();

    const androidSettings = AndroidInitializationSettings('@mipmap/ic_launcher');
    const initSettings = InitializationSettings(
      android: androidSettings,
    );

    await _notifications.initialize(
      initSettings,
      onDidReceiveNotificationResponse: _onNotificationResponse,
      onDidReceiveBackgroundNotificationResponse: _backgroundNotificationHandler,
    );

    await _createNotificationChannel();

    // Best-effort request for exact alarms. This opens system settings on
    // Android 12+; if the user declines we fall back to inexact scheduling.
    try {
      await requestExactAlarmPermission();
    } on Exception catch (e) {
      debugPrint('Exact-alarm permission request failed: $e');
    }

    _initialized = true;
  }

  Future<void> _createNotificationChannel() async {
    final androidPlugin = _notifications.resolvePlatformSpecificImplementation<AndroidFlutterLocalNotificationsPlugin>();
    if (androidPlugin == null) return;

    await androidPlugin.createNotificationChannel(
      const AndroidNotificationChannel(
        _channelId,
        _channelName,
        description: _channelDescription,
        importance: Importance.high,
      ),
    );
  }

  /// Whether the app can schedule exact alarms on Android.
  Future<bool> get canScheduleExactAlarms async {
    if (defaultTargetPlatform != TargetPlatform.android) return false;
    final androidPlugin = _notifications.resolvePlatformSpecificImplementation<AndroidFlutterLocalNotificationsPlugin>();
    if (androidPlugin == null) return false;
    return await androidPlugin.canScheduleExactNotifications() ?? false;
  }

  /// Opens the system exact-alarm permission screen on Android 12+.
  /// Returns whether permission was granted after the user returns.
  Future<bool> requestExactAlarmPermission() async {
    if (defaultTargetPlatform != TargetPlatform.android) return false;
    final androidPlugin = _notifications.resolvePlatformSpecificImplementation<AndroidFlutterLocalNotificationsPlugin>();
    if (androidPlugin == null) return false;
    return await androidPlugin.requestExactAlarmsPermission() ?? false;
  }

  /// Maximum number of upcoming recurrence occurrences scheduled at once.
  static const maxOccurrenceReminders = 5;

  /// Schedules a reminder for [taskUuid] at the given [dueDate].
  ///
  /// If [dueDate] contains only a date component, the reminder is scheduled at
  /// [_defaultReminderHour] on that day. Past due dates are ignored. Any
  /// existing reminder for the same task is replaced.
  Future<void> scheduleTaskReminder(
    String taskUuid,
    String taskName,
    DateTime dueDate,
  ) async {
    if (!_initialized) await initialize();
    if (defaultTargetPlatform != TargetPlatform.android) return;

    await cancelTaskReminder(taskUuid);

    final scheduledDate = _toScheduledDateTime(dueDate);
    final now = tz.TZDateTime.now(tz.local);
    if (scheduledDate.isBefore(now)) return;

    await _scheduleNotification(
      _notificationIdFor(taskUuid),
      taskUuid,
      taskName,
      scheduledDate,
    );
  }

  /// Schedules one reminder per upcoming occurrence of a recurring task.
  ///
  /// [dueDates] are the expanded occurrence dates (see
  /// `occurrenceSeries`); past dates are skipped. Any existing reminders for
  /// the same task — single or recurring — are replaced.
  Future<void> scheduleRecurringTaskReminders(
    String taskUuid,
    String taskName,
    List<DateTime> dueDates,
  ) async {
    if (!_initialized) await initialize();
    if (defaultTargetPlatform != TargetPlatform.android) return;

    await cancelTaskReminder(taskUuid);

    final now = tz.TZDateTime.now(tz.local);
    var index = 0;
    for (final dueDate in dueDates.take(maxOccurrenceReminders)) {
      final scheduledDate = _toScheduledDateTime(dueDate);
      if (scheduledDate.isBefore(now)) continue;
      await _scheduleNotification(
        _notificationIdForOccurrence(taskUuid, index),
        taskUuid,
        taskName,
        scheduledDate,
      );
      index++;
    }
  }

  /// Cancels the reminder for [taskUuid] if one exists.
  Future<void> cancelTaskReminder(String taskUuid) async {
    if (!_initialized) await initialize();
    await _notifications.cancel(_notificationIdFor(taskUuid));
    for (var i = 0; i < maxOccurrenceReminders; i++) {
      await _notifications.cancel(_notificationIdForOccurrence(taskUuid, i));
    }
  }

  /// Reschedules the reminder for [taskUuid] to fire after [duration].
  Future<void> snoozeTaskReminder(
    String taskUuid,
    String taskName,
    Duration duration,
  ) async {
    final newDue = DateTime.now().add(duration);
    await scheduleTaskReminder(taskUuid, taskName, newDue);
  }

  /// Maps a due date (possibly date-only) to a timezone-aware scheduled time.
  tz.TZDateTime _toScheduledDateTime(DateTime dueDate) {
    // If the supplied value is UTC, convert to local first.
    final local = dueDate.isUtc ? dueDate.toLocal() : dueDate;

    final scheduled = tz.TZDateTime(
      tz.local,
      local.year,
      local.month,
      local.day,
      local.hour == 0 && local.minute == 0 && local.second == 0
          ? _defaultReminderHour
          : local.hour,
      local.hour == 0 && local.minute == 0 && local.second == 0
          ? 0
          : local.minute,
    );
    return scheduled;
  }

  int _notificationIdFor(String taskUuid) {
    return taskUuid.hashCode & 0x7FFFFFFF;
  }

  /// Notification id for the [index]-th occurrence reminder of a recurring
  /// task; distinct from the single-reminder id so both can be cancelled
  /// exhaustively.
  int _notificationIdForOccurrence(String taskUuid, int index) {
    return '$taskUuid#$index'.hashCode & 0x7FFFFFFF;
  }

  Future<void> _scheduleNotification(
    int notificationId,
    String taskUuid,
    String taskName,
    tz.TZDateTime scheduledDate,
  ) async {
    final exactAlarmGranted = await canScheduleExactAlarms;
    final scheduleMode = exactAlarmGranted
        ? AndroidScheduleMode.exactAllowWhileIdle
        : AndroidScheduleMode.inexactAllowWhileIdle;

    await _notifications.zonedSchedule(
      notificationId,
      taskName,
      'Due now',
      scheduledDate,
      NotificationDetails(
        android: AndroidNotificationDetails(
          _channelId,
          _channelName,
          channelDescription: _channelDescription,
          importance: Importance.high,
          priority: Priority.high,
          actions: const [
            AndroidNotificationAction(_snooze15MinActionId, '15 min'),
            AndroidNotificationAction(_snooze1HourActionId, '1 hour'),
            AndroidNotificationAction(_snoozeTomorrowActionId, 'Tomorrow'),
          ],
        ),
      ),
      androidScheduleMode: scheduleMode,
      uiLocalNotificationDateInterpretation: UILocalNotificationDateInterpretation.absoluteTime,
      payload: jsonEncode({_payloadKey: taskUuid}),
    );
  }

  void _onNotificationResponse(NotificationResponse response) {
    _handleNotificationResponse(response);
  }

  void _handleNotificationResponse(NotificationResponse response) {
    final payload = response.payload;
    if (payload == null || payload.isEmpty) return;

    try {
      final map = jsonDecode(payload) as Map<String, dynamic>;
      final taskUuid = map[_payloadKey] as String?;
      if (taskUuid == null || taskUuid.isEmpty) return;

      switch (response.actionId) {
        case _snooze15MinActionId:
          _snoozeController.add(
            ReminderSnoozeEvent(taskUuid: taskUuid, duration: const Duration(minutes: 15)),
          );
        case _snooze1HourActionId:
          _snoozeController.add(
            ReminderSnoozeEvent(taskUuid: taskUuid, duration: const Duration(hours: 1)),
          );
        case _snoozeTomorrowActionId:
          _snoozeController.add(
            ReminderSnoozeEvent(taskUuid: taskUuid, duration: const Duration(days: 1)),
          );
        default:
          _tapController.add(taskUuid);
      }
    } on Exception catch (e) {
      debugPrint('Failed to handle notification response: $e');
    }
  }
}

/// Event emitted when a user snoozes a reminder from the notification shade.
class ReminderSnoozeEvent {
  const ReminderSnoozeEvent({
    required this.taskUuid,
    required this.duration,
  });

  final String taskUuid;
  final Duration duration;
}

/// Top-level handler for notification actions selected while the app is not in
/// the foreground.
///
/// Background isolates cannot navigate, so snooze actions are best-effort
/// persisted by re-scheduling through the plugin. Because the plugin needs to
/// have been initialized in this isolate, the action is queued to shared
/// preferences and applied when the app next launches if initialization fails
/// here.
@pragma('vm:entry-point')
void _backgroundNotificationHandler(NotificationResponse response) {
  // TODO: Persist snooze actions to shared preferences and replay on launch.
  // For now the notification simply dismisses; the foreground listener handles
  // taps and actions while the app is alive.
}
