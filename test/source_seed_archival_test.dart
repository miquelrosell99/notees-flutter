import 'package:flutter_test/flutter_test.dart';
import 'package:notees/core/constants/system.dart';
import 'package:notees/data/local/app_database.dart';
import 'package:notees/data/repositories/node_cache_repository.dart';
import 'package:notees/domain/models/relay/hlc.dart';
import 'package:notees/domain/models/relay/operation_envelope.dart';
import 'package:notees/domain/models/relay/operation_payloads.dart';
import 'package:notees/domain/services/relay_appliers.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

/// The store-side half of the source-library slice (lockstep with the monorepo's `packages/store` changes in
/// `2441de071` + `packages/store/test/source-seed.test.ts`): archival is
/// VISIBILITY state, not an absence — an archived class (the 18
/// archived-by-default roster types, a feature toggle-off) still IS-A its
/// extends parents, and a re-issued `class.create` (the seed/ensure
/// idempotent re-run) must NOT revive an archived class.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  sqfliteFfiInit();

  const ws = '0192a000-0000-7000-8000-000000000001';
  const actor = '0192a000-0000-7000-8000-000000000002';

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
      affectedNodeIds: const [],
      opType: opType,
      payload: payload,
      timestamp: '2026-10-23T12:00:00.000Z',
    );
  }

  Future<void> createClass(String classId, {required String name}) =>
      appliers.apply(env(
        'class.create',
        OperationPayloads.classCreate(classId: classId, name: name),
        1,
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

  Future<void> archive(String classId) => appliers.apply(env(
        'object.update',
        OperationPayloads.objectUpdate(objectId: classId, active: false),
        1,
      ));

  Future<List<String>> closureOf(String classId) async {
    final db = await database.database;
    final rows = await db.rawQuery(
      'SELECT ancestor_id FROM class_hierarchy WHERE class_id = ? '
      'ORDER BY ancestor_id',
      [classId],
    );
    return [for (final row in rows) row['ancestor_id'] as String];
  }

  Future<int> activeBitOf(String classId) async {
    final db = await database.database;
    final rows = await db.rawQuery(
      'SELECT active FROM class_cache WHERE uuid = ?',
      [classId],
    );
    expect(rows, hasLength(1));
    return rows.single['active'] as int;
  }

  /// The archived-by-default seed shape: book_section (enabled in the
  /// roster) and artwork/patent (archived by default) extend source.
  Future<void> seedSourceFamily() async {
    await createClass(SystemClassUuids.source, name: 'Source');
    for (final entry in [
      (SystemClassUuids.bookSection, 'Book section'),
      (SystemClassUuids.artwork, 'Artwork'),
      (SystemClassUuids.patent, 'Patent'),
    ]) {
      await createClass(entry.$1, name: entry.$2);
      await setExtends(entry.$1, [SystemClassUuids.source]);
    }
  }

  test('an archived class survives the later-extends closure rebuild', () async {
    await seedSourceFamily();
    // The archived-by-default flips land as object.update {active:false}
    // (the server seed's shape — 18 roster classes).
    await archive(SystemClassUuids.artwork);
    await archive(SystemClassUuids.patent);
    expect(await activeBitOf(SystemClassUuids.artwork), 0);
    expect(await activeBitOf(SystemClassUuids.bookSection), 1);

    // An UNRELATED later setExtends rebuilds the whole closure — the
    // archived classes must keep their extends resolution (archival is
    // visibility, not absence: an archived-by-default type still IS-A
    // source).
    await createClass(SystemClassUuids.journalArticle, name: 'Journal article');
    await setExtends(SystemClassUuids.journalArticle, [SystemClassUuids.source]);

    final sorted = <String>[SystemClassUuids.artwork, SystemClassUuids.source]
      ..sort();
    expect(await closureOf(SystemClassUuids.artwork), sorted);
    final sortedPatent = <String>[SystemClassUuids.patent, SystemClassUuids.source]
      ..sort();
    expect(await closureOf(SystemClassUuids.patent), sortedPatent);
    final sortedBookSection = <String>[
      SystemClassUuids.bookSection,
      SystemClassUuids.source,
    ]..sort();
    expect(await closureOf(SystemClassUuids.bookSection), sortedBookSection);

    // The closure-backed ancestor read (the extends-aware membership test)
    // resolves the archived class through source.
    final ancestors = await cache.classHierarchyAncestorsOf(
      [SystemClassUuids.artwork],
    );
    expect(ancestors, contains(SystemClassUuids.source));
  });

  test('class.create re-issue does NOT revive an archived class', () async {
    await seedSourceFamily();
    await archive(SystemClassUuids.artwork);
    expect(await activeBitOf(SystemClassUuids.artwork), 0);

    // The seed/ensure idempotent re-run re-issues class.create with the
    // same payload — the conflict arm must preserve the archival bit
    // (revival is object.update / the feature
    // derivation / restore's job, never re-declaration).
    await createClass(SystemClassUuids.artwork, name: 'Artwork');
    expect(await activeBitOf(SystemClassUuids.artwork), 0);

    // A fresh class still seeds active.
    await createClass(SystemClassUuids.preprint, name: 'Preprint');
    expect(await activeBitOf(SystemClassUuids.preprint), 1);
  });

  test('an archived-type node still resolves the family through extends',
      () async {
    await seedSourceFamily();
    await archive(SystemClassUuids.artwork);

    // A node classed by the ARCHIVED type carries the class; the
    // closure-backed ancestor read (what class:/classAny filters and the
    // effective-properties walk use) still sees source.
    const nodeId = '0192a000-0000-7000-8000-0000000000aa';
    await appliers.apply(env(
      'object.create',
      OperationPayloads.objectCreate(
        objectId: nodeId,
        isEmbedded: false,
        classIds: const [SystemClassUuids.artwork],
        contentAst: const [
          {'type': 'text', 'text': 'A painting'},
        ],
      ),
      1,
    ));
    final ancestors = await cache.classHierarchyAncestorsOf(
      [SystemClassUuids.artwork],
    );
    expect(ancestors, contains(SystemClassUuids.source));
  });
}
