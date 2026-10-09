# AGENTS.md — Notees Mobile

This file contains project-specific context for the first-class Flutter mobile app in this repository.

## Overview

The mobile app is a **first-class native Flutter app** for Notees. It provides native Android and iOS experiences for the workflows users do most often on phones.

**The web app is the source of truth.** Always prefer the web app's API contracts, configuration, and design over anything in this mobile app. This app adapts to the web — never the other way around. When the two disagree, match the web.

- **Package**: `com.notees.notees` (Android)
- **Display name**: `Notees`
- **Functional accent**: Advance Green `#2E5E46` (Margin Green brand identity)
- **Architecture**: feature-first Flutter with Provider + ChangeNotifier, Dio, go_router, sqflite
- **Native features**: biometric app lock, offline quick-capture queue, share receiver, native block editor with inline styles and node/class/tag links, native list/card/table views, bottom navigation, advanced search filters, reusable node picker, native settings with server and account management, local task due-date reminders with snooze actions and boot reschedule, Android home-screen widgets (today's tasks, favorites, Inbox preview)

## Key Files

```
notees-flutter/
├── lib/
│   ├── main.dart
│   ├── app.dart
│   ├── core/
│   │   ├── api/              # Dio client + auth interceptor
│   │   ├── routing/          # go_router deep-link config
│   │   ├── secure/           # flutter_secure_storage wrapper
│   │   └── theme/            # RosellRamos theme + accent picker
│   ├── data/
│   │   ├── models/           # ServerProfile, User, Node
│   │   ├── repositories/     # Auth, Server, Workspace, Node
│   │   └── local/            # sqflite database
│   ├── domain/
│   │   ├── models/           # Relay op-log models (HLC, envelopes, payloads)
│   │   └── services/         # Sync engine, offline queue, quick capture
│   ├── shared/
│   │   ├── widgets/          # Cross-feature widgets (FleetCard, EmptyState, SectionTitle, NodePicker, ViewModeSheet, etc.)
│   │   └── views/            # Cross-feature node collection views (list/card/table/kanban/calendar, inbox)
│   ├── features/
│   │   ├── auth/             # screens/ (Splash, ServerSetup, Login, Onboarding, ServerManagement, WorkspaceManagement, Lock, ApiKeys, UserProfile), providers/ (Auth, Biometric)
│   │   ├── home/             # screens/ (Home, MainShell, Notifications), providers/ (Connectivity)
│   │   ├── editor/           # screens/ (NodeEditor, JournalContinuous), widgets/ (BlockTreeEditor, AstRichText, SlashCommandPalette, etc.)
│   │   ├── tasks/            # screens/ (Tasks), widgets/ (TaskRow, TaskCreationSheet)
│   │   ├── search/           # screens/ (Search), widgets/ (CommandPalette, FilterBottomSheet, FilterChipBar)
│   │   ├── library/          # screens/ (Library, Archived, Trash), widgets/ (BrowsePanel)
│   │   ├── settings/         # screens/ (Settings, About, KeyboardShortcuts), providers/ (Settings)
│   │   ├── capture/          # widgets/ (QuickCaptureSheet, FloatingCaptureSheet/Bubble, AudioRecorderSheet)
│   │   └── shares/           # widgets/ (SharesBottomSheet)
│   └── native/               # Platform-specific native helpers (reminder_service, intent_receiver, background_sync, app_locker, widget_service)
   └── android/.../TaskWidgetProvider.kt  # Today's tasks home-screen widget
   └── android/.../FavoritesWidgetProvider.kt  # Favorite pages home-screen widget
   └── android/.../PageWidgetProvider.kt   # Inbox preview home-screen widget
├── android/                  # Android platform project
├── ios/                      # iOS platform project
├── packaging/                # Release packaging (arch/ = the Linux pacman PKGBUILD)
├── .github/workflows/        # Android CI
├── scripts/                  # Build helpers (KGP + MDI icon patches) + screenshots harness (scripts/screenshots)
└── AGENTS.md                # This file
```

## Build

**Release APK builds must run in GitHub Actions only.** Do not build release APKs locally.

Two kinds of APK come out of CI — never confuse them:

- **Release APKs** (`.github/workflows/release.yml`, runs on `v*` tags): production-signed, versioned from the tag (see below), published as a GitHub Release. **This is the only APK to install on a real device.**
- **CI artifacts** (`.github/workflows/android.yml`, runs on every push/PR to `main`): a testing build named `notees-android-ci-<sha>.apk`, debug-signed, pubspec version `1.0.0+1` — for trying out main or a PR on an emulator or clean install. It can never update over a release (signature and versionCode differ by design).

The Android CI workflow builds, signs, and uploads the APK on every push to
`main` or pull request targeting `main`.

CI uses directly-installed tooling (`actions/setup-java`, `subosito/flutter-action`, `android-actions/setup-android`) with cached `~/.pub-cache` and Gradle homes, following the same pattern as Logseq's Android workflow. It builds an unsigned release APK and then signs it with `apksigner` using the production keystore.

Pushing to `main` automatically triggers the Android Build workflow, so a manual trigger is usually unnecessary.

To request a CI build manually (optional):

```bash
# Trigger a workflow dispatch and print the run URL
./trigger-ci-build.sh
```

Then download the artifact from the printed workflow run.

**Always commit and push snapshots before expecting them in a CI APK.** The workflow checks out `main` (or the configured git ref), so uncommitted local changes are not included in the build.

**Tag releases**: pushing a `v*` tag (e.g. `v1.2.3`) runs
`.github/workflows/release.yml`, which reuses `android.yml` to build a
production-signed release APK and publishes a GitHub Release for the tag with
the APK and its SHA-256 checksum attached. The app version is derived from the
tag at build time (`v2.0.0-m11` → versionName `2.0.0-m11`, versionCode
`2000011`; plain `vX.Y.Z` → versionCode `(X·10000 + Y·100 + Z)·100`), so every
release is a distinct in-place upgrade and any tag orders above its plain
base. Non-tag builds keep the pubspec version — never reuse a tag that
already exists.

## Local development

Install the Flutter SDK and Android toolchain, then use the native Flutter
commands. The CI workflow runs `flutter analyze` first so compile errors fail
fast instead of after a full Gradle build.

```bash
# Install dependencies and apply pub-cache patches
flutter pub get
python3 scripts/patch_kgp_plugins.py
python3 scripts/patch_mdi_icons.py

# Run static analysis (fast; catches compile errors before a full build)
flutter analyze

# Run tests
flutter test

# Capture per-screen screenshots for visual review (PNG output needs an
# Android/iOS device or emulator; on the headless tester the flow still runs)
./scripts/screenshots/run.sh

# Build a debug APK for local install
flutter build apk --debug
```

## Avoiding CI failures

Run the local analyze and test commands before every push:

```bash
flutter analyze
flutter test
```

The Android workflow runs two pub-cache patches after `flutter pub get`:

- `scripts/patch_kgp_plugins.py` removes legacy Kotlin Gradle Plugin application
  from plugins that have not yet migrated to AGP 9+ built-in Kotlin
  (`cryptography_flutter`, `dynamic_color`, `workmanager_android`, `home_widget`).
- `scripts/patch_mdi_icons.py` removes `class _MdiIconData extends IconData`
  from `material_design_icons_flutter` (because `IconData` is `final` in recent
  Flutter versions) and inlines each map entry as a **const** `IconData(...)`
  instance so release-build icon tree-shaking keeps working — non-const
  `IconData` invocations fail the release build with "Avoid non-constant
  invocations of IconData". The patch is idempotent and only touches the pub
  cache.

`share_plus`, `package_info_plus`, and `record` were upgraded to KGP-free major
versions instead. Remove the KGP workaround once the remaining plugins ship
built-in Kotlin releases.

Common issues that break the Android build:

- **Map literal types**: deduplicating lists into a map must use `<int, Node>{...}`, not `<Node>{...}`. The latter creates a `Set<Node>` and `.values` is undefined.
- **Parameter shadowing**: don't name a parameter the same as a static helper. For example, `String text` shadows `AstBuilder.text()`, causing `The method 'call' isn't defined for the type 'String'`.
- **Async `BuildContext` use**: capture `context.read<...>()` before the first `await`, or guard post-async context use with `if (mounted)`.
- **Unused private members**: the analyzer treats unused private methods/fields as warnings, and the workflow fails on them.
- **Map null entries**: CI's current Flutter (stable 3.47+) supports and *requires* null-aware collection elements: `flutter analyze` fails on `use_null_aware_elements` infos, so write `[?value]` / `'key': ?value` instead of `if (value != null)` guards in collection literals.

For major refactors, trigger a CI build via `./trigger-ci-build.sh` rather than running the full APK build locally. Use `docker compose run --rm build-apk` only when debugging a CI-specific build failure.

## Design System

- Monochrome base layer dominates 90%+ of the UI.
- Accent is monochrome white by default; Advance Green `#2E5E46`, paper `#F7F4EC`, and dynamic color are opt-in alternatives (Settings → Appearance). The accent is used only for selected states, badges, primary buttons, and status indicators.
- Cards use `borderRadius: 20`, zero elevation, subtle outline at 10% opacity.
- Bottom sheets use top radius of 28.
- Dynamic color is supported via `dynamic_color` and can be enabled in Settings.

## Security Notes

- Server credentials and tokens are stored in `flutter_secure_storage`.
- Biometric lock is enabled in Settings and gates app resume.

## Server Reference

The backend/server source for Notees is kept in a sibling clone of
`git@github.com:miquelrosell99/notees.git`, kept up to date, for reference
while building the mobile app:

Keep the clone current when the mobile app needs to align with API contracts,
data models, auth flows, or deployment conventions from the server
repository.

## Records

- **The changelog is the record**: what shipped and why lives in
  `CHANGELOG.md` at the repo root — one entry per shipped slice, newest
  first. This file and `docs/` stay static guidance/history; never append
  work-log entries to them. A change without its changelog entry is not done.
- In-flight proposals and parked decisions live in the main Notees monorepo
  (`.plans/YYYY-MM-DD-HHMM-<slug>/` and `.agents/parked-decisions.md` there).

| Record | Home |
|--------|------|
| Shipped work | `CHANGELOG.md` (newest first, one entry per slice) |
| Historical plans & audits | `docs/` (`flutter-audit.md`, `gap-analysis-web-vs-mobile.md`) |

## Project skills

```
AGENTS.md
    │
    ├── notees-flutter-development   (project skill — .agents/skills/notees-flutter-development/)
    │      └── development workflow  → references/development-workflow.md
    └── notees-flutter-operations    (project skill — .agents/skills/notees-flutter-operations/)
           └── releases & packaging → references/releases.md
```

Kimi Code auto-discovers these from `.agents/skills/` (Project scope); invoke
the matching skill first for any code change (`notees-flutter-development`)
or release/CI question (`notees-flutter-operations`).

## Skill References

- `flutter-app-development` — scaffold and fleet design system, UI patterns (cards, lists, empty states, bottom sheets), audit checklists, signing, AAB, Play Console
- `security-hardening` — token storage, HTTPS, input validation
- `accessibility-primer` — touch targets, focus, labels
