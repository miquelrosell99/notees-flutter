/// Fixed UUIDs that match the backend schema for system classes and properties.
/// Copied from frontend/src/constants/systemProperties.ts.
class SystemClassUuids {
  SystemClassUuids._();

  // …0001 WITHDRAWN 2026-10-07 (owner ruling, lockstep with the TS seed
  // manifest `SYSTEM_CLASS_UUIDS`): the seeded `class` META class is
  // retired — nodes bound to it become REAL classes (class.create on an
  // existing node, the conversion capability) and the seed no longer emits
  // it. Never reuse.
  static const String page = '00000000-0000-0000-0001-000000000002';
  static const String year = '00000000-0000-0000-0001-000000000003';
  static const String month = '00000000-0000-0000-0001-000000000004';
  static const String day = '00000000-0000-0000-0001-000000000005';
  static const String quote = '00000000-0000-0000-0001-000000000006';
  static const String query = '00000000-0000-0000-0001-000000000007';
  static const String code = '00000000-0000-0000-0001-000000000008';
  static const String asset = '00000000-0000-0000-0001-000000000009';
  static const String whiteboard = '00000000-0000-0000-0001-000000000010';
  static const String card = '00000000-0000-0000-0001-000000000011';
  static const String task = '00000000-0000-0000-0001-000000000012';
  static const String template = '00000000-0000-0000-0001-000000000013';
  static const String comment = '00000000-0000-0000-0001-000000000014';
  static const String table = '00000000-0000-0000-0001-000000000015';
  static const String warning = '00000000-0000-0000-0001-000000000016';
  static const String note = '00000000-0000-0000-0001-000000000017';
  static const String tip = '00000000-0000-0000-0001-000000000018';
  static const String info = '00000000-0000-0000-0001-000000000019';
  static const String danger = '00000000-0000-0000-0001-000000000020';
  static const String success = '00000000-0000-0000-0001-000000000021';
  static const String cloze = '00000000-0000-0000-0001-000000000022';
  static const String source = '00000000-0000-0000-0001-000000000023';

  // Citations-model revision (2026-09-27, lockstep with the TS seed
  // manifest `SYSTEM_CLASS_UUIDS` — fixed ids, never reuse).
  static const String song = '00000000-0000-0000-0001-000000000036';
  static const String tvSeries = '00000000-0000-0000-0001-000000000037';
  static const String conference = '00000000-0000-0000-0001-000000000038';

  /// Referenced by `linkedAuthors`' targetClassFilter; the agent class
  /// itself is not part of the mobile seed delta (TS manifest …029).
  static const String agent = '00000000-0000-0000-0001-000000000029';

  // Feature-family classes (2026-10-04 lockstep, TS manifest
  // `SYSTEM_CLASS_UUIDS` — the five family bases and their
  // extends-children; fixed ids, never reuse).
  static const String book = '00000000-0000-0000-0001-000000000024';
  static const String paper = '00000000-0000-0000-0001-000000000025';
  static const String article = '00000000-0000-0000-0001-000000000026';
  static const String thesis = '00000000-0000-0000-0001-000000000027';
  static const String document = '00000000-0000-0000-0001-000000000028';
  static const String person = '00000000-0000-0000-0001-000000000030';
  static const String movie = '00000000-0000-0000-0001-000000000035';
  // The web link IS a source (owner ruling, 2026-10-07 seed convergence):
  // a bookmarked page is a cited web source — weblink inherits the source
  // family's bibliographic bindings while its own `url` binding stays the
  // class-local winner; disabling `source` hides weblinks with the family.
  static const String weblink = '00000000-0000-0000-0001-000000000034';
  static const String meeting = '00000000-0000-0000-0001-000000000039';
  static const String event = '00000000-0000-0000-0001-000000000040';
  static const String birthday = '00000000-0000-0000-0001-000000000041';

