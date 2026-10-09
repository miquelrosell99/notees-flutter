# Releases & packaging — notees-flutter

## Workflows

- `.github/workflows/android.yml` — "Android CI". Triggers: push/PR to
  `main`, manual `workflow_dispatch`, and `workflow_call` (from release.yml).
  Inputs for dispatch: `build-mode` (release|debug|profile), `git-ref`
  (default `main`), `sign-release`. Builds an unsigned release APK, signs it
  with `apksigner` when `sign-release` (production keystore from secrets),
  uploads the APK as the `notees-android-apk` artifact. CI artifact name:
  `notees-android-ci-<sha>.apk` (debug-signed, pubspec `1.0.0+1`).
- `.github/workflows/release.yml` — "Android Tag Release". Trigger: push of a
  `v*` tag. Calls android.yml with `build-mode: release, sign-release: true`,
  then downloads the artifact and runs `gh release create` with the APK and a
  `sha256sum`-generated `.sha256` file. `permissions: contents: write`.

## Linux desktop package (pacman)

- `packaging/arch/PKGBUILD` is the canonical pacman source for the Linux
  GTK client. It pins the release-tag tarball (`pkgver` + `sha256sums`)
  and builds a `notees-<ver>-1-x86_64.pkg.tar.zst` (bundle in `/opt/notees`,
  `notees` on PATH, `.desktop` + icon; runtime `depends` derived from the
  bundle's `DT_NEEDED`).
- Built and installed **locally** — never CI (no runner has the Flutter
  Linux toolchain) and not submitted to AUR:
  `cd packaging/arch && makepkg -s && sudo pacman -U notees-<ver>-1-x86_64.pkg.tar.zst`
- The build needs a locally installed Flutter SDK (`~/flutter`; override
  with `FLUTTER_ROOT`) — Arch has no `flutter` package.
- Release flow: the tag tarball only exists once the tag is pushed, so the
  `pkgver` + `sha256sums` bump lands in a follow-up commit right after the
  tag push (part of cutting a release).

## Tag → version mapping (android.yml build step)

```
v2.0.0-m11 → versionName 2.0.0-m11, versionCode 2000011   # (2*10000+0*100+0)*100 + 11
v1.2.3     → versionName 1.2.3,     versionCode 1020300   # (1*10000+2*100+3)*100
non-tag    → pubspec version (1.0.0+1)
```

The regexes in android.yml are the normative derivation; keep the AGENTS.md
"Build" section and this file in sync if they change.

## Rules

- Release APKs build in CI only. Do not run `flutter build apk --release`
  locally for distribution; use `flutter build apk --debug` for local
  installs. (The Linux pacman package is the one thing that builds
  locally — from `packaging/arch/`, never CI.)
- Never re-tag. A tag is immutable version identity; cut the next number.
- Always commit + push before expecting something in a CI APK.
- `./trigger-ci-build.sh` — manual workflow dispatch + run URL (needs `gh`).
- Per-screen screenshot review harness: `./scripts/screenshots/run.sh`
  (PNG output needs a device/emulator; on the headless tester the flow still
  runs).

## What this repo does NOT do

- No Google Play / AAB pipeline, no AUR submission, no docker image, no
  server deployment. The pacman package builds locally from
  `packaging/arch/PKGBUILD` (see above). The Notees server the app talks
  to is deployed from the main monorepo (docker compose stack; see the
  monorepo's `notees-operations` skill and `docs/developers/releases.md`
  there).
