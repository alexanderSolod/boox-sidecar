# BOOX Sidecar native receiver

This is a dedicated Java Android app, not a browser or WebView. A custom Canvas view displays the Mac's latest JPEG while a single worker handles authenticated HTTP requests and bitmap decoding. USB uses `adb reverse`; both USB and Wi-Fi use HTTPS with a provisioned SHA-256 public-key/SPKI pin.

The app targets API 35 and supports API 26+. There are no third-party runtime libraries.

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

Start the Mac host and click **Connect** with the tablet attached over authorized USB. Both apps must support protocol 2; upgrading from protocol 1 requires pairing again. Auto prefers authenticated USB and then discovered or saved Wi-Fi. **Clear saved pairing** removes credentials.

Provisioning is restricted to callers holding `android.permission.DUMP`, including ADB. The public launcher ignores pairing extras. Invalid provisioning leaves the previous pairing intact, and manual replacement requires confirmation. See [the protocol](../docs/PROTOCOL.md#transports-and-pairing) for provisioning fields and trust requirements.

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

Official BOOX references: [EPD screen update API](https://github.com/onyx-intl/OnyxAndroidDemo/blob/master/doc/EPD-Screen-Update.md), [refresh-mode demo](https://github.com/onyx-intl/OnyxAndroidDemo/blob/master/app/OnyxAndroidDemo/src/main/java/com/android/onyx/demo/RefreshModeDemoActivity.java).

## Transport and lifecycle

USB and Wi-Fi use the same certificate-validity and public-key pin checks. Redirects and plaintext endpoints are rejected. Certificate renewal with the same key preserves trust; replacing the key requires pairing again.

The receiver bounds network requests and bitmap queues, discards obsolete capture sessions, and suppresses input when capture is unavailable. It stops its connection while paused and reconnects on resume. When the Mac display sleeps, it keeps the last frame, reduces polling, and releases its screen wake lock while staying connected. Capture resumes after the Mac wakes. Other capture stops, permission errors, and connection failures clear the frame.
