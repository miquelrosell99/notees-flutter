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

# Download Gradle wrapper JAR and script
RUN mkdir -p gradle/wrapper && \
    wget -q "https://raw.githubusercontent.com/gradle/gradle/v8.11.1/gradlew" -O gradlew && \
    wget -q "https://raw.githubusercontent.com/gradle/gradle/v8.11.1/gradlew.bat" -O gradlew.bat && \
    wget -q "https://services.gradle.org/distributions/gradle-8.11.1-bin.zip" -O /tmp/gradle-bin.zip && \
    echo "distributionBase=GRADLE_USER_HOME\ndistributionPath=wrapper/dists\ndistributionUrl=file\\:///tmp/gradle-bin.zip\nzipStoreBase=GRADLE_USER_HOME\nzipStorePath=wrapper/dists" > gradle/wrapper/gradle-wrapper.properties && \
    wget -q "https://raw.githubusercontent.com/gradle/gradle/v8.11.1/gradle/wrapper/gradle-wrapper.jar" -O gradle/wrapper/gradle-wrapper.jar && \
    chmod +x gradlew

# Build the APK
RUN ./gradlew assembleDebug --no-daemon

# Output stage — tiny image with just the APK
FROM scratch AS output
COPY --from=builder /app/app/build/outputs/apk/debug/app-debug.apk /notees.apk
