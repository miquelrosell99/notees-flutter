# Changelog

The record of shipped work for the Notees Flutter mobile client. One entry
per shipped slice, newest first. This file — not `AGENTS.md`, not `docs/` —
is where history goes; those stay static guidance. Before implementing a
change, skim this file for recent related work. Anything before 2026-10-06
lives in git history.

## 2026-10-08

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
