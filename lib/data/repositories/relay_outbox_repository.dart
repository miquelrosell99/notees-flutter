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
    // Envelopes persisted before protocolVersion existed are locally
    // produced; stamp the current version so strict envelope parsing can
    // proceed. Rows still failing parse (e.g. legacy v1 shapes predating
    // deviceId) are surfaced by the outbox repository, which quarantines
    // them instead of letting flush() wedge on an unreadable outbox.
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
    final pending = <PendingRelayEnvelope>[];
    for (final row in rows) {
      try {
        pending.add(PendingRelayEnvelope.fromRow(row));
      } on FormatException {
        // Unreadable (e.g. legacy v1) envelope: quarantine the row so a
        // stale outbox entry cannot wedge the sync loop; it stays
        // inspectable in `relay_outbox`.
        await db.update(
          'relay_outbox',
          {
            'state': 'quarantined',
            'last_error': 'Unparseable envelope (legacy protocol version?)',
            'next_retry_at': null,
          },
          where: 'id = ?',
          whereArgs: [row['id']],
        );
      }
    }
    return pending;
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

  /// Removes rows whose envelope carries one of [envelopeIds] — the WS
  /// `ack` frame path (acknowledgements arrive as envelope ids, not row ids).
  Future<void> removeByEnvelopeIds(List<String> envelopeIds) async {
    if (envelopeIds.isEmpty) return;
    final db = await _database.database;
    for (final id in envelopeIds) {
      await db.delete(
        'relay_outbox',
        where: 'envelope_json LIKE ?',
        whereArgs: ['%"id":"$id"%'],
      );
    }
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
