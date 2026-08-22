import 'package:sqflite_sqlcipher/sqflite.dart';

import '../../domain/models/relay/hlc.dart';
import '../local/app_database.dart';

/// Persistent store for relay sync watermarks.
class SyncWatermarkRepository {
  SyncWatermarkRepository(this._database);

  final AppDatabase _database;

  Future<Hlc?> getReceived(String workspaceId) async {
    final db = await _database.database;
    final rows = await db.query(
      'sync_watermark',
      where: 'workspace_id = ?',
      whereArgs: [workspaceId],
      limit: 1,
    );
    if (rows.isEmpty) return null;
    final row = rows.first;
    return Hlc(
      physical: row['hlc_physical'] as int,
      logical: row['hlc_logical'] as int,
    );
  }

  Future<void> setReceived(
    String workspaceId,
    Hlc hlc, {
    int restoreEpoch = 0,
    int cursorSeq = 0,
  }) async {
    final db = await _database.database;
    await db.insert(
      'sync_watermark',
      {
        'workspace_id': workspaceId,
        'hlc_physical': hlc.physical,
        'hlc_logical': hlc.logical,
        'restore_epoch': restoreEpoch,
        'cursor_seq': cursorSeq,
      },
      conflictAlgorithm: ConflictAlgorithm.replace,
    );
  }

  /// Highest applied server-assigned envelope seq for [workspaceId].
  /// Returns `0` (full catch-up) when no row exists yet.
  Future<int> getCursorSeq(String workspaceId) async {
    final db = await _database.database;
    final rows = await db.query(
      'sync_watermark',
      columns: ['cursor_seq'],
      where: 'workspace_id = ?',
      whereArgs: [workspaceId],
      limit: 1,
    );
    if (rows.isEmpty) return 0;
    return rows.first['cursor_seq'] as int? ?? 0;
  }

  Future<Hlc?> getPushed(String workspaceId) async {
    final db = await _database.database;
    final rows = await db.query(
      'sync_push_watermark',
      where: 'workspace_id = ?',
      whereArgs: [workspaceId],
      limit: 1,
    );
    if (rows.isEmpty) return null;
    final row = rows.first;
    return Hlc(
      physical: row['hlc_physical'] as int,
      logical: row['hlc_logical'] as int,
    );
  }

  Future<void> setPushed(String workspaceId, Hlc hlc) async {
    final db = await _database.database;
    await db.insert(
      'sync_push_watermark',
      {
        'workspace_id': workspaceId,
        'hlc_physical': hlc.physical,
        'hlc_logical': hlc.logical,
      },
      conflictAlgorithm: ConflictAlgorithm.replace,
    );
  }

  Future<int> getRestoreEpoch(String workspaceId) async {
    final db = await _database.database;
    final rows = await db.query(
      'sync_watermark',
      columns: ['restore_epoch'],
      where: 'workspace_id = ?',
      whereArgs: [workspaceId],
      limit: 1,
    );
    if (rows.isEmpty) return 0;
    return rows.first['restore_epoch'] as int? ?? 0;
  }

  Future<void> resetWorkspace(String workspaceId) async {
    final db = await _database.database;
    await db.delete(
      'sync_watermark',
      where: 'workspace_id = ?',
      whereArgs: [workspaceId],
    );
    await db.delete(
      'sync_push_watermark',
      where: 'workspace_id = ?',
      whereArgs: [workspaceId],
    );
    await db.delete(
      'relay_operations',
      where: 'workspace_id = ?',
      whereArgs: [workspaceId],
    );
    await db.delete(
      'relay_outbox',
      where: "envelope_json LIKE ?",
      whereArgs: ['%"workspaceId":"$workspaceId"%'],
    );
  }
}
