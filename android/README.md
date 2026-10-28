# BOOX Sidecar native receiver

This is a dedicated Java Android app, not a browser or WebView. A custom Canvas view displays the Mac's latest JPEG while a single worker handles authenticated HTTP requests and bitmap decoding. USB uses `adb reverse`; Wi-Fi uses HTTPS with a provisioned exact SHA-256 certificate pin.

The app targets API 35 and supports API 26+. The connected BOOX Note Air4 C reports Android 13. There are no third-party runtime libraries.

## Build and install

The repository's local tools are detected automatically: `.tools/jdk/Contents/Home` (JDK 17), `.tools/gradle-8.9`, and `.tools/android-sdk` (API/build tools 35). Alternatively supply `JAVA_HOME`, Gradle 8.9 on `PATH`, and `ANDROID_HOME` yourself.

From the repository root:

```sh
sh android/build.sh :app:lintDebug
sh android/tests/run-native-client-tests.sh
adb install -r android/app/build/outputs/apk/debug/app-debug.apk
adb shell am start -n local.boox.sidecar/.MainActivity
```

The first build downloads the pinned Android Gradle Plugin 8.7.3 and dependencies. Subsequent builds can append `--offline`. Build caches stay in `.tools/gradle-cache` by default. No Gradle wrapper binary is included. The debug APK is for local development/sideloading, not publication signing.

## Pairing

Start the Mac host and use the repository's USB pairing helper. The restricted `ProvisioningActivity` accepts explicit provisioning extras from callers holding `android.permission.DUMP` (including the ADB shell). The public launcher ignores pairing extras:

- `host`: `http://127.0.0.1:8787` for USB or `https://MAC_IP:8788` for Wi-Fi.
- `token`: the Mac's current 64-character hexadecimal session token.
- `cert_sha256`: the Wi-Fi server certificate's SHA-256 fingerprint over its DER encoding (64 hex characters, optional colons).

Pairing values are validated before a durable update. Invalid provisioning leaves the previous pairing intact. Manual replacement requires confirmation. A Wi-Fi provisioning intent selects Wi-Fi; USB provisioning selects USB. Both endpoint configurations are retained. Token and pin are kept in private app SharedPreferences, with Android backup and device-transfer exclusions. Tokens are never written to native app logs. Pair again after the Mac host rotates its session token. Use **Controls → Connect / pair** to edit settings or explicitly switch transports. There is no automatic downgrade from Wi-Fi to USB. **Clear saved pairing** removes the stored credentials.

For USB, authorize this computer on the tablet and run:

```sh
adb reverse tcp:8787 tcp:8787
```

Re-run reverse after reconnecting USB or restarting the tablet. For Wi-Fi, keep the Mac and BOOX on a reachable network and provision the trusted certificate pin over USB before removing the cable.

## Display controls

- Fullscreen is on by default. The **Controls** button shows or hides the overlay. Back hides controls, then exits fullscreen, then leaves the app.
- Streaming defaults to **60 FPS**, **color**, **1240-pixel maximum width**. Select 5/15/30/60 FPS and 1240/1860/2480 widths. The status reports requested FPS separately from frames received. Panel refresh rate and real streaming throughput can be much lower than requested FPS.
- **Remote input** enables taps and vertical swipes within the displayed image. Letterbox regions are excluded. The Mac also requires local input opt-in and Accessibility permission. Pen pressure and palm rejection are not implemented.
- **BOOX refresh mode** probes the actual firmware's public `android.onyx.optimization.EInkHelper` API. Available symbolic modes are Normal, DU, A2, Regal, X and Regal Plus. Mode changes happen only after user selection. A delayed readback confirms the reported mode; exceptions and unavailable services fall back to system controls. Existing BOOX mode is preserved on launch. Fast modes can reduce image detail/color quality.
- **Full refresh** appears only when the official `EpdController.invalidate(View, UpdateMode.GC)` SDK API is actually available. On firmware without that API, **E Ink Center…** explains how to use BOOX Control Center and offers system settings. The observed Note Air4 C firmware's direct `ViewUpdateHelper.fullRefreshScreen` API is blocked; the app does not bypass Android's hidden-API restrictions or label an ordinary bitmap redraw as a panel refresh.

Official BOOX references: [EPD screen update API](https://github.com/onyx-intl/OnyxAndroidDemo/blob/master/doc/EPD-Screen-Update.md), [refresh-mode demo](https://github.com/onyx-intl/OnyxAndroidDemo/blob/master/app/OnyxAndroidDemo/src/main/java/com/android/onyx/demo/RefreshModeDemoActivity.java). Public firmware method availability was checked independently on the connected tablet; visual refresh effectiveness still needs device observation.

## Transport and lifecycle guarantees

The HTTPS client checks certificate validity dates and a constant-time SHA-256 match of the exact leaf certificate. Its hostname verifier only accepts the configured host after rechecking that pin. This supports a locally generated self-signed Mac certificate without disabling server identity verification. The custom TLS policy applies only to this session's connections. HTTP redirects are rejected and the token is never forwarded to another URL. Plain HTTP is accepted only for `127.0.0.1:8787`; LAN HTTP is rejected.

There is one network/decode worker, one in-flight request, one displayed bitmap and at most one pending bitmap. New pending frames replace older pending frames. Input and settings are also bounded to their latest pending event. Responses are capped at 64 KiB for JSON and 12 MiB for JPEG, with dimension/decode limits. Connection/read timeouts are 2.5/3.5 seconds. Failures back off to 1.5-second retries. The receiver stops and cancels its connection when paused and starts a fresh session on resume. Session generations prevent stale frames from being displayed after reconnecting. The foreground Activity keeps the screen awake. If capture stops, Screen Recording permission is absent, or the connection fails, the app clears displayed/pending frames and suppresses input. Frames resume only after status reports capture and permission ready. Native diagnostics log the first actual Canvas draw dimensions once per session and received/requested FPS no more often than every five seconds; they contain no token or image content.

## Validation

The native APK builds successfully with the project-local toolchain. Android lint completes with no errors; remaining warnings concern the intentional custom certificate-pin TrustManager, English UI strings and backwards-compatible Android attributes. The native JVM tests check endpoint restrictions, tokens, pin normalization, matching/mismatching certificate pins and certificate expiration (18 checks).

The initial build alone does not verify physical e-ink response, networking on the tablet, or refresh-mode changes. Hardware acceptance checks are:

1. Install and provision over USB, verify native fullscreen color capture and token authentication.
2. Provision pinned Wi-Fi, unplug USB and confirm frames continue. A wrong pin must fail closed.
3. Change FPS, color and width; compare reported received rate rather than assuming 60 FPS.
4. Pause/background and resume; reconnect USB/Wi-Fi without showing stale session frames.
5. Verify tap/scroll mapping in portrait and landscape with Mac input opt-in.
6. Inspect BOOX mode readback and panel appearance. Use E Ink Center for full refresh when direct support is unavailable.
