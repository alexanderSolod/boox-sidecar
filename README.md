# BOOX Sidecar

An independent Mac-to-BOOX display app with remembered pairing, one **Connect** action, automatic USB preference with pinned Wi-Fi fallback, and performance presets. Current source builds use protocol 2; the documented v0.3.0 release assets use protocol 1. It provides a native Android receiver and an independent Mac desktop. The browser viewer is available only through an explicit development launch mode.

## Use the native app

For released binaries, see [installation instructions](docs/INSTALL.md).

1. Open `dist/BOOX Sidecar.app` on the Mac and grant Screen Recording when requested.
2. On first setup, connect the BOOX by USB, enable USB debugging and authorize this Mac.
3. Install the Android app: `./scripts/install-native.sh`.
4. Click **Connect** on the Mac. It creates the BOOX desktop, starts capture, enables encrypted Wi-Fi when available unless explicitly disabled, establishes the USB tunnel and provisions the installed native app.
5. Move windows onto the BOOX desktop using your Mac's display arrangement. Its logical size is 1240 × 930, backed by a 2480 × 1860 HiDPI display. The app remembers its position; if that position is unavailable, it places the BOOX beside the rightmost display.
6. Later, open both apps and click **Connect**. The Android app remembers this Mac. **Auto** prefers USB, falls back to the saved pinned Wi-Fi route, and returns to USB when available. Wi-Fi needs both devices on a reachable network; USB works without Wi-Fi.

Protocol 2 requires updating both apps and pairing again over USB. Pairing survives normal restarts. Both USB and Wi-Fi require TLS and the saved public-key pin; discovery can locate a remembered Mac but cannot pair an unknown Mac.

The Mac stores pairing and TLS credentials under `~/Library/Application Support/BOOX Sidecar/`. **Forget pairing** stops sharing and replaces the pairing credential. Disconnect stops sharing while retaining pairing. Certificates renew automatically without changing the pinned key. See [the protocol](docs/PROTOCOL.md) for transport and pairing details.

The Android app runs fullscreen and renders native bitmaps. Display selection is local to the Mac. Optional tap/scroll requires the Mac's separate input opt-in, Accessibility permission, and the current capture session.

## Resolution and refresh rate

The Note Air4 C has **2480 × 1860 monochrome** resolution and **1240 × 930 color** resolution. [BOOX specifications](https://shop.boox.com/collections/all/products/noteair4c).

| Preset | Stream width | Color | Requested FPS | JPEG quality |
| --- | ---: | --- | ---: | ---: |
| Speed | 1240 | Color | 60 | 0.60 |
| Balanced / Balanced color | 1240 | Color | 60 | 0.78 |
| Sharp text | 2480 | Grayscale | 60 | 0.88 |

Use Speed for motion, Balanced for general color use, and Sharp text for fine text. Doubling both dimensions processes four times as many pixels. Presets are starting points; actual performance depends on content, encoding, transport and tablet decoding.

**60 requested FPS is not 60 visible E Ink updates per second.** Static desktops may produce no new frames. BOOX documents a quality/speed tradeoff but does not give a guaranteed numerical panel refresh rate in its [refresh guide](https://booxsupport.zendesk.com/hc/en-us/articles/8569262708372-Refresh-Modes).

The Android **Faster panel…** button explicitly offers X mode, with reduced detail and more ghosting. It never changes the waveform merely because a stream preset was selected. Optional Normal, Regal, A2 and X modes use the firmware's public app-scoped API with delayed readback; unsupported firmware uses manual E Ink Center instructions. The app does not bypass Android's blocked hidden APIs.

## Build

Mac: macOS 15+ and Swift Command Line Tools.

```sh
./scripts/build-mac.sh
open 'dist/BOOX Sidecar.app'
```

The build creates and reuses a local self-signed `BOOX Sidecar Dev` identity in the login keychain. Set `BOOX_SIGN_IDENTITY` to an existing certificate name or SHA-1 to use another identity, including an Apple Development certificate. Keeping the same identity preserves the app's code-signing identity across rebuilds; switching identities may require Screen Recording and Accessibility approval again.

For CI or an ad-hoc build, use `BOOX_SIGNING=adhoc ./scripts/build-mac.sh`. Signing failures stop the build; there is no automatic ad-hoc fallback. See [installation details](docs/INSTALL.md) for the first-signing prompt.

For automatic setup on launch:

```sh
open 'dist/BOOX Sidecar.app' --args --extended --wireless
```

Android: the project-local bootstrap downloads checksum-verified official JDK17, Gradle8.9, Android Platform35 and Build Tools35 archives. It does not change global Java or Android settings.

```sh
python3 scripts/bootstrap-android.py
sh android/build.sh
./scripts/install-native.sh
```

See [Android build and connection details](android/README.md). The Mac app uses local development signing and the APK is debug-signed; these are not notarized/production-store releases.

## Tests and known limits

```sh
./scripts/test.sh
```

Requires the build tools above, Node.js 22+, and Python 3. Use `--suite browser|mac|android` for one platform or `--gui` for host smoke tests in an interactive macOS desktop session.

The [validation results](docs/VALIDATION.md), [hardware checklist](docs/HARDWARE-TEST.md), and [implementation plan](docs/PLAN.md) record the v0.3 release.

- Native virtual-display creation uses undocumented CoreGraphics interfaces isolated in an Objective-C target. It is experimental and may break with a macOS update. References/licenses are in [THIRD_PARTY_NOTICES.md](macos/THIRD_PARTY_NOTICES.md).
- Portrait desktop presets, pressure-sensitive pen, palm rejection, audio, clipboard and keyboard forwarding remain future work.
- Wi-Fi requires a route between tablet and Mac; guest/client-isolated networks can prevent it.
- The host keeps one latest JPEG and clients bound their work. Static screens may produce fewer frames than the requested rate.
- The normal USB TLS listener binds only to loopback on 8787. Wi-Fi uses a separate TLS listener on 8788. Both use SHA-256 public-key/SPKI pinning and bearer authentication. No cloud relay, external viewer assets, telemetry, or system-wide TLS bypass.
- Replacing the Mac TLS key, resetting its installation identity, or forgetting pairing requires pairing the Android app again. Stop capture or quit the host to end sharing.

## Development browser and troubleshooting

`./scripts/connect-usb.sh` creates the USB tunnel and opens the native app. For browser development, launch the Mac executable with `--development-browser`, then use `./scripts/connect-usb.sh --development-browser`. This mode uses loopback HTTP and a disposable token printed at launch or available through **Copy browser link**. It can capture a locally selected real display, but never loads native pairing credentials or enables native provisioning, Wi-Fi, or discovery. It is intentionally insecure development transport and cannot control BOOX hardware refresh modes. `--demo` continues to provide synthetic frames without capture or input. `--lan` is unsupported.

Run `./scripts/doctor.sh` for basic diagnostics. If ADB reports unauthorized, accept the prompt on the BOOX. If no device appears, reconnect a data cable and keep the device unlocked. A repeated USB 'device not responding' error can require restarting the tablet before installation; that is independent of the display-streaming code.

If the BOOX freezes newly installed apps, unfreeze **BOOX Sidecar** in its app management settings. A disabled app can misleadingly appear as “Activity does not exist” during pairing. If macOS rejects capture after changing the app's signing identity, remove its old entry and add the exact current `dist/BOOX Sidecar.app` under Screen & System Audio Recording, then quit and reopen it.
