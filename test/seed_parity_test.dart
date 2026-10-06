import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:notees/core/constants/system.dart';
import 'package:notees/data/local/app_database.dart';
import 'package:notees/domain/services/local_workspace_seed.dart';
import 'package:notees/domain/services/sync_v2_service.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

/// Seed-parity tests for the citations-model revision (2026-09-27), in
/// lockstep with the TS seed manifest (`packages/domain/src/seeds.ts`):
/// fixed UUIDs, never reused; new classes extend `source`; the `authors`
/// spec is verbatim-text (never node-typed person creation); `linkedAuthors`
/// is the explicit person linkage.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  sqfliteFfiInit();

  group('system UUID parity', () {
    test('all system class UUIDs are unique and live in the 0001 block', () {
      const uuids = <String>[
        SystemClassUuids.class_,
        SystemClassUuids.page,
        SystemClassUuids.year,
        SystemClassUuids.month,
        SystemClassUuids.day,
        SystemClassUuids.quote,
        SystemClassUuids.query,
        SystemClassUuids.code,
        SystemClassUuids.asset,
        SystemClassUuids.whiteboard,
        SystemClassUuids.card,
        SystemClassUuids.task,
        SystemClassUuids.template,
        SystemClassUuids.comment,
        SystemClassUuids.table,
        SystemClassUuids.warning,
        SystemClassUuids.note,
        SystemClassUuids.tip,
        SystemClassUuids.info,
        SystemClassUuids.danger,
        SystemClassUuids.success,
        SystemClassUuids.cloze,
        SystemClassUuids.source,
        SystemClassUuids.song,
        SystemClassUuids.tvSeries,
        SystemClassUuids.conference,
        SystemClassUuids.agent,
      ];
      expect(uuids.toSet(), hasLength(uuids.length), reason: 'unique class UUIDs');
      for (final uuid in uuids) {
        expect(
          uuid.startsWith('00000000-0000-0000-0001-'),
          isTrue,
          reason: 'class UUIDs live in the 0001 block: $uuid',
        );
      }
    });

    test('citations-revision class UUIDs match the TS manifest exactly', () {
      expect(SystemClassUuids.song, '00000000-0000-0000-0001-000000000036');
      expect(SystemClassUuids.tvSeries, '00000000-0000-0000-0001-000000000037');
      expect(SystemClassUuids.conference, '00000000-0000-0000-0001-000000000038');
      expect(SystemClassUuids.source, '00000000-0000-0000-0001-000000000023');
    });

    test('all system property UUIDs are unique and block-clean', () {
      const general = <String>[
        SystemPropertyUuids.tags,
        SystemPropertyUuids.showHierarchy,
        SystemPropertyUuids.usedIn,
        SystemPropertyUuids.cover,
        SystemPropertyUuids.banner,
        SystemPropertyUuids.description,
        SystemPropertyUuids.extends_,
        SystemPropertyUuids.whiteboardData,
        SystemPropertyUuids.authors,
      ];
      const task = <String>[
        SystemPropertyUuids.taskStatus,
        SystemPropertyUuids.taskDeadline,
        SystemPropertyUuids.taskScheduled,
        SystemPropertyUuids.taskPriority,
        SystemPropertyUuids.taskClosedDate,
        SystemPropertyUuids.taskRecurrence,
      ];
      expect(general.toSet(), hasLength(general.length));
      expect(task.toSet(), hasLength(task.length));
      expect(general.toSet().intersection(task.toSet()), isEmpty);
      for (final uuid in general) {
        expect(
          uuid.startsWith('00000000-0000-0000-0000-'),
          isTrue,
          reason: 'general property UUIDs live in the 0000 block: $uuid',
        );
      }
      for (final uuid in task) {
        expect(
          uuid.startsWith('00000000-0000-0000-0003-'),
          isTrue,
          reason: 'task property UUIDs live in the 0003 block: $uuid',
        );
      }
      expect(SystemPropertyUuids.authors,
          '00000000-0000-0000-0000-000000000012');
      // …0025 was withdrawn in the FINAL reversion (never reuse): the
      // constant is gone, so every constant in this file carries a live id.
    });
  });

  group('citations-revision seed specs', () {
    test('authors is node-typed (FINAL owner reversion)', () {
      final authors = LocalWorkspaceSeed.systemPropertySpecs
          .firstWhere((spec) => spec.name == 'authors');
      expect(authors.propertySchemaId, SystemPropertyUuids.authors);
      expect(authors.type, 'object');
      expect(authors.multi, isTrue);
      expect(authors.bindTo, 'source');
      expect(authors.targetClassFilter, [SystemClassUuids.agent]);
    });

    test('the linkedAuthors spec entry is gone (…0025 withdrawn)', () {
      expect(
        LocalWorkspaceSeed.systemPropertySpecs
            .where((spec) => spec.name == 'linkedAuthors'),
        isEmpty,
      );
      // No live constant references the withdrawn id: the value appears
      // nowhere in the seed specs.
      final referenced = <String>[
        for (final spec in LocalWorkspaceSeed.systemPropertySpecs)
          spec.propertySchemaId,
      ];
      expect(
        referenced.contains('00000000-0000-0000-0000-000000000025'),
        isFalse,
      );
    });

    test('new classes extend source with the TS manifest icons', () {
      for (final name in ['song', 'tv_series', 'conference']) {
        expect(LocalWorkspaceSeed.systemClassExtends[name], ['source']);
      }
      expect(LocalWorkspaceSeed.systemClassIcons['song'], 'mdiMusicNote');
      expect(LocalWorkspaceSeed.systemClassIcons['tv_series'],
          'mdiTelevisionClassic');
      expect(LocalWorkspaceSeed.systemClassIcons['conference'],
          'mdiPresentation');
      // The extends targets all resolve to seeded classes.
      final targets = <String>{
        for (final parents in LocalWorkspaceSeed.systemClassExtends.values)
          ...parents,
      };
      for (final target in targets) {
        expect(LocalWorkspaceSeed.systemClassNames.containsKey(target), isTrue,
            reason: 'extends target $target is seeded');
      }
    });

    test('seeded class UUIDs in the seed map stay unique', () {
      final uuids = LocalWorkspaceSeed.systemClassNames.values.toList();
      expect(uuids.toSet(), hasLength(uuids.length));
    });
  });

  group('seed emission', () {
    late AppDatabase database;
    late SyncV2Service syncService;

    setUp(() async {
      final ffiDb = await databaseFactoryFfi.openDatabase(
        ':memory:',
        options: OpenDatabaseOptions(singleInstance: false),
      );
      database = AppDatabase.fromDatabase(ffiDb);
      await database.initializeSchema();
      syncService = SyncV2Service(
        database: database,
        dio: Dio(),
        clientId: '40000000-0000-4000-8000-000000000001',
        serverless: true,
      );
      await syncService.setWorkspaceId('10000000-0000-4000-8000-000000000001');
    });

    tearDown(() async {
      await database.close();
      AppDatabase.reset();
    });

    test('emits the citations-revision classes, extends, and property specs',
        () async {
      final emitted =
          await LocalWorkspaceSeed(syncService).ensureLocalWorkspace();
      // 25 class.create + 3 class.setExtends + 1 propertySchema.create +
      // 1 class.property.set (authors, node-typed per the FINAL reversion)
      // + 1 object.create (Inbox; the scratchpad seed was withdrawn
      // 2026-10-05).
      expect(emitted, 31);

      final db = await database.database;

      // Icons landed on the new classes.
      final song = await db.rawQuery(
        'SELECT icon FROM class_cache WHERE uuid = ?',
        [SystemClassUuids.song],
      );
      expect(song.single['icon'], 'mdiMusicNote');

      // Extends edges + closure: the three new classes extend source.
      for (final classId in [
        SystemClassUuids.song,
        SystemClassUuids.tvSeries,
        SystemClassUuids.conference,
      ]) {
        final edges = await db.rawQuery(
          'SELECT parent_class_id FROM class_extends WHERE class_id = ?',
          [classId],
        );
        expect(edges.map((r) => r['parent_class_id']).toList(),
            [SystemClassUuids.source]);
        final closure = await db.rawQuery(
          'SELECT ancestor_id FROM class_hierarchy WHERE class_id = ? AND ancestor_id = ?',
          [classId, SystemClassUuids.source],
        );
        expect(closure, hasLength(1));
      }

      // Property schemas + bindings on source.
      for (final schemaId in [
        SystemPropertyUuids.authors,
      ]) {
        final schema = await db.rawQuery(
          'SELECT name, type, multi FROM property_schema WHERE uuid = ?',
          [schemaId],
        );
        expect(schema, hasLength(1));
        final binding = await db.rawQuery(
          'SELECT class_id FROM class_property WHERE property_schema_id = ?',
          [schemaId],
        );
        expect(binding.single['class_id'], SystemClassUuids.source);
      }
      final authorsRow = await db.rawQuery(
        'SELECT type, multi FROM property_schema WHERE uuid = ?',
        [SystemPropertyUuids.authors],
      );
      expect(authorsRow.single['type'], 'object');
      expect(authorsRow.single['multi'], 1);

      // Idempotent re-run emits nothing.
      expect(
        await LocalWorkspaceSeed(syncService).ensureLocalWorkspace(),
        0,
      );
    });
  });
}
