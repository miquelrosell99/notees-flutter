# AGENTS.md — Notees Mobile

This file contains project-specific context for the Android Kotlin wrapper app in `mobile/`.

## Overview

The mobile app is a **minimal Android WebView wrapper** around the Notees React frontend. It does not bundle the web app; it connects to a user-provided self-hosted Notees server.

- **minSdk**: 26 (Android 8.0)
- **targetSdk / compileSdk**: 36
- **Language**: Kotlin
- **Build tool**: Gradle (wrapped)
- **Containerized build**: `mobile/build-apk.sh` uses Docker; no local Android SDK required.

## Project Structure

```
mobile/
├── app/
│   ├── build.gradle.kts          # App module config
│   ├── proguard-rules.pro        # ProGuard rules for release
│   └── src/main/
│       ├── AndroidManifest.xml
│       ├── java/com/notees/app/
│       │   ├── SetupActivity.kt      # Server URL entry screen
│       │   ├── MainActivity.kt       # WebView wrapper
│       │   ├── ShareActivity.kt      # Transparent share receiver
│       │   ├── BiometricHelper.kt    # Fingerprint / face unlock
│       │   ├── AndroidBridge.kt      # JS ↔ native bridge
│       │   ├── ServerPreferences.kt  # Encrypted URL storage
│       │   └── NoteesWidget.kt       # Home-screen widget provider
│       └── res/                    # Layouts, themes, icons, menus
├── build-apk.sh                  # Docker-based debug APK build
├── Dockerfile                    # Multi-stage Docker build for APK
├── build.gradle.kts              # Root Gradle config
└── settings.gradle.kts
```

## Key Behaviors

- **First launch**: `SetupActivity` prompts for the server URL.
- **URL storage**: Saved encrypted via `EncryptedSharedPreferences`.
- **Subsequent launches**: `SetupActivity` detects the saved URL and forwards to `MainActivity`.
- **WebView**: Loads the user’s Notees server; login page (or app if cookies persist) is shown.
- **Back navigation**: Android back button navigates web history; exits when history is empty.
- **Share receiver**: Other apps can send text to `ShareActivity`, which forwards it into Notees as a quick note.
- **Deep links**: `notees://note/…` opens directly in the WebView.
- **Biometric lock**: Optional fingerprint / face unlock via `BiometricHelper`.
- **Cookie persistence**: Sessions survive app restarts.
- **Offline awareness**: Native network listener injects connectivity events into the web app.

## Build Commands

```bash
# Easiest path: Docker-based build
cd mobile
./build-apk.sh

# Manual debug build (requires JDK 17 + Android SDK 35)
cd mobile
./gradlew assembleDebug

# Release build (requires a signing keystore; see mobile/README.md)
./gradlew assembleRelease
```

## Security Notes

- Cleartext HTTP is allowed for local network servers via `network_security_config.xml`. Always use HTTPS for production.
- Server URLs are encrypted at rest with `EncryptedSharedPreferences`.
- The debug keystore in the repo is intentional and not a secret.

## Skill References

- `selfhost-release` — Docker-based builds, env files, deployment workflow.
- `security-hardening` — Secure storage, HTTPS, native bridge input validation.
- `accessibility-primer` — Touch targets, focus, motion, screen reader labels for native Android UI.

## Full Documentation

See `mobile/README.md` for detailed build instructions, release signing setup, and icon customization.
