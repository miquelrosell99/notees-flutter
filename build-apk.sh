#!/usr/bin/env bash
set -euo pipefail

# Build a release APK for the Notees Flutter app inside Docker.
# Release builds are unsigned by default; sign them separately with apksigner.
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
