import 'package:flutter_test/flutter_test.dart';
import 'package:notees/core/constants/system.dart';
import 'package:notees/data/local/app_database.dart';
import 'package:notees/data/models/node.dart';
import 'package:notees/data/repositories/node_cache_repository.dart';
import 'package:notees/domain/models/relay/hlc.dart';
import 'package:notees/domain/models/relay/operation_envelope.dart';
import 'package:notees/domain/models/relay/operation_payloads.dart';
import 'package:notees/domain/models/search_filters.dart';
import 'package:notees/domain/services/relay_appliers.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  sqfliteFfiInit();

  group('NodeCacheRepository', () {
    late Database ffiDb;
    late AppDatabase database;
    late NodeCacheRepository repo;

    setUp(() async {
      AppDatabase.reset();
      ffiDb = await databaseFactoryFfi.openDatabase(
        ':memory:',
        options: OpenDatabaseOptions(singleInstance: false),
      );
      database = AppDatabase.fromDatabase(ffiDb);
      await database.initializeSchema();
      repo = NodeCacheRepository(database);
    });

    tearDown(() async {
      await ffiDb.close();
      AppDatabase.reset();
    });

    Node makePage({
      required String uuid,
      required String name,
      String? parentUuid,
      String? writeDate,
    }) {
      return Node(
        id: 0,
        uuid: uuid,
        name: name,
        displayName: name,
        parentUuid: parentUuid,
        isPage: true,
        // Revision 11: page-ness is the render bit, not a node kind.
        presentAsMain: true,
        writeDate: writeDate,
      );
    }

    Node makeTask({
      required String uuid,
      required String name,
      String? statusValue,
      String? deadline,
    }) {
      final properties = <String, dynamic>{};
      if (statusValue != null) {
        properties[SystemPropertyUuids.taskStatus] = statusValue;
      }
      if (deadline != null) {
        properties[SystemPropertyUuids.taskDeadline] = deadline;
      }
      return Node(
        id: 0,
        uuid: uuid,
        name: name,
        displayName: name,
        isTask: true,
        properties: properties,
      );
    }

    test('upsert stores page flags and getRecentPages returns them', () async {
      await repo.upsert(makePage(uuid: 'p-1', name: 'A', writeDate: '2026-01-02'));
      await repo.upsert(makePage(uuid: 'p-2', name: 'B', writeDate: '2026-01-03'));
      // An inline child block: parented, bit unset — not a page.
      await repo.upsert(Node(
        id: 0,
        uuid: 'b-1',
        name: 'Block',
        displayName: 'Block',
        parentUuid: 'p-1',
      ));

      final pages = await repo.getRecentPages(limit: 10);
      expect(pages.length, 2);
      expect(pages.first.uuid, 'p-2');
    });

    test('getRootPages returns only top-level pages', () async {
      await repo.upsert(makePage(uuid: 'root-1', name: 'Root'));
      await repo.upsert(makePage(uuid: 'child-1', name: 'Child', parentUuid: 'root-1'));

      final roots = await repo.getRootPages();
      expect(roots.length, 1);
      expect(roots.first.uuid, 'root-1');
    });

    test('upsert/getByUuid round-trips the wire node fields', () async {
      // The editor header reads the cover from node.coverAssetId — the
      // derived projection of object.update's coverAssetId field (the
      // cover_asset_id column rides the payload JSON).
      await repo.upsert(Node(
        id: 0,
        uuid: 'p-cover',
        name: 'Covered',
        displayName: 'Covered',
        isPage: true,
        presentAsMain: true,
        coverAssetId: 'asset-1',
        bannerAssetId: 'asset-2',
        aliasedNodeId: 'p-main',
      ));

      final node = await repo.getByUuid('p-cover');
      expect(node, isNotNull);
      expect(node!.coverAssetId, 'asset-1');
      expect(node.bannerAssetId, 'asset-2');
      expect(node.aliasedNodeId, 'p-main');
    });

    test('getTasks filters by task class and open state', () async {
      await repo.upsert(makeTask(uuid: 't-1', name: 'Open', statusValue: 'Pending'));
      await repo.upsert(makeTask(uuid: 't-2', name: 'Done', statusValue: 'Done'));
      await repo.upsert(makePage(uuid: 'p-1', name: 'Page'));

      final open = await repo.getTasks();
      expect(open.length, 1);
      expect(open.first.uuid, 't-1');

      final all = await repo.getTasks(includeComplete: true);
      expect(all.length, 2);
    });

    test('searchNodes finds nodes by display name', () async {
      await repo.upsert(makePage(uuid: 'p-1', name: 'Shopping list'));
      await repo.upsert(makePage(uuid: 'p-2', name: 'Work notes'));

      final results = await repo.searchNodes('shopping');
      expect(results.length, 1);
      expect(results.first.uuid, 'p-1');
    });

    test('searchWithFilters filters by node type', () async {
      await repo.upsert(makePage(uuid: 'p-1', name: 'Page'));
      await repo.upsert(makeTask(uuid: 't-1', name: 'Task'));

      final pages = await repo.searchWithFilters(
        const SearchFilters(nodeType: SearchKind.page),
      );
      expect(pages.length, 1);
      expect(pages.first.uuid, 'p-1');

      final tasks = await repo.searchWithFilters(
        const SearchFilters(nodeType: SearchKind.task),
      );
      expect(tasks.length, 1);
      expect(tasks.first.uuid, 't-1');
    });

    test('favorites are stored per workspace and ordered', () async {
      await repo.upsert(makePage(uuid: 'p-1', name: 'A'));
      await repo.upsert(makePage(uuid: 'p-2', name: 'B'));
      await repo.upsert(makePage(uuid: 'p-3', name: 'C'));

      await repo.addFavorite('ws-1', 'p-1');
      await repo.addFavorite('ws-1', 'p-2');
      await repo.addFavorite('ws-2', 'p-3');

      final ws1 = await repo.getFavorites('ws-1');
      expect(ws1.map((n) => n.uuid).toList(), ['p-1', 'p-2']);

      final uuids = await repo.getFavoriteUuids('ws-1');
      expect(uuids, ['p-1', 'p-2']);

      await repo.removeFavorite('ws-1', 'p-1');
      expect(await repo.getFavoriteUuids('ws-1'), ['p-2']);

      await repo.reorderFavorites('ws-1', ['p-2', 'p-3']);
      expect(await repo.getFavoriteUuids('ws-1'), ['p-2', 'p-3']);
    });

    test('favorites are isolated per actor', () async {
      await repo.upsert(makePage(uuid: 'p-1', name: 'A'));
      await repo.upsert(makePage(uuid: 'p-2', name: 'B'));

      await repo.addFavorite('ws-1', 'p-1', actorId: 'user-1');
      await repo.addFavorite('ws-1', 'p-2', actorId: 'user-2');

      expect(await repo.getFavoriteUuids('ws-1', actorId: 'user-1'), ['p-1']);
      expect(await repo.getFavoriteUuids('ws-1', actorId: 'user-2'), ['p-2']);
      // No actor filter returns all rows for the workspace.
      expect((await repo.getFavoriteUuids('ws-1')).length, 2);

      await repo.removeFavorite('ws-1', 'p-1', actorId: 'user-1');
      expect(await repo.getFavoriteUuids('ws-1', actorId: 'user-1'), isEmpty);
      expect(await repo.getFavoriteUuids('ws-1', actorId: 'user-2'), ['p-2']);
    });

    test('getAvailableProperties returns schemas attached to node classes', () async {
      final classUuid = '00000000-0000-0000-0000-000000000601';
      final schemaUuid = '00000000-0000-0000-0000-000000000602';
      final node = Node(
        id: 0,
        uuid: 'n-1',
        name: 'Item',
        displayName: 'Item',
        classesUuid: [classUuid],
      );
      await repo.upsertClass(uuid: classUuid, name: 'Book');
      await repo.upsertPropertySchema(
        PropertySchemaRow(
          uuid: schemaUuid,
          workspaceId: 'ws',
          name: 'Author',
          type: 'text',
        ),
      );
      await repo.upsertClassPropertyEdge(
        ClassPropertyEdgeRow(
          classUuid: classUuid,
          propertyUuid: schemaUuid,
          sequence: 0,
        ),
      );
      await repo.upsert(node);

      final available = await repo.getAvailableProperties('n-1');
      expect(available.length, 1);
      expect(available.first.uuid, schemaUuid);
      expect(available.first.name, 'Author');
    });

    test('getClassProperties returns class-level metadata', () async {
      final classUuid = '00000000-0000-0000-0000-000000000603';
      final schemaUuid = '00000000-0000-0000-0000-000000000604';
      await repo.upsertClass(uuid: classUuid, name: 'Contact');
      await repo.upsertPropertySchema(
        PropertySchemaRow(
          uuid: schemaUuid,
          workspaceId: 'ws',
          name: 'Email',
          type: 'text',
        ),
      );
      await repo.upsertClassPropertyEdge(
        ClassPropertyEdgeRow(
          classUuid: classUuid,
          propertyUuid: schemaUuid,
          sequence: 1,
          required: true,
        ),
      );

      final classProperties = await repo.getClassProperties(classUuid);
      expect(classProperties.length, 1);
      expect(classProperties.first.propertyName, 'Email');
      expect(classProperties.first.sequence, 1);
      expect(classProperties.first.required, isTrue);
    });
  });

  group('readNodesFromSnapshotDatabase', () {
    late Database snapshotDb;

    setUp(() async {
      snapshotDb = await databaseFactoryFfi.openDatabase(
        ':memory:',
        options: OpenDatabaseOptions(singleInstance: false),
      );
      // derived-state schema (packages/store/src/schema.ts, Revision 11).
      await snapshotDb.execute('''
        CREATE TABLE node (
          id TEXT PRIMARY KEY,
          workspace_id TEXT NOT NULL,
          is_class INTEGER NOT NULL DEFAULT 0,
          present_as_main INTEGER NOT NULL DEFAULT 0,
          parent_id TEXT,
          class_ids TEXT NOT NULL DEFAULT '[]',
          name TEXT,
          content TEXT NOT NULL DEFAULT '[]',
          icon TEXT,
          color TEXT,
          is_active INTEGER NOT NULL DEFAULT 1,
          created_at TEXT,
          updated_at TEXT,
          created_by TEXT,
          updated_by TEXT,
          hlc_physical INTEGER NOT NULL DEFAULT 0,
          hlc_logical INTEGER NOT NULL DEFAULT 0,
          actor_id TEXT
        )
      ''');
      await snapshotDb.execute('''
        CREATE TABLE property_value (
          id TEXT PRIMARY KEY,
          node_id TEXT NOT NULL,
          property_schema_id TEXT NOT NULL,
          value TEXT NOT NULL,
          idx INTEGER NOT NULL DEFAULT 0,
          metadata TEXT,
          hlc_physical INTEGER NOT NULL DEFAULT 0,
          hlc_logical INTEGER NOT NULL DEFAULT 0,
          actor_id TEXT
        )
      ''');
      await snapshotDb.execute('''
        CREATE TABLE property_value_tombstone (
          node_id TEXT NOT NULL,
          property_schema_id TEXT NOT NULL,
          idx INTEGER NOT NULL DEFAULT 0,
          hlc_physical INTEGER NOT NULL DEFAULT 0,
          hlc_logical INTEGER NOT NULL DEFAULT 0,
          actor_id TEXT,
          PRIMARY KEY (node_id, property_schema_id, idx)
        )
      ''');
      await snapshotDb.execute('''
        CREATE TABLE node_child_order (
          parent_id TEXT NOT NULL,
          child_id TEXT NOT NULL,
          position TEXT NOT NULL,
          PRIMARY KEY (parent_id, child_id)
        )
      ''');
      await snapshotDb.execute('''
        CREATE TABLE class (
          id TEXT PRIMARY KEY,
          workspace_id TEXT NOT NULL,
          name TEXT NOT NULL,
          icon TEXT,
          color TEXT,
          description TEXT,
          active INTEGER NOT NULL DEFAULT 1,
          created_at TEXT,
          updated_at TEXT
        )
      ''');
      await snapshotDb.execute('''
        CREATE TABLE class_extends (
          class_id TEXT NOT NULL,
          parent_class_id TEXT NOT NULL,
          PRIMARY KEY (class_id, parent_class_id)
        )
      ''');
      await snapshotDb.execute('''
        CREATE TABLE class_member_set (
          node_id TEXT NOT NULL,
          class_id TEXT NOT NULL,
          present INTEGER NOT NULL,
          hlc_physical INTEGER NOT NULL DEFAULT 0,
          hlc_logical INTEGER NOT NULL DEFAULT 0,
          actor_id TEXT,
          PRIMARY KEY (node_id, class_id)
        )
      ''');
      await snapshotDb.execute('''
        CREATE TABLE property_schema (
          id TEXT PRIMARY KEY,
          workspace_id TEXT NOT NULL,
          name TEXT NOT NULL,
          type TEXT NOT NULL DEFAULT 'text',
          multi INTEGER NOT NULL DEFAULT 0,
          scope TEXT NOT NULL DEFAULT 'global',
          options TEXT NOT NULL DEFAULT '[]',
          target_class_filter TEXT,
          active INTEGER NOT NULL DEFAULT 1,
          created_at TEXT,
          updated_at TEXT
        )
      ''');
      await snapshotDb.execute('''
        CREATE TABLE class_property (
          class_id TEXT NOT NULL,
          property_schema_id TEXT NOT NULL,
          sequence INTEGER NOT NULL DEFAULT 0,
          required INTEGER,
          readonly INTEGER,
          hide_when_empty INTEGER,
          default_value TEXT,
          PRIMARY KEY (class_id, property_schema_id)
        )
      ''');
      await snapshotDb.execute('''
        CREATE TABLE collection_member (
          collection_id TEXT NOT NULL,
          object_id TEXT NOT NULL,
          present INTEGER NOT NULL,
          hlc_physical INTEGER NOT NULL DEFAULT 0,
          hlc_logical INTEGER NOT NULL DEFAULT 0,
          actor_id TEXT,
          PRIMARY KEY (collection_id, object_id)
        )
      ''');
    });

    tearDown(() async {
      await snapshotDb.close();
    });

    test('reads page, task, properties, and child order from a snapshot',
        () async {
      const workspaceId = 'ws-1';
      await snapshotDb.insert('node', {
        'id': 'page-1',
        'workspace_id': workspaceId,
        'is_class': 0,
        'present_as_main': 1,
        'class_ids': '[]',
        'name': 'Hello page',
        'parent_id': null,
        'content': '[{"type":"paragraph","children":[{"type":"text","text":"Hello"}]}]',
        'icon': '📄',
        'color': null,
        'is_active': 1,
        'updated_at': '2026-01-02T10:00:00Z',
        'hlc_physical': 1727200000000,
        'hlc_logical': 0,
        'actor_id': 'actor-1',
      });
      await snapshotDb.insert('node', {
        'id': 'task-1',
        'workspace_id': workspaceId,
        'is_class': 0,
        'present_as_main': 0,
        'class_ids': '["${SystemClassUuids.task}"]',
        'parent_id': 'page-1',
        'content': '[{"type":"paragraph","children":[{"type":"text","text":"Buy milk"}]}]',
        'is_active': 1,
        'updated_at': '2026-01-02T11:00:00Z',
      });
      await snapshotDb.insert('node', {
        'id': 'archived-1',
        'workspace_id': workspaceId,
        'is_class': 0,
        'present_as_main': 1,
        'class_ids': '[]',
        'is_active': 0,
        'updated_at': '2026-01-01T00:00:00Z',
      });
      await snapshotDb.insert('property_value', {
        'id': 'pv-1',
        'node_id': 'task-1',
        'property_schema_id': SystemPropertyUuids.taskStatus,
        'value': '"Pending"',
        'idx': 0,
        'hlc_physical': 1727200000000,
        'hlc_logical': 0,
        'actor_id': 'actor-1',
      });
      await snapshotDb.insert('node_child_order', {
        'parent_id': 'page-1',
        'child_id': 'task-1',
        'position': 'a',
      });
      await snapshotDb.insert('class_member_set', {
        'node_id': 'task-1',
        'class_id': SystemClassUuids.task,
        'present': 1,
      });

      // We need a NodeCacheRepository to call the helper; the AppDatabase
      // itself is not used by the reader, but the constructor requires one.
      AppDatabase.reset();
      final appDb = AppDatabase.inMemory();
      final readerRepo = NodeCacheRepository(appDb);

      final snapshot = await readerRepo.readSnapshot(snapshotDb, workspaceId);
      final nodes = snapshot.nodes;

      expect(nodes.length, 3);

      final page = nodes.firstWhere((n) => n.uuid == 'page-1');
      expect(page.isPage, isTrue);
      expect(page.isClass, isFalse);
      expect(page.presentAsMain, isTrue);
      // Title-is-content: the retired node `name` column is ignored; the
      // display name derives from the content excerpt (legacy paragraph AST
      // normalizes to 'Hello').
      expect(page.title, isNull);
      expect(page.displayName, 'Hello');
      expect(page.icon, '📄');
      expect(page.hlcPhysical, 1727200000000);

      final task = nodes.firstWhere((n) => n.uuid == 'task-1');
      expect(task.isTask, isTrue);
      expect(task.isClass, isFalse);
      expect(task.presentAsMain, isFalse);
      expect(task.parentUuid, 'page-1');
      // Fractional positions stay strings.
      expect(task.position, 'a');
      expect(task.properties[SystemPropertyUuids.taskStatus], 'Pending');
      expect(snapshot.propertyValueRows, hasLength(1));
      expect(snapshot.classMemberRows, hasLength(1));

      final archived = nodes.firstWhere((n) => n.uuid == 'archived-1');
      expect(archived.isPage, isTrue);
      expect(archived.isArchived, isTrue);
      expect(archived.isDeleted, isFalse);

      await appDb.close();
      AppDatabase.reset();
    });
  });

  group('AppDatabase v19 → v20 migration (Revision 11 render-state model)',
      () {
    late Database ffiDb;

    setUp(() async {
      AppDatabase.reset();
      ffiDb = await databaseFactoryFfi.openDatabase(
        ':memory:',
        options: OpenDatabaseOptions(singleInstance: false),
      );
      // The v19 node_cache shape: base table + v16 columns (title, position,
      // node_type, hlc winner) + v19 class_order.
      await ffiDb.execute('''
        CREATE TABLE node_cache (
          uuid TEXT PRIMARY KEY,
          name TEXT,
          parent_uuid TEXT,
          classes_uuid TEXT,
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
          node_type TEXT,
          hlc_physical INTEGER NOT NULL DEFAULT 0,
          hlc_logical INTEGER NOT NULL DEFAULT 0,
          actor_id TEXT,
          class_order TEXT NOT NULL DEFAULT '[]'
        )
      ''');
      await ffiDb.execute(
        'CREATE INDEX idx_node_cache_parent ON node_cache(parent_uuid)',
      );
      await ffiDb.execute(
        'CREATE INDEX idx_node_cache_deleted ON node_cache(is_deleted)',
      );
      await ffiDb.execute(
        'CREATE INDEX idx_node_cache_page ON node_cache(is_page)',
      );
    });

    tearDown(() async {
      await ffiDb.close();
      AppDatabase.reset();
    });

    test('rebuilds node_type into is_class/present_as_main and drops it',
        () async {
      // Payload blobs embed the toJson shape; after the wipe every blob is
      // rewritten by the new code, so the blobs carry the new keys (the
      // migration maps the retired node_type column, not the blobs).
      String payload(String uuid, {bool page = false, bool cls = false}) =>
          '{"id": 0, "uuid": "$uuid", "name": "[]", "display_name": "", '
              '"is_page": $page, "is_class": $cls, '
              '"present_as_main": ${page && !cls}}';
      await ffiDb.insert('node_cache', {
        'uuid': 'page-1',
        'name': '[]',
        'parent_uuid': null,
        'classes_uuid': '[]',
        'is_page': 1,
        'payload': payload('page-1', page: true),
        'synced_at': 1,
        'node_type': 'page',
      });
      await ffiDb.insert('node_cache', {
        'uuid': 'block-1',
        'name': '[]',
        'parent_uuid': 'page-1',
        'classes_uuid': '[]',
        'is_page': 0,
        'payload': payload('block-1'),
        'synced_at': 2,
        'node_type': 'block',
      });
      await ffiDb.insert('node_cache', {
        'uuid': 'class-1',
        'name': '[]',
        'parent_uuid': null,
        'classes_uuid': '[]',
        'is_page': 0,
        'payload': payload('class-1', cls: true),
        'synced_at': 3,
        'node_type': 'class',
      });

      // initializeSchema runs the full migration chain on the pre-existing
      // table (all CREATEs are IF NOT EXISTS; _migrateV20 rebuilds it).
      final database = AppDatabase.fromDatabase(ffiDb);
      await database.initializeSchema();

      final columns = await ffiDb
          .rawQuery('PRAGMA table_info(node_cache)')
          .then((rows) => rows.map((r) => r['name'] as String).toList());
      expect(columns, contains('is_class'));
      expect(columns, contains('present_as_main'));
      expect(columns, isNot(contains('node_type')));

      final rows = await ffiDb.rawQuery(
        'SELECT uuid, is_class, present_as_main FROM node_cache '
        'ORDER BY uuid',
      );
      expect(
        rows
            .map(
              (r) => (
                r['uuid'],
                r['is_class'],
                r['present_as_main'],
              ),
            )
            .toList(),
        [
          ('block-1', 0, 0),
          ('class-1', 1, 0),
          ('page-1', 0, 1),
        ],
      );

      // The repository reads the new columns back through the Node model.
      final repo = NodeCacheRepository(database);
      final page = await repo.getByUuid('page-1');
      expect(page!.presentAsMain, isTrue);
      expect(page.isClass, isFalse);
      final cls = await repo.getByUuid('class-1');
      expect(cls!.isClass, isTrue);
      expect(cls.presentAsMain, isFalse);

      // The v20 placement CHECK is live: a class with a parent, and any
      // is_class row under a parent, is rejected by SQLite.
      expect(
        () => ffiDb.insert('node_cache', {
          'uuid': 'class-2',
          'name': '[]',
          'parent_uuid': 'page-1',
          'classes_uuid': '[]',
          'payload': '{}',
          'synced_at': 4,
          'is_class': 1,
        }),
        throwsA(isA<DatabaseException>()),
      );
    });
  });

  group('AppDatabase v25 → v26 migration (render contracts to the '
      'property)', () {
    late Database ffiDb;

    setUp(() async {
      AppDatabase.reset();
      ffiDb = await databaseFactoryFfi.openDatabase(
        ':memory:',
        options: OpenDatabaseOptions(singleInstance: false),
      );
      // The v25 class_property shape: the binding-level experiment
      // (display) on top of the original shape (readonly/hide_when_empty).
      // (property_schema is created by the chain at its current shape — its
      // CREATE is not idempotent, so the display add-column guard is covered
      // by the same _addColumnIfMissing helper as v24 rather than a fixture.)
      await ffiDb.execute('''
        CREATE TABLE class_property (
          class_id TEXT NOT NULL,
          property_schema_id TEXT NOT NULL,
          sequence INTEGER NOT NULL DEFAULT 0,
          required INTEGER,
          readonly INTEGER,
          hide_when_empty INTEGER,
          default_value TEXT,
          display TEXT,
          hlc_physical INTEGER NOT NULL DEFAULT 0,
          hlc_logical INTEGER NOT NULL DEFAULT 0,
          actor_id TEXT,
          active INTEGER NOT NULL DEFAULT 1,
          PRIMARY KEY (class_id, property_schema_id)
        )
      ''');
    });

    tearDown(() async {
      await ffiDb.close();
      AppDatabase.reset();
    });

    test('rebuilds class_property without the retired columns (rows copy '
        'verbatim, required + LWW survive) and adds property_schema.display; '
        'schema display rides the effective read', () async {
      // A pre-v26 binding row already lives in the table.
      await ffiDb.insert('class_property', {
        'class_id': '0192a000-0000-7000-8000-000000000900',
        'property_schema_id': '0192a000-0000-7000-8000-000000000901',
        'sequence': 7,
        'required': 1,
        'default_value': '"legacy"',
        'readonly': 1,
        'hide_when_empty': 1,
        'display': 'inline',
        'active': 1,
        'hlc_physical': 42,
        'hlc_logical': 1,
        'actor_id': 'legacy-actor',
      });
      final database = AppDatabase.fromDatabase(ffiDb);
      await database.initializeSchema();

      // class_property: rebuilt to the per-class mechanics ONLY.
      final columns = await ffiDb.rawQuery('PRAGMA table_info(class_property)');
      final names = columns.map((c) => c['name'] as String).toList();
      expect(names, contains('required'));
      expect(names, contains('default_value'));
      expect(names, contains('active'));
      expect(names, contains('hlc_physical'));
      expect(names, isNot(contains('readonly')));
      expect(names, isNot(contains('hide_when_empty')));
      expect(names, isNot(contains('display')));
      // The surviving row copies verbatim (retired values dropped, LWW kept).
      final migrated = await ffiDb.rawQuery(
        'SELECT sequence, required, default_value, active, hlc_physical, '
        'hlc_logical, actor_id FROM class_property WHERE class_id = ?',
        ['0192a000-0000-7000-8000-000000000900'],
      );
      expect(migrated.single['sequence'], 7);
      expect(migrated.single['required'], 1);
      expect(migrated.single['default_value'], '"legacy"');
      expect(migrated.single['active'], 1);
      expect(migrated.single['hlc_physical'], 42);
      expect(migrated.single['hlc_logical'], 1);
      expect(migrated.single['actor_id'], 'legacy-actor');

      // property_schema: created by the chain at its current shape — the
      // display column is present for the schema-side write below.
      final schemaColumns =
          await ffiDb.rawQuery('PRAGMA table_info(property_schema)');
      expect(
        schemaColumns.map((c) => c['name'] as String),
        contains('display'),
      );

      // A schema-side display write lands through the applier on the
      // migrated tables and reads back on the effective row.
      const classId = '0192a000-0000-7000-8000-000000000901';
      const schemaId = '0192a000-0000-7000-8000-000000000902';
      const nodeId = '0192a000-0000-7000-8000-000000000903';
      final cache = NodeCacheRepository(database);
      final appliers = RelayAppliers(cache);
      await appliers.apply(OperationEnvelope(
        id: '0192a000-0000-7000-8000-000000000910',
        workspaceId: '0192a000-0000-7000-8000-000000000001',
        actorId: '0192a000-0000-7000-8000-000000000002',
        deviceId: 'migration-test-device',
        hlc: const Hlc(physical: 1000, logical: 0),
        affectedNodeIds: const [classId],
        opType: 'propertySchema.create',
        payload: OperationPayloads.propertySchemaCreate(
          propertySchemaId: schemaId,
          name: 'Stage',
          type: 'select',
          display: 'bullet',
        ),
        timestamp: '2026-09-24T12:00:00.000Z',
      ));
      await appliers.apply(OperationEnvelope(
        id: '0192a000-0000-7000-8000-000000000911',
        workspaceId: '0192a000-0000-7000-8000-000000000001',
        actorId: '0192a000-0000-7000-8000-000000000002',
        deviceId: 'migration-test-device',
        hlc: const Hlc(physical: 1100, logical: 0),
        affectedNodeIds: const [classId],
        opType: 'class.property.set',
        payload: OperationPayloads.classPropertySet(
          classId: classId,
          propertySchemaId: schemaId,
          defaultValue: 'x',
        ),
        timestamp: '2026-09-24T12:00:01.000Z',
      ));
      await appliers.apply(OperationEnvelope(
        id: '0192a000-0000-7000-8000-000000000912',
        workspaceId: '0192a000-0000-7000-8000-000000000001',
        actorId: '0192a000-0000-7000-8000-000000000002',
        deviceId: 'migration-test-device',
        hlc: const Hlc(physical: 1200, logical: 0),
        affectedNodeIds: const [nodeId],
        opType: 'object.create',
        payload: OperationPayloads.objectCreate(
          objectId: nodeId,
          classIds: const [classId],
        ),
        timestamp: '2026-09-24T12:00:02.000Z',
      ));
      final rows = await ffiDb.rawQuery(
        'SELECT display FROM property_schema WHERE uuid = ?',
        [schemaId],
      );
      expect(rows.single['display'], 'bullet');
      final effective = await cache.getEffectiveProperties(nodeId);
      expect(effective.single.display, 'bullet');
    });
  });
}
