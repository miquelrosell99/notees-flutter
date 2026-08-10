import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../../core/constants/capture_types.dart';
import '../../presentation/views/node_view_mode.dart';

/// Where quick-captured notes and audio recordings are saved.
enum QuickCaptureDestination {
  inbox,
  today,
}

/// Which screen the Home tab shows.
enum HomePage {
  inbox,
  today,
}

/// Persists user settings that are not handled by [ThemeProvider].
class SettingsProvider extends ChangeNotifier {
  SettingsProvider(this._prefs);

  final SharedPreferences _prefs;

  // --- Editor ---------------------------------------------------------------

  NodeViewMode get defaultViewMode {
    final raw = _prefs.getString(_defaultViewModeKey);
    return NodeViewMode.values.firstWhere(
      (m) => m.name == raw,
      orElse: () => NodeViewMode.list,
    );
  }

  int get linkedRefsCollapseLevel =>
      _prefs.getInt(_linkedRefsCollapseLevelKey) ?? 1;

  /// 0 = Sunday, 1 = Monday, 6 = Saturday.
  int get firstDayOfWeek => _prefs.getInt(_firstDayOfWeekKey) ?? 0;

  String get dateFormat => _prefs.getString(_dateFormatKey) ?? 'YYYY/MM/DD';

  QuickCaptureDestination get quickCaptureDestination {
    final raw = _prefs.getString(_quickCaptureDestinationKey);
    return QuickCaptureDestination.values.firstWhere(
      (d) => d.name == raw,
      orElse: () => QuickCaptureDestination.inbox,
    );
  }

  HomePage get homePage {
    final raw = _prefs.getString(_homePageKey);
    return HomePage.values.firstWhere(
      (p) => p.name == raw,
      orElse: () => HomePage.inbox,
    );
  }

  bool get floatingCaptureBubbleEnabled =>
      _prefs.getBool(_floatingCaptureBubbleEnabledKey) ?? false;

  QuickCaptureType get floatingCaptureBubbleDefaultType {
    final raw = _prefs.getString(_floatingCaptureBubbleDefaultTypeKey);
    return QuickCaptureType.values.firstWhere(
      (t) => t.name == raw,
      orElse: () => QuickCaptureType.note,
    );
  }

  Future<void> setDefaultViewMode(NodeViewMode value) async {
    await _prefs.setString(_defaultViewModeKey, value.name);
    HapticFeedback.lightImpact();
    notifyListeners();
  }

  Future<void> setLinkedRefsCollapseLevel(int value) async {
    await _prefs.setInt(_linkedRefsCollapseLevelKey, value);
    HapticFeedback.lightImpact();
    notifyListeners();
  }

  Future<void> setFirstDayOfWeek(int value) async {
    await _prefs.setInt(_firstDayOfWeekKey, value);
    HapticFeedback.lightImpact();
    notifyListeners();
  }

  Future<void> setDateFormat(String value) async {
    await _prefs.setString(_dateFormatKey, value);
    HapticFeedback.lightImpact();
    notifyListeners();
  }

  Future<void> setQuickCaptureDestination(QuickCaptureDestination value) async {
    await _prefs.setString(_quickCaptureDestinationKey, value.name);
    HapticFeedback.lightImpact();
    notifyListeners();
  }

  Future<void> setHomePage(HomePage value) async {
    await _prefs.setString(_homePageKey, value.name);
    HapticFeedback.lightImpact();
    notifyListeners();
  }

  Future<void> setFloatingCaptureBubbleEnabled(bool value) async {
    await _prefs.setBool(_floatingCaptureBubbleEnabledKey, value);
    HapticFeedback.lightImpact();
    notifyListeners();
  }

  Future<void> setFloatingCaptureBubbleDefaultType(QuickCaptureType value) async {
    await _prefs.setString(_floatingCaptureBubbleDefaultTypeKey, value.name);
    HapticFeedback.lightImpact();
    notifyListeners();
  }

  // --- Graph / Workspace ----------------------------------------------------

  bool get showSidebarFavorites =>
      _prefs.getBool(_showSidebarFavoritesKey) ?? true;

  bool get showSidebarRecents =>
      _prefs.getBool(_showSidebarRecentsKey) ?? true;

  bool get showSidebarJournals =>
      _prefs.getBool(_showSidebarJournalsKey) ?? true;

  bool get showSidebarTasks =>
      _prefs.getBool(_showSidebarTasksKey) ?? true;

