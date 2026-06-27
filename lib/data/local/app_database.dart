import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart';
import 'package:path_provider/path_provider.dart';
import 'package:sqflite_sqlcipher/sqflite.dart';

/// Simple SQLite database for the offline queue and v2 sync outbox.
///
/// The database is a singleton so all callers share the same connection and
/// encryption password. Encryption is opt-in; when enabled the database file is
/// recreated with a SQLCipher password.
class AppDatabase {
  // Kept configurable for tests that need an isolated database file.
  // ignore: unused_element_parameter
  AppDatabase._internal([this._dbName = 'notees_mobile.db']);

  static AppDatabase? _instance;

  /// Returns the shared database instance.
  factory AppDatabase() => _instance ??= AppDatabase._internal();

  /// Resets the singleton, mainly for tests.
  static void reset() {
    _instance?._db = null;
    _instance = null;
    encryptionPassword = null;
  }

  final String _dbName;
  Database? _db;

  /// The SQLCipher password used when opening the database.
  /// Set to `null` to use an unencrypted database.
  static String? encryptionPassword;

  Future<Database> get database async => _db ??= await _open();

  Future<String> get _path async {
    final dir = await getApplicationDocumentsDirectory();
    return join(dir.path, _dbName);
  }

  Future<Database> _open() async {
    final path = await _path;
    return openDatabase(
      path,
      version: 3,
      password: encryptionPassword,
      onCreate: (db, version) async {
        await _createOfflineQueue(db);
        await _createSyncOutbox(db);
        await _createSyncState(db);
        await _createNodeCache(db);
      },
      onUpgrade: (db, oldVersion, newVersion) async {
        if (oldVersion < 2) {
          await _createSyncOutbox(db);
          await _createSyncState(db);
        }
        if (oldVersion < 3) {
          await _createNodeCache(db);
        }
      },
    );
  }

  /// Closes and deletes the database file, then reopens it with the current
  /// encryption password. Use this when toggling encryption on or off.
  Future<void> recreate() async {
    await close();
    final path = await _path;
    final file = File(path);
    if (await file.exists()) {
      await file.delete();
    }
    _db = null;
    await database;
  }

  Future<void> _createOfflineQueue(Database db) async {
    await db.execute('''
      CREATE TABLE offline_queue (
        id INTEGER PRIMARY KEY AUTOINCREMENT,
        method TEXT NOT NULL,
        payload TEXT NOT NULL,
        created_at INTEGER NOT NULL
      )
    ''');
  }

  Future<void> _createSyncOutbox(Database db) async {
    await db.execute('''
      CREATE TABLE sync_outbox (
        id INTEGER PRIMARY KEY AUTOINCREMENT,
        op_json TEXT NOT NULL,
        client_id TEXT NOT NULL,
        seq INTEGER NOT NULL,
        attempt_count INTEGER NOT NULL DEFAULT 0,
        last_error TEXT,
        next_retry_at INTEGER,
        created_at INTEGER NOT NULL
      )
    ''');
    await db.execute('CREATE INDEX idx_sync_outbox_seq ON sync_outbox(seq)');
  }

  Future<void> _createSyncState(Database db) async {
    await db.execute('''
      CREATE TABLE sync_state (
        key TEXT PRIMARY KEY,
        value TEXT NOT NULL
      )
    ''');
  }

  Future<void> _createNodeCache(Database db) async {
    await db.execute('''
      CREATE TABLE node_cache (
        uuid TEXT PRIMARY KEY,
        name TEXT,
        parent_uuid TEXT,
        sequence REAL NOT NULL DEFAULT 0,
        is_deleted INTEGER NOT NULL DEFAULT 0,
        version INTEGER NOT NULL DEFAULT 0,
        write_date TEXT,
        payload TEXT NOT NULL,
        synced_at INTEGER NOT NULL
      )
    ''');
    await db.execute('CREATE INDEX idx_node_cache_parent ON node_cache(parent_uuid)');
    await db.execute('CREATE INDEX idx_node_cache_deleted ON node_cache(is_deleted)');
  }

  Future<int> enqueue(String method, String payload) async {
    final db = await database;
    return db.insert('offline_queue', {
      'method': method,
      'payload': payload,
      'created_at': DateTime.now().millisecondsSinceEpoch,
    });
  }

  Future<int> enqueueQuickNote(String name) async {
    return enqueue('quick_note', '{"name": ${jsonEncode(name)}}');
  }

  Future<List<Map<String, dynamic>>> pending() async {
    final db = await database;
    return db.query(
      'offline_queue',
      orderBy: 'created_at ASC',
    );
  }

  Future<void> remove(int id) async {
    final db = await database;
    await db.delete('offline_queue', where: 'id = ?', whereArgs: [id]);
  }

  Future<void> close() async {
    await _db?.close();
    _db = null;
  }
}
