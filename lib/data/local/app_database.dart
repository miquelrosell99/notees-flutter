import 'dart:convert';

import 'package:path/path.dart';
import 'package:path_provider/path_provider.dart';
import 'package:sqflite/sqflite.dart';

/// Simple SQLite database for the offline queue.
class AppDatabase {
  AppDatabase([this._dbName = 'notees_mobile.db']);

  final String _dbName;
  Database? _db;

  Future<Database> get database async => _db ??= await _open();

  Future<Database> _open() async {
    final dir = await getApplicationDocumentsDirectory();
    final path = join(dir.path, _dbName);
    return openDatabase(
      path,
      version: 1,
      onCreate: (db, version) async {
        await db.execute('''
          CREATE TABLE offline_queue (
            id INTEGER PRIMARY KEY AUTOINCREMENT,
            method TEXT NOT NULL,
            payload TEXT NOT NULL,
            created_at INTEGER NOT NULL
          )
        ''');
      },
    );
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
