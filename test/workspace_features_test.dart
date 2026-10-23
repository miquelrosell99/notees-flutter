import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:notees/core/constants/system.dart';
import 'package:notees/data/local/app_database.dart';
import 'package:notees/data/repositories/node_cache_repository.dart';
import 'package:notees/domain/models/relay/hlc.dart';
import 'package:notees/domain/models/relay/operation_envelope.dart';
import 'package:notees/domain/models/relay/operation_payloads.dart';
import 'package:notees/domain/models/relay/store_errors.dart';
import 'package:notees/domain/models/relay/workspace_features.dart';
import 'package:notees/domain/services/relay_appliers.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

/// Acceptance for the `workspace.feature.set` lockstep op:
/// the strict six-toggle enum (retired ids rejected outright; `journal` is
/// surfaces-only and derives no class bits), the `workspace_feature` LWW
/// row (absent = ON, F2), the membership-preserving family archival via
/// per-class re-derivation (F3 + the event→meeting / birthday / trip
/// cascade), the class-node delete routing on the five bases only (an
/// object.delete on a family base routes to the toggle), and the idempotent
/// task-family seed-ensure riding every enable payload.
/// Replays the two canonical fixtures (workspace-feature-set,
/// object-delete-class-routing) through the appliers.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  sqfliteFfiInit();

  const fixturesDir = 'test/fixtures/wire';
  const ws = '0192a000-0000-7000-8000-000000000001';
  const actor = '0192a000-0000-7000-8000-000000000002';

  List<Map<String, dynamic>> loadFixture(String name) =>
      ((jsonDecode(File('$fixturesDir/$name').readAsStringSync())
              as Map<String, dynamic>)['envelopes'] as List<dynamic>)
          .cast<Map<String, dynamic>>();

  List<OperationEnvelope> fixtureEnvelopes(String name) =>
      loadFixture(name).map(OperationEnvelope.fromJson).toList();

  OperationEnvelope toggle(
    String feature,
    bool enabled,
    int physical, {
    int idNonce = 0,
  }) =>
      OperationEnvelope(
        id: '0192a000-0000-7000-8000-'
            '${(physical * 10 + idNonce).toString().padLeft(12, '0')}',
        workspaceId: ws,
        actorId: actor,
        deviceId: 'feature-test-device',
        hlc: Hlc(physical: physical, logical: 0),
        affectedNodeIds: const [],
        opType: 'workspace.feature.set',
        payload: {'feature': feature, 'enabled': enabled},
        timestamp: '2026-09-24T12:00:00.000Z',
      );

  group('workspace.feature.set payload factory + strict enum', () {
    test('builder round-trips the five families', () {
      for (final feature in OperationPayloads.workspaceFeatures) {
        final payload = OperationPayloads.workspaceFeatureSet(
          feature: feature,
          enabled: false,
        );
        expect(payload, {'feature': feature, 'enabled': false});
      }
    });

    test('the retired pre-reshape ids are rejected outright', () {
      for (final retired in [
        'journals',
        'readItLater',
        'library',
        'people',
        'collections',
      ]) {
        expect(
          () => OperationPayloads.workspaceFeatureSet(
            feature: retired,
            enabled: true,
          ),
          throwsFormatException,
          reason: '$retired must fail loud',
        );
      }
    });

    test('unknown features and unknown keys fail loud', () {
      expect(
        () => OperationPayloads.workspaceFeatureSet(
          feature: 'whiteboards',
          enabled: true,
        ),
        throwsFormatException,
      );
      expect(
        () => OperationPayloads.validatePayload('workspace.feature.set', {
          'feature': 'tasks',
          'enabled': true,
          'workspaceId': ws,
        }),
        throwsFormatException,
      );
    });

    test('registry knows the op', () {
      expect(OperationPayloads.isKnownOpType('workspace.feature.set'), isTrue);
    });
  });

  group('feature family map (features.ts port)', () {
    test('family sets: base + sorted extends-children', () {
      expect(familyClassNames('tasks'), ['task']);
      expect(familyClassNames('meetings'), ['meeting']);
      expect(familyClassNames('persons'), ['person']);
      // The #14 follow-up (owner list, 2026-10-06): trip extends event — a
      // trip is calendar-bound, so the events family set archives it with
      // meeting and birthday (the four-strong cascade).
      expect(familyClassNames('events'), ['event', 'birthday', 'meeting', 'trip']);
      // The source-library roster: the
      // 30-new source type-classes all extend source — they join the
      // family set (paper withdrew; article/weblink/movie renamed to
      // journal_article/web_page/film, keeping their UUIDs).
      expect(
        familyClassNames('sources'),
        [
          'source',
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
        ],
      );
    });

    test('gating walks own feature + managed ancestors', () {
      expect(gatingFeaturesForClass('event'), ['events']);
      expect(gatingFeaturesForClass('birthday'), ['events']);
      expect(gatingFeaturesForClass('meeting'), ['meetings', 'events']);
      expect(gatingFeaturesForClass('trip'), ['events']);
      expect(gatingFeaturesForClass('book'), ['sources']);
      expect(gatingFeaturesForClass('person'), ['persons']);
      expect(gatingFeaturesForClass('day'), isEmpty);
    });

    test('the four plain deploy-catalog seeds have no gating', () {
      // features.ts parity: definition/idea/place/project are plain seeds —
      // unmanaged, like the TS record (absent from ALWAYS_ON_SYSTEM_CLASSES,
      // no family base ancestor, gate on nothing).
      for (final name in ['definition', 'idea', 'place', 'project']) {
        expect(systemClassAncestors(name), isEmpty);
        expect(gatingFeaturesForClass(name), isEmpty);
      }
    });

    test('delete routing resolves the five base ids and nothing else', () {
      // The TS domain test pins the owner mapping: the five bases route,
      // children (book, birthday, …) fall to the other delete arms —
      // archival for system classes, plain trash for user classes.
      expect(
        featureForManagedClass(SystemClassUuids.task),
        'tasks',
      );
      expect(featureForManagedClass(SystemClassUuids.event), 'events');
      expect(featureForManagedClass(SystemClassUuids.meeting), 'meetings');
      expect(featureForManagedClass(SystemClassUuids.source), 'sources');
      expect(featureForManagedClass(SystemClassUuids.person), 'persons');
      expect(featureForManagedClass(SystemClassUuids.book), isNull);
      expect(featureForManagedClass(SystemClassUuids.birthday), isNull);
      expect(featureForManagedClass(SystemClassUuids.trip), isNull);
      expect(managedClassIds('events'), [
        SystemClassUuids.event,
        SystemClassUuids.birthday,
        SystemClassUuids.meeting,
        SystemClassUuids.trip,
      ]);
    });

    test('the locked system classes: the always-on core, name lookup',
        () {
      // The locked core: the date chain + table,
      // asset, query, code, template, comment. Everything else system is
      // gallery-toggleable (archival), never deletable via the gallery.
      for (final name in [
        'year',
        'month',
        'day',
        'table',
        'asset',
        'query',
        'code',
        'template',
        'comment',
      ]) {
        expect(isLockedSystemClassId(systemClassSeedUuids[name]!), isTrue,
            reason: name);
      }
      expect(isLockedSystemClassId(SystemClassUuids.quote), isFalse);
      expect(isLockedSystemClassId(SystemClassUuids.task), isFalse);
      expect(isLockedSystemClassId('0192a000-0000-7000-8000-00000000ffff'),
          isFalse);
      expect(systemClassNameForId(SystemClassUuids.year), 'year');
      expect(systemClassNameForId(SystemClassUuids.task), 'task');
      expect(systemClassNameForId('0192a000-0000-7000-8000-00000000ffff'),
          isNull);
      // The family guard: journal is a toggle but NOT a family.
      expect(isFamilyFeature('journal'), isFalse);
      expect(isFamilyFeature('tasks'), isTrue);
    });
  });

  group('workspace.feature.set applier', () {
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

    Future<List<Map<String, dynamic>>> raw(String sql,
            [List<Object?>? args]) async =>
        (await database.database).rawQuery(sql, args);

    test('absent row reads enabled (F2); the toggle LWW-writes the row',
        () async {
      expect(await cache.featureEnabledNow(ws, 'tasks'), isTrue);
      expect(await appliers.apply(toggle('tasks', false, 1000)), isTrue);
      expect(await cache.featureEnabledNow(ws, 'tasks'), isFalse);
      // A stale toggle is dropped.
      expect(await appliers.apply(toggle('tasks', true, 900)), isFalse);
      expect(await cache.featureEnabledNow(ws, 'tasks'), isFalse);
      // A newer toggle wins.
      expect(await appliers.apply(toggle('tasks', true, 2000)), isTrue);
      expect(await cache.featureEnabledNow(ws, 'tasks'), isTrue);
    });

    test('tasks enable authors the family at the fixed seed ids', () async {
      expect(await appliers.apply(toggle('tasks', true, 1000)), isTrue);
      final task = await cache.getClassByUuid(SystemClassUuids.task);
      expect(task, isNotNull);
      expect(task!.name, 'Task');
      for (final entry in taskFamilySeed) {
        final schema = await cache.getPropertySchemaRow(entry.schemaId);
        expect(schema, isNotNull, reason: entry.name);
        expect(schema!.type, entry.type);
        expect(schema.options.length, entry.options.length);
        final winner =
            await cache.classPropertyBindingWinner(SystemClassUuids.task, entry.schemaId);
        expect(winner, isNotNull, reason: entry.name);
      }
      // The applier-authored rows never clobber a user-authored family:
      // re-enable after a client-authored schema change keeps the option.
      final schema = await cache.getPropertySchemaRow(SystemPropertyUuids.taskStatus);
      expect(schema!.options.first['label'], 'Backlog');

      // The designed status glyphs (owner-mandated icon + color set)
      // AND the display position are PROPERTY-level — they seed with the
      // SCHEMA (Status defaults to 'bullet'), not the binding; the binding
      // rows carry only the per-class mechanics.
      expect(schema.options.map((o) => o['label']), [
        'Backlog',
        'Pending',
        'Doing',
        'Reviewing',
        'Done',
        'Cancelled',
      ]);
      expect(schema.options.map((o) => [o['icon'], o['color']]), [
        ['mdiCircleOutline', 'gray'],
        ['mdiCircle', 'yellow'],
        ['mdiCircleHalfFull', 'orange'],
        ['mdiEyeCircleOutline', 'blue'],
        ['mdiCheckCircle', 'green'],
        ['mdiCloseCircle', 'red'],
      ]);
      expect(schema.display, 'bullet');
      final seeded = await raw(
        'SELECT uuid, display FROM property_schema WHERE uuid LIKE ? ORDER BY uuid',
        ['00000000-0000-0000-0003-%'],
      );
      expect(seeded.map((s) => s['display']), [
        'bullet', // Status
        null, // Scheduled
        null, // Deadline
        null, // Priority
        null, // Closed
        null, // Recurrence
      ]);
      // The six binding rows carry no order (sequence retired 2026-10-21);
      // the id order asserts the full family is bound.
      final bindings = await raw(
        'SELECT property_schema_id FROM class_property '
        'WHERE class_id = ? ORDER BY property_schema_id',
        [SystemClassUuids.task],
      );
      expect(bindings.map((b) => b['property_schema_id']), [
        SystemPropertyUuids.taskStatus,
        SystemPropertyUuids.taskDeadline,
        SystemPropertyUuids.taskScheduled,
        SystemPropertyUuids.taskPriority,
        SystemPropertyUuids.taskClosedDate,
        SystemPropertyUuids.taskRecurrence,
      ]);
      // The binding table no longer carries a display column at all.
      final columns = await raw('PRAGMA table_info(class_property)');
      expect(
        columns.map((c) => c['name']),
        isNot(contains('display')),
      );
    });

    test('the ensure rides every enable payload, win or lose', () async {
      // Racing pair: the disable carries the newer HLC and wins the row —
      // but BOTH delivery orders must author the identical family rows.
      final enable = toggle('tasks', true, 1000, idNonce: 1);
      final disable = toggle('tasks', false, 1100, idNonce: 2);

      Future<List<String>> familyState() async {
        final schemas = await raw(
          'SELECT uuid FROM property_schema WHERE uuid LIKE ? ORDER BY uuid',
          ['00000000-0000-0000-0003-%'],
        );
        final bindings = await raw(
          'SELECT property_schema_id FROM class_property WHERE class_id = ? '
          'ORDER BY property_schema_id',
          [SystemClassUuids.task],
        );
        final rows = await raw(
          'SELECT enabled FROM workspace_feature WHERE workspace_id = ? AND feature = ?',
          [ws, 'tasks'],
        );
        return [
          ...schemas.map((r) => r['uuid'] as String),
          ...bindings.map((r) => 'b:${r['property_schema_id']}'),
          'row:${rows.isEmpty ? 'absent' : rows.first['enabled']}',
        ];
      }

      await appliers.apply(enable);
      await appliers.apply(disable);
      final forward = await familyState();

      await database.close();
      final ffiDb2 = await databaseFactoryFfi.openDatabase(
        ':memory:',
        options: OpenDatabaseOptions(singleInstance: false),
      );
      database = AppDatabase.fromDatabase(ffiDb2);
      await database.initializeSchema();
      cache = NodeCacheRepository(database);
      appliers = RelayAppliers(cache);
      await appliers.apply(disable);
      await appliers.apply(enable);
      final backward = await familyState();

      expect(forward, backward);
      expect(forward.any((s) => s == 'row:0'), isTrue);
      // The family was authored on both paths.
      expect(forward.length, 6 + 6 + 1);
    });

    test('family archival cascades per-class '
        '(events → meeting + birthday + trip)', () async {
      Future<void> seedEventFamily() async {
        for (final entry in [
          ('event', SystemClassUuids.event),
          ('meeting', SystemClassUuids.meeting),
          ('birthday', SystemClassUuids.birthday),
          // The #14 follow-up (owner list, 2026-10-06): trip extends
          // event, so the events toggle cascades to it too.
          ('trip', SystemClassUuids.trip),
        ]) {
          if (await cache.getClassByUuid(entry.$2) != null) continue;
          await appliers.apply(OperationEnvelope(
            id: '0192a000-0000-7000-8000-0000000000${entry.$2.substring(34)}',
            workspaceId: ws,
            actorId: actor,
            deviceId: 'feature-test-device',
            hlc: Hlc(physical: 500, logical: 0),
            affectedNodeIds: [entry.$2],
            opType: 'class.create',
            payload: OperationPayloads.classCreate(classId: entry.$2, name: entry.$1),
            timestamp: '2026-09-24T12:00:00.000Z',
          ));
        }
      }

      Future<List<bool>> bits() async => [
            (await raw(
              'SELECT active FROM class_cache WHERE uuid = ?',
              [SystemClassUuids.event],
            ))
                .single['active'] ==
                1,
            (await raw(
              'SELECT active FROM class_cache WHERE uuid = ?',
              [SystemClassUuids.meeting],
            ))
                .single['active'] ==
                1,
            (await raw(
              'SELECT active FROM class_cache WHERE uuid = ?',
              [SystemClassUuids.birthday],
            ))
                .single['active'] ==
                1,
            (await raw(
              'SELECT active FROM class_cache WHERE uuid = ?',
              [SystemClassUuids.trip],
            ))
                .single['active'] ==
                1,
          ];

      await seedEventFamily();
      expect(await bits(), [true, true, true, true]);

      // Events off archives the whole family; meetings off alone leaves
      // event + birthday + trip live (the trip child has no toggle of its
      // own — it rides the events base).
      await appliers.apply(toggle('events', false, 1000));
      expect(await bits(), [false, false, false, false]);
      await appliers.apply(toggle('events', true, 2000));
      await appliers.apply(toggle('meetings', false, 3000));
      expect(await bits(), [true, false, true, true]);
      // Re-enabling events must NOT un-archive a meetings-off meeting
      // (per-class re-derivation — the TS convergence fix); the trip child
      // comes back with the events base.
      await appliers.apply(toggle('events', false, 4000));
      await appliers.apply(toggle('events', true, 5000));
      expect(await bits(), [true, false, true, true]);
    });

    test('fixture workspace-feature-set: disable wins the same-slot race',
        () async {
      for (final envelope in fixtureEnvelopes('workspace-feature-set.json')) {
        expect(await appliers.apply(envelope), isTrue);
      }
      final rows = await raw(
        'SELECT feature, enabled FROM workspace_feature WHERE workspace_id = ? '
        'ORDER BY feature',
        [ws],
      );
      // The `journal` pair (off → on) leaves the toggle enabled; it derives
      // NO class bits — the date classes stay always-on (surfaces-only).
      expect(
        rows.map((r) => (r['feature'], r['enabled'])).toList(),
        [('events', 0), ('journal', 1), ('sources', 1), ('tasks', 0)],
      );
      // The tasks enable payloads (both) authored the family even though
      // the disable won the row.
      expect(
        await cache.getPropertySchemaRow(SystemPropertyUuids.taskStatus),
        isNotNull,
      );
      final task = await raw(
        'SELECT active FROM class_cache WHERE uuid = ?',
        [SystemClassUuids.task],
      );
      expect(task.single['active'], 0);
      // Converges under the reversed delivery order too.
      await database.close();
      final ffiDb2 = await databaseFactoryFfi.openDatabase(
        ':memory:',
        options: OpenDatabaseOptions(singleInstance: false),
      );
      database = AppDatabase.fromDatabase(ffiDb2);
      await database.initializeSchema();
      cache = NodeCacheRepository(database);
      appliers = RelayAppliers(cache);
      final reversed = fixtureEnvelopes('workspace-feature-set.json').reversed;
      for (final envelope in reversed) {
        await appliers.apply(envelope);
      }
      final rowsReverse = await raw(
        'SELECT feature, enabled FROM workspace_feature WHERE workspace_id = ? '
        'ORDER BY feature',
        [ws],
      );
      expect(
        rowsReverse.map((r) => (r['feature'], r['enabled'])).toList(),
        [('events', 0), ('journal', 1), ('sources', 1), ('tasks', 0)],
      );
      final taskReverse = await raw(
        'SELECT active FROM class_cache WHERE uuid = ?',
        [SystemClassUuids.task],
      );
      expect(taskReverse.single['active'], 0);
    });

    test('the journal toggle is surfaces-only: row LWW, no class bits',
        () async {
      expect(await appliers.apply(toggle('journal', false, 1000)), isTrue);
      expect(await cache.featureEnabledNow(ws, 'journal'), isFalse);
      expect(await appliers.apply(toggle('journal', true, 900)), isFalse);
      expect(await cache.featureEnabledNow(ws, 'journal'), isFalse);
      expect(await appliers.apply(toggle('journal', true, 2000)), isTrue);
      expect(await cache.featureEnabledNow(ws, 'journal'), isTrue);
      // No family derivation: no class_cache row was touched (the date
      // classes stay always-on structural seeds).
      final classes = await raw('SELECT COUNT(*) AS c FROM class_cache');
      expect(classes.single['c'], 0);
    });

    test('fixture object-delete-class-routing: the task delete routes to '
        'the toggle mid-fixture', () async {
      final envelopes = fixtureEnvelopes('object-delete-class-routing.json');
      // Apply through the task delete only.
      await appliers.apply(envelopes[0]); // class.create Year (seed prefix)
      await appliers.apply(envelopes[1]); // class.create Quote
      await appliers.apply(envelopes[2]); // class.create Task
      await appliers.apply(envelopes[3]); // object.create member
      expect(await appliers.apply(envelopes[4]), isTrue); // object.delete Task
      final rows = await raw(
        'SELECT enabled FROM workspace_feature WHERE workspace_id = ? AND feature = ?',
        [ws, 'tasks'],
      );
      expect(rows.single['enabled'], 0);
      final task = await raw(
        'SELECT active FROM class_cache WHERE uuid = ?',
        [SystemClassUuids.task],
      );
      expect(task.single['active'], 0);
      // Membership stands (the routed arm never touches the pairs).
      const taskMember = '0192a000-0000-7000-8000-000000000a22';
      final member = await raw(
        'SELECT present FROM class_member_set WHERE node_uuid = ? AND class_id = ?',
        [taskMember, SystemClassUuids.task],
      );
      expect(member.single['present'], 1);
      // A stale routed delete (same HLC re-applied) is dropped by the LWW
      // row gate.
      expect(await appliers.apply(envelopes[4]), isFalse);
    });

    test('object.delete on a family child (birthday) archives, never '
        'routes: the system-class arm', () async {
      // A birthday (an EVENTS-family child, not any feature's base) delete
      // takes arm 3: the class row deactivates and NO workspace_feature row
      // appears. Membership rides.
      await appliers.apply(OperationEnvelope(
        id: '0192a000-0000-7000-8000-0000000000a1',
        workspaceId: ws,
        actorId: actor,
        deviceId: 'feature-test-device',
        hlc: Hlc(physical: 100, logical: 0),
        affectedNodeIds: [SystemClassUuids.birthday],
        opType: 'class.create',
        payload: OperationPayloads.classCreate(
          classId: SystemClassUuids.birthday,
          name: 'Birthday',
        ),
        timestamp: '2026-09-24T12:00:00.000Z',
      ));
      final deleted = await appliers.apply(OperationEnvelope(
        id: '0192a000-0000-7000-8000-0000000000a2',
        workspaceId: ws,
        actorId: actor,
        deviceId: 'feature-test-device',
        hlc: Hlc(physical: 200, logical: 0),
        affectedNodeIds: [SystemClassUuids.birthday],
        opType: 'object.delete',
        payload: OperationPayloads.objectDelete(
          objectId: SystemClassUuids.birthday,
        ),
        timestamp: '2026-09-24T12:00:00.100Z',
      ));
      expect(deleted, isTrue);
      // Archived, NOT trashed: the registry row reads inactive, the
      // trash_root table stays empty, and no toggle was written.
      expect(await cache.classActiveState(SystemClassUuids.birthday), isFalse);
      expect(await cache.getClassByUuid(SystemClassUuids.birthday), isNull);
      final trash = await raw('SELECT COUNT(*) AS c FROM trash_root');
      expect(trash.single['c'], 0);
      final rows = await raw(
        'SELECT COUNT(*) AS c FROM workspace_feature WHERE workspace_id = ?',
        [ws],
      );
      expect(rows.single['c'], 0);
      // Archive is not deletion: the unarchive write revives the class.
      final revived = await appliers.apply(OperationEnvelope(
        id: '0192a000-0000-7000-8000-0000000000a3',
        workspaceId: ws,
        actorId: actor,
        deviceId: 'feature-test-device',
        hlc: Hlc(physical: 300, logical: 0),
        affectedNodeIds: [SystemClassUuids.birthday],
        opType: 'object.update',
        payload: OperationPayloads.objectUpdate(
          objectId: SystemClassUuids.birthday,
          active: true,
        ),
        timestamp: '2026-09-24T12:00:00.200Z',
      ));
      expect(revived, isTrue);
      expect(await cache.classActiveState(SystemClassUuids.birthday), isTrue);
    });

    test('archival write refusals: locked classes and family bases fail '
        'loud; unarchiving stays legal', () async {
      // Seed the year (locked) and task (family base) class rows.
      for (final entry in [
        (SystemClassUuids.year, 'Year', 100),
        (SystemClassUuids.task, 'Task', 200),
      ]) {
        await appliers.apply(OperationEnvelope(
          id: '0192a000-0000-7000-8000-0000000000b${entry.$3}',
          workspaceId: ws,
          actorId: actor,
          deviceId: 'feature-test-device',
          hlc: Hlc(physical: entry.$3, logical: 0),
          affectedNodeIds: [entry.$1],
          opType: 'class.create',
          payload: OperationPayloads.classCreate(
            classId: entry.$1,
            name: entry.$2,
          ),
          timestamp: '2026-09-24T12:00:00.000Z',
        ));
      }
      OperationEnvelope archival(String classId, bool active, int physical) =>
          OperationEnvelope(
            id: '0192a000-0000-7000-8000-0000000000c$physical',
            workspaceId: ws,
            actorId: actor,
            deviceId: 'feature-test-device',
            hlc: Hlc(physical: physical, logical: 0),
            affectedNodeIds: [classId],
            opType: 'object.update',
            payload: OperationPayloads.objectUpdate(
              objectId: classId,
              active: active,
            ),
            timestamp: '2026-09-24T12:00:00.000Z',
          );

      // Locked: archiving the year fails loud, never applied.
      expect(() => appliers.apply(archival(SystemClassUuids.year, false, 300)),
          throwsA(isA<LockedSystemClassError>()));
      expect(await cache.classActiveState(SystemClassUuids.year), isTrue);
      // Family base: archiving the task is toggle-managed, refused.
      expect(() => appliers.apply(archival(SystemClassUuids.task, false, 400)),
          throwsA(isA<MoveGuardError>()));
      expect(await cache.classActiveState(SystemClassUuids.task), isTrue);
      // Unarchiving both is harmless and applies (no-ops on active rows).
      expect(await appliers.apply(archival(SystemClassUuids.year, true, 500)),
          isTrue);
      expect(await appliers.apply(archival(SystemClassUuids.task, true, 600)),
          isTrue);
    });
  });
}
