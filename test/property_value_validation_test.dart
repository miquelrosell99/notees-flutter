import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:notees/data/local/app_database.dart';
import 'package:notees/data/repositories/node_cache_repository.dart';
import 'package:notees/domain/models/relay/hlc.dart';
import 'package:notees/domain/models/relay/operation_envelope.dart';
import 'package:notees/domain/models/relay/operation_payloads.dart';
import 'package:notees/domain/models/relay/store_errors.dart';
import 'package:notees/domain/services/relay_appliers.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

/// Acceptance for the PG6 apply-time value validation port
/// (`packages/store/src/property-values.ts` → property_value_shapes.dart +
/// the repository graph checks), hooked into the property.set /
/// class.property.set appliers:
///
///  - one-shape-per-type with fail-loud rejection, the legacy encodings
///    (bare-uuid refs, numeric strings) normalizing to the canonical shape
///    AT WRITE (the stored row carries the normalized value);
///  - image values deliberately unchecked (the PG14 zombie row) and
///    unknown schema ids storing unchecked (property.set has no schema FK);
///  - cardinality: a single-value schema takes idx 0 only;
///  - datePrecision ceiling + targetClassFilter (extends-aware membership)
///    + node-target existence with trash counting;
///  - PC2 class.property.set default typing, and the effective read model's
///    defensive drop of a stored default whose type drifted.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  sqfliteFfiInit();

  const ws = '0192a000-0000-7000-8000-000000000001';
  const actor = '0192a000-0000-7000-8000-000000000002';
  const owner = '0192a000-0000-7000-8000-000000000101';
  const target = '0192a000-0000-7000-8000-000000000102';

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

  var clock = 100;

  OperationEnvelope env(String opType, Map<String, dynamic> payload) {
    clock += 1;
    return OperationEnvelope(
      id: '0192a000-0000-7000-8000-${clock.toString().padLeft(12, '0')}',
      workspaceId: ws,
      actorId: actor,
      deviceId: 't',
      hlc: Hlc(physical: clock, logical: 0),
      affectedNodeIds: [owner],
      opType: opType,
      payload: payload,
      timestamp: '2026-10-04T12:00:00.000Z',
    );
  }

  Future<void> apply(OperationEnvelope envelope) => appliers.apply(envelope);

  Future<void> createSchema(
    String id,
    String type, {
    bool multi = false,
    List<String>? targetClassFilter,
    String? datePrecision,
  }) =>
      apply(env(
        'propertySchema.create',
        {
          'propertySchemaId': id,
          'name': 's-$id',
          'type': type,
          'multi': multi,
          'targetClassFilter': ?targetClassFilter,
          'datePrecision': ?datePrecision,
        },
      ));

  Future<void> createNode(String id, {List<String>? classIds}) => apply(env(
        'object.create',
        {
          'objectId': id,
          'classIds': ?classIds,
          'contentAst': const [],
        },
      ));

  Future<void> setValue(
    String schemaId,
    dynamic value, {
    int idx = 0,
    String? elementId,
  }) =>
      apply(env(
        'property.set',
        OperationPayloads.propertySet(
          objectId: owner,
          propertySchemaId: schemaId,
          value: value,
          idx: idx,
          elementId: elementId,
        ),
      ));

  Future<List<Map<String, dynamic>>> storedRows(String schemaId) async {
    final db = await database.database;
    return db.rawQuery(
      'SELECT value FROM property_value WHERE node_uuid = ? AND '
      'property_schema_id = ? ORDER BY idx',
      [owner, schemaId],
    );
  }

  setUp(() => clock = 100);

  group('PG6 shape/scalar typing', () {
    const textSchema = '0192a000-0000-7000-8000-000000000201';

    test('text accepts a string or a node ref; a uuid-SHAPED string stays a '
        'scalar string (reads stay lenient, writes store as authored)', () async {
      await createNode(owner);
      await createSchema(textSchema, 'text', multi: true);
      await setValue(textSchema, 'plain', idx: 0);
      await setValue(textSchema, {'nodeId': target}, idx: 1, elementId: target);
      await setValue(textSchema, target, idx: 2, elementId: owner);
      final rows = await storedRows(textSchema);
      expect(jsonDecode(rows[0]['value'] as String), 'plain');
      expect(jsonDecode(rows[1]['value'] as String), {'nodeId': target});
      // One-shape-per-type: a string is a string, even uuid-shaped.
      expect(jsonDecode(rows[2]['value'] as String), target);
    });

    test('text rejects numbers, booleans and non-ref objects', () async {
      await createNode(owner);
      await createSchema(textSchema, 'text');
      for (final bad in [42, true, <String, dynamic>{}]) {
        expect(
          () => setValue(textSchema, bad),
          throwsA(isA<PropertyValueShapeError>()),
        );
      }
      expect(await storedRows(textSchema), isEmpty);
    });

    test('date/object require a ref; legacy bare uuid normalizes; plain '
        'strings rejected', () async {
      const dateSchema = '0192a000-0000-7000-8000-000000000202';
      await createNode(owner);
      await createNode(target);
      await createSchema(dateSchema, 'date');
      await setValue(dateSchema, {'nodeId': target});
      var rows = await storedRows(dateSchema);
      expect(jsonDecode(rows.single['value'] as String), {'nodeId': target});

      // Legacy bare-uuid encoding rewrites to the canonical ref.
      await cache.deletePropertyValueById(
        NodeCacheRepository.positionalPropertyValueId(owner, dateSchema, 0),
      );
      await setValue(dateSchema, target);
      rows = await storedRows(dateSchema);
      expect(jsonDecode(rows.single['value'] as String), {'nodeId': target});

      // A scalar is not a node reference.
      expect(
        () => setValue(dateSchema, 'not-a-ref'),
        throwsA(isA<PropertyValueShapeError>()),
      );
    });

    test('date/object refs must resolve to a node row', () async {
      const objectSchema = '0192a000-0000-7000-8000-000000000203';
      await createNode(owner);
      await createSchema(objectSchema, 'object');
      expect(
        () => setValue(objectSchema, {'nodeId': target}),
        throwsA(
          isA<PropertyValueShapeError>().having(
            (e) => e.message,
            'message',
            contains('which does not exist'),
          ),
        ),
      );
    });

    test('date_range takes both keys open/ref; garbage sides rejected', () async {
      const rangeSchema = '0192a000-0000-7000-8000-000000000204';
      await createNode(owner);
      await createNode(target);
      await createSchema(rangeSchema, 'date_range');
      await setValue(rangeSchema, {
        'start': {'nodeId': target},
        'end': null,
      });
      var rows = await storedRows(rangeSchema);
      expect(jsonDecode(rows.single['value'] as String), {
        'start': {'nodeId': target},
        'end': null,
      });

      // An absent side key is the TS `undefined` — the shape requires both.
      expect(
        () => setValue(rangeSchema, {
          'start': {'nodeId': target},
        }),
        throwsA(isA<PropertyValueShapeError>()),
      );
      expect(
        () => setValue(rangeSchema, {
          'start': {'nodeId': target},
          'end': 42,
        }),
        throwsA(isA<PropertyValueShapeError>()),
      );
    });

    test('number accepts finite numbers and normalizes numeric strings '
        '(the epoch-millis legacy)', () async {
      const numberSchema = '0192a000-0000-7000-8000-000000000205';
      await createNode(owner);
      await createSchema(numberSchema, 'number', multi: true);
      await setValue(numberSchema, 1727200012000, idx: 0);
      await setValue(numberSchema, '1727200012001', idx: 1, elementId: target);
      await setValue(numberSchema, '  42  ', idx: 2, elementId: owner);
      final rows = await storedRows(numberSchema);
      expect(jsonDecode(rows[0]['value'] as String), 1727200012000);
      expect(jsonDecode(rows[1]['value'] as String), 1727200012001);
      expect(jsonDecode(rows[2]['value'] as String), 42);

      for (final bad in ['abc', '', true]) {
        expect(
          () => setValue(numberSchema, bad),
          throwsA(isA<PropertyValueShapeError>()),
        );
      }
    });

    test('boolean/url/email/select are typed; multi_select is a string list',
        () async {
      const boolSchema = '0192a000-0000-7000-8000-000000000206';
      const urlSchema = '0192a000-0000-7000-8000-000000000207';
      const selectSchema = '0192a000-0000-7000-8000-000000000208';
      const multiSchema = '0192a000-0000-7000-8000-000000000209';
      await createNode(owner);
      await createSchema(boolSchema, 'boolean');
      await createSchema(urlSchema, 'url');
      await createSchema(selectSchema, 'select');
      await createSchema(multiSchema, 'multi_select');
      await setValue(boolSchema, true);
      await setValue(urlSchema, 'https://example.com');
      await setValue(selectSchema, 'opt-1');
      await setValue(multiSchema, ['a', 'b']);
      expect(
        () => setValue(boolSchema, 'true'),
        throwsA(isA<PropertyValueShapeError>()),
      );
      expect(
        () => setValue(urlSchema, 42),
        throwsA(isA<PropertyValueShapeError>()),
      );
      expect(
        () => setValue(selectSchema, ['opt-1']),
        throwsA(isA<PropertyValueShapeError>()),
      );
      expect(
        () => setValue(multiSchema, ['a', 1]),
        throwsA(isA<PropertyValueShapeError>()),
      );
    });

    test('image values are deliberately unchecked (any shape stores)', () async {
      const imageSchema = '0192a000-0000-7000-8000-00000000020a';
      await createNode(owner);
      await createSchema(imageSchema, 'image', multi: true);
      await setValue(imageSchema, 42, idx: 0);
      await setValue(imageSchema, {'asset': 'x'}, idx: 1, elementId: target);
      await setValue(imageSchema, target, idx: 2, elementId: owner);
      final rows = await storedRows(imageSchema);
      expect(rows, hasLength(3));
    });

    test('unknown schema ids store unchecked', () async {
      await createNode(owner);
      const unknown = '0192a000-0000-7000-8000-0000000002ff';
      await setValue(unknown, {'any': 'shape'});
      final rows = await storedRows(unknown);
      expect(jsonDecode(rows.single['value'] as String), {'any': 'shape'});
    });

    test('a null value bypasses validation and stores JSON null', () async {
      const dateSchema = '0192a000-0000-7000-8000-00000000020b';
      await createNode(owner);
      await createSchema(dateSchema, 'date');
      await setValue(dateSchema, null);
      final rows = await storedRows(dateSchema);
      expect(jsonDecode(rows.single['value'] as String), isNull);
    });
  });

  group('PG6 schema-linked integrity', () {
    const agentClass = '0192a000-0000-7000-8000-000000000301';
    const personClass = '0192a000-0000-7000-8000-000000000302';
    const refSchema = '0192a000-0000-7000-8000-000000000310';

    test('cardinality: a single-value schema takes idx 0 only', () async {
      const singleSchema = '0192a000-0000-7000-8000-000000000311';
      await createNode(owner);
      await createSchema(singleSchema, 'text');
      expect(
        () => setValue(singleSchema, 'x', idx: 1),
        throwsA(
          isA<PropertyValueShapeError>().having(
            (e) => e.message,
            'message',
            contains('is single-value'),
          ),
        ),
      );
      // Multi-value schemas take higher slots.
      const multiSchema = '0192a000-0000-7000-8000-000000000312';
      await createSchema(multiSchema, 'text', multi: true);
      await setValue(multiSchema, 'x', idx: 1);
    });

    test('targetClassFilter is extends-aware: a carried class satisfies a '
        'filter entry it descends from', () async {
      await createNode(owner);
      await createSchema(refSchema, 'object',
          multi: true, targetClassFilter: [agentClass]);
      await apply(env(
        'class.create',
        OperationPayloads.classCreate(classId: agentClass, name: 'agent'),
      ));
      // person EXTENDS agent.
      await apply(env(
        'class.create',
        OperationPayloads.classCreate(classId: personClass, name: 'person'),
      ));
      await apply(env(
        'class.setExtends',
        OperationPayloads.classSetExtends(
          classId: personClass,
          parentClassIds: [agentClass],
        ),
      ));
      final person = '0192a000-0000-7000-8000-000000000320';
      await createNode(person, classIds: [personClass]);

      // Direct membership satisfies.
      final direct = '0192a000-0000-7000-8000-000000000322';
      await createNode(direct, classIds: [agentClass]);
      await setValue(refSchema, {'nodeId': direct});

      // Extends-descended membership satisfies.
      await setValue(refSchema, {'nodeId': person}, idx: 1, elementId: person);

      // A node carrying no filter class fails.
      final classless = '0192a000-0000-7000-8000-000000000324';
      await createNode(classless);
      expect(
        () => setValue(refSchema, {'nodeId': classless}, idx: 2),
        throwsA(
          isA<PropertyValueShapeError>().having(
            (e) => e.message,
            'message',
            contains('allowed classes'),
          ),
        ),
      );
    });

    test('trash is a state, not an absence: a trashed target still exists',
        () async {
      await createNode(owner);
      await createSchema(refSchema, 'object');
      await createNode(target);
      await apply(env(
        'object.delete',
        OperationPayloads.objectDelete(objectId: target, permanent: false),
      ));
      await setValue(refSchema, {'nodeId': target});
      final rows = await storedRows(refSchema);
      expect(jsonDecode(rows.single['value'] as String), {'nodeId': target});
    });

    test('datePrecision ceiling: a date ref may not claim finer granularity '
        'than the schema', () async {
      const dateSchema = '0192a000-0000-7000-8000-000000000330';
      await createNode(owner);
      await createSchema(dateSchema, 'date', multi: true, datePrecision: 'month');
      const dayNode = '00000000-0000-0000-00dd-202003040000';
      const monthNode = '00000000-0000-0000-00aa-202003000000';
      const yearNode = '00000000-0000-0000-00bb-202000000000';
      await createNode(dayNode);
      await createNode(monthNode);
      await createNode(yearNode);

      await setValue(dateSchema, {'nodeId': monthNode});
      await setValue(dateSchema, {'nodeId': yearNode}, idx: 1, elementId: yearNode);
      expect(
        () => setValue(dateSchema, {'nodeId': dayNode}, idx: 2),
        throwsA(
          isA<PropertyValueShapeError>().having(
            (e) => e.message,
            'message',
            contains('finer granularity'),
          ),
        ),
      );

      // Null precision reads as day: a day ref is at the ceiling, not over.
      const daySchema = '0192a000-0000-7000-8000-000000000331';
      await createSchema(daySchema, 'date');
      await setValue(daySchema, {'nodeId': dayNode});
    });
  });

  group('PC2 default typing + the read-side drop', () {
    const numberSchema = '0192a000-0000-7000-8000-000000000401';
    const klass = '0192a000-0000-7000-8000-000000000402';

    Future<void> bindDefault(
      String schemaId,
      dynamic defaultValue,
    ) =>
        apply(env(
          'class.property.set',
          OperationPayloads.classPropertySet(
            classId: klass,
            propertySchemaId: schemaId,
            sequence: 0,
            defaultValue: defaultValue,
          ),
        ));

    test('a wrong-typed defaultValue fails loud at class.property.set',
        () async {
      await createSchema(numberSchema, 'number');
      expect(
        () => bindDefault(numberSchema, 'abc'),
        throwsA(
          isA<PropertyValueShapeError>().having(
            (e) => e.message,
            'message',
            contains('must be typed number'),
          ),
        ),
      );
      await bindDefault(numberSchema, 7);
    });

    test('node-typed schemas accept only a null default', () async {
      const dateSchema = '0192a000-0000-7000-8000-000000000403';
      await createSchema(dateSchema, 'date');
      expect(
        () => bindDefault(dateSchema, 'x'),
        throwsA(isA<PropertyValueShapeError>()),
      );
      // An EXPLICIT null default rides the wire (the payload builder's
      // null-aware key drop can't express it — hand-built, like the relay
      // would deliver it) and passes the check.
      await apply(env('class.property.set', {
        'classId': klass,
        'propertySchemaId': dateSchema,
        'defaultValue': null,
      }));
    });

    test('an unknown schema id skips the default check', () async {
      const unknown = '0192a000-0000-7000-8000-000000000404';
      await bindDefault(unknown, {'any': 'thing'});
    });

    test('a stale class.property.set is dropped before the check', () async {
      await createSchema(numberSchema, 'number');
      // First binding at the seeded clock (~101); a stale retry (older
      // HLC) with a bad default is LWW-dropped before validation, exactly
      // like the TS reference (validation rides behind the stale guard).
      await bindDefault(numberSchema, 1);
      final stale = OperationEnvelope(
        id: '0192a000-0000-7000-8000-000000000599',
        workspaceId: ws,
        actorId: actor,
        deviceId: 't',
        hlc: const Hlc(physical: 50, logical: 0),
        affectedNodeIds: [owner],
        opType: 'class.property.set',
        payload: OperationPayloads.classPropertySet(
          classId: klass,
          propertySchemaId: numberSchema,
          sequence: 0,
          defaultValue: 'bad',
        ),
        timestamp: '2026-10-04T12:00:00.000Z',
      );
      await apply(stale); // dropped silently — no throw
    });

    test('the effective read drops a stored default whose schema type '
        'drifted (delete + recreate at another type)', () async {
      const textSchema = '0192a000-0000-7000-8000-000000000405';
      await createSchema(textSchema, 'text');
      await apply(env(
        'class.create',
        OperationPayloads.classCreate(classId: klass, name: 'klass'),
      ));
      await bindDefault(textSchema, 'not-a-number');
      await createNode(owner, classIds: [klass]);
      var rows = await cache.getEffectiveProperties(owner);
      expect(rows.single.value, 'not-a-number');

      // Recreate the schema at the same id with a different type: the
      // stored default no longer matches — the read yields no default.
      await apply(env(
        'propertySchema.delete',
        OperationPayloads.propertySchemaDelete(propertySchemaId: textSchema),
      ));
      await createSchema(textSchema, 'number');
      rows = await cache.getEffectiveProperties(owner);
      expect(rows, isEmpty);
    });
  });
}