  // The #14 follow-up five (owner list, 2026-10-06, lockstep with the TS
  // seed manifest `SYSTEM_CLASS_UUIDS` — plain seeds per the meeting-system
  // ruling: zero wire cost, seed convergence only; the deploy catalog's
  // missing everyday classes). trip extends `event` — a trip is
  // calendar-bound, so the events toggle cascades to it
  // (workspace_features.dart `systemClassExtends` is the cascade authority).
  // Fixed ids, never reuse.
  static const String definition = '00000000-0000-0000-0001-000000000043';
  static const String idea = '00000000-0000-0000-0001-000000000044';
  static const String place = '00000000-0000-0000-0001-000000000045';
  static const String project = '00000000-0000-0000-0001-000000000046';
  static const String trip = '00000000-0000-0000-0001-000000000047';
}

class SystemPropertyUuids {
  SystemPropertyUuids._();

  static const String tags = '00000000-0000-0000-0000-000000000001';
  static const String showHierarchy = '00000000-0000-0000-0000-000000000003';
  static const String usedIn = '00000000-0000-0000-0000-000000000004';
  static const String cover = '00000000-0000-0000-0000-000000000005';
  static const String banner = '00000000-0000-0000-0000-000000000006';
  static const String description = '00000000-0000-0000-0000-000000000009';
  static const String extends_ = '00000000-0000-0000-0000-000000000008';
  static const String whiteboardData = '00000000-0000-0000-0000-000000000010';

  // FINAL (owner reversion, 2026-09-27): `authors` is node-typed again —
  // {type: object, multi: true, bindTo: source, targetClassFilter: [agent]}.
  static const String authors = '00000000-0000-0000-0000-000000000012';

  // …0025 withdrawn (was `linkedAuthors` in the reverted text-authors
  // revision) — never reuse (fixed-UUID manifest rule).

  // Task class properties
  static const String taskStatus = '00000000-0000-0000-0003-000000000001';
  static const String taskDeadline = '00000000-0000-0000-0003-000000000002';
  static const String taskScheduled = '00000000-0000-0000-0003-000000000003';
  static const String taskPriority = '00000000-0000-0000-0003-000000000004';
  static const String taskClosedDate = '00000000-0000-0000-0003-000000000005';
  static const String taskRecurrence = '00000000-0000-0000-0003-000000000006';
}

/// Deterministic select-option ids for the applier-side task-family
/// seed-ensure (the `workspace.feature.set
/// {feature:"tasks", enabled:true}` path authors the six schemas at apply
/// time, so its option ids must be fixed, not client-random). The
/// select-option namespace (`…0004-…`) continues after the role options
/// (`…0001–…0007`); appended, never reused (TS manifest
/// `TASK_STATUS_OPTION_UUIDS` / `TASK_PRIORITY_OPTION_UUIDS`).
class TaskFamilyOptionUuids {
  TaskFamilyOptionUuids._();

  static const String backlog = '00000000-0000-0000-0004-000000000008';
  static const String pending = '00000000-0000-0000-0004-000000000009';
  static const String doing = '00000000-0000-0000-0004-00000000000a';
  static const String reviewing = '00000000-0000-0000-0004-00000000000b';
  static const String done = '00000000-0000-0000-0004-00000000000c';
  static const String cancelled = '00000000-0000-0000-0004-00000000000d';

  static const String low = '00000000-0000-0000-0004-00000000000e';
  static const String medium = '00000000-0000-0000-0004-00000000000f';
  static const String high = '00000000-0000-0000-0004-000000000010';
  static const String urgent = '00000000-0000-0000-0004-000000000011';
}

/// Task status names, ordered to match the backend TASK_STATUS_OPTIONS.
class TaskStatuses {
  TaskStatuses._();

  static const List<String> all = [
    'Backlog',
    'Pending',
    'Doing',
    'Reviewing',
    'Done',
    'Cancelled',
  ];

  static const Set<String> closed = {'Done', 'Cancelled'};
}

class SystemPageUuids {
  SystemPageUuids._();

  // Owner ruling (2026-10-05): the scratchpad page
  // (00000000-0000-0000-0002-000000000001) is WITHDRAWN — "not wanted". No
  // longer seeded; the UUID is never reused. Pre-withdrawal workspaces keep
  // the page as an ordinary node.
  static const String inbox = '00000000-0000-0000-0002-000000000002';
}
