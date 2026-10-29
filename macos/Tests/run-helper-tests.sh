#!/bin/sh
set -eu
root="$(cd "$(dirname "$0")/../.." && pwd)"
work="$(mktemp -d "${TMPDIR:-/tmp}/boox-swift-tests.XXXXXX")"
trap 'rm -rf "$work"' EXIT
swiftc -module-cache-path "$work/module-cache" \
    "$root/macos/Sources/BooxSidecar/PairingCredential.swift" \
    "$root/macos/Sources/BooxSidecar/DevicePairing.swift" \
    "$root/macos/Tests/ConnectionHelpersTests.swift" -o "$work/helpers"
"$work/helpers"
swiftc -module-cache-path "$work/module-cache" \
    "$root/macos/Sources/BooxSidecar/USBProvisioningState.swift" \
    "$root/macos/Tests/USBProvisioningTests.swift" -o "$work/usb"
"$work/usb"
swiftc -module-cache-path "$work/module-cache" \
    "$root/macos/Sources/BooxSidecar/VirtualDisplayPlacement.swift" \
    "$root/macos/Tests/VirtualDisplayPlacementTests.swift" -o "$work/placement"
"$work/placement"
