/// Workspace feature map (reshaped per owner directive 2026-10-04) — the
/// Dart port of `packages/domain/src/features.ts` in the
/// Notees monorepo.
///
/// The per-workspace feature toggles ARE the core class families:
/// tasks=task, events=event, meetings=meeting, sources=source,
/// persons=person. Each family is a seeded system class with built-in
/// product logic; the extends-children ride the base class (disabling
/// events archives meetings, birthdays, and trips with it —
/// [systemClassAncestors] is the cascade authority). Feature ids are protocol
/// vocabulary ([OperationPayloads.workspaceFeatures]); the op-log home is
/// `workspace.feature.set`; the derived home is the app DB's
/// `workspace_feature` table (v22 migration).
///
/// Semantics (F1–F3 + the class-node delete routing, owner-confirmed;
/// superseding F4 — the retired class.delete op):
///  - Toggle-off is NEVER deletion (F3): the applier flips the family
///    classes' registry `active` bit, leaving class membership untouched —
///    instances keep their class ids and stay in the graph; pickers/search
///    filter the flags for free.
///  - An absent `workspace_feature` row means ENABLED (F2 — all families
///    default ON; the empty table is the pre-toggle state, zero migration).
///  - Class-node delete routing: `object.delete`
///    on a LOCKED system class ([lockedSystemClassNames]) fails loud; on a
///    family BASE class it is routed to the toggle (applied as a
///    feature-disable — the Features setting is the single archive path
///    for the families); on any other non-locked system class it archives
///    (`active = false`), never trash; on a user class it is a plain trash
///    row. Membership RIDES in every arm — `class_member_set` is never
///    touched by class removal (archive or trash); stripping a class from
///    nodes stays the explicit per-node `class.unassign`.
///  - The `journal` toggle is NOT a family: it
///    gates the journal SURFACES (the journal nav view, Today-page
///    management) while the date classes stay always-on structural seeds
///    (F1); it derives no class bits ([isFamilyFeature] is the guard).
library;

import '../../../core/constants/system.dart';

/// Feature ids are the six-toggle enum (validated on the wire by
/// [OperationPayloads.validatePayload]); the five families derive class
/// archival bits, `journal` gates surfaces only.
typedef WorkspaceFeature = String;

/// One family entry of [workspaceFeatureMap].
class WorkspaceFeatureSpec {
  const WorkspaceFeatureSpec({
    required this.baseClass,
    required this.label,
    required this.powers,
  });

  /// The family's base system class (the delete-routing target).
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
  'journal_article': SystemClassUuids.journalArticle,
  'thesis': SystemClassUuids.thesis,
  'document': SystemClassUuids.document,
  'film': SystemClassUuids.film,
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
  // The web link IS a source (
  // RENAMED weblink → web_page 2026-10-23, source-library roster — the
  // UUID …0034 is unchanged).
  'web_page': SystemClassUuids.webPage,
  // Source-library roster: the 30 NEW
  // source type-classes ALL extend source — they ride the sources toggle
  // with the family (the applier's family-bit derivation no-ops over
  // absent registry rows, so local-only workspaces that never seeded them
  // are unaffected).
  'artwork': SystemClassUuids.artwork,
  'audio_recording': SystemClassUuids.audioRecording,
  'bill': SystemClassUuids.bill,
  'blog_post': SystemClassUuids.blogPost,
  'book_section': SystemClassUuids.bookSection,
  'computer_program': SystemClassUuids.computerProgram,
  'conference_paper': SystemClassUuids.conferencePaper,
  'dataset': SystemClassUuids.dataset,
  'dictionary_entry': SystemClassUuids.dictionaryEntry,
  'email': SystemClassUuids.email,
  'encyclopedia_article': SystemClassUuids.encyclopediaArticle,
  'forum_post': SystemClassUuids.forumPost,
  'hearing': SystemClassUuids.hearing,
  'instant_message': SystemClassUuids.instantMessage,
  'interview': SystemClassUuids.interview,
  'letter': SystemClassUuids.letter,
  'magazine_article': SystemClassUuids.magazineArticle,
  'manuscript': SystemClassUuids.manuscript,
  'map': SystemClassUuids.map,
  'newspaper_article': SystemClassUuids.newspaperArticle,
  'patent': SystemClassUuids.patent,
  'podcast': SystemClassUuids.podcast,
  'preprint': SystemClassUuids.preprint,
  'presentation': SystemClassUuids.presentation,
  'radio_broadcast': SystemClassUuids.radioBroadcast,
  'report': SystemClassUuids.report,
  'standard': SystemClassUuids.standard,
  'statute': SystemClassUuids.statute,
  'tv_broadcast': SystemClassUuids.tvBroadcast,
  'video_recording': SystemClassUuids.videoRecording,
  // Workflows slice 2 (2026-10-30 — the everyday `question`/`plan` classes
  // the research workflow reuses; the TS manifest `SYSTEM_CLASS_UUIDS`
  // parity). Plain seeds exactly like the #14 follow-up four: unmanaged (no
  // gating, not a family base — features.ts parity, absent from the TS
  // ALWAYS_ON_SYSTEM_CLASSES too), no extends edge, no parentlessRole flag.
  'question': SystemClassUuids.question,
  'plan': SystemClassUuids.plan,
};

