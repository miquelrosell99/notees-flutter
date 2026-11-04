import 'dart:convert';

import 'package:shared_preferences/shared_preferences.dart';

import '../../domain/graph/graph_color_group.dart';

/// Device-local persistence for the graph's color groups (the web
/// GraphView's localStorage rows twin). The persisted value is the JSON
/// list of group rows — the AST rides inside each row, so a stored list is
/// self-contained. [migrateColorGroup] runs at the GraphService load site,
/// not here: this store reads and writes RAW rows so the migration's
/// one-time rewrite can re-persist the migrated shapes.
class ColorGroupStore {
  ColorGroupStore({this._prefs});

  final SharedPreferences? _prefs;
  static const _key = 'graph_color_groups';

  Future<SharedPreferences> _getPrefs() async =>
      _prefs ?? await SharedPreferences.getInstance();

  /// The raw stored rows (legacy shapes included — the load site
  /// migrates). Absent/corrupt storage reads as an empty list.
  Future<List<Map<String, dynamic>>> load() async {
    final prefs = await _getPrefs();
    final raw = prefs.getString(_key);
    if (raw == null || raw.isEmpty) return const [];
    try {
      final decoded = jsonDecode(raw);
      if (decoded is! List) return const [];
      return [for (final row in decoded) Map<String, dynamic>.from(row as Map)];
    } catch (_) {
      return const [];
    }
  }

  /// Persists the group rows (migrated shapes — the AST, never the legacy
  /// DSL string) in list order, the first-match-wins priority.
  Future<void> save(List<GraphColorGroup> groups) async {
    final prefs = await _getPrefs();
    await prefs.setString(
      _key,
      jsonEncode([for (final group in groups) group.toJson()]),
    );
  }
}
