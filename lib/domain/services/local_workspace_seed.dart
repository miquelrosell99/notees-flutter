import '../../core/constants/system.dart';
import '../../core/utils/ast_builder.dart';
import '../models/relay/operation_payloads.dart';
import '../models/relay/workspace_features.dart';
import './sync_v2_service.dart';

/// Client-side local workspace seed for offline (serverless) mode.
///
/// Mirrors the web client's seed and the server seed: emits `class.create`
/// for every system class — the class TITLE in normal wording (the
/// `systemClassDisplayNames` map, the seeds.ts `SYSTEM_CLASS_DISPLAY_NAMES`
/// slice — title-is-content; the server seed authors the same display
/// titles, never the raw keys) — then `object.create` for the Inbox. (The
/// scratchpad page the local seed used to mint as a personal page was
/// withdrawn 2026-10-05 ("not wanted";
/// the web/server seed no longer creates it either.)
///
/// The events family seeds as a UNIT (meeting + event + birthday + trip,
/// 2026-10-07 follow-up): the server seed keeps the full family, so the
/// local subset mirrors it whole — the workspace-feature cascade (the
/// applier's archival re-derivation over familyClassNames) then flips real
/// rows instead of no-opping over absent ones.
///
/// The property-SCHEMA axis seeds the source family's CREATOR slice
/// (authors + linkedAuthors + editors, 2026-10-23 source-library lockstep)
/// and the card family's six SRS schedule schemas (2026-10-28
/// memorization-cards lockstep, class-bound to `card`, all unpinned): the
/// meeting/event/birthday bindings and the rest of the bibliography pool
/// are not locally seeded — a server attach converges them through the
/// shared log (the mobile app reads no event/meeting property surfaces).
///
/// Ops go through the normal outbox/applier path ([SyncV2Service.emitLocal]),
/// so the local derived state matches what a server-seeded workspace would
/// produce, and the ops stay in the outbox to be pushed if a server is
/// attached later.
class LocalWorkspaceSeed {
  LocalWorkspaceSeed(this._sync);

  final SyncV2Service _sync;

  /// Class name → fixed system class UUID. Matches `SYSTEM_CLASS_UUIDS` in
  /// `frontend/src/constants/systemProperties.ts` (the obsolete `page` class
  /// is not seeded; page status derives from the node kind). The seeded
  /// `class` meta class (…0001) was retired 2026-10-07 (
  /// lockstep with the TS seed manifest): nodes bound to it become real
  /// classes (the class.create conversion capability) and the seed no
  /// longer emits it; the UUID is withdrawn, never reused.
  static const Map<String, String> systemClassNames = {
    'year': SystemClassUuids.year,
    'month': SystemClassUuids.month,
    'day': SystemClassUuids.day,
    'quote': SystemClassUuids.quote,
    'query': SystemClassUuids.query,
    'code': SystemClassUuids.code,
    'asset': SystemClassUuids.asset,
    'whiteboard': SystemClassUuids.whiteboard,
    'card': SystemClassUuids.card,
    'task': SystemClassUuids.task,
    'template': SystemClassUuids.template,
    'comment': SystemClassUuids.comment,
    'table': SystemClassUuids.table,
    'warning': SystemClassUuids.warning,
    'note': SystemClassUuids.note,
    'tip': SystemClassUuids.tip,
    'info': SystemClassUuids.info,
    'danger': SystemClassUuids.danger,
    'success': SystemClassUuids.success,
    'cloze': SystemClassUuids.cloze,
    'source': SystemClassUuids.source,
    'web_page': SystemClassUuids.webPage,
    'song': SystemClassUuids.song,
    'tv_series': SystemClassUuids.tvSeries,
    'conference': SystemClassUuids.conference,
    // The full events family (2026-10-07 follow-up): the server seed keeps
    // meeting + event + birthday (+ trip below), so the local subset mirrors
    // the family as a unit — the workspace-feature cascade flips real rows.
    'meeting': SystemClassUuids.meeting,
    'event': SystemClassUuids.event,
    'birthday': SystemClassUuids.birthday,
    // The #14 follow-up five (owner list, 2026-10-06 — the deploy catalog's
    // missing everyday classes, plain seeds per the meeting-system ruling;
    // seeds.ts …0043-…0047). trip extends `event` (the events cascade) —
    // see [systemClassExtends].
    'definition': SystemClassUuids.definition,
    'idea': SystemClassUuids.idea,
    'place': SystemClassUuids.place,
    'project': SystemClassUuids.project,
    'trip': SystemClassUuids.trip,
  };

