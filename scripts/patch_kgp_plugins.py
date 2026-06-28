#!/usr/bin/env python3
"""Patch Flutter plugins in the pub cache to stop applying the Kotlin Gradle Plugin.

This is a temporary workaround until the listed plugins migrate to AGP 9+
built-in Kotlin support. Running this script after `flutter pub get` removes the
`apply plugin: 'kotlin-android'` (and equivalent) declarations from plugin
Android build files so the Flutter Gradle Plugin no longer reports them as
KGP-applying plugins.

The patches are idempotent: running the script multiple times is safe.
"""

from __future__ import annotations

import os
import re
import sys
from pathlib import Path

# Plugins known to still apply KGP in their published versions.
# Map package name -> regex matching the version directory in the pub cache.
#
# share_plus, package_info_plus, and record_android were upgraded to KGP-free
# major versions (13.2.0, 10.2.0, and 2.1.2 respectively). They are kept in the
# list as a safety net so the script remains idempotent if the constraints are
# ever rolled back.
PATCH_PATTERNS = {
    "share_plus": r"^share_plus-",
    "package_info_plus": r"^package_info_plus-",
    "record_android": r"^record_android-",
    "dynamic_color": r"^dynamic_color-",
    "cryptography_flutter": r"^cryptography_flutter-",
    "workmanager_android": r"^workmanager_android-",
}


def find_pub_cache() -> Path:
    """Locate the Dart pub cache directory."""
    if "PUB_CACHE" in os.environ:
        return Path(os.environ["PUB_CACHE"])
    home = Path.home()
    candidates = [
        home / ".pub-cache",
        home / "AppData" / "Local" / "Pub" / "Cache",
    ]
    for candidate in candidates:
        if candidate.exists():
            return candidate
    raise FileNotFoundError("Could not locate pub cache")


def patch_build_gradle(build_file: Path) -> bool:
    """Patch a single plugin build.gradle to remove KGP application.

    Returns True if the file was modified.
    """
    original = build_file.read_text(encoding="utf-8")
    text = original

    # Idempotency marker.
    marker = "// patched_for_built_in_kotlin"
    if marker in text:
        return False

    # Remove `apply plugin: 'kotlin-android'` and variants.
    text = re.sub(
        r"apply plugin:\s*['\"](kotlin-android|org\.jetbrains\.kotlin\.android)['\"]\n?",
        "",
        text,
    )

    # Remove KGP classpath dependency from buildscript (quoted or parenthesized).
    text = re.sub(
        r"classpath\s*\(?['\"]org\.jetbrains\.kotlin:kotlin-gradle-plugin:[^'\"]+['\"]\)?\s*\n?",
        "",
        text,
    )

    # Mark as patched.
    if text != original:
        text = text.rstrip() + f"\n{marker}\n"
        build_file.write_text(text, encoding="utf-8")
        return True
    return False


def patch_plugins(pub_cache: Path) -> list[Path]:
    """Patch all matching plugin build.gradle files in the pub cache."""
    hosted = pub_cache / "hosted" / "pub.dev"
    if not hosted.exists():
        raise FileNotFoundError(f"Pub cache hosted directory not found: {hosted}")

    patched: list[Path] = []
    for package_dir in hosted.iterdir():
        if not package_dir.is_dir():
            continue
        name = package_dir.name
        if not any(re.search(pattern, name) for pattern in PATCH_PATTERNS.values()):
            continue

        build_file = package_dir / "android" / "build.gradle"
        if build_file.exists():
            try:
                if patch_build_gradle(build_file):
                    patched.append(build_file)
            except Exception as exc:  # pragma: no cover
                print(f"Failed to patch {build_file}: {exc}", file=sys.stderr)

    return patched


def main() -> int:
    pub_cache = find_pub_cache()
    print(f"Using pub cache: {pub_cache}")
    patched = patch_plugins(pub_cache)
    if patched:
        print(f"Patched {len(patched)} plugin build file(s):")
        for path in patched:
            print(f"  - {path}")
    else:
        print("No plugin build files needed patching.")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
