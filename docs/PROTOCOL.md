# BOOX Sidecar — protocol 2

Protocol 2 introduces authenticated native USB and versioned pairing. Defaults are color (`grayscale=false`), `maxWidth=1240`, and up to 60 requested frames per second. Requested capture/poll FPS is not a guarantee of delivered frames or physical e-ink refresh.

## Transports and pairing

Protocol 2 requires macOS 15+ and an updated native receiver. Upgrade both apps and re-pair once over authorized USB. Legacy saved records and plaintext native clients are rejected; there is no insecure compatibility fallback.

USB uses pinned TLS at `https://127.0.0.1:8787` over ADB reverse. Wi-Fi uses a separate optional TLS listener on 8788. `--port` and `--wifi-port` configure the respective endpoints; provisioning and Bonjour carry the actual ports. Turning off Wi-Fi does not disable secure USB. Discovery provides candidate addresses, never replacement trust.

The Mac persists an independent random installation ID and a 32-byte bearer credential (`pairing-token-v2`) under `~/Library/Application Support/BOOX Sidecar/`. Directory permissions are 0700; private files are 0600. The v2 credential replaces the old credential for authentication. Normal restarts retain pairing; **Forget pairing** stops sharing and rotates the token without changing the installation ID or key. A full identity reset requires trusted re-pairing. Demo and development-browser modes never read or write native pairing state.

A dedicated Android `.ProvisioningActivity` requires `android.permission.DUMP`. The public launcher ignores pairing extras. The restricted component validates a complete payload before committing saved state:

- `pairing_version`: integer 2.
- `host_id`: independent lowercase 64-hex installation ID, not an authentication secret.
- `token`: 64-hex bearer credential.
- `spki_sha256`: SHA-256 over the leaf certificate's DER SubjectPublicKeyInfo, encoded as lowercase hex.
- `usb_host`: HTTPS endpoint on 127.0.0.1 with an explicit port.
- `host`: primary HTTPS endpoint; optional `wifi_host` retains a Wi-Fi route even when USB is preferred.
- `preferred_transport`: `auto`, `usb`, or `wifi`.

Both native transports and Auto probes check certificate validity, the pinned public key, and TLS key possession before sending application credentials. Redirects are rejected. The connection-scoped hostname verifier uses the provisioned key as identity and restricts requests to the configured endpoint; no global TLS bypass is installed. Authenticated status must report protocol 2 and the saved installation ID. USB-only provisioning retains trust for subsequent Wi-Fi discovery.

The canonical TLS identity is published atomically as a private PKCS12 file, imported in memory. Certificates renew with the same key when fewer than 30 days remain, checked at startup and daily. Renewal failures retain an otherwise valid identity and are reported locally; expired identities stop native connections. Deliberate key replacement requires USB re-pairing. Neither a matching public host ID nor a discovery advertisement authorizes a key change.

Browser resources are available only with `--development-browser` or synthetic `--demo`. Development browser mode uses loopback HTTP and a disposable in-memory credential, can use locally approved real capture/input, and disables native provisioning and LAN listeners. Its insecure transport must not be used for normal native pairing. `--lan` is rejected. The browser removes a supplied `#token=...` fragment from its address bar and keeps the token in session storage.

## HTTP contract

Every `/api/` request requires `Authorization: Bearer TOKEN`; `/health` is public. Responses use `Cache-Control: no-store` and `X-Content-Type-Options: nosniff`, without permissive CORS. Cross-origin state-changing requests are rejected. Loopback listeners validate Host headers, including native USB TLS. Requests are bounded to 64 KiB. Only `index.html`, `app.js`, and `style.css` are served as viewer resources; no directory traversal or arbitrary file serving.

| Endpoint | Response / behavior |
| --- | --- |
| `GET /health` | `{"ok":true,"protocol":2}` |
| `GET /api/status` | Status object below |
| `GET /api/displays` | `{"displays":[{"id":UInt32,"name":String,"width":Int,"height":Int}]}` |
| `POST /api/settings` | Partial settings object; returns status |
| `GET /api/frame?after=ID` | Latest JPEG newer than ID, or 204 if none; `after` is an integer >= -1 |
| `POST /api/input` | Tap or scroll; returns `{"ok":true}` or error |

Status fields:

```text
protocol: 2
capturing, permission, inputEnabled, demo: Bool
frameID, width, height, fps, maxWidth, jpegBytes: Int
jpegQuality, encodeMilliseconds: Number
grayscale: Bool
displayID, virtualDisplayID: UInt32
extendedDesktop, wirelessEnabled: Bool
wirelessAddresses: [String]
spki_sha256, host_id, capture_session, message: String
displayAsleep: Bool
```

