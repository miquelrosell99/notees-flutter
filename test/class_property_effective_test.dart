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
/// properties — bindings, defaults, aggregation", 2026-09-27; the default
/// moved to the schema), replaying the canonical
/// `class-property-defaults.json` fixture through the appliers with
/// intermediate reads through the ported `getEffectiveProperties`:
///
///  - prefix 5 (schema 'priority' with the GLOBAL default 'medium', the node
///    of Task, Task's binding) → the node reads "medium", boundBy Task;
///  - prefix 7 (Project binds too, added second) → still "medium" — the
///    value is the schema's ONE GLOBAL default (per-class default conflicts
///    no longer exist); Task still wins the binding (earliest assignment
///    HLC), so boundBy stays Task;
///  - envelope 7 (Task's binding unset) → "medium", boundBy Project
///    (Project's binding supplies the metadata, the schema the value);
///  - envelope 8 (Project's binding unset too) → no binding, no derived
///    default: the property leaves the effective list entirely.
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
      ((jsonDecode(File('test/fixtures/wire/class-property-defaults.json')
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
      expect(envelopes, hasLength(10));
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
      // Derived only: no authored property_value rows exist.
      final db = await database.database;
      final authored = await db
          .rawQuery('SELECT COUNT(*) AS c FROM property_value WHERE node_uuid = ?', [nodeId]);
      expect(authored.single['c'], 0);
    });

    test('prefix 7: a second binding adds presence, not a competing '
        'default — the schema default is global', () async {
      await replayPrefix(7);
      expect(await effectivePriority(), 'medium');

      final rows = await cache.getEffectiveProperties(nodeId);
      final row = rows.singleWhere((r) => r.propertySchemaId == schema);
      expect(row.source, 'default');
      expect(row.boundBy, taskClass); // Task was assigned at the earlier HLC
      // The schema row carries the ONE GLOBAL default.
      final db = await database.database;
      final stored = await db.rawQuery(
        'SELECT default_value FROM property_schema WHERE uuid = ?',
        [schema],
      );
      expect(jsonDecode(stored.single['default_value'] as String), 'medium');
    });

    test('envelope 7: unbinding Task flips boundBy to Project — the value '
        'is still the schema default', () async {
      await replayPrefix(8);
      expect(await effectivePriority(), 'medium');

      final rows = await cache.getEffectiveProperties(nodeId);
      final row = rows.singleWhere((r) => r.propertySchemaId == schema);
      expect(row.source, 'default');
      expect(row.boundBy, projectClass);
    });

    test('envelope 8: unbinding Project too — no binding, no derived '
        'default', () async {
      await replayPrefix(9);
      final rows = await cache.getEffectiveProperties(nodeId);
      expect(rows.where((r) => r.propertySchemaId == schema), isEmpty);
      // The schema still carries its default — only the bindings are gone.
      final db = await database.database;
      final stored = await db.rawQuery(
        'SELECT default_value FROM property_schema WHERE uuid = ?',
        [schema],
      );
      expect(jsonDecode(stored.single['default_value'] as String), 'medium');
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
      expect(row.value, 'medium'); // falls back to the schema's global default
    });

    test('partial binding update keeps omitted fields; the default lives '
        'on the schema row', () async {
      await replayPrefix(5); // Task bound, schema default "medium"

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
          active: false,
        ),
        timestamp: '2026-09-24T12:00:13.000Z',
      ));

      final db = await database.database;
      final rows = await db.rawQuery(
        'SELECT active FROM class_property '
        'WHERE class_id = ? AND property_schema_id = ?',
        [taskClass, schema],
      );
      expect(rows.single['active'], 0); // patched

      // The default survives on the SCHEMA row (the global-default move):
      // patching the binding never touches it.
      final stored = await db.rawQuery(
        'SELECT default_value FROM property_schema WHERE uuid = ?',
        [schema],
      );
      expect(jsonDecode(stored.single['default_value'] as String), 'medium');

      // The binding row carries ONLY the genuinely per-class mechanics —
      // every retired column is gone from the table outright.
      final columns = await db.rawQuery('PRAGMA table_info(class_property)');
      final names = columns.map((c) => c['name'] as String).toList();
      expect(names, isNot(contains('required')));
      expect(names, isNot(contains('default_value')));
      expect(names, isNot(contains('sequence')));
      expect(names, isNot(contains('readonly')));
      expect(names, isNot(contains('hide_when_empty')));
      expect(names, isNot(contains('display')));
    });

    test('schema default keep/clear: propertySchema.update patches the '
        'value, an explicit null clears it', () async {
      await replayPrefix(5); // schema default "medium"

      final db = await database.database;
      Future<String?> storedDefault() async => (await db.rawQuery(
            'SELECT default_value FROM property_schema WHERE uuid = ?',
            [schema],
          )).single['default_value'] as String?;

      // Absent keeps.
      await appliers.apply(OperationEnvelope(
        id: '0192a000-0000-7000-8000-000000000701',
        workspaceId: '0192a000-0000-7000-8000-000000000001',
        actorId: '0192a000-0000-7000-8000-000000000002',
        deviceId: 'test-device',
        hlc: const Hlc(physical: 1727200013000, logical: 0),
        affectedNodeIds: const [schema],
        opType: 'propertySchema.update',
        payload: OperationPayloads.propertySchemaUpdate(
          propertySchemaId: schema,
          name: 'Importance',
        ),
        timestamp: '2026-09-24T12:00:13.000Z',
      ));
      expect(jsonDecode((await storedDefault())!), 'medium');

      // Present patches.
      await appliers.apply(OperationEnvelope(
        id: '0192a000-0000-7000-8000-000000000702',
        workspaceId: '0192a000-0000-7000-8000-000000000001',
        actorId: '0192a000-0000-7000-8000-000000000002',
        deviceId: 'test-device',
        hlc: const Hlc(physical: 1727200013100, logical: 0),
        affectedNodeIds: const [schema],
        opType: 'propertySchema.update',
        payload: OperationPayloads.propertySchemaUpdate(
          propertySchemaId: schema,
          defaultValue: 'low',
        ),
        timestamp: '2026-09-24T12:00:13.100Z',
      ));
      expect(jsonDecode((await storedDefault())!), 'low');
      expect(await effectivePriority(), 'low');

      // Present-null clears.
      await appliers.apply(OperationEnvelope(
        id: '0192a000-0000-7000-8000-000000000703',
        workspaceId: '0192a000-0000-7000-8000-000000000001',
        actorId: '0192a000-0000-7000-8000-000000000002',
        deviceId: 'test-device',
        hlc: const Hlc(physical: 1727200013200, logical: 0),
        affectedNodeIds: const [schema],
        opType: 'propertySchema.update',
        payload: OperationPayloads.propertySchemaUpdate(
          propertySchemaId: schema,
          defaultValue: null,
        ),
        timestamp: '2026-09-24T12:00:13.200Z',
      ));
      expect(await storedDefault(), isNull);
      expect(
        (await cache.getEffectiveProperties(nodeId))
            .where((r) => r.propertySchemaId == schema),
        isEmpty,
      );
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
          active: true,
        ),
        timestamp: '2026-09-24T12:00:10.000Z',
      ));
      expect(applied, isFalse);
      expect(await effectivePriority(), 'medium');
    });
  });

  group('pinned binding tier (2026-10-27 lockstep)', () {
    late AppDatabase database;
    late NodeCacheRepository cache;
    late RelayAppliers appliers;

    const ws = '0192a000-0000-7000-8000-000000000001';
    const actor = '0192a000-0000-7000-8000-000000000002';
    // Schemas named so pure-alphabetical order (alpha, beta, zeta) is the
    // OPPOSITE of pin-tier order when zeta alone is pinned.
    const alpha = '0192a000-0000-7000-8000-000000000511';
    const beta = '0192a000-0000-7000-8000-000000000512';
    const zeta = '0192a000-0000-7000-8000-000000000513';
    const orphan = '0192a000-0000-7000-8000-000000000514';
    const cls = '0192a000-0000-7000-8000-000000000521';
    const node = '0192a000-0000-7000-8000-000000000522';

    var physical = 1727200010000;
    var seq = 0;

    setUp(() async {
      final ffiDb = await databaseFactoryFfi.openDatabase(
        ':memory:',
        options: OpenDatabaseOptions(singleInstance: false),
      );
      database = AppDatabase.fromDatabase(ffiDb);
      await database.initializeSchema();
      cache = NodeCacheRepository(database);
      appliers = RelayAppliers(cache);
      physical = 1727200010000;
      seq = 0;
    });

    tearDown(() async {
      await database.close();
      AppDatabase.reset();
    });

    Future<void> emit(
      String opType,
      Map<String, dynamic> payload,
      List<String> affected,
    ) async {
      physical += 10;
      seq += 1;
      await appliers.apply(OperationEnvelope(
        id: '0192a000-0000-7000-8000-000000009${seq.toString().padLeft(3, '0')}',
        workspaceId: ws,
        actorId: actor,
        deviceId: 'test-device',
        hlc: Hlc(physical: physical, logical: 0),
        affectedNodeIds: affected,
        opType: opType,
        payload: payload,
        timestamp: '2026-09-24T12:00:00.000Z',
      ));
    }

    Future<void> seed({bool pinZeta = true}) async {
      for (final entry in [
        (alpha, 'alpha', 'a'),
        (beta, 'beta', 'b'),
        (zeta, 'zeta', 'z'),
      ]) {
        await emit(
          'propertySchema.create',
          OperationPayloads.propertySchemaCreate(
            propertySchemaId: entry.$1,
            name: entry.$2,
            type: 'text',
            defaultValue: entry.$3,
          ),
          [entry.$1],
        );
      }
      await emit(
        'propertySchema.create',
        OperationPayloads.propertySchemaCreate(
          propertySchemaId: orphan,
          name: 'orphan',
          type: 'text',
        ),
        [orphan],
      );
      await emit(
        'class.create',
        OperationPayloads.classCreate(
          classId: cls,
          contentAst: [
            {'type': 'text', 'text': 'Feature'},
          ],
        ),
        [cls],
      );
      await emit(
        'object.create',
        OperationPayloads.objectCreate(
          objectId: node,
          isEmbedded: false,
          classIds: const [cls],
        ),
        [node],
      );
      for (final schemaId in [alpha, beta, zeta]) {
        await emit(
          'class.property.set',
          OperationPayloads.classPropertySet(
            classId: cls,
            propertySchemaId: schemaId,
            pinned: schemaId == zeta ? pinZeta : null,
          ),
          [cls],
        );
      }
    }

    Future<List<String>> effectiveOrder() async =>
        (await cache.getEffectiveProperties(node))
            .map((r) => r.schema?.name ?? r.propertySchemaId)
            .toList();

    test('pinned tier renders FIRST, alphabetical within each tier, '
        'unpinned after', () async {
      await seed();
      // zeta is pinned (alphabetically LAST) yet renders first; alpha and
      // beta stay alphabetical in the unpinned tier.
      expect(await effectiveOrder(), ['zeta', 'alpha', 'beta']);
      final rows = await cache.getEffectiveProperties(node);
      expect(rows.singleWhere((r) => r.propertySchemaId == zeta).pinned,
          isTrue);
      expect(rows.singleWhere((r) => r.propertySchemaId == alpha).pinned,
          isFalse);
    });

    test('a true→false flip rejoins the unpinned tier; an active-only patch '
        'keeps the stored flag', () async {
      await seed();
      expect(await effectiveOrder(), ['zeta', 'alpha', 'beta']);

      // Active-only patch (pinned omitted) keeps the stored pin.
      await emit(
        'class.property.set',
        OperationPayloads.classPropertySet(
          classId: cls,
          propertySchemaId: zeta,
          active: true,
        ),
        [cls],
      );
      expect(await effectiveOrder(), ['zeta', 'alpha', 'beta']);

      // The flip back unpins: pure alphabetical again.
      await emit(
        'class.property.set',
        OperationPayloads.classPropertySet(
          classId: cls,
          propertySchemaId: zeta,
          pinned: false,
        ),
        [cls],
      );
      expect(await effectiveOrder(), ['alpha', 'beta', 'zeta']);
    });

    test('an unbound authored row renders LAST, unpinned, and bound authored '
        'rows join the pin tiers', () async {
      await seed();
      await emit(
        'property.set',
        OperationPayloads.propertySet(
          objectId: node,
          propertySchemaId: beta,
          value: 'authored-b',
        ),
        [node],
      );
      await emit(
        'property.set',
        OperationPayloads.propertySet(
          objectId: node,
          propertySchemaId: orphan,
          value: 'lonely',
        ),
        [node],
      );
      // The bound authored row replaces beta's derived default in place; the
      // unbound authored row trails every bound row.
      expect(await effectiveOrder(), ['zeta', 'alpha', 'beta', 'orphan']);
      final rows = await cache.getEffectiveProperties(node);
      expect(rows.singleWhere((r) => r.propertySchemaId == beta).source,
          'authored');
      final orphanRow =
          rows.singleWhere((r) => r.propertySchemaId == orphan);
      expect(orphanRow.boundBy, isNull);
      expect(orphanRow.pinned, isFalse);
    });

    test('the (idx, element id) tiebreak is unchanged by the pin tier',
        () async {
      await seed();
      // Two authored elements on the pinned schema at the same idx: the
      // element id orders them, inside the pinned tier.
      await emit(
        'property.set',
        OperationPayloads.propertySet(
          objectId: node,
          propertySchemaId: zeta,
          value: 'second',
          elementId: '0192a000-0000-7000-8000-000000000581',
          idx: 0,
        ),
        [node],
      );
      await emit(
        'property.set',
        OperationPayloads.propertySet(
          objectId: node,
          propertySchemaId: zeta,
          value: 'first',
          elementId: '0192a000-0000-7000-8000-000000000580',
          idx: 0,
        ),
        [node],
      );
      final rows = await cache.getEffectiveProperties(node);
      final zetas = rows.where((r) => r.propertySchemaId == zeta).toList();
      expect(zetas.map((r) => r.value), ['first', 'second']);
      // The pinned schema's rows still lead the list.
      expect(rows.first.propertySchemaId, zeta);
      expect(await effectiveOrder(), ['zeta', 'zeta', 'alpha', 'beta']);
    });
  });

  group('property-level render contracts (schema-sourced display)', () {
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

    test('an unbound authored value CARRIES the schema display; an inactive '
        'binding contributes nothing', () async {
      await replayFixturePrefix(appliers, 5);
      // Schema-side display, no authored value yet: the derived default
      // reads it.
      await appliers.apply(updateSchema(1727200014000, '820a', {
        'propertySchemaId': schema,
        'display': 'bullet',
      }));

      // Unbind: the authored value (written before the unbind) survives and
      // CARRIES the schema display — the contracts are
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

      // Re-bind, then flip inactive: the inactive binding stops
      // contributing metadata — the authored value reads unbound — while
      // the SCHEMA display still rides.
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
        ),
        timestamp: '2026-09-24T12:00:14.300Z',
      ));
      row = (await cache.getEffectiveProperties(nodeId))
          .singleWhere((r) => r.propertySchemaId == schema);
      expect(row.source, 'authored');
      expect(row.boundBy, taskClass); // the winning binding supplies metadata
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
      expect(row.display, 'bullet'); // the schema display still rides
      // The derived default vanishes with the inactive binding.
      expect(effective.where((r) => r.source == 'default'), isEmpty);
    });
  });

  group('class.property.* payload factories', () {
    const classId = '0192a000-0000-7000-8000-000000000302';
    const schemaId = '0192a000-0000-7000-8000-000000000301';

    test('set validates and round-trips (active only)', () {
      final payload = OperationPayloads.classPropertySet(
        classId: classId,
        propertySchemaId: schemaId,
        active: false,
      );
      expect(payload['active'], isFalse);
      expect(
        () => OperationPayloads.validatePayload('class.property.set', payload),
        returnsNormally,
      );
    });

    test('set rejects retired and unknown keys', () {
      // `required` retired outright and `defaultValue` moved to the schema
      // `sequence` retired outright — the strict 3-key payload rejects all three like any
      // retired key.
      for (final retired in ['required', 'defaultValue', 'sequence']) {
        expect(
          () => OperationPayloads.validatePayload('class.property.set', {
            'classId': classId,
            'propertySchemaId': schemaId,
            retired: retired == 'required' ? true : 'high',
          }),
          throwsFormatException,
          reason: retired,
        );
      }
      expect(
        () => OperationPayloads.validatePayload('class.property.set', {
          'classId': classId,
          'propertySchemaId': schemaId,
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

    test('the binding keeps ONLY active — required/defaultValue/sequence '
        'retired', () {
      // The retired keys reject on the binding op; `active` stays legal.
      expect(
        () => OperationPayloads.validatePayload('class.property.set', {
          'classId': classId,
          'propertySchemaId': schemaId,
          'required': null,
          'active': false,
        }),
        throwsFormatException,
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

    test('defaultValue rides the schema ops (any JSON value, nullable)', () {
      // Create: any JSON value validates, absent is fine too.
      final created = OperationPayloads.propertySchemaCreate(
        propertySchemaId: schemaId,
        name: 'Status',
        type: 'select',
        defaultValue: 'opt-a',
      );
      expect(created['defaultValue'], 'opt-a');
      expect(
        () => OperationPayloads.validatePayload('propertySchema.create', created),
        returnsNormally,
      );
      for (final value in [null, 7, true, ['a', 'b'], {'any': 'thing'}]) {
        expect(
          () => OperationPayloads.validatePayload('propertySchema.create', {
            'propertySchemaId': schemaId,
            'name': 'Status',
            'type': 'select',
            'defaultValue': value,
          }),
          returnsNormally,
          reason: 'defaultValue: $value',
        );
      }
      // Update: absent keeps (the sentinel drops the key), an explicit null
      // rides as a JSON clear.
      final untouched = OperationPayloads.propertySchemaUpdate(
        propertySchemaId: schemaId,
        name: 'x',
      );
      expect(untouched.containsKey('defaultValue'), isFalse);
      final cleared = OperationPayloads.propertySchemaUpdate(
        propertySchemaId: schemaId,
        defaultValue: null,
      );
      expect(cleared, containsPair('defaultValue', null));
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
/// `class-property-defaults.json` fixture through [appliers] (the
/// group shares the seed: prefix 5 = Task binds priority=medium).
Future<void> replayFixturePrefix(RelayAppliers appliers, int count) async {
  final envelopes = ((jsonDecode(File('test/fixtures/wire/class-property-defaults.json')
                  .readAsStringSync())
          as Map<String, dynamic>)['envelopes'] as List<dynamic>)
      .cast<Map<String, dynamic>>()
      .map(OperationEnvelope.fromJson)
      .toList();
  expect(envelopes, hasLength(10));
  for (var i = 0; i < count; i++) {
    await appliers.apply(envelopes[i]);
  }
}
