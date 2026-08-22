import 'dart:convert';

import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:notees/data/local/app_database.dart';
import 'package:notees/data/models/node.dart';
import 'package:notees/data/repositories/node_cache_repository.dart';
import 'package:notees/domain/services/sync_v2_service.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  sqfliteFfiInit();

  group('SyncV2Service pull', () {
    late AppDatabase database;
    late SyncV2Service syncService;

    Map<String, dynamic> envelopeJson({
      required String id,
      required String opType,
      required Map<String, dynamic> payload,
      int physical = 1,
      String actorId = 'user-1',
    }) =>
        {
          'id': id,
          'protocolVersion': 1,
          'workspaceId': 'ws-1',
          'actorId': actorId,
          'hlc': {'physical': physical, 'logical': 0},
          'affectedNodeIds': [payload['nodeId'] ?? ''],
          'opType': opType,
          'payload': payload,
          'timestamp': '2026-08-09T12:00:00.000Z',
        };

    /// Builds a Dio whose catch-up endpoint serves [pages] in order; a null
    /// page rejects with a connection error (simulating a mid-pull crash).
    Dio buildDio(List<Map<String, dynamic>?> pages) {
      var catchUpCalls = 0;
      final dio = Dio();
      dio.interceptors.add(
        InterceptorsWrapper(
          onRequest: (options, handler) {
            if (options.path == '/relay/snapshot') {
              handler.resolve(Response(
                requestOptions: options,
                data: const {
                  'snapshot_id': null,
                  'workspace_id': 'ws-1',
                  'hlc': {'physical': 0, 'logical': 0},
                  'data_base64': null,
                  'has_snapshot': false,
                  'restore_epoch': 0,
                  'up_to_seq': null,
                },
                statusCode: 200,
              ));
              return;
            }
            if (options.path == '/relay/catch-up') {
              final index = catchUpCalls < pages.length
                  ? catchUpCalls
                  : pages.length - 1;
              catchUpCalls++;
              final page = pages[index];
              if (page == null) {
                handler.reject(DioException(
                  requestOptions: options,
                  type: DioExceptionType.connectionError,
                  error: 'boom',
                ));
                return;
              }
              handler.resolve(Response(
                requestOptions: options,
                data: page,
                statusCode: 200,
              ));
              return;
            }
            handler.resolve(Response(
              requestOptions: options,
              data: const {'saved_count': 1, 'saved_ids': ['id']},
              statusCode: 200,
            ));
          },
        ),
      );
      return dio;
    }

    Map<String, dynamic> page(
      List<Map<String, dynamic>> envelopes,
      int nextAfterSeq, {
      bool hasMore = false,
    }) =>
        {
          'envelopes': envelopes,
          'next_after_seq': nextAfterSeq,
          'has_more': hasMore,
          'restore_epoch': 0,
        };

    Future<int> cursorSeq() async {
      final db = await database.database;
      final rows = await db.query(
        'sync_watermark',
        columns: ['cursor_seq'],
        where: 'workspace_id = ?',
        whereArgs: const ['ws-1'],
      );
      if (rows.isEmpty) return 0;
      return rows.first['cursor_seq'] as int? ?? 0;
    }

    Future<void> seedMetadataCaches() async {
      // Keep pull() from force-resetting the workspace due to empty class and
      // property-schema caches.
      final cache = NodeCacheRepository(database);
      await cache.upsertClass(uuid: 'class-1', name: 'Class');
      await cache.upsertPropertySchema(
        PropertySchemaRow(uuid: 'schema-1', workspaceId: 'ws-1', name: 'P'),
      );
    }

    setUp(() async {
      final ffiDb = await databaseFactoryFfi.openDatabase(
        ':memory:',
        options: OpenDatabaseOptions(singleInstance: false),
      );
      database = AppDatabase.fromDatabase(ffiDb);
      await database.initializeSchema();
      await seedMetadataCaches();
    });

    tearDown(() async {
      await database.close();
      AppDatabase.reset();
    });

    test('persists the cursor per page and dedupes already-applied envelopes',
        () async {
      // First pull: page 1 applies, page 2 fails mid-pull.
      syncService = SyncV2Service(
        database: database,
        dio: buildDio([
          page([
            envelopeJson(
              id: 'op-1',
              opType: 'node.create',
              payload: {'nodeId': 'n-1', 'kind': 'page', 'classIds': const <String>[]},
            ),
          ], 1, hasMore: true),
          null, // connection error on the second page
        ]),
        clientId: 'test-client',
      );
      await syncService.setWorkspaceId('ws-1');

      await expectLater(syncService.pull(), throwsA(isA<DioException>()));
      // Page 1 was applied and its cursor persisted despite the crash.
      expect(await cursorSeq(), 1);
      final cache = syncService.cache;
      expect((await cache.getByUuid('n-1'))!.displayName, '');

      // Locally rename the node: if op-1 is re-applied below, the name
      // reverts; dedupe must skip it.
      final node = (await cache.getByUuid('n-1'))!;
      await cache.upsert(Node(
        id: node.id,
        uuid: node.uuid,
        name: 'edited-locally',
        displayName: 'edited-locally',
        classesUuid: node.classesUuid,
        properties: node.properties,
        isPage: node.isPage,
      ));

      // Second pull re-serves op-1 (cursor was rewound server-side) plus op-2.
      syncService = SyncV2Service(
        database: database,
        dio: buildDio([
          page([
            envelopeJson(
              id: 'op-1',
              opType: 'node.create',
              payload: {'nodeId': 'n-1', 'kind': 'page', 'classIds': const <String>[]},
            ),
            envelopeJson(
              id: 'op-2',
              opType: 'node.create',
              payload: {'nodeId': 'n-2', 'kind': 'page', 'classIds': const <String>[]},
              physical: 2,
            ),
          ], 2),
        ]),
        clientId: 'test-client',
      );
      await syncService.setWorkspaceId('ws-1');
      await syncService.pull();

      expect(await cursorSeq(), 2);
      expect((await cache.getByUuid('n-1'))!.displayName, 'edited-locally');
      expect(await cache.getByUuid('n-2'), isNotNull);

      final db = await database.database;
      final rows = await db.query(
        'relay_operations',
        where: 'id = ?',
        whereArgs: const ['op-1'],
      );
      expect(rows, hasLength(1));
    });

    test('skips enqueueing content ops with a null AST', () async {
      syncService = SyncV2Service(
        database: database,
        dio: buildDio([page(const [], 0)]),
        clientId: 'test-client',
      );
      await syncService.setWorkspaceId('ws-1');

      await syncService.enqueue(type: 'update_content', nodeUuid: 'n-1');
      await syncService.enqueue(type: 'update_node', nodeUuid: 'n-1');

      final db = await database.database;
      final outbox = await db.query('relay_outbox');
      expect(outbox, isEmpty);

      // A real AST still enqueues.
      await syncService.enqueue(
        type: 'update_content',
        nodeUuid: 'n-1',
        contentAst: const [
          {'type': 'text', 'text': 'hi'},
        ],
      );
      final after = await db.query('relay_outbox');
      expect(after, hasLength(1));
    });

    test('stamps the authenticated user uuid as actor id', () async {
      syncService = SyncV2Service(
        database: database,
        dio: buildDio([page(const [], 0)]),
        clientId: 'test-client',
      );
      await syncService.setWorkspaceId('ws-1');

      expect(syncService.hasUserActor, isFalse);
      expect(syncService.actorId, 'test-client');

      syncService.actorId = 'user-uuid-1';
      expect(syncService.hasUserActor, isTrue);

      await syncService.enqueue(type: 'archive', nodeUuid: 'n-1');
      await syncService.flush();

      final db = await database.database;
      final rows = await db.query('relay_operations');
      expect(rows, hasLength(1));
      expect(rows.first['actor_id'], 'user-uuid-1');
      expect(jsonDecode(rows.first['payload'] as String), {'nodeId': 'n-1'});

      syncService.actorId = null;
      expect(syncService.actorId, 'test-client');
    });
  });
}
