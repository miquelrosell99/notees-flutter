import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:notees/data/local/app_database.dart';
import 'package:notees/data/repositories/node_cache_repository.dart';
import 'package:notees/domain/models/relay/hlc.dart';
import 'package:notees/domain/models/relay/operation_envelope.dart';
import 'package:notees/domain/models/relay/operation_payloads.dart';
import 'package:notees/domain/models/relay/store_errors.dart';
import 'package:notees/domain/services/relay_appliers.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

/// Lockstep for `class.unassign` (SCHEMA.md "Class properties"): the
/// membership OR-Set remove. Replays the canonical `class-unassign.json`
/// fixture through the appliers with intermediate reads through the
/// effective-properties model:
///
///  - prefix 7 (node created with Task, bindings effort=xs / impact=xl,
///    impact authored "authored"): effort derives "xs", impact reads
///    "authored" (shadows the "xl" default), both boundBy Task;
///  - prefix 8 (+ class.unassign): class_ids recomputed empty — the derived
///    "effort" default stops reading (nothing was ever stored), the authored
///    impact survives marked unbound (boundBy null);
///  - full 9 (+ re-issued object.create re-assigning Task with a newer HLC):
///    "effort" derives again, impact reads authored boundBy Task.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  sqfliteFfiInit();

  const effortSchema = '0192a000-0000-7000-8000-000000000410';
  const impactSchema = '0192a000-0000-7000-8000-000000000411';
  const taskClass = '0192a000-0000-7000-8000-000000000412';
  const nodeId = '0192a000-0000-7000-8000-000000000413';

  List<OperationEnvelope> fixtureEnvelopes() =>
      ((jsonDecode(File('test/fixtures/v2/class-unassign.json')
                  .readAsStringSync())
              as Map<String, dynamic>)['envelopes'] as List<dynamic>)
          .cast<Map<String, dynamic>>()
          .map(OperationEnvelope.fromJson)
          .toList();

  group('class.unassign fixture acceptance', () {
    late AppDatabase database;
    late NodeCacheRepository cache;
    late RelayAppliers appliers;

    setUp(() async {
      final ffiDb = await databaseFactoryFfi.openDatabase(
        ':memory:',
        options: OpenDatabaseOptions(singleInstance: false),
      );
      database = AppDatabase.fromDatabase(ffiDb);
      await database.initializeSchema();
      cache = NodeCacheRepository(database);
      appliers = RelayAppliers(cache);
    });

    tearDown(() async {
      await database.close();
      AppDatabase.reset();
    });

    Future<void> replayPrefix(int count) async {
      final envelopes = fixtureEnvelopes();
      expect(envelopes, hasLength(9));
      for (var i = 0; i < count; i++) {
        await appliers.apply(envelopes[i]);
      }
    }

    Future<List<EffectiveProperty>> effective() =>
        cache.getEffectiveProperties(nodeId);

    test('prefix 7: derived default + authored value bound by Task', () async {
      await replayPrefix(7);
      final rows = await effective();
      final effort = rows.singleWhere((r) => r.propertySchemaId == effortSchema);
      final impact = rows.singleWhere((r) => r.propertySchemaId == impactSchema);
      expect(effort.value, 'xs');
      expect(effort.source, 'default');
      expect(effort.boundBy, taskClass);
      expect(impact.value, 'authored'); // shadows the "xl" default
      expect(impact.source, 'authored');
      expect(impact.boundBy, taskClass);
    });

    test('prefix 8: unassign drops the derived default; authored survives '
        'unbound', () async {
      await replayPrefix(8);

      final node = await cache.getByUuid(nodeId);
      expect(node!.classesUuid, isEmpty); // class_ids recomputed empty

      final rows = await effective();
      expect(
        rows.where((r) => r.propertySchemaId == effortSchema),
        isEmpty,
        reason: 'the derived default stops reading — nothing was ever stored',
      );
      final impact = rows.singleWhere((r) => r.propertySchemaId == impactSchema);
      expect(impact.value, 'authored'); // authored always survives
      expect(impact.source, 'authored');
      expect(impact.boundBy, isNull); // unbound-by-current-classes, visible
    });

    test('full 9: re-assign restores the derived default and the binding',
        () async {
      await replayPrefix(9);
      final rows = await effective();
      final effort = rows.singleWhere((r) => r.propertySchemaId == effortSchema);
      final impact = rows.singleWhere((r) => r.propertySchemaId == impactSchema);
      expect(effort.value, 'xs'); // derived again
      expect(effort.source, 'default');
      expect(effort.boundBy, taskClass);
      expect(impact.value, 'authored');
      expect(impact.boundBy, taskClass); // bound again
    });
  });

  group('class.unassign membership gating', () {
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
          affectedNodeIds: [payload['objectId'] ?? ''],
          opType: opType,
          payload: payload,
          timestamp: '2026-09-24T12:00:00.000Z',
        );

    Future<void> createTaskClass() async {
      await appliers.apply(envelope(
        id: '0192a000-0000-7000-8000-000000000501',
        opType: 'class.create',
        payload: OperationPayloads.classCreate(classId: taskClass, name: 'Task'),
        physical: 1,
      ));
    }

    Future<void> createNodeWithTask({required int physical}) async {
      await appliers.apply(envelope(
        id: '0192a000-0000-7000-8000-000000000502',
        opType: 'object.create',
        payload: OperationPayloads.objectCreate(
          objectId: nodeId,
          classIds: const [taskClass],
        ),
        physical: physical,
      ));
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
      await createTaskClass();
    });

    tearDown(() async {
      await database.close();
      AppDatabase.reset();
    });

    Future<int> membershipPresent() async {
      final db = await database.database;
      final rows = await db.rawQuery(
        'SELECT present FROM class_member_set WHERE node_uuid = ? AND class_id = ?',
        [nodeId, taskClass],
      );
      return rows.single['present'] as int;
    }

    test('a stale remove loses to a newer add', () async {
      await createNodeWithTask(physical: 100);
      expect(await membershipPresent(), 1);

      await appliers.apply(envelope(
        id: '0192a000-0000-7000-8000-000000000503',
        opType: 'class.unassign',
        payload: OperationPayloads.classUnassign(
          objectId: nodeId,
          classId: taskClass,
        ),
        physical: 90, // older than the add
      ));
      expect(await membershipPresent(), 1, reason: 'remove gated out');
      expect((await cache.getByUuid(nodeId))!.classesUuid, [taskClass]);
    });

    test('exact-HLC tie: the add wins in either delivery order', () async {
      // Order A: add first, then the remove at the same HLC → add wins.
      await createNodeWithTask(physical: 100);
      await appliers.apply(envelope(
        id: '0192a000-0000-7000-8000-000000000504',
        opType: 'class.unassign',
        payload: OperationPayloads.classUnassign(
          objectId: nodeId,
          classId: taskClass,
        ),
        physical: 100, // exact tie: remove comparator is strictly-greater
      ));
      expect(await membershipPresent(), 1);
      expect((await cache.getByUuid(nodeId))!.classesUuid, [taskClass]);
    });

    test('exact-HLC tie, remove first: the later add still wins', () async {
      // The node exists without the class; remove lands at HLC 100, then a
      // re-issued create adds at the SAME HLC → add wins (seed comparator
      // >= on the actor tiebreak).
      await appliers.apply(envelope(
        id: '0192a000-0000-7000-8000-000000000505',
        opType: 'object.create',
        payload: OperationPayloads.objectCreate(
          objectId: nodeId,
        ),
        physical: 90,
      ));
      await appliers.apply(envelope(
        id: '0192a000-0000-7000-8000-000000000506',
        opType: 'class.unassign',
        payload: OperationPayloads.classUnassign(
          objectId: nodeId,
          classId: taskClass,
        ),
        physical: 100,
      ));
      await appliers.apply(envelope(
        id: '0192a000-0000-7000-8000-000000000507',
        opType: 'object.create',
        payload: OperationPayloads.objectCreate(
          objectId: nodeId,
          classIds: const [taskClass],
        ),
        physical: 100, // exact tie with the remove
      ));
      expect(await membershipPresent(), 1, reason: 'add wins the tie');
      expect((await cache.getByUuid(nodeId))!.classesUuid, [taskClass]);
    });

    test('a newer remove wins and recompute empties class_ids', () async {
      await createNodeWithTask(physical: 100);
      await appliers.apply(envelope(
        id: '0192a000-0000-7000-8000-000000000508',
        opType: 'class.unassign',
        payload: OperationPayloads.classUnassign(
          objectId: nodeId,
          classId: taskClass,
        ),
        physical: 110,
      ));
      expect(await membershipPresent(), 0);
      expect((await cache.getByUuid(nodeId))!.classesUuid, isEmpty);
    });

    test('unassign on a missing node throws NodeNotFoundError', () async {
      expect(
        () async => appliers.apply(envelope(
          id: '0192a000-0000-7000-8000-000000000509',
          opType: 'class.unassign',
          payload: OperationPayloads.classUnassign(
            objectId: '0192a000-0000-7000-8000-000000000499',
            classId: taskClass,
          ),
          physical: 1,
        )),
        throwsA(isA<NodeNotFoundError>()),
      );
    });
  });

  group('class.unassign payload factory', () {
    const objectId = '0192a000-0000-7000-8000-000000000413';
    const classId = '0192a000-0000-7000-8000-000000000412';

    test('validates and round-trips', () {
      final payload =
          OperationPayloads.classUnassign(objectId: objectId, classId: classId);
      expect(payload, {'objectId': objectId, 'classId': classId});
      expect(
        () => OperationPayloads.validatePayload('class.unassign', payload),
        returnsNormally,
      );
      expect(OperationPayloads.isKnownOpType('class.unassign'), isTrue);
    });

    test('rejects bad uuids and extra keys', () {
      expect(
        () => OperationPayloads.classUnassign(
            objectId: 'nope', classId: classId),
        throwsFormatException,
      );
      expect(
        () => OperationPayloads.validatePayload('class.unassign', {
          'objectId': objectId,
          'classId': classId,
          'extra': 1,
        }),
        throwsFormatException,
      );
    });
  });
}
