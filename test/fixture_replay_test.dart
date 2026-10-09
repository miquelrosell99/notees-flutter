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
/// here. The cycle fixture is deliberately excluded from the all-fixtures
/// replay: its final two envelopes close cycles and MUST throw CycleError
/// on apply (see the cycle test).
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
        payload: {
          'objectId': nodeId,
          'presentAsMain': true,
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
      expect(page!.presentAsMain, isTrue);
      expect(page.isPage, isTrue);
      expect(book, isNotNull);
      expect(book!.presentAsMain, isTrue);
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
      expect(node.presentAsMain, isFalse);
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
        'SELECT uuid, type, multi, scope, name FROM property_schema '
        'ORDER BY uuid',
      );
      expect(rows, hasLength(2));
      expect(rows[0]['uuid'], '0192a000-0000-7000-8000-000000000541');
      expect(rows[0]['type'], 'asset');
      expect(rows[0]['multi'], 1);
      expect(rows[0]['scope'], 'class');
      expect(rows[0]['name'], 'Attachment');
      expect(rows[1]['uuid'], '0192a000-0000-7000-8000-000000000542');
      expect(rows[1]['type'], 'asset');
      expect(rows[1]['multi'], 0);
      expect(rows[1]['scope'], 'object');
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
        'presentAsMain': true,
        'classIds': [assetClass],
      }, 1100));
      await appliers.apply(basePage(plainNode, 1200));
      await appliers.apply(op('propertySchema.create', {
        'propertySchemaId': schema,
        'name': 'Attachment',
        'type': 'asset',
        'multi': true,
        'scope': 'class',
      }, 1300));
      await appliers.apply(op('class.property.set', {
        'classId': bindingClass,
        'propertySchemaId': schema,
        'sequence': 0,
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
      // schema fails loud at the binding.
      expect(
        () => appliers.apply(op('class.property.set', {
              'classId': bindingClass,
              'propertySchemaId': schema,
              'defaultValue': {'nodeId': assetNode},
            }, 1900)),
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

    test('typed-link mark then deleted lands the final content', () async {
      await seedBaseWithBlock();
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
