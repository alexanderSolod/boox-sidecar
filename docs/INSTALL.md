# Install and launch — v0.3.0 release

These steps describe the v0.3.0 release assets using protocol 1. Current source builds use protocol 2, require macOS 15+, and require updating both apps and pairing again over USB. The plaintext status command below applies only to the older release. See [README.md](../README.md) for current-source behavior.

Release assets:

| Asset | Contents |
| --- | --- |
| `BOOX-Sidecar-v0.3.0-macOS.zip` | Ad-hoc-signed Mac host app (macOS 14+; encrypted Wi-Fi needs macOS 15+) |
| `BOOX-Sidecar-v0.3.0.apk` | Debug-signed Android receiver (Android 8+; built for BOOX e-ink tablets) |

Verify downloads against `SHA256SUMS.txt` in the same release:

```sh
shasum -a 256 -c SHA256SUMS.txt
```

## 1. Mac host app

```sh
unzip BOOX-Sidecar-v0.3.0-macOS.zip
xattr -dr com.apple.quarantine "BOOX Sidecar.app"   # required: ad-hoc signed, not notarized
open "BOOX Sidecar.app"
```

On first launch macOS asks for **Screen Recording** — approve it. If capture later reports
`The user declined TCCs`, the grant went stale:

```sh
tccutil reset ScreenCapture local.boox.sidecar   # clears the stale entry
```

Then quit the app, re-add the exact `.app` under
System Settings → Privacy & Security → Screen & System Audio Recording, and reopen it.
This step cannot be fully automated — it is a user consent gate.

Release assets are ad-hoc signed, so the grant must be re-approved after replacing the
app with a *differently signed* copy. Builds from `scripts/build-mac.sh` instead use a
persistent self-signed `BOOX Sidecar Dev` identity (`scripts/create-signing-identity.sh`,
auto-created on first build); grants then survive rebuilds. The first build may show one
keychain "Always allow" prompt.

## 2. Android receiver (BOOX)

Requirements: `adb` on PATH ([Android platform-tools](https://developer.android.com/tools/releases/platform-tools)),
the BOOX on USB with **USB debugging authorized** (Settings → Developer options).

```sh
adb devices                                     # expect: <serial>  device  (not "unauthorized")
adb install -r BOOX-Sidecar-v0.3.0.apk
adb shell pm enable local.boox.sidecar          # BOOX may auto-freeze new apps
adb reverse tcp:8787 tcp:8787                   # USB tunnel
adb shell am start -n local.boox.sidecar/.MainActivity
```

If `adb devices` shows `unauthorized`, approve the prompt on the tablet and re-run.
If launch reports "Activity does not exist", the app was frozen — re-run `pm enable` or
unfreeze **BOOX Sidecar** in BOOX app management.

## 3. Connect

1. Open both apps. Click **Connect** on the Mac — that one action creates the BOOX desktop
   (1240 × 930 logical, to the right of the main display), starts capture, enables encrypted
   Wi-Fi on port 8788, sets up the USB tunnel and provisions the tablet.
2. Move windows across the Mac screen's right edge onto the BOOX.
3. Later sessions need no cable: the tablet remembers this Mac and prefers USB when present,
   otherwise the pinned Wi-Fi route on the same network.

First-time pairing needs USB attached; afterwards Wi-Fi alone is enough.

## Verify the v0.3.0 release

```sh
TOKEN=$(cat "$HOME/Library/Application Support/BOOX Sidecar/pairing-token")
curl -s -H "Authorization: Bearer $TOKEN" http://127.0.0.1:8787/api/status
# expect: "capturing":true, "extendedDesktop":true, "wirelessEnabled":true
adb logcat -d -s BooxSidecar:* | tail
# expect: "Authenticated route connected: USB" (or "pinned Wi-Fi"), then "First native frame drawn"
```

`fps` in status is the *requested* capture rate (1–60), not panel refresh. Received FPS is
logged by the receiver as `Stream stats` and depends on content, transport and the BOOX
refresh mode — see `docs/HARDWARE-TEST.md` for what has and has not been measured.

## Uninstall

```sh
adb uninstall local.boox.sidecar
adb reverse --remove tcp:8787
# Mac: quit the app, delete "BOOX Sidecar.app", remove its Screen Recording entry,
# and delete "$HOME/Library/Application Support/BOOX Sidecar" to forget pairing + TLS identity.
```

## Build from source instead

```sh
./scripts/build-mac.sh                        # needs macOS 15+ and Swift Command Line Tools
python3 scripts/bootstrap-android.py          # project-local JDK17/Gradle/SDK, checksum-verified
sh android/build.sh && ./scripts/install-native.sh
```

See `README.md` for architecture/presets, `docs/PROTOCOL.md` for the wire contract, and
`docs/VALIDATION.md` for exactly what has been verified on hardware.
