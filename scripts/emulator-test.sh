#!/bin/bash
set -e
export ANDROID_SDK_ROOT=/opt/android-sdk-linux
export PATH=$ANDROID_SDK_ROOT/cmdline-tools/latest/bin:$ANDROID_SDK_ROOT/platform-tools:$ANDROID_SDK_ROOT/emulator:$PATH

# Accept licenses
yes | sdkmanager --licenses >/dev/null 2>&1 || true

# Download system image
sdkmanager "system-images;android-30;google_apis;x86_64"

# Create AVD
echo no | avdmanager create avd -n notees-test -k "system-images;android-30;google_apis;x86_64" -d pixel || true

# Start emulator headless
emulator -avd notees-test -no-window -no-audio -no-boot-anim -gpu swiftshader_indirect -netdelay none -netspeed full &
EMULATOR_PID=$!

# Wait for device
adb wait-for-device
adb shell 'while [[ -z $(getprop sys.boot_completed) ]]; do sleep 1; done'
echo "Emulator booted"

# Install APK
adb install -r /project/dist/notees.apk

# Clear logs and launch app
adb logcat -c
adb shell am start -n com.notees.notees/.MainActivity

# Capture logs for 30 seconds
sleep 30
adb logcat -d > /project/dist/logcat.txt
echo "Logs saved to /project/dist/logcat.txt"

# Stop emulator
kill $EMULATOR_PID || true
