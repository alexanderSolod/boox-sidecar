#!/bin/bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
CONFIG="${1:-release}"
if [[ "$CONFIG" != release && "$CONFIG" != debug ]]; then
  echo 'Usage: scripts/build-mac.sh [release|debug]' >&2
  exit 2
fi
mkdir -p "$ROOT/.build/swift-module-cache" "$ROOT/.build/clang-module-cache" "$ROOT/dist"
export CLANG_MODULE_CACHE_PATH="$ROOT/.build/clang-module-cache"
export SWIFTPM_MODULECACHE_OVERRIDE="$ROOT/.build/swift-module-cache"
swift build --package-path "$ROOT/macos" --scratch-path "$ROOT/.build/mac" --cache-path "$ROOT/.build/swift-package-cache" --disable-sandbox -c "$CONFIG"
BIN_DIR="$(swift build --package-path "$ROOT/macos" --scratch-path "$ROOT/.build/mac" --cache-path "$ROOT/.build/swift-package-cache" --disable-sandbox -c "$CONFIG" --show-bin-path)"
APP="$ROOT/dist/BOOX Sidecar.app"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources/viewer"
cp "$BIN_DIR/BooxSidecar" "$APP/Contents/MacOS/BooxSidecar"
cp "$ROOT/macos/THIRD_PARTY_NOTICES.md" "$APP/Contents/Resources/THIRD_PARTY_NOTICES.md"
for asset in index.html app.js style.css; do
  cp "$ROOT/viewer/$asset" "$APP/Contents/Resources/viewer/$asset"
done
cat > "$APP/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleExecutable</key><string>BooxSidecar</string>
<key>CFBundleIdentifier</key><string>local.boox.sidecar</string>
<key>CFBundleName</key><string>BOOX Sidecar</string>
<key>CFBundleDisplayName</key><string>BOOX Sidecar</string>
<key>CFBundlePackageType</key><string>APPL</string>
<key>CFBundleShortVersionString</key><string>0.3.2</string>
<key>CFBundleVersion</key><string>5</string>
<key>LSMinimumSystemVersion</key><string>14.0</string>
<key>NSLocalNetworkUsageDescription</key><string>Stream your selected desktop to your paired BOOX over encrypted Wi-Fi.</string>
<key>NSBonjourServices</key><array><string>_boox-sidecar._tcp</string></array>
<key>NSHighResolutionCapable</key><true/>
<key>NSScreenCaptureUsageDescription</key><string>Share the display you choose with your BOOX over USB or encrypted Wi-Fi.</string>
</dict></plist>
PLIST
# A persistent self-signed identity keeps the code requirement stable across
# rebuilds, so Screen Recording / Accessibility grants survive. Ad-hoc signing
# resets them every build. Opt out with BOOX_SIGNING=adhoc.
if [[ "${BOOX_SIGNING:-self}" == adhoc ]]; then
  codesign --force --sign - "$APP"
else
  IDENTITY="${BOOX_SIGN_IDENTITY:-BOOX Sidecar Dev}"
  if security find-identity 2>/dev/null | grep -qF "\"$IDENTITY\"" \
     || "$ROOT/scripts/create-signing-identity.sh" >/dev/null; then
    codesign --force --sign "$IDENTITY" --timestamp=none "$APP"
  else
    echo "warning: no signing identity; using ad-hoc (TCC grants reset each rebuild)" >&2
    codesign --force --sign - "$APP"
  fi
fi
codesign --verify --deep --strict "$APP"
echo "Built: $APP"
