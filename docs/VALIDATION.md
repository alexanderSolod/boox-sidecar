# BOOX Sidecar validation — 2026-10-28

Environment: Apple Silicon Mac, macOS 26.6.2, Swift 6.3.3 Command Line Tools. Mac minimum: 14 for USB, 15 for encrypted Wi-Fi. Actual tablet: BOOX NoteAir4C running Android 13.

## Current v0.3 evidence (2026-10-28)

- `./scripts/build-mac.sh` builds and ad-hoc signs the v0.3.0 Mac bundle; `codesign --verify --deep --strict` passes inside the script.
- `sh android/build.sh` compiles the v0.3.0 / versionCode 3 APK; `./scripts/install-native.sh` installed it on the actual NoteAir4C, and `am start` displays `MainActivity` (logcat: `Native receiver ready`, `BOOX refresh mode ready=true`).
- `sh android/tests/run-native-client-tests.sh` passes 40 checks covering endpoint restrictions, token/pin validation, certificate matching and expiry, and the v0.3 auto-route candidate/retry policy.
- `node --test viewer/app.test.js` passes 11 tests; `python3 tests/smoke_host.py` passes 8 tests.
- Live v0.3 USB pairing evidence: a provisioning intent carrying `host`, `usb_host`, `token`, `cert_sha256` and `host_id` logged `Pairing updated; automatic USB / pinned Wi-Fi enabled` followed by `Authenticated route connected: USB` on the actual tablet against the running host. The host reported `extendedDesktop=true`, `virtualDisplayID=20`, `wirelessEnabled=true`, `fps=60`, `maxWidth=1240`, color.
- Live capture remains gated by Screen Recording consent: after the v0.3 rebuild the running app reported `ScreenCaptureKit failed (-3801): The user declined TCCs` with `capturing=false`. The stale grant was reset with `tccutil reset ScreenCapture local.boox.sidecar`; approval plus a Connect retry, real frames, the Wi-Fi auto-route and sustained-FPS measurements remain the pending hardware gate.
- Earlier records below describe v0.2; only statements re-verified above apply to v0.3.

## Current v0.2 evidence

- The packaged Mac app builds with the isolated Objective-C virtual-display backend and native TLS support. Its experimental virtual-display creation succeeds: 1240 × 930 logical, 2480 × 1860 native HiDPI, arranged to the right, nonmirrored. The final host also captures that virtual display, and the installed native receiver logged its first 1240 × 930 Canvas draw over Wi-Fi; details follow.
- Native Android APK compilation and lint pass with the project-local JDK 17 / Gradle 8.9 / Android SDK 35 toolchain. Native version 0.2 / version code 2 was installed successfully on the actual Android 13 NoteAir4C.
- `sh android/tests/run-native-client-tests.sh` passes 18 checks covering endpoint restrictions, token validation, pin normalization, matching/mismatching certificate pins and certificate validity. These are JVM checks, not an on-tablet Wi-Fi acceptance test.
- `node --test viewer/app.test.js` passes 11 tests: aspect/letterbox coordinate mapping, polling bounds, token handling, status guidance, decode backpressure, stale decode cancellation, settings/frame races, retry/discovery, protocol checks and late-status suppression. The additional defaults regression checks color, 60 requested FPS and 1240 px.
- Read-only inspection of the actual tablet's system framework confirms public `android.onyx.optimization.EInkHelper` readiness/get/set app-scope refresh methods and symbolic mode constants. The implementation uses optional public reflection with delayed readback. Direct `ViewUpdateHelper.fullRefreshScreen` is marked blocked and is not used. API presence is not proof of effective panel changes.

The v0.2 implementation adds native Canvas rendering, host-created extended desktop, full color by default, 1–60 requested FPS, USB provisioning and pinned TLS Wi-Fi on port 8788. These are implemented capabilities; only the specific results above and below are verified.

## Final native Wi-Fi and extended-display evidence

Screen Recording consent for the exact final packaged Mac app was repaired by resetting the stale ad-hoc grant and manually adding that bundle again in System Settings. Final authenticated host status reported:

