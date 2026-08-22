import 'dart:convert';

import '../../domain/models/relay/operation_envelope.dart';
import '../local/app_database.dart';

/// Pending relay envelope stored in the local outbox.
class PendingRelayEnvelope {
  const PendingRelayEnvelope({
    required this.id,
    required this.envelope,
    required this.attemptCount,
    this.lastError,
    this.nextRetryAt,
    required this.createdAt,
  });

  final int id;
  final OperationEnvelope envelope;
  final int attemptCount;
  final String? lastError;
  final DateTime? nextRetryAt;
  final DateTime createdAt;

  factory PendingRelayEnvelope.fromRow(Map<String, dynamic> row) {
    final envelopeJson =
        jsonDecode(row['envelope_json'] as String) as Map<String, dynamic>;
    // Envelopes persisted before protocolVersion existed are locally produced
    // and always v1; stamp them so strict envelope parsing does not reject
    // the app's own outbox.
    envelopeJson.putIfAbsent('protocolVersion', () => kRelayProtocolVersion);
    return PendingRelayEnvelope(
      id: row['id'] as int,
      envelope: OperationEnvelope.fromJson(envelopeJson),
      attemptCount: row['attempt_count'] as int,
      lastError: row['last_error'] as String?,
      nextRetryAt: row['next_retry_at'] != null
          ? DateTime.fromMillisecondsSinceEpoch(row['next_retry_at'] as int)
          : null,
      createdAt: DateTime.fromMillisecondsSinceEpoch(row['created_at'] as int),
    );
  }
}

/// Local outbox for relay operation envelopes.
class RelayOutboxRepository {
  RelayOutboxRepository(this._database);

  final AppDatabase _database;

  static const List<int> _retryDelaysSeconds = [5, 15, 60, 300, 1800];

  Future<int> enqueue(OperationEnvelope envelope) async {
    final db = await _database.database;
    return db.insert('relay_outbox', {
      'envelope_json': jsonEncode(envelope.toJson()),
      'state': 'pending',
      'attempt_count': 0,
      'created_at': DateTime.now().millisecondsSinceEpoch,
    });
  }

  Future<List<PendingRelayEnvelope>> pending({DateTime? before}) async {
    final db = await _database.database;
    final now = before ?? DateTime.now();
    final rows = await db.query(
      'relay_outbox',
      where: "state IN ('pending', 'failed') AND "
          '(next_retry_at IS NULL OR next_retry_at <= ?)',
      whereArgs: [now.millisecondsSinceEpoch],
      orderBy: 'created_at ASC',
    );
    return rows.map(PendingRelayEnvelope.fromRow).toList();
  }

  Future<void> markInFlight(List<int> ids) async {
    if (ids.isEmpty) return;
    final db = await _database.database;
    await db.update(
      'relay_outbox',
      {'state': 'in_flight'},
      where: 'id IN (${ids.map((_) => '?').join(', ')})',
      whereArgs: ids,
    );
  }

  Future<void> markAcknowledged(List<int> ids) async {
    if (ids.isEmpty) return;
    final db = await _database.database;
    await db.update(
      'relay_outbox',
      {'state': 'acknowledged'},
      where: 'id IN (${ids.map((_) => '?').join(', ')})',
      whereArgs: ids,
    );
  }

  Future<void> markRetry({
    required int id,
    required String error,
  }) async {
    final db = await _database.database;
    final rows = await db.query(
      'relay_outbox',
      columns: ['attempt_count'],
      where: 'id = ?',
      whereArgs: [id],
      limit: 1,
    );
    final currentAttemptCount = rows.isEmpty ? 0 : rows.first['attempt_count'] as int;
    final newAttemptCount = currentAttemptCount + 1;

    if (newAttemptCount > _retryDelaysSeconds.length) {
      await db.update(
        'relay_outbox',
        {
          'state': 'quarantined',
          'attempt_count': newAttemptCount,
          'last_error': error,
          'next_retry_at': null,
        },
        where: 'id = ?',
        whereArgs: [id],
      );
      return;
    }

    final delaySeconds = _retryDelaysSeconds[currentAttemptCount];
    final nextRetryAt = DateTime.now().add(Duration(seconds: delaySeconds));

    await db.update(
      'relay_outbox',
      {
        'state': 'failed',
        'attempt_count': newAttemptCount,
        'last_error': error,
        'next_retry_at': nextRetryAt.millisecondsSinceEpoch,
      },
      where: 'id = ?',
      whereArgs: [id],
    );
  }

  Future<void> removeAll(List<int> ids) async {
    if (ids.isEmpty) return;
    final db = await _database.database;
    await db.delete(
      'relay_outbox',
      where: 'id IN (${ids.map((_) => '?').join(', ')})',
      whereArgs: ids,
    );
  }

  Future<void> clear() async {
    final db = await _database.database;
    await db.delete('relay_outbox');
  }
}
