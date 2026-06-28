#!/usr/bin/env bash
set -euo pipefail

# Build a release APK for the Notees Flutter app inside Docker.
# The APK is signed with the debug keystore so it can be installed locally.
# Outputs: dist/notees.apk

cd "$(dirname "$0")"

BUILD_TYPE="${1:-apk}"
BUILD_MODE="${2:-release}"
CLEAN_FLAG="${3:-}"

DIST_DIR="$(pwd)/dist"
mkdir -p "$DIST_DIR"

if [[ "$CLEAN_FLAG" == "--clean" ]]; then
  docker build --build-arg BUILD_TYPE="$BUILD_TYPE" --build-arg BUILD_FLAVOR="$BUILD_MODE" --no-cache -t notees-mobile-build .
else
  docker build --build-arg BUILD_TYPE="$BUILD_TYPE" --build-arg BUILD_FLAVOR="$BUILD_MODE" -t notees-mobile-build .
fi

# Extract the built artifact.
CONTAINER=$(docker create notees-mobile-build)

if [[ "$BUILD_TYPE" == "apk" ]]; then
  docker cp "$CONTAINER:/project/build/app/outputs/flutter-apk/app-$BUILD_MODE.apk" "$DIST_DIR/notees.apk"
  echo "APK copied to $DIST_DIR/notees.apk"
elif [[ "$BUILD_TYPE" == "appbundle" ]]; then
  docker cp "$CONTAINER:/project/build/app/outputs/bundle/${BUILD_MODE}Release/app-$BUILD_MODE-release.aab" "$DIST_DIR/notees.aab" || \
  docker cp "$CONTAINER:/project/build/app/outputs/bundle/${BUILD_MODE}/app.aab" "$DIST_DIR/notees.aab"
  echo "AAB copied to $DIST_DIR/notees.aab"
fi

docker rm "$CONTAINER" >/dev/null

# Sign APK builds with the debug keystore so the package installer accepts them.
if [[ "$BUILD_TYPE" == "apk" ]]; then
  echo "Signing APK with debug keystore..."
  docker run --rm -v "$(pwd):/project" -w /project notees-mobile-build bash -c '
    apksigner=$(find /opt/android-sdk-linux/build-tools -name apksigner | sort -V | tail -1)
    "$apksigner" sign \
      --ks android/app/debug.keystore \
      --ks-pass pass:android \
      --key-pass pass:android \
      --ks-key-alias androiddebugkey \
      --in dist/notees.apk \
      --out dist/notees-signed.apk
    mv dist/notees-signed.apk dist/notees.apk
  '
  echo "APK signed: $DIST_DIR/notees.apk"
fi
