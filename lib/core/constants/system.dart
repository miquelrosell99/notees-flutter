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
  // …0025 WITHDRAWN 2026-10-23 (source-library roster, lockstep with the TS
  // seed manifest `SYSTEM_CLASS_UUIDS`): Zotero has no "paper" — nodes
  // migrate to journal_article — never reuse.
  static const String journalArticle = '00000000-0000-0000-0001-000000000026';
  static const String thesis = '00000000-0000-0000-0001-000000000027';
  static const String document = '00000000-0000-0000-0001-000000000028';
  static const String person = '00000000-0000-0000-0001-000000000030';
  static const String film = '00000000-0000-0000-0001-000000000035';
  // The web page IS a source (owner ruling, 2026-10-07 seed convergence;
  // RENAMED weblink → web_page 2026-10-23 in the source-library roster,
  // lockstep with the TS seed manifest — the UUID …0034 is unchanged):
  // a bookmarked page is a cited web source — web_page inherits the source
  // family's bibliographic bindings while its own `url` binding stays the
  // class-local winner; disabling `source` hides web pages with the family.
  static const String webPage = '00000000-0000-0000-0001-000000000034';
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

  // The TS-manifest trio the mobile seed delta never carried (…031–…033,
  // lockstep with the TS seed manifest `SYSTEM_CLASS_UUIDS`): referenced by
  // the system-extends lock only — the frozen-extends authority needs every
  // system class UUID, and these three map to the empty parent set. Fixed
  // ids, never reuse.
  static const String organization = '00000000-0000-0000-0001-000000000031';
  static const String collection = '00000000-0000-0000-0001-000000000032';
  static const String highlight = '00000000-0000-0000-0001-000000000033';

  // Source-library roster (owner 2026-10-23, slice 1 task 3, lockstep with
  // the TS seed manifest `SYSTEM_CLASS_UUIDS`): 30 NEW source type-classes,
  // the Zotero-faithful long tail. Slots …0048–…0065 (hex — the
  // TASK_STATUS_OPTION_UUIDS precedent), assigned ALPHABETICALLY BY KEY for
  // determinism; all extend source (workspace_features `systemClassExtends`
  // is the cascade authority). Fixed ids, never reuse.
  static const String artwork = '00000000-0000-0000-0001-000000000048';
  static const String audioRecording = '00000000-0000-0000-0001-000000000049';
  static const String bill = '00000000-0000-0000-0001-00000000004a';
  static const String blogPost = '00000000-0000-0000-0001-00000000004b';
  static const String bookSection = '00000000-0000-0000-0001-00000000004c';
  static const String computerProgram = '00000000-0000-0000-0001-00000000004d';
  static const String conferencePaper = '00000000-0000-0000-0001-00000000004e';
  static const String dataset = '00000000-0000-0000-0001-00000000004f';
  static const String dictionaryEntry = '00000000-0000-0000-0001-000000000050';
  static const String email = '00000000-0000-0000-0001-000000000051';
  static const String encyclopediaArticle = '00000000-0000-0000-0001-000000000052';
  static const String forumPost = '00000000-0000-0000-0001-000000000053';
  static const String hearing = '00000000-0000-0000-0001-000000000054';
  static const String instantMessage = '00000000-0000-0000-0001-000000000055';
  static const String interview = '00000000-0000-0000-0001-000000000056';
  static const String letter = '00000000-0000-0000-0001-000000000057';
  static const String magazineArticle = '00000000-0000-0000-0001-000000000058';
  static const String manuscript = '00000000-0000-0000-0001-000000000059';
  static const String map = '00000000-0000-0000-0001-00000000005a';
  static const String newspaperArticle = '00000000-0000-0000-0001-00000000005b';
  static const String patent = '00000000-0000-0000-0001-00000000005c';
  static const String podcast = '00000000-0000-0000-0001-00000000005d';
  static const String preprint = '00000000-0000-0000-0001-00000000005e';
  static const String presentation = '00000000-0000-0000-0001-00000000005f';
  static const String radioBroadcast = '00000000-0000-0000-0001-000000000060';
  static const String report = '00000000-0000-0000-0001-000000000061';
  static const String standard = '00000000-0000-0000-0001-000000000062';
  static const String statute = '00000000-0000-0000-0001-000000000063';
  static const String tvBroadcast = '00000000-0000-0000-0001-000000000064';
  static const String videoRecording = '00000000-0000-0000-0001-000000000065';
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

  // RETYPED 2026-10-23 (owner ruling, source-library slice 1 task 4,
  // lockstep with the TS seed manifest `SYSTEM_PROPERTY_SPECS`): object →
  // text, multi — authors are free-text strings on the source family; the
  // node-typed experiment is reinstated as `linkedAuthors` (…0006-…0001).
  // The UUID …0012 is unchanged and the object filter is superseded (a
  // text schema takes no targetClassFilter).
  static const String authors = '00000000-0000-0000-0000-000000000012';

  // …0025 withdrawn (was `linkedAuthors` in the reverted text-authors
  // revision) — never reuse (fixed-UUID manifest rule). REINSTATED
  // 2026-10-23 at a NEW uuid (…0006-…0001) after the 2026-09-27
  // withdrawal: the node-typed authorship experiment returns as its own
  // property, coexisting with the free-text `authors` (source-library
  // slice 1 task 4, lockstep with the TS seed manifest).
  static const String linkedAuthors = '00000000-0000-0000-0006-000000000001';
  static const String editors = '00000000-0000-0000-0006-000000000002';

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

/// The READONLY derivation list (owner ruling 2026-10-21): the retired
/// `readonly` render contract was never user configuration (ZERO seeds ever
/// carried the flag), so clients DERIVE readonly-ness from the system list
/// instead of storing it (the binding-`sequence` philosophy). The list is
/// the platform-PROVENANCE properties — values authored by platform flows,
/// not user data: `generatedFrom` (…0027, templates provenance) and `alias`
/// (…0028, name-equivalence metadata). Mirrors `READONLY_SYSTEM_PROPERTY_IDS`
/// in the monorepo's packages/domain. Correcting the list is a one-line
/// change here (fixed seed UUIDs, precise).
const List<String> readonlySystemPropertyIds = [
  '00000000-0000-0000-0000-000000000027', // generatedFrom
  '00000000-0000-0000-0000-000000000028', // alias
];

/// True when the schema id is a system property whose editors render
/// readonly (the retired render contract, now derived — never blocks a
/// write, PC1).
bool isReadonlyProperty(String schemaId) =>
    readonlySystemPropertyIds.contains(schemaId);
