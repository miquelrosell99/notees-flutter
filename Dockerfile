FROM eclipse-temurin:17-jdk-jammy AS builder

ENV ANDROID_HOME=/opt/android-sdk
ENV ANDROID_SDK_ROOT=${ANDROID_HOME}
ENV PATH="${ANDROID_HOME}/cmdline-tools/latest/bin:${ANDROID_HOME}/platform-tools:${PATH}"

# Install dependencies
RUN apt-get update && apt-get install -y --no-install-recommends \
    unzip wget && \
    rm -rf /var/lib/apt/lists/*

# Download Android command-line tools
RUN mkdir -p "${ANDROID_HOME}/cmdline-tools" && \
    wget -q "https://dl.google.com/android/repository/commandlinetools-linux-11076708_latest.zip" -O /tmp/cmdline-tools.zip && \
    unzip -q /tmp/cmdline-tools.zip -d "${ANDROID_HOME}/cmdline-tools" && \
    mv "${ANDROID_HOME}/cmdline-tools/cmdline-tools" "${ANDROID_HOME}/cmdline-tools/latest" && \
    rm /tmp/cmdline-tools.zip

# Accept licenses and install SDK components
RUN yes | sdkmanager --licenses > /dev/null 2>&1 && \
    sdkmanager "platforms;android-35" "build-tools;35.0.0" "platform-tools"

# Copy project
WORKDIR /app
COPY . .

# Generate local.properties
RUN echo "sdk.dir=${ANDROID_HOME}" > local.properties

# Generate Gradle wrapper
RUN gradle wrapper --gradle-version 8.11.1 2>/dev/null || true

# Build the APK
RUN chmod +x gradlew && ./gradlew assembleDebug --no-daemon

# Output stage — tiny image with just the APK
FROM scratch AS output
COPY --from=builder /app/app/build/outputs/apk/debug/app-debug.apk /notees.apk
