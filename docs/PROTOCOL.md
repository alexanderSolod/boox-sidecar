# BOOX Sidecar v0.3 — protocol 1

Application version 0.3 retains wire protocol 1 and adds optional status fields. Defaults are color (`grayscale=false`), `maxWidth=1240`, and up to 60 requested frames per second. Requested capture/poll FPS is not a guarantee of delivered frames or physical e-ink refresh.

## Transports and pairing

- **USB:** loopback HTTP at `127.0.0.1:8787`; `adb reverse tcp:8787 tcp:8787` forwards the tablet's loopback port to the Mac. The browser remains an optional USB fallback.
- **Wi-Fi:** a separate TLS listener on port 8788, enabled explicitly in the Mac app. USB provisioning transfers the Mac endpoint, persistent pairing token and SHA-256 certificate fingerprint to the native Android app. Both devices need a reachable network route. No cloud relay is involved.
- The legacy `--lan` option exposes development-only plaintext HTTP. It is separate from encrypted Wi-Fi, and the native receiver rejects non-loopback plaintext HTTP. Do not use `--lan` for normal wireless pairing.

Normal launches load or securely create a persistent random 32-byte token encoded as 64 hexadecimal characters. It is stored in `~/Library/Application Support/BOOX Sidecar/pairing-token` with mode 0600 inside a mode-0700 directory. Invalid saved credentials fail closed; **Forget pairing** rotates the credential and stops sharing. Demo mode uses an ephemeral credential and does not read or overwrite the saved one. All `/api/` requests require `Authorization: Bearer TOKEN`; tokens never appear in API query strings. Static viewer resources and `GET /health` are public. A normal host restart preserves pairing; credential rotation requires pairing again.

The native Activity accepts provisioning extras `host`, `token`, `host_id`, and, for HTTPS, `cert_sha256`. HTTPS requires the normalized `host_id` and certificate pin to agree. USB may use a separate stable host identity when TLS is unavailable. The pin is SHA-256 over the exact leaf certificate's DER encoding. Endpoint, token and pin are validated before changes are stored. USB and Wi-Fi configurations are retained in private app storage with backup/device-transfer exclusions. Auto mode tries USB loopback first, then discovered/saved HTTPS routes. It periodically probes USB while on Wi-Fi and verifies authenticated `host_id` before changing routes. Explicit USB-only and Wi-Fi-only preferences remain available. It never falls back to plaintext LAN HTTP. Clearing saved pairing removes stored credentials.

The Android HTTPS client checks certificate validity and constant-time pin equality. Its connection-scoped hostname verifier accepts only the configured host after checking the pin. Redirects are rejected. No system-wide trust or hostname-verification override is installed. The Mac stores its app-local certificate/private key under `~/Library/Application Support/BOOX Sidecar/TLS`, using restrictive file permissions. The identity persists across launches; changing it requires re-pairing. TLS import is memory-only and requires macOS 15+; USB supports macOS 14+.

The Mac **Connect** action prepares the extended desktop/capture and TLS listener, establishes ADB reverse, provisions authorized attached BOOX devices, and watches for USB reconnects. Disconnect stops capture, discovery/listening and the virtual display, retaining pairing. Bonjour advertises `_boox-sidecar._tcp.` on port 8788 with a public `host_id` TXT field and no bearer token. Discovery supplies candidate addresses only; matching the advertisement does not authenticate a server. The native client still requires its saved pin/token and authenticated status identity.

When TLS identity is available, `host_id` is the lowercase 64-hex SHA-256 certificate fingerprint. When TLS is unavailable, the USB-only host identity is SHA-256 over the persistent token's UTF-8 bytes. This public hash does not replace bearer authentication. A later TLS identity can change `host_id` and require USB reprovisioning.

The browser accepts a manual token or `#token=...`, removes a supplied token fragment from the address bar, and keeps credentials only in memory/sessionStorage. It does not provide native certificate pinning or BOOX hardware refresh control.

## HTTP contract

Responses use `Cache-Control: no-store` and `X-Content-Type-Options: nosniff`, without permissive CORS. Cross-origin state-changing requests are rejected. The default HTTP listener validates loopback Host headers. Requests are bounded to 64 KiB. Only `index.html`, `app.js`, and `style.css` are served as viewer resources; no directory traversal or arbitrary file serving.

