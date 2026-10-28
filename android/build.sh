#!/bin/sh
set -eu

cd "$(dirname "$0")"
project_root="$(cd .. && pwd)"
if [ -d "$project_root/.tools/jdk/Contents/Home" ]; then
    JAVA_HOME="$project_root/.tools/jdk/Contents/Home"
    export JAVA_HOME
    PATH="$JAVA_HOME/bin:$PATH"
fi
if [ -d "$project_root/.tools/gradle-8.9/bin" ]; then
    PATH="$project_root/.tools/gradle-8.9/bin:$PATH"
fi
if [ -d "$project_root/.tools/android-sdk" ]; then
    ANDROID_HOME="$project_root/.tools/android-sdk"
    export ANDROID_HOME
fi
export PATH
GRADLE_USER_HOME="${GRADLE_USER_HOME:-$project_root/.tools/gradle-cache}"
export GRADLE_USER_HOME
missing=0
if ! java -version >/dev/null 2>&1; then
    printf '%s\n' 'Missing Java runtime. Configure JDK 17 (JAVA_HOME/PATH) before building.' >&2
    missing=1
fi
if ! command -v gradle >/dev/null 2>&1; then
    printf '%s\n' 'Missing Gradle. Put Gradle 8.9 on PATH or build this directory in Android Studio.' >&2
    missing=1
fi
sdk_dir="${ANDROID_HOME:-${ANDROID_SDK_ROOT:-$HOME/Library/Android/sdk}}"
if [ ! -f local.properties ] && [ ! -d "$sdk_dir/platforms/android-35" ]; then
    printf '%s\n' 'Missing Android SDK Platform 35. Configure Android Studio/ANDROID_HOME or local.properties.' >&2
    missing=1
fi
if [ "$missing" -ne 0 ]; then
    exit 1
fi
exec gradle --no-daemon :app:assembleDebug "$@"