`width`/`height` describe the latest encoded frame and can be zero before a frame exists. `displayAsleep` reports that macOS put the display to sleep: capture pauses and automatically resumes on wake, so a receiver should keep its last frame, reduce polling and avoid clearing to a blank screen. `extendedDesktop` means the selected source is the host-created virtual display. `virtualDisplayID=0` means none exists. `spki_sha256` is the public-key pin, not a replacement for bearer authentication. `host_id` is a public, non-secret identity included in authenticated status and Bonjour; `/health` remains only `ok` and `protocol`. `jpegBytes` and `encodeMilliseconds` describe the latest frame, not end-to-end latency. Clients should tolerate additional fields.

Settings accept `fps` (integer 1–60), `grayscale` (Boolean), `maxWidth` (integer 600–2480), `jpegQuality` (number 0.4–0.95). Display selection is restricted to the local Mac UI. Any remote payload containing `displayID` is rejected with HTTP 403 before applying other fields. Unknown keys and invalid types/ranges are rejected. Changing capture settings restarts an active stream. Capture start/stop and virtual-display creation/removal remain local Mac actions; there is no remote capture-start endpoint.

JPEG responses carry `X-Frame-ID`, `X-Frame-Width`, `X-Frame-Height`, and `X-Capture-Session`. Status reports `capture_session` (empty while stopped); input requests must include the matching `capture_session`. Session changes invalidate pending frames and input. Stop, source loss, capture permission errors, and Forget pairing revoke queued sends and cancel sensitive connections. Already transmitted bytes cannot be retracted. HTTP/1.1 connections support keep-alive. The native client reuses its TLS socket factory and hostname verifier across requests. The host retains only the latest JPEG. Clients preserve aspect ratio, bound requests and decoding, and discard obsolete results after settings/session changes. The native receiver has one network/decode worker, one displayed bitmap and at most one pending bitmap; responses are capped at 64 KiB JSON / 12 MiB JPEG with additional decode bounds. It retains the last frame while `displayAsleep` is true, and otherwise clears frames on capture stop, missing permission or connection failure. The browser keeps one frame fetch/decode in flight.

Input payloads:

```json
{"type":"tap","x":0.5,"y":0.5,"capture_session":"CURRENT_SESSION_FROM_STATUS"}
{"type":"scroll","deltaY":300,"capture_session":"CURRENT_SESSION_FROM_STATUS"}
```

Tap coordinates range from 0 to 1 within the actual image, excluding letterboxes, and map to the selected display's Mac bounds. Scroll ranges from -1000 to 1000; positive means up. The Mac requires local input opt-in, Accessibility permission and active non-demo capture. Invalid values are rejected; input denial returns 403.

Errors use `{"error":"human readable message"}`. Unknown paths return 404, wrong methods 405, missing/incorrect tokens 401. Clients handle missing permission/start, 204, reconnect, rotation and stale-session cancellation.

## Display and refresh integration

The Mac's isolated Objective-C backend creates a 1240 × 930 logical, 2480 × 1860 HiDPI virtual display at nominal 60 Hz arranged to the right in extended rather than mirrored mode. This uses undocumented CoreGraphics interfaces and is experimental. It supplies a capture source; it does not determine the BOOX panel's waveform or physical refresh rate.

The native Android receiver renders bitmaps directly using Canvas, without WebView or JavaScript bridges. Optional refresh controls discover the firmware's public `android.onyx.optimization.EInkHelper` app-scoped APIs and symbolic mode constants. Existing mode is preserved until the user chooses another. **Faster panel…** explicitly requests X mode after explaining reduced detail/ghosting; stream presets never imply waveform changes. Readiness and delayed readback are required because vendor setters may swallow errors. Blocked hidden APIs are not bypassed. Full refresh is offered only when a supported SDK API exists; otherwise direct the user to BOOX E Ink Center. Browser **Reload frame** never means a hardware panel refresh.

## Packaging and demo

SwiftPM sources live in `macos/`; viewer resources are copied into `.app/Contents/Resources/viewer`. Development can supply `BOOX_VIEWER_PATH`. Android is a separate native APK.

`--demo` generates synthetic frames and reports `permission=true`, `demo=true` so clients can render without Screen Recording. This is not evidence of an actual macOS permission grant, live desktop capture, or physical BOOX performance.
