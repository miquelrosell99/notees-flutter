---
name: notees-flutter-operations
description: Release and package the Notees Flutter mobile client — the v*-tag → GitHub Release APK pipeline, versionCode derivation, CI artifacts vs release APKs, the in-repo Arch PKGBUILD for the Linux desktop client, and the never-re-tag law. Use when cutting a release, tagging, debugging the Android CI, packaging the Linux client for pacman, or deciding how the app reaches a device on the fleet.
---

# notees-flutter-operations

Release/packaging truth for THIS repo only. The server side (the
`notees-sync` + `notees-web` docker stack) is operated from the main Notees
monorepo — see its `notees-operations` skill; nothing server-side lives here.

## Release mechanism: git tags → GitHub Releases

- Pushing a `v*` tag runs `.github/workflows/release.yml`, which reuses
  `.github/workflows/android.yml` to build a **production-signed release APK**
  and publishes a GitHub Release for the tag with the APK and its SHA-256
  checksum attached. **This is the only APK to install on a real device.**
- **Release APK builds run in GitHub Actions only.** Never build a release APK
  locally; never commit the keystore. Signing uses the
  `ANDROID_KEYSTORE_BASE64` / keystore-password secrets in the repo's GitHub
  configuration.
- Version derivation happens at build time from the tag:
  - `vX.Y.Z-mN` → versionName `X.Y.Z-mN`, versionCode `(X·10000 + Y·100 + Z)·100 + N`
  - plain `vX.Y.Z` → versionName `X.Y.Z`, versionCode `(X·10000 + Y·100 + Z)·100`
  - non-tag builds keep the pubspec version (`1.0.0+1`).
  Every tag is therefore a distinct in-place upgrade, and any `-mN` tag orders
  above its plain base.

## CI artifacts ≠ release APKs

- Every push/PR to `main` builds a **CI artifact** in `android.yml`:
  `notees-android-ci-<sha>.apk`, debug-signed, pubspec `1.0.0+1`. For trying
  out `main` or a PR on an emulator/clean install only.
- A CI artifact can never update over a release install (signature and
  versionCode differ by design).
- The workflow checks out the git ref, so **committed and pushed snapshots
  only** — uncommitted local changes never reach CI. Manual run:
  `./trigger-ci-build.sh` (needs the `gh` CLI), then download the artifact
  from the printed run URL.

## The never-re-tag law

Never move, delete, or reuse a tag that already exists: the tag is the
version identity on every installed device, and a re-used tag produces a
different APK under the same versionName (broken upgrades, mismatched
checksums). Bump to a new tag instead.

## Linux desktop (pacman)

- `packaging/arch/PKGBUILD` is the canonical pacman source for the Linux
  GTK client; it pins the release-tag tarball (`pkgver` + `sha256sums`).
- Built and installed locally (`makepkg -s`, then `sudo pacman -U`) with a
  local Flutter SDK (`~/flutter`, `FLUTTER_ROOT` override) — never CI, not
  on AUR.
- Per release: after the `v*` tag is pushed, bump `pkgver` and the tarball
  sha256 in a follow-up commit. Detail: `references/releases.md`.

## How the fleet consumes it

The app reaches a device by installing the release APK from the repo's
GitHub Releases page against a running Notees server (the fleet's
`notees-sync` relay at its configured URL). A Linux desktop installs the
client from the in-repo PKGBUILD instead (see "Linux desktop (pacman)"
above). There is no store listing and no hosted backend in this repo.

Detail (workflow inputs, manual dispatch, screenshot harness):
`references/releases.md`.
