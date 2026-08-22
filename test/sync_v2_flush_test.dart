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
            if (options.path == '/relay/batch') {
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
                  'saved_count': envelopes.length,
                  'saved_ids': envelopes.map((e) => e['id']).toList(),
                },
                statusCode: 200,
              ));
              return;
            }
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
              handler.resolve(Response(
                requestOptions: options,
                data: {
                  'envelopes': pushed,
                  'next_after_seq': pushed.isEmpty ? null : pushed.length,
                  'has_more': false,
                  'restore_epoch': 0,
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
        clientId: 'test-client',
      );
      await service.setWorkspaceId('ws-1');
      return service;
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
        nodeUuid: 'page-1',
        contentAst: AstBuilder.parseInline('Shopping'),
        isPage: true,
      );

      final errors = await service.flush();

      expect(errors, isEmpty);
      final node = await service.cache.getByUuid('page-1');
      expect(node, isNotNull);
      expect(node!.displayName, 'Shopping');
      expect(node.isPage, isTrue);

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
        nodeUuid: 'page-1',
        contentAst: AstBuilder.parseInline('Shopping'),
        isPage: true,
      );
      await service.flush();

      await service.enqueue(
        type: 'update_content',
        nodeUuid: 'page-1',
        contentAst: AstBuilder.parseInline('Groceries'),
      );
      await service.flush();

      final node = await service.cache.getByUuid('page-1');
      expect(node!.displayName, 'Groceries');
    });

    test('pull echo of own ops does not clobber or duplicate', () async {
      final service = await buildService(buildDio());
      await service.enqueue(
        type: 'create',
        nodeUuid: 'page-1',
        contentAst: AstBuilder.parseInline('Shopping'),
        isPage: true,
      );
      await service.enqueue(
        type: 'update_content',
        nodeUuid: 'page-1',
        contentAst: AstBuilder.parseInline('Groceries'),
      );
      await service.flush();
      expect((await service.cache.getByUuid('page-1'))!.displayName,
          'Groceries');

      // The server echoes both own ops back on the next pull. The create
      // echo must be a no-op (INSERT OR IGNORE parity) and the updateContent
      // echo is skipped by the content HLC guard, so the rename survives.
      await service.pull();

      final node = await service.cache.getByUuid('page-1');
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
        nodeUuid: 'page-1',
        contentAst: AstBuilder.parseInline('Shopping'),
        isPage: true,
      );

      final errors = await service.flush();

      expect(errors, isNotEmpty);
      expect(await service.cache.getByUuid('page-1'), isNull);

      final db = await database.database;
      // The row stays pending for a later retry.
      expect(await db.query('relay_outbox'), hasLength(1));
      expect(await db.query('relay_operations'), isEmpty);
    });
  });
}
