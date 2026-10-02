import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:notees/data/local/app_database.dart';
import 'package:notees/data/repositories/node_cache_repository.dart';
import 'package:notees/domain/models/relay/hlc.dart';
import 'package:notees/domain/models/relay/operation_envelope.dart';
import 'package:notees/domain/models/relay/operation_payloads.dart';
import 'package:notees/domain/models/relay/store_errors.dart';
import 'package:notees/domain/services/relay_appliers.dart';
import 'package:notees/domain/services/sync_v2_service.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

/// Lockstep for class ORDER (class.reorder, 2026-10-01, store schema v7
/// parity): display-only user ordering, LWW-by-arrival — the applier writes
/// the order list unconditionally (deterministic per op order, so replicas
/// converge) and the class_ids projection becomes: ordered members first
/// (per class_order, filtered to present members), then any unlisted
/// present members sorted by id (recomputeClassIds in the v2 store appliers).
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  sqfliteFfiInit();

  const pageId = '0192a000-0000-7000-8000-000000000201';
  const classA = '0192a000-0000-7000-8000-000000000202';
  const classB = '0192a000-0000-7000-8000-000000000203';
  const classC = '0192a000-0000-7000-8000-000000000204';

  group('class.reorder ordering', () {
    late AppDatabase database;
    late NodeCacheRepository cache;
    late RelayAppliers appliers;

    OperationEnvelope envelope({
      required String id,
      required String opType,
      required Map<String, dynamic> payload,
      required int physical,
      String actorId = '0192a000-0000-7000-8000-000000000002',
    }) =>
        OperationEnvelope(
          id: id,
          workspaceId: '0192a000-0000-7000-8000-000000000001',
          actorId: actorId,
          deviceId: 'test-device',
          hlc: Hlc(physical: physical, logical: 0),
          affectedNodeIds: [payload['objectId'] ?? payload['classId'] ?? ''],
          opType: opType,
          payload: payload,
          timestamp: '2026-10-01T12:00:00.000Z',
        );

    Future<void> apply(
      String id,
      String opType,
      Map<String, dynamic> payload,
      int physical,
    ) =>
        appliers.apply(envelope(
          id: id,
          opType: opType,
          payload: payload,
          physical: physical,
        ));

    Future<void> seedNodeWithClasses() async {
      await apply(
        '0192a000-0000-7000-8000-000000000401',
        'object.create',
        OperationPayloads.objectCreate(
          objectId: pageId,
          classIds: const [classA, classB, classC],
        ),
        100,
      );
    }

    setUp(() async {
      final ffiDb = await databaseFactoryFfi.openDatabase(
        ':memory:',
        options: OpenDatabaseOptions(singleInstance: false),
      );
      database = AppDatabase.fromDatabase(ffiDb);
      await database.initializeSchema();
      cache = NodeCacheRepository(database);
      appliers = RelayAppliers(cache);
      await seedNodeWithClasses();
    });

    tearDown(() async {
      await database.close();
      AppDatabase.reset();
    });

    test('no reorder: class_ids is the present members sorted by id', () async {
      expect((await cache.getByUuid(pageId))!.classesUuid,
          [classA, classB, classC]);
    });

    test('reorder puts ordered members first, unlisted ones sorted by id',
        () async {
      await apply(
        '0192a000-0000-7000-8000-000000000402',
        'class.reorder',
        OperationPayloads.classReorder(objectId: pageId, classIds: const [
          classC,
          classA,
        ]),
        200,
      );
      final node = await cache.getByUuid(pageId);
      // Ordered members first ([c, a] ∩ present), then the unlisted
      // present member sorted by id ([b]).
      expect(node!.classesUuid, [classC, classA, classB]);
      expect(await cache.classOrderOf(pageId), [classC, classA]);
    });

    test('reorder is LWW-by-arrival: the last applied write wins whole',
        () async {
      await apply(
        '0192a000-0000-7000-8000-000000000403',
        'class.reorder',
        OperationPayloads.classReorder(
            objectId: pageId, classIds: const [classB, classA]),
        200,
      );
      await apply(
        '0192a000-0000-7000-8000-000000000404',
        'class.reorder',
        OperationPayloads.classReorder(
            objectId: pageId, classIds: const [classA, classB]),
        210,
      );
      // The second write replaced the order list whole; the projection is
      // ordered members first, then the unlisted member sorted by id.
      expect((await cache.getByUuid(pageId))!.classesUuid,
          [classA, classB, classC]);
      expect(await cache.classOrderOf(pageId), [classA, classB]);

      // Reverse arrival order: the other write is the latest.
      await database.close();
      final ffiDb2 = await databaseFactoryFfi.openDatabase(
        ':memory:',
        options: OpenDatabaseOptions(singleInstance: false),
      );
      database = AppDatabase.fromDatabase(ffiDb2);
      await database.initializeSchema();
      cache = NodeCacheRepository(database);
      appliers = RelayAppliers(cache);
      await seedNodeWithClasses();
      await apply(
        '0192a000-0000-7000-8000-000000000405',
        'class.reorder',
        OperationPayloads.classReorder(
            objectId: pageId, classIds: const [classA, classB]),
        200,
      );
      await apply(
        '0192a000-0000-7000-8000-000000000406',
        'class.reorder',
        OperationPayloads.classReorder(
            objectId: pageId, classIds: const [classB, classA]),
        210,
      );
      expect((await cache.getByUuid(pageId))!.classesUuid,
          [classB, classA, classC]);
      expect(await cache.classOrderOf(pageId), [classB, classA]);
    });

    test('class.unassign after a reorder keeps the surviving order', () async {
      await apply(
        '0192a000-0000-7000-8000-000000000407',
        'class.reorder',
        OperationPayloads.classReorder(objectId: pageId, classIds: const [
          classC,
          classB,
          classA,
        ]),
        200,
      );
      await apply(
        '0192a000-0000-7000-8000-000000000408',
        'class.unassign',
        OperationPayloads.classUnassign(objectId: pageId, classId: classB),
        300,
      );
      final node = await cache.getByUuid(pageId);
      // Present: {a, c}; ordered ∩ present = [c, a]; unlisted = [].
      expect(node!.classesUuid, [classC, classA]);
      // The order list itself is untouched (LWW-by-arrival, display-only).
      expect(await cache.classOrderOf(pageId), [classC, classB, classA]);
    });

    test('re-assign after reorder+unassign lands back in the ordered slot',
        () async {
      await apply(
        '0192a000-0000-7000-8000-000000000409',
        'class.reorder',
        OperationPayloads.classReorder(objectId: pageId, classIds: const [
          classC,
          classB,
          classA,
        ]),
        200,
      );
      await apply(
        '0192a000-0000-7000-8000-00000000040a',
        'class.unassign',
        OperationPayloads.classUnassign(objectId: pageId, classId: classB),
        300,
      );
      // Re-assign b via the create carrier (add-wins, newer HLC): it lands
      // in its ordered slot again.
      await apply(
        '0192a000-0000-7000-8000-00000000040b',
        'object.create',
        OperationPayloads.objectCreate(
          objectId: pageId,
          classIds: const [classB],
        ),
        400,
      );
      expect((await cache.getByUuid(pageId))!.classesUuid,
          [classC, classB, classA]);
    });

    test('ordered ids that are not members are filtered out', () async {
      const phantom = '0192a000-0000-7000-8000-0000000002f9';
      await apply(
        '0192a000-0000-7000-8000-00000000040c',
        'class.reorder',
        OperationPayloads.classReorder(objectId: pageId, classIds: const [
          classC,
          phantom,
          classA,
        ]),
        200,
      );
      expect((await cache.getByUuid(pageId))!.classesUuid,
          [classC, classA, classB]);
    });

    test('reorder on a missing node throws NodeNotFoundError', () {
      expect(
        () async => apply(
          '0192a000-0000-7000-8000-00000000040d',
          'class.reorder',
          OperationPayloads.classReorder(
            objectId: '0192a000-0000-7000-8000-000000000499',
            classIds: const [classA],
          ),
          200,
        ),
        throwsA(isA<NodeNotFoundError>()),
      );
    });

    test('replicas applying membership/order ops in different orders '
        'converge to the same class_ids and class_order', () async {
      // Ops: create(+[a,b,c]), reorder([c,b,a]), unassign(b) — applied in
      // both orders on two fresh stores. Reorder and unassign touch
      // different state (order list vs membership pair) and the projection
      // is a pure function of both, so the delivery order does not matter.
      Future<({List<String> classIds, List<String> classOrder})> run(
        bool reorderFirst,
      ) async {
        final ffiDb = await databaseFactoryFfi.openDatabase(
          ':memory:',
          options: OpenDatabaseOptions(singleInstance: false),
        );
        final db = AppDatabase.fromDatabase(ffiDb);
        await db.initializeSchema();
        final repo = NodeCacheRepository(db);
        final ops = RelayAppliers(repo);
        Future<void> step(
          String id,
          String opType,
          Map<String, dynamic> payload,
          int physical,
        ) =>
            ops.apply(envelope(
              id: id,
              opType: opType,
              payload: payload,
              physical: physical,
            ));

        await step(
          '0192a000-0000-7000-8000-000000000501',
          'object.create',
          OperationPayloads.objectCreate(
            objectId: pageId,
              classIds: const [classA, classB, classC],
          ),
          100,
        );
        final reorder = (
          '0192a000-0000-7000-8000-000000000502',
          'class.reorder',
          OperationPayloads.classReorder(objectId: pageId, classIds: const [
            classC,
            classB,
            classA,
          ]),
          200,
        );
        final unassign = (
          '0192a000-0000-7000-8000-000000000503',
          'class.unassign',
          OperationPayloads.classUnassign(objectId: pageId, classId: classB),
          300,
        );
        for (final op in reorderFirst ? [reorder, unassign] : [unassign, reorder]) {
          await step(op.$1, op.$2, op.$3, op.$4);
        }
        final node = await repo.getByUuid(pageId);
        final order = await repo.classOrderOf(pageId);
        final result = (classIds: node!.classesUuid, classOrder: order);
        await db.close();
        AppDatabase.reset();
        return result;
      }

      final forward = await run(true);
      final backward = await run(false);
      expect(forward.classIds, [classC, classA]);
      expect(backward.classIds, forward.classIds);
      expect(backward.classOrder, forward.classOrder);
    });
  });

  group('class.reorder client convenience', () {
    late AppDatabase database;

    setUp(() async {
      final ffiDb = await databaseFactoryFfi.openDatabase(
        ':memory:',
        options: OpenDatabaseOptions(singleInstance: false),
      );
      database = AppDatabase.fromDatabase(ffiDb);
      await database.initializeSchema();
    });

    tearDown(() async {
      await database.close();
      AppDatabase.reset();
    });

    test('SyncV2Service.reorderClasses emits class.reorder and applies the '
        'order locally', () async {
      final service = SyncV2Service(
        database: database,
        dio: Dio(),
        clientId: '40000000-0000-4000-8000-000000000001',
        serverless: true,
      );
      await service.setWorkspaceId('10000000-0000-4000-8000-000000000001');
      await service.emitLocal(
        opType: 'object.create',
        payload: OperationPayloads.objectCreate(
          objectId: pageId,
          classIds: const [classA, classB, classC],
        ),
        affectedNodeIds: [pageId],
      );

      final envelope = await service.reorderClasses(
        objectId: pageId,
        classIds: const [classC, classA],
      );
      expect(envelope.opType, 'class.reorder');
      expect(envelope.payload, {
        'objectId': pageId,
        'classIds': [classC, classA],
      });

      final node = await service.cache.getByUuid(pageId);
      expect(node!.classesUuid, [classC, classA, classB]);
      expect(await service.cache.classOrderOf(pageId), [classC, classA]);
    });
  });
}
