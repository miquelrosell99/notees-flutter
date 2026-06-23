# AGENTS.md — Notees Mobile

This file contains project-specific context for the first-class Flutter mobile app in `mobile/`.

## Overview

The mobile app is a **first-class native Flutter app** for Notees. It provides native Android and iOS experiences for the workflows users do most often on phones.

- **Package**: `com.notees.notees` (Android)
- **Display name**: `Notees`
- **Functional accent**: sage green `#5B7D5B`
- **Architecture**: feature-first Flutter with Provider + ChangeNotifier, Dio, go_router, sqflite
- **Native features**: biometric app lock, offline quick-capture queue, share receiver, native editor, bottom navigation, advanced search filters, reusable node picker, native settings with server and account management

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
