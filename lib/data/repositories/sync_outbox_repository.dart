import 'dart:convert';

import '../../domain/models/sync_v2.dart';
import '../local/app_database.dart';

/// Pending sync operation stored in the local outbox.
class PendingSyncOp {
  const PendingSyncOp({
    required this.id,
    required this.operation,
    required this.clientId,
    required this.seq,
    required this.attemptCount,
    this.lastError,
    this.nextRetryAt,
    required this.createdAt,
  });

  final int id;
  final OperationIntent operation;
  final String clientId;
  final int seq;
  final int attemptCount;
  final String? lastError;
  final DateTime? nextRetryAt;
  final DateTime createdAt;

  factory PendingSyncOp.fromRow(Map<String, dynamic> row) => PendingSyncOp(
        id: row['id'] as int,
        operation: OperationIntent.fromJson(
          jsonDecode(row['op_json'] as String) as Map<String, dynamic>,
        ),
        clientId: row['client_id'] as String,
        seq: row['seq'] as int,
        attemptCount: row['attempt_count'] as int,
        lastError: row['last_error'] as String?,
        nextRetryAt: row['next_retry_at'] != null
            ? DateTime.fromMillisecondsSinceEpoch(row['next_retry_at'] as int)
            : null,
        createdAt: DateTime.fromMillisecondsSinceEpoch(row['created_at'] as int),
      );
}

/// Local outbox for v2 sync operations.
class SyncOutboxRepository {
  SyncOutboxRepository(this._database);

  final AppDatabase _database;

  Future<int> enqueue(OperationIntent operation) async {
    final db = await _database.database;
    return db.insert('sync_outbox', {
      'op_json': jsonEncode(operation.toJson()),
      'client_id': operation.clientId,
      'seq': operation.seq,
      'attempt_count': 0,
      'created_at': DateTime.now().millisecondsSinceEpoch,
    });
  }

  Future<List<PendingSyncOp>> pending({DateTime? before}) async {
    final db = await _database.database;
    final now = before ?? DateTime.now();
    final rows = await db.query(
      'sync_outbox',
      where: 'next_retry_at IS NULL OR next_retry_at <= ?',
      whereArgs: [now.millisecondsSinceEpoch],
      orderBy: 'seq ASC',
    );
    return rows.map(PendingSyncOp.fromRow).toList();
  }

  Future<void> remove(int id) async {
    final db = await _database.database;
    await db.delete('sync_outbox', where: 'id = ?', whereArgs: [id]);
  }

  Future<void> removeAll(List<int> ids) async {
    final db = await _database.database;
    await db.delete(
      'sync_outbox',
      where: 'id IN (${ids.map((_) => '?').join(', ')})',
      whereArgs: ids,
    );
  }

  Future<void> removeByNodeUuids(List<String> nodeUuids) async {
    if (nodeUuids.isEmpty) return;
    final db = await _database.database;
    final all = await pending();
    final idsToRemove = all
        .where((op) => nodeUuids.contains(op.operation.nodeUuid))
        .map((op) => op.id)
        .toList();
    if (idsToRemove.isNotEmpty) {
      await removeAll(idsToRemove);
    }
  }

  Future<void> markRetry({
    required int id,
    required String error,
    required DateTime nextRetryAt,
  }) async {
    final db = await _database.database;
    await db.update(
      'sync_outbox',
      {
        'attempt_count': 1,
        'last_error': error,
        'next_retry_at': nextRetryAt.millisecondsSinceEpoch,
      },
      where: 'id = ?',
      whereArgs: [id],
    );
  }
}

/// Persistent store for sync vector clock state and client identity.
class VectorClockStore {
  VectorClockStore(this._database);

  final AppDatabase _database;

  Future<String?> read(String key) async {
    final db = await _database.database;
    final rows = await db.query(
      'sync_state',
      columns: ['value'],
      where: 'key = ?',
      whereArgs: [key],
      limit: 1,
    );
    if (rows.isEmpty) return null;
    return rows.first['value'] as String;
  }

  Future<void> write(String key, String value) async {
    final db = await _database.database;
    await db.insert(
      'sync_state',
      {'key': key, 'value': value},
      conflictAlgorithm: ConflictAlgorithm.replace,
    );
  }
}
