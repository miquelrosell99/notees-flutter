import 'dart:convert';

import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:notees/data/local/app_database.dart';
import 'package:notees/data/repositories/node_cache_repository.dart';
import 'package:notees/domain/models/editor_block_snapshot.dart';
import 'package:notees/domain/services/editor_save_service.dart';
import 'package:notees/domain/services/sync_v2_service.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

/// Editor save path on the content grammar: titles ride object.update
/// contentAst (title-is-content — the protocol has no scalar name slot),
/// content rides contentAst, and block moves pass the previous sibling as
/// afterId (the sibling anchor).
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  sqfliteFfiInit();

  const workspaceId = '10000000-0000-4000-8000-000000000001';
  const pageUuid = '20000000-0000-4000-8000-000000000001';
  const blockA = '20000000-0000-4000-8000-000000000002';
  const blockB = '20000000-0000-4000-8000-000000000003';
  const blockC = '20000000-0000-4000-8000-000000000004';

  group('EditorSaveService (content grammar)', () {
    late AppDatabase database;
    late List<Map<String, dynamic>> pushed;

    Dio buildDio() {
      final dio = Dio();
      dio.interceptors.add(
        InterceptorsWrapper(
          onRequest: (options, handler) {
            if (options.path == '/relay/v2/batch') {
              final body = options.data as Map<String, dynamic>;
              pushed.addAll(
                (body['envelopes'] as List<dynamic>)
                    .cast<Map<String, dynamic>>(),
              );
              handler.resolve(Response(
                requestOptions: options,
                data: {
                  'savedCount': pushed.length,
                  'savedIds': pushed.map((e) => e['id']).toList(),
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
            handler.resolve(Response(
              requestOptions: options,
              data: const {
                'envelopes': <Map<String, dynamic>>[],
                'nextAfterSeq': null,
                'hasMore': false,
                'restoreEpoch': 0,
                'totalRemaining': 0,
              },
              statusCode: 200,
            ));
          },
        ),
      );
      return dio;
    }

    setUp(() async {
      final ffiDb = await databaseFactoryFfi.openDatabase(
        ':memory:',
        options: OpenDatabaseOptions(singleInstance: false),
      );
      database = AppDatabase.fromDatabase(ffiDb);
      await database.initializeSchema();
      pushed = [];
      final cache = NodeCacheRepository(database);
      await cache.upsertClass(uuid: 'class-1', name: 'Class');
      await cache.upsertPropertySchema(
        PropertySchemaRow(uuid: 'schema-1', workspaceId: workspaceId, name: 'P'),
      );
    });

    tearDown(() async {
      await database.close();
      AppDatabase.reset();
    });

    Future<SyncV2Service> buildService() async {
      final syncService = SyncV2Service(
        database: database,
        dio: buildDio(),
        clientId: '40000000-0000-4000-8000-000000000001',
      );
      await syncService.setWorkspaceId(workspaceId);
      // The page + blocks exist locally (created in an earlier sync round):
      // title updates are object.update on an existing row.
      for (final uuid in [pageUuid, blockA, blockB, blockC]) {
        await syncService.enqueue(
          type: 'create',
          nodeUuid: uuid,
          contentAst: const [
            {'type': 'text', 'text': 'seed'},
          ],
          isPage: uuid == pageUuid,
        );
      }
      await syncService.flush();
      pushed.clear();
      return syncService;
    }

    test('title rides object.update contentAst, content rides contentAst',
        () async {
      final syncService = await buildService();
      final service = EditorSaveService(syncService: syncService);

      await service.savePage(
        pageUuid: pageUuid,
        title: 'Shopping List',
        roots: [
          EditorBlockSnapshot(uuid: blockA, text: 'Apples'),
          EditorBlockSnapshot(uuid: blockB, text: '**Milk**'),
        ],
        deletedUuids: const [],
      );

      final ops = [for (final e in pushed) e['opType'] as String];
      // One title op + two content ops (no deletes, no moves: parents match).
      expect(ops, [
        'object.update',
        'object.update',
        'object.update',
      ]);

      final title = pushed.first;
      expect(title['payload']['objectId'], pageUuid);
      // Title-is-content: the rename is a contentAst replacement; the wire
      // has no scalar name field.
      expect(title['payload']['contentAst'], [
        {'type': 'text', 'text': 'Shopping List'},
      ]);
      expect(title['payload'].containsKey('name'), isFalse);

      final milk = pushed.last;
      expect(milk['payload']['contentAst'], [
        {'type': 'text', 'text': 'Milk', 'marks': ['bold']},
      ]);
      expect(milk['payload'].containsKey('name'), isFalse);
    });

    test('block moves pass the previous sibling as afterId', () async {
      final syncService = await buildService();
      final service = EditorSaveService(syncService: syncService);

      // B changes parent and lands after A under the page: afterId = A.
      await service.savePage(
        pageUuid: pageUuid,
        title: 'Reorg',
        roots: [
          EditorBlockSnapshot(uuid: blockA, text: 'A'),
          EditorBlockSnapshot(
            uuid: blockB,
            text: 'B',
            parentUuid: '20000000-0000-4000-8000-000000000099',
          ),
        ],
        deletedUuids: const [blockC],
      );

      final moves = pushed.where((e) => e['opType'] == 'object.move').toList();
      expect(moves, hasLength(1));
      expect(moves.single['payload'], {
        'objectId': blockB,
        'parentId': pageUuid,
        'afterId': blockA,
      });
      expect(jsonEncode(moves.single['payload']), contains(blockA));
    });
  });
}
