#!/bin/bash
set -u
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
echo 'BOOX Sidecar environment'
sw_vers
for tool in swift adb node python3; do
  if command -v "$tool" >/dev/null 2>&1; then
    echo "$tool: $(command -v "$tool")"
  else
    echo "$tool: missing"
  fi
done
if [[ -d /Applications/BetterDisplay.app ]]; then
  echo 'BetterDisplay: installed (optional virtual-display provider)'
else
  echo 'BetterDisplay: not installed (mirroring still works)'
fi
if [[ -d "$ROOT/dist/BOOX Sidecar.app" ]]; then
  echo 'Mac app: built'
else
  echo 'Mac app: run scripts/build-mac.sh'
fi
if command -v adb >/dev/null 2>&1; then
  adb devices -l
fi
echo 'No permissions or system settings have been changed by this check.'
