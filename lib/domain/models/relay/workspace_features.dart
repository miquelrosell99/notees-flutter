/// Workspace feature map (reshaped per owner directive 2026-10-04) — the
/// Dart port of `packages/domain/src/features.ts` in the
/// Notees monorepo.
///
/// The per-workspace feature toggles ARE the core class families:
/// tasks=task, events=event, meetings=meeting, sources=source,
/// persons=person. Each family is a seeded system class with built-in
/// product logic; the extends-children ride the base class (disabling
/// events archives meetings, birthdays, and trips with it —
/// [systemClassExtends] is the cascade authority). Feature ids are protocol
/// vocabulary ([OperationPayloads.workspaceFeatures]); the op-log home is
/// `workspace.feature.set`; the derived home is the app DB's
/// `workspace_feature` table (v22 migration).
///
/// Semantics (F1–F4, owner-confirmed):
///  - Toggle-off is NEVER deletion (F3): the applier flips the family
///    classes' registry `active` bit, leaving class membership untouched —
///    instances keep their class ids and stay in the graph; pickers/search
///    filter the flags for free.
///  - An absent `workspace_feature` row means ENABLED (F2 — all families
///    default ON; the empty table is the pre-toggle state, zero migration).
///  - A `class.delete` addressed at a family's BASE class is routed to the
///    toggle (F4): applied as a feature-disable, so the Features setting is
///    the single archive path and the lossy plain delete (membership
///    tombstoning) never runs on managed classes. The five bases route
///    (task, event, meeting, source, person — the TS domain test pins the
///    meeting mapping); non-base family children (book, birthday, …) keep
///    plain delete semantics.
library;

import '../../../core/constants/system.dart';

/// Feature ids are the five-family enum (validated on the wire by
/// [OperationPayloads.validatePayload]).
typedef WorkspaceFeature = String;

/// One family entry of [workspaceFeatureMap].
class WorkspaceFeatureSpec {
  const WorkspaceFeatureSpec({
    required this.baseClass,
    required this.label,
    required this.powers,
  });

  /// The family's base system class (the F4 routing target).
  final String baseClass;

  /// Settings label.
  final String label;

  /// One-line "powers" description — the product logic the family powers.
  final String powers;
}

/// The core class families (owner directive 2026-10-04).
const Map<WorkspaceFeature, WorkspaceFeatureSpec> workspaceFeatureMap = {
  'tasks': WorkspaceFeatureSpec(
    baseClass: 'task',
    label: 'Tasks',
    powers: 'Tasks hub + checkbox gestures',
  ),
  'events': WorkspaceFeatureSpec(
    baseClass: 'event',
    label: 'Events',
    powers: 'The calendar day/month surfaces',
  ),
  'meetings': WorkspaceFeatureSpec(
    baseClass: 'meeting',
    label: 'Meetings',
    powers: 'Meeting quick-create + meeting logic',
  ),
  'sources': WorkspaceFeatureSpec(
    baseClass: 'source',
    label: 'Sources',
    powers: 'The source family + citation import/export',
  ),
  'persons': WorkspaceFeatureSpec(
    baseClass: 'person',
    label: 'Persons',
    powers: 'The people graph + contact fields',
  ),
};

/// Class name → fixed system class UUID (the family subset of the TS
/// manifest `SYSTEM_CLASS_UUIDS`).
const Map<String, String> systemClassUuids = {
  'task': SystemClassUuids.task,
  'event': SystemClassUuids.event,
  'meeting': SystemClassUuids.meeting,
  'birthday': SystemClassUuids.birthday,
  'source': SystemClassUuids.source,
  'book': SystemClassUuids.book,
  'paper': SystemClassUuids.paper,
  'article': SystemClassUuids.article,
  'thesis': SystemClassUuids.thesis,
  'document': SystemClassUuids.document,
  'movie': SystemClassUuids.movie,
  'song': SystemClassUuids.song,
  'tv_series': SystemClassUuids.tvSeries,
  'conference': SystemClassUuids.conference,
  'person': SystemClassUuids.person,
  'agent': SystemClassUuids.agent,
  // The #14 follow-up five (owner list, 2026-10-06 — the deploy catalog's
  // missing everyday classes, plain seeds per the meeting-system ruling;
  // the TS manifest `SYSTEM_CLASS_UUIDS` parity). trip rides the events
  // family through its extends edge; the four plain seeds stay unmanaged
  // (no gating, not a family base — features.ts parity, absent from the TS
  // ALWAYS_ON_SYSTEM_CLASSES too).
  'definition': SystemClassUuids.definition,
  'idea': SystemClassUuids.idea,
  'place': SystemClassUuids.place,
  'project': SystemClassUuids.project,
  'trip': SystemClassUuids.trip,
};

