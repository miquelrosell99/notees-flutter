# AGENTS.md — Notees Mobile

This file contains project-specific context for the first-class Flutter mobile app in `mobile/`.

## Overview

The mobile app is a **first-class native Flutter app** for Notees. It provides native Android and iOS experiences for the workflows users do most often on phones.

- **Package**: `com.notees.notees` (Android)
- **Display name**: `Notees`
- **Functional accent**: sage green `#5B7D5B`
- **Architecture**: feature-first Flutter with Provider + ChangeNotifier, Dio, go_router, sqflite
- **Native features**: biometric app lock, offline quick-capture queue, share receiver, native block editor with inline styles and node/class/tag links, native list/card/table views, bottom navigation, advanced search filters, reusable node picker, native settings with server and account management

## Key Files

```
mobile/
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
├── build-apk.sh             # Docker-based APK build
├── Dockerfile               # Flutter build image
└── AGENTS.md                # This file
```

## Build

**Prefer CI builds.** The Docker-based local build (`./build-apk.sh`) downloads the Flutter image, the Android SDK/NDK, and compiles Gradle on every run, which is heavy for an i3/16 GB server that runs other apps. Use GitHub Actions instead:

```bash
# Trigger a release APK build and print the run URL
cd mobile
./trigger-ci-build.sh
```

Then grab the artifact from the printed workflow run.

For local emergencies only:

```bash
cd mobile
./build-apk.sh
```

This outputs `dist/notees.apk`.

## Local development with Docker Compose

A `compose.yaml` is provided for lightweight local Flutter checks without installing the Flutter SDK. It uses the same `ghcr.io/cirruslabs/flutter:stable` image as CI and persists `pub-cache` and Gradle caches in Docker volumes.

```bash
cd mobile

# Run static analysis (fast; catches compile errors before a full build)
docker compose run --rm flutter flutter analyze

# Run tests
docker compose run --rm flutter flutter test

# Build a release APK
docker compose run --rm build-apk
```

The Android workflow runs `flutter analyze` first so compile errors fail fast instead of after a full Gradle build.

## Avoiding CI failures

Run the local analyze command before every push that touches `mobile/`:

```bash
cd mobile
docker compose run --rm flutter flutter analyze
```

Common issues that break the Android build:

- **Map literal types**: deduplicating lists into a map must use `<int, Node>{...}`, not `<Node>{...}`. The latter creates a `Set<Node>` and `.values` is undefined.
- **Parameter shadowing**: don't name a parameter the same as a static helper. For example, `String text` shadows `AstBuilder.text()`, causing `The method 'call' isn't defined for the type 'String'`.
- **Async `BuildContext` use**: capture `context.read<...>()` before the first `await`, or guard post-async context use with `if (mounted)`.
- **Unused private members**: the analyzer treats unused private methods/fields as warnings, and the workflow fails on them.
- **Map null entries**: the Dart version in the pinned Flutter image does not accept `'key': value?` collection elements. Keep using `if (value != null) 'key': value` (with an optional `// ignore: use_null_aware_elements`).

For major refactors, also run the full APK build locally before pushing:

```bash
cd mobile
docker compose run --rm build-apk
```

## Design System

- Monochrome base layer dominates 90%+ of the UI.
- Functional accent (sage `#5B7D5B`) is used only for selected states, badges, primary buttons, and status indicators.
- Cards use `borderRadius: 20`, zero elevation, subtle outline at 10% opacity.
- Bottom sheets use top radius of 28.
- Dynamic color is supported via `dynamic_color` and can be enabled in Settings.

## Security Notes

- Server credentials and tokens are stored in `flutter_secure_storage`.
- Biometric lock is enabled in Settings and gates app resume.

## Skill References

- `rosellramos-app-creator` — scaffold and fleet design system
- `flutter-ui-patterns` — cards, lists, empty states, bottom sheets
- `flutter-play-store-release` — signing, AAB, Play Console
- `security-hardening` — token storage, HTTPS, input validation
- `accessibility-primer` — touch targets, focus, labels
