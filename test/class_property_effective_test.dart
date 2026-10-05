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

/// Acceptance for the class.property.* lockstep ops (SCHEMA.md "Class
/// properties — bindings, defaults, aggregation", 2026-09-27), replaying the
/// canonical `class-property-defaults.json` fixture through the appliers with
/// intermediate reads through the ported `getEffectiveProperties`:
///
///  - prefix 5 (Task binds priority=medium) → the node of Task reads "medium";
///  - prefix 7 (Project also binds "high" and is added second) → still
///    "medium" — first-class-applied wins (Task's membership add carries the
///    earlier HLC);
///  - full 8 (Task's binding unset) → "high" (Project's binding supplies it).
///
/// Defaults are a DERIVED read model: no property_value rows are written.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  sqfliteFfiInit();

  const schema = '0192a000-0000-7000-8000-000000000301';
  const taskClass = '0192a000-0000-7000-8000-000000000302';
  const projectClass = '0192a000-0000-7000-8000-000000000303';
  const nodeId = '0192a000-0000-7000-8000-000000000304';

  List<Map<String, dynamic>> loadFixture() =>
      ((jsonDecode(File('test/fixtures/v2/class-property-defaults.json')
                  .readAsStringSync())
              as Map<String, dynamic>)['envelopes'] as List<dynamic>)
          .cast<Map<String, dynamic>>();

  List<OperationEnvelope> fixtureEnvelopes() =>
      loadFixture().map(OperationEnvelope.fromJson).toList();

  group('class.property.* fixture acceptance', () {
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
      expect(envelopes, hasLength(8));
      for (var i = 0; i < count; i++) {
        await appliers.apply(envelopes[i]);
      }
    }

    Future<String?> effectivePriority() async {
      final rows = await cache.getEffectiveProperties(nodeId);
      final row = rows.where((r) => r.propertySchemaId == schema).toList();
      expect(row, hasLength(1), reason: 'exactly one effective row');
      return row.single.value as String?;
    }

    test('prefix 5: Task-bound default reads "medium"', () async {
      await replayPrefix(5);
      final rows = await cache.getEffectiveProperties(nodeId);
      final row = rows.singleWhere((r) => r.propertySchemaId == schema);
      expect(row.value, 'medium');
      expect(row.source, 'default');
      expect(row.boundBy, taskClass);
      expect(row.sequence, 0);
      // Derived only: no authored property_value rows exist.
      final db = await database.database;
      final authored = await db
          .rawQuery('SELECT COUNT(*) AS c FROM property_value WHERE node_uuid = ?', [nodeId]);
      expect(authored.single['c'], 0);
    });

    test('prefix 7: multi-class conflict resolves first-applied-wins',
        () async {
      await replayPrefix(7);
      expect(await effectivePriority(), 'medium');

      final rows = await cache.getEffectiveProperties(nodeId);
      final row = rows.singleWhere((r) => r.propertySchemaId == schema);
      expect(row.source, 'default');
      expect(row.boundBy, taskClass); // Task was assigned at the earlier HLC
    });

    test('full 8: unbinding Task flips the effective default to "high"',
        () async {
      await replayPrefix(8);
      expect(await effectivePriority(), 'high');

      final rows = await cache.getEffectiveProperties(nodeId);
      final row = rows.singleWhere((r) => r.propertySchemaId == schema);
      expect(row.source, 'default');
      expect(row.boundBy, projectClass);
    });

    test('authored value shadows the default and survives unbinding',
        () async {
      await replayPrefix(7);
      await appliers.apply(OperationEnvelope(
        id: '0192a000-0000-7000-8000-000000000301',
        workspaceId: '0192a000-0000-7000-8000-000000000001',
        actorId: '0192a000-0000-7000-8000-000000000002',
        deviceId: 'test-device',
        hlc: const Hlc(physical: 1727200012000, logical: 0),
        affectedNodeIds: const [nodeId],
        opType: 'property.set',
        payload: OperationPayloads.propertySet(
          objectId: nodeId,
          propertySchemaId: schema,
          value: 'low',
        ),
        timestamp: '2026-09-24T12:00:12.000Z',
      ));

      var rows = await cache.getEffectiveProperties(nodeId);
      var row = rows.singleWhere((r) => r.propertySchemaId == schema);
      expect(row.value, 'low');
      expect(row.source, 'authored');
      expect(row.boundBy, taskClass); // still bound (Task wins the binding)

      // Unbind BOTH bindings: the authored value stays visible, unbound.
      await appliers.apply(OperationEnvelope(
        id: '0192a000-0000-7000-8000-000000000302',
        workspaceId: '0192a000-0000-7000-8000-000000000001',
        actorId: '0192a000-0000-7000-8000-000000000002',
        deviceId: 'test-device',
        hlc: const Hlc(physical: 1727200012100, logical: 0),
        affectedNodeIds: const [taskClass],
        opType: 'class.property.unset',
        payload: OperationPayloads.classPropertyUnset(
          classId: taskClass,
          propertySchemaId: schema,
        ),
        timestamp: '2026-09-24T12:00:12.100Z',
      ));
      await appliers.apply(OperationEnvelope(
        id: '0192a000-0000-7000-8000-000000000303',
        workspaceId: '0192a000-0000-7000-8000-000000000001',
        actorId: '0192a000-0000-7000-8000-000000002',
        deviceId: 'test-device',
        hlc: const Hlc(physical: 1727200012200, logical: 0),
        affectedNodeIds: const [projectClass],
        opType: 'class.property.unset',
        payload: OperationPayloads.classPropertyUnset(
          classId: projectClass,
          propertySchemaId: schema,
        ),
        timestamp: '2026-09-24T12:00:12.200Z',
      ));

      rows = await cache.getEffectiveProperties(nodeId);
      row = rows.singleWhere((r) => r.propertySchemaId == schema);
      expect(row.value, 'low');
      expect(row.source, 'authored');
      expect(row.boundBy, isNull); // unbound-by-current-classes, still visible
    });

    test('tombstone-suppressed authored value falls back to the default',
        () async {
      await replayPrefix(5); // Task binds "medium"

      await appliers.apply(OperationEnvelope(
        id: '0192a000-0000-7000-8000-000000000401',
        workspaceId: '0192a000-0000-7000-8000-000000000001',
        actorId: '0192a000-0000-7000-8000-000000000002',
        deviceId: 'test-device',
        hlc: const Hlc(physical: 1727200012000, logical: 0),
        affectedNodeIds: const [nodeId],
        opType: 'property.set',
        payload: OperationPayloads.propertySet(
          objectId: nodeId,
          propertySchemaId: schema,
          value: 'low',
        ),
        timestamp: '2026-09-24T12:00:12.000Z',
      ));
      // A newer tombstone blocks the authored write.
      await appliers.apply(OperationEnvelope(
        id: '0192a000-0000-7000-8000-000000000402',
        workspaceId: '0192a000-0000-7000-8000-000000000001',
        actorId: '0192a000-0000-7000-8000-000000000002',
        deviceId: 'test-device',
        hlc: const Hlc(physical: 1727200012100, logical: 0),
        affectedNodeIds: const [nodeId],
        opType: 'property.unset',
        payload: OperationPayloads.propertyUnset(
          objectId: nodeId,
          propertySchemaId: schema,
        ),
        timestamp: '2026-09-24T12:00:12.100Z',
      ));

      final rows = await cache.getEffectiveProperties(nodeId);
      final row = rows.singleWhere((r) => r.propertySchemaId == schema);
      expect(row.source, 'default');
      expect(row.value, 'medium'); // falls back to the binding's default
    });

    test('partial binding update keeps omitted fields', () async {
      await replayPrefix(5); // Task: sequence 0, default "medium"

      await appliers.apply(OperationEnvelope(
        id: '0192a000-0000-7000-8000-000000000501',
        workspaceId: '0192a000-0000-7000-8000-000000000001',
        actorId: '0192a000-0000-7000-8000-000000000002',
        deviceId: 'test-device',
        hlc: const Hlc(physical: 1727200013000, logical: 0),
        affectedNodeIds: const [taskClass],
        opType: 'class.property.set',
        payload: OperationPayloads.classPropertySet(
          classId: taskClass,
          propertySchemaId: schema,
          required: true,
        ),
        timestamp: '2026-09-24T12:00:13.000Z',
      ));

      final db = await database.database;
      final rows = await db.rawQuery(
        'SELECT sequence, required, default_value, active '
        'FROM class_property WHERE class_id = ? AND property_schema_id = ?',
        [taskClass, schema],
      );
      expect(rows.single['sequence'], 0); // kept
      expect(rows.single['required'], 1); // patched
      expect(jsonDecode(rows.single['default_value'] as String), 'medium');
      expect(rows.single['active'], 1);

      // §34.90: the binding row carries ONLY the per-class mechanics — the
      // retired readonly/hideWhenEmpty/display columns are gone from the
      // table outright.
      final columns = await db.rawQuery('PRAGMA table_info(class_property)');
      final names = columns.map((c) => c['name'] as String).toList();
      expect(names, contains('required'));
      expect(names, isNot(contains('readonly')));
      expect(names, isNot(contains('hide_when_empty')));
      expect(names, isNot(contains('display')));
    });

    test('binding row LWW: a stale set is dropped', () async {
      await replayPrefix(5);
      final applied = await appliers.apply(OperationEnvelope(
        id: '0192a000-0000-7000-8000-000000000601',
        workspaceId: '0192a000-0000-7000-8000-000000000001',
        actorId: '0192a000-0000-7000-8000-000000000002',
        deviceId: 'test-device',
        hlc: const Hlc(physical: 1727200011000, logical: 0), // older than the
        // fixture's binding op (…1400)
        affectedNodeIds: const [taskClass],
        opType: 'class.property.set',
        payload: OperationPayloads.classPropertySet(
          classId: taskClass,
          propertySchemaId: schema,
          defaultValue: 'stale',
        ),
        timestamp: '2026-09-24T12:00:10.000Z',
      ));
      expect(applied, isFalse);
      expect(await effectivePriority(), 'medium');
    });
  });

  group('§34.90 property-level render contracts (schema-sourced display)', () {
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

    OperationEnvelope updateSchema(
      int physical,
      String idSuffix,
      Map<String, dynamic> payload,
    ) =>
        OperationEnvelope(
          id: '0192a000-0000-7000-8000-0000000$idSuffix',
          workspaceId: '0192a000-0000-7000-8000-000000000001',
          actorId: '0192a000-0000-7000-8000-000000000002',
          deviceId: 'test-device',
          hlc: Hlc(physical: physical, logical: 0),
          affectedNodeIds: const [taskClass],
          opType: 'propertySchema.update',
          payload: payload,
          timestamp: '2026-09-24T12:00:00.000Z',
        );

    Future<String?> storedDisplay() async {
      final db = await database.database;
      final rows = await db.rawQuery(
        'SELECT display FROM property_schema WHERE uuid = ?',
        [schema],
      );
      return rows.single['display'] as String?;
    }

    test('display persists on the SCHEMA row and rides the effective read '
        '(panel default → bullet → patch-keep → inline → null clear)', () async {
      await replayFixturePrefix(appliers, 5);
      // Absent display = the NULL 'panel' default.
      expect(await storedDisplay(), isNull);
      var row = (await cache.getEffectiveProperties(nodeId))
          .singleWhere((r) => r.propertySchemaId == schema);
      expect(row.display, isNull);
      expect(row.source, 'default');

      // A schema-side display write surfaces on authored + default rows.
      await appliers.apply(updateSchema(1727200014000, '810a', {
        'propertySchemaId': schema,
        'display': 'bullet',
      }));
      expect(await storedDisplay(), 'bullet');
      row = (await cache.getEffectiveProperties(nodeId))
          .singleWhere((r) => r.propertySchemaId == schema);
      expect(row.display, 'bullet');
      expect(row.source, 'default');

      // An authored value at idx 0 shadows the default but inherits the
      // SCHEMA's display.
      await appliers.apply(OperationEnvelope(
        id: '0192a000-0000-7000-8000-00000000810b',
        workspaceId: '0192a000-0000-7000-8000-000000000001',
        actorId: '0192a000-0000-7000-8000-000000000002',
        deviceId: 'test-device',
        hlc: const Hlc(physical: 1727200014100, logical: 0),
        affectedNodeIds: const [nodeId],
        opType: 'property.set',
        payload: OperationPayloads.propertySet(
          objectId: nodeId,
          propertySchemaId: schema,
          value: 'low',
        ),
        timestamp: '2026-09-24T12:00:14.100Z',
      ));
      row = (await cache.getEffectiveProperties(nodeId))
          .singleWhere((r) => r.propertySchemaId == schema);
      expect(row.display, 'bullet');
      expect(row.source, 'authored');

      // Patch semantics: an omitted display keeps the stored position.
      await appliers.apply(updateSchema(1727200014200, '810c', {
        'propertySchemaId': schema,
        'name': 'Importance',
      }));
      expect(await storedDisplay(), 'bullet'); // kept

      // A present value replaces it...
      await appliers.apply(updateSchema(1727200014300, '810d', {
        'propertySchemaId': schema,
        'display': 'inline',
      }));
      expect(await storedDisplay(), 'inline');
      expect(
        (await cache.getEffectiveProperties(nodeId))
            .singleWhere((r) => r.propertySchemaId == schema)
            .display,
        'inline',
      );

      // ...and an explicit null clears back to the 'panel' default.
      await appliers.apply(updateSchema(1727200014400, '810e', {
        'propertySchemaId': schema,
        'display': null,
      }));
      expect(await storedDisplay(), isNull);
      expect(
        (await cache.getEffectiveProperties(nodeId))
            .singleWhere((r) => r.propertySchemaId == schema)
            .display,
        isNull,
      );
    });

    test('an unbound authored value CARRIES the schema display; required '
        'stays binding-sourced (null when unbound); an inactive binding '
        'contributes nothing', () async {
      await replayFixturePrefix(appliers, 5);
      // Schema-side display, no authored value yet: the derived default
      // reads it.
      await appliers.apply(updateSchema(1727200014000, '820a', {
        'propertySchemaId': schema,
        'display': 'bullet',
      }));

      // Unbind: the authored value (written before the unbind) survives and
      // CARRIES the schema display — §34.90: the contracts are
      // PROPERTY-level, the same for every carrier, class-bound or not.
      await appliers.apply(OperationEnvelope(
        id: '0192a000-0000-7000-8000-00000000820b',
        workspaceId: '0192a000-0000-7000-8000-000000000001',
        actorId: '0192a000-0000-7000-8000-000000000002',
        deviceId: 'test-device',
        hlc: const Hlc(physical: 1727200014100, logical: 0),
        affectedNodeIds: const [nodeId],
        opType: 'property.set',
        payload: OperationPayloads.propertySet(
          objectId: nodeId,
          propertySchemaId: schema,
          value: 'low',
        ),
        timestamp: '2026-09-24T12:00:14.100Z',
      ));
      await appliers.apply(OperationEnvelope(
        id: '0192a000-0000-7000-8000-00000000820c',
        workspaceId: '0192a000-0000-7000-8000-000000000001',
        actorId: '0192a000-0000-7000-8000-000000000002',
        deviceId: 'test-device',
        hlc: const Hlc(physical: 1727200014200, logical: 0),
        affectedNodeIds: const [taskClass],
        opType: 'class.property.unset',
        payload: OperationPayloads.classPropertyUnset(
          classId: taskClass,
          propertySchemaId: schema,
        ),
        timestamp: '2026-09-24T12:00:14.200Z',
      ));
      var row = (await cache.getEffectiveProperties(nodeId))
          .singleWhere((r) => r.propertySchemaId == schema);
      expect(row.source, 'authored');
      expect(row.boundBy, isNull);
      expect(row.display, 'bullet'); // schema-sourced, rides unbound rows
      expect(row.required, isNull); // binding-sourced: no current binding

      // Re-bind (required + a default), then flip inactive: the inactive
      // binding stops contributing metadata — the authored value reads
      // unbound with required null — while the SCHEMA display still rides.
      await appliers.apply(OperationEnvelope(
        id: '0192a000-0000-7000-8000-00000000820d',
        workspaceId: '0192a000-0000-7000-8000-000000000001',
        actorId: '0192a000-0000-7000-8000-000000000002',
        deviceId: 'test-device',
        hlc: const Hlc(physical: 1727200014300, logical: 0),
        affectedNodeIds: const [taskClass],
        opType: 'class.property.set',
        payload: OperationPayloads.classPropertySet(
          classId: taskClass,
          propertySchemaId: schema,
          required: true,
          defaultValue: 'medium',
        ),
        timestamp: '2026-09-24T12:00:14.300Z',
      ));
      row = (await cache.getEffectiveProperties(nodeId))
          .singleWhere((r) => r.propertySchemaId == schema);
      expect(row.source, 'authored');
      expect(row.required, isTrue); // the winning binding's per-class flag
      expect(row.display, 'bullet');

      await appliers.apply(OperationEnvelope(
        id: '0192a000-0000-7000-8000-00000000820e',
        workspaceId: '0192a000-0000-7000-8000-000000000001',
        actorId: '0192a000-0000-7000-8000-000000000002',
        deviceId: 'test-device',
        hlc: const Hlc(physical: 1727200014400, logical: 0),
        affectedNodeIds: const [taskClass],
        opType: 'class.property.set',
        payload: OperationPayloads.classPropertySet(
          classId: taskClass,
          propertySchemaId: schema,
          active: false,
        ),
        timestamp: '2026-09-24T12:00:14.400Z',
      ));
      final effective = await cache.getEffectiveProperties(nodeId);
      row = effective.singleWhere((r) => r.propertySchemaId == schema);
      expect(row.source, 'authored');
      expect(row.boundBy, isNull);
      expect(row.required, isNull); // the inactive binding contributes nothing
      expect(row.display, 'bullet'); // the schema display still rides
      // The derived default vanishes with the inactive binding.
      expect(effective.where((r) => r.source == 'default'), isEmpty);
    });
  });

  group('class.property.* payload factories', () {
    const classId = '0192a000-0000-7000-8000-000000000302';
    const schemaId = '0192a000-0000-7000-8000-000000000301';

    test('set validates and round-trips', () {
      final payload = OperationPayloads.classPropertySet(
        classId: classId,
        propertySchemaId: schemaId,
        sequence: 2,
        required: true,
        defaultValue: 'high',
      );
      expect(payload['sequence'], 2);
      expect(payload['required'], isTrue);
      expect(payload['defaultValue'], 'high');
      expect(
        () => OperationPayloads.validatePayload('class.property.set', payload),
        returnsNormally,
      );
    });

    test('set rejects unknown keys and bad uuids', () {
      expect(
        () => OperationPayloads.validatePayload('class.property.set', {
          'classId': classId,
          'propertySchemaId': schemaId,
          'sequence': 0,
          'nope': 1,
        }),
        throwsFormatException,
      );
      expect(
        () => OperationPayloads.classPropertySet(
          classId: 'not-a-uuid',
          propertySchemaId: schemaId,
        ),
        throwsFormatException,
      );
    });

    test('unset validates and round-trips', () {
      final payload = OperationPayloads.classPropertyUnset(
        classId: classId,
        propertySchemaId: schemaId,
      );
      expect(
        () =>
            OperationPayloads.validatePayload('class.property.unset', payload),
        returnsNormally,
      );
      expect(OperationPayloads.isKnownOpType('class.property.unset'), isTrue);
    });

    test('flags accept explicit null (clear) in raw maps', () {
      // §34.90: the binding keeps ONLY required (the owner's per-class
      // exception) — explicit null validates; readonly is retired here.
      expect(
        () => OperationPayloads.validatePayload('class.property.set', {
          'classId': classId,
          'propertySchemaId': schemaId,
          'required': null,
          'active': false,
        }),
        returnsNormally,
      );
      expect(
        () => OperationPayloads.validatePayload('class.property.set', {
          'classId': classId,
          'propertySchemaId': schemaId,
          'required': 'yes',
        }),
        throwsFormatException,
      );
      expect(
        () => OperationPayloads.validatePayload('class.property.set', {
          'classId': classId,
          'propertySchemaId': schemaId,
          'readonly': false,
        }),
        throwsFormatException,
      );
    });
  });

  group('class.property.* applier guards', () {
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

    test('validation failure on a known op throws EnvelopeValidationError',
        () async {
      expect(
        () async => appliers.apply(OperationEnvelope(
          id: '0192a000-0000-7000-8000-000000000701',
          workspaceId: '0192a000-0000-7000-8000-000000000001',
          actorId: '0192a000-0000-7000-8000-000000000002',
          deviceId: 'test-device',
          hlc: const Hlc(physical: 1, logical: 0),
          affectedNodeIds: const [taskClass],
          opType: 'class.property.set',
          payload: const {
            'classId': taskClass,
            'propertySchemaId': 'not-a-uuid',
          },
          timestamp: '2026-09-24T12:00:00.000Z',
        )),
        throwsA(isA<EnvelopeValidationError>()),
      );
    });
  });
}

const taskClass = '0192a000-0000-7000-8000-000000000302';
const projectClass = '0192a000-0000-7000-8000-000000000303';

/// Replays the first [count] envelopes of the canonical
/// `class-property-defaults.json` fixture through [appliers] (the §34.89
/// group shares the seed: prefix 5 = Task binds priority=medium).
Future<void> replayFixturePrefix(RelayAppliers appliers, int count) async {
  final envelopes = ((jsonDecode(File('test/fixtures/v2/class-property-defaults.json')
                  .readAsStringSync())
          as Map<String, dynamic>)['envelopes'] as List<dynamic>)
      .cast<Map<String, dynamic>>()
      .map(OperationEnvelope.fromJson)
      .toList();
  expect(envelopes, hasLength(8));
  for (var i = 0; i < count; i++) {
    await appliers.apply(envelopes[i]);
  }
}
