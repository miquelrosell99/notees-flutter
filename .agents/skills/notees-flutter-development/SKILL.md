---
name: notees-flutter-development
description: Develop the Notees Flutter mobile client — a lockstep client of the Notees op-log protocol (envelope v3, relay protocol v2). Use when writing or changing code, wire models, appliers, fixtures, sync, or UI in the notees-flutter repo; when touching test/fixtures/wire; or when porting a monorepo protocol/store change to Dart.
---

# notees-flutter-development

First-class Flutter (Android/iOS) client of the Notees object graph. The
monorepo (TypeScript) is the source of truth; this app adapts to it — never
the other way around. AGENTS.md at the repo root is the canonical orientation
(overview, layout, build, CI pitfalls); this skill enforces the laws.

## Laws

1. **The fixture corpus is byte-pinned.** `test/fixtures/wire/` is byte-identical
   (sha256) to the main repo's `packages/protocol/fixtures/` — the shared
   convergence corpus for the TS reference, the GTK client, and this app.
   NEVER edit fixture bytes, names, or counts. If the protocol changes, the
   fixtures change in the monorepo first and are copied here verbatim.
2. **The lockstep law.** A wire/applier/model change is not done until all
   three implementations (TS reference, GTK, Flutter) converge on the same
   envelopes and derived state. Land parsers before authoring where the batch
   is gated; replay fixtures through the appliers
   (`test/fixture_replay_test.dart`, `test/fixtures_test.dart`,
   `test/content_lockstep_test.dart`) to prove convergence.
3. **The gate is green or the change is not done.** Before claiming anything:
   `flutter pub get && python3 scripts/patch_kgp_plugins.py && python3 scripts/patch_mdi_icons.py && flutter analyze && flutter test`.
   The two patches are mandatory after every `pub get` (they patch the pub
   cache; see AGENTS.md "Avoiding CI failures").
4. **The changelog is the record.** One entry per shipped slice in
   `CHANGELOG.md` (repo root), newest first. Docs/comment updates ride in the
   same change; a change without its changelog entry is not done.
5. **No legacy version names.** No §-citation tokens, no milestone markers
   (M1–M5), no narrative v1/v2 qualifiers ("the v2 store", "v1 behavior") in
   comments, docs, or test titles. Version numbers that ARE the protocol stay
   (`protocol v2`, envelope v3, `/api/relay/v2`, `v2.0.0-m11`-style tags,
   local DB schema versions v16–v27, `test/fixtures/wire/` paths).
6. **Comments/docs only for record-keeping changes.** Never rename symbols,
   files, or test structure to satisfy the record rules; reword the prose.

## Orientation

- `lib/domain/models/relay/` — wire models (envelope, payloads, HLC, LWW),
  all strict ports of `packages/protocol/src/*`.
- `lib/domain/services/relay_appliers.dart` + `sync_v2_service.dart` — the
  derived-state appliers and the sync engine (outbox, catch-up, WS realtime).
- `lib/data/repositories/node_cache_repository.dart` — the derived SQLite
  projection (schema in `lib/data/local/app_database.dart`, versioned v16+).
- `lib/core/utils/ast_builder.dart` / `ast_stringifier.dart` — the flat
  content-grammar port (`content-mark.ts`), including legacy nested-AST
  conversion.
- Reference the monorepo through a sibling clone kept up to date
  (`git@github.com:miquelrosell99/notees.git`) — never hardcode host paths.

Longer workflow detail (fixture sync procedure, adding an op type, the
analyze pitfalls that break CI): `references/development-workflow.md`.
