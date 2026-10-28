#!/bin/bash
set -euo pipefail
if ! command -v adb >/dev/null 2>&1; then
  echo 'adb is required. Install Android SDK Platform Tools, then retry.' >&2
  exit 1
fi
if [[ $# -gt 1 ]]; then
  echo 'Usage: scripts/connect-usb.sh [USB-device-serial]' >&2
  exit 2
fi
# -d selects one USB device and refuses to guess if several are connected.
ADB=(adb -d)
if [[ $# -eq 1 ]]; then ADB=(adb -s "$1"); fi
if ! "${ADB[@]}" get-state >/dev/null; then
  echo 'Connect the BOOX with a data-capable USB cable, enable USB debugging, and approve this Mac on the tablet.' >&2
  exit 1
fi
"${ADB[@]}" reverse tcp:8787 tcp:8787
if "${ADB[@]}" shell pm path local.boox.sidecar >/dev/null 2>&1 && [[ -n "$("${ADB[@]}" shell pm path local.boox.sidecar)" ]]; then
  "${ADB[@]}" shell am start -n local.boox.sidecar/.MainActivity >/dev/null
else
  "${ADB[@]}" shell am start -a android.intent.action.VIEW -d http://127.0.0.1:8787/ >/dev/null
fi
echo 'USB forwarding ready. Open BOOX Sidecar on the Mac, start capture, and enter its session token in the BOOX viewer.'
echo 'To remove forwarding later: adb -d reverse --remove tcp:8787'
