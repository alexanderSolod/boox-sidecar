#!/bin/sh
set -eu
project_root="$(cd "$(dirname "$0")/../.." && pwd)"
java_home="${JAVA_HOME:-$project_root/.tools/jdk/Contents/Home}"
sdk_home="${ANDROID_HOME:-$project_root/.tools/android-sdk}"
work_dir="$(mktemp -d "${TMPDIR:-/tmp}/boox-native-tests.XXXXXX")"
trap 'rm -rf "$work_dir"' EXIT
"$java_home/bin/keytool" -genkeypair -alias test -keyalg RSA -keysize 2048 -storetype PKCS12 \
  -keystore "$work_dir/valid.p12" -storepass testpass -keypass testpass -dname CN=test.invalid -validity 2 >/dev/null 2>&1
"$java_home/bin/keytool" -genkeypair -alias test -keyalg RSA -keysize 2048 -storetype PKCS12 \
  -keystore "$work_dir/expired.p12" -storepass testpass -keypass testpass -dname CN=test.invalid \
  -startdate '2000/01/01 00:00:00' -validity 1 >/dev/null 2>&1
"$java_home/bin/javac" -cp "$sdk_home/platforms/android-35/android.jar" -d "$work_dir/classes" \
  "$project_root/android/app/src/main/java/local/boox/sidecar/PinnedClient.java" \
  "$project_root/android/app/src/main/java/local/boox/sidecar/AutoRoutePolicy.java" \
  "$project_root/android/tests/NativeClientTest.java"
"$java_home/bin/java" -cp "$work_dir/classes:$sdk_home/platforms/android-35/android.jar" \
  local.boox.sidecar.NativeClientTest "$work_dir/valid.p12" "$work_dir/expired.p12"
