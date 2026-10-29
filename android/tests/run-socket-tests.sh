#!/bin/sh
set -eu
root="$(cd "$(dirname "$0")/../.." && pwd)"
java_home="${JAVA_HOME:-$root/.tools/jdk/Contents/Home}"
sdk_home="${ANDROID_HOME:-${ANDROID_SDK_ROOT:-$root/.tools/android-sdk}}"
work="$(mktemp -d "${TMPDIR:-/tmp}/boox-socket-tests.XXXXXX")"
trap 'rm -rf "$work"' EXIT
fixture() {
    if ! "$java_home/bin/keytool" "$@" >"$work/keytool.log" 2>&1; then cat "$work/keytool.log" >&2; exit 1; fi
}
for name in valid expired replaced; do
    if [ "$name" = expired ]; then start='2000/01/01 00:00:00'; else start=-1d; fi
    fixture -genkeypair -alias test -keyalg RSA -keysize 2048 -storetype PKCS12 \
        -keystore "$work/$name.p12" -storepass testpass -keypass testpass \
        -dname CN=test.invalid -startdate "$start" -validity 3
done
cp "$work/valid.p12" "$work/renewed.p12"
fixture -selfcert -alias test -keystore "$work/renewed.p12" -storepass testpass \
    -keypass testpass -startdate -1d -validity 30
"$java_home/bin/javac" -cp "$sdk_home/platforms/android-35/android.jar" -d "$work/classes" \
    "$root/android/app/src/main/java/local/boox/sidecar/PinnedClient.java" \
    "$root/android/app/src/main/java/local/boox/sidecar/CaptureSessionState.java" \
    "$root/android/tests/NativeSocketTest.java"
"$java_home/bin/java" -cp "$work/classes:$sdk_home/platforms/android-35/android.jar" \
    local.boox.sidecar.NativeSocketTest "$work/valid.p12" "$work/expired.p12" "$work/renewed.p12" "$work/replaced.p12"
