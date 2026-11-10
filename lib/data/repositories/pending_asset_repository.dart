import '../local/app_database.dart';

/// One row of the `pending_asset` queue — a captured file waiting for its
/// upload+attach, or a dead-lettered failure surfaced in Settings.
class PendingAssetRow {
  const PendingAssetRow({
    required this.id,
    required this.localPath,
    required this.mime,
    required this.originalName,
    required this.sizeBytes,
    required this.state,
    required this.retryCount,
    required this.createdAt,
    this.nodeUuid,
    this.parentUuid,
    this.lastError,
    this.lastAttemptAt,
    this.nextAttemptAt,
  });

  final String id;
  final String localPath;
  final String? nodeUuid;
  final String? parentUuid;
  final String mime;
  final String originalName;
  final int sizeBytes;

  /// `pending` (awaiting a drain round) or `failed` (dead-lettered after the
  /// attempt budget — user retry/discard from Settings → Sync).
  final String state;
  final int retryCount;
  final String? lastError;
  final int createdAt;
  final int? lastAttemptAt;
  final int? nextAttemptAt;

  bool get isPending => state == 'pending';

  factory PendingAssetRow.fromMap(Map<String, dynamic> map) => PendingAssetRow(
        id: map['id'] as String,
        localPath: map['local_path'] as String,
        nodeUuid: map['node_uuid'] as String?,
        parentUuid: map['parent_uuid'] as String?,
        mime: map['mime'] as String,
        originalName: map['original_name'] as String,
        sizeBytes: map['size_bytes'] as int,
        state: map['state'] as String? ?? 'pending',
        retryCount: map['retry_count'] as int? ?? 0,
        lastError: map['last_error'] as String?,
        createdAt: map['created_at'] as int,
        lastAttemptAt: map['last_attempt_at'] as int?,
        nextAttemptAt: map['next_attempt_at'] as int?,
      );
}

/// CRUD + drain scheduling for the `pending_asset` queue. The drain state
/// machine itself lives in `PendingAssetService`; this is the durable store.
class PendingAssetRepository {
  PendingAssetRepository(this._database);

  final AppDatabase _database;

  static const maxAttempts = 6;

  Future<void> insert(PendingAssetRow row) async {
    final db = await _database.database;
    await db.insert('pending_asset', {
      'id': row.id,
      'local_path': row.localPath,
      'node_uuid': row.nodeUuid,
      'parent_uuid': row.parentUuid,
      'mime': row.mime,
      'original_name': row.originalName,
      'size_bytes': row.sizeBytes,
      'sealed': 0,
      'state': row.state,
      'created_at': row.createdAt,
    });
  }

  /// Rows due for a drain round, oldest first: pending state whose backoff
  /// window (`next_attempt_at`) has elapsed or was never set.
  Future<List<PendingAssetRow>> listDue({int? nowMillis}) async {
    final db = await _database.database;
    final now = nowMillis ?? DateTime.now().millisecondsSinceEpoch;
    final rows = await db.query(
      'pending_asset',
      where: "state = 'pending' AND (next_attempt_at IS NULL OR "
          'next_attempt_at <= ?)',
      whereArgs: [now],
      orderBy: 'created_at ASC',
    );
    return rows.map(PendingAssetRow.fromMap).toList();
  }

  Future<List<PendingAssetRow>> listFailed() async {
    final db = await _database.database;
    final rows = await db.query(
      'pending_asset',
      where: "state = 'failed'",
      orderBy: 'created_at ASC',
    );
    return rows.map(PendingAssetRow.fromMap).toList();
  }

  /// The Settings → Sync counts: uploads waiting vs dead-lettered.
  Future<({int pending, int failed})> counts({int? nowMillis}) async {
    final db = await _database.database;
    final now = nowMillis ?? DateTime.now().millisecondsSinceEpoch;
    final rows = await db.rawQuery(
      "SELECT state, COUNT(*) AS c FROM pending_asset WHERE state = 'failed' "
      'OR (state = \'pending\' AND (next_attempt_at IS NULL OR '
      'next_attempt_at <= ?)) GROUP BY state',
      [now],
    );
    var pending = 0;
    var failed = 0;
    for (final row in rows) {
      final count = row['c'] as int? ?? 0;
      if (row['state'] == 'failed') {
        failed = count;
      } else {
        pending = count;
      }
    }
    return (pending: pending, failed: failed);
  }

  /// The upload+attach succeeded: the row and (caller-side) the file go.
  Future<void> markDone(String id) async {
    final db = await _database.database;
    await db.delete('pending_asset', where: 'id = ?', whereArgs: [id]);
  }

  /// Records a failed attempt. [retryNow] defers only to the next drain
  /// round (attach 4xx — the target node may not exist server-side yet);
  /// otherwise [nextAttemptAtMillis] carries the exponential backoff.
  /// Past [maxAttempts] the row dead-letters into `failed`.
  Future<void> recordFailure(
    String id, {
    required String error,
    required int retryNowOrAtMillis,
    required bool retryNow,
    required int attempts,
    required int attemptedAtMillis,
  }) async {
    final db = await _database.database;
    final state = attempts >= maxAttempts ? 'failed' : 'pending';
    await db.update(
      'pending_asset',
      {
        'retry_count': attempts,
        'last_error': error,
        'state': state,
        'last_attempt_at': attemptedAtMillis,
        'next_attempt_at': retryNow ? attemptedAtMillis : retryNowOrAtMillis,
      },
      where: 'id = ?',
      whereArgs: [id],
    );
  }

  /// User retry from the dead-letter view: back to the queue, fresh budget.
  Future<void> requeue(String id) async {
    final db = await _database.database;
    await db.update(
      'pending_asset',
      {
        'state': 'pending',
        'retry_count': 0,
        'next_attempt_at': null,
      },
      where: 'id = ?',
      whereArgs: [id],
    );
  }

  /// User discard from the dead-letter view (the caller deletes the file).
  Future<void> discard(String id) async {
    final db = await _database.database;
    await db.delete('pending_asset', where: 'id = ?', whereArgs: [id]);
  }

  Future<PendingAssetRow?> get(String id) async {
    final db = await _database.database;
    final rows = await db.query(
      'pending_asset',
      where: 'id = ?',
      whereArgs: [id],
      limit: 1,
    );
    if (rows.isEmpty) return null;
    return PendingAssetRow.fromMap(rows.first);
  }
}