/// Icons for the family classes (TS manifest `SYSTEM_CLASS_ICONS` slice).
const Map<String, String> systemClassIcons = {
  // RENAMED 2026-10-28 (memorization-cards slice, lockstep with the TS seed
  // manifest `SYSTEM_CLASS_ICONS`): card's icon moves from the generic
  // summary glyph to the playing-cards outline (the UUID …0011 is
  // unchanged; icon strings ride the stored class rows).
  'card': 'mdiCardsPlayingOutline',
  'task': 'mdiCheckboxMarkedCircleOutline',
  'event': 'mdiCalendar',
  'meeting': 'mdiCalendarClock',
  'birthday': 'mdiCakeVariant',
  'source': 'mdiBookshelf',
  'book': 'mdiBookOpenVariant',
  'journal_article': 'mdiNewspaper',
  'thesis': 'mdiSchoolOutline',
  'document': 'mdiFileOutline',
  'film': 'mdiMovieOpenOutline',
  'song': 'mdiMusicNote',
  'tv_series': 'mdiTelevisionClassic',
  'conference': 'mdiPresentation',
  'person': 'mdiAccountOutline',
  'web_page': 'mdiLinkVariant',
  // The #14 follow-up five (seeds.ts `SYSTEM_CLASS_ICONS` slice).
  'definition': 'mdiBookOpenPageVariant',
  'idea': 'mdiThoughtBubbleOutline',
  'place': 'mdiMapMarkerOutline',
  'project': 'mdiBriefcaseOutline',
  'trip': 'mdiAirplane',
  // Source-library roster (the seeds.ts
  // `SYSTEM_CLASS_ICONS` slice for the 30-new set; RENAMED classes keep
  // their icons: journal_article was article's mdiNewspaper, web_page was
  // weblink's mdiLinkVariant, film was movie's mdiMovieOpenOutline).
  'audio_recording': 'mdiMicrophone',
  'artwork': 'mdiPaletteOutline',
  'bill': 'mdiScriptTextOutline',
  'blog_post': 'mdiPostOutline',
  'book_section': 'mdiTableOfContents',
  'computer_program': 'mdiCodeBraces',
  'conference_paper': 'mdiTextBoxOutline',
  'dataset': 'mdiDatabaseOutline',
  'dictionary_entry': 'mdiBookAlphabet',
  'email': 'mdiEmailOutline',
  'encyclopedia_article': 'mdiLibrary',
  'forum_post': 'mdiForumOutline',
  'hearing': 'mdiGavel',
  'instant_message': 'mdiMessageTextOutline',
  'interview': 'mdiAccountVoice',
  'letter': 'mdiMailboxOutline',
  'magazine_article': 'mdiNewspaperVariant',
  'manuscript': 'mdiScriptOutline',
  'map': 'mdiMapOutline',
  'newspaper_article': 'mdiTextBoxMultipleOutline',
  'patent': 'mdiStamp',
  'podcast': 'mdiPodcast',
  'preprint': 'mdiFileClockOutline',
  'presentation': 'mdiPresentationPlay',
  'radio_broadcast': 'mdiRadio',
  'report': 'mdiFileChartOutline',
  'standard': 'mdiFileCheckOutline',
  'statute': 'mdiScaleBalance',
  'tv_broadcast': 'mdiTelevision',
  'video_recording': 'mdiVideoOutline',
  // Workflows slice 2 (2026-10-30 — the everyday `question`/`plan` classes;
  // the seeds.ts `SYSTEM_CLASS_ICONS` slice).
  'question': 'mdiHelpCircleOutline',
  'plan': 'mdiClipboardTextOutline',
};

