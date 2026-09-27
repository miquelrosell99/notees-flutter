import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:notees/core/utils/ast_builder.dart';
import 'package:notees/data/local/app_database.dart';
import 'package:notees/data/repositories/node_cache_repository.dart';
import 'package:notees/domain/services/sync_v2_service.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  sqfliteFfiInit();

  const workspaceId = '10000000-0000-4000-8000-000000000001';

  group('SyncV2Service flush (server mode)', () {
    late AppDatabase database;
    late List<Map<String, dynamic>> pushed;

    /// Builds a Dio whose batch endpoint captures pushed envelopes into
    /// [pushed] and whose catch-up endpoint echoes them back, mirroring the
    /// server returning each client's own operations.
    Dio buildDio({bool failPush = false}) {
      final dio = Dio();
      dio.interceptors.add(
        InterceptorsWrapper(
          onRequest: (options, handler) {
            if (options.path == '/relay/v2/batch') {
              if (failPush) {
                handler.reject(DioException(
                  requestOptions: options,
                  type: DioExceptionType.connectionError,
                  error: 'offline',
                ));
                return;
              }
              final body = options.data as Map<String, dynamic>;
              final envelopes = (body['envelopes'] as List<dynamic>)
                  .cast<Map<String, dynamic>>();
              pushed.addAll(envelopes);
              handler.resolve(Response(
                requestOptions: options,
                data: {
                  'savedCount': envelopes.length,
                  'savedIds': envelopes.map((e) => e['id']).toList(),
                },
                statusCode: 200,
              ));
              return;
            }
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
              handler.resolve(Response(
                requestOptions: options,
                data: {
                  'envelopes': pushed,
                  'nextAfterSeq': pushed.isEmpty ? null : pushed.length,
                  'hasMore': false,
                  'restoreEpoch': 0,
                  'totalRemaining': pushed.length,
                },
                statusCode: 200,
              ));
              return;
            }
            handler.reject(DioException(
              requestOptions: options,
              type: DioExceptionType.connectionError,
              error: 'unexpected call to ${options.path}',
            ));
          },
        ),
      );
      return dio;
    }

    Future<SyncV2Service> buildService(Dio dio) async {
      final service = SyncV2Service(
        database: database,
        dio: dio,
        clientId: '40000000-0000-4000-8000-000000000001',
      );
      await service.setWorkspaceId(workspaceId);
      return service;
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
      pushed = [];
    });

    tearDown(() async {
      await database.close();
      AppDatabase.reset();
    });

    test('applies pushed envelopes to the local cache immediately', () async {
      final service = await buildService(buildDio());
      await service.enqueue(
        type: 'create',
        nodeUuid: '20000000-0000-4000-8000-000000000001',
        contentAst: AstBuilder.parseInline('Shopping'),
        isPage: true,
      );

      final errors = await service.flush();

      expect(errors, isEmpty);
      final node =
          await service.cache.getByUuid('20000000-0000-4000-8000-000000000001');
      expect(node, isNotNull);
      expect(node!.displayName, 'Shopping');
      expect(node.isPage, isTrue);

      // The wire envelope is a v2 object.create.
      expect(pushed, hasLength(1));
      expect(pushed.first['opType'], 'object.create');
      expect(pushed.first['protocolVersion'], 2);
      expect(pushed.first['payload']['objectId'],
          '20000000-0000-4000-8000-000000000001');
      expect(pushed.first['payload']['nodeType'], 'page');
      expect(pushed.first['deviceId'], '40000000-0000-4000-8000-000000000001');
      expect(pushed.first['client'], 'flutter');

      final db = await database.database;
      // The outbox is drained and the op recorded as locally applied.
      expect(await db.query('relay_outbox'), isEmpty);
      final ops = await db.query('relay_operations');
      expect(ops, hasLength(1));
      expect(ops.first['is_local'], 1);
    });

    test('applies renames (update_content) to the cached page title',
        () async {
      final service = await buildService(buildDio());
      await service.enqueue(
        type: 'create',
        nodeUuid: '20000000-0000-4000-8000-000000000001',
        contentAst: AstBuilder.parseInline('Shopping'),
        isPage: true,
      );
      await service.flush();

      await service.enqueue(
        type: 'update_content',
        nodeUuid: '20000000-0000-4000-8000-000000000001',
        contentAst: AstBuilder.parseInline('Groceries'),
      );
      await service.flush();

      final node =
          await service.cache.getByUuid('20000000-0000-4000-8000-000000000001');
      expect(node!.displayName, 'Groceries');
      expect(pushed.last['opType'], 'object.update');
      expect(pushed.last['payload']['contentAst'], isNotNull);
    });

    test('pull echo of own ops does not clobber or duplicate', () async {
      final service = await buildService(buildDio());
      await service.enqueue(
        type: 'create',
        nodeUuid: '20000000-0000-4000-8000-000000000001',
        contentAst: AstBuilder.parseInline('Shopping'),
        isPage: true,
      );
      await service.enqueue(
        type: 'update_content',
        nodeUuid: '20000000-0000-4000-8000-000000000001',
        contentAst: AstBuilder.parseInline('Groceries'),
      );
      await service.flush();
      expect(
          (await service.cache.getByUuid('20000000-0000-4000-8000-000000000001'))!
              .displayName,
          'Groceries');

      // The server echoes both own ops back on the next pull. The create
      // echo must be a no-op (first-create-wins parity) and the update echo
      // is skipped by the content HLC guard, so the rename survives.
      await service.pull();

      final node =
          await service.cache.getByUuid('20000000-0000-4000-8000-000000000001');
      expect(node!.displayName, 'Groceries');

      final db = await database.database;
      final ops = await db.query('relay_operations');
      // One row per envelope id; the echo replaces is_local=1 with 0.
      expect(ops, hasLength(2));
      expect(ops.map((r) => r['is_local']), everyElement(0));
    });

    test('does not apply envelopes to the cache when the push fails',
        () async {
      final service = await buildService(buildDio(failPush: true));
      await service.enqueue(
        type: 'create',
        nodeUuid: '20000000-0000-4000-8000-000000000001',
        contentAst: AstBuilder.parseInline('Shopping'),
        isPage: true,
      );

      final errors = await service.flush();

      expect(errors, isNotEmpty);
      expect(
          await service.cache.getByUuid('20000000-0000-4000-8000-000000000001'),
          isNull);

      final db = await database.database;
      // The row stays pending for a later retry.
      expect(await db.query('relay_outbox'), hasLength(1));
      expect(await db.query('relay_operations'), isEmpty);
    });

    test('archive maps to the v2 tombstone (object.delete permanent:false)',
        () async {
      final service = await buildService(buildDio());
      await service.enqueue(
        type: 'archive',
        nodeUuid: '20000000-0000-4000-8000-000000000001',
      );
      await service.flush();

      expect(pushed.single['opType'], 'object.delete');
      expect(pushed.single['payload'], {
        'objectId': '20000000-0000-4000-8000-000000000001',
        'permanent': false,
      });
    });

    test('legacy v1 outbox rows are quarantined, not wedged', () async {
      // A pre-port outbox row: v1 envelope without deviceId/timestamp and
      // with a v1 payload shape. Strict v2 parsing rejects it; flush must
      // quarantine the row and keep flushing the rest.
      final service = await buildService(buildDio());
      await service.enqueue(
        type: 'create',
        nodeUuid: '20000000-0000-4000-8000-000000000002',
        contentAst: AstBuilder.parseInline('Fresh'),
        isPage: true,
      );

      final db = await database.database;
      await db.insert('relay_outbox', {
        'envelope_json':
            '{"id":"0192a000-0000-7000-8000-000000000099","protocolVersion":1,'
            '"workspaceId":"10000000-0000-4000-8000-000000000001",'
            '"actorId":"40000000-0000-4000-8000-000000000001",'
            '"hlc":{"physical":1,"logical":0},'
            '"affectedNodeIds":["20000000-0000-4000-8000-000000000003"],'
            '"opType":"node.create",'
            '"payload":{"nodeId":"20000000-0000-4000-8000-000000000003","kind":"page"}}',
        'state': 'pending',
        'attempt_count': 0,
        'created_at': DateTime.now().millisecondsSinceEpoch,
      });

      final errors = await service.flush();

      expect(errors, isEmpty);
      // The valid row flushed; the legacy row was quarantined for inspection.
      expect(pushed, hasLength(1));
      expect(pushed.single['payload']['objectId'],
          '20000000-0000-4000-8000-000000000002');
      final rows = await db.query('relay_outbox');
      expect(rows, hasLength(1));
      expect(rows.single['state'], 'quarantined');
    });
  });
}
