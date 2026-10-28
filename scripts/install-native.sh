#!/bin/bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
APK="$ROOT/android/app/build/outputs/apk/debug/app-debug.apk"
ADB="${BOOX_ADB:-adb}"
TARGET=(-d)
if [[ $# -gt 1 ]]; then echo 'Usage: scripts/install-native.sh [device-serial]' >&2; exit 2; fi
if [[ $# -eq 1 ]]; then TARGET=(-s "$1"); fi
if [[ ! -f "$APK" ]]; then echo 'Build the Android app first: sh android/build.sh' >&2; exit 1; fi
"$ADB" "${TARGET[@]}" get-state >/dev/null
"$ADB" "${TARGET[@]}" install -r "$APK"
"$ADB" "${TARGET[@]}" shell pm enable local.boox.sidecar >/dev/null
"$ADB" "${TARGET[@]}" reverse tcp:8787 tcp:8787
LAUNCH_RESULT="$("$ADB" "${TARGET[@]}" shell am start -n local.boox.sidecar/.MainActivity)"
if [[ "$LAUNCH_RESULT" == *"Error"* || "$LAUNCH_RESULT" == *"Exception"* ]]; then
  echo 'Android could not launch BOOX Sidecar. Unfreeze it in BOOX app management and retry.' >&2
  exit 1
fi
echo 'Native BOOX Sidecar installed. Press Connect in the Mac app to pair both USB and Wi-Fi.'
