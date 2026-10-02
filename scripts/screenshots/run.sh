#!/usr/bin/env bash
# Capture per-screen Notees screenshots by driving the real app with seeded
# local data (see integration_test/screenshots_test.dart).
#
# Usage:
#   ./scripts/screenshots/run.sh              # first connected device
#   DEVICE_ID=emulator-5554 ./scripts/screenshots/run.sh
set -euo pipefail
cd "$(dirname "$0")/../.."

OUT_DIR="docs/img/screenshots"
mkdir -p "$OUT_DIR"

if ! command -v flutter >/dev/null 2>&1; then
  echo "flutter not found on PATH. Export the Flutter SDK bin dir first," >&2
  echo "e.g. export PATH=/path/to/flutter-sdk/bin:\$PATH" >&2
  exit 1
fi

flutter pub get

DEVICE_ID="${DEVICE_ID:-}"
if [ -z "$DEVICE_ID" ]; then
  # Prefer a real mobile device/emulator (screenshots need one); otherwise
  # fall back to the headless tester, which only verifies the flow.
  DEVICE_ID="$(flutter devices --machine 2>/dev/null | python3 -c '
import json, sys
try:
    devices = json.load(sys.stdin)
except Exception:
    sys.exit(0)
for d in devices:
    if d.get("platformType") in ("android", "ios"):
        print(d.get("id") or "")
        break
' || true)"
fi

if [ -n "$DEVICE_ID" ]; then
  echo "Running on device: $DEVICE_ID"
  flutter test integration_test/screenshots_test.dart -d "$DEVICE_ID"
else
  echo "No Android/iOS device or emulator found."
  echo "Falling back to the headless tester: the navigation flow runs but"
  echo "no PNGs are produced (takeScreenshot needs a mobile target)."
  flutter test integration_test/screenshots_test.dart -d flutter-tester
fi

# Collect whatever screenshots the runner produced (location varies by
# platform and flutter tool version).
collected=0
for dir in screenshots build/screenshots; do
  if [ -d "$dir" ]; then
    if cp "$dir"/*.png "$OUT_DIR"/ 2>/dev/null; then
      collected=1
    fi
  fi
done

echo
if [ "$collected" -eq 1 ]; then
  echo "Screenshots landed in $OUT_DIR — eyeball the PNGs."
else
  echo "No PNG files were collected into $OUT_DIR."
  echo "- On the host tester / a desktop target, takeScreenshot is unsupported"
  echo "  and the run only verifies the navigation flow."
  echo "- Run against an Android emulator or iOS device to produce images."
fi
