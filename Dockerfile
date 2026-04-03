FROM eclipse-temurin:17-jdk-jammy AS builder

ENV ANDROID_HOME=/opt/android-sdk
ENV ANDROID_SDK_ROOT=${ANDROID_HOME}
ENV PATH="${ANDROID_HOME}/cmdline-tools/latest/bin:${ANDROID_HOME}/platform-tools:${PATH}"

# Install dependencies
RUN apt-get update && apt-get install -y --no-install-recommends \
    unzip wget && \
    rm -rf /var/lib/apt/lists/*

# Download Android command-line tools (with checksum verification)
# SHA-256 from https://developer.android.com/studio#command-line-tools-only
RUN mkdir -p "${ANDROID_HOME}/cmdline-tools" && \
    wget -q "https://dl.google.com/android/repository/commandlinetools-linux-11076708_latest.zip" -O /tmp/cmdline-tools.zip && \
    echo "2d2d50857e4eb553af5a6dc3ad507a17adf43d115264b1afc116f95c92e5e258  /tmp/cmdline-tools.zip" | sha256sum -c - && \
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

# Gradle 8.11.1 — SHA-256 from https://gradle.org/release-checksums/
ENV GRADLE_VERSION=8.11.1
ENV GRADLE_SHA256=f397b287023acdba1e9f6fc5ea72d22dd63a5f2aff054879e1e68712f7db0b22

RUN mkdir -p gradle/wrapper && \
    wget -q "https://raw.githubusercontent.com/gradle/gradle/v${GRADLE_VERSION}/gradlew" -O gradlew && \
    wget -q "https://services.gradle.org/distributions/gradle-${GRADLE_VERSION}-bin.zip" -O /tmp/gradle-bin.zip && \
    echo "${GRADLE_SHA256}  /tmp/gradle-bin.zip" | sha256sum -c - && \
    echo "distributionBase=GRADLE_USER_HOME\ndistributionPath=wrapper/dists\ndistributionUrl=file\\:///tmp/gradle-bin.zip\nzipStoreBase=GRADLE_USER_HOME\nzipStorePath=wrapper/dists" > gradle/wrapper/gradle-wrapper.properties && \
    wget -q "https://raw.githubusercontent.com/gradle/gradle/v${GRADLE_VERSION}/gradle/wrapper/gradle-wrapper.jar" -O gradle/wrapper/gradle-wrapper.jar && \
    chmod +x gradlew

# Build the APK
RUN ./gradlew assembleDebug --no-daemon

# Output stage — tiny image with just the APK
FROM scratch AS output
COPY --from=builder /app/app/build/outputs/apk/debug/app-debug.apk /notees.apk
