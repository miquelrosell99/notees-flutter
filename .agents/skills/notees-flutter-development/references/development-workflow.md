# Development workflow — notees-flutter

## The gate (run before every push)

```bash
flutter pub get
python3 scripts/patch_kgp_plugins.py   # mandatory after every pub get
python3 scripts/patch_mdi_icons.py     # mandatory after every pub get
flutter analyze
flutter test
```

CI runs the same analyze/test steps (`.github/workflows/android.yml`), so a
green local gate means a green CI build. `flutter test` needs no device; the
sqflite tests run on `sqflite_common_ffi`.

## Fixture sync procedure (protocol change lands in the monorepo first)

1. The monorepo authors/updates fixtures under `packages/protocol/fixtures/`
   and its own gate goes green.
2. Copy the changed files into `test/fixtures/wire/` **verbatim** — byte-for-
   byte, including the `comment` fields (they carry §-era history; that is
   fine, the corpus is pinned). Do not hand-edit, reformat, or "fix" a
   fixture; if it looks wrong, the monorepo is wrong.
3. Verify identity: `sha256sum` each file against the monorepo copy.
4. Wire new fixtures into the replay suites (`fixtures_test.dart`,
   `fixture_replay_test.dart`, `content_lockstep_test.dart`, and the
   per-batch acceptance tests) so the Flutter appliers prove convergence with
   the TS reference and the GTK client.
5. Gate green + `CHANGELOG.md` entry.

## Adding / changing an op type

- Port the payload shape to `lib/domain/models/relay/operation_payloads.dart`
  (factories + strict validators, zod `.strict()` parity).
- Port the apply semantics to `relay_appliers.dart` (fail loud with typed
  `StoreError`s; never swallow a write).
- Extend the local schema in `app_database.dart` if derived rows change
  (bump `_schemaVersion`, add an idempotent migration, keep vN comments).
- Add the op to the known-registry test surface and replay the fixture.
- The change is NOT done until the monorepo and GTK implementations converge
  on the same fixture outcomes.

## Analyze pitfalls that break CI (from AGENTS.md, kept current)

- Map literal types: dedupe with `<int, Node>{...}`, not `<Node>{...}`.
- Parameter shadowing: a parameter named like a static helper shadows it.
- Async `BuildContext`: capture `context.read<>()` before the first `await`
  or guard with `if (mounted)`.
- Unused private members are analyzer warnings — CI fails on them.
- Null-aware collection elements are required style: `[?value]`,
  `'key': ?value` (CI's Flutter treats `use_null_aware_elements` infos as
  failures).
- The pub-cache patches are load-bearing: KGP-legacy plugins
  (`cryptography_flutter`, `dynamic_color`, `workmanager_android`,
  `home_widget`) and the MDI icon tree-shaking patch. Re-run both after every
  `flutter pub get`.

## Record-keeping rules

- `CHANGELOG.md` at the repo root is the shipped-work record: newest first,
  one entry per slice. AGENTS.md and `docs/` stay static — never append
  work-log entries to them.
- The `docs/plan*.md` and `docs/*audit*.md` files are historical
  plan/audit documents, kept for context; the changelog supersedes them as
  the record of what actually shipped.
- Keep all host references fleet-agnostic: "a sibling clone of
  `git@github.com:miquelrosell99/notees.git`", never machine-specific paths.
