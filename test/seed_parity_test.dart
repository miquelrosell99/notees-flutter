import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:notees/core/constants/system.dart';
import 'package:notees/data/local/app_database.dart';
import 'package:notees/domain/models/relay/workspace_features.dart';
import 'package:notees/domain/services/local_workspace_seed.dart';
import 'package:notees/domain/services/sync_v2_service.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

/// Seed-parity tests for the citations-model revision (2026-09-27), in
/// lockstep with the TS seed manifest (`packages/domain/src/seeds.ts`):
/// fixed UUIDs, never reused; new classes extend `source`; the `authors`
/// spec is verbatim-text (never node-typed person creation); `linkedAuthors`
/// is the explicit person linkage.
///
/// Also pins the #14 follow-up five (owner list, 2026-10-06):
/// definition/idea/place/project as plain seeds + trip extending event
/// (the events-family cascade) — the fixed ids, the static-map coverage,
/// the local seed emission, and the features.ts gating/family mirror.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  sqfliteFfiInit();

  group('system UUID parity', () {
    test('all system class UUIDs are unique and live in the 0001 block', () {
      const uuids = <String>[
        // …0001 was withdrawn 2026-10-07 (the seeded `class` meta class is
        // retired — never reused); no live constant carries it.
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
      for (final name in ['song', 'tv_series', 'conference', 'weblink']) {
        expect(LocalWorkspaceSeed.systemClassExtends[name], ['source']);
      }
      expect(LocalWorkspaceSeed.systemClassIcons['song'], 'mdiMusicNote');
      expect(LocalWorkspaceSeed.systemClassIcons['tv_series'],
          'mdiTelevisionClassic');
      expect(LocalWorkspaceSeed.systemClassIcons['conference'],
          'mdiPresentation');
      expect(LocalWorkspaceSeed.systemClassIcons['weblink'], 'mdiLinkVariant');
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

    test('the seeded class meta class is retired (…0001 withdrawn, never '
        'reused)', () {
      // The seed map no longer emits the `class` meta class; the UUID
      // appears nowhere in the seed maps (the linkedAuthors …0025
      // precedent).
      expect(LocalWorkspaceSeed.systemClassNames.containsKey('class'), isFalse);
      final seeded = <String>[
        ...LocalWorkspaceSeed.systemClassNames.values,
      ];
      expect(
        seeded.contains('00000000-0000-0000-0001-000000000001'),
        isFalse,
      );
      // weblink leads the source-family convergence (owner ruling,
      // 2026-10-07): seeded, and its extends edge targets source.
      expect(LocalWorkspaceSeed.systemClassNames['weblink'],
          '00000000-0000-0000-0001-000000000034');
      expect(LocalWorkspaceSeed.systemClassExtends['weblink'], ['source']);
    });

    test('seeded class UUIDs in the seed map stay unique', () {
      final uuids = LocalWorkspaceSeed.systemClassNames.values.toList();
      expect(uuids.toSet(), hasLength(uuids.length));
    });
  });

  group('deploy-catalog five (#14 follow-up)', () {
    // The #14 follow-up seed convergence (owner list, 2026-10-06): the
    // deploy catalog's missing everyday classes — definition/idea/place/
    // project as plain seeds, trip extending event so the events-family
    // cascade reaches it. The seeds.ts record (…0043-…0047), pinned here
    // so the seed drift cannot recur (the GTK lockstep commit fd50e5c).
    const five = <(String, String, String, String)>[
      // (seed key, uuid, mdi icon, display title) — the seeds.ts record.
      ('definition', '00000000-0000-0000-0001-000000000043',
        'mdiBookOpenPageVariant', 'Definition'),
      ('idea', '00000000-0000-0000-0001-000000000044',
        'mdiThoughtBubbleOutline', 'Idea'),
      ('place', '00000000-0000-0000-0001-000000000045',
        'mdiMapMarkerOutline', 'Place'),
      ('project', '00000000-0000-0000-0001-000000000046',
        'mdiBriefcaseOutline', 'Project'),
      ('trip', '00000000-0000-0000-0001-000000000047', 'mdiAirplane', 'Trip'),
    ];

    // The WITHDRAWN class slots the five must never collide with: …0001
    // (the seeded `class` meta class, retired 2026-10-07) and …0042
    // (`cover`, withdrawn 2026-10-04 the day it was minted) — dead slots,
    // never reused (the seeds.ts withdrawal comments).
    const withdrawnClassIds = <String>[
      '00000000-0000-0000-0001-000000000001',
      '00000000-0000-0000-0001-000000000042',
    ];

    test('fixed ids: block-prefixed, unique, withdrawn slots untouched',
        () {
      final ids = [for (final entry in five) entry.$2];
      expect(ids.toSet(), hasLength(ids.length), reason: 'unique class UUIDs');
      for (final id in ids) {
        expect(
          id.startsWith('00000000-0000-0000-0001-'),
          isTrue,
          reason: 'class UUIDs live in the 0001 block: $id',
        );
      }
      for (final id in withdrawnClassIds) {
        expect(ids.contains(id), isFalse, reason: 'withdrawn slot: $id');
      }
    });

    test('the static maps carry the five with the seeds.ts icons + display '
        'titles', () {
      // The drift guard: every one of the five resolves through the
      // Flutter maps at its fixed id, with the seeds.ts icon + display
      // title — a future main-repo seed change that skips this port fails
      // here.
      const constants = <String, String>{
        'definition': SystemClassUuids.definition,
        'idea': SystemClassUuids.idea,
        'place': SystemClassUuids.place,
        'project': SystemClassUuids.project,
        'trip': SystemClassUuids.trip,
      };
      for (final entry in five) {
        final name = entry.$1;
        expect(constants[name], entry.$2, reason: 'SystemClassUuids.$name');
        expect(systemClassUuids[name], entry.$2,
            reason: 'workspace_features systemClassUuids.$name');
        expect(LocalWorkspaceSeed.systemClassNames[name], entry.$2,
            reason: 'local seed systemClassNames.$name');
        expect(systemClassIcons[name], entry.$3, reason: 'icons.$name');
        expect(LocalWorkspaceSeed.systemClassIcons[name], entry.$3,
            reason: 'local seed icons.$name');
        expect(systemClassDisplayNames[name], entry.$4,
            reason: 'display names.$name');
      }
      // trip → event is the only extends edge among the five (the cascade
      // authority); the four plain seeds extend nothing.
      expect(LocalWorkspaceSeed.systemClassExtends['trip'], ['event']);
      for (final name in ['definition', 'idea', 'place', 'project']) {
        expect(LocalWorkspaceSeed.systemClassExtends[name], isNull,
            reason: '$name is a plain seed');
        expect(systemClassExtends[name], isNull, reason: '$name is a plain seed');
      }
      expect(systemClassExtends['trip'], ['event']);
      // The extends targets all resolve to seeded classes.
      expect(LocalWorkspaceSeed.systemClassNames.containsKey('event'), isTrue);
    });

    test('gating and family groupings mirror features.ts', () {
      // features.ts parity: trip joined the events family (the cascade
      // set + the gating walk), while the four plain seeds are unmanaged —
      // exactly like the TS record, where they are absent from
      // ALWAYS_ON_SYSTEM_CLASSES and gate on nothing.
      expect(systemClassAncestors('trip'), {'event'});
      expect(familyClassNames('events'),
          ['event', 'birthday', 'meeting', 'trip']);
      expect(managedClassIds('events'), [
        SystemClassUuids.event,
        SystemClassUuids.birthday,
        SystemClassUuids.meeting,
        SystemClassUuids.trip,
      ]);
      expect(gatingFeaturesForClass('trip'), ['events']);
      for (final name in ['definition', 'idea', 'place', 'project']) {
        expect(systemClassAncestors(name), isEmpty, reason: name);
        expect(gatingFeaturesForClass(name), isEmpty, reason: name);
      }
    });
  });

  group('display titles + the events family (2026-10-07 follow-up)', () {
    // The display-title revision: the local seed authors the display
    // titles (the seeds.ts SYSTEM_CLASS_DISPLAY_NAMES slice), matching the
    // server seed's shape — never the raw keys. The completeness pin
    // (one entry per seeded class) mirrors the TS domain test over the
    // manifest.
    test('every seeded class resolves a display title', () {
      for (final name in LocalWorkspaceSeed.systemClassNames.keys) {
        final title = systemClassDisplayNames[name];
        expect(title, isNotNull, reason: 'display title for $name');
        expect(title!.isNotEmpty, isTrue, reason: 'non-empty for $name');
        expect(title.contains('_'), isFalse,
            reason: 'normal wording, not the raw key: $name');
      }
    });

    test('the wording pins (the seeds.ts record)', () {
      expect(systemClassDisplayNames['tv_series'], 'TV series');
      expect(systemClassDisplayNames['weblink'], 'Web link');
      expect(systemClassDisplayNames['task'], 'Task');
      expect(systemClassDisplayNames['source'], 'Source');
      expect(systemClassDisplayNames['meeting'], 'Meeting');
      expect(systemClassDisplayNames['event'], 'Event');
      expect(systemClassDisplayNames['birthday'], 'Birthday');
      expect(systemClassDisplayNames['trip'], 'Trip');
    });

    test('the events family seeds whole: meeting + event + birthday + trip',
        () {
      // The server seed keeps the full family (SEEDED_SYSTEM_CLASSES), so
      // the local subset mirrors it as a unit — meeting/birthday carry
      // their fixed ids + the extends edge to event, trip's cascade
      // siblings.
      expect(LocalWorkspaceSeed.systemClassNames['meeting'],
          '00000000-0000-0000-0001-000000000039');
      expect(LocalWorkspaceSeed.systemClassNames['event'],
          '00000000-0000-0000-0001-000000000040');
      expect(LocalWorkspaceSeed.systemClassNames['birthday'],
          '00000000-0000-0000-0001-000000000041');
      expect(LocalWorkspaceSeed.systemClassExtends['meeting'], ['event']);
      expect(LocalWorkspaceSeed.systemClassExtends['birthday'], ['event']);
      // The extends targets all resolve to seeded classes.
      final targets = <String>{
        for (final parents in LocalWorkspaceSeed.systemClassExtends.values)
          ...parents,
      };
      for (final target in targets) {
        expect(LocalWorkspaceSeed.systemClassNames.containsKey(target), isTrue,
            reason: 'extends target $target is seeded');
      }
      // The property-schema axis stays the authors-only slice (documented
      // divergence — the meeting/event/birthday bindings are server-seeded,
      // like the source family's bibliography specs).
      expect(
        LocalWorkspaceSeed.systemPropertySpecs.map((s) => s.name),
        ['authors'],
      );
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
      // 33 class.create (the seeded `class` meta class retired 2026-10-07;
      // weblink joins the source family; meeting + event + birthday join as
      // the full events family, 2026-10-07; the #14 follow-up five join,
      // 2026-10-06) + 7 class.setExtends (song, tv_series, conference,
      // weblink — all extend source; meeting, birthday, trip extend event) +
      // 1 propertySchema.create + 1 class.property.set (authors,
      // node-typed per the FINAL reversion) + 1 object.create (Inbox; the
      // scratchpad seed was withdrawn 2026-10-05).
      expect(emitted, 43);

      final db = await database.database;

      // Class titles land in DISPLAY wording (the server seed's shape —
      // SYSTEM_CLASS_DISPLAY_NAMES, never the raw keys).
      for (final entry in [
        (SystemClassUuids.task, 'Task'),
        (SystemClassUuids.tvSeries, 'TV series'),
        (SystemClassUuids.weblink, 'Web link'),
        (SystemClassUuids.meeting, 'Meeting'),
        (SystemClassUuids.event, 'Event'),
        (SystemClassUuids.birthday, 'Birthday'),
        (SystemClassUuids.trip, 'Trip'),
      ]) {
        final row = await db.rawQuery(
          'SELECT name FROM class_cache WHERE uuid = ?',
          [entry.$1],
        );
        expect(row.single['name'], entry.$2, reason: 'display title');
      }

      // Icons landed on the new classes.
      final song = await db.rawQuery(
        'SELECT icon FROM class_cache WHERE uuid = ?',
        [SystemClassUuids.song],
      );
      expect(song.single['icon'], 'mdiMusicNote');
      final weblink = await db.rawQuery(
        'SELECT icon FROM class_cache WHERE uuid = ?',
        [SystemClassUuids.weblink],
      );
      expect(weblink.single['icon'], 'mdiLinkVariant');
      // The #14 follow-up five seeded with their mdi icons.
      for (final entry in [
        (SystemClassUuids.definition, 'mdiBookOpenPageVariant'),
        (SystemClassUuids.idea, 'mdiThoughtBubbleOutline'),
        (SystemClassUuids.place, 'mdiMapMarkerOutline'),
        (SystemClassUuids.project, 'mdiBriefcaseOutline'),
        (SystemClassUuids.trip, 'mdiAirplane'),
      ]) {
        final row = await db.rawQuery(
          'SELECT icon FROM class_cache WHERE uuid = ?',
          [entry.$1],
        );
        expect(row.single['icon'], entry.$2);
      }

      // Extends edges + closure: the four source-family classes extend
      // source.
      for (final classId in [
        SystemClassUuids.song,
        SystemClassUuids.tvSeries,
        SystemClassUuids.conference,
        SystemClassUuids.weblink,
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
      // The #14 follow-up cascade: trip extends event (edge + closure).
      final tripEdges = await db.rawQuery(
        'SELECT parent_class_id FROM class_extends WHERE class_id = ?',
        [SystemClassUuids.trip],
      );
      expect(tripEdges.map((r) => r['parent_class_id']).toList(),
          [SystemClassUuids.event]);
      final tripClosure = await db.rawQuery(
        'SELECT ancestor_id FROM class_hierarchy WHERE class_id = ? AND ancestor_id = ?',
        [SystemClassUuids.trip, SystemClassUuids.event],
      );
      expect(tripClosure, hasLength(1));
      // The full events family (2026-10-07 follow-up): meeting + birthday
      // extend event exactly like trip (edge + closure).
      for (final classId in [
        SystemClassUuids.meeting,
        SystemClassUuids.birthday,
      ]) {
        final edges = await db.rawQuery(
          'SELECT parent_class_id FROM class_extends WHERE class_id = ?',
          [classId],
        );
        expect(edges.map((r) => r['parent_class_id']).toList(),
            [SystemClassUuids.event]);
        final closure = await db.rawQuery(
          'SELECT ancestor_id FROM class_hierarchy WHERE class_id = ? AND ancestor_id = ?',
          [classId, SystemClassUuids.event],
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
