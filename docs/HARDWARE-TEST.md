# BOOX Sidecar hardware acceptance

Updated 2026-10-28. Record Mac version, BOOX firmware, app build, connection type/network and test date with each result. Compilation, a created virtual display and synthetic frames do not establish native end-to-end streaming or physical panel performance.

Current device: NoteAir4C, Android 13; installed native app **v0.3 / version code 3** on 2026-10-28. The sections below marked v0.2 are the earlier verified baseline; the v0.3 checklist tracks the new one-Connect, remembered-pairing and auto-route flow.

## v0.3 acceptance (2026-10-28)

- [x] v0.3.0 APK (versionCode 3) builds, installs and launches on the actual Android 13 NoteAir4C; logcat shows `Native receiver ready` and `BOOX refresh mode ready=true`.
- [x] USB provisioning intent stores pairing and the Auto route reaches `Authenticated route connected: USB` against the live v0.3 host (token + authenticated `host_id` verified).
- [x] Host creates the v0.3 extended desktop (virtual display 20) and enables the TLS listener + Bonjour on 8788 from a single Connect.
- [ ] Connect retry after Screen Recording re-approval delivers real capture frames to the native Canvas (grant reset 2026-10-28; approval pending).
- [ ] Unplugging USB after pairing falls back to the pinned Wi-Fi route; replugging returns to USB.
- [ ] Received-FPS and panel quality measured while content moves, recorded per preset (Speed / Balanced / Sharp text).
- [ ] Disconnect stops sharing while retaining pairing; Forget pairing rotates the credential and forces re-pairing.
- [ ] Mac restart keeps pairing; address change is recovered by Bonjour discovery with `host_id` match.

## v0.2 baseline evidence

## Evidence already obtained

- [x] Authorized BOOX detected over ADB and USB reverse established during initial testing.
- [x] Earlier Mac capture reached BOOX over USB: authenticated status/JPEG checked on tablet; user confirmed browser rendering on 2026-10-27. This was 1240 px, 5 requested FPS, grayscale.
- [x] Packaged v0.2 Mac app creates an independent virtual display: 1240 × 930 logical, 2480 × 1860 native, right-hand position, nonmirrored.
- [x] Native APK builds, lint and JVM tests pass, and APK installation succeeded on the actual Android 13 BOOX.
- [x] Read-only firmware inspection confirms public app-scoped refresh API signatures/constants. This does not verify mode switching or physical refresh behavior.

## Current native USB and extended display

- [x] Final packaged Mac app has valid Screen Recording consent and emits live `demo=false`, `extendedDesktop=true` frames: virtual display 18, 1240 × 930, color, requested 60 FPS.
- [ ] Denied/revoked Screen Recording shows actionable guidance and no desktop content.
- [ ] USB provisioning opens the installed native app and authenticated frames reach its Canvas renderer.
- [x] A window moved across the MacBook's right edge appears on BOOX; user confirmed on 2026-10-27.
- [ ] Native color, width and requested FPS controls apply correctly; record received FPS separately.
- [ ] Stop capture clears displayed/pending native frames within the status polling interval; quitting or connection loss clears stale content.
- [ ] A token from a prior host launch is rejected; re-pairing restores the session.
- [ ] Removing the selected display stops safely rather than silently sharing another display.
- [ ] Portrait/landscape device rotation preserves image aspect and touch coordinates.
- [ ] Fullscreen, controls overlay and exit remain usable.

## Encrypted Wi-Fi

- [x] Enable Mac TLS listener and provision endpoint/token/certificate fingerprint over USB; native app logs Wi-Fi pairing.
- [x] Native app receives and draws a 1240 × 930 frame over Wi-Fi on the actual BOOX (`First native frame drawn`, session 1).
- [x] Remove USB reverse mapping for port 8787.
- [x] Physically unplug USB and confirm frames continue over Wi-Fi; user confirmed on 2026-10-27.
- [ ] Incorrect certificate pin fails closed without sending authenticated API requests or accepting frames.
- [ ] Expired/replaced certificate and rotated token fail with actionable re-pairing guidance.
- [ ] Wi-Fi interruption/reconnection and Mac LAN-address changes are handled without stale frames or unbounded queues.
- [ ] Explicit USB/Wi-Fi switching works; Wi-Fi failure never silently downgrades to plaintext LAN HTTP.
- [ ] A network with client isolation produces understandable connection failure rather than a misleading “live” status.

## Input, refresh and sustained use

- [ ] With Mac input disabled or Accessibility absent, taps/swipes do not control the Mac.
- [ ] With local consent and Accessibility granted, four corners and center map correctly on the selected display.
- [ ] Letterbox taps and invalid coordinates produce no input.
- [ ] Display placement left/above the main display maps correctly, including negative Mac coordinates.
- [ ] Existing BOOX refresh mode is preserved on app launch; only explicit selection requests a change.
- [ ] Optional refresh mode readiness/readback agrees with the selected mode, and visual quality/ghosting changes are observed.
- [ ] Missing firmware APIs/service readiness fall back to E Ink Center. Blocked hidden APIs are never bypassed.
- [ ] BOOX system full refresh works; **Reload frame** and bitmap redraw are not presented as hardware refresh.
- [ ] BOOX/Mac sleep-wake, app background-resume and USB reconnection recover without frame backlog.
- [ ] A 30-minute reading/scrolling session has acceptable ghosting, battery, CPU and memory behavior.

Measure input-to-visible latency with an external camera. Compare requested 5/15/30/60 FPS and different image widths/colors; do not infer 60 visible color updates per second from a 60 Hz Mac display or a configured 60 FPS limit.

## Observed setup issues

The BOOX launcher automatically froze this app during testing. If installation succeeds but opening fails, unfreeze/enable BOOX Sidecar in BOOX app management. The observed package state was `enabled=3` with `lastDisabledCaller=com.onyx`; enabling the app restored launching.

Ad-hoc Mac rebuilds can leave stale Screen Recording authorization. Remove the stale app entry and add the exact current bundle again in System Settings, then relaunch. The final run succeeded after resetting the stale grant and manually re-adding the final app.

Zero received FPS on an unchanged desktop is not a motion benchmark. Move a window or scroll while measuring sustained delivery and observing panel quality.
