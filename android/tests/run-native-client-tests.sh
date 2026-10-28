#!/bin/sh
set -eu
project_root="$(cd "$(dirname "$0")/../.." && pwd)"
java_home="${JAVA_HOME:-$project_root/.tools/jdk/Contents/Home}"
sdk_home="${ANDROID_HOME:-${ANDROID_SDK_ROOT:-$project_root/.tools/android-sdk}}"
missing=0
for tool in keytool javac java; do
  if [ ! -x "$java_home/bin/$tool" ]; then
    printf 'Missing JDK tool: %s/bin/%s. Set JAVA_HOME to JDK 17 or run python3 scripts/bootstrap-android.py.\n' "$java_home" "$tool" >&2
    missing=1
  fi
done
if [ ! -f "$sdk_home/platforms/android-35/android.jar" ]; then
  printf 'Missing Android API 35: %s/platforms/android-35/android.jar. Set ANDROID_HOME or run python3 scripts/bootstrap-android.py.\n' "$sdk_home" >&2
  missing=1
fi
if [ "$missing" -ne 0 ]; then exit 1; fi
work_dir="$(mktemp -d "${TMPDIR:-/tmp}/boox-native-tests.XXXXXX")"
trap 'rm -rf "$work_dir"' EXIT
make_fixture() {
  if ! "$java_home/bin/keytool" "$@" >"$work_dir/keytool.log" 2>&1; then
    cat "$work_dir/keytool.log" >&2
    exit 1
  fi
}
make_fixture -genkeypair -alias test -keyalg RSA -keysize 2048 -storetype PKCS12 \
  -keystore "$work_dir/valid.p12" -storepass testpass -keypass testpass -dname CN=test.invalid -validity 2
make_fixture -genkeypair -alias test -keyalg RSA -keysize 2048 -storetype PKCS12 \
  -keystore "$work_dir/expired.p12" -storepass testpass -keypass testpass -dname CN=test.invalid \
  -startdate '2000/01/01 00:00:00' -validity 1
"$java_home/bin/javac" -cp "$sdk_home/platforms/android-35/android.jar" -d "$work_dir/classes" \
  "$project_root/android/app/src/main/java/local/boox/sidecar/PinnedClient.java" \
  "$project_root/android/app/src/main/java/local/boox/sidecar/CaptureSessionState.java" \
  "$project_root/android/app/src/main/java/local/boox/sidecar/AutoRoutePolicy.java" \
  "$project_root/android/tests/NativeClientTest.java"
"$java_home/bin/java" -cp "$work_dir/classes:$sdk_home/platforms/android-35/android.jar" \
  local.boox.sidecar.NativeClientTest "$work_dir/valid.p12" "$work_dir/expired.p12"
