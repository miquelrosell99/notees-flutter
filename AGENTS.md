# AGENTS.md — Notees Mobile

This file contains project-specific context for the first-class Flutter mobile app in this repository.

## Overview

The mobile app is a **first-class native Flutter app** for Notees. It provides native Android and iOS experiences for the workflows users do most often on phones.

- **Package**: `com.notees.notees` (Android)
- **Display name**: `Notees`
- **Functional accent**: sage green `#5B7D5B`
- **Architecture**: feature-first Flutter with Provider + ChangeNotifier, Dio, go_router, sqflite
- **Native features**: biometric app lock, offline quick-capture queue, share receiver, native block editor with inline styles and node/class/tag links, native list/card/table views, bottom navigation, advanced search filters, reusable node picker, native settings with server and account management

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
│   │   └── repositories/     # Auth, Server, Workspace, Node
│   ├── presentation/
│   │   ├── providers/        # AuthProvider
│   │   ├── screens/          # Splash, ServerSetup, Login, Dashboard, Settings, ServerManagement, UserProfile, ApiKeys, etc.
│   │   └── widgets/          # Fleet-styled cards, section titles
│   └── native/               # Platform-specific native helpers
├── android/                  # Android platform project
├── ios/                      # iOS platform project
├── .github/workflows/        # Android CI
├── scripts/                  # Build helpers (KGP + MDI icon patches)
└── AGENTS.md                # This file
```

## Build

**Release APK builds must run in GitHub Actions only.** Do not build release APKs locally. The Android workflow (`.github/workflows/android.yml`) builds, signs, and uploads the APK on every push or pull request.

CI uses directly-installed tooling (`actions/setup-java`, `subosito/flutter-action`, `android-actions/setup-android`) with cached `~/.pub-cache` and Gradle homes, following the same pattern as Logseq's Android workflow. It builds an unsigned release APK and then signs it with `apksigner` using the production keystore.

To request a CI build manually:

```bash
# Trigger a workflow dispatch and print the run URL
./trigger-ci-build.sh
```

Then download the artifact from the printed workflow run.

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
  (`cryptography_flutter`, `dynamic_color`, `workmanager_android`).
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
- **Map null entries**: the Dart version in the pinned Flutter image does not accept `'key': value?` collection elements. Keep using `if (value != null) 'key': value` (with an optional `// ignore: use_null_aware_elements`).

For major refactors, trigger a CI build via `./trigger-ci-build.sh` rather than running the full APK build locally. Use `docker compose run --rm build-apk` only when debugging a CI-specific build failure.

## Design System

- Monochrome base layer dominates 90%+ of the UI.
- Accent is monochrome white by default; sage green `#5B7D5B`, muted orange `#B0763D`, and dynamic color are opt-in alternatives (Settings → Appearance). The accent is used only for selected states, badges, primary buttons, and status indicators.
- Cards use `borderRadius: 20`, zero elevation, subtle outline at 10% opacity.
- Bottom sheets use top radius of 28.
- Dynamic color is supported via `dynamic_color` and can be enabled in Settings.

## Security Notes

- Server credentials and tokens are stored in `flutter_secure_storage`.
- Biometric lock is enabled in Settings and gates app resume.

## Server Reference

The backend/server source for Notees is kept in a sibling folder for reference while building the mobile app:

```
../notees/   # git@github.com:miquelrosell99/notees.git
```

Keep this clone up to date when the mobile app needs to align with API contracts, data models, auth flows, or deployment conventions from the server repository.

## Skill References

- `rosellramos-app-creator` — scaffold and fleet design system
- `flutter-ui-patterns` — cards, lists, empty states, bottom sheets
- `flutter-play-store-release` — signing, AAB, Play Console
- `security-hardening` — token storage, HTTPS, input validation
- `accessibility-primer` — touch targets, focus, labels