/// Icons for the family classes (TS manifest `SYSTEM_CLASS_ICONS` slice).
const Map<String, String> systemClassIcons = {
  'task': 'mdiCheckboxMarkedCircleOutline',
  'event': 'mdiCalendar',
  'meeting': 'mdiCalendarClock',
  'birthday': 'mdiCakeVariant',
  'source': 'mdiBookshelf',
  'book': 'mdiBookOpenVariant',
  'paper': 'mdiNewspaperVariantOutline',
  'article': 'mdiNewspaper',
  'thesis': 'mdiSchoolOutline',
  'document': 'mdiFileOutline',
  'movie': 'mdiMovieOpenOutline',
  'song': 'mdiMusicNote',
  'tv_series': 'mdiTelevisionClassic',
  'conference': 'mdiPresentation',
  'person': 'mdiAccountOutline',
  // The #14 follow-up five (seeds.ts `SYSTEM_CLASS_ICONS` slice).
  'definition': 'mdiBookOpenPageVariant',
  'idea': 'mdiThoughtBubbleOutline',
  'place': 'mdiMapMarkerOutline',
  'project': 'mdiBriefcaseOutline',
  'trip': 'mdiAirplane',
};

/// The display titles the server seed authors into the class nodes' text
/// content for the #14 follow-up five (seeds.ts
/// `SYSTEM_CLASS_DISPLAY_NAMES` slice — title-is-content; the raw keys stay
/// code-facing vocabulary, these are the human wordings).
const Map<String, String> systemClassDisplayNames = {
  'definition': 'Definition',
  'idea': 'Idea',
  'place': 'Place',
  'project': 'Project',
  'trip': 'Trip',
};

/// Canonical `extends` edges between the family classes (TS manifest
/// `SYSTEM_CLASS_EXTENDS` slice): the source family's ten-strong set,
/// meeting + birthday + trip under event (the event→meeting/birthday/trip
/// cascade), person under agent.
const Map<String, List<String>> systemClassExtends = {
  'book': ['source'],
  'paper': ['source'],
  'article': ['source'],
  'thesis': ['source'],
  'document': ['source'],
  'movie': ['source'],
  'song': ['source'],
  'tv_series': ['source'],
  'conference': ['source'],
  'person': ['agent'],
  'meeting': ['event'],
  'birthday': ['event'],
  // A trip IS an event (the #14 follow-up, owner list 2026-10-06): a trip
  // is calendar-bound, so the events toggle cascades to it — this map is
  // the cascade authority (seeds.ts `SYSTEM_CLASS_EXTENDS` parity).
  'trip': ['event'],
};

/// The transitive ancestor set of [name] over [systemClassExtends];
/// a class is gated when itself or any ancestor is feature-off.
Set<String> systemClassAncestors(String name) {
  final ancestors = <String>{};
  final stack = [...(systemClassExtends[name] ?? const <String>[])];
  while (stack.isNotEmpty) {
    final current = stack.removeLast();
    if (ancestors.contains(current)) continue;
    ancestors.add(current);
    stack.addAll(systemClassExtends[current] ?? const <String>[]);
  }
  return ancestors;
}

/// The feature whose BASE class is [name], if any.
WorkspaceFeature? featureForBaseClass(String name) {
  for (final entry in workspaceFeatureMap.entries) {
    if (entry.value.baseClass == name) return entry.key;
  }
  return null;
}

/// The family's full class set: the base class + its transitive
/// extends-children (deterministic, sorted after the base). Disabling the
/// family archives exactly this set.
List<String> familyClassNames(WorkspaceFeature feature) {
  final base = workspaceFeatureMap[feature]!.baseClass;
  final children = systemClassUuids.keys
      .where((name) => name != base && systemClassAncestors(name).contains(base))
      .toList()
    ..sort();
  return [base, ...children];
}

/// Resolved UUIDs of the family's full class set (the applier's flip list).
List<String> managedClassIds(WorkspaceFeature feature) =>
    [for (final name in familyClassNames(feature)) systemClassUuids[name]!];

/// F4 routing: the owning feature when [classId] is a family's BASE class,
/// else null. The five bases route — task, event, meeting, source, person
/// (pinned by the TS domain test, `featureForManagedClass` there returns
/// "meetings" for the meeting id). Family children that are NOT bases
/// (book, birthday, …) keep plain delete semantics.
WorkspaceFeature? featureForManagedClass(String classId) {
  for (final entry in workspaceFeatureMap.entries) {
    if (systemClassUuids[entry.value.baseClass] == classId) return entry.key;
  }
  return null;
}

