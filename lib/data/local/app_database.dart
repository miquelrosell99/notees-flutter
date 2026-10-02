import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:path/path.dart';
import 'package:path_provider/path_provider.dart';
import 'package:sqflite_sqlcipher/sqflite.dart';

import '../../core/constants/system.dart';

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

  /// Returns an in-memory database instance for tests.
  factory AppDatabase.inMemory() =>
      _inMemoryInstance ??= AppDatabase._internal(':memory:');
  static AppDatabase? _inMemoryInstance;

  /// Wraps an already-opened database for tests.
  factory AppDatabase.fromDatabase(Database db) {
    final instance = AppDatabase._internal(':memory:');
    instance._db = db;
    return instance;
  }

  /// Resets the singleton, mainly for tests.
  static void reset() {
    _instance?._db = null;
    _instance = null;
    _inMemoryInstance?._db = null;
    _inMemoryInstance = null;
    encryptionPassword = null;
  }

  final String _dbName;
  Database? _db;

  /// Whether the local SQLite database has a platform implementation.
  /// sqflite_sqlcipher only supports Android and iOS.
  static bool get isSupported =>
      defaultTargetPlatform == TargetPlatform.android ||
      defaultTargetPlatform == TargetPlatform.iOS;

  /// The SQLCipher password used when opening the database.
  /// Set to `null` to use an unencrypted database.
  static String? encryptionPassword;

  /// Test hook: overrides the database factory (integration/widget tests run
  /// the cache on ffi SQLite; the SQLCipher plugin channel has no test
  /// implementation and cannot be redirected via the package-global
  /// `databaseFactory`).
  static DatabaseFactory? debugDatabaseFactory;

  Future<Database> get database async => _db ??= await _open();

  Future<String> get _path async {
    if (_dbName == ':memory:') return ':memory:';
    final dir = await getApplicationDocumentsDirectory();
    return join(dir.path, _dbName);
  }

  Future<Database> _open() async {
    final path = await _path;
    final factory = debugDatabaseFactory;
    if (factory != null) {
      return factory.openDatabase(
        path,
        options: OpenDatabaseOptions(
          version: 20,
          onCreate: _onCreate,
          onUpgrade: _onUpgrade,
        ),
      );
    }
    return openDatabase(
      path,
      version: 20,
      password: encryptionPassword,
      onCreate: _onCreate,
      onUpgrade: _onUpgrade,
    );
  }

  Future<void> _onCreate(Database db, int version) async {
    await _createOfflineQueue(db);
    await _createSyncState(db);
    await _createNodeCache(db);
    await _createSearchIndex(db);
    await _createRelayOutbox(db);
    await _createRelayOperations(db);
    await _createSyncWatermark(db);
    await _createSyncPushWatermark(db);
    await _createFavorites(db);
    await _createTaskCompletion(db);
    await _createTaskRecurrence(db);
    await _createNodeContentHlc(db);
    await _createClassCache(db);
    await _createPropertySchema(db);
    await _createClassPropertyEdge(db);
    await _createNodeUserShare(db);
    await _migrateV16(db);
    await _createEdge(db);
    await _createClassProperty(db);
    await _migrateV19(db);
    await _migrateV20(db);
  }

  Future<void> _onUpgrade(Database db, int oldVersion, int newVersion) async {
    if (oldVersion < 2) {
      await _createSyncOutbox(db);
      await _createSyncState(db);
    }
    if (oldVersion < 3) {
      await _createNodeCache(db);
    }
    if (oldVersion < 4) {
      await _createSearchIndex(db);
    }
    if (oldVersion < 5) {
      await _createRelayOutbox(db);
      await _createRelayOperations(db);
      await _createSyncWatermark(db);
      await _createSyncPushWatermark(db);
    }
    if (oldVersion < 6) {
      await _migrateNodeCacheV6(db);
    }
    if (oldVersion < 7) {
      await _createFavorites(db);
    }
    if (oldVersion < 8) {
      await _migrateNodeCacheV8(db);
    }
    if (oldVersion < 9) {
      await _createTaskCompletion(db);
    }
    if (oldVersion < 10) {
      await _createClassCache(db);
    }
    if (oldVersion < 11) {
      await _createPropertySchema(db);
      await _createClassPropertyEdge(db);
    }
    if (oldVersion < 12) {
      await _migrateNodeCacheV12(db);
    }
    if (oldVersion < 13) {
      await _migrateSyncWatermarkV13(db);
    }
    if (oldVersion < 14) {
      await _migrateFavoritesV14(db);
      await _createTaskRecurrence(db);
      await _createNodeContentHlc(db);
    }
    if (oldVersion < 15) {
      await _createNodeUserShare(db);
    }
    if (oldVersion < 16) {
      await _migrateV16(db);
    }
    if (oldVersion < 17) {
      await _createEdge(db);
    }
    if (oldVersion < 18) {
      await _createClassProperty(db);
    }
    if (oldVersion < 19) {
      await _migrateV19(db);
    }
    if (oldVersion < 20) {
      await _migrateV20(db);
    }
  }

  /// v16 — derived-state depth for the relay-v2 appliers:
  ///  - `node_cache` gains the v2 row shape: scalar `title` (the v2 `name`
  ///    slot, split from the content `name` column; since retired — the
  ///    protocol has no node `name` field anymore (title-is-content,
  ///    2026-10-01) — the column stays for legacy rows only), lexicographic
  ///    fractional `position`, `node_type` (retired by v20: the render-state
  ///    migration rebuilds the table with `is_class`/`present_as_main` and
  ///    drops it), and the row-LWW winner
  ///    (`hlc_physical`, `hlc_logical`, `actor_id`);
  ///  - new derived tables mirroring the v2 store: OR-Set class membership,
  ///    m2m class extends + transitive closure, multi-value property rows
  ///    with LWW tombstones, and collection membership.
  Future<void> _migrateV16(Database db) async {
    await _addColumnIfMissing(db, 'node_cache', 'title', 'TEXT');
    await _addColumnIfMissing(db, 'node_cache', 'position', 'TEXT');
    await _addColumnIfMissing(db, 'node_cache', 'node_type', 'TEXT');
    await _addColumnIfMissing(
      db,
      'node_cache',
      'hlc_physical',
      'INTEGER NOT NULL DEFAULT 0',
    );
    await _addColumnIfMissing(
      db,
      'node_cache',
      'hlc_logical',
      'INTEGER NOT NULL DEFAULT 0',
    );
    await _addColumnIfMissing(db, 'node_cache', 'actor_id', 'TEXT');
    await _createClassMemberSet(db);
    await _createClassExtends(db);
    await _createPropertyValue(db);
    await _createCollectionMember(db);
  }

  /// v19 — first-class tags + class ORDER (2026-10-01 protocol lockstep,
  /// store schema v6→v7 parity):
  ///  - `tag_member_set`: the tag-assignment OR-Set (same membership
  ///    semantics as `class_member_set`, own table, no role overlap);
  ///  - `node_cache.class_order`: the per-node user-defined class order list
  ///    (class.reorder, LWW-by-arrival); the effective classes_uuid =
  ///    ordered members first, then unlisted members sorted by id.
  Future<void> _migrateV19(Database db) async {
    await _createTagMemberSet(db);
    await _addColumnIfMissing(
      db,
      'node_cache',
      'class_order',
      "TEXT NOT NULL DEFAULT '[]'",
    );
  }

  /// v20 — Revision-11 render-state model (2026-10-02 protocol lockstep,
  /// store schema v7→v8 parity): the retired `node_type` enumeration
  /// (`page`/`block`/`class`) is replaced by two booleans — `is_class` (the
  /// only identity marker; classes are always roots) and `present_as_main`
  /// (the render bit read by the third cascade branch). Table rebuild (safe
  /// on stock SQLite builds — no DROP COLUMN): the rows map
  /// page → (0, 1), block → (0, 0), class → (1, 0), and the single
  /// placement CHECK (`is_class = 0 OR parent_uuid IS NULL`) replaces the
  /// retired block-needs-a-parent / class-is-tree-external rules.
  /// Parentless non-class nodes are legal from here on: they render with
  /// document chrome by the second cascade branch regardless of the bit.
  Future<void> _migrateV20(Database db) async {
    final columns = await db.rawQuery('PRAGMA table_info(node_cache)');
    if (columns.any((c) => c['name'] == 'node_type')) {
      await db.execute('''
        CREATE TABLE node_cache_v20 (
          uuid TEXT PRIMARY KEY,
          name TEXT,
          parent_uuid TEXT,
          classes_uuid TEXT,
          is_class INTEGER NOT NULL DEFAULT 0,
          present_as_main INTEGER NOT NULL DEFAULT 0,
          is_page INTEGER NOT NULL DEFAULT 0,
          is_task INTEGER NOT NULL DEFAULT 0,
          is_daily INTEGER NOT NULL DEFAULT 0,
          is_monthly INTEGER NOT NULL DEFAULT 0,
          is_yearly INTEGER NOT NULL DEFAULT 0,
          is_deleted INTEGER NOT NULL DEFAULT 0,
          is_archived INTEGER NOT NULL DEFAULT 0,
          sequence REAL NOT NULL DEFAULT 0,
          version INTEGER NOT NULL DEFAULT 0,
          write_date TEXT,
          payload TEXT NOT NULL,
          synced_at INTEGER NOT NULL,
          title TEXT,
          position TEXT,
          class_order TEXT NOT NULL DEFAULT '[]',
          hlc_physical INTEGER NOT NULL DEFAULT 0,
          hlc_logical INTEGER NOT NULL DEFAULT 0,
          actor_id TEXT,
          CHECK (is_class = 0 OR parent_uuid IS NULL)
        )
      ''');
      await db.execute('''
        INSERT INTO node_cache_v20 (
          uuid, name, parent_uuid, classes_uuid, is_class, present_as_main,
          is_page, is_task, is_daily, is_monthly, is_yearly, is_deleted,
          is_archived, sequence, version, write_date, payload, synced_at,
          title, position, class_order,
          hlc_physical, hlc_logical, actor_id
        )
        SELECT
          uuid, name, parent_uuid, classes_uuid,
          CASE WHEN node_type = 'class' THEN 1 ELSE 0 END,
          CASE WHEN node_type = 'page' THEN 1 ELSE 0 END,
          is_page, is_task, is_daily, is_monthly, is_yearly, is_deleted,
          is_archived, sequence, version, write_date, payload, synced_at,
          title, position, class_order,
          hlc_physical, hlc_logical, actor_id
        FROM node_cache
      ''');
      await db.execute('DROP TABLE node_cache');
      await db.execute('ALTER TABLE node_cache_v20 RENAME TO node_cache');
      await db.execute(
        'CREATE INDEX IF NOT EXISTS idx_node_cache_parent ON node_cache(parent_uuid)',
      );
      await db.execute(
        'CREATE INDEX IF NOT EXISTS idx_node_cache_deleted ON node_cache(is_deleted)',
      );
      await db.execute(
        'CREATE INDEX IF NOT EXISTS idx_node_cache_page ON node_cache(is_page)',
      );
      await db.execute(
        'CREATE INDEX IF NOT EXISTS idx_node_cache_task ON node_cache(is_task)',
      );
      await db.execute(
        'CREATE INDEX IF NOT EXISTS idx_node_cache_daily ON node_cache(is_daily)',
      );
      return;
    }
    // No node_type column: the table is already at the v20 shape (fresh
    // create); keep the guarded adds for defense in depth.
    await _addColumnIfMissing(
      db,
      'node_cache',
      'is_class',
      'INTEGER NOT NULL DEFAULT 0',
    );
    await _addColumnIfMissing(
      db,
      'node_cache',
      'present_as_main',
      'INTEGER NOT NULL DEFAULT 0',
    );
  }

  Future<void> _createTagMemberSet(Database db) async {
    // OR-Set of tag assignments (add-wins, LWW per (node, tag) pair by
    // (hlc, actor)); the applier projects the present rows into
    // node_cache's tags_uuid payload. Mirrors v2 store schema.ts
    // tag_member_set.
    await db.execute('''
      CREATE TABLE IF NOT EXISTS tag_member_set (
        node_uuid TEXT NOT NULL,
        tag_id TEXT NOT NULL,
        present INTEGER NOT NULL,
        hlc_physical INTEGER NOT NULL DEFAULT 0,
        hlc_logical INTEGER NOT NULL DEFAULT 0,
        actor_id TEXT,
        PRIMARY KEY (node_uuid, tag_id)
      )
    ''');
    await db.execute(
      'CREATE INDEX IF NOT EXISTS idx_tag_member_set_tag ON tag_member_set(tag_id)',
    );
  }

  Future<void> _createClassMemberSet(Database db) async {
    // OR-Set of class assignments (add-wins, LWW per (node, class) pair by
    // (hlc, actor)); the applier projects the present rows into
    // node_cache.classes_uuid. Mirrors v2 store schema.ts class_member_set.
    await db.execute('''
      CREATE TABLE IF NOT EXISTS class_member_set (
        node_uuid TEXT NOT NULL,
        class_id TEXT NOT NULL,
        present INTEGER NOT NULL,
        hlc_physical INTEGER NOT NULL DEFAULT 0,
        hlc_logical INTEGER NOT NULL DEFAULT 0,
        actor_id TEXT,
        PRIMARY KEY (node_uuid, class_id)
      )
    ''');
    await db.execute(
      'CREATE INDEX IF NOT EXISTS idx_class_member_set_class ON class_member_set(class_id)',
    );
  }

  Future<void> _createClassExtends(Database db) async {
    // Direct m2m extends edges (class.setExtends replace semantics) plus the
    // applier-maintained transitive closure (self-row included). Mirrors v2
    // store class_extends / class_hierarchy.
    await db.execute('''
      CREATE TABLE IF NOT EXISTS class_extends (
        class_id TEXT NOT NULL,
        parent_class_id TEXT NOT NULL,
        PRIMARY KEY (class_id, parent_class_id)
      )
    ''');
    await db.execute(
      'CREATE INDEX IF NOT EXISTS idx_class_extends_parent ON class_extends(parent_class_id)',
    );
    await db.execute('''
      CREATE TABLE IF NOT EXISTS class_hierarchy (
        class_id TEXT NOT NULL,
        ancestor_id TEXT NOT NULL,
        PRIMARY KEY (class_id, ancestor_id)
      )
    ''');
    await db.execute(
      'CREATE INDEX IF NOT EXISTS idx_class_hierarchy_ancestor ON class_hierarchy(ancestor_id)',
    );
  }

  Future<void> _createPropertyValue(Database db) async {
    // Multi-value property rows keyed by (node, schema, idx) with row-level
    // LWW winner and a tombstone table (tombstone wins over a live write with
    // equal (hlc, actor)). Mirrors v2 store property_value /
    // property_value_tombstone.
    await db.execute('''
      CREATE TABLE IF NOT EXISTS property_value (
        id TEXT PRIMARY KEY,
        node_uuid TEXT NOT NULL,
        property_schema_id TEXT NOT NULL,
        value TEXT NOT NULL,
        idx INTEGER NOT NULL DEFAULT 0,
        metadata TEXT,
        hlc_physical INTEGER NOT NULL DEFAULT 0,
        hlc_logical INTEGER NOT NULL DEFAULT 0,
        actor_id TEXT,
        UNIQUE (node_uuid, property_schema_id, idx)
      )
    ''');
    await db.execute(
      'CREATE INDEX IF NOT EXISTS idx_property_value_node ON property_value(node_uuid)',
    );
    await db.execute('''
      CREATE TABLE IF NOT EXISTS property_value_tombstone (
        node_uuid TEXT NOT NULL,
        property_schema_id TEXT NOT NULL,
        idx INTEGER NOT NULL DEFAULT 0,
        hlc_physical INTEGER NOT NULL DEFAULT 0,
        hlc_logical INTEGER NOT NULL DEFAULT 0,
        actor_id TEXT,
        PRIMARY KEY (node_uuid, property_schema_id, idx)
      )
    ''');
  }

  /// Class → property-schema bindings (SCHEMA.md "Class properties"):
  /// configuration rows (sequence, required, readonly, hideWhenEmpty,
  /// defaultValue) authored by class.property.set/unset. The legacy
  /// `class_property_edge` table (v1 UI read model) stays untouched.
  Future<void> _createClassProperty(Database db) async {
    await db.execute('''
      CREATE TABLE IF NOT EXISTS class_property (
        class_id TEXT NOT NULL,
        property_schema_id TEXT NOT NULL,
        sequence INTEGER NOT NULL DEFAULT 0,
        required INTEGER,
        readonly INTEGER,
        hide_when_empty INTEGER,
        default_value TEXT,
        hlc_physical INTEGER NOT NULL DEFAULT 0,
        hlc_logical INTEGER NOT NULL DEFAULT 0,
        actor_id TEXT,
        PRIMARY KEY (class_id, property_schema_id)
      )
    ''');
    await db.execute(
      'CREATE INDEX IF NOT EXISTS idx_class_property_schema ON class_property(property_schema_id)',
    );
  }

  /// Derived reference index (never authored): mention/typed_link edges
  /// projected from content tokens plus node-typed property values. Mirrors
  /// the v2 store `edge` table.
  Future<void> _createEdge(Database db) async {
    await db.execute('''
      CREATE TABLE IF NOT EXISTS edge (
        id TEXT PRIMARY KEY,
        workspace_id TEXT NOT NULL DEFAULT '',
        source_id TEXT NOT NULL,
        target_id TEXT,
        type TEXT NOT NULL,
        verb TEXT,
        metadata TEXT,
        created_at TEXT
      )
    ''');
    await db.execute('CREATE INDEX IF NOT EXISTS idx_edge_source ON edge(source_id, type)');
    await db.execute('CREATE INDEX IF NOT EXISTS idx_edge_target ON edge(target_id, type)');
  }

  Future<void> _createCollectionMember(Database db) async {
    // OR-Set membership for collection nodes (add-wins per member pair).
    // Mirrors v2 store collection_member.
    await db.execute('''
      CREATE TABLE IF NOT EXISTS collection_member (
        collection_id TEXT NOT NULL,
        object_id TEXT NOT NULL,
        present INTEGER NOT NULL,
        hlc_physical INTEGER NOT NULL DEFAULT 0,
        hlc_logical INTEGER NOT NULL DEFAULT 0,
        actor_id TEXT,
        PRIMARY KEY (collection_id, object_id)
      )
    ''');
    await db.execute(
      'CREATE INDEX IF NOT EXISTS idx_collection_member_object ON collection_member(object_id)',
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
      CREATE TABLE IF NOT EXISTS node_cache (
        uuid TEXT PRIMARY KEY,
        name TEXT,
        parent_uuid TEXT,
        classes_uuid TEXT,
        is_class INTEGER NOT NULL DEFAULT 0,
        present_as_main INTEGER NOT NULL DEFAULT 0,
        is_page INTEGER NOT NULL DEFAULT 0,
        is_task INTEGER NOT NULL DEFAULT 0,
        is_daily INTEGER NOT NULL DEFAULT 0,
        is_monthly INTEGER NOT NULL DEFAULT 0,
        is_yearly INTEGER NOT NULL DEFAULT 0,
        is_deleted INTEGER NOT NULL DEFAULT 0,
        is_archived INTEGER NOT NULL DEFAULT 0,
        sequence REAL NOT NULL DEFAULT 0,
        version INTEGER NOT NULL DEFAULT 0,
        write_date TEXT,
        payload TEXT NOT NULL,
        synced_at INTEGER NOT NULL,
        CHECK (is_class = 0 OR parent_uuid IS NULL)
      )
    ''');
    await db.execute(
      'CREATE INDEX IF NOT EXISTS idx_node_cache_parent ON node_cache(parent_uuid)',
    );
    await db.execute(
      'CREATE INDEX IF NOT EXISTS idx_node_cache_deleted ON node_cache(is_deleted)',
    );
    await db.execute('CREATE INDEX IF NOT EXISTS idx_node_cache_page ON node_cache(is_page)');
    await db.execute('CREATE INDEX IF NOT EXISTS idx_node_cache_task ON node_cache(is_task)');
    await db.execute(
      'CREATE INDEX IF NOT EXISTS idx_node_cache_daily ON node_cache(is_daily)',
    );
  }

  /// Adds [column] to [table] unless it already exists. Column migrations
  /// must be idempotent: upgrade paths from versions predating a table create
  /// it at its CURRENT shape (via the _create* functions), so an unguarded
  /// ALTER re-adding the same column fails with "duplicate column name".
  Future<void> _addColumnIfMissing(
    Database db,
    String table,
    String column,
    String definition,
  ) async {
    final columns = await db.rawQuery('PRAGMA table_info($table)');
    if (columns.any((c) => c['name'] == column)) return;
    await db.execute('ALTER TABLE $table ADD COLUMN $column $definition');
  }

  Future<void> _migrateNodeCacheV6(Database db) async {
    await _addColumnIfMissing(db, 'node_cache', 'classes_uuid', 'TEXT');
    await _addColumnIfMissing(
      db,
      'node_cache',
      'is_page',
      'INTEGER NOT NULL DEFAULT 0',
    );
    await _addColumnIfMissing(
      db,
      'node_cache',
      'is_task',
      'INTEGER NOT NULL DEFAULT 0',
    );
    await _addColumnIfMissing(
      db,
      'node_cache',
      'is_daily',
      'INTEGER NOT NULL DEFAULT 0',
    );
    await _addColumnIfMissing(
      db,
      'node_cache',
      'is_monthly',
      'INTEGER NOT NULL DEFAULT 0',
    );
    await _addColumnIfMissing(
      db,
      'node_cache',
      'is_yearly',
      'INTEGER NOT NULL DEFAULT 0',
    );
    await db.execute(
      'CREATE INDEX IF NOT EXISTS idx_node_cache_page ON node_cache(is_page)',
    );
    await db.execute(
      'CREATE INDEX IF NOT EXISTS idx_node_cache_task ON node_cache(is_task)',
    );
    await db.execute(
      'CREATE INDEX IF NOT EXISTS idx_node_cache_daily ON node_cache(is_daily)',
    );
  }

  Future<void> _migrateNodeCacheV8(Database db) async {
    await _addColumnIfMissing(
      db,
      'node_cache',
      'is_archived',
      'INTEGER NOT NULL DEFAULT 0',
    );
  }

  Future<void> _migrateNodeCacheV12(Database db) async {
    // The `page` system class is no longer emitted; page status is now derived
    // from `kind == 'page'` / the `is_page` column. Strip the obsolete page
    // class UUID from any cached class lists.
    const pageClassUuid = SystemClassUuids.page;
    final rows = await db.query(
      'node_cache',
      columns: ['uuid', 'classes_uuid'],
      where: "classes_uuid LIKE ?",
      whereArgs: ['%$pageClassUuid%'],
    );
    for (final row in rows) {
      final uuid = row['uuid'] as String?;
      final classesJson = row['classes_uuid'] as String?;
      if (uuid == null || classesJson == null) continue;
      final classIds = (jsonDecode(classesJson) as List<dynamic>)
          .cast<String>();
      if (!classIds.contains(pageClassUuid)) continue;
      classIds.remove(pageClassUuid);
      await db.update(
        'node_cache',
        {'classes_uuid': jsonEncode(classIds)},
        where: 'uuid = ?',
        whereArgs: [uuid],
      );
    }
  }

  Future<void> _createFavorites(Database db) async {
    // Favorites are keyed per actor, matching the server-side
    // `user_favorite(actor_id, node_id, workspace_id)` keying. Rows written
    // before the actor column existed carry the empty-string actor.
    await db.execute('''
      CREATE TABLE user_favorite (
        workspace_id TEXT NOT NULL,
        actor_id TEXT NOT NULL DEFAULT '',
        node_uuid TEXT NOT NULL,
        position INTEGER NOT NULL DEFAULT 0,
        updated_at INTEGER NOT NULL,
        PRIMARY KEY (workspace_id, actor_id, node_uuid)
      )
    ''');
    await db.execute(
      'CREATE INDEX idx_user_favorite_workspace ON user_favorite(workspace_id)',
    );
    await db.execute(
      'CREATE INDEX idx_user_favorite_position ON user_favorite(workspace_id, actor_id, position)',
    );
  }

  Future<void> _migrateFavoritesV14(Database db) async {
    // Rebuilds user_favorite with actor_id in the primary key; existing rows
    // keep the empty-string actor (pre-actor-aware local writes).
    await db.execute('''
      CREATE TABLE user_favorite_new (
        workspace_id TEXT NOT NULL,
        actor_id TEXT NOT NULL DEFAULT '',
        node_uuid TEXT NOT NULL,
        position INTEGER NOT NULL DEFAULT 0,
        updated_at INTEGER NOT NULL,
        PRIMARY KEY (workspace_id, actor_id, node_uuid)
      )
    ''');
    await db.execute('''
      INSERT INTO user_favorite_new (workspace_id, actor_id, node_uuid, position, updated_at)
      SELECT workspace_id, '', node_uuid, position, updated_at FROM user_favorite
    ''');
    await db.execute('DROP TABLE user_favorite');
    await db.execute('ALTER TABLE user_favorite_new RENAME TO user_favorite');
    await db.execute(
      'CREATE INDEX idx_user_favorite_workspace ON user_favorite(workspace_id)',
    );
    await db.execute(
      'CREATE INDEX idx_user_favorite_position ON user_favorite(workspace_id, actor_id, position)',
    );
  }

  Future<void> _createSearchIndex(Database db) async {
    await db.execute('''
      CREATE TABLE search_index (
        term TEXT NOT NULL,
        node_uuid TEXT NOT NULL,
        field TEXT NOT NULL,
        rank INTEGER NOT NULL DEFAULT 1,
        PRIMARY KEY (term, node_uuid, field)
      )
    ''');
    await db.execute(
      'CREATE INDEX idx_search_index_term ON search_index(term)',
    );
    await db.execute(
      'CREATE INDEX idx_search_index_node ON search_index(node_uuid)',
    );
  }

  Future<void> _createRelayOutbox(Database db) async {
    await db.execute('''
      CREATE TABLE relay_outbox (
        id INTEGER PRIMARY KEY AUTOINCREMENT,
        envelope_json TEXT NOT NULL,
        state TEXT NOT NULL DEFAULT 'pending',
        attempt_count INTEGER NOT NULL DEFAULT 0,
        last_error TEXT,
        next_retry_at INTEGER,
        created_at INTEGER NOT NULL
      )
    ''');
    await db.execute(
      'CREATE INDEX idx_relay_outbox_state_retry ON relay_outbox(state, next_retry_at)',
    );
    await db.execute(
      'CREATE INDEX idx_relay_outbox_created ON relay_outbox(created_at)',
    );
  }

  Future<void> _createRelayOperations(Database db) async {
    await db.execute('''
      CREATE TABLE relay_operations (
        id TEXT PRIMARY KEY,
        workspace_id TEXT NOT NULL,
        actor_id TEXT NOT NULL,
        hlc_physical INTEGER NOT NULL,
        hlc_logical INTEGER NOT NULL,
        affected_node_ids TEXT NOT NULL,
        op_type TEXT NOT NULL,
        payload TEXT NOT NULL,
        timestamp TEXT NOT NULL,
        is_local INTEGER NOT NULL DEFAULT 0
      )
    ''');
    await db.execute(
      'CREATE INDEX idx_relay_operations_workspace_hlc ON relay_operations(workspace_id, hlc_physical, hlc_logical)',
    );
  }

  Future<void> _createSyncWatermark(Database db) async {
    await db.execute('''
      CREATE TABLE sync_watermark (
        workspace_id TEXT PRIMARY KEY,
        hlc_physical INTEGER NOT NULL,
        hlc_logical INTEGER NOT NULL,
        restore_epoch INTEGER NOT NULL DEFAULT 0,
        cursor_seq INTEGER NOT NULL DEFAULT 0
      )
    ''');
  }

  Future<void> _migrateSyncWatermarkV13(Database db) async {
    // Adds the server-assigned seq catch-up cursor. Existing rows read as
    // cursor 0 = full catch-up; re-applied envelopes are deduped by op id.
    // Guarded: upgrades from versions predating the table create it at its
    // CURRENT shape (cursor_seq included) in the <5 branch above, so an
    // unguarded ALTER fails with "duplicate column name".
    await _addColumnIfMissing(
      db,
      'sync_watermark',
      'cursor_seq',
      'INTEGER NOT NULL DEFAULT 0',
    );
  }

  Future<void> _createSyncPushWatermark(Database db) async {
    await db.execute('''
      CREATE TABLE sync_push_watermark (
        workspace_id TEXT PRIMARY KEY,
        hlc_physical INTEGER NOT NULL,
        hlc_logical INTEGER NOT NULL
      )
    ''');
  }

  Future<void> _createTaskCompletion(Database db) async {
    await db.execute('''
      CREATE TABLE task_completion (
        completion_id TEXT PRIMARY KEY,
        node_uuid TEXT NOT NULL,
        completed_at TEXT,
        scheduled_date TEXT,
        deadline_date TEXT,
        status TEXT,
        created_at INTEGER NOT NULL
      )
    ''');
    await db.execute(
      'CREATE INDEX idx_task_completion_node ON task_completion(node_uuid)',
    );
    await db.execute(
      'CREATE INDEX idx_task_completion_created ON task_completion(node_uuid, created_at DESC)',
    );
  }

  Future<void> _createTaskRecurrence(Database db) async {
    // Mirrors the server-derived `task_recurrence` table.
    await db.execute('''
      CREATE TABLE task_recurrence (
        recurrence_id TEXT PRIMARY KEY,
        node_uuid TEXT NOT NULL,
        rule TEXT NOT NULL,
        actor_id TEXT,
        created_at TEXT,
        updated_at TEXT
      )
    ''');
    await db.execute(
      'CREATE INDEX idx_task_recurrence_node ON task_recurrence(node_uuid)',
    );
  }

  Future<void> _createNodeUserShare(Database db) async {
    // Mirrors the server-derived `node_user_share` table, plus a workspace
    // column since the local cache spans workspaces.
    await db.execute('''
      CREATE TABLE node_user_share (
        workspace_id TEXT NOT NULL,
        node_uuid TEXT NOT NULL,
        target_user_id TEXT NOT NULL,
        role TEXT NOT NULL DEFAULT '',
        permission_bits INTEGER NOT NULL DEFAULT 0,
        share_id TEXT,
        created_by TEXT,
        created_at TEXT,
        PRIMARY KEY (workspace_id, node_uuid, target_user_id)
      )
    ''');
    await db.execute(
      'CREATE INDEX idx_node_user_share_target ON node_user_share(workspace_id, target_user_id)',
    );
    await db.execute(
      'CREATE INDEX idx_node_user_share_share ON node_user_share(share_id)',
    );
  }

  Future<void> _createNodeContentHlc(Database db) async {
    // Last applied content HLC per node, used to skip stale
    // `node.updateContent` operations (last-write-wins, like the server).
    await db.execute('''
      CREATE TABLE node_content_hlc (
        node_uuid TEXT PRIMARY KEY,
        hlc_physical INTEGER NOT NULL,
        hlc_logical INTEGER NOT NULL
      )
    ''');
  }

  Future<void> _createClassCache(Database db) async {
    await db.execute('''
      CREATE TABLE class_cache (
        uuid TEXT PRIMARY KEY,
        name TEXT NOT NULL,
        icon TEXT,
        color TEXT,
        description TEXT,
        extends_uuid TEXT NOT NULL DEFAULT '[]',
        active INTEGER NOT NULL DEFAULT 1,
        created_at TEXT,
        updated_at TEXT
      )
    ''');
    await db.execute(
      'CREATE INDEX idx_class_cache_active ON class_cache(active)',
    );
  }

  Future<void> _createPropertySchema(Database db) async {
    await db.execute('''
      CREATE TABLE property_schema (
        uuid TEXT PRIMARY KEY,
        workspace_id TEXT NOT NULL,
        name TEXT NOT NULL,
        icon TEXT,
        type TEXT NOT NULL DEFAULT 'text',
        multi INTEGER NOT NULL DEFAULT 0,
        is_system INTEGER NOT NULL DEFAULT 0,
        scope TEXT NOT NULL DEFAULT 'global',
        node_uuid TEXT,
        icon_visibility TEXT,
        validation_rules TEXT,
        required INTEGER NOT NULL DEFAULT 0,
        readonly INTEGER NOT NULL DEFAULT 0,
        hide_when_empty INTEGER NOT NULL DEFAULT 0,
        default_value TEXT,
        class_filter_uuids TEXT NOT NULL DEFAULT '[]',
        options TEXT NOT NULL DEFAULT '[]',
        computed TEXT,
        active INTEGER NOT NULL DEFAULT 1,
        created_at TEXT,
        updated_at TEXT
      )
    ''');
    await db.execute(
      'CREATE INDEX idx_property_schema_workspace ON property_schema(workspace_id)',
    );
    await db.execute(
      'CREATE INDEX idx_property_schema_node ON property_schema(node_uuid)',
    );
    await db.execute(
      'CREATE INDEX idx_property_schema_active ON property_schema(active)',
    );
  }

  Future<void> _createClassPropertyEdge(Database db) async {
    await db.execute('''
      CREATE TABLE class_property_edge (
        class_uuid TEXT NOT NULL,
        property_uuid TEXT NOT NULL,
        sequence INTEGER NOT NULL DEFAULT 0,
        default_value TEXT,
        hidden INTEGER NOT NULL DEFAULT 0,
        required INTEGER,
        readonly INTEGER,
        hide_when_empty INTEGER,
        PRIMARY KEY (class_uuid, property_uuid)
      )
    ''');
    await db.execute(
      'CREATE INDEX idx_class_property_edge_class ON class_property_edge(class_uuid)',
    );
    await db.execute(
      'CREATE INDEX idx_class_property_edge_property ON class_property_edge(property_uuid)',
    );
  }

  /// Creates the full schema on an already-opened test database.
  Future<void> initializeSchema() async {
    final db = await database;
    await _createOfflineQueue(db);
    await _createSyncState(db);
    await _createNodeCache(db);
    await _createSearchIndex(db);
    await _createRelayOutbox(db);
    await _createRelayOperations(db);
    await _createSyncWatermark(db);
    await _createSyncPushWatermark(db);
    await _createFavorites(db);
    await _createTaskCompletion(db);
    await _createTaskRecurrence(db);
    await _createNodeContentHlc(db);
    await _createClassCache(db);
    await _createPropertySchema(db);
    await _createClassPropertyEdge(db);
    await _createNodeUserShare(db);
    await _migrateV16(db);
    await _createEdge(db);
    await _createClassProperty(db);
    await _migrateV19(db);
    await _migrateV20(db);
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
    return db.query('offline_queue', orderBy: 'created_at ASC');
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
