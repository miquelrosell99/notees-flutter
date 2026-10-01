import 'package:flutter_test/flutter_test.dart';
import 'package:notees/data/local/app_database.dart';
import 'package:notees/data/repositories/node_cache_repository.dart';
import 'package:notees/domain/models/relay/hlc.dart';
import 'package:notees/domain/models/relay/operation_envelope.dart';
import 'package:notees/domain/models/relay/operation_payloads.dart';
import 'package:notees/domain/models/relay/store_errors.dart';
import 'package:notees/domain/services/relay_appliers.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

/// Lockstep for first-class TAGS (2026-10-01, store schema v6 parity):
/// object.create's `tagIds` seeds the tag membership OR-Set and
/// `tag.unassign` is the OR-Set remove complement — identical gating to
/// class.unassign (strictly-greater on (hlc, actor)), own table
/// (`tag_member_set`). Mirrors the web store test "assign via create
/// carrier, unassign tombstones, re-add wins; tag_ids derived"
/// (packages/store/test/store.test.ts).
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  sqfliteFfiInit();

  const pageId = '0192a000-0000-7000-8000-000000000301';
  const tagA = '0192a000-0000-7000-8000-000000000302';
  const tagB = '0192a000-0000-7000-8000-000000000303';

  group('tag membership OR-Set', () {
    late AppDatabase database;
    late NodeCacheRepository cache;
    late RelayAppliers appliers;

    OperationEnvelope envelope({
      required String id,
      required String opType,
      required Map<String, dynamic> payload,
      required int physical,
      String actorId = '0192a000-0000-7000-8000-000000000002',
    }) =>
        OperationEnvelope(
          id: id,
          workspaceId: '0192a000-0000-7000-8000-000000000001',
          actorId: actorId,
          deviceId: 'test-device',
          hlc: Hlc(physical: physical, logical: 0),
          affectedNodeIds: [payload['objectId'] ?? ''],
          opType: opType,
          payload: payload,
          timestamp: '2026-10-01T12:00:00.000Z',
        );

    Future<void> createPage(String objectId, {int physical = 100}) =>
        appliers.apply(envelope(
          id: '0192a000-0000-7000-8000-0000000004$physical',
          opType: 'object.create',
          payload: OperationPayloads.objectCreate(
            objectId: objectId,
            nodeType: 'page',
          ),
          physical: physical,
        ));

    setUp(() async {
      final ffiDb = await databaseFactoryFfi.openDatabase(
        ':memory:',
        options: OpenDatabaseOptions(singleInstance: false),
      );
      database = AppDatabase.fromDatabase(ffiDb);
      await database.initializeSchema();
      cache = NodeCacheRepository(database);
      appliers = RelayAppliers(cache);
      await createPage(pageId);
      await createPage(tagA, physical: 110);
      await createPage(tagB, physical: 120);
    });

    tearDown(() async {
      await database.close();
      AppDatabase.reset();
    });

    Future<int> pairPresent() async {
      final db = await database.database;
      final rows = await db.rawQuery(
        'SELECT present FROM tag_member_set WHERE node_uuid = ? AND tag_id = ?',
        [pageId, tagA],
      );
      if (rows.isEmpty) return -1;
      return rows.single['present'] as int;
    }

    test('assign via the object.create carrier derives sorted tag_ids',
        () async {
      await appliers.apply(envelope(
        id: '0192a000-0000-7000-8000-000000000501',
        opType: 'object.create',
        payload: OperationPayloads.objectCreate(
          objectId: pageId,
          nodeType: 'page',
          tagIds: const [tagA, tagB],
        ),
        physical: 200,
      ));
      expect(await pairPresent(), 1);
      expect((await cache.getByUuid(pageId))!.tagsUuid, [tagA, tagB]);
    });

    test('tag.unassign tombstones the pair; tag_ids recompute', () async {
      await appliers.apply(envelope(
        id: '0192a000-0000-7000-8000-000000000502',
        opType: 'object.create',
        payload: OperationPayloads.objectCreate(
          objectId: pageId,
          nodeType: 'page',
          tagIds: const [tagA, tagB],
        ),
        physical: 200,
      ));
      await appliers.apply(envelope(
        id: '0192a000-0000-7000-8000-000000000503',
        opType: 'tag.unassign',
        payload: OperationPayloads.tagUnassign(objectId: pageId, tagId: tagA),
        physical: 300,
      ));
      expect(await pairPresent(), 0);
      expect((await cache.getByUuid(pageId))!.tagsUuid, [tagB]);
    });

    test('a stale re-add (lower HLC than the remove) loses', () async {
      await appliers.apply(envelope(
        id: '0192a000-0000-7000-8000-000000000504',
        opType: 'object.create',
        payload: OperationPayloads.objectCreate(
          objectId: pageId,
          nodeType: 'page',
          tagIds: const [tagA, tagB],
        ),
        physical: 200,
      ));
      await appliers.apply(envelope(
        id: '0192a000-0000-7000-8000-000000000505',
        opType: 'tag.unassign',
        payload: OperationPayloads.tagUnassign(objectId: pageId, tagId: tagA),
        physical: 300,
      ));
      // Re-issue the add at an OLDER HLC than the remove: gated out.
      await appliers.apply(envelope(
        id: '0192a000-0000-7000-8000-000000000506',
        opType: 'object.create',
        payload: OperationPayloads.objectCreate(
          objectId: pageId,
          nodeType: 'page',
          tagIds: const [tagA],
        ),
        physical: 250,
      ));
      expect(await pairPresent(), 0, reason: 'stale re-add loses');
      expect((await cache.getByUuid(pageId))!.tagsUuid, [tagB]);
    });

    test('a newer re-add wins (idempotent re-assign)', () async {
      await appliers.apply(envelope(
        id: '0192a000-0000-7000-8000-000000000507',
        opType: 'object.create',
        payload: OperationPayloads.objectCreate(
          objectId: pageId,
          nodeType: 'page',
          tagIds: const [tagA, tagB],
        ),
        physical: 200,
      ));
      await appliers.apply(envelope(
        id: '0192a000-0000-7000-8000-000000000508',
        opType: 'tag.unassign',
        payload: OperationPayloads.tagUnassign(objectId: pageId, tagId: tagA),
        physical: 300,
      ));
      // Re-assign with a newer HLC: the add wins, tag_ids re-derive sorted.
      await appliers.apply(envelope(
        id: '0192a000-0000-7000-8000-000000000509',
        opType: 'object.create',
        payload: OperationPayloads.objectCreate(
          objectId: pageId,
          nodeType: 'page',
          tagIds: const [tagA],
        ),
        physical: 400,
      ));
      expect(await pairPresent(), 1);
      expect((await cache.getByUuid(pageId))!.tagsUuid, [tagA, tagB]);

      // An exact re-issue at a still-newer HLC is a no-op on the projection
      // (no duplicates — the pair row is add-wins).
      await appliers.apply(envelope(
        id: '0192a000-0000-7000-8000-00000000050a',
        opType: 'object.create',
        payload: OperationPayloads.objectCreate(
          objectId: pageId,
          nodeType: 'page',
          tagIds: const [tagA],
        ),
        physical: 500,
      ));
      expect((await cache.getByUuid(pageId))!.tagsUuid, [tagA, tagB]);
      final db = await database.database;
      final rows = await db.rawQuery(
        'SELECT COUNT(*) AS c FROM tag_member_set WHERE node_uuid = ? AND tag_id = ?',
        [pageId, tagA],
      );
      expect(rows.single['c'], 1, reason: 'one pair row per (node, tag)');
    });

    test('exact-HLC tie: strictly-greater gating, first write wins', () async {
      // Add at HLC 300, remove at the SAME HLC: the remove's strictly-
      // greater comparator loses the tie → the add stands (tag gating is
      // `>` on both sides, unlike the class add's `>=`).
      await appliers.apply(envelope(
        id: '0192a000-0000-7000-8000-00000000050b',
        opType: 'object.create',
        payload: OperationPayloads.objectCreate(
          objectId: pageId,
          nodeType: 'page',
          tagIds: const [tagA],
        ),
        physical: 300,
      ));
      await appliers.apply(envelope(
        id: '0192a000-0000-7000-8000-00000000050c',
        opType: 'tag.unassign',
        payload: OperationPayloads.tagUnassign(objectId: pageId, tagId: tagA),
        physical: 300,
      ));
      expect(await pairPresent(), 1);
      expect((await cache.getByUuid(pageId))!.tagsUuid, [tagA]);

      // Remove first at HLC 300, then the add at the same HLC: the add's
      // strictly-greater comparator loses the tie → the remove stands.
      await appliers.apply(envelope(
        id: '0192a000-0000-7000-8000-00000000050d',
        opType: 'tag.unassign',
        payload: OperationPayloads.tagUnassign(objectId: pageId, tagId: tagB),
        physical: 300,
      ));
      await appliers.apply(envelope(
        id: '0192a000-0000-7000-8000-00000000050e',
        opType: 'object.create',
        payload: OperationPayloads.objectCreate(
          objectId: pageId,
          nodeType: 'page',
          tagIds: const [tagB],
        ),
        physical: 300,
      ));
      final db = await database.database;
      final rows = await db.rawQuery(
        'SELECT present FROM tag_member_set WHERE node_uuid = ? AND tag_id = ?',
        [pageId, tagB],
      );
      expect(rows.single['present'], 0, reason: 'remove wins the tie');
    });

    test('tag.unassign on a missing node throws NodeNotFoundError', () {
      expect(
        () async => appliers.apply(envelope(
          id: '0192a000-0000-7000-8000-00000000050f',
          opType: 'tag.unassign',
          payload: OperationPayloads.tagUnassign(
            objectId: '0192a000-0000-7000-8000-000000000499',
            tagId: tagA,
          ),
          physical: 1,
        )),
        throwsA(isA<NodeNotFoundError>()),
      );
    });

    test('an invalid payload fails loud at the validator gate', () {
      expect(
        () async => appliers.apply(envelope(
          id: '0192a000-0000-7000-8000-000000000510',
          opType: 'tag.unassign',
          payload: {
            'objectId': pageId,
            'tagId': tagA,
            'name': 'retired key',
          },
          physical: 1,
        )),
        throwsA(isA<EnvelopeValidationError>()),
      );
    });
  });
}
