import 'dart:convert';

import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:notees/data/local/app_database.dart';
import 'package:notees/data/repositories/node_cache_repository.dart';
import 'package:notees/domain/models/relay/hlc.dart';
import 'package:notees/domain/models/relay/operation_envelope.dart';
import 'package:notees/domain/models/relay/operation_payloads.dart';
import 'package:notees/domain/services/relay_appliers.dart';
import 'package:notees/domain/services/sync_v2_service.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

/// Acceptance for the §34.65 default-mirror sweep port (web
/// `unassignClass` parity): removing a class sweeps the node's authored
/// values that merely MIRROR the departing class's binding defaults —
/// explicit property.unset envelopes enqueued BEFORE the class.unassign so
/// every client converges; values differing from a default survive, marked
/// unbound; bindings without a default never sweep.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  sqfliteFfiInit();

  const workspaceId = '10000000-0000-4000-8000-000000000001';
  const actor = '20000000-0000-4000-8000-000000000002';
  const node = '20000000-0000-4000-8000-000000000010';
  const klass = '20000000-0000-4000-8000-000000000020';
  const statusSchema = '20000000-0000-4000-8000-000000000030';
  const notesSchema = '20000000-0000-4000-8000-000000000031';
  const elementUuid = '20000000-0000-4000-8000-0000000000e1';

  late AppDatabase database;
  late NodeCacheRepository cache;
  late RelayAppliers appliers;
  late SyncV2Service service;

  var clock = 0;

  OperationEnvelope env(String opType, Map<String, dynamic> payload) {
    clock += 1;
    return OperationEnvelope(
      id: '20000000-0000-4000-8000-${(1000 + clock).toString().padLeft(12, '0')}',
      workspaceId: workspaceId,
      actorId: actor,
      deviceId: 't',
      hlc: Hlc(physical: clock, logical: 0),
      affectedNodeIds: [node],
      opType: opType,
      payload: payload,
      timestamp: '2026-10-04T12:00:00.000Z',
    );
  }

  Future<void> apply(OperationEnvelope envelope) => appliers.apply(envelope);

  /// Seeds: the status schema (select, multi) bound by [klass] with
  /// default "opt-pending"; the notes schema (text) bound WITHOUT a
  /// default; [node] carrying [klass] with three authored values — the
  /// mirror at the positional slot, the mirror as a PG5 element add, and a
  /// differing notes value.
  Future<void> seed() async {
    await apply(env(
      'propertySchema.create',
      OperationPayloads.propertySchemaCreate(
        propertySchemaId: statusSchema,
        name: 'status',
        type: 'select',
        multi: true,
        options: const [
          {'id': 'opt-pending', 'label': 'Pending'},
          {'id': 'opt-done', 'label': 'Done'},
        ],
      ),
    ));
    await apply(env(
      'propertySchema.create',
      OperationPayloads.propertySchemaCreate(
        propertySchemaId: notesSchema,
        name: 'notes',
        type: 'text',
      ),
    ));
    await apply(env(
      'class.create',
      OperationPayloads.classCreate(classId: klass, name: 'taskish'),
    ));
    await apply(env(
      'class.property.set',
      OperationPayloads.classPropertySet(
        classId: klass,
        propertySchemaId: statusSchema,
        sequence: 0,
        defaultValue: 'opt-pending',
      ),
    ));
    await apply(env(
      'class.property.set',
      OperationPayloads.classPropertySet(
        classId: klass,
        propertySchemaId: notesSchema,
        sequence: 1,
      ),
    ));
    await apply(env(
      'object.create',
      OperationPayloads.objectCreate(
        objectId: node,
        classIds: [klass],
        contentAst: const [],
      ),
    ));
    await apply(env(
      'property.set',
      OperationPayloads.propertySet(
        objectId: node,
        propertySchemaId: statusSchema,
        value: 'opt-pending', // mirrors the default
      ),
    ));
    await apply(env(
      'property.set',
      OperationPayloads.propertySet(
        objectId: node,
        propertySchemaId: statusSchema,
        value: 'opt-pending', // mirrors the default, PG5 element addressing
        idx: 1,
        elementId: elementUuid,
      ),
    ));
    await apply(env(
      'property.set',
      OperationPayloads.propertySet(
        objectId: node,
        propertySchemaId: notesSchema,
        value: 'user wrote this', // no default on this binding
      ),
    ));
  }

  Future<List<Map<String, dynamic>>> outboxRows() async {
    final db = await database.database;
    return db.rawQuery(
      "SELECT envelope_json FROM relay_outbox WHERE state = 'pending' "
      'ORDER BY created_at ASC, id ASC',
    );
  }

  setUp(() async {
    clock = 0;
    final ffiDb = await databaseFactoryFfi.openDatabase(
      ':memory:',
      options: OpenDatabaseOptions(singleInstance: false),
    );
    database = AppDatabase.fromDatabase(ffiDb);
    await database.initializeSchema();
    cache = NodeCacheRepository(database);
    appliers = RelayAppliers(cache);
    service = SyncV2Service(
      database: database,
      dio: Dio(),
      clientId: '40000000-0000-4000-8000-000000000001',
      serverless: true,
    );
    await service.setWorkspaceId(workspaceId);
  });

  tearDown(() async {
    await database.close();
    AppDatabase.reset();
  });

  test('unassigning sweeps mirrors (by idx and by element id) before the '
      'membership remove; differing values survive unbound', () async {
    await seed();

    await service.enqueue(
      type: 'remove_class',
      nodeUuid: node,
      classUuid: klass,
    );

    // Outbox order: the two sweep unsets first, the class.unassign last.
    final pending = await outboxRows();
    expect(pending, hasLength(3));
    final unsets = pending
        .take(2)
        .map((r) =>
            jsonDecode(r['envelope_json'] as String) as Map<String, dynamic>)
        .toList();
    final unassign = jsonDecode(pending[2]['envelope_json'] as String)
        as Map<String, dynamic>;
    expect(unsets.every((e) => e['opType'] == 'property.unset'), isTrue);
    expect(unassign['opType'], 'class.unassign');
    // The positional composite row (node:schema:0) is not uuid-shaped —
    // it unsets by idx; the PG5 element unsets by element id.
    expect(unsets[0]['payload'], {
      'objectId': node,
      'propertySchemaId': statusSchema,
      'idx': 0,
    });
    expect(unsets[1]['payload'], {
      'objectId': node,
      'propertySchemaId': statusSchema,
      'elementId': elementUuid,
    });

    // Serverless flush applies the pending envelopes locally in order.
    await service.flush();

    final rows = await cache.getEffectiveProperties(node);
    expect(rows, hasLength(1));
    expect(rows.single.propertySchemaId, notesSchema);
    expect(rows.single.value, 'user wrote this');
    expect(rows.single.source, 'authored');
    expect(rows.single.boundBy, isNull); // unbound after the removal
    final member = await cache.getByUuid(node);
    expect(member!.classesUuid, isEmpty);
  });

  test('the mirrors are the DEFAULT-MIRROR values only: an authored value '
      'differing from the default survives the sweep', () async {
    await seed();
    await apply(env(
      'property.set',
      OperationPayloads.propertySet(
        objectId: node,
        propertySchemaId: statusSchema,
        value: 'opt-done', // the user actually chose Done
        idx: 2,
        elementId: '20000000-0000-4000-8000-0000000000e2',
      ),
    ));

    await service.enqueue(
      type: 'remove_class',
      nodeUuid: node,
      classUuid: klass,
    );
    await service.flush();

    final rows = await cache.getEffectiveProperties(node);
    expect(rows, hasLength(2));
    final notes = rows.singleWhere((r) => r.propertySchemaId == notesSchema);
    final status = rows.singleWhere((r) => r.propertySchemaId == statusSchema);
    expect(notes.value, 'user wrote this');
    expect(status.value, 'opt-done');
    expect(status.boundBy, isNull);
  });

  test('bindings without a defaultValue never sweep', () async {
    await seed();
    // A class whose binding carries NO default, with an authored value.
    const plainClass = '20000000-0000-4000-8000-000000000040';
    await apply(env(
      'class.create',
      OperationPayloads.classCreate(classId: plainClass, name: 'plainish'),
    ));
    await apply(env(
      'class.property.set',
      OperationPayloads.classPropertySet(
        classId: plainClass,
        propertySchemaId: notesSchema,
        sequence: 0,
      ),
    ));
    await apply(env(
      'object.create',
      OperationPayloads.objectCreate(objectId: node, classIds: [plainClass]),
    ));

    await service.enqueue(
      type: 'remove_class',
      nodeUuid: node,
      classUuid: plainClass,
    );

    // Exactly one pending envelope: the unassign itself (no sweep).
    final pending = await outboxRows();
    expect(pending, hasLength(1));
    final envelope = jsonDecode(pending.single['envelope_json'] as String)
        as Map<String, dynamic>;
    expect(envelope['opType'], 'class.unassign');
  });

  test('a class the node does not carry sweeps nothing (web membership '
      'gate)', () async {
    await seed();
    const stranger = '20000000-0000-4000-8000-000000000050';

    await service.enqueue(
      type: 'remove_class',
      nodeUuid: node,
      classUuid: stranger,
    );

    final pending = await outboxRows();
    expect(pending, hasLength(1));
    final envelope = jsonDecode(pending.single['envelope_json'] as String)
        as Map<String, dynamic>;
    expect(envelope['opType'], 'class.unassign');
  });

  test('a stored non-string default sweeps only the authored row whose '
      'JSON text equals the quoted string (web decodeDefault parity)', () async {
    const countSchema = '20000000-0000-4000-8000-000000000060';
    const counter = '20000000-0000-4000-8000-000000000061';
    await apply(env(
      'propertySchema.create',
      OperationPayloads.propertySchemaCreate(
        propertySchemaId: countSchema,
        name: 'count',
        type: 'number',
        multi: true,
      ),
    ));
    await apply(env(
      'class.create',
      OperationPayloads.classCreate(classId: counter, name: 'counter'),
    ));
    // A number default (5). Web decodeDefault re-encodes it to the STRING
    // "5", and the sweep compares JSON.stringify(value) to '"5"' — the
    // quoted string — so an authored NUMBER 5 does NOT sweep, while an
    // authored STRING "5" does. Quirk recorded in the port.
    await apply(env(
      'class.property.set',
      OperationPayloads.classPropertySet(
        classId: counter,
        propertySchemaId: countSchema,
        sequence: 0,
        defaultValue: 5,
      ),
    ));
    await apply(env(
      'object.create',
      OperationPayloads.objectCreate(
        objectId: node,
        classIds: [counter],
        contentAst: const [],
      ),
    ));
    await apply(env(
      'property.set',
      OperationPayloads.propertySet(
        objectId: node,
        propertySchemaId: countSchema,
        value: 5, // authored number — JSON text '5' ≠ '"5"' — survives
      ),
    ));
    // A legacy pre-PG6 row stored as the raw STRING '5' (the migrated log
    // can carry it): PG6 normalization never rewrote it, so its JSON text
    // still equals the quoted default string — the quirk branch fires.
    final db = await database.database;
    await db.insert('property_value', {
      'id': '20000000-0000-4000-8000-0000000000e3',
      'node_uuid': node,
      'property_schema_id': countSchema,
      'value': '"5"',
      'idx': 1,
      'hlc_physical': 900,
      'hlc_logical': 0,
      'actor_id': actor,
    });
    await cache.projectNodeProperties(node);

    await service.enqueue(
      type: 'remove_class',
      nodeUuid: node,
      classUuid: counter,
    );

    final pending = await outboxRows();
    expect(pending, hasLength(2)); // one unset + the unassign
    final unset = jsonDecode(pending.first['envelope_json'] as String)
        as Map<String, dynamic>;
    expect(unset['opType'], 'property.unset');
    expect(unset['payload']['elementId'],
        '20000000-0000-4000-8000-0000000000e3');
  });
}