/// The display titles the server seed authors into the class nodes' text
/// content (seeds.ts `SYSTEM_CLASS_DISPLAY_NAMES` slice — title-is-content;
/// the raw keys stay code-facing vocabulary, these are the human wordings).
/// Covers every class the local workspace seed emits AND the source-library
/// roster the synced server seed carries (2026-10-23) — the local seed
/// writes its subset into its class.create content, exactly the server
/// seed's shape (normal wording, "TV series" not "tv_series"). The
/// seed-parity suite pins one entry per local-seed class key plus the
/// roster's fixed ids, icons, and titles.
const Map<String, String> systemClassDisplayNames = {
  'year': 'Year',
  'month': 'Month',
  'day': 'Day',
  'quote': 'Quote',
  'query': 'Query',
  'code': 'Code',
  'asset': 'Asset',
  'whiteboard': 'Whiteboard',
  // RENAMED 2026-10-28 (memorization-cards slice, lockstep with the TS seed
  // manifest `SYSTEM_CLASS_DISPLAY_NAMES` — the UUID …0011 is unchanged, the
  // key `card` stays code-facing vocabulary): the compact-summary wording
  // retires in favor of the spaced-repetition recall role.
  'card': 'Memorization card',
  'task': 'Task',
  'template': 'Template',
  'comment': 'Comment',
  'table': 'Table',
  'warning': 'Warning',
  'note': 'Note',
  'tip': 'Tip',
  'info': 'Info',
  'danger': 'Danger',
  'success': 'Success',
  'cloze': 'Cloze',
  'source': 'Source',
  'web_page': 'Web page',
  // The pre-roster source-family children (the seeds.ts
  // `SYSTEM_CLASS_DISPLAY_NAMES` slice; RENAMED 2026-10-23: article →
  // journal_article, movie → film — the local seed emits only web_page of
  // these, the rest arrive via a server attach).
  'book': 'Book',
  'journal_article': 'Journal article',
  'thesis': 'Thesis',
  'document': 'Document',
  'film': 'Film',
  'song': 'Song',
  'tv_series': 'TV series',
  'conference': 'Conference',
  // The full events family (the server seed keeps meeting + event +
  // birthday + trip — the local seed mirrors the family as a unit, not
  // event alone as trip's extends target).
  'meeting': 'Meeting',
  'event': 'Event',
  'birthday': 'Birthday',
  // The #14 follow-up five (owner list, 2026-10-06).
  'definition': 'Definition',
  'idea': 'Idea',
  'place': 'Place',
  'project': 'Project',
  'trip': 'Trip',
  // Source-library roster (the seeds.ts
  // `SYSTEM_CLASS_DISPLAY_NAMES` slice for the 30-new set; sentence-case
  // conventional wordings, acronyms uppercase: "TV broadcast").
  'audio_recording': 'Audio recording',
  'artwork': 'Artwork',
  'bill': 'Bill',
  'blog_post': 'Blog post',
  'book_section': 'Book section',
  'computer_program': 'Computer program',
  'conference_paper': 'Conference paper',
  'dataset': 'Dataset',
  'dictionary_entry': 'Dictionary entry',
  'email': 'Email',
  'encyclopedia_article': 'Encyclopedia article',
  'forum_post': 'Forum post',
  'hearing': 'Hearing',
  'instant_message': 'Instant message',
  'interview': 'Interview',
  'letter': 'Letter',
  'magazine_article': 'Magazine article',
  'manuscript': 'Manuscript',
  'map': 'Map',
  'newspaper_article': 'Newspaper article',
  'patent': 'Patent',
  'podcast': 'Podcast',
  'preprint': 'Preprint',
  'presentation': 'Presentation',
  'radio_broadcast': 'Radio broadcast',
  'report': 'Report',
  'standard': 'Standard',
  'statute': 'Statute',
  'tv_broadcast': 'TV broadcast',
  'video_recording': 'Video recording',
  // Workflows slice 2 (2026-10-30 — the everyday `question`/`plan` classes).
  'question': 'Question',
  'plan': 'Plan',
};

