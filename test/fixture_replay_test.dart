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

/// Acceptance suite: replays the vendored protocol fixtures through the
/// Flutter derived-state appliers — the same envelopes the monorepo's store
/// tests and the GTK client replay must converge to the same derived state
/// here. The throw-fixtures are deliberately excluded from the all-fixtures
/// replay: class-extends-cycle's final two envelopes close cycles and MUST
/// throw CycleError on apply, class-extends-system-lock's tail deviates from
/// the seeded system-extends sets and MUST throw SystemExtendsLockError
/// (see the dedicated tests).
///
/// Expected outcomes mirror `tests/test_store_fixtures.py` (GTK) and
/// `packages/store/test/store.test.ts` (monorepo).
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  sqfliteFfiInit();

  const fixturesDir = 'test/fixtures/wire';

  const ws = '0192a000-0000-7000-8000-000000000001';
  const nodePage = '0192a000-0000-7000-8000-000000000010';
  const nodeBook = '0192a000-0000-7000-8000-000000000011';
  const nodeBlock = '0192a000-0000-7000-8000-000000000020';
  const propSchema = '0192a000-0000-7000-8000-0000000000a1';
  const bookClass = '00000000-0000-0000-0001-000000000025';

  // object-move.json ids.
  const moveP = '0192a000-0000-7000-8000-000000000020';
  const moveA = '0192a000-0000-7000-8000-000000000021';
  const moveB = '0192a000-0000-7000-8000-000000000022';
  const moveC = '0192a000-0000-7000-8000-000000000023';

  // object-move-before.json ids.
  const moveBeforeP = '0192a000-0000-7000-8000-000000000140';
  const moveBeforeA = '0192a000-0000-7000-8000-000000000141';
  const moveBeforeB = '0192a000-0000-7000-8000-000000000142';
  const moveBeforeC = '0192a000-0000-7000-8000-000000000143';
  const moveBeforeD = '0192a000-0000-7000-8000-000000000144';

  // class-extends-cycle.json ids.
  const cycleRoot = '0192a000-0000-7000-8000-0000000000d1';
  const cycleLeaf = '0192a000-0000-7000-8000-0000000000d2';

  // external-ref.json ids + refs.
  const extA = '0192a000-0000-7000-8000-000000000b10';
  const extB = '0192a000-0000-7000-8000-000000000b11';
  const refGcal = 'gcal:event:abc123@google.com';
  const refReadwise = 'readwise:highlight:12345';
  const refReaditlater = 'readitlater:entry:7788';
  const refDef456 = 'gcal:event:def456@google.com';
  const refGhi789 = 'gcal:event:ghi789@google.com';

  /// Fixtures whose application must throw — never part of the replay set
  /// (class-extends-cycle closes a cycle; class-extends-system-lock pins the
  /// system-extends lock's reject tail (detach/extra-parent/deviate) after
  /// an accepting prefix; is-embedded-parent-page claims the
  /// standalone role under an embedded block, the parent-page condition;
  /// property-validation-rules' rejecting tail — below-min/above-max number,
  /// pattern rejects, a bad multi element, an uncompilable pattern — throws
  /// on apply by design, each reject pinned deliberately in the replay
  /// suite; object-delete-class-routing pins the locked-system-class delete
  /// arm (LockedSystemClassError) after its accepting prefix — the four
  /// arms are asserted deliberately in the routing suite below).
  const replayExcluded = {
    'class-extends-cycle.json',
    'class-extends-system-lock.json',
    'is-embedded-parent-page.json',
    'object-delete-class-routing.json',
    'property-validation-rules.json',
  };

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
        payload: {
          'objectId': nodeId,
          'isEmbedded': false,
          'classIds': <String>[],
        },
        timestamp: '2026-09-24T12:00:00.000Z',
      );

  /// The typed-link fixtures update the BLOCK under nodePage (the TS store
  /// tests seed it the same way via baseStoreWithBlock).
  OperationEnvelope baseBlock(String nodeId, String parentId, int physical) =>
      OperationEnvelope(
        id: '0192a000-0000-7000-8000-0000000004$physical',
        workspaceId: ws,
        actorId: '0192a000-0000-7000-8000-000000000002',
        deviceId: 'fixture-test-device',
        hlc: Hlc(physical: physical, logical: 0),
        affectedNodeIds: [nodeId],
        opType: 'object.create',
        payload: {
          'objectId': nodeId,
          'classIds': <String>[],
          'parentId': parentId,
        },
        timestamp: '2026-09-24T12:00:00.000Z',
      );

  /// Hand-built `external_ref.*` envelope (the TS store tests' `env()`
  /// helper equivalent): the mapping ops key their state by the payload's
  /// `ref`, so affectedNodeIds stays empty.
  OperationEnvelope extRefOp(
    String opType,
    Map<String, dynamic> payload,
    int physical,
  ) =>
      OperationEnvelope(
        id: '0192a000-0000-7000-8000-0000000005$physical',
        workspaceId: ws,
        actorId: '0192a000-0000-7000-8000-000000000002',
        deviceId: 'fixture-test-device',
        hlc: Hlc(physical: physical, logical: 0),
        affectedNodeIds: const [],
        opType: opType,
        payload: payload,
        timestamp: '2026-09-24T12:00:50.000Z',
      );

  group('fixture replay acceptance', () {
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

    /// The typed-link fixtures target the block under nodePage.
    Future<void> seedBaseWithBlock() async {
      await seedBase();
      await appliers.apply(baseBlock(nodeBlock, nodePage, 500));
    }

    Future<List<Map<String, dynamic>>> raw(String sql,
        [List<Object?>? args]) async {
      final db = await database.database;
      return db.rawQuery(sql, args);
    }

    test('object.create fixtures land content and OR-Set class ids', () async {
      for (final envelope in <OperationEnvelope>[
        ...fixtureEnvelopes('envelope-minimal.json'),
        ...fixtureEnvelopes('object-create.json'),
      ]) {
        expect(await appliers.apply(envelope), isTrue);
      }
      final page = await cache.getByUuid(nodePage);
      final book = await cache.getByUuid(nodeBook);
      expect(page, isNotNull);
      expect(page!.isEmbedded, isFalse);
      expect(page.isPage, isTrue);
      expect(book, isNotNull);
      expect(book!.isEmbedded, isFalse);
      expect(book.isPage, isTrue);
      // Title-is-content: the fixture's contentAst IS the title; there is
      // no scalar name slot on the wire.
      expect(book.title, isNull);
      expect(book.displayName, 'The Structure of Scientific Revolutions');
      expect(
        jsonDecode(book.name),
        [
          {'type': 'text', 'text': 'The Structure of Scientific Revolutions'},
        ],
      );
      // classIds seed the OR-Set membership, projected into classesUuid.
      expect(book.classesUuid, [bookClass]);
      final member = await raw(
        'SELECT present FROM class_member_set WHERE node_uuid = ? AND class_id = ?',
        [nodeBook, bookClass],
      );
      expect(member.single['present'], 1);
    });

    test('object-color lands token → hex → null-clear; class token → null',
        () async {
      const objectProbe = '0192a000-0000-7000-8000-000000000510';
      const classProbe = '0192a000-0000-7000-8000-000000000511';
      final envelopes = fixtureEnvelopes('object-color.json');

      // object.create carries no color slot (color rides
      // object.update), so the probe page starts uncolored.
      expect(await appliers.apply(envelopes[0]), isTrue);
      expect((await cache.getByUuid(objectProbe))!.color, isNull);

      // object.update with a preset token lands it verbatim.
      expect(await appliers.apply(envelopes[1]), isTrue);
      expect((await cache.getByUuid(objectProbe))!.color, 'sky');

      // object.update with a custom hex lands it verbatim.
      expect(await appliers.apply(envelopes[2]), isTrue);
      expect((await cache.getByUuid(objectProbe))!.color, '#123abc');

      // object.update with a present null CLEARS — a
      // `!= null` drop here would leave '#123abc' behind.
      expect(await appliers.apply(envelopes[3]), isTrue);
      expect((await cache.getByUuid(objectProbe))!.color, isNull);

      // class.create carries the token; class.update null clears.
      expect(await appliers.apply(envelopes[4]), isTrue);
      expect((await cache.getClassByUuid(classProbe))!.color, 'pink');
      expect(await appliers.apply(envelopes[5]), isTrue);
      expect((await cache.getClassByUuid(classProbe))!.color, isNull);
    });

    test('object-wire-fields lands set + clear through object.update', () async {
      const page = '0192a000-0000-7000-8000-00000000052a';
      const asset = '0192a000-0000-7000-8000-00000000052b';
      const main = '0192a000-0000-7000-8000-00000000052c';
      final envelopes = fixtureEnvelopes('object-wire-fields.json');
      for (final envelope in envelopes.take(3)) {
        expect(await appliers.apply(envelope), isTrue);
      }

      Future<({String? cover, String? banner, String? alias, String? description})>
      fields() async {
        final node = await cache.getByUuid(page);
        final rows = await raw(
          'SELECT cover_asset_id, banner_asset_id, aliased_node_id, description '
          'FROM node_cache WHERE uuid = ?',
          [page],
        );
        expect(rows, hasLength(1));
        final row = rows.single;
        // The Node payload and the derived v27/v28 columns project the same
        // fields (the payload is the read authority; the columns serve SQL).
        expect(node!.coverAssetId, row['cover_asset_id']);
        expect(node.bannerAssetId, row['banner_asset_id']);
        expect(node.aliasedNodeId, row['aliased_node_id']);
        expect(node.description, row['description']);
        return (
          cover: row['cover_asset_id'] as String?,
          banner: row['banner_asset_id'] as String?,
          alias: row['aliased_node_id'] as String?,
          description: row['description'] as String?,
        );
      }

      expect(
        await fields(),
        (cover: null, banner: null, alias: null, description: null),
      );
      expect(await appliers.apply(envelopes[3]), isTrue); // coverAssetId = ASSET
      expect(
        await fields(),
        (cover: asset, banner: null, alias: null, description: null),
      );
      expect(await appliers.apply(envelopes[4]), isTrue); // banner + alias
      expect(
        await fields(),
        (cover: asset, banner: asset, alias: main, description: null),
      );
      expect(await appliers.apply(envelopes[5]), isTrue); // alias clear
      expect(
        await fields(),
        (cover: asset, banner: asset, alias: null, description: null),
      );
      expect(await appliers.apply(envelopes[6]), isTrue); // cover clear
      expect(
        await fields(),
        (cover: null, banner: asset, alias: null, description: null),
      );
      expect(await appliers.apply(envelopes[7]), isTrue); // banner clear
      expect(
        await fields(),
        (cover: null, banner: null, alias: null, description: null),
      );
      expect(await appliers.apply(envelopes[8]), isTrue); // description = text
      expect(
        await fields(),
        (
          cover: null,
          banner: null,
          alias: null,
          description: 'Subtitle text',
        ),
      );
      expect(await appliers.apply(envelopes[9]), isTrue); // description clear
      expect(
        await fields(),
        (cover: null, banner: null, alias: null, description: null),
      );
    });

    test('wire fields: absence preserves, present-null clears, stale-HLC '
        'drops', () async {
      const page = '0192a000-0000-7000-8000-00000000052a';
      const asset = '0192a000-0000-7000-8000-00000000052b';
      const main = '0192a000-0000-7000-8000-00000000052c';

      OperationEnvelope update(
        Map<String, dynamic> payload,
        int physical,
      ) =>
          OperationEnvelope(
            id: '0192a000-0000-7000-8000-0000000009$physical',
            workspaceId: ws,
            actorId: '0192a000-0000-7000-8000-000000000002',
            deviceId: 'fixture-test-device',
            hlc: Hlc(physical: physical, logical: 0),
            affectedNodeIds: [page],
            opType: 'object.update',
            payload: payload,
            timestamp: '2026-09-24T12:00:09.000Z',
          );

      await appliers.apply(basePage(page, 0));
      await appliers.apply(update({
        'objectId': page,
        'coverAssetId': asset,
        'bannerAssetId': asset,
        'aliasedNodeId': main,
      }, 1000));
      // An absent field is not a write: an icon-only update keeps the fields.
      await appliers
          .apply(update({'objectId': page, 'icon': 'mdiStar'}, 2000));
      var node = await cache.getByUuid(page);
      expect(node!.icon, 'mdiStar');
      expect(node.coverAssetId, asset);
      expect(node.bannerAssetId, asset);
      expect(node.aliasedNodeId, main);
      // A stale-HLC update loses the row LWW race: nothing changes.
      await appliers
          .apply(update({'objectId': page, 'coverAssetId': null}, 500));
      node = await cache.getByUuid(page);
      expect(node!.coverAssetId, asset);
      // The winning clear.
      await appliers
          .apply(update({'objectId': page, 'coverAssetId': null}, 3000));
      node = await cache.getByUuid(page);
      expect(node!.coverAssetId, isNull);
    });

    group('alias cycles (M12)', () {
      const a = '0192a000-0000-7000-8000-0000000000a1';
      const b = '0192a000-0000-7000-8000-0000000000a2';
      const c = '0192a000-0000-7000-8000-0000000000a3';
      const d = '0192a000-0000-7000-8000-0000000000a4';

      OperationEnvelope alias(
        String from,
        String? to,
        int physical,
      ) =>
          OperationEnvelope(
            id: '0192a000-0000-7000-8000-0000000009$physical',
            workspaceId: ws,
            actorId: '0192a000-0000-7000-8000-000000000002',
            deviceId: 'fixture-test-device',
            hlc: Hlc(physical: physical, logical: 0),
            affectedNodeIds: [from],
            opType: 'object.update',
            payload: {'objectId': from, 'aliasedNodeId': to},
            timestamp: '2026-09-24T12:00:09.000Z',
          );

      test('a plain chain sets and resolves; acyclic re-points stay legal',
          () async {
        for (final id in [a, b, c, d]) {
          await appliers.apply(basePage(id, 0));
        }
        await appliers.apply(alias(a, b, 1000));
        await appliers.apply(alias(b, c, 2000));
        expect((await cache.getByUuid(a))!.aliasedNodeId, b);
        expect(await cache.resolveAlias(a), c);
        expect(await cache.resolveAlias(b), c);
        expect(await cache.resolveAlias(c), c);
        // Re-pointing the middle of the chain is fine while it stays
        // acyclic: B → D (D carries no alias) collapses A's chain to D.
        await appliers.apply(alias(b, d, 3000));
        expect(await cache.resolveAlias(a), d);
        expect(await cache.resolveAlias(b), d);
      });

      test('self-alias (the 1-edge cycle) fails loud and is never applied',
          () async {
        await appliers.apply(basePage(a, 0));
        expect(() => appliers.apply(alias(a, a, 1000)),
            throwsA(isA<CycleError>()));
        expect((await cache.getByUuid(a))!.aliasedNodeId, isNull);
      });

      test('an indirect cycle fails loud: A→B→C then C→A is rejected and '
          'nothing changes', () async {
        for (final id in [a, b, c]) {
          await appliers.apply(basePage(id, 0));
        }
        await appliers.apply(alias(a, b, 1000));
        await appliers.apply(alias(b, c, 2000));
        // C → A would close A → B → C → A: rejected, never applied.
        expect(() => appliers.apply(alias(c, a, 3000)),
            throwsA(isA<CycleError>()));
        expect((await cache.getByUuid(c))!.aliasedNodeId, isNull);
        expect((await cache.getByUuid(a))!.aliasedNodeId, b);
        expect((await cache.getByUuid(b))!.aliasedNodeId, c);
        // Same for a 2-cycle proposal: B → A revisits A's chain back to B.
        expect(() => appliers.apply(alias(b, a, 4000)),
            throwsA(isA<CycleError>()));
        expect((await cache.getByUuid(b))!.aliasedNodeId, c);
      });

      test('clearing an alias lands NULL and re-opens the chain for new '
          'targets', () async {
        for (final id in [a, b]) {
          await appliers.apply(basePage(id, 0));
        }
        await appliers.apply(alias(a, b, 1000));
        expect(await cache.resolveAlias(a), b);
        // Clearing cannot create a cycle — it never touches the check and
        // lands.
        await appliers.apply(alias(a, null, 2000));
        expect((await cache.getByUuid(a))!.aliasedNodeId, isNull);
        expect(await cache.resolveAlias(a), a);
        // With A's alias gone, B → A is acyclic and legal.
        await appliers.apply(alias(b, a, 3000));
        expect(await cache.resolveAlias(b), a);
      });

      test('a stale-HLC alias write is dropped by the row LWW before any '
          'check', () async {
        for (final id in [a, b, c]) {
          await appliers.apply(basePage(id, 0));
        }
        await appliers.apply(alias(a, b, 1000));
        await appliers.apply(alias(b, c, 2000));
        // Older than both rows — dropped silently (LWW), no throw, no
        // change.
        await appliers.apply(alias(a, c, 500));
        expect((await cache.getByUuid(a))!.aliasedNodeId, b);
      });

      test('resolveAlias is cycle-safe (id unchanged on a revisit) and '
          'depth-capped', () async {
        for (final id in [a, b, c]) {
          await appliers.apply(basePage(id, 0));
        }
        await appliers.apply(alias(a, b, 1000));
        await appliers.apply(alias(b, c, 2000));
        expect(await cache.resolveAlias(a), c);
        // A cycle can only exist if it predates the write-path check (a
        // legacy row, a hand-edited store): close C → A in place and
        // observe the walker's ruling — every member's walk revisits its
        // start and yields the STARTING id unchanged.
        final db = await database.database;
        await db.rawUpdate(
          'UPDATE node_cache SET aliased_node_id = ? WHERE uuid = ?',
          [a, c],
        );
        expect(await cache.resolveAlias(a), a);
        expect(await cache.resolveAlias(b), b);
        expect(await cache.resolveAlias(c), c);
        // Depth cap: a hand-built 40-link chain resolves to the node
        // reached at the cap (best-effort terminal), never loops forever.
        var prev = a;
        for (var i = 0; i < 40; i++) {
          final next =
              '0192a000-0000-7000-8000-0000000001${i.toString().padLeft(2, '0')}';
          await appliers.apply(basePage(next, 10000 + i));
          await appliers.apply(alias(prev, next, 20000 + i));
          prev = next;
        }
        expect(await cache.resolveAlias(a), isNot(a));
      });

      test('aliasNodeIdsOf lists every node whose alias-terminal is this '
          'one (chains included, trashed excluded, the main never lists)',
          () async {
        for (final id in [a, b, c, d]) {
          await appliers.apply(basePage(id, 0));
        }
        expect(await cache.aliasNodeIdsOf(c), isEmpty);
        // A → B → C: C's listing carries BOTH A and B (the reverse walk
        // follows chains, not just direct links); B lists only A.
        await appliers.apply(alias(a, b, 1000));
        await appliers.apply(alias(b, c, 2000));
        expect(await cache.aliasNodeIdsOf(c), [a, b]);
        expect(await cache.aliasNodeIdsOf(b), [a]);
        expect(await cache.aliasNodeIdsOf(a), isEmpty);
        // Re-pointing collapses the listing with the chain: B → D moves
        // A's listing to D.
        await appliers.apply(alias(b, d, 3000));
        expect(await cache.aliasNodeIdsOf(c), isEmpty);
        expect(await cache.aliasNodeIdsOf(d), [a, b]);
        // Trashed rows never list.
        final db = await database.database;
        await db.rawUpdate(
          'UPDATE node_cache SET is_deleted = 1 WHERE uuid = ?',
          [a],
        );
        expect(await cache.aliasNodeIdsOf(d), [b]);
      });
    });

    test('class-convert declares an existing parentless page a class: '
        'identity flips, the title rides along', () async {
      const genre = '0192a000-0000-7000-8000-00000000053a';
      final envelopes = fixtureEnvelopes('class-convert.json');
      expect(await appliers.apply(envelopes[0]), isTrue);
      expect(await appliers.apply(envelopes[3]), isTrue);

      final node = await cache.getByUuid(genre);
      expect(node!.isClass, isTrue);
      expect(node.isEmbedded, isFalse); // classes converge to the standalone 0
      expect(node.parentUuid, isNull);
      // Title-is-content: the node's existing text content is the class
      // title (the conversion payload carried no contentAst).
      expect(jsonDecode(node.name), [
        {'type': 'text', 'text': 'Genre collection'},
      ]);
      expect(node.displayName, 'Genre collection');
      // The registry row adopted the title + the hierarchy self-row landed.
      final cls = await cache.getClassByUuid(genre);
      expect(cls, isNotNull);
      expect(cls!.displayName, 'Genre collection');
      expect(await cache.isClassNode(genre), isTrue);
      final selfRow = await raw(
        'SELECT 1 FROM class_hierarchy WHERE class_id = ? AND ancestor_id = ?',
        [genre, genre],
      );
      expect(selfRow, hasLength(1));
    });

    test('class-convert cuts a parented node to a root: the parent edge '
        'and its position go', () async {
      const rack = '0192a000-0000-7000-8000-00000000053b';
      const shelf = '0192a000-0000-7000-8000-00000000053c';
      final envelopes = fixtureEnvelopes('class-convert.json');
      expect(await appliers.apply(envelopes[1]), isTrue);
      expect(await appliers.apply(envelopes[2]), isTrue);
      expect((await cache.getChildren(rack)).map((n) => n.uuid).toList(),
          [shelf]);

      expect(await appliers.apply(envelopes[4]), isTrue);
      final node = await cache.getByUuid(shelf);
      expect(node!.isClass, isTrue);
      expect(node.parentUuid, isNull);
      expect(node.position, isNull);
      expect((await cache.getChildren(rack)), isEmpty);
      // The registry adopted the shelf title.
      expect((await cache.getClassByUuid(shelf))!.displayName, 'Shelf');
    });

    test('class-convert re-declaration is a replace no-op and fresh '
        'declaration keeps working', () async {
      const genre = '0192a000-0000-7000-8000-00000000053a';
      const fresh = '0192a000-0000-7000-8000-00000000053d';
      final envelopes = fixtureEnvelopes('class-convert.json');
      expect(await appliers.apply(envelopes[0]), isTrue);
      expect(await appliers.apply(envelopes[3]), isTrue);
      final contentBefore = (await cache.getByUuid(genre))!.name;

      // Re-declaration (bare id, absent fields preserve): the node's title
      // and the registry row ride untouched.
      expect(await appliers.apply(envelopes[5]), isTrue);
      expect((await cache.getByUuid(genre))!.name, contentBefore);
      expect((await cache.getClassByUuid(genre))!.displayName,
          'Genre collection');

      // A fresh id still declares a brand-new class.
      expect(await appliers.apply(envelopes[6]), isTrue);
      expect((await cache.getClassByUuid(fresh))!.displayName, 'Fresh genre');
      // The fresh class has no local node row (classes live in class_cache
      // locally); it still answers class-identity reads and carries its
      // hierarchy self-row.
      expect(await cache.getByUuid(fresh), isNull);
      expect(await cache.isClassNode(fresh), isTrue);
      final selfRow = await raw(
        'SELECT 1 FROM class_hierarchy WHERE class_id = ? AND ancestor_id = ?',
        [fresh, fresh],
      );
      expect(selfRow, hasLength(1));
    });

    test('property-asset-type lands asset-typed schemas and the coexisting '
        'update', () async {
      for (final envelope in fixtureEnvelopes('property-asset-type.json')) {
        expect(await appliers.apply(envelope), isTrue);
      }
      final rows = await raw(
        'SELECT uuid, type, multi, scope, scope_class_ids, name '
        'FROM property_schema ORDER BY uuid',
      );
      expect(rows, hasLength(2));
      expect(rows[0]['uuid'], '0192a000-0000-7000-8000-000000000541');
      expect(rows[0]['type'], 'asset');
      expect(rows[0]['multi'], 1);
      // The retired `scope` enum is gone from the wire — the create carries
      // scopeClassIds (local to the source class + its extends-ancestors);
      // the legacy display-only column keeps its 'global' default.
      expect(rows[0]['scope'], 'global');
      expect(
        jsonDecode(rows[0]['scope_class_ids'] as String),
        ['00000000-0000-0000-0001-000000000023'],
      );
      expect(rows[0]['name'], 'Attachment');
      expect(rows[1]['uuid'], '0192a000-0000-7000-8000-000000000542');
      expect(rows[1]['type'], 'asset');
      expect(rows[1]['multi'], 0);
      expect(rows[1]['scope'], 'global');
      expect(rows[1]['scope_class_ids'], isNull);
      expect(rows[1]['name'], 'Cover file (renamed)');
    });

    test('asset values validate as asset-node references — the implicit '
        'filter is the asset class', () async {
      const schema = '0192a000-0000-7000-8000-000000000541';
      const page = '0192a000-0000-7000-8000-0000000000f1';
      const assetNode = '0192a000-0000-7000-8000-0000000000f2';
      const plainNode = '0192a000-0000-7000-8000-0000000000f3';
      const assetClass = '00000000-0000-0000-0001-000000000009';
      const bindingClass = '00000000-0000-7000-8000-0000000000f4';

      OperationEnvelope op(
        String opType,
        Map<String, dynamic> payload,
        int physical,
      ) =>
          OperationEnvelope(
            id: '0192a000-0000-7000-8000-0000000009$physical',
            workspaceId: ws,
            actorId: '0192a000-0000-7000-8000-000000000002',
            deviceId: 'fixture-test-device',
            hlc: Hlc(physical: physical, logical: 0),
            affectedNodeIds: [payload['objectId'] ?? payload['classId'] ?? ''],
            opType: opType,
            payload: payload,
            timestamp: '2026-09-24T12:00:09.000Z',
          );

      // The asset system class + a binding host class + the value targets.
      await appliers.apply(op('class.create', {
        'classId': assetClass,
        'contentAst': [
          {'type': 'text', 'text': 'Asset'},
        ],
      }, 900));
      await appliers.apply(op('class.create', {
        'classId': bindingClass,
        'contentAst': [
          {'type': 'text', 'text': 'Source'},
        ],
      }, 950));
      await appliers.apply(basePage(page, 1000));
      await appliers.apply(op('object.create', {
        'objectId': assetNode,
        'isEmbedded': false,
        'classIds': [assetClass],
      }, 1100));
      await appliers.apply(basePage(plainNode, 1200));
      await appliers.apply(op('propertySchema.create', {
        'propertySchemaId': schema,
        'name': 'Attachment',
        'type': 'asset',
        'multi': true,
      }, 1300));
      await appliers.apply(op('class.property.set', {
        'classId': bindingClass,
        'propertySchemaId': schema,
      }, 1400));

      // A legacy bare-uuid carrier normalizes to {nodeId}.
      await appliers.apply(op('property.set', {
        'objectId': page,
        'propertySchemaId': schema,
        'value': assetNode,
      }, 1500));
      final rows = await raw(
        'SELECT value FROM property_value WHERE node_uuid = ? AND '
        'property_schema_id = ?',
        [page, schema],
      );
      expect(jsonDecode(rows.single['value'] as String),
          {'nodeId': assetNode});

      // A target NOT carrying the asset class fails loud (implicit
      // filter)…
      expect(
        () => appliers.apply(op('property.set', {
              'objectId': page,
              'propertySchemaId': schema,
              'value': {'nodeId': plainNode},
            }, 1600)),
        throwsA(isA<PropertyValueShapeError>()),
      );
      // …as does a nonexistent node…
      expect(
        () => appliers.apply(op('property.set', {
              'objectId': page,
              'propertySchemaId': schema,
              'value': {'nodeId': '0192a000-0000-7000-8000-00000000ffff'},
            }, 1700)),
        throwsA(isA<PropertyValueShapeError>()),
      );
      // …and a non-reference shape fails the type's shape check.
      expect(
        () => appliers.apply(op('property.set', {
              'objectId': page,
              'propertySchemaId': schema,
              'value': 'not-a-ref',
            }, 1800)),
        throwsA(isA<PropertyValueShapeError>()),
      );
      // Node-typed defaults stay unsupported: a defaultValue on an asset
      // schema fails loud at the schema (owner ruling 2026-10-20 — the
      // default moved from the binding to the schema; PC2 rejects a
      // node-linking default).
      expect(
        () => appliers.apply(op('propertySchema.update', {
              'propertySchemaId': schema,
              'defaultValue': {'nodeId': assetNode},
            }, 1900)),
        throwsA(isA<PropertyValueShapeError>()),
      );
      // …while an explicit null CLEAR validates (the keep/clear contract).
      await appliers.apply(op('propertySchema.update', {
        'propertySchemaId': schema,
        'defaultValue': null,
      }, 1950));
    });

    test('property-datetime lands the unified union: datetime schemas, the '
        'value writes, and the year-precision ceiling', () async {
      final envelopes = fixtureEnvelopes('property-datetime.json');
      for (final envelope in envelopes) {
        expect(await appliers.apply(envelope), isTrue);
      }
      const when = '0192a000-0000-7000-8000-000000000810';
      const year = '0192a000-0000-7000-8000-000000000811';
      const note = '0192a000-0000-7000-8000-000000000812';

      final schemas = await raw(
        'SELECT uuid, type, date_precision FROM property_schema ORDER BY uuid',
      );
      expect(schemas.map((r) => [r['uuid'], r['type']]), [
        [when, 'datetime'],
        [year, 'datetime'],
      ]);
      expect(schemas[1]['date_precision'], 'year');

      // The last 'When' write wins the LWW slot: the timed range end.
      final rows = await raw(
        'SELECT value FROM property_value WHERE node_uuid = ? AND '
        'property_schema_id = ? AND idx = 0',
        [note, when],
      );
      expect(
        jsonDecode(rows.single['value'] as String),
        {
          'start': {'nodeId': '00000000-0000-0000-00dd-202407260000'},
          'end': {
            'nodeId': '00000000-0000-0000-00dd-202408020000',
            'time': '09:15',
          },
        },
      );
      final yearRows = await raw(
        'SELECT value FROM property_value WHERE node_uuid = ? AND '
        'property_schema_id = ? AND idx = 0',
        [note, year],
      );
      expect(jsonDecode(yearRows.single['value'] as String), {
        'nodeId': '00000000-0000-0000-00bb-202400000000',
      });

      // Fail-loud mirror of the applier checks (not carried by the
      // fixture's happy path): a mixed-shape value, a malformed time, a
      // timed value on a year ceiling, and a ghost slot ref all reject.
      const dayNode = '00000000-0000-0000-00dd-202407260000';
      const ghostDay = '00000000-0000-0000-00dd-203001010000';
      OperationEnvelope set(
        String schemaId,
        dynamic value,
        int physical,
      ) =>
          OperationEnvelope(
            id: '0192a000-0000-7000-8000-0000000009$physical',
            workspaceId: ws,
            actorId: '0192a000-0000-7000-8000-000000000002',
            deviceId: 'fixture-test-device',
            hlc: Hlc(physical: physical, logical: 0),
            affectedNodeIds: [note],
            opType: 'property.set',
            payload: {
              'objectId': note,
              'propertySchemaId': schemaId,
              'value': value,
              'idx': 0,
            },
            timestamp: '2026-09-24T12:00:35.000Z',
          );

      expect(
        () => appliers.apply(set(when, {'nodeId': dayNode, 'end': null}, 9000)),
        throwsA(isA<PropertyValueShapeError>()),
      );
      expect(
        () => appliers.apply(set(when, {'nodeId': dayNode, 'time': '25:00'}, 9100)),
        throwsA(isA<PropertyValueShapeError>()),
      );
      expect(
        () => appliers.apply(set(year, {'nodeId': dayNode, 'time': '08:00'}, 9200)),
        throwsA(isA<PropertyValueShapeError>()),
      );
      expect(
        () => appliers.apply(
            set(when, {'start': {'nodeId': ghostDay}, 'end': null}, 9300)),
        throwsA(isA<PropertyValueShapeError>()),
      );
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

    test('trash-empty hard-deletes every soft-trashed root; the restored '
        'page survives with no trash row', () async {
      // trash-empty.json: A (...f3) + child (...f4), B (...f5) + child
      // (...f6), C (...f7). A, then independently A's child, then B and C
      // are soft-deleted; C is restored; trash.empty lands last.
      const a = '0192a000-0000-7000-8000-0000000000f3';
      const aChild = '0192a000-0000-7000-8000-0000000000f4';
      const b = '0192a000-0000-7000-8000-0000000000f5';
      const bChild = '0192a000-0000-7000-8000-0000000000f6';
      const c = '0192a000-0000-7000-8000-0000000000f7';
      for (final envelope in fixtureEnvelopes('trash-empty.json')) {
        expect(await appliers.apply(envelope), isTrue);
      }

      // A and B went with their whole subtrees — the independently-trashed
      // child inside A's tree is consumed by A's purge, exactly the TS
      // reference's end state.
      for (final id in [a, aChild, b, bChild]) {
        expect(await cache.getByUuid(id), isNull, reason: id);
      }
      // C was restored BEFORE the empty: it survives, active, with no
      // trash_root row.
      final restored = await cache.getByUuid(c);
      expect(restored, isNotNull);
      expect(restored!.isArchived, isFalse);
      // No non-permanent trash rows remain for any fixture id (this store
      // purges trash_root rows on a permanent delete instead of
      // tombstoning — the documented tombstone-bookkeeping divergence).
      final rows = await raw(
        'SELECT node_id FROM trash_root WHERE node_id IN (?, ?, ?, ?, ?)',
        [a, aChild, b, bChild, c],
      );
      expect(rows, isEmpty);
    });

    test('external-ref: the canonical fixture converges — the re-set moves '
        'the mapping, the deletes tombstone, the hard delete purges', () async {
      final envelopes = fixtureEnvelopes('external-ref.json');
      for (final envelope in envelopes) {
        expect(await appliers.apply(envelope), isTrue);
      }

      // The gcal re-set MOVED the mapping A -> B (the higher HLC tuple
      // wins); the readwise delete tombstoned the ref; the def456 delete
      // tombstoned that ref too; ghi789 named A, whose permanent delete
      // purged the row with the subtree; readitlater re-set to B at ...750
      // (the last write) rides B, untouched by A's purge.
      expect(await cache.resolveExternalRef(ws, refGcal), extB);
      expect(await cache.resolveExternalRef(ws, refReaditlater), extB);
      expect(await cache.resolveExternalRef(ws, refReadwise), isNull);
      expect(await cache.resolveExternalRef(ws, refDef456), isNull);
      expect(await cache.resolveExternalRef(ws, refGhi789), isNull);
      expect(await cache.externalRefsOf(ws, extA), isEmpty);
      expect(await cache.externalRefsOf(ws, extB), [refGcal, refReaditlater]);

      // The one-record invariant: the live table holds the two B mappings,
      // the tombstones carry exactly the two winning deletes.
      final liveRows = await raw(
        'SELECT ref, node_id FROM external_ref WHERE workspace_id = ? '
        'ORDER BY ref',
        [ws],
      );
      expect(liveRows, [
        {'ref': refGcal, 'node_id': extB},
        {'ref': refReaditlater, 'node_id': extB},
      ]);
      final tombRows = await raw(
        'SELECT ref FROM external_ref_tombstone WHERE workspace_id = ? '
        'ORDER BY ref',
        [ws],
      );
      expect(
        tombRows.map((r) => r['ref']).toList(),
        [refDef456, refReadwise],
      );

      // Idempotent replay: every op re-applies to the identical state.
      for (final envelope in envelopes) {
        await appliers.apply(envelope);
      }
      expect(await cache.externalRefsOf(ws, extB), [refGcal, refReaditlater]);
      final liveAfter = await raw(
        'SELECT ref, node_id FROM external_ref WHERE workspace_id = ?',
        [ws],
      );
      expect(liveAfter, hasLength(2));
    });

    test('external-ref: the mapping ops converge under reverse delivery '
        '(the tombstones kill the stale sets)', () async {
      final envelopes = fixtureEnvelopes('external-ref.json');
      // The node creates and the permanent delete are causally ordered (a
      // hard delete cannot apply before its node's create) — the
      // convergence claim under reordering covers the MAPPING ops, whose
      // only interdependencies are the LWW tuples (the TS reference test
      // builds the scenario the same way).
      final creates = envelopes.take(2).toList();
      final mappingOps = envelopes.skip(2).take(9).toList();
      final purge = envelopes.last;

      Future<void> replay(List<OperationEnvelope> ops) async {
        for (final op in ops) {
          await appliers.apply(op);
        }
      }

      Future<void> expectConverged() async {
        expect(await cache.resolveExternalRef(ws, refGcal), extB);
        expect(await cache.resolveExternalRef(ws, refReaditlater), extB);
        expect(await cache.resolveExternalRef(ws, refReadwise), isNull);
        expect(await cache.resolveExternalRef(ws, refDef456), isNull);
        expect(await cache.resolveExternalRef(ws, refGhi789), isNull);
        expect(await cache.externalRefsOf(ws, extA), isEmpty);
        expect(await cache.externalRefsOf(ws, extB), [refGcal, refReaditlater]);
      }

      await replay([...creates, ...mappingOps, purge]);
      await expectConverged();

      // Fresh store, mapping ops reversed: the winning deletes land
      // FIRST, the stale sets LAST — the tombstones must drop them (the
      // divergence the tombstone exists to prevent).
      await database.close();
      final ffiDb2 = await databaseFactoryFfi.openDatabase(
        ':memory:',
        options: OpenDatabaseOptions(singleInstance: false),
      );
      database = AppDatabase.fromDatabase(ffiDb2);
      await database.initializeSchema();
      cache = NodeCacheRepository(database);
      appliers = RelayAppliers(cache);
      await replay([...creates, ...mappingOps.reversed, purge]);
      await expectConverged();
    });

    test('external_ref: soft-trash keeps the mappings (restore re-activates '
        'them intact); a hard delete purges', () async {
      const page = '0192a000-0000-7000-8000-000000000b20';
      await appliers.apply(basePage(page, 0));
      await appliers.apply(
          extRefOp('external_ref.set', {'ref': refGcal, 'nodeId': page}, 1));
      await appliers.apply(extRefOp(
          'external_ref.set', {'ref': refReadwise, 'nodeId': page}, 2));
      expect(await cache.externalRefsOf(ws, page), [refGcal, refReadwise]);

      // Soft-trash: the mappings ride.
      await appliers
          .apply(extRefOp('object.delete', {'objectId': page}, 3));
      expect(await cache.resolveExternalRef(ws, refGcal), page);
      expect(await cache.externalRefsOf(ws, page), [refGcal, refReadwise]);
      await appliers
          .apply(extRefOp('object.restore', {'objectId': page}, 4));
      expect(await cache.externalRefsOf(ws, page), [refGcal, refReadwise]);

      // Hard delete: the subtree's live rows are purged.
      await appliers.apply(extRefOp(
          'object.delete', {'objectId': page, 'permanent': true}, 5));
      expect(await cache.resolveExternalRef(ws, refGcal), isNull);
      expect(await cache.resolveExternalRef(ws, refReadwise), isNull);
      expect(await cache.externalRefsOf(ws, page), isEmpty);
    });

    test('external_ref: malformed payloads fail loud at the apply boundary '
        'and never touch state', () async {
      const page = '0192a000-0000-7000-8000-000000000b21';
      await appliers.apply(basePage(page, 0));

      Future<void> expectRejected(
              String opType, Map<String, dynamic> payload) =>
          expectLater(
            appliers.apply(extRefOp(opType, payload, 1)),
            throwsA(isA<EnvelopeValidationError>()),
          );

      await expectRejected(
          'external_ref.set', {'ref': '', 'nodeId': page});
      await expectRejected(
          'external_ref.set', {'ref': 'x' * 513, 'nodeId': page});
      await expectRejected('external_ref.set', {'ref': refGcal});
      await expectRejected(
          'external_ref.set', {'ref': refGcal, 'nodeId': 'not-a-uuid'});
      await expectRejected('external_ref.set',
          {'ref': refGcal, 'nodeId': page, 'kind': 'event'});
      await expectRejected('external_ref.delete', {'ref': ''});
      await expectRejected(
          'external_ref.delete', {'ref': refGcal, 'nodeId': page});

      expect(await cache.resolveExternalRef(ws, refGcal), isNull);
      final liveRows =
          await raw('SELECT COUNT(*) AS c FROM external_ref');
      expect(liveRows.single['c'], 0);
      final tombRows =
          await raw('SELECT COUNT(*) AS c FROM external_ref_tombstone');
      expect(tombRows.single['c'], 0);
    });

    test('typed-link mark then deleted lands the final content', () async {      await seedBaseWithBlock();
      for (final name in ['typed-link-mark.json', 'typed-link-mark-deleted.json']) {
        for (final envelope in fixtureEnvelopes(name)) {
          expect(await appliers.apply(envelope), isTrue);
        }
      }
      final block = await cache.getByUuid(nodeBlock);
      expect(
        jsonDecode(block!.name),
        [
          {'type': 'text', 'text': 'Kuhn cites earlier work.'},
        ],
      );
      expect(block.displayName, 'Kuhn cites earlier work.');
    });

    test('content updates converge regardless of order', () async {
      final mark = fixtureEnvelopes('typed-link-mark.json')[0];
      final deleted = fixtureEnvelopes('typed-link-mark-deleted.json')[0];

      Future<String> contentOf() async =>
          (await cache.getByUuid(nodeBlock))!.name;

      await seedBaseWithBlock();
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
      await seedBaseWithBlock();
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

    test('object.move beforeId lands B, C, D, A with one row per node',
        () async {
      for (final envelope in fixtureEnvelopes('object-move-before.json')) {
        expect(await appliers.apply(envelope), isTrue);
      }
      expect(
        (await cache.getChildren(moveBeforeP)).map((n) => n.uuid).toList(),
        [moveBeforeB, moveBeforeC, moveBeforeD, moveBeforeA],
      );
      // Exactly one row per node — no dual-parent residue (the position
      // lives on the node row; a second row for a child would mean
      // corruption).
      for (final child in [
        moveBeforeA,
        moveBeforeB,
        moveBeforeC,
        moveBeforeD,
      ]) {
        final rows = await raw(
          'SELECT COUNT(*) AS c FROM node_cache WHERE uuid = ?',
          [child],
        );
        expect(rows.single['c'], 1);
      }
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

    test('system-extends lock: seeded re-issue applies, deviations throw and '
        'change nothing', () async {
      final envelopes = fixtureEnvelopes('class-extends-system-lock.json');
      const event = '00000000-0000-0000-0001-000000000040';
      const meeting = '00000000-0000-0000-0001-000000000039';
      const userClass = '0192a000-0000-7000-8000-0000000000e1';

      // The 5-envelope PREFIX applies cleanly: a USER class may extend a
      // system base (conference talk extends meeting), and meeting → [event]
      // is the seeded re-issue (the seed/ensure convergence path).
      for (final envelope in envelopes.take(5)) {
        expect(await appliers.apply(envelope), isTrue);
      }
      Future<List<String>> parentsOf(String id) async => (await raw(
            'SELECT parent_class_id FROM class_extends WHERE class_id = ? '
            'ORDER BY parent_class_id',
            [id],
          ))
              .map((r) => r['parent_class_id'] as String)
              .toList();
      expect(await parentsOf(userClass), [meeting]);
      expect(await parentsOf(meeting), [event]);

      // The rejecting tail: detaching meeting's seeded parent, an extra
      // parent on meeting, and event gaining a parent (event has no seeded
      // parents — a system class is frozen to the empty set).
      for (final envelope in envelopes.skip(5)) {
        expect(() async => appliers.apply(envelope),
            throwsA(isA<SystemExtendsLockError>()));
      }

      // A thrown apply changes nothing: exactly the two prefix edges remain.
      final edgeCount =
          await raw('SELECT COUNT(*) AS c FROM class_extends');
      expect(edgeCount.single['c'], 2);
    });

    group('class-parentless-role (owner 2026-10-24)', () {
      const taskClass = '0192a000-0000-7000-8000-0000000000d1';
      const eventClass = '0192a000-0000-7000-8000-0000000000d2';
      const standaloneTask = '0192a000-0000-7000-8000-0000000000d3';
      const errandClass = '0192a000-0000-7000-8000-0000000000d4';

      OperationEnvelope op(
        String opType,
        Map<String, dynamic> payload,
        int physical,
      ) =>
          OperationEnvelope(
            id: '0192a000-0000-7000-8000-0000000006$physical',
            workspaceId: ws,
            actorId: '0192a000-0000-7000-8000-000000000002',
            deviceId: 'fixture-test-device',
            hlc: Hlc(physical: physical, logical: 0),
            affectedNodeIds: [payload['objectId'] ?? payload['classId'] ?? ''],
            opType: opType,
            payload: payload,
            timestamp: '2026-09-24T12:00:50.000Z',
          );

      test('the canonical fixture replays to the flag-aware derived state',
          () async {
        final envelopes = fixtureEnvelopes('class-parentless-role.json');

        // class.create maps the flag to the registry column; absent = NULL
        // (the icon/color two-table precedent collapses to class_cache —
        // classes have no node_cache row locally).
        expect(await appliers.apply(envelopes[0]), isTrue);
        expect(await appliers.apply(envelopes[1]), isTrue);
        expect(await cache.classParentlessRole(taskClass), 'block');
        expect(await cache.classParentlessRole(eventClass), isNull);

        // The standalone task node is the population the role bends:
        // parentless + a flagged class → Block role (no document chrome).
        expect(await appliers.apply(envelopes[2]), isTrue);
        final taskNode = await cache.getByUuid(standaloneTask);
        expect(taskNode!.parentUuid, isNull);
        expect(taskNode.isPage, isFalse);

        // class.update presence writes...
        expect(await appliers.apply(envelopes[3]), isTrue);
        expect(await cache.classParentlessRole(eventClass), 'block');
        // ...and present-null clears back to the page default.
        expect(await appliers.apply(envelopes[4]), isTrue);
        expect(await cache.classParentlessRole(eventClass), isNull);

        // Errand carries no flag of its own; the extends edge to the
        // flagged Task lands and the EFFECTIVE flag derives through the
        // closure (one-way demote, no stored value).
        expect(await appliers.apply(envelopes[5]), isTrue);
        expect(await appliers.apply(envelopes[6]), isTrue);
        expect(await cache.classParentlessRole(errandClass), isNull);
        expect(
          await raw(
            'SELECT 1 FROM class_hierarchy WHERE class_id = ? AND ancestor_id = ?',
            [errandClass, taskClass],
          ),
          hasLength(1),
        );
        expect(await cache.classEffectivelyBlockFlagged([errandClass]),
            isTrue);
        expect(await cache.classEffectivelyBlockFlagged([eventClass]),
            isFalse);

        // The inherited demote bends a member's role without any stored
        // value of its own: a parentless node created carrying Errand
        // lands is_page = 0.
        const errandNode = '0192a000-0000-7000-8000-000000000d10';
        expect(
          await appliers.apply(op('object.create', {
            'objectId': errandNode,
            'contentAst': [
              {'type': 'text', 'text': 'Pick up dry cleaning'},
            ],
            'classIds': [errandClass],
          }, 1000)),
          isTrue,
        );
        expect((await cache.getByUuid(errandNode))!.isPage, isFalse);
      });

      test('a re-issued flag-less class.create (the seed/ensure re-run) '
          'preserves the stored flag', () async {
        const task = '0192a000-0000-7000-8000-000000000601';
        expect(
          await appliers.apply(op('class.create', {
            'classId': task,
            'contentAst': [
              {'type': 'text', 'text': 'Task'},
            ],
            'parentlessRole': 'block',
          }, 100)),
          isTrue,
        );
        expect(
          await appliers.apply(op('class.create', {
            'classId': task,
            'contentAst': [
              {'type': 'text', 'text': 'Task'},
            ],
          }, 200)),
          isTrue,
        );
        expect(await cache.classParentlessRole(task), 'block');
      });

      test('a class.update flag flip re-derives the parentless members\' '
          'is_page bits', () async {
        const klass = '0192a000-0000-7000-8000-000000000602';
        const member = '0192a000-0000-7000-8000-000000000603';
        expect(
          await appliers.apply(op('class.create', {
            'classId': klass,
            'contentAst': [
              {'type': 'text', 'text': 'Quote'},
            ],
            'parentlessRole': 'block',
          }, 100)),
          isTrue,
        );
        expect(
          await appliers.apply(op('object.create', {
            'objectId': member,
            'classIds': [klass],
          }, 200)),
          isTrue,
        );
        expect((await cache.getByUuid(member))!.isPage, isFalse);
        // Clearing the flag promotes the member back to the Page role.
        expect(
          await appliers.apply(op('class.update', {
            'classId': klass,
            'parentlessRole': null,
          }, 300)),
          isTrue,
        );
        expect(await cache.classParentlessRole(klass), isNull);
        expect((await cache.getByUuid(member))!.isPage, isTrue);
        // Setting it again demotes once more.
        expect(
          await appliers.apply(op('class.update', {
            'classId': klass,
            'parentlessRole': 'block',
          }, 400)),
          isTrue,
        );
        expect((await cache.getByUuid(member))!.isPage, isFalse);
      });

      test('the parent-page guard is flag-aware: no standalone claim under '
          'a block-role parentless node', () async {
        const task = '0192a000-0000-7000-8000-000000000620';
        const parent = '0192a000-0000-7000-8000-000000000621';
        const child = '0192a000-0000-7000-8000-000000000622';
        const wanted = '0192a000-0000-7000-8000-000000000623';
        const mover = '0192a000-0000-7000-8000-000000000624';
        expect(
          await appliers.apply(op('class.create', {
            'classId': task,
            'contentAst': [
              {'type': 'text', 'text': 'Task'},
            ],
            'parentlessRole': 'block',
          }, 100)),
          isTrue,
        );
        expect(
          await appliers.apply(op('object.create', {
            'objectId': parent,
            'classIds': [task],
            'contentAst': [
              {'type': 'text', 'text': 'Fix sink'},
            ],
          }, 200)),
          isTrue,
        );
        expect((await cache.getByUuid(parent))!.isPage, isFalse);

        // An EMBEDDED child under the block-role parentless node stays
        // legal (embedded blocks are the Block role's children).
        expect(
          await appliers.apply(op('object.create', {
            'objectId': child,
            'parentId': parent,
            'contentAst': [
              {'type': 'text', 'text': 'detail'},
            ],
          }, 300)),
          isTrue,
        );

        // A standalone claim (isEmbedded = false) under it fails loud — the
        // guard sees the same block role render sees.
        expect(
          () => appliers.apply(op('object.create', {
                'objectId': wanted,
                'parentId': parent,
                'isEmbedded': false,
                'contentAst': [
                  {'type': 'text', 'text': 'claim'},
                ],
              }, 400)),
          throwsA(isA<MoveGuardError>()),
        );
        // Promotion of the embedded child is rejected by the same guard.
        expect(
          () => appliers.apply(op('object.update', {
                'objectId': child,
                'isEmbedded': false,
              }, 500)),
          throwsA(isA<MoveGuardError>()),
        );
        // Moving a standalone node under it fails loud too.
        expect(
          await appliers.apply(op('object.create', {
            'objectId': mover,
            'isEmbedded': false,
            'contentAst': [
              {'type': 'text', 'text': 'page'},
            ],
          }, 600)),
          isTrue,
        );
        expect(
          () => appliers.apply(op('object.move', {
                'objectId': mover,
                'parentId': parent,
              }, 700)),
          throwsA(isA<MoveGuardError>()),
        );
      });
    });

    test('object-list-style lands numbered → alpha → clear, and styles the '
        'page itself', () async {
      const page = '0192a000-0000-7000-8000-00000000056a';
      const block = '0192a000-0000-7000-8000-00000000056b';
      final envelopes = fixtureEnvelopes('object-list-style.json');

      // create: the page starts bullet (null); the block seeds 'numbered'.
      expect(await appliers.apply(envelopes[0]), isTrue);
      expect(await appliers.apply(envelopes[1]), isTrue);
      expect((await cache.getByUuid(page))!.listStyle, isNull);
      expect((await cache.getByUuid(block))!.listStyle, 'numbered');

      // The payload and the v31 derived column project the same field.
      Future<String?> columnOf(String id) async => (await raw(
            'SELECT list_style FROM node_cache WHERE uuid = ?',
            [id],
          ))
              .single['list_style'] as String?;
      expect(await columnOf(block), 'numbered');

      // update re-styles ('alpha'), then present-null CLEARS to the bullet.
      expect(await appliers.apply(envelopes[2]), isTrue);
      expect((await cache.getByUuid(block))!.listStyle, 'alpha');
      expect(await appliers.apply(envelopes[3]), isTrue);
      expect((await cache.getByUuid(block))!.listStyle, isNull);
      expect(await columnOf(block), isNull);

      // The field is per-node and applier-unrestricted: the page styles too.
      expect(await appliers.apply(envelopes[4]), isTrue);
      expect((await cache.getByUuid(page))!.listStyle, 'roman');
      expect(await columnOf(page), 'roman');
    });

    test('property-schema-scope: extends-aware eligibility (R3), the R5 '
        'binding gate, widen/narrow keep-clear, and the eligible=false '
        'read', () async {
      const classA = '0192a000-0000-7000-8000-000000000901';
      const genre = '0192a000-0000-7000-8000-000000000910';
      const aNode = '0192a000-0000-7000-8000-000000000921';
      const bNode = '0192a000-0000-7000-8000-000000000922';
      const unclassed = '0192a000-0000-7000-8000-000000000923';
      final envelopes = fixtureEnvelopes('property-schema-scope.json');

      // Classes A, B (B extends A), the Genre schema scoped to A (with its
      // icon), the A-binding (R5 accept — the binding class is in scope).
      for (final envelope in envelopes.take(5)) {
        expect(await appliers.apply(envelope), isTrue);
      }
      final schemaRow = (await raw(
        'SELECT icon, scope_class_ids FROM property_schema WHERE uuid = ?',
        [genre],
      ))
          .single;
      expect(schemaRow['icon'], 'mdiTagOutline');
      expect(jsonDecode(schemaRow['scope_class_ids'] as String), [classA]);

      // R3: an A-classed node carries the scoped property...
      expect(await appliers.apply(envelopes[5]), isTrue); // create aNode
      // ...and so does a B-classed node — EXTENDS-AWARE eligibility (B's
      // closure carries the ancestor A).
      expect(await appliers.apply(envelopes[6]), isTrue); // create bNode
      expect(await appliers.apply(envelopes[7]), isTrue); // set aNode
      expect(await appliers.apply(envelopes[8]), isTrue); // set bNode
      expect(
        (await cache.propertyValuesFor(aNode)).map((v) => v.value).toList(),
        ['science fiction'],
      );
      expect(
        (await cache.propertyValuesFor(bNode)).map((v) => v.value).toList(),
        ['hard sci-fi'],
      );

      // R5 reject: binding a class OUTSIDE the scope is dead config and
      // fails loud (never applied).
      final foreignClass = '0192a000-0000-7000-8000-000000000930';
      await appliers.apply(OperationEnvelope(
        id: '0192a000-0000-7000-8000-000000000931',
        workspaceId: ws,
        actorId: '0192a000-0000-7000-8000-000000000002',
        deviceId: 'fixture-test-device',
        hlc: Hlc(physical: 1727200040350, logical: 0),
        affectedNodeIds: [foreignClass],
        opType: 'class.create',
        payload: {
          'classId': foreignClass,
          'contentAst': [
            {'type': 'text', 'text': 'Foreign'},
          ],
        },
        timestamp: '2026-09-24T12:00:40.350Z',
      ));
      expect(
        () => appliers.apply(OperationEnvelope(
          id: '0192a000-0000-7000-8000-000000000932',
          workspaceId: ws,
          actorId: '0192a000-0000-7000-8000-000000000002',
          deviceId: 'fixture-test-device',
          hlc: Hlc(physical: 1727200040360, logical: 0),
          affectedNodeIds: [foreignClass],
          opType: 'class.property.set',
          payload: {
            'classId': foreignClass,
            'propertySchemaId': genre,
          },
          timestamp: '2026-09-24T12:00:40.360Z',
        )),
        throwsA(isA<MoveGuardError>()),
      );

      // The unclassed page; the scope WIDENS to global (present-null
      // clears); its property.set rides while global.
      expect(await appliers.apply(envelopes[9]), isTrue); // create unclassed
      expect(await appliers.apply(envelopes[10]), isTrue); // scopeClassIds: null
      expect(
        (await raw(
          'SELECT scope_class_ids FROM property_schema WHERE uuid = ?',
          [genre],
        ))
            .single['scope_class_ids'],
        isNull,
      );
      expect(await appliers.apply(envelopes[11]), isTrue); // set unclassed
      expect(
        (await cache.propertyValuesFor(unclassed)).map((v) => v.value).toList(),
        ['authored while global'],
      );

      // The scope NARROWS back to A: narrowing is never retroactive — the
      // authored row survives in the log...
      expect(await appliers.apply(envelopes[12]), isTrue); // scopeClassIds: [A]
      expect(
        (await cache.propertyValuesFor(unclassed)).map((v) => v.value).toList(),
        ['authored while global'],
      );
      // ...and the effective read tags it eligible=false (the store suite
      // pins the same read in the TS reference).
      final effective = await cache.getEffectiveProperties(unclassed);
      expect(effective, hasLength(1));
      expect(effective.single.eligible, isFalse);
      expect(effective.single.source, 'authored');
      // The eligible nodes still read true.
      final aEffective = await cache.getEffectiveProperties(aNode);
      expect(aEffective.single.eligible, isTrue);
    });

    test('property-schema-update-fields: icon/multi/validationRules and '
        'targetClassFilter/scopeClassIds keep + clear through the '
        'lifecycle', () async {
      const score = '0192a000-0000-7000-8000-000000000960';
      const related = '0192a000-0000-7000-8000-000000000961';
      const filterClass = '0192a000-0000-7000-8000-000000000951';
      final envelopes = fixtureEnvelopes('property-schema-update-fields.json');

      Future<Map<String, dynamic>> rowOf(String id) async => (await raw(
            'SELECT icon, multi, validation_rules, class_filter_uuids, '
            'scope_class_ids FROM property_schema WHERE uuid = ?',
            [id],
          ))
          .single;

      expect(await appliers.apply(envelopes[0]), isTrue); // class
      expect(await appliers.apply(envelopes[1]), isTrue); // Score create
      expect(await rowOf(score), {
        'icon': null,
        'multi': 0,
        'validation_rules': null,
        'class_filter_uuids': '[]',
        'scope_class_ids': null,
      });

      // Set icon + multi + {min: 0, max: 10} rules.
      expect(await appliers.apply(envelopes[2]), isTrue);
      var scoreRow = await rowOf(score);
      expect(scoreRow['icon'], 'mdiStar');
      expect(scoreRow['multi'], 1);
      expect(
        jsonDecode(scoreRow['validation_rules'] as String),
        {'min': 0, 'max': 10},
      );

      // An absent-field update keeps them (name only).
      expect(await appliers.apply(envelopes[3]), isTrue);
      scoreRow = await rowOf(score);
      expect(scoreRow['icon'], 'mdiStar');
      expect(scoreRow['multi'], 1);
      expect(scoreRow['validation_rules'], isNotNull);
      expect(
        (await raw(
          'SELECT name FROM property_schema WHERE uuid = ?',
          [score],
        ))
            .single['name'],
        'Score (kept fields ride)',
      );

      // Present-null clears all three back to defaults.
      expect(await appliers.apply(envelopes[4]), isTrue);
      scoreRow = await rowOf(score);
      expect(scoreRow['icon'], isNull);
      expect(scoreRow['multi'], 0);
      expect(scoreRow['validation_rules'], isNull);

      // Related gains a targetClassFilter + scopeClassIds, then clears both.
      expect(await appliers.apply(envelopes[5]), isTrue);
      expect(await appliers.apply(envelopes[6]), isTrue);
      var relatedRow = await rowOf(related);
      expect(
        jsonDecode(relatedRow['class_filter_uuids'] as String),
        [filterClass],
      );
      expect(jsonDecode(relatedRow['scope_class_ids'] as String), [filterClass]);
      expect(await appliers.apply(envelopes[7]), isTrue);
      relatedRow = await rowOf(related);
      expect(relatedRow['class_filter_uuids'], '[]');
      expect(relatedRow['scope_class_ids'], isNull);

      // R2 applicability against the STORED type: min/max on a text schema
      // and a pattern on a number schema fail loud at the rule write.
      final textSchema = '0192a000-0000-7000-8000-000000000970';
      await appliers.apply(OperationEnvelope(
        id: '0192a000-0000-7000-8000-000000000971',
        workspaceId: ws,
        actorId: '0192a000-0000-7000-8000-000000000002',
        deviceId: 'fixture-test-device',
        hlc: Hlc(physical: 1727200042800, logical: 0),
        affectedNodeIds: [textSchema],
        opType: 'propertySchema.create',
        payload: {
          'propertySchemaId': textSchema,
          'name': 'Label',
          'type': 'text',
          'multi': false,
        },
        timestamp: '2026-09-24T12:00:42.800Z',
      ));
      expect(
        () => appliers.apply(OperationEnvelope(
          id: '0192a000-0000-7000-8000-000000000972',
          workspaceId: ws,
          actorId: '0192a000-0000-7000-8000-000000000002',
          deviceId: 'fixture-test-device',
          hlc: Hlc(physical: 1727200042810, logical: 0),
          affectedNodeIds: [],
          opType: 'propertySchema.update',
          payload: {
            'propertySchemaId': textSchema,
            'validationRules': {'min': 1},
          },
          timestamp: '2026-09-24T12:00:42.810Z',
        )),
        throwsA(isA<PropertyValueShapeError>()),
      );
      expect(
        () => appliers.apply(OperationEnvelope(
          id: '0192a000-0000-7000-8000-000000000973',
          workspaceId: ws,
          actorId: '0192a000-0000-7000-8000-000000000002',
          deviceId: 'fixture-test-device',
          hlc: Hlc(physical: 1727200042820, logical: 0),
          affectedNodeIds: [],
          opType: 'propertySchema.update',
          payload: {
            'propertySchemaId': score,
            'validationRules': {'pattern': '[a-z]+'},
          },
          timestamp: '2026-09-24T12:00:42.820Z',
        )),
        throwsA(isA<PropertyValueShapeError>()),
      );
    });

    test('property-validation-rules: the accepting prefix lands; each '
        'rejecting envelope throws on apply', () async {
      const owner = '0192a000-0000-7000-8000-000000001001';
      final envelopes = fixtureEnvelopes('property-validation-rules.json');
      // The rejecting tail: below-min/above-max number, two pattern rejects,
      // one bad multi element, one uncompilable pattern rule write.
      final accepting = envelopes.sublist(0, envelopes.length - 6);
      final rejecting = envelopes.sublist(envelopes.length - 6);
      for (final envelope in accepting) {
        expect(await appliers.apply(envelope), isTrue,
            reason: envelope.id);
      }

      final values = await cache.propertyValuesFor(owner);
      const rating = '0192a000-0000-7000-8000-000000001010';
      const slug = '0192a000-0000-7000-8000-000000001011';
      const homepage = '0192a000-0000-7000-8000-000000001012';
      const keywords = '0192a000-0000-7000-8000-000000001013';
      const note = '0192a000-0000-7000-8000-000000001014';
      const floor = '0192a000-0000-7000-8000-000000001015';
      const cap = '0192a000-0000-7000-8000-000000001016';
      const schemaLess = '0192a000-0000-7000-8000-00000000109f';
      expect(values.singleWhere((v) => v.schemaId == rating).value, 4);
      expect(values.singleWhere((v) => v.schemaId == slug).value, 'hello-world');
      expect(
        values.singleWhere((v) => v.schemaId == homepage).value,
        'https://example.com',
      );
      expect(
        values.singleWhere((v) => v.schemaId == keywords).value,
        'good',
      );
      expect(
        values.singleWhere((v) => v.schemaId == note).value,
        'ANYTHING at all! 123',
      );
      // Inclusive bounds: exactly min / exactly max ride.
      expect(values.singleWhere((v) => v.schemaId == floor).value, 0);
      expect(values.singleWhere((v) => v.schemaId == cap).value, 100);
      // Schema-less writes stay unchecked — any shape at any idx.
      expect(
        values.singleWhere((v) => v.schemaId == schemaLess).value,
        {'anything': true},
      );

      // Each rejecting envelope fails loud and is never applied.
      for (final envelope in rejecting) {
        expect(() => appliers.apply(envelope), throwsA(isA<PropertyValueShapeError>()),
            reason: '${envelope.id} (${envelope.opType}) must fail loud');
      }
      // The surviving state is untouched by the rejects.
      final after = await cache.propertyValuesFor(owner);
      expect(after.map((v) => v.schemaId).toSet(),
          values.map((v) => v.schemaId).toSet());
    });

    test('object-update-active fixture archives then unarchives via the '
        'active bit', () async {
      for (final envelope in fixtureEnvelopes('object-update-active.json')) {
        expect(await appliers.apply(envelope), isTrue);
      }
      const page = '0192a000-0000-7000-8000-000000000a20';
      const other = '0192a000-0000-7000-8000-000000000a21';
      // Archive page, archive the other page, unarchive page — one archived
      // node remains at the end (the default read hides it; the unarchived
      // one is back).
      expect((await cache.getByUuid(page))!.isArchived, isFalse);
      expect((await cache.getByUuid(other))!.isArchived, isTrue);
      // Archive is not deletion: no trash_root row on either arm.
      final trash = await raw(
        'SELECT node_id FROM trash_root WHERE node_id IN (?, ?)',
        [page, other],
      );
      expect(trash, isEmpty);
    });

    test('object-delete-class-routing fixture exercises all four arms; '
        'membership survives each', () async {
      const task = '00000000-0000-0000-0001-000000000012';
      const year = '00000000-0000-0000-0001-000000000003';
      const quote = '00000000-0000-0000-0001-000000000006';
      const genre = '0192a000-0000-7000-8000-000000000a23';
      const taskMember = '0192a000-0000-7000-8000-000000000a22';
      const genreMember = '0192a000-0000-7000-8000-000000000a24';
      final fixture = fixtureEnvelopes('object-delete-class-routing.json');
      final lockedDelete = fixture[5]; // the year delete — arm 1 fails loud
      for (final envelope in [...fixture.take(5), ...fixture.skip(6)]) {
        await appliers.apply(envelope);
      }
      // Arm 2 — family base (task): routed to the toggle, NOT trashed; the
      // family archives membership-preserving.
      expect(await cache.featureEnabledNow(ws, 'tasks'), isFalse);
      expect(await cache.classActiveState(task), isFalse);
      expect(
        await raw('SELECT 1 AS x FROM trash_root WHERE node_id = ?', [task]),
        isEmpty,
      );
      final taskMemberRow = await raw(
        'SELECT present FROM class_member_set WHERE node_uuid = ? AND class_id = ?',
        [taskMember, task],
      );
      expect(taskMemberRow.single['present'], 1);
      // Arm 3 — system class (quote): archived, NOT trashed.
      expect(await cache.classActiveState(quote), isFalse);
      expect(
        await raw('SELECT 1 AS x FROM trash_root WHERE node_id = ?', [quote]),
        isEmpty,
      );
      // Arm 4 — user class (Genre): plain trash row, memberships intact.
      expect(await cache.classActiveState(genre), isFalse);
      final genreTrash = await raw(
        'SELECT 1 AS x FROM trash_root WHERE node_id = ?',
        [genre],
      );
      expect(genreTrash, isNotEmpty);
      final genreMemberRow = await raw(
        'SELECT present FROM class_member_set WHERE node_uuid = ? AND class_id = ?',
        [genreMember, genre],
      );
      expect(genreMemberRow.single['present'], 1);
      expect((await cache.getByUuid(genreMember))!.classesUuid, [genre]);
      // Arm 1 — the locked delete still throws when applied deliberately,
      // and the year class stays active.
      expect(() => appliers.apply(lockedDelete),
          throwsA(isA<LockedSystemClassError>()));
      expect(await cache.classActiveState(year), isTrue);
    });

    test('re-applying the whole fixture set is state-idempotent', () async {
      final envelopes = allFixtureEnvelopes();
      // The typed-link updates (physical 2000/3000) lose the row-LWW race to
      // the object-move fixture (physical 7000+, which creates their target
      // ...020 = "Move Fixture" earlier in the alphabetical order) — the
      // same convergence the TS store's all-fixtures replay produces. The
      // page content stays the move fixture's title text; the typed-link
      // content landing is covered by the block-seeded test above.
      for (final envelope in envelopes) {
        await appliers.apply(envelope);
      }
      final moveFixture = await cache.getByUuid(moveP);
      expect(
        jsonDecode(moveFixture!.name),
        [
          {'type': 'text', 'text': 'Move Fixture'},
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