/// Chrome gating: the features whose OFF state hides a class's surfaces —
/// its own feature when it is a family base, plus the feature of every
/// family-base ANCESTOR. Empty for always-on/unmanaged classes. A class's
/// chrome shows only when EVERY listed feature is enabled (a meeting
/// surface hides when MEETINGS or EVENTS is off; a birthday surface hides
/// when EVENTS is off).
List<WorkspaceFeature> gatingFeaturesForClass(String name) {
  final gating = <WorkspaceFeature>[];
  final own = featureForBaseClass(name);
  if (own != null) gating.add(own);
  for (final ancestor in systemClassAncestors(name)) {
    final feature = featureForBaseClass(ancestor);
    if (feature != null && !gating.contains(feature)) gating.add(feature);
  }
  return gating;
}

/// One task-family seed-ensure entry: a property schema + its task-class
/// binding, authored idempotently when the `tasks` feature enables
/// (closes the "task property schemas never authored" row). Fixed ids end
/// to end (schema + option uuids); [sequence]
/// is the task-panel display order. Status options carry the
/// designed glyphs (the owner-mandated icon + color set);
/// [display] (PROPERTY-level after the owner review) rides the
/// SCHEMA entry — the Status schema defaults to 'bullet' (its value rides
/// the block bullet as an icon button), the rest stay in the properties
/// panel (null). The binding row carries only the per-class mechanics.
class TaskFamilySeedEntry {
  const TaskFamilySeedEntry({
    required this.schemaId,
    required this.name,
    required this.type,
    required this.sequence,
    this.options = const [],
    this.display,
  });

  final String schemaId;
  final String name;
  final String type; // 'select' | 'date'
  final int sequence;
  final List<Map<String, String>> options; // [{id, label, icon?, color?}]
  final String? display; // 'panel' | 'bullet' | 'inline'
}

/// The task-family seed-ensure manifest (TS manifest `TASK_FAMILY_SEED`):
/// six schemas + their task-class bindings. INSERT-or-ignore everywhere —
/// a client-authored family (random option ids) or a server-seeded one is
/// never clobbered: first writer wins, convergent on the single global log.
const List<TaskFamilySeedEntry> taskFamilySeed = [
  TaskFamilySeedEntry(
    schemaId: SystemPropertyUuids.taskStatus,
    name: 'Status',
    type: 'select',
    sequence: 1,
    display: 'bullet',
    options: [
      {
        'id': TaskFamilyOptionUuids.backlog,
        'label': 'Backlog',
        'icon': 'mdiCircleOutline',
        'color': 'gray',
      },
      {
        'id': TaskFamilyOptionUuids.pending,
        'label': 'Pending',
        'icon': 'mdiCircle',
        'color': 'yellow',
      },
      {
        'id': TaskFamilyOptionUuids.doing,
        'label': 'Doing',
        'icon': 'mdiCircleHalfFull',
        'color': 'orange',
      },
      {
        'id': TaskFamilyOptionUuids.reviewing,
        'label': 'Reviewing',
        'icon': 'mdiEyeCircleOutline',
        'color': 'blue',
      },
      {
        'id': TaskFamilyOptionUuids.done,
        'label': 'Done',
        'icon': 'mdiCheckCircle',
        'color': 'green',
      },
      {
        'id': TaskFamilyOptionUuids.cancelled,
        'label': 'Cancelled',
        'icon': 'mdiCloseCircle',
        'color': 'red',
      },
    ],
  ),
  TaskFamilySeedEntry(
    schemaId: SystemPropertyUuids.taskScheduled,
    name: 'Scheduled',
    type: 'date',
    sequence: 2,
  ),
  TaskFamilySeedEntry(
    schemaId: SystemPropertyUuids.taskDeadline,
    name: 'Deadline',
    type: 'date',
    sequence: 3,
  ),
  TaskFamilySeedEntry(
    schemaId: SystemPropertyUuids.taskPriority,
    name: 'Priority',
    type: 'select',
    sequence: 4,
    options: [
      {'id': TaskFamilyOptionUuids.low, 'label': 'Low'},
      {'id': TaskFamilyOptionUuids.medium, 'label': 'Medium'},
      {'id': TaskFamilyOptionUuids.high, 'label': 'High'},
      {'id': TaskFamilyOptionUuids.urgent, 'label': 'Urgent'},
    ],
  ),
  TaskFamilySeedEntry(
    schemaId: SystemPropertyUuids.taskClosedDate,
    name: 'Closed',
    type: 'date',
    sequence: 5,
  ),
  // migrated recurrence as a plain select (no engine executes it);
  // authored optionless until the recurrence spec lands.
  TaskFamilySeedEntry(
    schemaId: SystemPropertyUuids.taskRecurrence,
    name: 'Recurrence',
    type: 'select',
    sequence: 6,
  ),
];
