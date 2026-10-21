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

    test('datetime/object require a ref; legacy bare uuid normalizes; '
        'plain strings rejected', () async {
      const dateSchema = '0192a000-0000-7000-8000-000000000202';
      await createNode(owner);
      await createNode(target);
      await createSchema(dateSchema, 'datetime');
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

    test('datetime/object refs must resolve to a node row', () async {
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

    test('datetime ranges take both keys open/ref/slot; garbage sides '
        'rejected', () async {
      const rangeSchema = '0192a000-0000-7000-8000-000000000204';
      await createNode(owner);
      await createNode(target);
      await createSchema(rangeSchema, 'datetime');
      await setValue(rangeSchema, {
        'start': {'nodeId': target},
        'end': null,
      });
      var rows = await storedRows(rangeSchema);
      expect(jsonDecode(rows.single['value'] as String), {
        'start': {'nodeId': target},
        'end': null,
      });

      // A legacy bare-uuid side normalizes to the slot shape.
      await cache.deletePropertyValueById(
        NodeCacheRepository.positionalPropertyValueId(owner, rangeSchema, 0),
      );
      await setValue(rangeSchema, {'start': target, 'end': target});
      rows = await storedRows(rangeSchema);
      expect(jsonDecode(rows.single['value'] as String), {
        'start': {'nodeId': target},
        'end': {'nodeId': target},
      });

      // A both-open range is a legal value.
      await cache.deletePropertyValueById(
        NodeCacheRepository.positionalPropertyValueId(owner, rangeSchema, 0),
      );
      await setValue(rangeSchema, {'start': null, 'end': null});
      rows = await storedRows(rangeSchema);
      expect(jsonDecode(rows.single['value'] as String), {
        'start': null,
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
      // A non-uuid string side is not a reference.
      expect(
        () => setValue(rangeSchema, {'start': 'not-a-ref', 'end': null}),
        throwsA(isA<PropertyValueShapeError>()),
      );
    });

    test('datetime: a value carrying BOTH nodeId and start/end keys is '
        'rejected outright', () async {
      const pointSchema = '0192a000-0000-7000-8000-00000000020c';
      await createNode(owner);
      await createNode(target);
      await createSchema(pointSchema, 'datetime');
      for (final bad in [
        {
          'nodeId': target,
          'start': {'nodeId': target},
          'end': null,
        },
        {'nodeId': target, 'end': null},
      ]) {
        expect(
          () => setValue(pointSchema, bad),
          throwsA(isA<PropertyValueShapeError>()),
        );
      }
      expect(await storedRows(pointSchema), isEmpty);
    });

    test('datetime: a malformed time is rejected (points and range slots '
        'alike)', () async {
      const pointSchema = '0192a000-0000-7000-8000-00000000020d';
      const rangeSchema = '0192a000-0000-7000-8000-00000000020e';
      await createNode(owner);
      await createNode(target);
      await createSchema(pointSchema, 'datetime');
      await createSchema(rangeSchema, 'datetime');
      const dayNode = '00000000-0000-7000-8000-000000000102';
      for (final badTime in ['25:00', '9:30', '10:60', '14:30:00', 430, null]) {
        expect(
          () => setValue(pointSchema, {'nodeId': dayNode, 'time': badTime}),
          throwsA(isA<PropertyValueShapeError>()),
        );
        expect(
          () => setValue(rangeSchema, {
            'start': null,
            'end': {'nodeId': dayNode, 'time': badTime},
          }),
          throwsA(isA<PropertyValueShapeError>()),
        );
      }
    });

    test('datetime: time requires day precision on the slot\'s ref (a '
        'month/year anchor — or a non-date id — has no wall-clock time)',
        () async {
      const pointSchema = '0192a000-0000-7000-8000-00000000020f';
      const rangeSchema = '0192a000-0000-7000-8000-000000000210';
      await createNode(owner);
      await createSchema(pointSchema, 'datetime');
      await createSchema(rangeSchema, 'datetime');
      const monthNode = '00000000-0000-0000-00aa-202003000000';
      const yearNode = '00000000-0000-0000-00bb-202000000000';
      await createNode(monthNode);
      await createNode(yearNode);
      expect(
        () => setValue(pointSchema, {'nodeId': monthNode, 'time': '10:00'}),
        throwsA(isA<PropertyValueShapeError>()),
      );
      expect(
        () => setValue(rangeSchema, {
          'start': {'nodeId': yearNode, 'time': '10:00'},
          'end': null,
        }),
        throwsA(isA<PropertyValueShapeError>()),
      );
      // A timed ref to a plain (non-date) node fails the day-anchor
      // requirement too.
      expect(
        () => setValue(pointSchema, {'nodeId': owner, 'time': '10:00'}),
        throwsA(isA<PropertyValueShapeError>()),
      );
    });

    test('datetime: a well-formed timed point round-trips verbatim', () async {
      const pointSchema = '0192a000-0000-7000-8000-000000000211';
      await createNode(owner);
      await createSchema(pointSchema, 'datetime');
      const dayNode = '00000000-0000-0000-00dd-202407260000';
      await createNode(dayNode);
      await setValue(pointSchema, {'nodeId': dayNode, 'time': '14:30'});
      final rows = await storedRows(pointSchema);
      expect(jsonDecode(rows.single['value'] as String), {
        'nodeId': dayNode,
        'time': '14:30',
      });
    });

    test('datetime: each non-null range slot ref gets the existence check '
        '(a ghost slot fails loud, open sides skip)', () async {
      const rangeSchema = '0192a000-0000-7000-8000-000000000212';
      await createNode(owner);
      await createNode(target);
      await createSchema(rangeSchema, 'datetime');
      // A valid day-node id with no node row (the date_range parity: either
      // end missing fails, open sides skip).
      const ghost = '00000000-0000-0000-00dd-202801150000';
      expect(
        () => setValue(rangeSchema, {'start': {'nodeId': ghost}, 'end': null}),
        throwsA(
          isA<PropertyValueShapeError>().having(
            (e) => e.message,
            'message',
            contains('does not exist'),
          ),
        ),
      );
      expect(
        () => setValue(rangeSchema, {
          'start': null,
          'end': {'nodeId': ghost, 'time': '12:00'},
        }),
        throwsA(isA<PropertyValueShapeError>()),
      );
      // Open sides store fine (no ref to check).
      await setValue(rangeSchema, {'start': null, 'end': null});
      final rows = await storedRows(rangeSchema);
      expect(jsonDecode(rows.single['value'] as String), {
        'start': null,
        'end': null,
      });
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
      await createSchema(dateSchema, 'datetime');
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

    test('datePrecision ceiling: a datetime ref may not claim finer '
        'granularity than the schema', () async {
      const dateSchema = '0192a000-0000-7000-8000-000000000330';
      await createNode(owner);
      await createSchema(dateSchema, 'datetime', multi: true, datePrecision: 'month');
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
      await createSchema(daySchema, 'datetime');
      await setValue(daySchema, {'nodeId': dayNode});
    });
  });

  group('PC2 default typing + the read-side drop (schema-level defaults, '
      'owner ruling 2026-10-20)', () {
    const numberSchema = '0192a000-0000-7000-8000-000000000401';
    const klass = '0192a000-0000-7000-8000-000000000402';

    /// Writes the schema's GLOBAL default (owner ruling 2026-10-20 — the
    /// default moved from the binding to the schema; keep/clear: absent
    /// keeps, an explicit null clears).
    Future<void> writeDefault(
      String schemaId,
      dynamic defaultValue,
    ) =>
        apply(env(
          'propertySchema.update',
          OperationPayloads.propertySchemaUpdate(
            propertySchemaId: schemaId,
            defaultValue: defaultValue,
          ),
        ));

    test('propertySchema.update fails loud on a wrong-typed default '
        '(validated against the STORED type)', () async {
      await createSchema(numberSchema, 'number');
      expect(
        () => writeDefault(numberSchema, 'abc'),
        throwsA(
          isA<PropertyValueShapeError>().having(
            (e) => e.message,
            'message',
            contains('must be typed number'),
          ),
        ),
      );
      await writeDefault(numberSchema, 7);
    });

    test('a create-time default validates against the payload type', () async {
      const textSchema = '0192a000-0000-7000-8000-000000000406';
      expect(
        () => apply(env(
          'propertySchema.create',
          OperationPayloads.propertySchemaCreate(
            propertySchemaId: textSchema,
            name: 'slot',
            type: 'text',
            defaultValue: 42,
          ),
        )),
        throwsA(isA<PropertyValueShapeError>()),
      );
      await apply(env(
        'propertySchema.create',
        OperationPayloads.propertySchemaCreate(
          propertySchemaId: textSchema,
          name: 'slot',
          type: 'text',
          defaultValue: 'from-create',
        ),
      ));
      final db = await database.database;
      final rows = await db.rawQuery(
        'SELECT default_value FROM property_schema WHERE uuid = ?',
        [textSchema],
      );
      expect(jsonDecode(rows.single['default_value'] as String), 'from-create');
    });

    test('node-typed schemas accept only a null default', () async {
      const dateSchema = '0192a000-0000-7000-8000-000000000403';
      await createSchema(dateSchema, 'datetime');
      expect(
        () => writeDefault(dateSchema, 'x'),
        throwsA(isA<PropertyValueShapeError>()),
      );
      // An EXPLICIT null default CLEARS (the keep/clear contract — SQL
      // NULL, the canonical "no default" spelling) and passes the check.
      await writeDefault(dateSchema, null);
      final db = await database.database;
      final rows = await db.rawQuery(
        'SELECT default_value FROM property_schema WHERE uuid = ?',
        [dateSchema],
      );
      expect(rows.single['default_value'], isNull);
    });

    test('an unknown schema id stores the default unchecked', () async {
      const unknown = '0192a000-0000-7000-8000-000000000404';
      await apply(env(
        'propertySchema.update',
        OperationPayloads.propertySchemaUpdate(
          propertySchemaId: unknown,
          defaultValue: {'any': 'thing'},
        ),
      ));
    });

    test('a stale class.property.set is dropped before any write', () async {
      await createSchema(numberSchema, 'number');
      // First binding at the seeded clock (~101); a stale retry (older
      // HLC) is LWW-dropped, exactly like the TS reference (the binding
      // carries no default anymore — nothing to validate).
      await apply(env(
        'class.property.set',
        OperationPayloads.classPropertySet(
          classId: klass,
          propertySchemaId: numberSchema,
        ),
      ));
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
          active: true,
        ),
        timestamp: '2026-10-04T12:00:00.000Z',
      );
      expect(await appliers.apply(stale), isFalse); // dropped silently
    });

    test('the effective read drops a stored default whose schema type '
        'drifted (delete + recreate at another type)', () async {
      const textSchema = '0192a000-0000-7000-8000-000000000405';
      await createSchema(textSchema, 'text');
      await apply(env(
        'class.create',
        OperationPayloads.classCreate(classId: klass, name: 'klass'),
      ));
      await apply(env(
        'class.property.set',
        OperationPayloads.classPropertySet(
          classId: klass,
          propertySchemaId: textSchema,
        ),
      ));
      // The default is schema-level (owner ruling 2026-10-20): a wrong-typed
      // write fails loud at the schema, so the drift arm below is purely the
      // delete+recreate path (the recreate carries no default → clears).
      await writeDefault(textSchema, 'not-a-number');
      await createNode(owner, classIds: [klass]);
      var rows = await cache.getEffectiveProperties(owner);
      expect(rows.single.value, 'not-a-number');

      // Recreate the schema at the same id with a different type: the
      // create replaces the row (default cleared), so nothing derives.
      await apply(env(
        'propertySchema.delete',
        OperationPayloads.propertySchemaDelete(propertySchemaId: textSchema),
      ));
      await createSchema(textSchema, 'number');
      rows = await cache.getEffectiveProperties(owner);
      expect(rows, isEmpty);
    });
  });

  group('R2 validationRules value enforcement (owner ruling 2026-10-20)', () {
    const numberSchema = '0192a000-0000-7000-8000-000000000301';
    const textSchema = '0192a000-0000-7000-8000-000000000302';
    const urlSchema = '0192a000-0000-7000-8000-000000000303';
    const keywordsSchema = '0192a000-0000-7000-8000-000000000304';

    Future<void> setRules(String schemaId, Map<String, dynamic> rules) => apply(
          env(
            'propertySchema.update',
            OperationPayloads.propertySchemaUpdate(
              propertySchemaId: schemaId,
              validationRules: rules,
            ),
          ),
        );

    test('number min/max bound the value inclusively, after the '
        'numeric-string normalization', () async {
      await createNode(owner);
      await createSchema(numberSchema, 'number');
      await setRules(numberSchema, {'min': 1, 'max': 5});
      // Inclusive bounds: exactly min / exactly max ride (the single-value
      // slot is LWW at idx 0 — each write replaces the previous one).
      await setValue(numberSchema, 1);
      await setValue(numberSchema, 5);
      // A legacy numeric string normalizes BEFORE the rule check, so "4"
      // (the string) passes and stores as a number.
      await setValue(numberSchema, '4');
      var rows = await storedRows(numberSchema);
      expect(rows, hasLength(1));
      expect(jsonDecode(rows.single['value'] as String), 4);
      // Out of bounds fails loud and stores nothing.
      expect(() => setValue(numberSchema, 0),
          throwsA(isA<PropertyValueShapeError>()));
      expect(() => setValue(numberSchema, 6),
          throwsA(isA<PropertyValueShapeError>()));
      expect(jsonDecode((await storedRows(numberSchema)).single['value'] as String),
          4);
      // Clearing the rules (present-null) restores the unchecked write.
      await apply(env(
        'propertySchema.update',
        {
          'propertySchemaId': numberSchema,
          'validationRules': null,
        },
      ));
      await setValue(numberSchema, 100);
      rows = await storedRows(numberSchema);
      expect(jsonDecode(rows.single['value'] as String), 100);
    });

    test('text/url/email full-string-test scalars against the pattern; '
        'carrier refs and rule-free schemas ride unchecked', () async {
      await createNode(owner);
      await createNode(target);
      await createSchema(textSchema, 'text');
      await createSchema(urlSchema, 'url');
      await setRules(textSchema, {'pattern': '[a-z0-9-]+'});
      await setRules(urlSchema, {'pattern': 'https://.+'});
      await setValue(textSchema, 'hello-world');
      await setValue(urlSchema, 'https://example.com');
      // A substring match is NOT a full-string match (implicit anchors).
      expect(() => setValue(textSchema, 'Hello World'),
          throwsA(isA<PropertyValueShapeError>()));
      expect(() => setValue(urlSchema, 'ftp://example.com'),
          throwsA(isA<PropertyValueShapeError>()));
      // A text carrier ref {nodeId} is not a scalar string — the shape
      // family owns refs; the rule check skips it.
      await setValue(textSchema, {'nodeId': target});
      // A rule-free schema stays unchecked.
      await createSchema(keywordsSchema, 'text', multi: true);
      await setValue(keywordsSchema, 'ANYTHING at all! 123', idx: 0);
    });

    test('a multi batch validates each element at its own add — one bad '
        'element rejects its op while the survivors stay', () async {
      await createNode(owner);
      await createSchema(keywordsSchema, 'text', multi: true);
      await setRules(keywordsSchema, {'pattern': '[a-z]+'});
      await setValue(keywordsSchema, 'good',
          idx: 0, elementId: '0192a000-0000-7000-8000-000000000311');
      expect(
        () => setValue(keywordsSchema, 'BAD1',
            idx: 1, elementId: '0192a000-0000-7000-8000-000000000312'),
        throwsA(isA<PropertyValueShapeError>()),
      );
      final rows = await storedRows(keywordsSchema);
      expect(rows, hasLength(1));
      expect(jsonDecode(rows.single['value'] as String), 'good');
    });

    test('a non-compilable stored pattern fails loud at value-check time '
        '(corrupt config is never an applier crash)', () async {
      await createNode(owner);
      await createSchema(textSchema, 'text');
      // Seed a corrupt column directly — the rule WRITE path refuses to
      // store a non-compilable pattern, so this is only reachable from a
      // hand-edited/legacy store.
      final db = await database.database;
      await db.update(
        'property_schema',
        {'validation_rules': jsonEncode({'pattern': '([a-z'})},
        where: 'uuid = ?',
        whereArgs: [textSchema],
      );
      expect(() => setValue(textSchema, 'anything'),
          throwsA(isA<PropertyValueShapeError>()));
      // ...and the rule write itself fails loud before storing.
      expect(() => setRules(textSchema, {'pattern': '([a-z'}),
          throwsA(isA<PropertyValueShapeError>()));
    });
  });
}
