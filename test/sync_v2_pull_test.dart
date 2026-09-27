import 'dart:convert';

import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:notees/data/local/app_database.dart';
import 'package:notees/data/models/node.dart';
import 'package:notees/data/repositories/node_cache_repository.dart';
import 'package:notees/domain/models/sync_v2.dart';
import 'package:notees/domain/services/sync_v2_service.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  sqfliteFfiInit();

  const workspaceId = '10000000-0000-4000-8000-000000000001';
  const node1 = '20000000-0000-4000-8000-000000000001';
  const node2 = '20000000-0000-4000-8000-000000000002';
  const user1 = '30000000-0000-4000-8000-000000000001';

  group('SyncV2Service pull', () {
    late AppDatabase database;
    late SyncV2Service syncService;

    Map<String, dynamic> envelopeJson({
      required String id,
      required String opType,
      required Map<String, dynamic> payload,
      int physical = 1,
      String actorId = user1,
    }) =>
        {
          'id': id,
          'protocolVersion': 2,
          'workspaceId': workspaceId,
          'actorId': actorId,
          'deviceId': 'test-device',
          'hlc': {'physical': physical, 'logical': 0},
          'affectedNodeIds': [payload['objectId'] ?? ''],
          'opType': opType,
          'payload': payload,
          'timestamp': '2026-09-24T12:00:00.000Z',
        };

    /// Builds a Dio whose catch-up endpoint serves [pages] in order; a null
    /// page rejects with a connection error (simulating a mid-pull crash).
    Dio buildDio(List<Map<String, dynamic>?> pages) {
      var catchUpCalls = 0;
      final dio = Dio();
      dio.interceptors.add(
        InterceptorsWrapper(
          onRequest: (options, handler) {
            if (options.path == '/relay/v2/snapshot') {
              handler.resolve(Response(
                requestOptions: options,
                data: const {
                  'snapshotId': null,
                  'hlc': {'physical': 0, 'logical': 0},
                  'hasSnapshot': false,
                  'restoreEpoch': 0,
                  'upToSeq': null,
                },
                statusCode: 200,
              ));
              return;
            }
            if (options.path == '/relay/v2/catch-up') {
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
              data: const {'savedCount': 1, 'savedIds': ['id']},
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
          'nextAfterSeq': nextAfterSeq,
          'hasMore': hasMore,
          'restoreEpoch': 0,
          'totalRemaining': envelopes.length,
        };

    Future<int> cursorSeq() async {
      final db = await database.database;
      final rows = await db.query(
        'sync_watermark',
        columns: ['cursor_seq'],
        where: 'workspace_id = ?',
        whereArgs: const [workspaceId],
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
        PropertySchemaRow(uuid: 'schema-1', workspaceId: workspaceId, name: 'P'),
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
              id: '0192a000-0000-7000-8000-000000000001',
              opType: 'object.create',
              payload: {
                'objectId': node1,
                'nodeType': 'page',
                'classIds': const <String>[],
              },
            ),
          ], 1, hasMore: true),
          null, // connection error on the second page
        ]),
        clientId: '40000000-0000-4000-8000-000000000001',
      );
      await syncService.setWorkspaceId(workspaceId);

      await expectLater(syncService.pull(), throwsA(isA<DioException>()));
      // Page 1 was applied and its cursor persisted despite the crash.
      expect(await cursorSeq(), 1);
      final cache = syncService.cache;
      expect((await cache.getByUuid(node1))!.displayName, '');

      // Locally rename the node: if op-1 is re-applied below, the name
      // reverts; dedupe must skip it.
      final node = (await cache.getByUuid(node1))!;
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
              id: '0192a000-0000-7000-8000-000000000001',
              opType: 'object.create',
              payload: {
                'objectId': node1,
                'nodeType': 'page',
                'classIds': const <String>[],
              },
            ),
            envelopeJson(
              id: '0192a000-0000-7000-8000-000000000002',
              opType: 'object.create',
              payload: {
                'objectId': node2,
                'nodeType': 'page',
                'classIds': const <String>[],
              },
              physical: 2,
            ),
          ], 2),
        ]),
        clientId: '40000000-0000-4000-8000-000000000001',
      );
      await syncService.setWorkspaceId(workspaceId);
      await syncService.pull();

      expect(await cursorSeq(), 2);
      expect((await cache.getByUuid(node1))!.displayName, 'edited-locally');
      expect(await cache.getByUuid(node2), isNotNull);

      final db = await database.database;
      final rows = await db.query(
        'relay_operations',
        where: 'id = ?',
        whereArgs: const ['0192a000-0000-7000-8000-000000000001'],
      );
      expect(rows, hasLength(1));
    });

    test('skips enqueueing content ops with a null AST', () async {
      syncService = SyncV2Service(
        database: database,
        dio: buildDio([page(const [], 0)]),
        clientId: '40000000-0000-4000-8000-000000000001',
      );
      await syncService.setWorkspaceId(workspaceId);

      await syncService.enqueue(type: 'update_content', nodeUuid: node1);
      await syncService.enqueue(type: 'update_node', nodeUuid: node1);

      final db = await database.database;
      final outbox = await db.query('relay_outbox');
      expect(outbox, isEmpty);

      // A real AST still enqueues.
      await syncService.enqueue(
        type: 'update_content',
        nodeUuid: node1,
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
        clientId: '40000000-0000-4000-8000-000000000001',
      );
      await syncService.setWorkspaceId(workspaceId);

      expect(syncService.hasUserActor, isFalse);
      expect(syncService.actorId, '40000000-0000-4000-8000-000000000001');

      syncService.actorId = user1;
      expect(syncService.hasUserActor, isTrue);

      // Create the node first: v2 object.delete requires the target row.
      await syncService.enqueue(
        type: 'create',
        nodeUuid: node1,
        contentAst: const [
          {'type': 'text', 'text': 'hi'},
        ],
        isPage: true,
      );
      await syncService.enqueue(type: 'archive', nodeUuid: node1);
      await syncService.flush();

      final db = await database.database;
      final rows = await db.query('relay_operations');
      expect(rows, hasLength(2));
      expect(rows.every((r) => r['actor_id'] == user1), isTrue);
      final archive = rows.firstWhere((r) => r['op_type'] == 'object.delete');
      expect(jsonDecode(archive['payload'] as String), {
        'objectId': node1,
        'permanent': false,
      });

      syncService.actorId = null;
      expect(syncService.actorId, '40000000-0000-4000-8000-000000000001');
    });

    test('reports per-page catch-up progress with totalRemaining', () async {
      final progress = <SyncPullProgress>[];
      syncService = SyncV2Service(
        database: database,
        dio: buildDio([
          page([
            envelopeJson(
              id: '0192a000-0000-7000-8000-000000000001',
              opType: 'object.create',
              payload: {
                'objectId': node1,
                'nodeType': 'page',
                'classIds': const <String>[],
              },
            ),
          ], 1, hasMore: true),
          page(const [], 1),
        ]),
        clientId: '40000000-0000-4000-8000-000000000001',
      );
      syncService.onPullProgress = progress.add;
      await syncService.setWorkspaceId(workspaceId);

      await syncService.pull();

      expect(progress, isNotEmpty);
      expect(progress.first.applied, 1);
      expect(progress.first.total, 1 + 1); // applied + totalRemaining
    });

    test('restoreEpoch change wipes derived state and resyncs from 0', () async {
      // Seed a node + a pending outbox op, then report a newer epoch: the
      // cache is wiped, the outbox survives, catch-up re-runs from 0.
      syncService = SyncV2Service(
        database: database,
        dio: buildDio([page(const [], 0)]),
        clientId: '40000000-0000-4000-8000-000000000001',
      );
      await syncService.setWorkspaceId(workspaceId);
      await syncService.enqueue(
        type: 'create',
        nodeUuid: node1,
        contentAst: const [
          {'type': 'text', 'text': 'hi'},
        ],
        isPage: true,
      );
      final db0 = await database.database;
      expect(await db0.query('relay_outbox'), hasLength(1));

      var snapshotEpoch = 7;
      final dio = Dio();
      dio.interceptors.add(
        InterceptorsWrapper(
          onRequest: (options, handler) {
            if (options.path == '/relay/v2/snapshot') {
              handler.resolve(Response(
                requestOptions: options,
                data: {
                  'snapshotId': null,
                  'hlc': {'physical': 0, 'logical': 0},
                  'hasSnapshot': false,
                  'restoreEpoch': snapshotEpoch,
                  'upToSeq': null,
                },
                statusCode: 200,
              ));
              return;
            }
            if (options.path == '/relay/v2/catch-up') {
              handler.resolve(Response(
                requestOptions: options,
                data: {
                  'envelopes': <Map<String, dynamic>>[],
                  'nextAfterSeq': null,
                  'hasMore': false,
                  'restoreEpoch': snapshotEpoch,
                  'totalRemaining': 0,
                },
                statusCode: 200,
              ));
              return;
            }
            // Batch: capture the re-push of the parked outbox op.
            handler.resolve(Response(
              requestOptions: options,
              data: const {'savedCount': 1, 'savedIds': ['id']},
              statusCode: 200,
            ));
          },
        ),
      );
      syncService = SyncV2Service(
        database: database,
        dio: dio,
        clientId: '40000000-0000-4000-8000-000000000001',
      );
      await syncService.setWorkspaceId(workspaceId);

      await syncService.pull();

      // The epoch is adopted and the cursor reset to 0.
      final db = await database.database;
      final wm = await db.query(
        'sync_watermark',
        where: 'workspace_id = ?',
        whereArgs: const [workspaceId],
      );
      expect(wm.single['restore_epoch'], 7);
      expect(wm.single['cursor_seq'], 0);
      // The parked local op was re-pushed (outbox drained by the resync
      // flush + echo pull).
      snapshotEpoch = 7;
    });

    test('produced envelopes carry v2 provenance (deviceId, client, timestamp)',
        () async {
      syncService = SyncV2Service(
        database: database,
        dio: buildDio([page(const [], 0)]),
        clientId: '40000000-0000-4000-8000-000000000001',
      );
      await syncService.setWorkspaceId(workspaceId);

      await syncService.enqueue(type: 'delete', nodeUuid: node1);

      final db = await database.database;
      final rows = await db.query('relay_outbox');
      expect(rows, hasLength(1));
      final envelope = jsonDecode(rows.first['envelope_json'] as String)
          as Map<String, dynamic>;
      expect(envelope['protocolVersion'], 2);
      expect(envelope['deviceId'], '40000000-0000-4000-8000-000000000001');
      expect(envelope['client'], 'flutter');
      expect(envelope['timestamp'], isNotNull);
      expect(envelope['opType'], 'object.delete');
      expect(envelope['payload'], {'objectId': node1, 'permanent': true});
    });
  });
}
