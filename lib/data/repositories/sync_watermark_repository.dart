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
    // A targeted upsert, not a row replace: the received watermark is
    // persisted on every catch-up page and must not wipe the
    // uploaded-snapshot columns written by [setUploadedSnapshotHlc].
    await db.rawInsert(
      'INSERT INTO sync_watermark ('
      'workspace_id, hlc_physical, hlc_logical, restore_epoch, cursor_seq) '
      'VALUES (?, ?, ?, ?, ?) '
      'ON CONFLICT(workspace_id) DO UPDATE SET '
      'hlc_physical = excluded.hlc_physical, '
      'hlc_logical = excluded.hlc_logical, '
      'restore_epoch = excluded.restore_epoch, '
      'cursor_seq = excluded.cursor_seq',
      [workspaceId, hlc.physical, hlc.logical, restoreEpoch, cursorSeq],
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
    await db.insert('sync_push_watermark', {
      'workspace_id': workspaceId,
      'hlc_physical': hlc.physical,
      'hlc_logical': hlc.logical,
    }, conflictAlgorithm: ConflictAlgorithm.replace);
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

  /// The HLC this device last covered with a client-uploaded snapshot
  /// (`uploadedSnapshotHlc` in the TS engine), or null when never uploaded.
  /// Durable across restarts; a workspace reset drops it.
  Future<Hlc?> getUploadedSnapshotHlc(String workspaceId) async {
    final db = await _database.database;
    final rows = await db.query(
      'sync_watermark',
      columns: [
        'uploaded_snapshot_hlc_physical',
        'uploaded_snapshot_hlc_logical',
      ],
      where: 'workspace_id = ?',
      whereArgs: [workspaceId],
      limit: 1,
    );
    if (rows.isEmpty) return null;
    final row = rows.first;
    final physical = row['uploaded_snapshot_hlc_physical'];
    if (physical == null) return null;
    return Hlc(
      physical: physical as int,
      logical: row['uploaded_snapshot_hlc_logical'] as int? ?? 0,
    );
  }

  /// Records the covering HLC of a client-uploaded snapshot, preserving the
  /// row's other watermark columns (a first insert seeds a zero received
  /// watermark — the catch-up overwrites it).
  Future<void> setUploadedSnapshotHlc(String workspaceId, Hlc hlc) async {
    final db = await _database.database;
    await db.rawInsert(
      'INSERT INTO sync_watermark ('
      'workspace_id, hlc_physical, hlc_logical, restore_epoch, cursor_seq, '
      'uploaded_snapshot_hlc_physical, uploaded_snapshot_hlc_logical) '
      'VALUES (?, 0, 0, 0, 0, ?, ?) '
      'ON CONFLICT(workspace_id) DO UPDATE SET '
      'uploaded_snapshot_hlc_physical = excluded.uploaded_snapshot_hlc_physical, '
      'uploaded_snapshot_hlc_logical = excluded.uploaded_snapshot_hlc_logical',
      [workspaceId, hlc.physical, hlc.logical],
    );
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
    // The outbox deliberately survives a workspace reset: unsent local ops
    // are parked (restoreEpoch recovery) and re-pushed after the resync
    // catch-up; envelope-id dedupe on the server makes the overlap harmless.
  }
}
