import 'dart:convert';

import 'package:shared_preferences/shared_preferences.dart';

/// Device-local record of recently opened nodes, most-recent-first.
///
/// The server's recent-pages list orders by `write_date`, so merely opening
/// a page never surfaces it there (only edits do). This record captures the
/// open action itself, mirroring the web client's local recents, and is
/// merged ahead of the server list on the Home screen.
class LocalRecentsRepository {
  LocalRecentsRepository(this._prefs);

  final SharedPreferences _prefs;

  static const _key = 'local_recent_node_uuids';
  static const _cap = 20;

  /// Uuids of recently opened nodes, most-recent-first. Unknown/absent
  /// entries are dropped lazily by the merge.
  List<String> get uuids {
    final raw = _prefs.getString(_key);
    if (raw == null || raw.isEmpty) return const [];
    try {
      final list = jsonDecode(raw);
      if (list is List) return list.whereType<String>().toList();
    } catch (_) {}
    return const [];
  }

  /// Records [uuid] as the most recent open: deduped, front-inserted, capped.
  Future<void> recordOpen(String uuid) async {
    if (uuid.isEmpty) return;
    final list = uuids.toList()
      ..remove(uuid)
      ..insert(0, uuid);
    final capped = list.take(_cap).toList();
    await _prefs.setString(_key, jsonEncode(capped));
  }
}
