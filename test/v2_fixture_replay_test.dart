import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:notees/data/local/app_database.dart';
import 'package:notees/data/repositories/node_cache_repository.dart';
import 'package:notees/domain/models/relay/hlc.dart';
import 'package:notees/domain/models/relay/operation_envelope.dart';
import 'package:notees/domain/models/relay/store_errors.dart';
import 'package:notees/domain/services/relay_appliers.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

/// Acceptance suite: replays the vendored v2 protocol fixtures through the
/// Flutter derived-state appliers — the same envelopes the monorepo's store
/// tests and the GTK client replay must converge to the same derived state
/// here. The cycle fixture is deliberately excluded from the all-fixtures
/// replay: its final two envelopes close cycles and MUST throw CycleError
/// on apply (see the cycle test).
///
/// Expected outcomes mirror `tests/test_store_fixtures.py` (GTK) and
/// `v2/packages/store/test/store.test.ts` (monorepo).
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  sqfliteFfiInit();

  const fixturesDir = 'test/fixtures/v2';

  const ws = '0192a000-0000-7000-8000-000000000001';
  const nodePage = '0192a000-0000-7000-8000-000000000010';
  const nodeBook = '0192a000-0000-7000-8000-000000000011';
  const propSchema = '0192a000-0000-7000-8000-0000000000a1';
  const bookClass = '00000000-0000-0000-0001-000000000025';

  // object-move.json ids.
  const moveP = '0192a000-0000-7000-8000-000000000020';
  const moveA = '0192a000-0000-7000-8000-000000000021';
  const moveB = '0192a000-0000-7000-8000-000000000022';
  const moveC = '0192a000-0000-7000-8000-000000000023';

  // class-extends-cycle.json ids.
  const cycleRoot = '0192a000-0000-7000-8000-0000000000d1';
  const cycleLeaf = '0192a000-0000-7000-8000-0000000000d2';

  /// The cycle fixture must throw — never part of the replay set.
  const replayExcluded = {'class-extends-cycle.json'};

  List<Map<String, dynamic>> loadFixture(String name) {
    final raw = jsonDecode(File('$fixturesDir/$name').readAsStringSync())
        as Map<String, dynamic>;
    final envelopes = raw['envelopes'];
    if (envelopes is List) return envelopes.cast<Map<String, dynamic>>();
    return [raw];
  }

  List<OperationEnvelope> fixtureEnvelopes(String name) =>
      loadFixture(name).map(OperationEnvelope.fromJson).toList();

  List<OperationEnvelope> allFixtureEnvelopes() {
    final names = Directory(fixturesDir)
        .listSync()
        .whereType<File>()
        .map((f) => f.uri.pathSegments.last)
        .where((name) => name.endsWith('.json') && !replayExcluded.contains(name))
        .toList()
      ..sort();
    return [for (final name in names) ...fixtureEnvelopes(name)];
  }

  OperationEnvelope basePage(String nodeId, int physical) => OperationEnvelope(
        id: '0192a000-0000-7000-8000-0000000003$physical',
        workspaceId: ws,
        actorId: '0192a000-0000-7000-8000-000000000002',
        deviceId: 'fixture-test-device',
        hlc: Hlc(physical: physical, logical: 0),
        affectedNodeIds: [nodeId],
        opType: 'object.create',
        payload: {'objectId': nodeId, 'nodeType': 'page', 'classIds': <String>[]},
        timestamp: '2026-09-24T12:00:00.000Z',
      );

  group('v2 fixture replay acceptance', () {
    late NodeCacheRepository cache;
    late RelayAppliers appliers;
    late AppDatabase database;

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

    /// The monorepo tests seed two pages before replaying most fixtures.
    Future<void> seedBase() async {
      await appliers.apply(basePage(nodePage, 0));
      await appliers.apply(basePage(nodeBook, 1));
    }

    Future<List<Map<String, dynamic>>> raw(String sql,
        [List<Object?>? args]) async {
      final db = await database.database;
      return db.rawQuery(sql, args);
    }

    test('object.create fixtures land names and OR-Set class ids', () async {
      for (final envelope in <OperationEnvelope>[
        ...fixtureEnvelopes('envelope-minimal.json'),
        ...fixtureEnvelopes('object-create.json'),
      ]) {
        expect(await appliers.apply(envelope), isTrue);
      }
      final page = await cache.getByUuid(nodePage);
      final book = await cache.getByUuid(nodeBook);
      expect(page, isNotNull);
      expect(page!.nodeType, 'page');
      expect(book, isNotNull);
      expect(book!.nodeType, 'page');
      // The v2 scalar name lands in the title field, not the content slot.
      expect(book.title, 'The Structure of Scientific Revolutions');
      expect(book.displayName, 'The Structure of Scientific Revolutions');
      // classIds seed the OR-Set membership, projected into classesUuid.
      expect(book.classesUuid, [bookClass]);
      final member = await raw(
        'SELECT present FROM class_member_set WHERE node_uuid = ? AND class_id = ?',
        [nodeBook, bookClass],
      );
      expect(member.single['present'], 1);
    });

    test('property-set-lww converges to the higher-HLC phone value both orders',
        () async {
      final laptop = fixtureEnvelopes('property-set-lww.json')[0];
      final phone = fixtureEnvelopes('property-set-lww.json')[1];

      Future<List<Map<String, dynamic>>> winnerSlot() => raw(
            'SELECT value, metadata, actor_id FROM property_value '
            'WHERE node_uuid = ? AND property_schema_id = ? AND idx = 0',
            [nodeBook, propSchema],
          );

      final expected = [
        (
          jsonEncode({'nodeId': '0192a000-0000-7000-8000-000000000031'}),
          jsonEncode({'since': '1963'}),
          '0192a000-0000-7000-8000-000000000003',
        ),
      ];

      await seedBase();
      await appliers.apply(laptop);
      await appliers.apply(phone);
      final forward = await winnerSlot();
      expect(
        forward.map((r) => (r['value'], r['metadata'], r['actor_id'])).toList(),
        expected,
      );

      // Fresh store, reverse order: same convergence.
      await database.close();
      final ffiDb2 = await databaseFactoryFfi.openDatabase(
        ':memory:',
        options: OpenDatabaseOptions(singleInstance: false),
      );
      database = AppDatabase.fromDatabase(ffiDb2);
      await database.initializeSchema();
      cache = NodeCacheRepository(database);
      appliers = RelayAppliers(cache);
      await seedBase();
      await appliers.apply(phone);
      await appliers.apply(laptop);
      final backward = await winnerSlot();
      expect(
        backward.map((r) => (r['value'], r['metadata'], r['actor_id'])).toList(),
        expected,
      );
    });

    test('typed-link mark then deleted lands the final content', () async {
      await seedBase();
      for (final name in ['typed-link-mark.json', 'typed-link-mark-deleted.json']) {
        for (final envelope in fixtureEnvelopes(name)) {
          expect(await appliers.apply(envelope), isTrue);
        }
      }
      final page = await cache.getByUuid(nodePage);
      expect(
        jsonDecode(page!.name),
        [
          {'type': 'text', 'text': 'Kuhn cites earlier work.'},
        ],
      );
      expect(page.displayName, 'Kuhn cites earlier work.');
    });

    test('content updates converge regardless of order', () async {
      final mark = fixtureEnvelopes('typed-link-mark.json')[0];
      final deleted = fixtureEnvelopes('typed-link-mark-deleted.json')[0];

      Future<String> contentOf() async =>
          (await cache.getByUuid(nodePage))!.name;

      await seedBase();
      await appliers.apply(mark);
      await appliers.apply(deleted);
      final forward = await contentOf();

      await database.close();
      final ffiDb2 = await databaseFactoryFfi.openDatabase(
        ':memory:',
        options: OpenDatabaseOptions(singleInstance: false),
      );
      database = AppDatabase.fromDatabase(ffiDb2);
      await database.initializeSchema();
      cache = NodeCacheRepository(database);
      appliers = RelayAppliers(cache);
      await seedBase();
      await appliers.apply(deleted);
      await appliers.apply(mark);
      final backward = await contentOf();

      expect(forward, backward);
      expect(
        jsonDecode(forward),
        [
          {'type': 'text', 'text': 'Kuhn cites earlier work.'},
        ],
      );
    });

    test('object.move lands C under A with expected fractional positions',
        () async {
      for (final envelope in fixtureEnvelopes('object-move.json')) {
        expect(await appliers.apply(envelope), isTrue);
      }
      expect((await cache.getByUuid(moveC))!.parentUuid, moveA);
      expect(
        (await cache.getChildren(moveP)).map((n) => n.uuid).toList(),
        [moveA, moveB],
      );
      expect(
        (await cache.getChildren(moveA)).map((n) => n.uuid).toList(),
        [moveC],
      );
      // Exactly one row per node — no dual-parent residue (the position
      // lives on the node row; a second row for C would mean corruption).
      final orderRows = await raw(
        'SELECT uuid, position FROM node_cache WHERE parent_uuid = ? ORDER BY position',
        [moveP],
      );
      expect(
        orderRows.map((r) => (r['uuid'], r['position'] as String?)).toList(),
        [(moveA, 'a'), (moveB, 'aa')],
      );
      final cRows =
          await raw('SELECT COUNT(*) AS c FROM node_cache WHERE uuid = ?', [moveC]);
      expect(cRows.single['c'], 1);
    });

    test('class-extends-m2m lands the child under both ancestors', () async {
      for (final envelope in fixtureEnvelopes('class-extends-m2m.json')) {
        expect(await appliers.apply(envelope), isTrue);
      }
      const a = '0192a000-0000-7000-8000-0000000000c5';
      const b = '0192a000-0000-7000-8000-0000000000c6';
      const c = '0192a000-0000-7000-8000-0000000000c7';
      final edges = await raw(
        'SELECT parent_class_id FROM class_extends WHERE class_id = ? ORDER BY parent_class_id',
        [c],
      );
      expect(edges.map((r) => r['parent_class_id']).toList(), [a, b]);
      final ancestors = await raw(
        'SELECT ancestor_id FROM class_hierarchy WHERE class_id = ? ORDER BY ancestor_id',
        [c],
      );
      expect(ancestors.map((r) => r['ancestor_id']).toList(), [a, b, c]);
      for (final parent in [a, b]) {
        final descendants = await raw(
          'SELECT class_id FROM class_hierarchy WHERE ancestor_id = ? ORDER BY class_id',
          [parent],
        );
        expect(descendants.map((r) => r['class_id']), contains(c));
      }
    });

    test('cycle-closing setExtends envelopes throw and change nothing', () async {
      final envelopes = fixtureEnvelopes('class-extends-cycle.json');
      final root = envelopes[0];
      final leaf = envelopes[1];
      final leafExtendsRoot = envelopes[2];
      final rootExtendsLeaf = envelopes[3];
      final rootExtendsRoot = envelopes[4];

      // The PREFIX applies cleanly: Root and Leaf are created, then Leaf
      // extends [Root].
      expect(await appliers.apply(root), isTrue);
      expect(await appliers.apply(leaf), isTrue);
      expect(await appliers.apply(leafExtendsRoot), isTrue);
      final prefixClosure = await raw(
        'SELECT ancestor_id FROM class_hierarchy WHERE class_id = ? ORDER BY ancestor_id',
        [cycleLeaf],
      );
      expect(prefixClosure.map((r) => r['ancestor_id']).toList(),
          [cycleRoot, cycleLeaf]);

      // Multi-hop cycle (Root extends [Leaf] with Leaf already under Root)...
      expect(() async => appliers.apply(rootExtendsLeaf),
          throwsA(isA<CycleError>()));
      // ...and the self-parent case (Root extends [Root]).
      expect(() async => appliers.apply(rootExtendsRoot),
          throwsA(isA<CycleError>()));

      // A thrown apply changes nothing: closure and edges are exactly the
      // prefix state.
      final rootClosure = await raw(
        'SELECT ancestor_id FROM class_hierarchy WHERE class_id = ? ORDER BY ancestor_id',
        [cycleRoot],
      );
      expect(rootClosure.map((r) => r['ancestor_id']).toList(), [cycleRoot]);
      final edgeCount =
          await raw('SELECT COUNT(*) AS c FROM class_extends');
      expect(edgeCount.single['c'], 1);
    });

    test('re-applying the whole fixture set is state-idempotent', () async {
      final envelopes = allFixtureEnvelopes();
      // Alphabetical fixture order lands typed-link-mark-deleted (higher
      // HLC) before typed-link-mark, so the mark is legitimately dropped by
      // row LWW on first replay — convergence, not a bug.
      for (final envelope in envelopes) {
        await appliers.apply(envelope);
      }
      final page = await cache.getByUuid(nodePage);
      expect(
        jsonDecode(page!.name),
        [
          {'type': 'text', 'text': 'Kuhn cites earlier work.'},
        ],
      );
      final before = await raw(
        'SELECT uuid, name, classes_uuid, title FROM node_cache ORDER BY uuid',
      );
      // Second replay: LWW guards and first-create-wins keep the state
      // identical. (Envelope-id dedupe lives in the sync service —
      // relay_operations — not in the appliers; the GTK store asserts the
      // per-op false there via its applied_envelope table.)
      for (final envelope in envelopes) {
        await appliers.apply(envelope);
      }
      final after = await raw(
        'SELECT uuid, name, classes_uuid, title FROM node_cache ORDER BY uuid',
      );
      expect(after, before);
    });
  });
}
