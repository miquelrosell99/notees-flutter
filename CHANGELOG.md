# Changelog

The record of shipped work for the Notees Flutter mobile client. One entry
per shipped slice, newest first. This file — not `AGENTS.md`, not `docs/` —
is where history goes; those stay static guidance. Before implementing a
change, skim this file for recent related work. Anything before 2026-10-06
lives in git history.

## 2026-10-23

- **feat(protocol,store): the source library — seed-manifest lockstep
  (Flutter port of the monorepo's source-library slice 1 tasks 3–5).** The
  system-seed manifests align with the TS seed authority
  (`packages/domain/src/seeds.ts` + `source-class-bindings.ts`): three
  system class RENAMES keeping their fixed UUIDs — `article` →
  `journal_article` (…0026), `weblink` → `web_page` (…0034), `movie` →
  `film` (…0035) — and the `paper` class WITHDRAWN (…0025, never reused:
  Zotero has no "paper"; nodes migrate to journal_article). The
  source-library roster lands: 30 NEW source type-classes (UUIDs
  …0048–…0065, alphabetical by key) ALL extending `source` — the
  frozen-extends lock authority (`systemClassSeedUuids` /
  `systemClassExtendsIds`), the sources-family cascade
  (`familyClassNames('sources')` now 40 classes), the icons/display-titles
  maps, and the gating walk all cover them; the 18-name
  `SYSTEM_ARCHIVED_BY_DEFAULT_CLASSES` set ports as
  `systemArchivedByDefaultClasses` (pure seed data — nothing consumes it
  yet, exactly the core's slice-1 state). The property axis: `authors`
  RETYPED object → text-multi (UUID …0012 unchanged, the agent filter
  superseded), `linkedAuthors` REINSTATED at its new UUID …0006-…0001
  (object-multi, targetClassFilter [agent] — the burned …0025 stays
  unused), `editors` ADDED at …0006-…0002 (text-multi); the local
  workspace seed's property slice is now the creator family
  (authors + linkedAuthors + editors, each bound to `source`), replacing
  the retired authors-object reversion. Structural divergences kept
  deliberate: the local seed still emits its curated class subset (the
  30-new roster is NOT locally seeded — a server attach converges it, and
  the applier's family-bit derivation no-ops over absent registry rows),
  and the rest of the bibliographic pool (the 80 non-creator properties),
  the per-class `SYSTEM_SOURCE_CLASS_BINDINGS` table, and the Zotero
  item-type manifest stay unported — no Flutter surface consumes them
  until the citation-import slices. Two store applier fixes ride the same
  slice (the core's `2441de071`, owner ruling 2026-10-23 "archival is
  VISIBILITY state, not an absence"): the `class_hierarchy` closure
  rebuild walks EVERY class row (the `active = 1` filter dropped an
  archived class's entire extends closure on the next `class.setExtends`),
  and the `class_cache` upsert's conflict arm never rewrites `active` (a
  re-issued `class.create` — the seed/ensure idempotent re-run — no longer
  revives an archived class). The vendored `object-create.json` fixture
  keeps its …0025 classId (opaque to the appliers; the core left it
  unchanged). **Verification:** `flutter analyze` clean; `flutter test`
  green (seed-parity suite extended: the roster pins — fixed ids, static
  maps, the frozen-extends lock coverage, the family cascade, the
  archived set — the creator-spec and emission-count updates, plus the new
  archival-semantics regressions: archived-survives-rebuild,
  re-create-never-revives, archived-type resolves through extends).

- **feat(protocol,store): external-id mappings — the `external_ref.*` op
  family (Flutter lockstep port of the monorepo's SCHEMA.md "External-id
  mappings" + TS store schema v30).** The plugin mapping substrate: a
  durable, per-workspace, log-carried `externalId -> nodeId` map so
  re-runs of an importer or a provider sync UPDATE the mapped node instead
  of duplicating it. `external_ref.set {ref, nodeId}` writes one LIVE
  mapping per (workspace, ref) — LWW by envelope (hlc, actor) on the ref
  key, so a re-set MOVES the mapping (re-targeting is legal) and a racing
  pair converges on the higher tuple under either delivery order; a stale
  write (full tuple <= the standing record) is dropped. `external_ref.delete
  {ref}` is the LWW delete side and keeps a TOMBSTONE per (workspace, ref)
  — including a delete of an UNMAPPED ref — so a stale concurrent set
  delivered after the winning delete is dropped on every replica and
  wipe → replay converges under any delivery order; at most one of {live
  row, tombstone} stands per key (a winning set deletes the tombstone, a
  winning delete deletes the live row). `ref` is the caller-namespaced key
  `<provider>:<kind>:<externalId>` (opaque to the protocol, 1..512 chars —
  empty/oversize fail loud in the strict validator); `nodeId` is a bare
  uuid with NO referential integrity (the property_value precedent — a
  mapping may name a not-yet-synced node). Both ops join the op registry
  (`OperationPayloads.knownOpTypes`) with strict factories
  `externalRefSet`/`externalRefDelete`; the appliers route by op type
  (the payload carries no addressed `objectId`), fail loud with
  `EnvelopeValidationError` on malformed payloads, and never swallow a
  write. Derived state: local schema v35→v36 (`external_ref` PK
  (workspace_id, ref) + node_id index, `external_ref_tombstone` — purely
  additive, the TS store's v29→v30 mirror) with the repository's
  record/upsert/purge methods and the two TS-parity reads
  `resolveExternalRef` (live table only — a tombstoned ref resolves null)
  and `externalRefsOf` (sorted reverse read). A node's HARD delete purges
  its live rows (the subtree purge in `NodeCacheRepository.hardDelete`,
  riding trash.empty too); soft-trash keeps them (a restore re-activates
  the node, mappings intact); ref tombstones survive their node's purge.
  Fixture corpus: `external-ref.json` vendored byte-identical (sha256
  9cf46b1b630be8db109cf999f451242ca880398eb43c2decc79068994145a47e)
  and wired into the parity gate + the replay suite — the canonical
  fixture converges forward AND with the mapping ops reversed (the
  tombstones kill the stale sets), plus soft/hard-trash and fail-loud
  payload suites. **Verification:** `flutter analyze` clean; `flutter
  test` green (payload registry, fixture parity, fixture replay).

## 2026-10-22

- **feat(protocol,store): the classes gallery + retired `class.delete`
  (Flutter lockstep port of the monorepo's 1423ce2c2).** Four wire/applier
  changes land together: (1) `object.update` gains the optional `active`
  boolean — `false` archives, `true` unarchives — a platform node field
  like icon/color; the applier projects it to the node row's archived flag
  and mirrors it to the class registry for class rows, with two archival
  refusals failing loud (the locked system classes can never be archived;
  family bases are toggle-managed — the Features setting is their single
  archive path; unarchiving stays legal). (2) `workspace.feature.set`'s
  feature enum gains `journal` — a SURFACES-only toggle (journal view +
  Today-page management) that derives NO class archival bits
  (`isFamilyFeature` is the applier guard). (3) `class.delete` is RETIRED
  from the op registry — rejected outright like any unknown op type; a
  replayed log entry is ignored. (4) `object.delete` on a class node routes
  four ways, all a pure function of the class id: LOCKED system classes
  (year, month, day, table, asset, query, code, template, comment — new
  `lockedSystemClassNames`/`isLockedSystemClassId`/
  `systemClassNameForId` in `workspace_features.dart`) fail loud with the
  new `LockedSystemClassError`; family bases route to
  `workspace.feature.set {enabled: false}`; other system classes archive
  (`active = false`, no trash row — the unarchive path is the archival
  write, never `object.restore`); user classes take the plain trash row.
  Membership RIDES every removal path: the membership sweep is gone from
  the delete arms and `trash.empty`, so `class_member_set` pairs survive
  archive, trash, restore, and permanent delete (the dangling-reference
  state); `object.restore` gained a class-only root path (registry
  reactivation + subtree reactivation). `_deriveFamilyClassBits` now also
  flips class node rows that exist. Fixture corpus: byte-identical sync
  with the monorepo — `object-update-active.json` and
  `object-delete-class-routing.json` added, `workspace-feature-set.json`
  gains the journal pair, `class-delete-managed.json` deleted; the replay
  gate excludes the routing fixture (its locked delete throws) and pins
  all four arms, and the `workspace-feature-set` replay now expects the
  `journal` row. **Verification:** `flutter analyze` clean; `flutter
  test` green (payload registry, feature routing, fixture replay).

- **feat(sync): WS auth moves to the `Authorization` upgrade header —
  `?token=` retired (Flutter lockstep port of the monorepo's
  0ea18fcd5, WIRE.md §2).** The relay now REJECTS `?token=` credential
  query params on the entire API (401) — a bearer token in a URL lands in
  every log along the path — and the WS upgrade `/api/relay/v2/ws/
  {workspaceId}` admits auth as an `Authorization: Bearer <credential>`
  header (native-client path; the `?ticket=` flow is browser-only and not
  needed here). `buildRelayWsUrl(baseUrl, workspaceId)` loses its token
  parameter entirely (the `/api` suffix-trim and http→ws mapping
  unchanged); the credential now travels as
  `{'Authorization': 'Bearer $apiKey'}` on every connect, including
  backoff reconnects: `RelayWsClient` gains a `headers` field, the
  `WsConnector` typedef becomes `(String url, Map<String, String>
  headers) → Future<WsConnection>`, and `defaultWsConnector` switches
  from `WebSocketChannel.connect` (cannot set headers) to
  `IOWebSocketChannel.connect(uri, headers: …)` from
  `package:web_socket_channel/io.dart` (pinned 3.0.3; dart:io is
  available on Android/iOS/Linux). The `WsConnection` seam is untouched —
  tests still inject scripted fakes. `SyncV2Service.startRealtime`
  passes the header map; the Dio REST layer already attached
  `Authorization`/`X-API-Key` via interceptors and needed no change.
  Docstrings updated (`?token=` rationale recorded at each anchor).
  **Verification:** `flutter analyze` clean; `flutter test` green —
  URL assertions no longer expect a query string, a new unit proves the
  URL carries no credential, the connector-fake suite asserts the
  `Authorization` header reaches the connector on connect AND reconnect,
  and the engine-level realtime test captures the header the production
  connector would send. Shipped via CI APK on push to main.

- **feat(protocol,store): the system-extends lock — a system class's
  `extends` mapping is frozen to the seeded set (Flutter lockstep port of the
  monorepo's owner ruling 2026-10-22, SCHEMA.md "Class properties").**
  `class.setExtends` on a SYSTEM class applies only when the payload's
  `parentClassIds` set EQUALS the seeded parent set (order-insensitive — the
  seed/ensure re-issue convergence path keeps working); every deviation fails
  loud with the new `SystemExtendsLockError` and is never applied. The guard
  runs after the class-node existence check, before the parent-existence and
  cycle checks (TS ordering). Authority: `systemClassExtendsIds` in
  `domain/models/relay/workspace_features.dart` — the Dart port of the TS
  manifest `SYSTEM_CLASS_EXTENDS_IDS` (every system class UUID resolved to its
  seeded parent UUIDs via the full `systemClassSeedUuids` map; classes absent
  from the seeded edges are frozen to the empty set), with `isSystemClassId`
  alongside. The full map needs the three seed UUIDs the mobile seed delta
  never carried (`organization`/`collection`/`highlight`, …031–…033), added
  to `core/constants/system.dart` — additive constants only, the seed delta
  itself is untouched. User classes stay freely extensible, including onto
  system bases. New vendored fixture `class-extends-system-lock.json`
  (byte-pinned, sha256-verified against the monorepo corpus) — added to the
  fixtures-test gate list and excluded from the all-fixtures replay; the
  replay suite pins its accepting prefix (user class → meeting, meeting →
  event re-issue) and its three-envelope rejecting tail (detach, extra
  parent, empty-set deviate), each throwing the lock error and leaving
  `class_extends` exactly at the two prefix edges. No local DB schema change.
  **Verification:** `flutter analyze` clean; `flutter test` green. Shipped
  via CI APK on push to main.

## 2026-10-21

- **fix(search,picker): diacritic folding — `video` finds the class
  "Vídeo" (the web store's `foldSearchText` mirror).** The local search
  index and the class-mode node picker compared raw lowercased text, so an
  unaccented query missed accented names everywhere: the search screen, the
  node picker (all modes — page/any ride the term index, class mode filtered
  raw display names), and every `searchLocal` consumer. `tokenize()` now
  strips diacritics (`diacritic` package — pure Dart; the SDK has no
  Unicode normalization), folding BOTH the index build and every query in
  one place (the index/query mirror pair by construction, same rule as the
  web store's `foldSearchText`); the node picker's class mode folds both
  sides of its substring match. Local DB schema v35 clears `search_index` —
  the sync service's `shouldReindexSearch()` backfills with folded terms on
  the next boot. Verification: `flutter analyze` clean; `flutter test`
  green — new tokenize folding units (both directions), an index+query
  mirror test, and a repository-level `searchNodes` test over the real
  sqflite schema (unaccented query, accented query). Shipped via CI APK on
  push to main.

- **feat(protocol,render): the `external_link` retirement — links are
  markdown spans inside `text` tokens, parsed at render time (Flutter
  lockstep port of the monorepo ruling 2026-10-21, SCHEMA.md "Content
  grammar").** The `external_link` token RETIRES: links live as markdown
  `[label](href)` spans inside ordinary `text` tokens, parsed at render
  time. `ExternalLinkToken` and its `fromJson` dispatch arm are gone —
  unknown wire types already degrade to `UnsupportedToken`. Render grammar
  (normative, ported 1:1 from `splitMarkdownLinks` in
  `packages/domain/src/markdownLinks.ts` into
  `domain/models/content/markdown_links.dart`): match
  `\[([^\]\n]+)\]\(([^()\s]+)\)`; only `http:`/`https:`/`mailto:` hrefs
  render as anchors (underlined, accent-colored, tappable via the existing
  `onExternalLinkTap` handler); unclosed brackets, other schemes
  (`javascript:`, relative paths) stay literal text. `AstRichText`'s text
  span builder splits each run through the parser — link segments get the
  same underline/accent look the old token arm had, and plain segments keep
  their marks. Legacy conversion (`ast_stringifier.dart`): the `{url,
  children}` pill now converts to a text token carrying `[text](href)`
  (marks ride along), which `AstBuilder.toMarkdown` writes verbatim and
  `parseInline` reads back as plain text — the editor text form
  round-trips the shape; the retired type leaves `isFlatTokenStream`'s
  vocabulary and `ast_builder.dart`'s dead serializer arm. **Verification:**
  `flutter analyze` clean; `flutter test` green (674 tests). No fixture
  bytes change (no fixture ever carried the token).

## 2026-10-21

- **feat(protocol,store): the readonly retirement — `readonly` derives from
  the system list, not stored (Flutter lockstep port of the monorepo's owner
  ruling 2026-10-21, a continuation of the property-definition surfaces
  batch).** The `readonly` render contract RETIRES from
  `propertySchema.create/update` — an enumeration of the seeds finds ZERO
  system properties that ever carried the flag, so it was never user
  configuration. The strict payload validator rejects the retired key on
  both schema payloads like any unknown key; `hideWhenEmpty`/`display` stay.
  Readonly-ness now DERIVES from the system property list —
  `isReadonlyProperty(schemaId)` in `core/constants` (fixed seed UUIDs,
  precise) covering the platform-provenance schemas `generatedFrom`
  (…000000000027) + `alias` (…000000000028), mirroring the monorepo's
  `isReadonlyProperty` in packages/domain. Data layer: local store bumps to
  schema **v34** — the legacy NOT NULL `readonly` column on the local
  `property_schema` cache table rebuilds away (same-table copy, the v26/v32
  rebuild pattern; no data backfill); `PropertySchemaRow` and the
  `EffectivePropertySchema`/`EffectiveProperty` read models drop the field.
  **Verification:** `flutter analyze` clean; `flutter test` green (668
  tests). No fixture bytes change (no fixture ever carried the flag). The
  live log rewrite (`migrate-drop-schema-readonly.mts`) runs in the
  monorepo after this port (the fixture gate law).

## 2026-10-21

- **feat(protocol,store): the binding-sequence retirement —
  `class.property.set` is active-only (Flutter lockstep port of the
  monorepo's owner ruling 2026-10-21, a continuation of the
  property-definition surfaces batch).** `sequence` RETIRES from the
  binding: class properties render as a PURE ALPHABETICAL list everywhere
  (by property name, a read-time derivation), so panel order no longer
  exists to configure; the binding keeps only the `active` soft-unbind flag.
  The strict payload validator rejects the retired key like any unknown key
  (the row carries ONLY the genuinely per-class mechanic). Data layer: local
  store bumps to schema v33 — `class_property` REBUILDS without `sequence`
  (the v26/v32 rebuild pattern; no data backfill — order metadata is
  discarded; the historical v26/v32 migration views drop it too), the
  snapshot reader guards the column for pre-v26 server snapshots, and the
  effective-properties read orders PURE ALPHABETICALLY by property name,
  unbound authored rows last, `(idx, elementId)` tiebreak — the
  `EffectiveProperty.sequence` field is gone. The applier's binding upsert
  is `active`-only; the task-family seed-ensure (and the local workspace
  seed) bind sequence-less — `TaskFamilySeedEntry.sequence` is gone.
  Fixtures: `class-property-defaults`/`class-property-active`/
  `class-unassign`/`property-schema-scope` re-vendored byte-identical
  (sha256-verified) from the monorepo. The block-bullet value button's
  ordering rides the effective read's alphabetical order.

  Verification: `flutter analyze` clean; `flutter test` green (see the run
  on main). The live log rewrite
  (`scripts/migrate-drop-binding-sequence.mts`) runs in the monorepo after
  this port (the fixture gate law).

## 2026-10-20

- **feat(protocol,store): the binding-default batch — `defaultValue` moves
  to the property schema, `required` retires (Flutter lockstep port of the
  monorepo's owner ruling 2026-10-20, the property-definition surfaces
  batch).** `class.property.set` is now STRICTLY `{classId,
  propertySchemaId, sequence?, active?}` — `required` and `defaultValue`
  RETIRE from the binding and the strict payload validator rejects both like
  any unknown key (the row carries ONLY the genuinely per-class mechanics).
  `propertySchema.create`/`update` gain `defaultValue` (any JSON value,
  optional; the property's ONE GLOBAL default — the Logseq shape): PC2
  typing is enforced fail loud at apply — string for text/url/email/image/
  select, finite number for number, boolean for boolean, string array for
  multi_select, JSON null only for datetime/object/asset ("a default that
  links a node is meaningless") — validated against the payload's type at
  CREATE and the schema's STORED type at UPDATE (keep/clear: absent keeps,
  explicit null clears; a schema-less write stores unchecked). Data layer:
  local store bumps to schema v32 — `class_property` REBUILDS without
  `required`/`default_value` (the v26 rebuild pattern; `property_schema.
  default_value` is the legacy column reused verbatim as the moved default's
  home, guarded additive). Effective-properties read: a derived default row
  materializes when a winning ACTIVE binding brings the property into the
  node's context AND the schema row carries a non-null default — the VALUE
  is schema-sourced (per-class default conflicts no longer exist), the
  winning binding still supplies boundBy/sequence; `required` drops from
  the effective-row read model. The default-mirror sweep (class.unassign)
  sources defaults from the schema rows now and compares decoded JSON texts
  (the old decodeDefault re-encode quirk inverts: an authored number sweeps
  a number default, a string survives). UI: the block-bullet value button's
  "None" row always shows (`required` hiding was mild enforcement —
  suggestion only, never enforcement). Fixtures: `class-property-defaults.
  json`, `class-property-active.json`, `class-unassign.json` re-vendored
  byte-identical from the monorepo (sha256-verified; the defaults fixture
  gains the trailing second class.property.unset). **Verification:** `flutter
  analyze` clean; `flutter test` green (668 tests).**

- **feat(protocol,store): the property-scope batch + validationRules value
  enforcement + per-block listStyle (Flutter lockstep port of the
  monorepo's 2026-10-20 slices, TS `b8548e0e` + `19baac4b` + the
  list-style field).** `propertySchema.create` RETIRES the display-only
  `scope` enum (rejected outright like any retired key — hand-rolled strict
  validators pin the unknown-key reject) and gains `icon` (nullable MDI
  name) + `scopeClassIds` (nullable non-empty uuid list — absent/null =
  global, exactly one spelling of "global"); `propertySchema.update` gains
  `icon`, `scopeClassIds`, `targetClassFilter`, `multi`, and
  `validationRules` ({min?, max?, pattern?} — strict keys, numeric bounds,
  min ≤ max at parse time; absent keeps / present-null clears throughout).
  Wire semantics now enforced at apply time, fail loud, mirroring the TS
  reference: **R3** — `property.set` fails loud (`MoveGuardError`) when the
  node's class closure (its classes + extends ancestors) misses the schema's
  scopeClassIds; **R5** — `class.property.set` on an out-of-scope binding is
  rejected as dead config (the binding class's own extends closure counts);
  **R2** — a schema carrying stored validationRules validates every
  `property.set` value BEFORE the write (inclusive min/max on numbers after
  the numeric-string normalization, full-string `^(?:…)$` pattern on
  text/url/email scalars only — carrier {nodeId} refs and schema-less
  writes ride unchecked, each multi element at its own add), and a
  `propertySchema.update` carrying rules checks applicability against the
  schema's STORED type plus pattern compilability at the rule write.
  **R4** — the effective-properties read tags ineligible authored rows
  `eligible: false` (narrowing is never retroactive) and never derives a
  default for an ineligible node. `object.create`/`object.update` carry the
  optional nullable `listStyle` ('numbered' | 'alpha' | 'roman'; absent/null
  = the bullet default, present-null clears — the icon/color precedent); the
  derived store projects it as `node_cache.list_style` (the marker number
  stays render-time, never stored). Data layer: local store bumps to schema
  v31 — `property_schema.scope_class_ids` (the v11-era `icon` /
  `validation_rules` columns already carry the wire shape and are reused
  verbatim) + `node_cache.list_style`, both guarded additive ALTERs; the
  legacy display-only `scope` column stays (round-tripped, zero availability
  semantics). Seeds: the tasks-enable task-family schemas seed at GLOBAL
  scope (owner ruling 2026-10-20, the seed-scope audit — the whole family is
  reusable), and the local workspace seed's `authors` spec now seeds
  `scopeClassIds: [source]` per the TS manifest. Fixtures: the corpus
  re-vendors from the main repo (36 files, sha256-identical —
  `object-list-style.json`, `property-schema-scope.json`,
  `property-schema-update-fields.json`, `property-validation-rules.json`
  added; `property-validation-rules.json` joins the replay-excluded set — its
  rejecting tail throws on apply by design, each reject pinned in the replay
  suite). **Verification:** `flutter analyze` clean; `flutter test` green
  (664 tests).

## 2026-10-16

- **feat(model): node links carry their own `isEmbedded` flag — manual,
  default false (main-repo lockstep, owner ruling 2026-10-16).** The
  `MentionToken` model accepts the optional `isEmbedded` boolean (absent/
  false = an ordinary inline link); the local store bumps to schema v30 —
  `edge` gains `is_embedded INTEGER NOT NULL DEFAULT 0` (TS store v22
  parity, guarded additive ALTER). Embedding is a per-link USER choice:
  only a link marked embedded — and sole in its block — presents the
  target's content in place; every pre-existing link reads false. Also
  lands the deferred merge of the Revision-12 embedding-model slice (this
  repo's `main` now carries the rename, the parent-page guard, and local
  schema v29). Fixtures: the corpus re-vendors from the main repo's slice
  (32 files, sha256-identical, `link-embedded.json` added). **Verification:**
  `flutter analyze` clean; `flutter test` green (642 tests).

- **feat(model): the Revision-12 embedding model — `isEmbedded` replaces

- **feat(model): the Revision-12 embedding model — `isEmbedded` replaces
  `presentAsMain` (polarity inverted), the parent-page condition guard, and
  the fixture corpus re-vendor (main-repo lockstep, owner 2026-10-16).** The
  node model's three concerns are named separately: classification
  (`is_class`), parent relationship (`parent_id`), and embedding
  (`is_embedded` — whether the node's content belongs to the parent's body;
  true = the Block role and the DEFAULT for parented nodes, false = the
  standalone Page role). Wire: `objectCreate`/`objectUpdate` carry optional
  `isEmbedded`; the strict validators reject the retired `presentAsMain`
  key; the seed/sync payload builders emit the explicit standalone claim
  for roots and journals. Appliers: defaults parentless → standalone,
  parented → embedded; promotion = the false claim and still stringifies
  the content. **The parent-page condition ships with this slice** (the
  2026-10-15 lockstep debt): a standalone claim under a non-page parent
  fails loud on create, promotion, and move; demotion of a parented page
  is gated on its standalone children being gone; the recursive
  `_isPageRow` chain walk enforces it. Data layer: the local store bumps
  to schema v29 — `node_cache` rebuilds, renaming `present_as_main` →
  `is_embedded` with polarity inversion (class rows converge to 0) and
  recomputing the derived `is_page` flag (`is_class OR parentless OR
  is_embedded = 0`); the v2 snapshot schema (exchanged with the TS store)
  carries the v21-shaped `is_embedded` column. UI: the render-state
  helpers and editor screens read the renamed flag (a page = parentless
  or not embedded). Fixtures: the corpus re-vendors from the main repo's
  landed slice (31 files, sha256-identical — the
  `present-as-main-parent-page.json` → `is-embedded-parent-page.json`
  rename plus `object-is-embedded.json` and `heading-content.json`); the
  parent-page fixture joins the replay-excluded set. **Verification:**
  `flutter analyze` clean; `flutter test` green (641 tests).

## 2026-10-15

- **feat(appliers): the no-divergence law — content-asserted membership,
  the class.unassign content lock, and the class-delete membership sweep
  (Flutter lockstep port of the monorepo's 2026-10-15 slice).** A
  `class_link` token in a stored content stream IS a classing of its node:
  the object create/update appliers OR-set-add the referenced classes (any
  writer converges; document-chrome content still flattens, date-chain
  nodes keep their fixed class). `class.unassign` refuses loud while the
  stored content references the class (the removal gesture strips the links
  first). Deleting a class node (trash or permanent, and trash.empty)
  sweeps its memberships — trash tombstones the pairs, permanent purges
  them — via the new `NodeCacheRepository.sweepClassMembership`. The
  vendored wire corpus gains `class-link-assertion.json`. **Verification:**
  `flutter test` — all 638 tests pass.

## 2026-10-15

- **refactor(protocol)!: `class_chip` → `class_link` — the Flutter lockstep
  port of the monorepo's 2026-10-15 rename.** The render-only inline class
  reference (a node link, class variant — wavy underline, no membership
  effect) is renamed across the token model (`ClassLinkToken`, the
  `'class_link'` wire string), the AST builder (quick-capture template
  substitution), the stringifier, the rich-text renderer, and the inbox
  card view; the vendored wire corpus gains `class-link.json` (gate list
  updated). Render-only semantics are untouched. The strict schema rejects
  the retired `class_chip` key outright — the monorepo's stored-log
  migration rewrites live envelopes before clients re-sync. **Verification:**
  `flutter test` — all 637 tests pass.

## 2026-10-14

- **feat(protocol): `trash.empty` bulk op — the Flutter lockstep port of
  the monorepo's additive wire change (envelope v3, no protocol bump).**
  The payload is a strict empty object (any key rejects like the relay's
  422 gate), the op joins the registry, and the applier permanently
  deletes every node carrying a non-permanent `trash_root` row: the root
  set is an apply-time snapshot ordered by node_id, each root goes
  through the same `NodeCacheRepository.hardDelete` body as
  `object.delete {permanent: true}`, a root consumed by an earlier
  iteration's subtree (an independently-trashed descendant) or a stale
  nodeless row is swept, never fatal, and a second apply over an empty
  trash no-ops. Concurrency is plain log order: a restore landing before
  the empty leaves the apply-time set (survivor), one landing after is
  LWW against the delete. Tombstone bookkeeping stays this store's
  established permanent-delete behavior — hard-delete PURGES `trash_root`
  rows rather than recording the TS reference's `is_permanent = 1`
  tombstone — per the pre-existing divergence, not a new retention
  behavior. The `trash-empty.json` fixture is byte-identical to the
  monorepo corpus (sha256-verified) and is covered by the parity gate,
  a dedicated replay assertion (A/B and their children hard-deleted, the
  restored C active with no trash row), per-op applier tests, and the
  all-fixtures replay sweep.

## 2026-10-13

- **feat(store): date-chain parent+class locks — the Flutter port of the
  monorepo's parent-lock/class-lock slice (TS a35bb7c5), clearing the
  LOCKSTEP-PENDING marker in the main repo's `SCHEMA.md`.** A date node's
  parent IS its deterministic chain parent (year at the workspace root,
  month under its year, day under its month) and its class set IS its
  precision's system class — nothing else, never declared a class itself.
  The guards land in `RelayAppliers`, matching the TS appliers' semantics
  and error wording exactly so all three clients reject alike: `object.move`
  with any other parent (parentless included for month/day) fails loud
  BEFORE the row-LWW gate; `object.create` claiming a non-chain parent fails
  after the parent-existence check, while a parentless create stays legal
  (the standalone shape the chain self-heal adopts); `object.create`'s
  classIds guard runs at the top of the applier — BEFORE the OR-Set
  membership seeding and the first-create-wins early return — so the
  re-issued-create carrier (this client has no `class.assign` op) cannot
  sneak a foreign class onto a date id; `class.unassign` of the precision's
  system class fails loud (foreign-class unassign stays legal as legacy
  cleanup); `class.create` on a date id fails loud before the conversion
  flip. All five throw the existing `MoveGuardError`, so the sync service's
  `on StoreError` quarantine/skip-and-continue paths apply unchanged. New
  domain helpers `dateChainParentId` / `dateChainClassId` in
  `lib/core/utils/date_uuid.dart` derive the locked parent/class from the
  date id via the existing deterministic encoders (the 1900..2200-window
  `parseDateNodeId`, not the legacy-prefix `journalDateFromUuid`). Tests:
  date_uuid unit round-trips + a full guard matrix in
  `test/relay_appliers_test.dart` (rejected moves create nothing, chain-
  correct moves/creates stay legal, the re-issued-create foreign-class
  rejection, foreign-class unassign legal). No wire change — the vendored
  fixtures are untouched. Verification: `flutter analyze` clean, `flutter
  test` green.

## 2026-10-09

- **feat(packaging): the repo ships an Arch Linux PKGBUILD for the Linux
  desktop client.** `packaging/arch/PKGBUILD` builds the Linux GTK bundle
  from the release-tag tarball and packages it for pacman (`/opt/notees`
  bundle, `notees` on PATH, `.desktop` + icon, runtime `depends` from the
  bundle's `DT_NEEDED`). The operations skill and `releases.md` claimed
  "no PKGBUILD/AUR" — corrected: the pacman flow is documented, including
  the per-release `pkgver` + tarball-sha256 bump (the tarball exists only
  once the tag is pushed, so it lands in a follow-up commit). Built and
  installed locally with `makepkg` — never CI (no runner has the Flutter
  Linux toolchain), not submitted to AUR; needs a local Flutter SDK
  (`~/flutter`, `FLUTTER_ROOT` override). Verification: `makepkg -s` from
  `packaging/arch/` green; package installed via `pacman -U` and the app
  smoke-launched on the fleet workstation.
- **fix(auth): the strict server bodies ride clean — `register` drops the
  retired `remember_me` key, and the connect prompt says "a Notees sync
  server".** The login path already sent exactly `{email, password}` (the
  server's strict schema 422s extra keys), but `register` still shipped the
  legacy `remember_me` field and would have failed the same way; the param
  and the key are gone (session lifetime is server-owned — 30-day sliding
  sessions). The dead "Remember me" checkbox and the ignored `rememberMe`
  login parameter retire with it. The server-setup prompt reads "Enter a
  Notees sync server URL" (owner wording ruling — the GTK and web clients
  ship the same wording). Verification: `flutter analyze` clean, `flutter
  test` 621 passed.
- **feat(protocol,store): the unified Datetime property type — the
  `date`/`date_range` retirement lockstep port.** Lockstep with the
  monorepo's TS reference (the d58aeb1c + dbfd6d29 batch): the
  `propertySchema.create` type enum retires `date`/`date_range` and adds
  `datetime` — the strict validator (payload builder + apply-time
  `validatePayload`) rejects the retired values outright, matching the zod.
  The value union is one shape per value: a POINT `{ "nodeId": …, "time"?:
  "HH:MM" }` (a legacy bare-uuid string normalizes to `{nodeId}`, the
  archived `date` encoding) or a RANGE `{ "start": slot|null, "end":
  slot|null }` with either side open and both-open legal; a value carrying
  BOTH `nodeId` and `start`/`end` fails loud, and a `time` must be 24h
  minute-precision `HH:MM` riding a DAY-precision date-node ref (a
  month/year anchor or a non-date id has no wall-clock time). The PG6
  graph checks mirror the old `date_range` arms per non-null slot
  (existence / targetClassFilter / the datePrecision ceiling — a timed
  day ref on a coarser-than-day ceiling claims finer granularity and
  throws). PC2 stays node-typed: a `datetime` schema accepts only a null
  binding default. The task-family seed manifest (Scheduled / Deadline /
  Closed) and the fallback task property constants retype to `datetime`
  (the Flutter seed carries three of the TS six — eventDate, meetingDate
  and publicationDate are not locally seeded, by design); the legacy
  property value cell routes `datetime` through the date picker.
  `test/fixtures/wire/` re-vendors the canonical corpus — sha256-match
  the TS reference 25/25 (gate 24→25, `property-datetime.json`), and the
  fixture replay test now asserts the union values land (the timed range
  end wins the 'When' LWW slot, the year-precision point rides the 'Year'
  schema) plus the four fail-loud mirrors (mixed shape, malformed time,
  timed value over a year ceiling, ghost slot ref). Verification:
  `flutter analyze` + `flutter test` green (621 tests).
- **feat(protocol): `object.update` gains the `description` wire node field
  (the page subtitle, max 512 chars).** Lockstep with the monorepo's TS
  store schema v17→v18: the optional nullable plain-text field joins
  `coverAssetId` / `bannerAssetId` / `aliasedNodeId` — presence writes,
  present-null clears (SQL NULL), absence preserves; `object.create`
  still carries none (the strict validator rejects it there). The payload
  builder takes the `_undefined`-sentinel parameter like the other wire
  node fields; the strict validator admits the key and enforces the 512
  cap (the zod `z.string().max(512).nullish()` port). The applier maps it
  into the Node model; `node_cache` gains the `description` derived
  column at local schema v28 (idempotent additive migration, `_migrateV28`,
  bumping the v27 cover/banner/alias batch). The canonical fixture
  `object-wire-fields.json` is copied byte-identical from the monorepo
  (two new trailing envelopes: set `"Subtitle text"`, clear `null`), and
  the fixture replay test now asserts the description set + clear land in
  both the Node payload and the derived column. Verification:
  `flutter analyze` + `flutter test` green.

## 2026-10-08

- **feat(launcher): Android and iOS carry the Margin Green mark.** The
  launcher rasters are regenerated from `brand/assets/logo/app-icon-512.png`
  (PIL, LANCZOS): the Android legacy `mipmap-*` set (48–192), the adaptive
  foregrounds (108–432, the white symbol extracted onto transparent at the
  62% safe zone), the themed-icon monochrome drawable (the margin + three
  annotations as vector path data), and every size in the iOS
  `AppIcon.appiconset` per its Contents.json. The adaptive background and
  the widget palette (`notees_sage`, `widget_paper`) move to the brand
  tokens (Advance Green `#2e5e46`, paper `#f7f4ec`). Verification: rasters
  re-opened and dimension-checked; `flutter analyze` + `flutter test`
  green.
- **fix(editor): the header cover reads the `coverAssetId` wire node
  field, not the retired cover property.** The wire-fields slice moved
  the cover off the image-typed `cover` system property (uuid …0005)
  onto the `coverAssetId` node field (the migration rewrote stored
  values), and the plumbing here already projected it (payload builder +
  strict validator, applier, `node_cache` columns, the Node model) — but
  the editor header still extracted the asset uuid from the retired
  property rows, so migrated covers silently did not render. The screen
  now takes `_coverAssetUuid` from `page.coverAssetId` (the cached Node
  the load path already holds); the retired-property extraction helper
  is gone, along with the now-dead cover filters in the display-property
  merge (nothing authors cover property rows) and the stale
  re-extraction after property writes (a property write cannot change
  the field). Doc comments updated (`node_editor_screen.dart`,
  `cover_image_widget.dart`). Test: `node_cache_repository_test.dart`
  pins the upsert/getByUuid round-trip of coverAssetId/bannerAssetId/
  aliasedNodeId — the cached-model contract the header reads.

- **feat(ui): align the Flutter client to the Margin Green brand — theme
  tokens, icons.** The brand repo (`notees-brand`, tag `v1.0.0`) is consumed
  as a git submodule at `brand/` (pin it; never commit inside). Theme: the
  color constants and both schemes are remapped to the brand tokens
  (`brand/assets/tokens/tokens.css` is authoritative) — light ground is paper
  `#f7f4ec` with ink text `#221a13` and border `#d8d3c7`; dark ground is the
  `#161412` family (`surface` `#221a13`, alt `#312a22`, border `#483f37`,
  text `#f4f3f1`, muted `#a6a09a`); the seed and the functional accent are
  Advance Green `#2e5e46` (the old sage `#5B7D5B` and cream `#F5F3EF` are
  retired); error keeps its semantic role on the brand danger scale
  (`#b4312b` light / `#fe8477` dark); the pure-black OLED scale is untouched.
  Web identity: `web/favicon.png`, `web/icons/*.png` are replaced with the
  brand favicon/app-icon assets (the 512 is the brand `app-icon-512`, the
  192 is a LANCZOS resize, the maskables pull the symbol into the 80% safe
  zone on the icon's own `#2e5e46` ground) and `web/manifest.json` carries
  the brand `theme_color`/`background_color` instead of the stock Flutter
  blue. Pending, deliberately out of this slice: (1) Android/iOS launcher
  icons — the repo has no `flutter_launcher_icons` (or equivalent) config and
  hand-editing platform rasters would bypass the canonical generator, so the
  `mipmap-*`/`AppIcon.appiconset` rasters still show the old mark; adopt the
  generator pointed at `brand/assets/logo/app-icon-512.png` and regenerate.
  (2) Brand typefaces — the app bundles no fonts (system Roboto/Georgia
  stacks); bundle Instrument Sans (chrome), Newsreader (reading), and
  JetBrains Mono (data) per `brand/guidelines/fonts.md` (OFL via
  `google_fonts`) in a follow-up. Verification: `flutter analyze` reports no
  issues and `flutter test` passes (612/612) on the host SDK; theme/web
  changes are value-for-value against tokens.css; generated PNGs re-opened
  and dimension-checked (16/192/512, maskable safe zone confirmed).


## 2026-10-07

- **feat(editor): the node-alias chrome — the title-row aliases
  affordance + the alias-side "Aliased node" row.** The minimal honest
  set on the `aliasedNodeId` wire field (SCHEMA.md "Node aliases"),
  composed from the client's own idioms (the properties card + the pages
  node picker + a modal bottom sheet), not a literal port of the web
  chrome. The title row gains an "Aliases · N" chip opening a sheet that
  lists every page whose alias-terminal is this node (chains included —
  the store's new recursive `aliasNodeIdsOf` read over
  `aliased_node_id`) and authors new aliases through THE BACKWARD WRITE
  (the picked page's `aliasedNodeId` becomes this node — one
  `object.update` via the new `SyncV2Service.setAliasedNode`, applied
  locally and pushed on the next flush); a sheet row returns the alias
  uuid and the caller opens the ALIAS page itself (the app has no
  redirect seam, so the plain push lands on the alias's own view). An
  alias page's properties card gains ONE pseudo-property row naming the
  main page — open / change (re-point: the carrier's OWN field) / clear
  (present-null) through the same write, with a broken-reference state
  when the target row is gone. The client-side pick guard (page-only, no
  self-alias, never repointing a page that already is an alias — the
  web's `aliasedNodeTargetError`) validates before writing; the applier's
  write-time cycle check stays the final authority. Tests:
  `alias_nodes_test.dart` (the guard, the write/listing round-trip, the
  loud cycle rejection) + the recursive-read listing pins in the
  fixture-replay alias-cycles group. Wire/fixtures untouched (the field
  landed in the earlier alignment batch).

- **feat(seed): the local seed authors display titles + the full events
  family (seed convergence follow-up).** The local workspace seed's
  class.create titles move from the raw keys (`tv_series`) to the display
  wording (`TV series`): `workspace_features.dart`
  `systemClassDisplayNames` grows from the #14 five to one entry per
  seeded class (the seeds.ts `SYSTEM_CLASS_DISPLAY_NAMES` slice — the
  server seed's exact shape, title-is-content) and the seed resolves
  titles through it. The events family seeds as a UNIT — meeting + event
  + birthday join trip (the server seed keeps the full family, so the
  local subset mirrors it whole and the events/meetings toggles flip
  real rows) — which restructures the emission into the server seed's
  two-pass shape: every class.create lands before any class.setExtends,
  so an edge may target a class declared later in the map (meeting
  extends event). The property-schema axis stays the citations
  revision's `authors` spec only — the documented divergence: the
  meeting/event/birthday bindings (like the source family's bibliography
  specs) are server-seeded and converge on attach. The emission count
  moves 39 → 43 (33 class.create + 7 class.setExtends + the authors pair
  + Inbox); the parity suites pin the display titles (wording + per-key
  completeness, no raw keys), the meeting/birthday fixed ids + extends
  edges + closures, and the class_cache display names end to end.

- **feat(seed): port the #14 follow-up five — definition/idea/place/
  project/trip seeds, the trip→event cascade (seed convergence).**
  Mirrors the GTK lockstep commit fd50e5c and the monorepo's
  `packages/domain/src/seeds.ts` (owner list, 2026-10-06 — plain seeds
  per the meeting-system ruling, zero wire cost): `SystemClassUuids`
  gains the five fixed class ids (…0043-…0047);
  `workspace_features.dart` resolves them (`systemClassUuids`) with
  their mdi icons + display titles (`systemClassIcons` /
  `systemClassDisplayNames`, the seeds.ts slices) and the `trip → event`
  extends edge — so the events-family cascade (family set, gating walk,
  the applier's archival re-derivation) reaches trip exactly like
  meeting/birthday, while the four plain seeds stay unmanaged (no
  gating, not always-on — features.ts parity). The local workspace seed
  (serverless mode) emits the five too (plus `event` as trip's extends
  target — the calendar family root), so a locally seeded workspace
  no longer misses classes the server seed authors. The parity suites
  pin the manifest: `seed_parity_test.dart` gains the deploy-catalog
  five group (fixed ids, the withdrawn …0001/…0042 slots untouched,
  static-map coverage, the features.ts gating/family mirror) and the
  seed-emission count moves 32 → 39 (31 class.create — event joins as
  trip's extends target — + 5 class.setExtends + the authors pair +
  Inbox);
  `workspace_features_test.dart` pins the four-strong events family and
  replays the toggle cascade with trip. Wire/fixtures untouched (the
  seed change is server-side).

- **feat(protocol,store): lockstep convergence with the main repo's
  node-fields / class-convert / alias-validation / asset-type batches
  (fixture-gated).** Ports the four protocol+store slices the monorepo
  shipped today; the fixture corpus gains three files (24 total, all
  sha256-identical to `packages/protocol/fixtures/`).
  **Wire node fields:** `object.update` gains the optional nullable
  `coverAssetId` / `bannerAssetId` / `aliasedNodeId` (presence writes,
  present-null clears — the `_undefined` sentinel builder pattern, the
  icon/color precedent); `object.create` still carries none (the strict
  validator rejects the keys there). The local DB schema bumps to **v27**:
  `node_cache` gains `cover_asset_id` / `banner_asset_id` /
  `aliased_node_id` (guarded idempotent migration; the Node payload is the
  read authority, the columns are the SQL projections — snapshots at store
  schema v16+ map them, older snapshots read null). **Title applier:** the
  `object.update` content path no longer flattens rich content to
  text-only for main-presenting nodes — only class rows flatten on update
  now (create-as-main and the promotion stringify keep the lossy
  boundaries); a page title may carry inline rich tokens, display-name
  derivation still flattens for labels. **class-convert:** `class.create`
  on an EXISTING node now DECLARES it a class — the node row flips
  `is_class`, a parented node is cut to a root (parent + fractional
  position drop), the render bit clears, the registry adopts the node's
  title, and absent icon/color/name PRESERVE on re-declaration (the upsert
  used to wipe them with null); the registry never writes `description` on
  create (TS parity — the payload key is accepted, the applier drops it;
  storing it would break wipe→replay convergence); every declaration lands
  the `class_hierarchy` self-row. **Alias write-time validation (M12):**
  `object.update {aliasedNodeId}` walks the would-be chain — a revisit
  (self-alias included) throws `CycleError` and the write is never
  applied; clearing (null) skips the check; a stale-HLC write drops by the
  row LWW before any check. The read helper `resolveAlias` walks a chain
  to its terminal — cycle-safe (a revisit yields the starting id unchanged)
  with a 32-link depth cap. **The `asset` property type (M38):** the
  `propertySchema.create` type enum gains `"asset"` — a node-typed value
  (`{nodeId}`) whose target must carry the asset class, the filter
  implicit in the type (explicit filters ignored); node-typed defaults stay
  unsupported. **Seeds:** the seeded `class` meta class (…0001) retires —
  the local seed no longer emits it (the UUID is withdrawn, never reused);
  `weblink` (…0034) joins the seeded source family with its
  `mdiLinkVariant` icon and the `weblink extends source` edge. The alias
  read-path repointing (redirect, roll-up) and the M38 UI are the main
  repo's recorded follow-ons — same here. **Verification:** the fixture
  gate lists the three new files; `fixture_replay_test` gains the
  wire-fields set/clear + LWW/absence block, the class-convert
  parentless/parented/re-declaration block, the asset-type rows +
  implicit-filter value-validation block, and the six alias-cycle blocks;
  `operation_payloads_test` pins the strict field semantics; the seed
  parity + local-mode suites track the retirement and weblink; the full
  gate green — `flutter analyze` clean, `flutter test`: **598 tests, all
  passed**.
- **chore(docs): the development skill's version-range keep-list tracks the
  v27 schema bump.** Law 5's live-identifier parenthetical moves to
  "local DB schema versions v16–v27".

## 2026-10-06

- **chore(sync): re-vendored the wire fixture corpus from the main repo
  (lockstep convergence).** `test/fixtures/wire/` is byte-identical (sha256)
  to the monorepo's `packages/protocol/fixtures/` again — 21 files, zero
  mismatches / zero extras / zero missing in the pairwise sweep. Adds
  `object-restore.json` (object.create → object.delete → object.restore,
  picked up by the all-fixtures replay and the fixtures gate list) and
  updates `class-property-defaults.json` (a ninth envelope appends an
  unrelated number-format `propertySchema.create`; the first eight are
  unchanged, so the prefix-replay acceptance only had to re-track the
  envelope count — the same slicing the TS reference store tests use).
  Wire models and appliers already carried `object.restore`,
  `class.property.unset`, and the number-format schema fields, so no
  implementation change was needed — the corpus was the only lag.
- **chore(docs): record-keeping aligned with the main repo — plan-era
  citations scrubbed, AGENTS.md aligned, per-client skill pair added.** Same
  treatment the main Notees monorepo gave itself on this date: every §-citation
  token removed from code comments, test titles, and docs (sentence kept, e.g.
  "(owner review 2026-10-05): …"; "WIRE.md §2" → "WIRE.md"); all
  `implementation-plan` / "main repo's plan" references deleted or made
  self-contained; narrative v1/v2 history reworded minimally ("the v2 store"
  → "the TS store", "legacy v1 ops" → "legacy ops", stale `v2/packages/…`
  layout qualifiers dropped to the current monorepo paths); the 18 milestone
  markers (M1–M3 prose labels) removed. Deliberate keeps: the vendored fixture
  corpus stays byte-pinned (fixture comment strings are part of the
  sha256-pinned convergence corpus — untouched, as in the monorepo), live
  version identifiers (`protocol v2`, envelope v3, `/api/relay/v2`, WS framing
  v2, `v2.0.0-mN`-style version tags, local DB schema versions v16–v26, the
  fixture corpus paths, code symbols like `SyncV2Service`), and the
  AGENTS.md release-pipeline docs (v*-tag → versionCode/APK mechanics).
  Comments/docs/test-titles only — no logic, symbol, or assertion changes.
- **chore(repo): legacy "v2" labels out of the fixture corpus — `test/fixtures/v2`
  → `test/fixtures/wire`, `v2_fixtures_test.dart` → `fixtures_test.dart`,
  `v2_fixture_replay_test.dart` → `fixture_replay_test.dart`; the three
  completed plan docs deleted.** Fixture JSON bytes untouched (sha256-verified
  before/after; the corpus stays pinned to the monorepo's
  `packages/protocol/fixtures/`). No test-side symbols carried the label (no
  `V2Fixtures`-style identifiers existed) so no symbol renames; protocol-version
  logic (`protocolVersion` checks, relay protocol v2 semantics) deliberately
  untouched. Every path reference updated (the seven fixture-loading test
  files, the development skill + workflow reference, AGENTS.md records table).
  `git rm docs/plan.md docs/plan-product-alignment.md docs/plan-sync-relay.md` —
  the AGENTS.md docs listing now keeps only `flutter-audit.md` and
  `gap-analysis-web-vs-mobile.md`.
- **chore(docs): AGENTS.md becomes static guidance with a records index.**
  Added the "Records" section (the changelog-is-the-record law + records
  table), the "Project skills" tree, and made the Server Reference
  host-agnostic ("a sibling clone of git@github.com:miquelrosell99/notees.git,
  kept up to date" — no hardcoded sibling path).
- **chore(docs): per-client skill pair created under `.agents/skills/`.**
  `notees-flutter-development` (lockstep law, fixture byte-pin, the
  build/test gate, changelog law, no-legacy-version-names rule; detail in
  `references/development-workflow.md`) and `notees-flutter-operations`
  (v*-tag → release.yml → GitHub Release APK pipeline, versionCode
  derivation, CI artifacts vs release APKs, the never-re-tag law; detail in
  `references/releases.md`).
- **chore(docs): `CHANGELOG.md` created** as this repo's shipped-work record,
  mirroring the main-repo format.
