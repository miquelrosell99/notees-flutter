# Flutter build environment for Notees Android.
# This image is used by build-apk.sh; it is not the production runtime image.
FROM ghcr.io/cirruslabs/flutter:stable

WORKDIR /project

# Accept build arguments.
ARG BUILD_TYPE=apk
ARG BUILD_FLAVOR=release

# Cache dependencies before copying the full source.
COPY pubspec.yaml pubspec.lock ./
RUN flutter pub get

# Copy the rest of the source.
COPY . .

# Build the Android artifact.
RUN flutter build $BUILD_TYPE --$BUILD_FLAVOR

# The caller should extract artifacts from /project/build/app/outputs.
