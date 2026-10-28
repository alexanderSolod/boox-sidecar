#!/bin/bash
set -euo pipefail
PORT=8787
DEVELOPMENT=false
SERIAL=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    --development-browser) DEVELOPMENT=true; shift ;;
    --port) PORT="${2:?--port requires a port}"; shift 2 ;;
    --*) echo 'Usage: scripts/connect-usb.sh [--port PORT] [--development-browser] [USB-device-serial]' >&2; exit 2 ;;
    *) [[ -z "$SERIAL" ]] || exit 2; SERIAL="$1"; shift ;;
  esac
done
[[ "$PORT" =~ ^[0-9]+$ && ${#PORT} -le 5 ]] && ((10#$PORT > 0 && 10#$PORT <= 65535)) || { echo 'Invalid port' >&2; exit 2; }
PORT=$((10#$PORT))
command -v adb >/dev/null || { echo 'Install Android SDK Platform Tools first.' >&2; exit 1; }
ADB=(adb -d)
if [[ -n "$SERIAL" ]]; then ADB=(adb -s "$SERIAL"); fi
"${ADB[@]}" get-state >/dev/null
"${ADB[@]}" reverse "tcp:$PORT" "tcp:$PORT"
if "$DEVELOPMENT"; then
  "${ADB[@]}" shell am start -a android.intent.action.VIEW -d "http://127.0.0.1:$PORT/" >/dev/null
  echo 'Development browser opened. Start the Mac with --development-browser and use its disposable browser token.'
else
  if [[ -z "$("${ADB[@]}" shell pm path local.boox.sidecar)" ]]; then
    echo 'Install the native app, then press Connect on the Mac to pair. Browser access requires --development-browser.' >&2
    exit 1
  fi
  "${ADB[@]}" shell am start -n local.boox.sidecar/.MainActivity >/dev/null
  echo 'USB forwarding ready. Press Connect in the Mac app to pair the native receiver.'
fi