  /// Icons for the seeded classes that carry one (TS manifest
  /// `SYSTEM_CLASS_ICONS` slice — the citations-model revision's four plus
  /// the #14 follow-up five); the rest of the legacy mobile subset seeds
  /// without icons. card's entry lands 2026-10-28 (memorization-cards
  /// slice): the renamed class carries the playing-cards outline, exactly
  /// the server seed's shape.
  static const Map<String, String> systemClassIcons = {
    'card': 'mdiCardsPlayingOutline',
    'source': 'mdiBookshelf',
    'song': 'mdiMusicNote',
    'tv_series': 'mdiTelevisionClassic',
    'conference': 'mdiPresentation',
    'web_page': 'mdiLinkVariant',
    'definition': 'mdiBookOpenPageVariant',
    'idea': 'mdiThoughtBubbleOutline',
    'place': 'mdiMapMarkerOutline',
    'project': 'mdiBriefcaseOutline',
    'trip': 'mdiAirplane',
  };

  /// Canonical extends edges for the seeded classes that carry one (TS
  /// manifest `SYSTEM_CLASS_EXTENDS` slice): the citations-model revision's
  /// four all extend `source` — the web page IS a cited web source (owner
  /// ruling, 2026-10-07 seed convergence; RENAMED weblink → web_page
  /// 2026-10-23, source-library roster — the UUID …0034 is unchanged) —
  /// and the events family rides its root (meeting + birthday + trip extend
  /// `event`; a trip is calendar-bound, so the events toggle cascades to
  /// it — this map is the cascade authority).
  static const Map<String, List<String>> systemClassExtends = {
    'song': ['source'],
    'tv_series': ['source'],
    'conference': ['source'],
    'web_page': ['source'],
    'meeting': ['event'],
    'birthday': ['event'],
    'trip': ['event'],
  };

  /// System property specs the source family's CREATOR slice carries (TS
  /// manifest `SYSTEM_PROPERTY_SPECS`, source-library slice 1 task 4,
  /// 2026-10-23): `authors` is free TEXT again (object → text-multi retype,the UUID …0012 unchanged, the object filter superseded);
  /// `linkedAuthors` is the reinstated node-typed authorship experiment
  /// (new UUID …0006-…0001 — the withdrawn …0025 stays burned, never
  /// reused), explicit person linkage to `agent`; `editors` is free-text
  /// multi (…0006-…0002). The rest of the bibliographic pool stays
  /// server-seeded (the documented divergence — a server attach converges
  /// it through the shared log).
  ///
  /// The card family joins 2026-10-28 (memorization-cards slice, TS
  /// manifest `SYSTEM_PROPERTY_SPECS` slice): the six SRS schedule schemas,
  /// class-bound to `card` at the …0004- block, all UNPINNED (the 2026-10-27
  /// pinned roster is frozen). `cardDue` is the datetime-typed due date (day
  /// precision); the five numbers carry the SM-2 ease factor and the FSRS
  /// difficulty/stability alongside reps/interval. All scalar — multi is
  /// false on every entry.
  static const List<SeedPropertySpec> systemPropertySpecs = [
    SeedPropertySpec(
      name: 'authors',
      propertySchemaId: SystemPropertyUuids.authors,
      type: 'text',
      multi: true,
      bindTo: 'source',
    ),
    SeedPropertySpec(
      name: 'linkedAuthors',
      propertySchemaId: SystemPropertyUuids.linkedAuthors,
      type: 'object',
      multi: true,
      bindTo: 'source',
      targetClassFilter: <String>[SystemClassUuids.agent],
    ),
    SeedPropertySpec(
      name: 'editors',
      propertySchemaId: SystemPropertyUuids.editors,
      type: 'text',
      multi: true,
      bindTo: 'source',
    ),
    SeedPropertySpec(
      name: 'Card due',
      propertySchemaId: SystemPropertyUuids.cardDue,
      type: 'datetime',
      multi: false,
      bindTo: 'card',
    ),
    SeedPropertySpec(
      name: 'Card reps',
      propertySchemaId: SystemPropertyUuids.cardReps,
      type: 'number',
      multi: false,
      bindTo: 'card',
    ),
    SeedPropertySpec(
      name: 'Card interval',
      propertySchemaId: SystemPropertyUuids.cardInterval,
      type: 'number',
      multi: false,
      bindTo: 'card',
    ),
    SeedPropertySpec(
      name: 'Card ease',
      propertySchemaId: SystemPropertyUuids.cardEase,
      type: 'number',
      multi: false,
      bindTo: 'card',
    ),
    SeedPropertySpec(
      name: 'Card difficulty',
      propertySchemaId: SystemPropertyUuids.cardDifficulty,
      type: 'number',
      multi: false,
      bindTo: 'card',
    ),
    SeedPropertySpec(
      name: 'Card stability',
      propertySchemaId: SystemPropertyUuids.cardStability,
      type: 'number',
      multi: false,
      bindTo: 'card',
    ),
  ];