| Endpoint | Response / behavior |
| --- | --- |
| `GET /health` | `{"ok":true,"protocol":1}` |
| `GET /api/status` | Status object below |
| `GET /api/displays` | `{"displays":[{"id":UInt32,"name":String,"width":Int,"height":Int}]}` |
| `POST /api/settings` | Partial settings object; returns status |
| `GET /api/frame?after=ID` | Latest JPEG newer than ID, or 204 if none; `after` is an integer >= -1 |
| `POST /api/input` | Tap or scroll; returns `{"ok":true}` or error |

Status fields:

```text
protocol: 1
capturing, permission, inputEnabled, demo: Bool
frameID, width, height, fps, maxWidth, jpegBytes: Int
jpegQuality, encodeMilliseconds: Number
grayscale: Bool
displayID, virtualDisplayID: UInt32
extendedDesktop, wirelessEnabled: Bool
wirelessAddresses: [String]
fingerprint, host_id, message: String
displayAsleep: Bool
position: "left" | "right"
```

`width`/`height` describe the latest encoded frame and can be zero before a frame exists. `displayAsleep` reports that macOS put the display to sleep: capture pauses and automatically resumes on wake, so a receiver should keep its last frame, reduce polling and avoid clearing to a blank screen. `extendedDesktop` means the selected source is the host-created virtual display. `virtualDisplayID=0` means none exists. `fingerprint` is public certificate identity, not a replacement for bearer authentication. `host_id` is a public, non-secret identity included in authenticated status and Bonjour; `/health` remains only `ok` and `protocol`. `jpegBytes` and `encodeMilliseconds` describe the latest frame, not end-to-end latency. Clients should tolerate additional fields.

Settings accept `fps` (integer 1–60), `grayscale` (Boolean), `maxWidth` (integer 600–2480), `jpegQuality` (number 0.4–0.95), and `displayID` (existing display). Unknown keys and invalid types/ranges are rejected. Changing capture settings restarts an active stream. Capture start/stop and virtual-display creation/removal remain local Mac actions; there is no remote capture-start endpoint.

JPEG responses carry `X-Frame-ID`, `X-Frame-Width`, and `X-Frame-Height`. HTTP/1.1 connections support keep-alive. The native client reuses its TLS socket factory and hostname verifier across requests. The host retains only the latest JPEG. Clients preserve aspect ratio, bound requests and decoding, and discard obsolete results after settings/session changes. The native receiver has one network/decode worker, one displayed bitmap and at most one pending bitmap; responses are capped at 64 KiB JSON / 12 MiB JPEG with additional decode bounds. It clears frames on capture stop, missing permission or connection failure. The browser keeps one frame fetch/decode in flight.

Input payloads:

```json
{"type":"tap","x":0.5,"y":0.5}
{"type":"scroll","deltaY":300}
```

Tap coordinates range from 0 to 1 within the actual image, excluding letterboxes, and map to the selected display's Mac bounds. Scroll ranges from -1000 to 1000; positive means up. The Mac requires local input opt-in, Accessibility permission and active non-demo capture. Invalid values are rejected; input denial returns 403.

Errors use `{"error":"human readable message"}`. Unknown paths return 404, wrong methods 405, missing/incorrect tokens 401. Clients handle missing permission/start, 204, reconnect, rotation and stale-session cancellation.

## Display and refresh integration

The Mac's isolated Objective-C backend creates a 1240 × 930 logical, 2480 × 1860 HiDPI virtual display at nominal 60 Hz, arranged to the right in extended rather than mirrored mode. This uses undocumented CoreGraphics interfaces and is experimental. It supplies a capture source; it does not determine the BOOX panel's waveform or physical refresh rate.

The native Android receiver renders bitmaps directly using Canvas, without WebView or JavaScript bridges. Optional refresh controls discover the firmware's public `android.onyx.optimization.EInkHelper` app-scoped APIs and symbolic mode constants. Existing mode is preserved until the user chooses another. **Faster panel…** explicitly requests X mode after explaining reduced detail/ghosting; stream presets never imply waveform changes. Readiness and delayed readback are required because vendor setters may swallow errors. Blocked hidden APIs are not bypassed. Full refresh is offered only when a supported SDK API exists; otherwise direct the user to BOOX E Ink Center. Browser **Reload frame** never means a hardware panel refresh.

## Packaging and demo

SwiftPM sources live in `macos/`; viewer resources are copied into `.app/Contents/Resources/viewer`. Development can supply `BOOX_VIEWER_PATH`. Android is a separate native APK.

`--demo` generates synthetic frames and reports `permission=true`, `demo=true` so clients can render without Screen Recording. This is not evidence of an actual macOS permission grant, live desktop capture, or physical BOOX performance.
