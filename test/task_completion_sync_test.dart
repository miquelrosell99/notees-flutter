import 'dart:convert';

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
                  'saved_count': 1,
                  'saved_ids': ['id'],
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
        clientId: 'test-client',
      );
      await syncService.setWorkspaceId('ws-1');
    });

    tearDown(() async {
      await database.close();
      AppDatabase.reset();
    });

    test('record completion intent maps to task.recordCompletion envelope', () async {
      await syncService.enqueue(
        type: 'task_record_completion',
        nodeUuid: 'task-1',
        completionId: 'completion-1',
        completionStatus: 'done',
        completedAt: '2026-08-09T12:00:00.000Z',
        scheduledDate: '2026-08-09',
        deadlineDate: '2026-08-10',
      );
      await syncService.flush();

      final db = await database.database;
      final rows = await db.query(
        'relay_operations',
        where: 'op_type = ?',
        whereArgs: const ['task.recordCompletion'],
      );

      expect(rows, hasLength(1));
      final payload = jsonDecode(rows.first['payload'] as String) as Map<String, dynamic>;
      expect(payload['nodeId'], 'task-1');
      expect(payload['completionId'], 'completion-1');
      expect(payload['completedAt'], '2026-08-09T12:00:00.000Z');
      expect(payload['scheduledDate'], '2026-08-09');
      expect(payload['deadlineDate'], '2026-08-10');
      expect(payload['status'], 'done');
    });

    test('delete completion intent maps to task.deleteCompletion envelope', () async {
      await syncService.enqueue(
        type: 'task_delete_completion',
        nodeUuid: 'task-1',
        completionId: 'completion-1',
      );
      await syncService.flush();

      final db = await database.database;
      final rows = await db.query(
        'relay_operations',
        where: 'op_type = ?',
        whereArgs: const ['task.deleteCompletion'],
      );

      expect(rows, hasLength(1));
      final payload = jsonDecode(rows.first['payload'] as String) as Map<String, dynamic>;
      expect(payload['nodeId'], 'task-1');
      expect(payload['completionId'], 'completion-1');
    });

    test('record completion generates ids and timestamps when omitted', () async {
      await syncService.enqueue(
        type: 'task_record_completion',
        nodeUuid: 'task-1',
      );
      await syncService.flush();

      final db = await database.database;
      final rows = await db.query(
        'relay_operations',
        where: 'op_type = ?',
        whereArgs: const ['task.recordCompletion'],
      );

      expect(rows, hasLength(1));
      final payload = jsonDecode(rows.first['payload'] as String) as Map<String, dynamic>;
      expect(payload['nodeId'], 'task-1');
      expect(payload['completionId'], isNotNull);
      expect(payload['completionId'], isNotEmpty);
      expect(payload['completedAt'], isNotNull);
      expect(payload['completedAt'], isNotEmpty);
      expect(payload['status'], 'done');
    });

    test('NodeRepository records and deletes task completions locally', () async {
      final repo = NodeRepository(dio: dio, syncService: syncService);

      await repo.recordTaskCompletion('task-1', status: 'done');
      var completionId = await repo.getMostRecentTaskCompletionId('task-1');
      expect(completionId, isNotNull);
      expect(completionId, isNotEmpty);

      await repo.deleteTaskCompletion('task-1', completionId!);
      completionId = await repo.getMostRecentTaskCompletionId('task-1');
      expect(completionId, isNull);

      final db = await database.database;
      final rows = await db.query(
        'relay_operations',
        where: 'op_type IN (?, ?)',
        whereArgs: const ['task.recordCompletion', 'task.deleteCompletion'],
        orderBy: 'timestamp ASC',
      );

      expect(rows, hasLength(2));
      final recordPayload = jsonDecode(rows.first['payload'] as String) as Map<String, dynamic>;
      final deletePayload = jsonDecode(rows.last['payload'] as String) as Map<String, dynamic>;
      expect(recordPayload['status'], 'done');
      expect(deletePayload['completionId'], recordPayload['completionId']);
    });

    test('NodeRepository reads scheduled and deadline dates from cached task', () async {
      final repo = NodeRepository(dio: dio, syncService: syncService);

      await syncService.cache.upsert(
        TestNodeBuilder.task(
          uuid: 'task-1',
          scheduledDate: '2026-08-09',
          deadlineDate: '2026-08-10',
        ),
      );

      await repo.recordTaskCompletion('task-1', status: 'done');

      final db = await database.database;
      final rows = await db.query(
        'relay_operations',
        where: 'op_type = ?',
        whereArgs: const ['task.recordCompletion'],
      );

      expect(rows, hasLength(1));
      final payload = jsonDecode(rows.first['payload'] as String) as Map<String, dynamic>;
      expect(payload['scheduledDate'], '2026-08-09');
      expect(payload['deadlineDate'], '2026-08-10');
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