```text
permission=true, demo=false, extendedDesktop=true
displayID=18, virtualDisplayID=18
width=1240, height=930, fps=60, grayscale=false
wirelessEnabled=true
```

The BOOX launcher had automatically frozen the installed app (`enabled=3`, `lastDisabledCaller=com.onyx`). Enabling `local.boox.sidecar` restored launching. Native logs then reported Wi-Fi pairing and `First native frame drawn 1240x930 session=1` on the actual tablet. Together with the live host status, this verifies the native Wi-Fi receive/decode/Canvas path for the extended display. It does not measure physical panel quality or continuous motion throughput.

The USB reverse mapping for port 8787 was removed. The user physically unplugged USB, moved a Mac window onto the BOOX desktop, and confirmed that it continued updating in the native app on 2026-10-27. Wireless extended-desktop operation is verified end to end. An idle received rate of zero is compatible with an unchanged desktop and is not a sustained-moving-FPS measurement.

## Remaining acceptance and troubleshooting

Still pending:

- Sustained moving-image received FPS, panel latency, color/waveform quality, ghosting and battery measurements.
- On-device wrong-pin rejection, explicit transport switching, restart/re-pairing and network recovery.
- Actual refresh-mode changes/readback and visible panel effect.
- Accessibility input against real applications; rotation and display-position mapping on hardware.
- Sleep/wake, background/resume, display removal and cable reconnection acceptance.

If the installed native app will not launch, check BOOX app management for automatic app freezing and unfreeze/enable BOOX Sidecar. A correctly installed APK can still be disabled by the BOOX launcher.

An ad-hoc Mac rebuild can invalidate or leave a stale Screen Recording grant. If capture is denied despite an existing permission entry, quit the app, remove the stale entry and add the exact current `dist/BOOX Sidecar.app` in System Settings → Privacy & Security → Screen Recording, then reopen it and start capture. The final validation used a reset followed by this exact-bundle re-add; do not assume every subsequent rebuild retains that grant.

Do not infer 60 visible color updates per second from a 60 Hz virtual display or configured 60 FPS limit. See [HARDWARE-TEST.md](HARDWARE-TEST.md) for the remaining acceptance checklist.

## Initial software validation

The initial USB/browser build passed:

- `./scripts/build-mac.sh`, including a release app bundle and ad-hoc signature verification with `codesign --verify --deep --strict`.
- Seven `python3 tests/smoke_host.py` cases against the packaged synthetic demo: public assets, bearer authentication, JPEG delivery, input consent gate, settings validation, origin/method/path checks and malformed/oversized HTTP rejection. The suite now accepts the v0.2 FPS range; this historical result is not an assertion that every later packaged revision has been retested.
- A real browser connected to the native synthetic demo and displayed changing 1240 × 930 generated frames, with remote input disabled. See `demo-viewer.png`.
- Shell syntax and Android XML/static configuration checks.

Local socket smoke tests required execution outside the coding sandbox. Synthetic mode reports `demo=true`, `permission=true` without granting Screen Recording or Accessibility. Its frames contain generated content, not the user's desktop.

## Earlier live Mac capture and USB mirroring

After the user initially granted Screen Recording, the packaged app started real ScreenCaptureKit capture (`demo=false`). API checks showed advancing frame IDs, 1240 × 805 output at a 5 FPS requested maximum, and a valid 141,841-byte JPEG. Desktop image bytes were validated in memory and not saved.

The tablet initially exposed only MTP. After retrying the ADB handshake, NoteAir4C became authorized and reported Android 13. `adb reverse tcp:8787 tcp:8787` established the USB tunnel. HTTP checks executed on the BOOX confirmed health, authenticated live status (`permission=true`, `demo=false`, 1240 × 805, 5 requested FPS) and a valid 193,304-byte JPEG. Image bytes were checked in memory rather than saved.

The user then confirmed that the Mac desktop appeared in the BOOX browser after tapping Connect. This establishes the earlier end-to-end **browser USB mirroring** baseline at grayscale / 1240 px / 5 requested FPS / viewing only. It does not verify the newer native receiver, color performance, virtual-display capture or encrypted Wi-Fi path.
