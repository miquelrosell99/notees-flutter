import 'dart:convert';

import 'package:sqflite_sqlcipher/sqflite.dart';

import '../../data/local/app_database.dart';
import '../../data/models/node.dart';

/// Local cache of server node state populated by pull sync.
class NodeCacheRepository {
  NodeCacheRepository(this._database);

  final AppDatabase _database;

  static const _lastSyncKey = 'sync_v1_last_sync';

  Future<String?> getLastSync() async {
    final db = await _database.database;
    final rows = await db.query('sync_state', where: 'key = ?', whereArgs: [_lastSyncKey]);
    if (rows.isEmpty) return null;
    return rows.first['value'] as String?;
  }

  Future<void> setLastSync(String? value) async {
    final db = await _database.database;
    if (value == null) {
      await db.delete('sync_state', where: 'key = ?', whereArgs: [_lastSyncKey]);
      return;
    }
    await db.insert(
      'sync_state',
      {'key': _lastSyncKey, 'value': value},
      conflictAlgorithm: ConflictAlgorithm.replace,
    );
  }

  Future<void> upsert(Node node) async {
    final db = await _database.database;
    await db.insert(
      'node_cache',
      {
        'uuid': node.uuid,
        'name': node.name,
        'parent_uuid': node.parentUuid,
        'sequence': node.sequence,
        'is_deleted': node.isDeleted ? 1 : 0,
        'version': node.id, // Use server numeric id as version proxy.
        'write_date': node.writeDate,
        'payload': jsonEncode(node.toJson()),
        'synced_at': DateTime.now().millisecondsSinceEpoch,
      },
      conflictAlgorithm: ConflictAlgorithm.replace,
    );
  }

  Future<void> upsertMany(List<Node> nodes) async {
    final db = await _database.database;
    final batch = db.batch();
    final now = DateTime.now().millisecondsSinceEpoch;
    for (final node in nodes) {
      batch.insert(
        'node_cache',
        {
          'uuid': node.uuid,
          'name': node.name,
          'parent_uuid': node.parentUuid,
          'sequence': node.sequence,
          'is_deleted': node.isDeleted ? 1 : 0,
          'version': node.id,
          'write_date': node.writeDate,
          'payload': jsonEncode(node.toJson()),
          'synced_at': now,
        },
        conflictAlgorithm: ConflictAlgorithm.replace,
      );
    }
    await batch.commit(noResult: true);
  }

  Future<void> deleteByUuid(String uuid) async {
    final db = await _database.database;
    await db.delete('node_cache', where: 'uuid = ?', whereArgs: [uuid]);
  }

  Future<void> deleteByUuids(List<String> uuids) async {
    if (uuids.isEmpty) return;
    final db = await _database.database;
    final placeholders = uuids.map((_) => '?').join(',');
    await db.rawDelete('DELETE FROM node_cache WHERE uuid IN ($placeholders)', uuids);
  }

  Future<Node?> getByUuid(String uuid) async {
    final db = await _database.database;
    final rows = await db.query('node_cache', where: 'uuid = ?', whereArgs: [uuid]);
    if (rows.isEmpty) return null;
    final payload = rows.first['payload'] as String?;
    if (payload == null) return null;
    return Node.fromJson(jsonDecode(payload) as Map<String, dynamic>);
  }

  Future<List<Node>> getAll({bool includeDeleted = false}) async {
    final db = await _database.database;
    final rows = await db.query(
      'node_cache',
      where: includeDeleted ? null : 'is_deleted = 0',
    );
    return rows.map((row) {
      final payload = row['payload'] as String;
      return Node.fromJson(jsonDecode(payload) as Map<String, dynamic>);
    }).toList();
  }

  Future<void> clear() async {
    final db = await _database.database;
    await db.delete('node_cache');
  }
}
