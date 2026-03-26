#!/bin/bash
set -e

cd "$(dirname "$0")"

echo "Building Notees APK in Docker..."
docker build --output=. --target=output -t notees-apk-builder .

if [ -f notees.apk ]; then
    echo ""
    echo "Build complete: notees.apk ($(du -h notees.apk | cut -f1))"
else
    echo "Build failed — APK not found."
    exit 1
fi
