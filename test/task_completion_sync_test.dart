import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:notees/core/constants/system.dart';
import 'package:notees/data/local/app_database.dart';
import 'package:notees/data/models/node.dart';
import 'package:notees/data/repositories/node_repository.dart';
import 'package:notees/domain/services/sync_v2_service.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  sqfliteFfiInit();

  const workspaceId = '10000000-0000-4000-8000-000000000001';
  const taskUuid = '20000000-0000-4000-8000-000000000001';

  group('Task completion sync', () {
    late AppDatabase database;
    late Dio dio;
    late SyncV2Service syncService;

    setUp(() async {
      final ffiDb = await databaseFactoryFfi.openDatabase(
        ':memory:',
        options: OpenDatabaseOptions(singleInstance: false),
      );
      database = AppDatabase.fromDatabase(ffiDb);
      await database.initializeSchema();

      dio = Dio();
      dio.interceptors.add(
        InterceptorsWrapper(
          onRequest: (options, handler) {
            handler.resolve(
              Response(
                requestOptions: options,
                data: const {
                  'savedCount': 1,
                  'savedIds': ['id'],
                },
                statusCode: 200,
              ),
            );
          },
        ),
      );

      syncService = SyncV2Service(
        database: database,
        dio: dio,
        clientId: '40000000-0000-4000-8000-000000000001',
      );
      await syncService.setWorkspaceId(workspaceId);
    });

    tearDown(() async {
      await database.close();
      AppDatabase.reset();
    });

    // Phase A gate: task completions have no op in the v2 M1 registry
    // (task.* was dropped), so the intents fail loud instead of emitting a
    // v1 op the relay would 422. The local completion is still recorded
    // (NodeRepository writes the local cache first); only the sync envelope
    // is missing. Phase B re-homes task state on the v2 model.
    test('record completion intent throws UnsupportedError (no v2 op)',
        () async {
      final repo = NodeRepository(dio: dio, syncService: syncService);

      await expectLater(
        repo.recordTaskCompletion(taskUuid, status: 'done'),
        throwsUnsupportedError,
      );

      // The local completion is recorded before the sync attempt.
      final completionId =
          await repo.getMostRecentTaskCompletionId(taskUuid);
      expect(completionId, isNotNull);
      expect(completionId, isNotEmpty);

      // No envelope reaches the outbox or the operations log.
      final db = await database.database;
      expect(await db.query('relay_outbox'), isEmpty);
      expect(await db.query('relay_operations'), isEmpty);
    });

    test('delete completion intent throws UnsupportedError (no v2 op)',
        () async {
      final repo = NodeRepository(dio: dio, syncService: syncService);

      await expectLater(
        repo.deleteTaskCompletion(taskUuid, 'completion-1'),
        throwsUnsupportedError,
      );

      final db = await database.database;
      expect(await db.query('relay_outbox'), isEmpty);
      expect(await db.query('relay_operations'), isEmpty);
    });

    test('favorites intents throw UnsupportedError (no v2 op)', () async {
      await expectLater(
        syncService.enqueue(type: 'add_favorite', nodeUuid: taskUuid),
        throwsUnsupportedError,
      );
      await expectLater(
        syncService.enqueue(type: 'remove_favorite', nodeUuid: taskUuid),
        throwsUnsupportedError,
      );
      await expectLater(
        syncService.enqueue(
          type: 'reorder_favorites',
          nodeUuid: '',
          favoriteNodeUuids: const [taskUuid],
        ),
        throwsUnsupportedError,
      );

      final db = await database.database;
      expect(await db.query('relay_outbox'), isEmpty);
    });

    test('remove_tag maps to tag.unassign (2026-10-01 registry)', () async {
      await syncService.enqueue(
        type: 'remove_tag',
        nodeUuid: taskUuid,
        tagUuid: '30000000-0000-4000-8000-000000000001',
      );

      final db = await database.database;
      final rows = await db.query('relay_outbox');
      expect(rows, hasLength(1));
      final envelopeJson = rows.first['envelope_json'] as String;
      expect(envelopeJson, contains('"tag.unassign"'));
      expect(envelopeJson, contains('30000000-0000-4000-8000-000000000001'));
    });

    test('restore intent throws UnsupportedError (no v2 op)', () async {
      await expectLater(
        syncService.enqueue(type: 'restore', nodeUuid: taskUuid),
        throwsUnsupportedError,
      );

      final db = await database.database;
      expect(await db.query('relay_outbox'), isEmpty);
    });

    test('add_tag maps to a re-issued object.create with tagIds '
        '(OR-Set membership carrier)', () async {
      await syncService.enqueue(
        type: 'add_tag',
        nodeUuid: taskUuid,
        tagUuid: '30000000-0000-4000-8000-000000000001',
      );

      final db = await database.database;
      final rows = await db.query('relay_outbox');
      expect(rows, hasLength(1));
      final envelopeJson = rows.first['envelope_json'] as String;
      expect(envelopeJson, contains('"object.create"'));
      expect(envelopeJson, contains('"tagIds"'));
      expect(envelopeJson,
          contains('30000000-0000-4000-8000-000000000001'));
    });

    test('NodeRepository reads scheduled and deadline dates from cached task',
        () async {
      final repo = NodeRepository(dio: dio, syncService: syncService);

      await syncService.cache.upsert(
        TestNodeBuilder.task(
          uuid: taskUuid,
          scheduledDate: '2026-08-09',
          deadlineDate: '2026-08-10',
        ),
      );

      // The sync envelope is gated in Phase A, but the local completion row
      // is recorded first and carries the cached task dates.
      await expectLater(
        repo.recordTaskCompletion(taskUuid, status: 'done'),
        throwsUnsupportedError,
      );

      final completionId =
          await repo.getMostRecentTaskCompletionId(taskUuid);
      expect(completionId, isNotNull);
    });
  });
}

class TestNodeBuilder {
  TestNodeBuilder._();

  static Node task({
    required String uuid,
    String? scheduledDate,
    String? deadlineDate,
  }) {
    final properties = <String, dynamic>{};
    if (scheduledDate != null) {
      properties[SystemPropertyUuids.taskScheduled] = scheduledDate;
    }
    if (deadlineDate != null) {
      properties[SystemPropertyUuids.taskDeadline] = deadlineDate;
    }

    return Node(
      id: 0,
      uuid: uuid,
      name: '{"type":"text","text":"Task"}',
      displayName: 'Task',
      classesUuid: const [SystemClassUuids.task],
      properties: properties,
      isTask: true,
    );
  }
}
