# Notees Mobile

A first-class Flutter companion app for [Notees](https://github.com/notees/notees) — your self-hosted notes, journals, and tasks.

## Features

- **Self-hosted first**: connect to any Notees server you control.
- **Biometric lock**: protect the app with fingerprint/face unlock.
- **Quick capture**: jot down notes or receive shared text from other apps.
- **Offline queue**: save quick notes locally and sync when connectivity returns.
- **Native editor**: edit pages with a native block-based editor. Inline styles (bold, italic, strikethrough, code, highlight), node/class/tag links via a bottom-sheet picker, and a read-only properties panel are supported.
- **View modes**: browse nodes as a list, cards, or table. Toggle from Search and Pages; the choice is persisted locally.
- **Bottom navigation**: Home, Tasks, Pages, and Search tabs.
- **Advanced search**: plain text search plus an Immich-style bottom-sheet filter for node type, task state, date range, and sort order.
- **Reusable node picker**: the same search UI is available as a bottom sheet for inserting links and selecting pages anywhere in the app.

## Build

Install the Flutter SDK and Android toolchain, then run the native Flutter
commands:

```bash
flutter pub get
python3 scripts/patch_kgp_plugins.py
python3 scripts/patch_mdi_icons.py
flutter build apk --release
```

The APK is written to `build/app/outputs/flutter-apk/app-release.apk`.

### Pub-cache patches

A few published Flutter plugins still apply the legacy Kotlin Gradle Plugin
(KGP), which causes Flutter to emit a migration warning during Android builds.
`scripts/patch_kgp_plugins.py` removes `apply plugin: 'kotlin-android'` from the
remaining plugin build files in the pub cache. It is idempotent and only touches
the pub cache.

`material_design_icons_flutter` also needs a small patch because `IconData` is
`final` in recent Flutter versions. Run `scripts/patch_mdi_icons.py` after every
`flutter pub get`.

`share_plus`, `package_info_plus`, and `record` were upgraded to KGP-free major
versions, so they no longer need patching. Remove the KGP workaround once
`cryptography_flutter`, `dynamic_color`, and `workmanager_android` also ship
built-in Kotlin releases.

## Protocol lockstep

This app parses the Notees envelope-v3 operation log at the **3.0.0** protocol
level: the Revision-11 render-state model (`is_class` + `present_as_main`), the
§34.54 batch (`workspace.feature.set` for the five class-family toggles, the
`code_block` and `hr` content tokens, `embed_ref.view`), the §34.57
property-wire batch (per-element property value ids, `class_property.active`,
date-node-backed qualifiers), the §34.79 number formats (pad / decimals /
rounding), and the §34.89 property-display batch — `class.property.set` gains
the optional `display` position (`panel` | `bullet` | `inline`, strict,
row-LWW patch, no null-clear; stored NULL = the `panel` default) and select
options gain the optional `icon` (MDI name, ≤ 64 chars, on a deliberately
non-strict option record so icon-carrying options sync through older parsers).
The app DB carries the batch as **v25** (`class_property.display`). The
block-bullet value button renders a bound select / multi_select / boolean
value next to the bullet (or before the content, per the winning binding's
display position) as its option's MDI icon tinted with the §34.43 color —
unset reads as a dimmed hollow circle — and opens the bottom-sheet picker to
author `property.set` / `property.unset` through the sync service; it is the
first lockstep-batch surface this app writes (the rest parse and replay).
Per the three-client lockstep law, pre-§34.89-released peers reject the
`display` envelope outright — do not flip display settings or run the
task-status restyle against a workspace older clients sync with. Releases use
plain `vX.Y.Z` tags; the pubspec version tracks the same X.Y.Z (build number
`X·1000000 + Y·10000 + Z·100`).

## Advanced search & node picker

The Search tab supports plain text search and advanced filters via a slide-up bottom sheet. Filters include node type, task state, date range, and sort order. The Flutter client calls the structured endpoint `POST /nodes/search`, which returns the same `SearchResponse` shape as the plain GET search.

The same UI powers `NodePicker`, a reusable bottom sheet for selecting a node anywhere in the app.

## Development

Run in debug mode:

```bash
flutter run
```

Lint and analyze:

```bash
flutter analyze
```