/// Canonical `extends` edges between the family classes (TS manifest
/// `SYSTEM_CLASS_EXTENDS` slice): the source family's full set — the
/// pre-roster children, the RENAMED web_page (weblink → web_page
/// 2026-10-23, source-library roster), and the 30-new roster ALL extending
/// source — plus meeting + birthday + trip under event (the event cascade)
/// and person under agent.
const Map<String, List<String>> systemClassExtends = {
  'book': ['source'],
  'journal_article': ['source'],
  'thesis': ['source'],
  'document': ['source'],
  'film': ['source'],
  'song': ['source'],
  'tv_series': ['source'],
  'conference': ['source'],
  'web_page': ['source'],
  'person': ['agent'],
  'meeting': ['event'],
  'birthday': ['event'],
  // A trip IS an event (the #14 follow-up, owner list 2026-10-06): a trip
  // is calendar-bound, so the events toggle cascades to it — this map is
  // the cascade authority (seeds.ts `SYSTEM_CLASS_EXTENDS` parity).
  'trip': ['event'],
  // Source-library roster: the 30-new
  // source type-classes ALL extend source — the Zotero-faithful long tail
  // inherits the family's bibliographic bindings; the sources toggle
  // archives/revives them with the family (seeds.ts parity).
  'artwork': ['source'],
  'audio_recording': ['source'],
  'bill': ['source'],
  'blog_post': ['source'],
  'book_section': ['source'],
  'computer_program': ['source'],
  'conference_paper': ['source'],
  'dataset': ['source'],
  'dictionary_entry': ['source'],
  'email': ['source'],
  'encyclopedia_article': ['source'],
  'forum_post': ['source'],
  'hearing': ['source'],
  'instant_message': ['source'],
  'interview': ['source'],
  'letter': ['source'],
  'magazine_article': ['source'],
  'manuscript': ['source'],
  'map': ['source'],
  'newspaper_article': ['source'],
  'patent': ['source'],
  'podcast': ['source'],
  'preprint': ['source'],
  'presentation': ['source'],
  'radio_broadcast': ['source'],
  'report': ['source'],
  'standard': ['source'],
  'statute': ['source'],
  'tv_broadcast': ['source'],
  'video_recording': ['source'],
};

