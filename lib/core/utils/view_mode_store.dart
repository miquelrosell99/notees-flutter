import 'package:shared_preferences/shared_preferences.dart';

import '../../presentation/views/node_view_mode.dart';

/// Persists the preferred node collection view mode per screen.
class ViewModeStore {
  ViewModeStore({SharedPreferences? prefs}) : _prefs = prefs;

  SharedPreferences? _prefs;

  Future<SharedPreferences> _getPrefs() async {
    _prefs ??= await SharedPreferences.getInstance();
    return _prefs!;
  }

  String _key(String screen) => 'view_mode_$screen';

  Future<NodeViewMode> getMode(String screen, NodeViewMode fallback) async {
    final prefs = await _getPrefs();
    final value = prefs.getString(_key(screen));
    if (value == null) return fallback;
    return NodeViewMode.values.firstWhere(
      (m) => m.name == value,
      orElse: () => fallback,
    );
  }

  Future<void> setMode(String screen, NodeViewMode mode) async {
    final prefs = await _getPrefs();
    await prefs.setString(_key(screen), mode.name);
  }
}
