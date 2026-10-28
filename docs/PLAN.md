# BOOX Sidecar implementation plan

Target: BOOX Note Air4 C and this Apple Silicon MacBook. Updated 2026-10-28.

## v0.3 delta (implemented 2026-10-28)

One **Connect** action replaces the manual setup sequence: it prepares the extended desktop, starts capture, enables encrypted Wi-Fi, establishes the ADB reverse tunnel, provisions attached BOOX devices and keeps a USB watcher for reconnects. Pairing now persists in a private `~/Library/Application Support/BOOX Sidecar` credential (0600 file in a 0700 directory), so a Mac restart keeps the pairing and **Forget pairing** rotates it. The Mac advertises `_boox-sidecar._tcp.` with a public `host_id`; the Android Auto route tries USB first, then discovered/saved pinned Wi-Fi, probing USB while on Wi-Fi. Picture presets (Speed / Balanced / Sharp text) set width, color and JPEG quality at 60 requested FPS. Wire protocol stays at 1 with added `host_id`/status fields; see [PROTOCOL.md](PROTOCOL.md). Hardware acceptance for this delta is tracked in [HARDWARE-TEST.md](HARDWARE-TEST.md).

## v0.2 plan record

## Intended outcome

Use a dedicated BOOX Android app as an independent Mac display over USB or encrypted Wi-Fi, with full-color frames, optional touch control and device refresh controls. This independent prototype does not implement Apple's proprietary Sidecar protocol.

The Note Air4 C runs Android 13 and has 2480 × 1860 monochrome / 1240 × 930 color resolution. Current defaults are a 1240-pixel-wide color stream and a maximum requested rate of 60 FPS. Nominal Mac display refresh, capture/poll FPS, received frames and physical e-ink updates are different measurements. No 60 Hz color-panel claim is made.

## Implemented architecture

```text
Mac-created extended desktop (or selected existing display)
  → ScreenCaptureKit → resize / optional grayscale → newest JPEG
  → bearer-authenticated USB HTTP or certificate-pinned Wi-Fi HTTPS
  → native Android worker → bounded bitmap handoff → Canvas view
```

The Mac app owns capture consent, virtual-display lifecycle, encoding, local input consent, the TLS identity and USB provisioning. The native Android app owns connection selection, certificate pinning, rendering, touch mapping, lifecycle/reconnect and optional BOOX refresh modes. The browser is a USB fallback. Queues remain bounded so a slow receiver cannot accumulate a stream backlog.

The Mac creates its own 1240 × 930 logical, 2480 × 1860 HiDPI desktop to the right of the main display, with mirroring disabled. The Objective-C backend isolates undocumented CoreGraphics interfaces. They remain a macOS compatibility risk; selecting an existing display remains available. BetterDisplay is no longer required for the implemented path.

USB uses ADB reverse on loopback port 8787. Wireless uses a separate TLS listener on 8788, with the exact certificate fingerprint and current bearer token provisioned over USB. No system trust changes or cloud relay are required. The host token rotates on every launch; certificate identity persists. The actual BOOX has logged a first native Canvas frame over Wi-Fi from the live extended-display stream. The user confirmed moving-window updates with USB physically unplugged. Sustained motion/panel measurements remain outstanding.

## Milestones and actual completion gates

| Milestone | Implemented / verified evidence | Remaining completion gate |
| --- | --- | --- |
| USB mirroring baseline | Earlier real Mac capture and authenticated USB JPEG transport verified; user confirmed browser rendering | Complete native USB lifecycle and reconnection checks |
| Native extended desktop | Packaged Mac app creates the right-hand nonmirrored HiDPI desktop; live 1240 × 930 capture and first native Canvas frame verified | Move a window onto it and verify its live content in the native BOOX app |
| Native Android receiver | APK build/lint/JVM tests pass; v0.2/code 2 installed; first 1240 × 930 native frame drawn on actual Android 13 NoteAir4C | Verify fullscreen, rotation, lifecycle and reconnection |
| Encrypted Wi-Fi | TLS listener/provisioning implemented; actual BOOX renders the extended desktop; user confirmed moving-window continuity with USB unplugged | Test wrong-pin rejection and network recovery on device |
| Color and input | Color / resolution / requested FPS controls and locally gated tap/scroll implemented | Measure received rate and visible panel latency; verify touch mapping and consent on physical devices |
| BOOX refresh modes | Public firmware API signatures verified read-only; optional mode selection/readback implemented | Confirm reported mode and physical response; manual E Ink Center remains fallback |
| Distribution readiness | Ad-hoc Mac bundle and debug APK available for development | Stable signing/notarization, release updates, clean-machine install and broader macOS/firmware testing |

The final Mac app reports live color capture from virtual display 18 at 1240 × 930 with 60 requested FPS and Wi-Fi enabled. Its stale ad-hoc Screen Recording grant was repaired by re-adding the exact final bundle. The native BOOX app has drawn its first frame over Wi-Fi. The user confirmed a moving window on the BOOX continues updating after physically unplugging USB. Wireless extended-desktop operation is verified; sustained motion and waveform-quality measurements remain pending.

## Next acceptance sequence

1. Completed: user confirmed a window moved across the MacBook’s right edge appears on the BOOX.
2. Completed: user confirmed moving frames continue with USB physically unplugged; the USB reverse mapping was also removed.
3. Measure received FPS while content changes. An unchanged desktop can report zero received FPS; compare that separately from motion performance.
4. Exercise pause/resume, network interruption, host restart/token rotation, capture stop and display removal. Confirm stale frames and input are cleared, with no silent source switch or plaintext downgrade.
5. Select optional BOOX refresh modes explicitly, verify readiness/readback and observe the panel. Preserve the original mode when no selection is made. Do not bypass blocked hidden APIs.
6. Test input with Mac opt-in/Accessibility both absent and present. Verify corners/center, letterboxes and different display positions.
7. Run a 30-minute mixed reading/scrolling session and record received FPS, CPU/memory, frame sizes, battery and ghosting.

## Performance and future work

Compare 5/15/30/60 requested FPS, color/grayscale and 1240/1860/2480 widths. Use an external camera for input-to-visible latency because software timestamps omit panel scanout. Static screens may naturally produce fewer frames. Evaluate unchanged-frame suppression, text-oriented compression or dirty rectangles only after collecting measurements.

Portrait virtual-display presets, pressure-sensitive pen, palm rejection, keyboard forwarding, audio and clipboard remain future features. Production distribution also needs a documented strategy for private CoreGraphics API compatibility and TLS identity expiration/re-pairing. Observed setup issues are BOOX auto-freezing the native app and stale Screen Recording grants after ad-hoc Mac rebuilds; troubleshooting must cover unfreezing the app and re-adding the exact current Mac bundle.

## Validation and references

Automated checks cover HTTP validation/authentication, bounded frame semantics, browser race handling, native endpoint/pin validation, build/lint and packaging. Hardware completion is tracked in [HARDWARE-TEST.md](HARDWARE-TEST.md); evidence and limitations are in [VALIDATION.md](VALIDATION.md).

- [BOOX official specifications](https://booxsupport.zendesk.com/hc/en-us/articles/360027768131-What-are-the-specifications-of-BOOX-devices)
- [Apple ScreenCaptureKit](https://developer.apple.com/documentation/screencapturekit)
- [Android Debug Bridge](https://developer.android.com/tools/adb)
- [BOOX SDK and examples](https://github.com/onyx-intl/OnyxAndroidDemo)
- [Virtual-display references/licenses](../macos/THIRD_PARTY_NOTICES.md)