/// The full system-class seed set (TS manifest `SYSTEM_CLASS_UUIDS` — the
/// frozen-extends authority below needs EVERY system class UUID; the family
/// subset [systemClassUuids] above is not enough). Fixed ids, never reuse.
const Map<String, String> systemClassSeedUuids = {
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
  'book': SystemClassUuids.book,
  'journal_article': SystemClassUuids.journalArticle,
  'thesis': SystemClassUuids.thesis,
  'document': SystemClassUuids.document,
  'agent': SystemClassUuids.agent,
  'person': SystemClassUuids.person,
  'organization': SystemClassUuids.organization,
  'collection': SystemClassUuids.collection,
  'highlight': SystemClassUuids.highlight,
  'web_page': SystemClassUuids.webPage,
  'film': SystemClassUuids.film,
  'song': SystemClassUuids.song,
  'tv_series': SystemClassUuids.tvSeries,
  'conference': SystemClassUuids.conference,
  'meeting': SystemClassUuids.meeting,
  'event': SystemClassUuids.event,
  'birthday': SystemClassUuids.birthday,
  'definition': SystemClassUuids.definition,
  'idea': SystemClassUuids.idea,
  'place': SystemClassUuids.place,
  'project': SystemClassUuids.project,
  'trip': SystemClassUuids.trip,
  // Source-library roster: the 30-new
  // source type-classes join the frozen-extends authority — the system
  // lock must know EVERY system class UUID or a server-origined
  // class.setExtends on one of them would be treated as a user-class op
  // (the …0048–…0065 slots, alphabetical by key; paper's …0025 stays
  // withdrawn, never reused).
  'artwork': SystemClassUuids.artwork,
  'audio_recording': SystemClassUuids.audioRecording,
  'bill': SystemClassUuids.bill,
  'blog_post': SystemClassUuids.blogPost,
  'book_section': SystemClassUuids.bookSection,
  'computer_program': SystemClassUuids.computerProgram,
  'conference_paper': SystemClassUuids.conferencePaper,
  'dataset': SystemClassUuids.dataset,
  'dictionary_entry': SystemClassUuids.dictionaryEntry,
  'email': SystemClassUuids.email,
  'encyclopedia_article': SystemClassUuids.encyclopediaArticle,
  'forum_post': SystemClassUuids.forumPost,
  'hearing': SystemClassUuids.hearing,
  'instant_message': SystemClassUuids.instantMessage,
  'interview': SystemClassUuids.interview,
  'letter': SystemClassUuids.letter,
  'magazine_article': SystemClassUuids.magazineArticle,
  'manuscript': SystemClassUuids.manuscript,
  'map': SystemClassUuids.map,
  'newspaper_article': SystemClassUuids.newspaperArticle,
  'patent': SystemClassUuids.patent,
  'podcast': SystemClassUuids.podcast,
  'preprint': SystemClassUuids.preprint,
  'presentation': SystemClassUuids.presentation,
  'radio_broadcast': SystemClassUuids.radioBroadcast,
  'report': SystemClassUuids.report,
  'standard': SystemClassUuids.standard,
  'statute': SystemClassUuids.statute,
  'tv_broadcast': SystemClassUuids.tvBroadcast,
  'video_recording': SystemClassUuids.videoRecording,
  // Workflows slice 2 (2026-10-30 — the everyday `question`/`plan` classes
  // join the frozen-extends authority: the system lock must know EVERY
  // system class UUID or a server-origined class.setExtends on one of them
  // would be treated as a user-class op; both map to the empty parent set).
  'question': SystemClassUuids.question,
  'plan': SystemClassUuids.plan,
};

/// The seeded `extends` edges the feature-cascade slice [systemClassExtends]
/// omits — the TS manifest `SYSTEM_CLASS_EXTENDS` is complete: organization
/// under agent (RENAMED web_page carries its edge in [systemClassExtends]
/// since 2026-10-23).
const Map<String, List<String>> systemClassExtendsLockExtra = {
  'organization': ['agent'],
};

