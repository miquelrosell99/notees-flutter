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
/// fixed UUIDs, never reused; new classes extend `source`; the creator
/// family is `authors` (free-text multi, retyped from object 2026-10-23)
/// + `linkedAuthors` (the explicit node-typed person linkage to `agent`,
/// reinstated at …0006-…0001) + `editors` (free-text multi, …0006-…0002).
///
/// Also pins the #14 follow-up five (owner list, 2026-10-06):
/// definition/idea/place/project as plain seeds + trip extending event
/// (the events-family cascade) — the fixed ids, the static-map coverage,
/// the local seed emission, and the features.ts gating/family mirror.
///
/// And the source-library roster: the
/// three class renames (article → journal_article …0026, weblink →
/// web_page …0034, movie → film …0035), the paper withdrawal (…0025,
/// never reused), and the 30-new source type-classes …0048–…0065 (all
/// extend source; 18 archived-by-default) — the frozen-extends lock
/// coverage, the family cascade, and the archived set.
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
    test('the creator-family slice: authors retyped, linkedAuthors '
        'reinstated, editors added (source-library slice 1 task 4)', () {
      final specs = {
        for (final spec in LocalWorkspaceSeed.systemPropertySpecs)
          spec.name: spec,
      };
      expect(specs.keys, ['authors', 'linkedAuthors', 'editors']);

      // authors: object → text, multi (owner retype ruling 2026-10-23) —
      // the UUID …0012 unchanged, the object filter superseded.
      final authors = specs['authors']!;
      expect(authors.propertySchemaId, SystemPropertyUuids.authors);
      expect(authors.propertySchemaId,
          '00000000-0000-0000-0000-000000000012');
      expect(authors.type, 'text');
      expect(authors.multi, isTrue);
      expect(authors.bindTo, 'source');
      expect(authors.targetClassFilter, isNull);

      // linkedAuthors: the node-typed authorship experiment REINSTATED at
      // the NEW uuid …0006-…0001 (the withdrawn …0025 stays burned, never
      // reused) — object, multi, explicit person linkage to `agent`.
      final linked = specs['linkedAuthors']!;
      expect(linked.propertySchemaId, SystemPropertyUuids.linkedAuthors);
      expect(linked.propertySchemaId,
          '00000000-0000-0000-0006-000000000001');
      expect(linked.type, 'object');
      expect(linked.multi, isTrue);
      expect(linked.bindTo, 'source');
      expect(linked.targetClassFilter, [SystemClassUuids.agent]);

      // editors: free-text multi at the pinned slot …0006-…0002.
      final editors = specs['editors']!;
      expect(editors.propertySchemaId, SystemPropertyUuids.editors);
      expect(editors.propertySchemaId,
          '00000000-0000-0000-0006-000000000002');
      expect(editors.type, 'text');
      expect(editors.multi, isTrue);
      expect(editors.bindTo, 'source');
      expect(editors.targetClassFilter, isNull);

      // No live spec references the withdrawn …0025 (the fixed-UUID
      // manifest rule — withdrawn ids are never reused).
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
      for (final name in ['song', 'tv_series', 'conference', 'web_page']) {
        expect(LocalWorkspaceSeed.systemClassExtends[name], ['source']);
      }
      expect(LocalWorkspaceSeed.systemClassIcons['song'], 'mdiMusicNote');
      expect(LocalWorkspaceSeed.systemClassIcons['tv_series'],
          'mdiTelevisionClassic');
      expect(LocalWorkspaceSeed.systemClassIcons['conference'],
          'mdiPresentation');
      expect(LocalWorkspaceSeed.systemClassIcons['web_page'],
          'mdiLinkVariant');
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
      // web_page leads the source-family convergence (source-library
      // roster — the UUID …0034 is unchanged): seeded, and its extends
      // edge targets source.
      expect(LocalWorkspaceSeed.systemClassNames['web_page'],
          '00000000-0000-0000-0001-000000000034');
      expect(LocalWorkspaceSeed.systemClassExtends['web_page'], ['source']);
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

  group('source-library roster ', () {
    // The 30-new source type-classes (seeds.ts `SYSTEM_CLASS_UUIDS` slots
    // …0048–…0065, assigned ALPHABETICALLY BY KEY for determinism — the
    // domain test pins the exact map). Pinned here so a future main-repo
    // seed change that skips this port fails here.
    const roster = <(String, String, String, String)>[
      // (seed key, uuid, mdi icon, display title) — the seeds.ts record.
      ('artwork', '00000000-0000-0000-0001-000000000048',
        'mdiPaletteOutline', 'Artwork'),
      ('audio_recording', '00000000-0000-0000-0001-000000000049',
        'mdiMicrophone', 'Audio recording'),
      ('bill', '00000000-0000-0000-0001-00000000004a',
        'mdiScriptTextOutline', 'Bill'),
      ('blog_post', '00000000-0000-0000-0001-00000000004b',
        'mdiPostOutline', 'Blog post'),
      ('book_section', '00000000-0000-0000-0001-00000000004c',
        'mdiTableOfContents', 'Book section'),
      ('computer_program', '00000000-0000-0000-0001-00000000004d',
        'mdiCodeBraces', 'Computer program'),
      ('conference_paper', '00000000-0000-0000-0001-00000000004e',
        'mdiTextBoxOutline', 'Conference paper'),
      ('dataset', '00000000-0000-0000-0001-00000000004f',
        'mdiDatabaseOutline', 'Dataset'),
      ('dictionary_entry', '00000000-0000-0000-0001-000000000050',
        'mdiBookAlphabet', 'Dictionary entry'),
      ('email', '00000000-0000-0000-0001-000000000051',
        'mdiEmailOutline', 'Email'),
      ('encyclopedia_article', '00000000-0000-0000-0001-000000000052',
        'mdiLibrary', 'Encyclopedia article'),
      ('forum_post', '00000000-0000-0000-0001-000000000053',
        'mdiForumOutline', 'Forum post'),
      ('hearing', '00000000-0000-0000-0001-000000000054',
        'mdiGavel', 'Hearing'),
      ('instant_message', '00000000-0000-0000-0001-000000000055',
        'mdiMessageTextOutline', 'Instant message'),
      ('interview', '00000000-0000-0000-0001-000000000056',
        'mdiAccountVoice', 'Interview'),
      ('letter', '00000000-0000-0000-0001-000000000057',
        'mdiMailboxOutline', 'Letter'),
      ('magazine_article', '00000000-0000-0000-0001-000000000058',
        'mdiNewspaperVariant', 'Magazine article'),
      ('manuscript', '00000000-0000-0000-0001-000000000059',
        'mdiScriptOutline', 'Manuscript'),
      ('map', '00000000-0000-0000-0001-00000000005a',
        'mdiMapOutline', 'Map'),
      ('newspaper_article', '00000000-0000-0000-0001-00000000005b',
        'mdiTextBoxMultipleOutline', 'Newspaper article'),
      ('patent', '00000000-0000-0000-0001-00000000005c',
        'mdiStamp', 'Patent'),
      ('podcast', '00000000-0000-0000-0001-00000000005d',
        'mdiPodcast', 'Podcast'),
      ('preprint', '00000000-0000-0000-0001-00000000005e',
        'mdiFileClockOutline', 'Preprint'),
      ('presentation', '00000000-0000-0000-0001-00000000005f',
        'mdiPresentationPlay', 'Presentation'),
      ('radio_broadcast', '00000000-0000-0000-0001-000000000060',
        'mdiRadio', 'Radio broadcast'),
      ('report', '00000000-0000-0000-0001-000000000061',
        'mdiFileChartOutline', 'Report'),
      ('standard', '00000000-0000-0000-0001-000000000062',
        'mdiFileCheckOutline', 'Standard'),
      ('statute', '00000000-0000-0000-0001-000000000063',
        'mdiScaleBalance', 'Statute'),
      ('tv_broadcast', '00000000-0000-0000-0001-000000000064',
        'mdiTelevision', 'TV broadcast'),
      ('video_recording', '00000000-0000-0000-0001-000000000065',
        'mdiVideoOutline', 'Video recording'),
    ];

    // The renames keep their UUIDs; paper's …0025 is withdrawn (never
    // reused); the retired `class` meta class (…0001) and `cover` (…0042)
    // stay dead slots.
    const renamed = <(String, String, String, String)>[
      ('journal_article', '00000000-0000-0000-0001-000000000026',
        'mdiNewspaper', 'Journal article'),
      ('web_page', '00000000-0000-0000-0001-000000000034',
        'mdiLinkVariant', 'Web page'),
      ('film', '00000000-0000-0000-0001-000000000035',
        'mdiMovieOpenOutline', 'Film'),
    ];
    const withdrawnClassIds = <String>[
      '00000000-0000-0000-0001-000000000001', // the `class` meta class
      '00000000-0000-0000-0001-000000000025', // paper (2026-10-23)
      '00000000-0000-0000-0001-000000000042', // cover
    ];

    // seeds.ts `SYSTEM_ARCHIVED_BY_DEFAULT_CLASSES` — the 18 archived by
    // default (the list is the authority over the brief's prose).
    const archivedByDefault = <String>[
      'artwork',
      'bill',
      'blog_post',
      'computer_program',
      'dataset',
      'dictionary_entry',
      'email',
      'encyclopedia_article',
      'forum_post',
      'hearing',
      'instant_message',
      'interview',
      'letter',
      'manuscript',
      'map',
      'patent',
      'radio_broadcast',
      'statute',
    ];

    test('fixed ids: block-prefixed, hex-slot contiguous, withdrawn slots '
        'untouched', () {
      final ids = [for (final entry in roster) entry.$2];
      expect(ids.toSet(), hasLength(ids.length), reason: 'unique class UUIDs');
      for (var i = 0; i < roster.length; i++) {
        final suffix = (0x48 + i).toRadixString(16).padLeft(12, '0');
        expect(
          roster[i].$2,
          '00000000-0000-0000-0001-$suffix',
          reason: 'alphabetical-by-key slot assignment: ${roster[i].$1}',
        );
      }
      for (final id in withdrawnClassIds) {
        expect(ids.contains(id), isFalse, reason: 'withdrawn slot: $id');
        expect(renamed.any((entry) => entry.$2 == id), isFalse,
            reason: 'withdrawn slot: $id');
      }
    });

    test('the static maps carry the roster + the renames with the seeds.ts '
        'icons + display titles', () {
      for (final entry in [...roster, ...renamed]) {
        final name = entry.$1;
        expect(systemClassUuids[name], entry.$2,
            reason: 'workspace_features systemClassUuids.$name');
        expect(systemClassSeedUuids[name], entry.$2,
            reason: 'workspace_features systemClassSeedUuids.$name');
        expect(systemClassIcons[name], entry.$3, reason: 'icons.$name');
        expect(systemClassDisplayNames[name], entry.$4,
            reason: 'display names.$name');
        // Every roster class extends source — the family cascade + the
        // frozen-extends lock both derive from this edge.
        expect(systemClassExtends[name], ['source'],
            reason: 'extends.$name');
      }
      // The old keys are gone everywhere.
      for (final dead in ['paper', 'article', 'weblink', 'movie']) {
        expect(systemClassUuids.containsKey(dead), isFalse, reason: dead);
        expect(systemClassSeedUuids.containsKey(dead), isFalse,
            reason: dead);
      }
      // The archived-by-default set is exactly the 18, all roster members.
      expect(systemArchivedByDefaultClasses, archivedByDefault);
      for (final name in archivedByDefault) {
        expect(systemClassUuids.containsKey(name), isTrue, reason: name);
      }
    });

    test('the frozen-extends lock covers the whole roster', () {
      // systemClassExtendsIds is the system-extends lock authority: every
      // roster class must resolve there, frozen to {source}.
      for (final entry in roster) {
        final locked = systemClassExtendsIds[entry.$2];
        expect(locked, [SystemClassUuids.source], reason: entry.$1);
        expect(isSystemClassId(entry.$2), isTrue, reason: entry.$1);
      }
      // The renamed classes keep their frozen source parent set.
      expect(
        systemClassExtendsIds[SystemClassUuids.journalArticle],
        [SystemClassUuids.source],
      );
      expect(systemClassExtendsIds[SystemClassUuids.webPage],
          [SystemClassUuids.source]);
      expect(systemClassExtendsIds[SystemClassUuids.film],
          [SystemClassUuids.source]);
      // paper's …0025 is nobody's lock key anymore.
      expect(
        systemClassExtendsIds.containsKey(
            '00000000-0000-0000-0001-000000000025'),
        isFalse,
      );
    });

    test('the sources family cascade covers the roster', () {
      // features.ts parity: the sources family set is the base + every
      // extends-child, sorted — the 30-new roster joins the eight
      // pre-roster children (paper withdrew; the three renames keep their
      // slots).
      final family = familyClassNames('sources');
      expect(family.first, 'source');
      expect(family.length, 40);
      expect(family.sublist(1), [
        'artwork',
        'audio_recording',
        'bill',
        'blog_post',
        'book',
        'book_section',
        'computer_program',
        'conference',
        'conference_paper',
        'dataset',
        'dictionary_entry',
        'document',
        'email',
        'encyclopedia_article',
        'film',
        'forum_post',
        'hearing',
        'instant_message',
        'interview',
        'journal_article',
        'letter',
        'magazine_article',
        'manuscript',
        'map',
        'newspaper_article',
        'patent',
        'podcast',
        'preprint',
        'presentation',
        'radio_broadcast',
        'report',
        'song',
        'standard',
        'statute',
        'thesis',
        'tv_broadcast',
        'tv_series',
        'video_recording',
        'web_page',
      ]);
      // The roster classes gate on the sources toggle.
      for (final entry in roster) {
        expect(gatingFeaturesForClass(entry.$1), ['sources'],
            reason: entry.$1);
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
      expect(systemClassDisplayNames['web_page'], 'Web page');
      expect(systemClassDisplayNames['journal_article'], 'Journal article');
      expect(systemClassDisplayNames['film'], 'Film');
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
      // The property-schema axis stays the creator-family slice
      // (authors + linkedAuthors + editors — the 2026-10-23 source-library
      // lockstep); the meeting/event/birthday bindings and the rest of the
      // bibliography pool are server-seeded (the documented divergence).
      expect(
        LocalWorkspaceSeed.systemPropertySpecs.map((s) => s.name),
        ['authors', 'linkedAuthors', 'editors'],
      );
    });

    test('the parentlessRole "block" roster', () {
      // The TS seed manifest SYSTEM_CLASS_PARENTLESS_ROLE_BLOCK port: the
      // 14 flagged names exactly. meeting/birthday are DELIBERATELY
      // absent — they inherit the demote through event via the seeded
      // extends edge (the effective flag derives at read time).
      expect(systemClassParentlessRoleBlock, {
        'quote',
        'code',
        'asset',
        'card',
        'task',
        'template',
        'comment',
        'table',
        'cloze',
        'highlight',
        'query',
        'definition',
        'idea',
        'event',
      });
      expect(systemClassParentlessRoleBlock.contains('meeting'), isFalse);
      expect(systemClassParentlessRoleBlock.contains('birthday'), isFalse);
      // Every locally seeded flagged class resolves a seed entry (highlight
      // is not in the local subset — the TS-manifest trio the mobile seed
      // never carried — so the emitted create set is 13 of the 14).
      for (final name in systemClassParentlessRoleBlock) {
        if (name == 'highlight') continue;
        expect(LocalWorkspaceSeed.systemClassNames.containsKey(name), isTrue,
            reason: 'flagged class $name is locally seeded');
      }
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
      // web_page joins the source family; meeting + event + birthday join as
      // the full events family, 2026-10-07; the #14 follow-up five join,
      // 2026-10-06) + 7 class.setExtends (song, tv_series, conference,
      // web_page — all extend source; meeting, birthday, trip extend event) +
      // 3 propertySchema.create + 3 class.property.set (the creator-family
      // slice — authors retyped text-multi, linkedEditors node-typed to
      // agent, editors text-multi; source-library slice 1 task 4,
      // 2026-10-23) + 1 object.create (Inbox; the scratchpad seed was
      // withdrawn 2026-10-05).
      expect(emitted, 47);

      final db = await database.database;

      // Class titles land in DISPLAY wording (the server seed's shape —
      // SYSTEM_CLASS_DISPLAY_NAMES, never the raw keys).
      for (final entry in [
        (SystemClassUuids.task, 'Task'),
        (SystemClassUuids.tvSeries, 'TV series'),
        (SystemClassUuids.webPage, 'Web page'),
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
      final webPage = await db.rawQuery(
        'SELECT icon FROM class_cache WHERE uuid = ?',
        [SystemClassUuids.webPage],
      );
      expect(webPage.single['icon'], 'mdiLinkVariant');
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

      // The parentlessRole "block" roster: the flagged
      // seeded classes emit the flag on class.create; the unflagged stay
      // NULL — meeting/birthday inherit the demote through event's extends
      // edge, so they deliberately write NO flag of their own.
      Future<String?> roleOf(String uuid) async {
        final rows = await db.rawQuery(
          'SELECT parentless_role FROM class_cache WHERE uuid = ?',
          [uuid],
        );
        return rows.isEmpty ? null : rows.single['parentless_role'] as String?;
      }

      for (final uuid in [
        SystemClassUuids.quote,
        SystemClassUuids.query,
        SystemClassUuids.code,
        SystemClassUuids.asset,
        SystemClassUuids.card,
        SystemClassUuids.task,
        SystemClassUuids.template,
        SystemClassUuids.comment,
        SystemClassUuids.table,
        SystemClassUuids.cloze,
        SystemClassUuids.definition,
        SystemClassUuids.idea,
        SystemClassUuids.event,
      ]) {
        expect(await roleOf(uuid), 'block', reason: 'flagged roster member');
      }
      for (final uuid in [
        SystemClassUuids.meeting,
        SystemClassUuids.birthday,
        SystemClassUuids.trip,
        SystemClassUuids.source,
        SystemClassUuids.webPage,
      ]) {
        expect(await roleOf(uuid), isNull,
            reason: 'no own flag (meeting/birthday inherit through event)');
      }

      // Extends edges + closure: the four source-family classes extend
      // source.
      for (final classId in [
        SystemClassUuids.song,
        SystemClassUuids.tvSeries,
        SystemClassUuids.conference,
        SystemClassUuids.webPage,
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
        SystemPropertyUuids.linkedAuthors,
        SystemPropertyUuids.editors,
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
      expect(authorsRow.single['type'], 'text');
      expect(authorsRow.single['multi'], 1);
      final linkedRow = await db.rawQuery(
        'SELECT type, multi FROM property_schema WHERE uuid = ?',
        [SystemPropertyUuids.linkedAuthors],
      );
      expect(linkedRow.single['type'], 'object');
      expect(linkedRow.single['multi'], 1);

      // Idempotent re-run emits nothing.
      expect(
        await LocalWorkspaceSeed(syncService).ensureLocalWorkspace(),
        0,
      );
    });
  });
}