  /// Seeds missing system classes and default pages, idempotently.
  ///
  /// Entries that already exist in the local store (e.g. a previously seeded
  /// or server-synced workspace) are skipped, so re-running emits nothing.
  /// Returns the number of seed operations emitted (0 when already seeded).
  Future<int> ensureLocalWorkspace() async {
    var emitted = 0;
    final seededThisRun = <String>{};

    for (final entry in systemClassNames.entries) {
      final classId = entry.value;
      if (await _sync.cache.getClassByUuid(classId) != null) continue;
      // class.create carries the title as contentAst (title-is-content;
      // the builder wraps the `name` convenience); no separate content op
      // is needed (the legacy app emitted a node.updateContent for the
      // class-page title). The title is the DISPLAY wording — the server
      // seed authors SYSTEM_CLASS_DISPLAY_NAMES, never the raw key. The
      // parentlessRole "block" roster rides the same
      // envelope: the flagged classes emit the flag on create, exactly
      // like the server seed and the web ensure path.
      final flagged = systemClassParentlessRoleBlock.contains(entry.key);
      await _sync.emitLocal(
        opType: 'class.create',
        payload: flagged
            ? OperationPayloads.classCreate(
                classId: classId,
                name: systemClassDisplayNames[entry.key]!,
                icon: systemClassIcons[entry.key],
                parentlessRole: 'block',
              )
            : OperationPayloads.classCreate(
                classId: classId,
                name: systemClassDisplayNames[entry.key]!,
                icon: systemClassIcons[entry.key],
              ),
        affectedNodeIds: [classId],
      );
      seededThisRun.add(classId);
      emitted += 1;
    }

    // Extends edges in a SECOND pass, the server seed's shape: every
    // class.create lands before any class.setExtends runs, so an edge may
    // target a class declared later in the map (meeting extends event).
    // Only classes seeded JUST NOW take an extends op — a previously
    // seeded or server-synced class keeps its stored edges (idempotency).
    for (final entry in systemClassNames.entries) {
      final extendsNames = systemClassExtends[entry.key];
      if (extendsNames == null) continue;
      if (!seededThisRun.contains(entry.value)) continue;
      await _sync.emitLocal(
        opType: 'class.setExtends',
        payload: OperationPayloads.classSetExtends(
          classId: entry.value,
          parentClassIds: [
            for (final parent in extendsNames)
              systemClassNames[parent]!,
          ],
        ),
        affectedNodeIds: [entry.value],
      );
      emitted += 1;
    }

    // Property schemas + their class bindings (citations revision).
    for (final spec in systemPropertySpecs) {
      if (await _sync.cache.getPropertySchemaRow(spec.propertySchemaId) != null) {
        continue;
      }
      await _sync.emitLocal(
        opType: 'propertySchema.create',
        payload: OperationPayloads.propertySchemaCreate(
          propertySchemaId: spec.propertySchemaId,
          name: spec.name,
          type: spec.type,
          multi: spec.multi,
          // A bound spec seeds its schema LOCAL to bindTo (scopeClassIds [bindClass] — the binding row still
          // lands on bindTo; bindings are per-class config, zero
          // availability semantics). TS `seedSystemProperties` parity.
          scopeClassIds: [systemClassNames[spec.bindTo]!],
          targetClassFilter: spec.targetClassFilter,
        ),
        affectedNodeIds: [spec.propertySchemaId],
      );
      await _sync.emitLocal(
        opType: 'class.property.set',
        payload: OperationPayloads.classPropertySet(
          classId: systemClassNames[spec.bindTo]!,
          propertySchemaId: spec.propertySchemaId,
        ),
        affectedNodeIds: [systemClassNames[spec.bindTo]!],
      );
      emitted += 2;
    }

    final pages = <String, String>{
      'Inbox': SystemPageUuids.inbox,
    };
    for (final entry in pages.entries) {
      final pageId = entry.value;
      if (await _sync.cache.getByUuid(pageId) != null) continue;
      await _sync.emitLocal(
        opType: 'object.create',
        payload: OperationPayloads.objectCreate(
          objectId: pageId,
          isEmbedded: false,
          contentAst: AstBuilder.parseInline(entry.key),
        ),
        affectedNodeIds: [pageId],
      );
      emitted += 1;
    }

    return emitted;
  }
}

/// One system property-schema spec entry (TS manifest
/// `SYSTEM_PROPERTY_SPECS` slice the mobile seed mirrors).
class SeedPropertySpec {
  const SeedPropertySpec({
    required this.name,
    required this.propertySchemaId,
    required this.type,
    required this.multi,
    required this.bindTo,
    this.targetClassFilter,
  });

  final String name;
  final String propertySchemaId;
  final String type;
  final bool multi;

  /// Class name the schema binds to (key of [LocalWorkspaceSeed.systemClassNames]).
  final String bindTo;
  final List<String>? targetClassFilter;
}