/// Source-library roster (the TS
/// manifest `SYSTEM_ARCHIVED_BY_DEFAULT_CLASSES`): the new source
/// type-classes that seed ARCHIVED (`active = false`) — the long tail
/// nobody wants in a fresh workspace's gallery and pickers. EIGHTEEN
/// names: the everyday types (book_section, magazine_article,
/// newspaper_article, preprint, report, standard, podcast, the
/// broadcasts, the conference trio, audio/video) stay ENABLED by default.
/// NOTHING consumes this yet — it is seed data for the later slices (the
/// ensure paths seed the archived bit from it), exactly the core's
/// slice-1 state.
const List<String> systemArchivedByDefaultClasses = [
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

/// The frozen extends parent set per system class UUID (the Dart port of the
/// TS manifest `SYSTEM_CLASS_EXTENDS_IDS`) — the system-extends lock
/// authority (SCHEMA.md "Class properties"): a
/// system class's extends mapping is seeded platform structure the
/// feature-toggle cascade ([systemClassAncestors]) and binding inheritance
/// (the applier's `class_extends` walk) both derive from, so
/// `class.setExtends` on a system class only applies when the payload's
/// parent set EQUALS the seeded set (compared order-insensitively — the
/// seed/ensure re-issue convergence path); every deviation fails loud with
/// `SystemExtendsLockError` and is never applied. Classes absent from the
/// seeded edges map to the empty set. User classes stay freely extensible,
/// including onto system bases.
final Map<String, List<String>> systemClassExtendsIds = {
  for (final entry in systemClassSeedUuids.entries)
    entry.value: [
      for (final parent in systemClassExtends[entry.key] ??
          systemClassExtendsLockExtra[entry.key] ??
          const <String>[])
        systemClassSeedUuids[parent]!,
    ],
};

/// True when [id] is a fixed system-class seed UUID.
bool isSystemClassId(String id) => systemClassExtendsIds.containsKey(id);

/// Locked system classes (the classes-gallery
/// batch): the core seeds that can NEVER be archived or deleted —
/// `object.delete` fails loud (LockedSystemClassError) and an archival
/// write (`object.update {active: false}`) is rejected the same way. This
/// is the always-on set's locked CORE: the date chain + table, asset,
/// query, code, template, comment. The other always-on classes (callouts,
/// quote, whiteboard, …) are gallery-toggleable — disabling them archives
/// (`active = false`), it never deletes. Membership rides; nothing here is
/// ever feature-managed.
const List<String> lockedSystemClassNames = [
  'year',
  'month',
  'day',
  'table',
  'asset',
  'query',
  'code',
  'template',
  'comment',
];

final Set<String> _lockedSystemClassIdSet = {
  for (final name in lockedSystemClassNames) systemClassSeedUuids[name]!,
};

/// True when [classId] is a LOCKED system class (never archivable/deletable).
bool isLockedSystemClassId(String classId) =>
    _lockedSystemClassIdSet.contains(classId);

final Map<String, String> _systemClassNameById = {
  for (final entry in systemClassSeedUuids.entries) entry.value: entry.key,
};

/// The seed name for a system-class id, else null (user/unknown classes).
String? systemClassNameForId(String classId) =>
    _systemClassNameById[classId];

/// True when [feature] is a family toggle (derives class archival bits).
/// The `journal` toggle is surfaces-only — no family, no derivation.
bool isFamilyFeature(WorkspaceFeature feature) =>
    workspaceFeatureMap.containsKey(feature);

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

/// Delete routing: the owning feature when [classId] is a family's BASE
/// class, else null. The five bases route (task, event, meeting, source,
/// person — the TS domain test pins the meeting mapping); family children
/// that are NOT bases (book, birthday, …) fall to the other delete arms —
/// archival when they are system classes, plain trash when user classes.
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
/// to end (schema + option uuids). Binding rows carry NO order (owner
/// ruling 2026-10-21 — `sequence` retired from the binding; class panels
/// render alphabetically by property name). Status options carry the
/// designed glyphs (the owner-mandated icon + color set);
/// [display] (PROPERTY-level after the owner review) rides the
/// SCHEMA entry — the Status schema defaults to 'bullet' (its value rides
/// the block bullet as an icon button), the rest stay in the properties
/// panel (null). The binding row carries only the soft-unbind flag.
class TaskFamilySeedEntry {
  const TaskFamilySeedEntry({
    required this.schemaId,
    required this.name,
    required this.type,
    this.options = const [],
    this.display,
  });

  final String schemaId;
  final String name;
  final String type; // 'select' | 'datetime'
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
    type: 'datetime',
  ),
  TaskFamilySeedEntry(
    schemaId: SystemPropertyUuids.taskDeadline,
    name: 'Deadline',
    type: 'datetime',
  ),
  TaskFamilySeedEntry(
    schemaId: SystemPropertyUuids.taskPriority,
    name: 'Priority',
    type: 'select',
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
    type: 'datetime',
  ),
  // migrated recurrence as a plain select (no engine executes it);
  // authored optionless until the recurrence spec lands.
  TaskFamilySeedEntry(
    schemaId: SystemPropertyUuids.taskRecurrence,
    name: 'Recurrence',
    type: 'select',
  ),
];
