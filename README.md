# Notees Android App

A lightweight Android wrapper that connects to your self-hosted Notees server. On first launch, you enter your server URL — from there, the login screen and full interface are displayed natively in the app.

## Features

- **Server URL setup** — enter your Notees instance URL on first launch
- **Full WebView experience** — login, navigate, edit notes, manage assets
- **File uploads** — attach images and files from your phone
- **Swipe to refresh** — pull down to reload
- **Back navigation** — Android back button navigates web history
- **Cookie persistence** — stay logged in across sessions
- **Dark mode** — follows system theme automatically
- **Change server** — disconnect and connect to a different instance via the toolbar menu

## Prerequisites

- **Android Studio** — [Download here](https://developer.android.com/studio) (Ladybug or newer recommended)
- **JDK 17** — bundled with Android Studio
- **Android SDK 35** — install via Android Studio SDK Manager

## Build Instructions

### 1. Open in Android Studio

```
File → Open → select the mobile/ directory
```

Android Studio will automatically download Gradle, sync dependencies, and configure the project.

### 2. Generate the Gradle Wrapper

If the `gradlew` script is missing (it's not checked into version control), Android Studio generates it automatically on first sync. Or run:

```bash
gradle wrapper --gradle-version 8.11.1
```

### 3. Build Debug APK

**From Android Studio:**
- Click **Build → Build Bundle(s) / APK(s) → Build APK(s)**
- The APK will be at `app/build/outputs/apk/debug/app-debug.apk`

**From command line:**
```bash
cd mobile
./gradlew assembleDebug
```

### 4. Install on Device

**Via USB:**
```bash
adb install app/build/outputs/apk/debug/app-debug.apk
```

**Via file transfer:**
- Copy the APK to your phone
- Open it to install (enable "Install from unknown sources" if prompted)

### 5. Build Release APK (for distribution)

First, create a signing keystore:

```bash
keytool -genkey -v -keystore notees-release.keystore \
  -alias notees -keyalg RSA -keysize 2048 -validity 10000
```

Then create `mobile/keystore.properties` (do NOT commit this file):

```properties
storeFile=../notees-release.keystore
storePassword=your_store_password
keyAlias=notees
keyPassword=your_key_password
```

Add to `app/build.gradle.kts` inside the `android` block:

```kotlin
signingConfigs {
    create("release") {
        val props = java.util.Properties()
        props.load(file("../keystore.properties").inputStream())
        storeFile = file(props["storeFile"] as String)
        storePassword = props["storePassword"] as String
        keyAlias = props["keyAlias"] as String
        keyPassword = props["keyPassword"] as String
    }
}

buildTypes {
    release {
        signingConfig = signingConfigs.getByName("release")
        // ... existing config
    }
}
```

Then build:

```bash
./gradlew assembleRelease
```

The signed APK will be at `app/build/outputs/apk/release/app-release.apk`.

## Project Structure

```
mobile/
├── build.gradle.kts              # Root Gradle config
├── settings.gradle.kts           # Project settings
├── gradle.properties             # Gradle JVM settings
├── gradle/wrapper/               # Gradle wrapper config
├── app/
│   ├── build.gradle.kts          # App module config
│   ├── proguard-rules.pro        # ProGuard rules for release
│   └── src/main/
│       ├── AndroidManifest.xml   # App manifest
│       ├── java/com/notees/app/
│       │   ├── SetupActivity.kt  # Server URL entry screen
│       │   ├── MainActivity.kt   # WebView wrapper
│       │   └── ServerPreferences.kt  # Encrypted URL storage
│       └── res/
│           ├── layout/           # XML layouts
│           ├── menu/             # Toolbar menu
│           ├── values/           # Strings, colors, themes (light)
│           ├── values-night/     # Dark theme overrides
│           ├── drawable/         # Vector icons
│           ├── mipmap-anydpi-v26/# Adaptive app icon
│           └── xml/              # Network security config
```

## How It Works

1. **First Launch** → `SetupActivity` shows a clean setup screen where you enter your server URL
2. **URL is saved** → stored encrypted on-device via Android's `EncryptedSharedPreferences`
3. **Subsequent launches** → `SetupActivity` detects the saved URL and immediately opens `MainActivity`
4. **MainActivity** → full-screen `WebView` loads your Notees server, showing the login page (or the app if session cookies are still valid)
5. **Change server** → toolbar menu → "Change server" → clears cookies and saved URL, returns to setup

## Notes

- **HTTP support**: The app allows cleartext HTTP for local network servers (e.g., `http://192.168.1.100:8000`). For production, always use HTTPS.
- **SharedArrayBuffer**: Android WebView supports `SharedArrayBuffer` when the server sends proper COOP/COEP headers (which Notees already does via `vite.config.ts`). The sql.js WASM features should work correctly.
- **Minimum Android version**: 8.0 (API 26), covering 95%+ of active devices.
- **App size**: The APK will be very small (~2-3 MB) since it doesn't bundle the web frontend.

## Customizing the App Icon

The current icon is a vector drawable. To use a custom icon:

1. In Android Studio: **Right-click `res`** → **New** → **Image Asset**
2. Select your source image (use the existing `app/static/icons/icon-512.svg` from the Notees project)
3. It will generate all required mipmap sizes automatically
