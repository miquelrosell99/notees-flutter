import 'package:flutter_test/flutter_test.dart';
import 'package:notees/core/constants/system.dart';
import 'package:notees/data/local/app_database.dart';
import 'package:notees/data/models/node.dart';
import 'package:notees/data/repositories/node_cache_repository.dart';
import 'package:notees/domain/models/search_filters.dart';
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
      await repo.upsert(Node(id: 0, uuid: 'b-1', name: 'Block', displayName: 'Block'));

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
        const SearchFilters(nodeType: NodeType.page),
      );
      expect(pages.length, 1);
      expect(pages.first.uuid, 'p-1');

      final tasks = await repo.searchWithFilters(
        const SearchFilters(nodeType: NodeType.task),
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
      await snapshotDb.execute('''
        CREATE TABLE node (
          id TEXT PRIMARY KEY,
          workspace_id TEXT NOT NULL,
          kind TEXT NOT NULL,
          class_ids TEXT NOT NULL DEFAULT '[]',
          parent_id TEXT,
          content TEXT NOT NULL DEFAULT '[]',
          icon TEXT,
          color TEXT,
          active INTEGER NOT NULL DEFAULT 1,
          created_at TEXT,
          updated_at TEXT,
          created_by TEXT,
          updated_by TEXT
        )
      ''');
      await snapshotDb.execute('''
        CREATE TABLE property_value (
          id TEXT PRIMARY KEY,
          node_id TEXT NOT NULL,
          property_schema_id TEXT NOT NULL,
          value TEXT NOT NULL,
          idx INTEGER NOT NULL DEFAULT 0
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
    });

    tearDown(() async {
      await snapshotDb.close();
    });

    test('reads page, task, properties, and child order from snapshot', () async {
      const workspaceId = 'ws-1';
      await snapshotDb.insert('node', {
        'id': 'page-1',
        'workspace_id': workspaceId,
        'kind': 'page',
        'class_ids': '[]',
        'parent_id': null,
        'content': '[{"type":"paragraph","children":[{"type":"text","text":"Hello"}]}]',
        'icon': '📄',
        'color': null,
        'active': 1,
        'updated_at': '2026-01-02T10:00:00Z',
      });
      await snapshotDb.insert('node', {
        'id': 'task-1',
        'workspace_id': workspaceId,
        'kind': 'block',
        'class_ids': '["${SystemClassUuids.task}"]',
        'parent_id': 'page-1',
        'content': '[{"type":"paragraph","children":[{"type":"text","text":"Buy milk"}]}]',
        'active': 1,
        'updated_at': '2026-01-02T11:00:00Z',
      });
      await snapshotDb.insert('node', {
        'id': 'archived-1',
        'workspace_id': workspaceId,
        'kind': 'page',
        'class_ids': '[]',
        'active': 0,
        'updated_at': '2026-01-01T00:00:00Z',
      });
      await snapshotDb.insert('property_value', {
        'id': 'pv-1',
        'node_id': 'task-1',
        'property_schema_id': SystemPropertyUuids.taskStatus,
        'value': '"Pending"',
        'idx': 0,
      });
      await snapshotDb.insert('node_child_order', {
        'parent_id': 'page-1',
        'child_id': 'task-1',
        'position': '2.5',
      });

      // We need a NodeCacheRepository to call the helper; the AppDatabase
      // itself is not used by the reader, but the constructor requires one.
      AppDatabase.reset();
      final appDb = AppDatabase.inMemory();
      final readerRepo = NodeCacheRepository(appDb);

      final nodes = await readerRepo.readNodesFromSnapshotDatabase(
        snapshotDb,
        workspaceId,
      );

      expect(nodes.length, 3);

      final page = nodes.firstWhere((n) => n.uuid == 'page-1');
      expect(page.isPage, isTrue);
      expect(page.displayName, 'Hello');
      expect(page.icon, '📄');

      final task = nodes.firstWhere((n) => n.uuid == 'task-1');
      expect(task.isTask, isTrue);
      expect(task.parentUuid, 'page-1');
      expect(task.sequence, 2.5);
      expect(task.properties[SystemPropertyUuids.taskStatus], 'Pending');

      final archived = nodes.firstWhere((n) => n.uuid == 'archived-1');
      expect(archived.isPage, isTrue);
      expect(archived.isArchived, isTrue);
      expect(archived.isDeleted, isFalse);

      await appDb.close();
      AppDatabase.reset();
    });
  });
}
