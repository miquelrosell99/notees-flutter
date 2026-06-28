# Flutter build environment for Notees Android.
# This image is used by build-apk.sh for local debugging; it is not the
# production runtime image and CI no longer uses it (see
# .github/workflows/android.yml).
FROM ghcr.io/cirruslabs/flutter:stable

WORKDIR /project

# Accept build arguments.
ARG BUILD_TYPE=apk
ARG BUILD_FLAVOR=release

# Cache dependencies before copying the full source.
COPY pubspec.yaml pubspec.lock ./
RUN flutter pub get

# Patch plugins that still apply the Kotlin Gradle Plugin so the Flutter
# Gradle Plugin stops emitting built-in Kotlin migration warnings.
# This is a temporary workaround until upstream plugins migrate.
COPY scripts/patch_kgp_plugins.py ./scripts/patch_kgp_plugins.py
RUN python3 ./scripts/patch_kgp_plugins.py

# Copy the rest of the source.
COPY . .

# Build the Android artifact. Release builds are unsigned by default; sign
# them separately with apksigner if you need a signed APK.
RUN flutter build $BUILD_TYPE --$BUILD_FLAVOR

# The caller should extract artifacts from /project/build/app/outputs.
