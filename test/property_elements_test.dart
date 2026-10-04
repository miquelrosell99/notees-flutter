import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:notees/core/utils/date_uuid.dart';
import 'package:notees/data/local/app_database.dart';
import 'package:notees/data/repositories/node_cache_repository.dart';
import 'package:notees/domain/models/relay/hlc.dart';
import 'package:notees/domain/models/relay/operation_envelope.dart';
import 'package:notees/domain/models/relay/operation_payloads.dart';
import 'package:notees/domain/services/relay_appliers.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

/// Acceptance for the §34.57 property-wire batch lockstep:
///
///  - PG5 — per-element value identity: the property_value row id IS the
///    element id (writer UUIDv7 adds, the deterministic `node:schema:idx`
///    composite for positional writes), same-idx concurrent element adds
///    coexist, element tombstones are add-wins (HLC-only membership
///    comparator: equal HLC ⇒ the add wins regardless of actor), a not-
///    strictly-older re-add revives the element, and every read derives the
///    visible set (live rows minus slot tombstones minus element
///    tombstones);
///  - PC4 — `class_property.active`: an inactive binding stops contributing
///    defaults AND metadata to the effective read (authored values read
///    unbound) while the row survives; omitted = keep;
///  - PC6 — date-node-backed qualifiers: well-formed YYYY-MM-DD strings in
///    metadata startDate/endDate normalize on write to the deterministic
///    day-node ref (dateQualified schemas only, the two reserved keys only);
///    reads stay lenient for both shapes;
///  - §34.45 — unsetting a node-backed TEXT value trashes the unreferenced
///    carrier block (child-of-owner, active non-class, unreferenced).
///
/// Replays the three canonical §34.57 fixtures (property-value-elements,
/// class-property-active, property-date-qualifier) through the appliers.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  sqfliteFfiInit();

  const fixturesDir = 'test/fixtures/v2';
  const ws = '0192a000-0000-7000-8000-000000000001';
  const actor = '0192a000-0000-7000-8000-000000000002';
  const carol = '0192a000-0000-7000-8000-000000000712';
  const nicknameSchema = '0192a000-0000-7000-8000-000000000711';
  const alpha = '0192a000-0000-7000-8000-000000000721';
  const beta = '0192a000-0000-7000-8000-000000000722';
  const gamma = '0192a000-0000-7000-8000-000000000723';

  List<Map<String, dynamic>> loadFixture(String name) =>
      ((jsonDecode(File('$fixturesDir/$name').readAsStringSync())
              as Map<String, dynamic>)['envelopes'] as List<dynamic>)
          .cast<Map<String, dynamic>>();

  List<OperationEnvelope> fixtureEnvelopes(String name) =>
      loadFixture(name).map(OperationEnvelope.fromJson).toList();

  group('§34.57 payload factories', () {
    test('property.set/unset carry the optional PG5 elementId', () {
      final set = OperationPayloads.propertySet(
        objectId: carol,
        propertySchemaId: nicknameSchema,
        value: 'x',
        elementId: alpha,
        idx: 1,
      );
      expect(set['elementId'], alpha);
      expect(set['idx'], 1);
      final unset = OperationPayloads.propertyUnset(
        objectId: carol,
        propertySchemaId: nicknameSchema,
        elementId: alpha,
      );
      expect(unset, {
        'objectId': carol,
        'propertySchemaId': nicknameSchema,
        'elementId': alpha,
        'idx': 0,
      });
      // Absent stays absent (the legacy positional carrier).
      final positional = OperationPayloads.propertySet(
        objectId: carol,
        propertySchemaId: nicknameSchema,
        value: 'x',
      );
      expect(positional.containsKey('elementId'), isFalse);
    });

    test('elementId is uuid-checked', () {
      expect(
        () => OperationPayloads.propertySet(
          objectId: carol,
          propertySchemaId: nicknameSchema,
          value: 'x',
          elementId: 'not-a-uuid',
        ),
        throwsFormatException,
      );
    });

    test('class.property.set carries the optional PC4 active flag', () {
      final payload = OperationPayloads.classPropertySet(
        classId: carol,
        propertySchemaId: nicknameSchema,
        active: false,
      );
      expect(payload['active'], isFalse);
      final kept = OperationPayloads.classPropertySet(
        classId: carol,
        propertySchemaId: nicknameSchema,
      );
      expect(kept.containsKey('active'), isFalse);
    });

    test('propertySchema.create/update carry the Dates fields', () {
      final created = OperationPayloads.propertySchemaCreate(
        propertySchemaId: nicknameSchema,
        name: 'membership',
        type: 'object',
        datePrecision: 'day',
        dateQualified: true,
      );
      expect(created['datePrecision'], 'day');
      expect(created['dateQualified'], isTrue);
      final updated = OperationPayloads.propertySchemaUpdate(
        propertySchemaId: nicknameSchema,
        dateQualified: false,
      );
      expect(updated['dateQualified'], isFalse);
      expect(() => OperationPayloads.propertySchemaCreate(
            propertySchemaId: nicknameSchema,
            name: 'x',
            type: 'object',
            datePrecision: 'hour',
          ), throwsFormatException);
    });
  });

  group('strict ISO date helper (PC6)', () {
    test('real-calendar validation including leap years', () {
      expect(parseIsoDateStrict('2020-02-29'), DateTime.utc(2020, 2, 29));
      expect(parseIsoDateStrict('2019-02-29'), isNull);
      expect(parseIsoDateStrict('2021-04-31'), isNull);
      expect(parseIsoDateStrict('2021-04-30'), DateTime.utc(2021, 4, 30));
      expect(parseIsoDateStrict('2021-13-01'), isNull);
      expect(parseIsoDateStrict('2021-00-10'), isNull);
      expect(parseIsoDateStrict('2021-01-10T00:00:00'), isNull);
      expect(dayUuidFromIsoDate('2019-01-15'),
          '00000000-0000-0000-00dd-201901150000');
      expect(dayUuidFromIsoDate('nope'), isNull);
    });
  });

  group('PG5/PC4/PC6 appliers + fixtures', () {
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

    Future<List<Map<String, dynamic>>> raw(String sql,
            [List<Object?>? args]) async =>
        (await database.database).rawQuery(sql, args);

    test('fixture property-value-elements: OR-Set semantics end to end',
        () async {
      for (final envelope
          in fixtureEnvelopes('property-value-elements.json')) {
        expect(await appliers.apply(envelope), isTrue);
      }
      final rows = await raw(
        'SELECT id, value, idx, metadata FROM property_value '
        'WHERE node_uuid = ? ORDER BY idx, id',
        [carol],
      );
      // alpha (idx 0, metadata intact), beta REVIVED (idx 1), gamma
      // (idx 1 — same-idx concurrent adds coexist), positional (idx 4).
      expect(
        rows.map((r) => (r['id'], r['value'], r['idx'])).toList(),
        [
          (alpha, '"alpha"', 0),
          (beta, '"beta"', 1),
          (gamma, '"gamma"', 1),
          ('$carol:$nicknameSchema:4', '"positional"', 4),
        ],
      );
      expect(rows.first['metadata'], jsonEncode({'since': '2020'}));
      // The element tombstone for beta records the winning remove.
      final tomb = await raw(
        'SELECT hlc_physical, hlc_logical FROM property_value_element_tombstone '
        'WHERE element_id = ?',
        [beta],
      );
      expect(tomb.single['hlc_physical'], 1727200020500);

      // Every read consults the visible set: (idx, element id) ordering.
      final visible = await cache.propertyValuesFor(carol);
      expect(
        visible.map((r) => (r.elementId, r.value, r.idx)).toList(),
        [
          (alpha, 'alpha', 0),
          (beta, 'beta', 1),
          (gamma, 'gamma', 1),
          ('$carol:$nicknameSchema:4', 'positional', 4),
        ],
      );
      // The payload projection reflects the visible set too.
      final node = await cache.getByUuid(carol);
      expect(
        (node!.properties[nicknameSchema] as List<dynamic>).toSet(),
        {'alpha', 'beta', 'gamma', 'positional'},
      );
    });

    test('PG5 element remove is add-wins on equal HLC regardless of actor',
        () async {
      final schema = nicknameSchema;
      await appliers.apply(OperationEnvelope(
        id: '0192a000-0000-7000-8000-000000000101',
        workspaceId: ws,
        actorId: actor,
        deviceId: 't',
        hlc: Hlc(physical: 100, logical: 0),
        affectedNodeIds: [carol],
        opType: 'object.create',
        payload: {'objectId': carol, 'contentAst': const []},
        timestamp: '2026-09-24T12:00:00.000Z',
      ));
      await appliers.apply(OperationEnvelope(
        id: '0192a000-0000-7000-8000-000000000102',
        workspaceId: ws,
        actorId: actor,
        deviceId: 't',
        hlc: Hlc(physical: 100, logical: 0),
        affectedNodeIds: [carol],
        opType: 'propertySchema.create',
        payload: {
          'propertySchemaId': schema,
          'name': 'nickname',
          'type': 'text',
          'multi': true,
        },
        timestamp: '2026-09-24T12:00:00.000Z',
      ));
      OperationEnvelope op(
        String opType,
        Map<String, dynamic> payload,
        int physical,
        int nonce,
      ) =>
          OperationEnvelope(
            id: '0192a000-0000-7000-8000-'
                '${(physical * 10 + nonce).toString().padLeft(12, '0')}',
            workspaceId: ws,
            actorId: nonce.isEven
                ? '90000000-0000-7000-8000-000000000002'
                : 'a0000000-0000-7000-8000-000000000002',
            deviceId: 't',
            hlc: Hlc(physical: physical, logical: 0),
            affectedNodeIds: [carol],
            opType: opType,
            payload: payload,
            timestamp: '2026-09-24T12:00:00.000Z',
          );

      // Add @100 (actor a...) then remove @100 (actor 9...): equal HLC, the
      // remove's actor is lexicographically SMALLER (would win a full tuple
      // compare) — the add still wins (HLC-only comparator).
      await appliers.apply(op('property.set',
          {'objectId': carol, 'propertySchemaId': schema, 'value': 'v', 'elementId': alpha}, 100, 1));
      await appliers.apply(op('property.unset',
          {'objectId': carol, 'propertySchemaId': schema, 'elementId': alpha}, 100, 2));
      var visible = await cache.propertyValuesFor(carol);
      expect(visible.map((r) => r.elementId), [alpha]);

      // Remove @101 (strictly newer) kills the element...
      await appliers.apply(op('property.unset',
          {'objectId': carol, 'propertySchemaId': schema, 'elementId': alpha}, 101, 2));
      visible = await cache.propertyValuesFor(carol);
      expect(visible, isEmpty);
      // ...and a re-add @101 (equal to the tombstone, not strictly older)
      // REVIVES it.
      await appliers.apply(op('property.set',
          {'objectId': carol, 'propertySchemaId': schema, 'value': 'v', 'elementId': alpha}, 101, 1));
      visible = await cache.propertyValuesFor(carol);
      expect(visible.map((r) => r.elementId), [alpha]);
    });

    test('element unset with malformed addressing is a deterministic no-op',
        () async {
      const otherNode = '0192a000-0000-7000-8000-000000000799';
      for (final envelope in [
        OperationEnvelope(
          id: '0192a000-0000-7000-8000-000000000111',
          workspaceId: ws,
          actorId: actor,
          deviceId: 't',
          hlc: Hlc(physical: 100, logical: 0),
          affectedNodeIds: [carol],
          opType: 'object.create',
          payload: {'objectId': carol, 'contentAst': const []},
          timestamp: '2026-09-24T12:00:00.000Z',
        ),
        OperationEnvelope(
          id: '0192a000-0000-7000-8000-000000000112',
          workspaceId: ws,
          actorId: actor,
          deviceId: 't',
          hlc: Hlc(physical: 100, logical: 0),
          affectedNodeIds: [otherNode],
          opType: 'object.create',
          payload: {'objectId': otherNode, 'contentAst': const []},
          timestamp: '2026-09-24T12:00:00.000Z',
        ),
        OperationEnvelope(
          id: '0192a000-0000-7000-8000-000000000113',
          workspaceId: ws,
          actorId: actor,
          deviceId: 't',
          hlc: Hlc(physical: 101, logical: 0),
          affectedNodeIds: [carol],
          opType: 'propertySchema.create',
          payload: {
            'propertySchemaId': nicknameSchema,
            'name': 'nickname',
            'type': 'text',
            'multi': true,
          },
          timestamp: '2026-09-24T12:00:00.000Z',
        ),
        OperationEnvelope(
          id: '0192a000-0000-7000-8000-000000000114',
          workspaceId: ws,
          actorId: actor,
          deviceId: 't',
          hlc: Hlc(physical: 102, logical: 0),
          affectedNodeIds: [carol],
          opType: 'property.set',
          payload: {
            'objectId': carol,
            'propertySchemaId': nicknameSchema,
            'value': 'v',
            'elementId': alpha,
          },
          timestamp: '2026-09-24T12:00:00.000Z',
        ),
      ]) {
        await appliers.apply(envelope);
      }
      // The element lives under (carol, nickname); an unset addressed at
      // (otherNode, nickname) must not tombstone or delete it.
      await appliers.apply(OperationEnvelope(
        id: '0192a000-0000-7000-8000-000000000115',
        workspaceId: ws,
        actorId: actor,
        deviceId: 't',
        hlc: Hlc(physical: 200, logical: 0),
        affectedNodeIds: [otherNode],
        opType: 'property.unset',
        payload: {
          'objectId': otherNode,
          'propertySchemaId': nicknameSchema,
          'elementId': alpha,
        },
        timestamp: '2026-09-24T12:00:00.000Z',
      ));
      final visible = await cache.propertyValuesFor(carol);
      expect(visible.map((r) => r.elementId), [alpha]);
      final tomb = await raw(
        'SELECT COUNT(*) AS c FROM property_value_element_tombstone',
      );
      expect(tomb.single['c'], 0);
    });

    test('fixture class-property-active: soft-unbind via the row LWW',
        () async {
      final envelopes = fixtureEnvelopes('class-property-active.json');
      const pipelineClass = '0192a000-0000-7000-8000-000000000742';
      const dealNode = '0192a000-0000-7000-8000-000000000743';
      const stageSchema = '0192a000-0000-7000-8000-000000000741';

      // Apply through the disable (envelope 5, …736): the interleaved
      // enable (…735, lower HLC) loses the row LWW race.
      for (var i = 0; i <= 5; i++) {
        expect(await appliers.apply(envelopes[i]), isTrue);
      }
      final row = await raw(
        'SELECT active FROM class_property WHERE class_id = ? AND property_schema_id = ?',
        [pipelineClass, stageSchema],
      );
      expect(row.single['active'], 0);
      // The default vanishes from the effective read while no authored
      // value exists yet: Deal reads nothing bound.
      var effective = await cache.getEffectiveProperties(dealNode);
      expect(effective, isEmpty);

      // Authored while inactive: the value reads, boundBy null (unbound),
      // and the default stays suppressed.
      expect(await appliers.apply(envelopes[6]), isTrue);
      effective = await cache.getEffectiveProperties(dealNode);
      expect(effective.length, 1);
      expect(effective.single.value, 'opt-b');
      expect(effective.single.source, 'authored');
      expect(effective.single.boundBy, isNull);
      expect(effective.single.elementId,
          '$dealNode:$stageSchema:0');

      // The re-enable restores the binding: authored idx 0 still shadows
      // the default; the value now reads bound by Pipeline.
      expect(await appliers.apply(envelopes[7]), isTrue);
      final rowAfter = await raw(
        'SELECT active FROM class_property WHERE class_id = ? AND property_schema_id = ?',
        [pipelineClass, stageSchema],
      );
      expect(rowAfter.single['active'], 1);
      effective = await cache.getEffectiveProperties(dealNode);
      expect(effective.length, 1);
      expect(effective.single.boundBy, pipelineClass);
      expect(effective.single.value, 'opt-b');

      // Both-orders convergence for the enable/disable pair (…735/…736).
      await database.close();
      final ffiDb2 = await databaseFactoryFfi.openDatabase(
        ':memory:',
        options: OpenDatabaseOptions(singleInstance: false),
      );
      database = AppDatabase.fromDatabase(ffiDb2);
      await database.initializeSchema();
      cache = NodeCacheRepository(database);
      appliers = RelayAppliers(cache);
      final reversed = [...envelopes]..sort((a, b) {
          // Reverse HLC order delivery (stable on id for the pair).
          final delta = b.hlc.physical.compareTo(a.hlc.physical);
          return delta != 0 ? delta : b.id.compareTo(a.id);
        });
      for (final envelope in reversed) {
        await appliers.apply(envelope);
      }
      final rowReverse = await raw(
        'SELECT active FROM class_property WHERE class_id = ? AND property_schema_id = ?',
        [pipelineClass, stageSchema],
      );
      expect(rowReverse.single['active'], 1);
      final effectiveReverse = await cache.getEffectiveProperties(dealNode);
      final authoredIdx0 =
          effectiveReverse.where((e) => e.idx == 0).toList();
      expect(authoredIdx0.single.value, 'opt-b');
      expect(authoredIdx0.single.boundBy, pipelineClass);
    });

    test('PC6 fixture: qualifier refs verbatim, ISO strings normalize on write',
        () async {
      for (final envelope
          in fixtureEnvelopes('property-date-qualifier.json')) {
        expect(await appliers.apply(envelope), isTrue);
      }
      const club = '0192a000-0000-7000-8000-000000000763';
      final rows = await raw(
        'SELECT idx, metadata FROM property_value WHERE node_uuid = ? '
        'ORDER BY idx',
        [club],
      );
      expect(rows.length, 2);
      // idx 0: canonical date-node refs ride through verbatim.
      expect(
        jsonDecode(rows[0]['metadata'] as String),
        {
          'startDate': {'nodeId': '00000000-0000-0000-00dd-202003040000'},
          'endDate': {'nodeId': '00000000-0000-0000-00dd-202205060000'},
        },
      );
      // idx 1: the legacy ISO string normalized to the deterministic
      // day-node ref on write.
      expect(
        jsonDecode(rows[1]['metadata'] as String),
        {
          'startDate': {'nodeId': '00000000-0000-0000-00dd-201901150000'},
        },
      );
      // Read-leniency: both shapes decode for any reader.
      final visible = await cache.propertyValuesFor(club);
      expect(visible.length, 2);
      expect(
        (visible[0].metadata as Map<String, dynamic>)['startDate'],
        {'nodeId': '00000000-0000-0000-00dd-202003040000'},
      );
    });

    test('PC6 normalization is scoped: non-qualified schemas and non-date '
        'strings ride through', () async {
      const owner = '0192a000-0000-7000-8000-000000000881';
      const plainSchema = '0192a000-0000-7000-8000-000000000882';
      const qualifiedSchema = '0192a000-0000-7000-8000-000000000883';
      for (final envelope in [
        OperationEnvelope(
          id: '0192a000-0000-7000-8000-000000000870',
          workspaceId: ws,
          actorId: actor,
          deviceId: 't',
          hlc: Hlc(physical: 99, logical: 0),
          affectedNodeIds: [carol],
          opType: 'object.create',
          payload: {'objectId': carol, 'contentAst': const []},
          timestamp: '2026-09-24T12:00:00.000Z',
        ),
        OperationEnvelope(
          id: '0192a000-0000-7000-8000-000000000871',
          workspaceId: ws,
          actorId: actor,
          deviceId: 't',
          hlc: Hlc(physical: 100, logical: 0),
          affectedNodeIds: [owner],
          opType: 'object.create',
          payload: {'objectId': owner, 'contentAst': const []},
          timestamp: '2026-09-24T12:00:00.000Z',
        ),
        OperationEnvelope(
          id: '0192a000-0000-7000-8000-000000000872',
          workspaceId: ws,
          actorId: actor,
          deviceId: 't',
          hlc: Hlc(physical: 101, logical: 0),
          affectedNodeIds: const [],
          opType: 'propertySchema.create',
          payload: {
            'propertySchemaId': plainSchema,
            'name': 'plain',
            'type': 'object',
            'multi': true,
          },
          timestamp: '2026-09-24T12:00:00.000Z',
        ),
        OperationEnvelope(
          id: '0192a000-0000-7000-8000-000000000873',
          workspaceId: ws,
          actorId: actor,
          deviceId: 't',
          hlc: Hlc(physical: 102, logical: 0),
          affectedNodeIds: const [],
          opType: 'propertySchema.create',
          payload: {
            'propertySchemaId': qualifiedSchema,
            'name': 'qualified',
            'type': 'object',
            'multi': true,
            'dateQualified': true,
          },
          timestamp: '2026-09-24T12:00:00.000Z',
        ),
      ]) {
        await appliers.apply(envelope);
      }
      Future<void> setAt(
        String schema,
        int idx,
        Map<String, dynamic> metadata,
        int physical,
      ) =>
          appliers.apply(OperationEnvelope(
            id: '0192a000-0000-7000-8000-0000000008$physical',
            workspaceId: ws,
            actorId: actor,
            deviceId: 't',
            hlc: Hlc(physical: physical, logical: 0),
            affectedNodeIds: [owner],
            opType: 'property.set',
            payload: {
              'objectId': owner,
              'propertySchemaId': schema,
              'value': {'nodeId': carol},
              'idx': idx,
              'metadata': metadata,
            },
            timestamp: '2026-09-24T12:00:00.000Z',
          ));

      // Non-qualified schema: the ISO string stays a string.
      await setAt(plainSchema, 0, {'startDate': '2019-01-15'}, 200);
      // Qualified schema, well-formed string: normalizes.
      await setAt(qualifiedSchema, 0, {'startDate': '2019-01-15'}, 201);
      // Qualified schema, malformed date + non-reserved key: untouched.
      await setAt(qualifiedSchema, 1, {
        'startDate': '2019-13-45',
        'note': '2019-01-15',
      }, 202);

      final rows = await raw(
        'SELECT property_schema_id, metadata FROM property_value '
        'WHERE node_uuid = ? ORDER BY property_schema_id, idx',
        [owner],
      );
      expect(jsonDecode(rows[0]['metadata'] as String), {
        'startDate': '2019-01-15',
      });
      expect(jsonDecode(rows[1]['metadata'] as String), {
        'startDate': {'nodeId': '00000000-0000-0000-00dd-201901150000'},
      });
      expect(jsonDecode(rows[2]['metadata'] as String), {
        'startDate': '2019-13-45',
        'note': '2019-01-15',
      });
    });

    group('§34.45 unset-carrier trashing', () {
      const owner = '0192a000-0000-7000-8000-000000000901';
      const textSchema = '0192a000-0000-7000-8000-000000000902';
      const carrier = '0192a000-0000-7000-8000-000000000903';
      const numberSchema = '0192a000-0000-7000-8000-000000000904';

      Future<void> seedAll() async {
        for (final envelope in [
          OperationEnvelope(
            id: '0192a000-0000-7000-8000-000000000911',
            workspaceId: ws,
            actorId: actor,
            deviceId: 't',
            hlc: Hlc(physical: 100, logical: 0),
            affectedNodeIds: [owner],
            opType: 'object.create',
            payload: {
              'objectId': owner,
              'presentAsMain': true,
              'contentAst': const [],
            },
            timestamp: '2026-09-24T12:00:00.000Z',
          ),
          OperationEnvelope(
            id: '0192a000-0000-7000-8000-000000000912',
            workspaceId: ws,
            actorId: actor,
            deviceId: 't',
            hlc: Hlc(physical: 101, logical: 0),
            affectedNodeIds: [carrier],
            opType: 'object.create',
            payload: {
              'objectId': carrier,
              'parentId': owner,
              'contentAst': const [
                {'type': 'text', 'text': 'carrier block'},
              ],
            },
            timestamp: '2026-09-24T12:00:00.000Z',
          ),
          OperationEnvelope(
            id: '0192a000-0000-7000-8000-000000000913',
            workspaceId: ws,
            actorId: actor,
            deviceId: 't',
            hlc: Hlc(physical: 102, logical: 0),
            affectedNodeIds: const [],
            opType: 'propertySchema.create',
            payload: {
              'propertySchemaId': textSchema,
              'name': 'provenance',
              'type': 'text',
            },
            timestamp: '2026-09-24T12:00:00.000Z',
          ),
        ]) {
          await appliers.apply(envelope);
        }
      }

      Future<void> setValue(
        String schema,
        dynamic value, {
        String? elementId,
        int physical = 200,
      }) =>
          appliers.apply(OperationEnvelope(
            id: '0192a000-0000-7000-8000-00000000$physical',
            workspaceId: ws,
            actorId: actor,
            deviceId: 't',
            hlc: Hlc(physical: physical, logical: 0),
            affectedNodeIds: [owner],
            opType: 'property.set',
            payload: {
              'objectId': owner,
              'propertySchemaId': schema,
              'value': value,
              'elementId': ?elementId,
            },
            timestamp: '2026-09-24T12:00:00.000Z',
          ));

      Future<void> unsetValue(
        String schema, {
        String? elementId,
        int idx = 0,
        int physical = 300,
      }) =>
          appliers.apply(OperationEnvelope(
            id: '0192a000-0000-7000-8000-00000000$physical',
            workspaceId: ws,
            actorId: actor,
            deviceId: 't',
            hlc: Hlc(physical: physical, logical: 0),
            affectedNodeIds: [owner],
            opType: 'property.unset',
            payload: {
              'objectId': owner,
              'propertySchemaId': schema,
              'elementId': ?elementId,
              'idx': idx,
            },
            timestamp: '2026-09-24T12:00:00.000Z',
          ));

      test('positional unset of a node-backed text value trashes the carrier',
          () async {
        await seedAll();
        await setValue(textSchema, {'nodeId': carrier});
        await unsetValue(textSchema);
        final node = await cache.getByUuid(carrier);
        expect(node!.isArchived, isTrue);
        final trash = await raw(
          'SELECT COUNT(*) AS c FROM trash_root WHERE node_id = ?',
          [carrier],
        );
        expect(trash.single['c'], 1);
        // The owner survives; the value row is gone.
        expect((await cache.getByUuid(owner))!.isArchived, isFalse);
        expect(await cache.propertyValuesFor(owner), isEmpty);
      });

      test('element unset of a node-backed text value trashes the carrier',
          () async {
        await seedAll();
        const element = '0192a000-0000-7000-8000-000000000921';
        await setValue(textSchema, {'nodeId': carrier}, elementId: element);
        await unsetValue(textSchema, elementId: element);
        final node = await cache.getByUuid(carrier);
        expect(node!.isArchived, isTrue);
      });

      test('guard: still-referenced carrier survives', () async {
        await seedAll();
        const otherOwner = '0192a000-0000-7000-8000-000000000931';
        await appliers.apply(OperationEnvelope(
          id: '0192a000-0000-7000-8000-000000000932',
          workspaceId: ws,
          actorId: actor,
          deviceId: 't',
          hlc: Hlc(physical: 150, logical: 0),
          affectedNodeIds: [otherOwner],
          opType: 'object.create',
          payload: {'objectId': otherOwner, 'contentAst': const []},
          timestamp: '2026-09-24T12:00:00.000Z',
        ));
        await setValue(textSchema, {'nodeId': carrier});
        await setValue(
          textSchema,
          {'nodeId': carrier},
          elementId: '0192a000-0000-7000-8000-000000000933',
          physical: 201,
        );
        await unsetValue(textSchema);
        // The second row still references the carrier: it survives.
        expect((await cache.getByUuid(carrier))!.isArchived, isFalse);
      });

      test('guard: scalar text values carry no carrier', () async {
        await seedAll();
        await setValue(textSchema, 'plain scalar');
        await unsetValue(textSchema);
        expect((await cache.getByUuid(carrier))!.isArchived, isFalse);
      });

      test('guard: non-text schemas never trash', () async {
        await seedAll();
        await appliers.apply(OperationEnvelope(
          id: '0192a000-0000-7000-8000-000000000941',
          workspaceId: ws,
          actorId: actor,
          deviceId: 't',
          hlc: Hlc(physical: 103, logical: 0),
          affectedNodeIds: const [],
          opType: 'propertySchema.create',
          payload: {
            'propertySchemaId': numberSchema,
            'name': 'count',
            'type': 'number',
          },
          timestamp: '2026-09-24T12:00:00.000Z',
        ));
        await setValue(numberSchema, 42);
        await unsetValue(numberSchema);
        expect((await cache.getByUuid(carrier))!.isArchived, isFalse);
      });

      test('guard: a carrier that is not a child of the owner survives',
          () async {
        await seedAll();
        // Reparent the carrier elsewhere, then set/unset.
        const elsewhere = '0192a000-0000-7000-8000-000000000951';
        await appliers.apply(OperationEnvelope(
          id: '0192a000-0000-7000-8000-000000000952',
          workspaceId: ws,
          actorId: actor,
          deviceId: 't',
          hlc: Hlc(physical: 160, logical: 0),
          affectedNodeIds: [elsewhere],
          opType: 'object.create',
          payload: {'objectId': elsewhere, 'contentAst': const []},
          timestamp: '2026-09-24T12:00:00.000Z',
        ));
        await appliers.apply(OperationEnvelope(
          id: '0192a000-0000-7000-8000-000000000953',
          workspaceId: ws,
          actorId: actor,
          deviceId: 't',
          hlc: Hlc(physical: 161, logical: 0),
          affectedNodeIds: [carrier],
          opType: 'object.move',
          payload: {'objectId': carrier, 'parentId': elsewhere},
          timestamp: '2026-09-24T12:00:00.000Z',
        ));
        await setValue(textSchema, {'nodeId': carrier}, physical: 210);
        await unsetValue(textSchema, physical: 310);
        expect((await cache.getByUuid(carrier))!.isArchived, isFalse);
      });
    });
  });
}
