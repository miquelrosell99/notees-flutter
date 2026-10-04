import 'package:flutter_test/flutter_test.dart';
import 'package:notees/data/local/app_database.dart';
import 'package:notees/data/repositories/node_cache_repository.dart';
import 'package:notees/domain/models/relay/hlc.dart';
import 'package:notees/domain/models/relay/operation_envelope.dart';
import 'package:notees/domain/models/relay/operation_payloads.dart';
import 'package:notees/domain/services/relay_appliers.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

/// Acceptance for the §34.32 PG4 extends-aware binding resolution port
/// (`packages/store/src/effective.ts`): the winning binding per schema is
/// discovered by BFS over class_extends (own binding = distance 0), the
/// winner minimizing (distance, class-assignment HLC, class id), and
/// `boundBy` names the ANCESTOR whose class_property row supplies the
/// binding + default. With no extends edges this reduces exactly to
/// first-class-applied-wins over own bindings.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  sqfliteFfiInit();

  const ws = '0192a000-0000-7000-8000-000000000001';
  const actor = '0192a000-0000-7000-8000-000000000002';
  const node = '0192a000-0000-7000-8000-000000000001';
  const schema = '0192a000-0000-7000-8000-000000000010';

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

  var clock = 0;

  OperationEnvelope env(String opType, Map<String, dynamic> payload, int hlc) {
    clock += 1;
    return OperationEnvelope(
      id: '0192a000-0000-7000-8000-${(1000 + clock).toString().padLeft(12, '0')}',
      workspaceId: ws,
      actorId: actor,
      deviceId: 't',
      hlc: Hlc(physical: hlc, logical: 0),
      affectedNodeIds: [node],
      opType: opType,
      payload: payload,
      timestamp: '2026-10-04T12:00:00.000Z',
    );
  }

  Future<void> createSchema() => appliers.apply(env(
        'propertySchema.create',
        OperationPayloads.propertySchemaCreate(
          propertySchemaId: schema,
          name: 's',
          type: 'select',
          options: const [
            {'id': 'a', 'label': 'A'},
            {'id': 'b', 'label': 'B'},
          ],
        ),
        1,
      ));

  Future<void> createClass(String classId, {String? name}) => appliers.apply(
        env(
          'class.create',
          OperationPayloads.classCreate(
            classId: classId,
            name: name ?? 'c-$classId',
          ),
          1,
        ),
      );

  Future<void> bind(
    String classId,
    String defaultValue, {
    int hlc = 5,
    bool? active,
  }) =>
      appliers.apply(env(
        'class.property.set',
        {
          'classId': classId,
          'propertySchemaId': schema,
          'sequence': 0,
          'defaultValue': defaultValue,
          'active': ?active,
        },
        hlc,
      ));

  Future<void> setExtends(String classId, List<String> parents) =>
      appliers.apply(env(
        'class.setExtends',
        OperationPayloads.classSetExtends(
          classId: classId,
          parentClassIds: parents,
        ),
        1,
      ));

  /// Assigns [classIds] in order: the first batch rides the node's create,
  /// each later batch a re-issued create at the given HLCs.
  Future<void> assign(
    List<String> classIds,
    List<int> assignmentHlcs,
  ) async {
    assert(classIds.length == assignmentHlcs.length);
    await appliers.apply(env(
      'object.create',
      OperationPayloads.objectCreate(
        objectId: node,
        classIds: [classIds.first],
        contentAst: const [],
      ),
      assignmentHlcs.first,
    ));
    for (var i = 1; i < classIds.length; i++) {
      await appliers.apply(env(
        'object.create',
        OperationPayloads.objectCreate(
          objectId: node,
          classIds: [classIds[i]],
        ),
        assignmentHlcs[i],
      ));
    }
  }

  Future<EffectiveProperty> effectiveRow() async {
    final rows = await cache.getEffectiveProperties(node);
    expect(rows, hasLength(1), reason: 'exactly one effective row');
    return rows.single;
  }

  setUp(() => clock = 0);

  test('an inherited-only binding derives, boundBy naming the supplying '
      'ancestor', () async {
    const sub = '0192a000-0000-7000-8000-000000000100';
    const base = '0192a000-0000-7000-8000-000000000101';
    await createSchema();
    await createClass(sub);
    await createClass(base);
    await setExtends(sub, [base]);
    await bind(base, 'a');
    await assign([sub], [10]);

    final row = await effectiveRow();
    expect(row.value, 'a');
    expect(row.source, 'default');
    expect(row.boundBy, base); // the ANCESTOR supplies, not the member sub
  });

  test('an own binding beats an inherited one (distance 0 wins)', () async {
    const sub = '0192a000-0000-7000-8000-000000000110';
    const base = '0192a000-0000-7000-8000-000000000111';
    await createSchema();
    await createClass(sub);
    await createClass(base);
    await setExtends(sub, [base]);
    await bind(base, 'a'); // inherited (distance 1 from sub)
    await bind(sub, 'b', hlc: 6); // own (distance 0) — wins regardless of HLC
    await assign([sub], [10]);

    final row = await effectiveRow();
    expect(row.value, 'b');
    expect(row.boundBy, sub);
  });

  test('the shortest extends path beats an earlier class assignment',
      () async {
    const early = '0192a000-0000-7000-8000-000000000120';
    const mid = '0192a000-0000-7000-8000-000000000121';
    const deep = '0192a000-0000-7000-8000-000000000122';
    const late = '0192a000-0000-7000-8000-000000000123';
    const shallow = '0192a000-0000-7000-8000-000000000124';
    await createSchema();
    for (final c in [early, mid, deep, late, shallow]) {
      await createClass(c);
    }
    await setExtends(early, [mid]);
    await setExtends(mid, [deep]); // early → deep is distance 2
    await setExtends(late, [shallow]); // late → shallow is distance 1
    await bind(deep, 'a');
    await bind(shallow, 'b');
    // early assigned FIRST: under the pre-PG4 first-own-binding-wins rule
    // nothing derived here at all (neither class binds the schema itself);
    // under PG4 the distance-1 candidate wins over the distance-2 one.
    await assign([early, late], [10, 20]);

    final row = await effectiveRow();
    expect(row.value, 'b');
    expect(row.boundBy, shallow);
  });

  test('a distance tie breaks on the earliest class-assignment HLC', () async {
    const first = '0192a000-0000-7000-8000-000000000130';
    const p1 = '0192a000-0000-7000-8000-000000000131';
    const second = '0192a000-0000-7000-8000-000000000132';
    const p2 = '0192a000-0000-7000-8000-000000000133';
    await createSchema();
    for (final c in [first, p1, second, p2]) {
      await createClass(c);
    }
    await setExtends(first, [p1]);
    await setExtends(second, [p2]);
    await bind(p1, 'a');
    await bind(p2, 'b');
    await assign([first, second], [10, 20]); // first carries the earlier HLC

    final row = await effectiveRow();
    expect(row.value, 'a');
    expect(row.boundBy, p1);
  });

  test('a distance + HLC tie breaks on the class id', () async {
    // B < A by id; both memberships carry the SAME HLC (concurrent adds).
    const classA = '0192a000-0000-7000-8000-000000000140';
    const pa = '0192a000-0000-7000-8000-000000000141';
    const classB = '0192a000-0000-7000-8000-000000000142';
    const pb = '0192a000-0000-7000-8000-000000000143';
    await createSchema();
    for (final c in [classA, pa, classB, pb]) {
      await createClass(c);
    }
    await setExtends(classA, [pa]);
    await setExtends(classB, [pb]);
    await bind(pa, 'a');
    await bind(pb, 'b');
    await assign([classB, classA], [10, 10]);

    // classA sorts before classB on the id tiebreak — its ancestor wins.
    final row = await effectiveRow();
    expect(row.value, 'a');
    expect(row.boundBy, pa);
  });

  test('an inactive (PC4) ancestor binding is not a candidate', () async {
    const sub = '0192a000-0000-7000-8000-000000000150';
    const base = '0192a000-0000-7000-8000-000000000151';
    const other = '0192a000-0000-7000-8000-000000000152';
    await createSchema();
    await createClass(sub);
    await createClass(base);
    await createClass(other);
    await setExtends(sub, [base]);
    await bind(base, 'a', active: false); // soft-unbound — contributes nothing
    await bind(other, 'b');
    await assign([sub, other], [10, 20]);

    final row = await effectiveRow();
    expect(row.value, 'b');
    expect(row.boundBy, other);
  });

  test('a diamond reaches the common root once at its shortest distance',
      () async {
    const sub = '0192a000-0000-7000-8000-000000000160';
    const left = '0192a000-0000-7000-8000-000000000161';
    const right = '0192a000-0000-7000-8000-000000000162';
    const root = '0192a000-0000-7000-8000-000000000163';
    await createSchema();
    for (final c in [sub, left, right, root]) {
      await createClass(c);
    }
    await setExtends(sub, [left, right]);
    await setExtends(left, [root]);
    await setExtends(right, [root]);
    await bind(root, 'a');
    await assign([sub], [10]);

    final row = await effectiveRow();
    expect(row.value, 'a');
    expect(row.boundBy, root);
  });

  test('with no extends edges the rule reduces to first-class-applied-wins',
      () async {
    const task = '0192a000-0000-7000-8000-000000000170';
    const project = '0192a000-0000-7000-8000-000000000171';
    await createSchema();
    await createClass(task);
    await createClass(project);
    await bind(task, 'a');
    await bind(project, 'b');
    await assign([task, project], [10, 20]);

    final row = await effectiveRow();
    expect(row.value, 'a');
    expect(row.boundBy, task);
  });

  test('an authored row reads boundBy the supplying ancestor', () async {
    const sub = '0192a000-0000-7000-8000-000000000180';
    const base = '0192a000-0000-7000-8000-000000000181';
    await createSchema();
    await createClass(sub);
    await createClass(base);
    await setExtends(sub, [base]);
    await bind(base, 'a');
    await assign([sub], [10]);
    await appliers.apply(env(
      'property.set',
      OperationPayloads.propertySet(
        objectId: node,
        propertySchemaId: schema,
        value: 'b',
      ),
      30,
    ));

    final rows = await cache.getEffectiveProperties(node);
    expect(rows, hasLength(1));
    expect(rows.single.source, 'authored');
    expect(rows.single.value, 'b');
    expect(rows.single.boundBy, base); // authored + bound → the ancestor
  });
}
