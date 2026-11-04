import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:notees/data/local/app_database.dart';
import 'package:notees/data/repositories/graph_repository.dart';
import 'package:notees/data/repositories/node_cache_repository.dart';
import 'package:notees/domain/graph/graph_model.dart';
import 'package:notees/domain/models/relay/hlc.dart';
import 'package:notees/domain/models/relay/operation_envelope.dart';
import 'package:notees/domain/models/relay/operation_payloads.dart';
import 'package:notees/domain/services/relay_appliers.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

/// The graph-topology pins over the seeded ffi store: the node set is
/// classes + standalone pages ONLY (blocks never render as graph nodes,
/// deleted/archived/journal rows drop), the typed edge families ride the
/// derived `edge` index (mention / tag / property) plus the structural
/// parent family, an edge endpoint outside the node set rolls up to its
/// nearest node-set ancestor (the web graph.ts rollup — a block's mention
/// lands between the block's page and the target), parallel same-family
/// edges collapse into one weighted edge, and rolled-up self-links drop.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  sqfliteFfiInit();

  const ws = '0192a000-0000-7000-8000-000000000001';
  const pageA = '0192a000-0000-7000-8000-000000000101';
  const pageB = '0192a000-0000-7000-8000-000000000102';
  const pageC = '0192a000-0000-7000-8000-000000000103';
  const subPage = '0192a000-0000-7000-8000-000000000104';
  const block = '0192a000-0000-7000-8000-000000000105';
  const blockLoop = '0192a000-0000-7000-8000-000000000109';
  const tagT = '0192a000-0000-7000-8000-000000000106';
  const classK = '0192a000-0000-7000-8000-000000000107';
  const journalDay = '0192a000-0000-7000-8000-000000000108';

  late AppDatabase database;
  late NodeCacheRepository cache;
  late RelayAppliers appliers;
  late GraphRepository graph;

  OperationEnvelope envelope({
    required String opType,
    required Map<String, dynamic> payload,
    required int physical,
  }) =>
      OperationEnvelope(
        id: '0192a000-0000-7000-8000-0000000003$physical',
        workspaceId: ws,
        actorId: '0192a000-0000-7000-8000-000000000002',
        deviceId: 'test-device',
        hlc: Hlc(physical: physical, logical: 0),
        affectedNodeIds: [payload['objectId'] ?? ''],
        opType: opType,
        payload: payload,
        timestamp: '2026-11-04T12:00:00.000Z',
      );

  Future<void> create(
    String objectId, {
    int physical = 100,
    String? name,
    List<Map<String, dynamic>>? contentAst,
    List<String>? tagIds,
    List<String>? classIds,
    String? parentId,
    bool? isEmbedded,
  }) =>
      appliers.apply(envelope(
        opType: 'object.create',
        payload: OperationPayloads.objectCreate(
          objectId: objectId,
          name: name,
          contentAst: contentAst,
          tagIds: tagIds,
          classIds: classIds,
          parentId: parentId,
          isEmbedded: isEmbedded,
        ),
        physical: physical,
      ));

  Future<void> insertClassCacheRow(String uuid, String title) async {
    final db = await database.database;
    await db.insert('class_cache', {
      'uuid': uuid,
      'name': jsonEncode([
        {'type': 'text', 'text': title}
      ]),
      'active': 1,
    });
  }

  setUp(() async {
    final ffiDb = await databaseFactoryFfi.openDatabase(
      ':memory:',
      options: OpenDatabaseOptions(singleInstance: false),
    );
    database = AppDatabase.fromDatabase(ffiDb);
    await database.initializeSchema();
    cache = NodeCacheRepository(database);
    appliers = RelayAppliers(cache);
    graph = GraphRepository(database, cache: cache);
  });

  tearDown(() async {
    await database.close();
    AppDatabase.reset();
  });

  group('the node set', () {
    test('classes + standalone pages only; blocks, journal, deleted drop',
        () async {
      await create(pageA, name: 'Alpha');
      await create(pageB, name: 'Beta', physical: 110);
      await create(block,
          name: 'a block', parentId: pageA, isEmbedded: true, physical: 120);
      await create(subPage,
          name: 'Sub page',
          parentId: pageA,
          isEmbedded: false,
          physical: 130);
      await create(journalDay,
          name: '20261104',
          classIds: const ['00000000-0000-0000-0001-000000000005'],
          physical: 140);
      await create(classK, name: 'Meeting', physical: 150);
      await insertClassCacheRow(classK, 'Meeting');

      final top = await graph.loadTopology();
      final ids = top.nodes.map((n) => n.id).toSet();
      expect(ids, containsAll([pageA, pageB, subPage, classK]));
      expect(ids, isNot(contains(block)));
      expect(ids, isNot(contains(journalDay)));

      final classNode = top.nodes.firstWhere((n) => n.id == classK);
      expect(classNode.isClass, isTrue);
      expect(classNode.label, 'Meeting');
      final alpha = top.nodes.firstWhere((n) => n.id == pageA);
      expect(alpha.isClass, isFalse);
      expect(alpha.label, 'Alpha');
    });

    test('archived pages drop from the node set', () async {
      await create(pageA, name: 'Alpha');
      await create(pageB, name: 'Beta', physical: 110);
      final db = await database.database;
      await db.update('node_cache', {'is_archived': 1},
          where: 'uuid = ?', whereArgs: [pageB]);
      final top = await graph.loadTopology();
      expect(top.nodes.map((n) => n.id), [pageA]);
    });
  });

  group('the edge families', () {
    setUp(() async {
      await create(pageA, name: 'Alpha');
      await create(pageB,
          name: 'Beta', physical: 110, tagIds: const [tagT]);
      await create(pageC,
          name: 'Gamma',
          physical: 115,
          // A parentless page's content flattens text-only (the
          // Revision-11 contract), so its own mention token derives NO
          // edge — the surviving mentions live on the embedded blocks.
          contentAst: const [
            {'type': 'text', 'text': 'see '},
            {'type': 'mention', 'targetNodeId': pageA},
          ]);
      await create(block,
          name: 'a block',
          parentId: pageA,
          isEmbedded: true,
          physical: 120,
          contentAst: const [
            {'type': 'text', 'text': 'links '},
            {'type': 'mention', 'targetNodeId': pageB},
            {'type': 'mention', 'targetNodeId': pageB},
          ]);
      await create(blockLoop,
          name: 'a self-linking block',
          parentId: pageA,
          isEmbedded: true,
          physical: 125,
          contentAst: const [
            {'type': 'mention', 'targetNodeId': pageA},
          ]);
      await create(subPage,
          name: 'Sub page', parentId: pageA, isEmbedded: false, physical: 130);
      await create(tagT, name: 'topic', physical: 140);
    });

    test('a block\'s mentions roll up to its page and collapse to weight',
        () async {
      final top = await graph.loadTopology();
      final mentions = top.edges
          .where((e) => e.kind == GraphEdgeKind.mention)
          .toList();
      expect(mentions, hasLength(1));
      expect(mentions.single.source, pageA);
      expect(mentions.single.target, pageB);
      // Two mention tokens on one target collapse into one weighted edge.
      expect(mentions.single.weight, 2);
    });

    test('a page\'s own flattened mention derives no edge', () async {
      final top = await graph.loadTopology();
      expect(
        top.edges.any((e) => e.source == pageC || e.target == pageC),
        isFalse,
      );
    });

    test('a rolled-up self-link drops (the block mentions its own page)',
        () async {
      final top = await graph.loadTopology();
      expect(top.edges.any((e) => e.source == pageA && e.target == pageA),
          isFalse);
    });

    test('tag membership rides the edge index as the tag family', () async {
      final top = await graph.loadTopology();
      final tags = top.edges.where((e) => e.kind == GraphEdgeKind.tag).toList();
      expect(tags, hasLength(1));
      expect(tags.single.source, pageB);
      expect(tags.single.target, tagT);
    });

    test('the parent family links node-set members only', () async {
      final top = await graph.loadTopology();
      final parents =
          top.edges.where((e) => e.kind == GraphEdgeKind.parent).toList();
      expect(parents, hasLength(1));
      expect(parents.single.source, pageA);
      expect(parents.single.target, subPage);
    });

    test('the property family rides the edge index too', () async {
      // Direct edge-table row: the family-filter contract is what is pinned
      // here (the property-value op path is covered by the edge-index port's
      // own pins); the row shape is exactly what rebuildEdges writes.
      final db = await database.database;
      await db.insert('edge', {
        'id': 'e-prop-1',
        'source_id': pageA,
        'target_id': pageB,
        'type': 'property',
        'verb': '0192a000-0000-7000-8000-000000000501',
      });
      final top = await graph.loadTopology();
      final props =
          top.edges.where((e) => e.kind == GraphEdgeKind.property).toList();
      expect(props, hasLength(1));
      expect(props.single.source, pageA);
      expect(props.single.target, pageB);
    });

    test('typed-link rows (deferred resolution, null target) drop', () async {
      final before = await graph.loadTopology();
      final db = await database.database;
      await db.insert('edge', {
        'id': 'e-tl-1',
        'source_id': pageA,
        'target_id': null,
        'type': 'typed_link',
        'verb': 'meets',
      });
      final top = await graph.loadTopology();
      // The row contributes nothing — the topology is byte-identical.
      expect(top.edges.map((e) => '${e.source}>${e.target}:${e.kind.name}:${e.weight}').toList(),
          before.edges.map((e) => '${e.source}>${e.target}:${e.kind.name}:${e.weight}').toList());
    });

    test('degree counts collapsed incident edges on both endpoints', () async {
      final top = await graph.loadTopology();
      expect(top.degreeOf(pageA), 2); // mention to B, parent to subPage
      expect(top.degreeOf(pageB), 2); // mention from A, tag to tagT
      expect(top.degreeOf(pageC), 0);
      expect(top.degreeOf(subPage), 1);
      expect(top.degreeOf(tagT), 1);
      expect(top.degreeOf('nope'), 0);
    });
  });
}