  bool get showSidebarPages =>
      _prefs.getBool(_showSidebarPagesKey) ?? true;

  bool get showSidebarGraph =>
      _prefs.getBool(_showSidebarGraphKey) ?? true;

  int get trashRetentionDays => _prefs.getInt(_trashRetentionDaysKey) ?? 30;

  Future<void> setShowSidebarFavorites(bool value) async {
    await _prefs.setBool(_showSidebarFavoritesKey, value);
    HapticFeedback.lightImpact();
    notifyListeners();
  }

  Future<void> setShowSidebarRecents(bool value) async {
    await _prefs.setBool(_showSidebarRecentsKey, value);
    HapticFeedback.lightImpact();
    notifyListeners();
  }

  Future<void> setShowSidebarJournals(bool value) async {
    await _prefs.setBool(_showSidebarJournalsKey, value);
    HapticFeedback.lightImpact();
    notifyListeners();
  }

  Future<void> setShowSidebarTasks(bool value) async {
    await _prefs.setBool(_showSidebarTasksKey, value);
    HapticFeedback.lightImpact();
    notifyListeners();
  }

  Future<void> setShowSidebarPages(bool value) async {
    await _prefs.setBool(_showSidebarPagesKey, value);
    HapticFeedback.lightImpact();
    notifyListeners();
  }

  Future<void> setShowSidebarGraph(bool value) async {
    await _prefs.setBool(_showSidebarGraphKey, value);
    HapticFeedback.lightImpact();
    notifyListeners();
  }

  Future<void> setTrashRetentionDays(int value) async {
    await _prefs.setInt(_trashRetentionDaysKey, value);
    HapticFeedback.lightImpact();
    notifyListeners();
  }

  // --- Keys -----------------------------------------------------------------

  static const _defaultViewModeKey = 'default_view_mode';
  static const _linkedRefsCollapseLevelKey = 'linked_refs_collapse_level';
  static const _firstDayOfWeekKey = 'first_day_of_week';
  static const _dateFormatKey = 'date_format';

  static const _showSidebarFavoritesKey = 'show_sidebar_favorites';
  static const _showSidebarRecentsKey = 'show_sidebar_recents';
  static const _showSidebarJournalsKey = 'show_sidebar_journals';
  static const _showSidebarTasksKey = 'show_sidebar_tasks';
  static const _showSidebarPagesKey = 'show_sidebar_pages';
  static const _showSidebarGraphKey = 'show_sidebar_graph';
  static const _trashRetentionDaysKey = 'trash_retention_days';
  static const _quickCaptureDestinationKey = 'quick_capture_destination';
  static const _homePageKey = 'home_page';
  static const _floatingCaptureBubbleEnabledKey =
      'floating_capture_bubble_enabled';
  static const _floatingCaptureBubbleDefaultTypeKey =
      'floating_capture_bubble_default_type';
}

/// Human-readable label for a [QuickCaptureType].
String quickCaptureTypeLabel(QuickCaptureType type) {
  return switch (type) {
    QuickCaptureType.note => 'Note',
    QuickCaptureType.task => 'Task',
    QuickCaptureType.voice => 'Voice',
    QuickCaptureType.photo => 'Photo',
    QuickCaptureType.journal => 'Journal',
  };
}

/// Human-readable label for a [QuickCaptureDestination].
String quickCaptureDestinationLabel(QuickCaptureDestination destination) {
  return switch (destination) {
    QuickCaptureDestination.inbox => 'Inbox',
    QuickCaptureDestination.today => "Today's note",
  };
}

/// Human-readable label for a [HomePage].
String homePageLabel(HomePage page) {
  return switch (page) {
    HomePage.inbox => 'Inbox',
    HomePage.today => 'Today',
  };
}

/// Supported date format patterns.
const List<String> kDateFormatOptions = [
  'YYYY/MM/DD',
  'YYYY-MM-DD',
  'DD/MM/YYYY',
  'DD-MM-YYYY',
  'MM/DD/YYYY',
  'MM-DD-YYYY',
];

/// Labels for first-day-of-week choices.
String firstDayOfWeekLabel(int day) {
  return switch (day) {
    0 => 'Sunday',
    1 => 'Monday',
    6 => 'Saturday',
    _ => 'Sunday',
  };
}

/// Format [date] using one of the supported [kDateFormatOptions].
String formatDateWithSettings(DateTime date, String format) {
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
