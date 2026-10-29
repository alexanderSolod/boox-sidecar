import AppKit
import ApplicationServices
import SwiftUI
import VirtualDisplayKit
import CryptoKit

struct DisplayInfo: Identifiable {
    let id: CGDirectDisplayID
    let name: String
    let width: Int
    let height: Int
    var json: [String: Any] { ["id": id, "name": name, "width": width, "height": height] }
}

@MainActor final class HostModel: ObservableObject {
    @Published var displays: [DisplayInfo] = []
    @Published var displayID: CGDirectDisplayID = CGMainDisplayID()
    @Published var fps = 60
    @Published var grayscale = false
    @Published var jpegQuality = 0.70
    @Published var maxWidth = 1240
    @Published var capturing = false
    @Published var starting = false
    @Published var permission = CGPreflightScreenCaptureAccess()
    @Published var inputEnabled = false
    @Published var message = "Connect your BOOX over USB, then start sharing a display."
    @Published var frameID = 0
    @Published var serverReady = false
    @Published var virtualDisplayID: CGDirectDisplayID = 0
    @Published var creatingExtendedDisplay = false
    @Published var pairingDevice = false
    @Published var wirelessEnabled = false
    @Published var fingerprint = ""
    @Published var wirelessMessage = ""
    let virtualDisplay = BXVirtualDisplayController()
    @Published private(set) var token: String
    @Published var connecting = false
    @Published var connectionRequested = false
    @Published var connectionMessage = "Open the BOOX app, then click Connect. First-time pairing needs USB."
    @Published var wirelessStarting = false
    @Published var displayAsleep = false
    private var sleepWasSharing = false
    private var workspaceObservers: [NSObjectProtocol] = []
    private let credentialStore: PairingCredentialStore?
    private let advertiser = BonjourAdvertiser()
    private var connectionTask: Task<Void, Never>?
    private var usbWatcher: Task<Void, Never>?
    private var seenUSBDevices = Set<String>()
    private var wirelessGeneration = 0
    var hostID: String {
        if !fingerprint.isEmpty { return fingerprint.lowercased().replacingOccurrences(of: ":", with: "") }
        // USB remains usable when TLS cannot load (including macOS 14). The
        // random credential has 256 bits of entropy; its hash reveals no secret.
        return SHA256.hash(data: Data(token.utf8)).map { String(format: "%02x", $0) }.joined()
    }
    let port: UInt16
    let lan: Bool
    let demo: Bool
    private let server = HTTPServer()
    private let wirelessServer = HTTPServer()
    private var capture: ScreenCapture?
    private var generation = 0
    private var frame: CapturedFrame?
    private var demoTimer: Timer?
    var viewerURL: String { "http://127.0.0.1:\(port)/#token=\(token)" }

    init() {
        let args = CommandLine.arguments
        demo = args.contains("--demo")
        lan = args.contains("--lan")
        if let index = args.firstIndex(of: "--port"), args.indices.contains(index + 1), let value = UInt16(args[index + 1]), value > 0 { port = value } else { port = 8787 }
        if demo { credentialStore = nil }
        else {
            let directory: URL
            if let index = args.firstIndex(of: "--pairing-directory"), args.indices.contains(index + 1) { directory = URL(fileURLWithPath: args[index + 1], isDirectory: true) }
            else { directory = PairingCredentialStore.applicationDirectory }
            credentialStore = PairingCredentialStore(directory: directory)
        }
        var credentialFailure: String?
        do { token = try credentialStore?.loadOrCreate() ?? PairingCredentialStore.randomToken() }
        catch { token = ""; credentialFailure = error.localizedDescription }
        if !demo {
            let prefs = UserDefaults.standard
            if let value = prefs.object(forKey: "capture.fps") as? Int, (1...60).contains(value) { fps = value }
            if let value = prefs.object(forKey: "capture.width") as? Int, (600...2480).contains(value) { maxWidth = value }
            if prefs.object(forKey: "capture.grayscale") != nil { grayscale = prefs.bool(forKey: "capture.grayscale") }
            if let value = prefs.object(forKey: "capture.jpegQuality") as? Double, (0.4...0.95).contains(value) { jpegQuality = value }
        }
        refreshDisplays()
        if let credentialFailure { message = credentialFailure; connectionMessage = credentialFailure }
        server.handler = { [weak self] request, reply in
            Task { @MainActor in reply(self?.handle(request) ?? .error("Host unavailable", status: 503)) }
        }
        server.onReady = { [weak self] in Task { @MainActor in self?.serverReady = true } }
        server.onError = { [weak self] text in Task { @MainActor in self?.message = "Server: \(text)"; self?.serverReady = false } }
        do {
            if !token.isEmpty { try server.start(port: port, lan: lan) }
            // CLI output is intentionally a local pairing credential; never transmitted to a third party.
            if demo { print("BOOX Sidecar DEMO viewer: \(viewerURL)"); fflush(stdout) }
        } catch { message = "Unable to start server: \(error.localizedDescription)" }
        if demo { startDemo() }
        if !token.isEmpty, args.contains("--wireless") { enableWireless(true) }
        if !token.isEmpty, args.contains("--extended"), !demo {
            Task { await createExtendedDisplay(requestPermission: false) }
        }
        let center = NSWorkspace.shared.notificationCenter
        workspaceObservers.append(center.addObserver(forName: NSWorkspace.screensDidSleepNotification, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in self?.displayDidSleep() }
        })
        workspaceObservers.append(center.addObserver(forName: NSWorkspace.screensDidWakeNotification, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in self?.displayDidWake() }
        })
        // System sleep wakes through a different notification than display sleep.
        workspaceObservers.append(center.addObserver(forName: NSWorkspace.didWakeNotification, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in self?.displayDidWake() }
        })
    }

    deinit { workspaceObservers.forEach { NSWorkspace.shared.notificationCenter.removeObserver($0) } }

    private func displayDidSleep() {
        displayAsleep = true
        sleepWasSharing = connectionRequested || capturing || starting
        if capturing || starting {
            stop()
            message = "Display asleep. Sharing pauses until the display wakes."
        }
    }

    private func displayDidWake() {
        displayAsleep = false
        refreshDisplays()
        let virtualAlive = virtualDisplayID != 0 && displays.contains(where: { $0.id == virtualDisplayID })
        if connectionRequested {
            if virtualAlive {
                displayID = virtualDisplayID
                // A ScreenCaptureKit stream can silently die across sleep;
                // always rebuild it rather than trusting a stale flag.
                if capturing || starting { stop() }
                start()
            } else {
                virtualDisplayID = 0
                if demo { start() }
                else { Task { await createExtendedDisplay(requestPermission: false) } }
            }
        } else if sleepWasSharing {
            if capturing || starting { stop() }
            start()
        }
        sleepWasSharing = false
    }

    func refreshDisplays() {
        var count: UInt32 = 0
        CGGetActiveDisplayList(0, nil, &count)
        var ids = [CGDirectDisplayID](repeating: 0, count: Int(count))
        CGGetActiveDisplayList(count, &ids, &count)
        displays = ids.prefix(Int(count)).enumerated().map { index, id in
            DisplayInfo(id: id, name: id == virtualDisplayID ? "BOOX Extended Desktop" : "Display \(index + 1)\(id == CGMainDisplayID() ? " (main)" : "")", width: CGDisplayPixelsWide(id), height: CGDisplayPixelsHigh(id))
        }
        if !displays.contains(where: { $0.id == displayID }) {
            if capturing || starting { stop(); message = "Selected display disconnected. Choose a display and start sharing again." }
            if let first = displays.first { displayID = first.id }
        }
        // A running ScreenCaptureKit stream is authoritative. Legacy preflight
        // can remain stale after permission changes on recent macOS releases.
        if !capturing && !starting { permission = CGPreflightScreenCaptureAccess() }
    }

    func createExtendedDisplay(requestPermission: Bool = true) async {
        guard !creatingExtendedDisplay, !demo else { return }
        creatingExtendedDisplay = true
        defer {
            creatingExtendedDisplay = false
            if Task.isCancelled {
                stop(); virtualDisplay.removeDisplay(); virtualDisplayID = 0; refreshDisplays()
            }
        }
        let id = virtualDisplay.createExtendedDisplay()
        guard id != 0 else { message = virtualDisplay.lastError ?? "Virtual display creation failed."; return }
        virtualDisplayID = id
        // WindowServer and ScreenCaptureKit discover new displays asynchronously.
        for _ in 0..<20 {
            if Task.isCancelled { return }
            refreshDisplays()
            if displays.contains(where: { $0.id == id }) { break }
            try? await Task.sleep(nanoseconds: 150_000_000)
        }
        guard displays.contains(where: { $0.id == id }) else {
            virtualDisplay.removeDisplay(); virtualDisplayID = 0
            message = "The new display did not become available. Try creating it again."
            return
        }
        // A registered display can still be mid-configuration. Let WindowServer
        // finish publishing it before committing its session-only arrangement.
        var arranged = false
        for _ in 0..<20 {
            if Task.isCancelled { return }
            if virtualDisplay.arrangeExtendedDisplay() { arranged = true; break }
            try? await Task.sleep(nanoseconds: 150_000_000)
        }
        guard arranged else {
            let failure = virtualDisplay.lastError ?? "Could not arrange the extended desktop."
            virtualDisplay.removeDisplay(); virtualDisplayID = 0
            refreshDisplays()
            message = failure
            return
        }
        if capturing || starting { stop() }
        displayID = id
        message = "Extended desktop created to the right of your main display. Move windows onto it."
        try? await Task.sleep(nanoseconds: 300_000_000)
        guard !Task.isCancelled else { return }
        if requestPermission || CGPreflightScreenCaptureAccess() { start() }
        else { message = "Extended desktop is ready. Click Start capture to grant Screen Recording permission." }
    }

    func removeExtendedDisplay() {
        guard !creatingExtendedDisplay else { return }
        if displayID == virtualDisplayID { stop() }
        virtualDisplay.removeDisplay()
        virtualDisplayID = 0
        refreshDisplays()
        message = "BOOX extended display removed."
    }

    func enableWireless(_ enabled: Bool) {
        if !enabled {
            wirelessGeneration += 1
            advertiser.stop()
            wirelessServer.stop()
            wirelessStarting = false
            wirelessEnabled = false
            wirelessMessage = "Encrypted Wi-Fi is off."
            return
        }
        guard !wirelessEnabled, !wirelessStarting else { return }
        wirelessStarting = true
        wirelessGeneration += 1
        let attempt = wirelessGeneration
        do {
            let args = CommandLine.arguments
            let directory: URL?
            if let index = args.firstIndex(of: "--tls-directory"), args.indices.contains(index + 1) {
                directory = URL(fileURLWithPath: args[index + 1], isDirectory: true)
            } else { directory = nil }
            let tls = try TLSIdentity.load(directory: directory)
            fingerprint = tls.fingerprint
            wirelessServer.handler = { [weak self] request, reply in
                Task { @MainActor in reply(self?.handle(request) ?? .error("Host unavailable", status: 503)) }
            }
            wirelessServer.onReady = { [weak self] in Task { @MainActor in
                guard let self, self.wirelessGeneration == attempt else { return }
                self.wirelessStarting = false
                self.wirelessEnabled = true
                self.advertiser.onError = { [weak self] text in self?.wirelessMessage = text }
                self.advertiser.start(hostID: self.hostID)
                self.wirelessMessage = "Encrypted Wi-Fi and automatic discovery are ready."
            } }
            wirelessServer.onError = { [weak self] text in Task { @MainActor in
                guard let self, self.wirelessGeneration == attempt else { return }
                self.wirelessStarting = false
                self.wirelessEnabled = false
                self.advertiser.stop()
                self.wirelessMessage = "Wi-Fi: \(text)"
            } }
            try wirelessServer.start(port: 8788, lan: true, tlsIdentity: tls.identity)
            wirelessMessage = "Starting encrypted Wi-Fi…"
        } catch { wirelessStarting = false; wirelessEnabled = false; wirelessMessage = "Wi-Fi unavailable: \(error.localizedDescription)" }
    }

    func connect() {
        guard !connecting, !token.isEmpty else { return }
        if demo {
            connectionRequested = true
            if !capturing { startDemo() }
            connectionMessage = "Synthetic demo is ready. No BOOX pairing or screen capture is performed."
            return
        }
        connectionRequested = true
        connecting = true
        connectionMessage = "Preparing your BOOX desktop…"
        connectionTask?.cancel()
        connectionTask = Task {
            defer { connecting = false }
            for _ in 0..<30 {
                if serverReady { break }
                if Task.isCancelled { return }
                try? await Task.sleep(nanoseconds: 100_000_000)
            }
            guard serverReady else { connectionRequested = false; connectionMessage = "The local server is unavailable. " + message; return }
            enableWireless(true)
            if demo { start() } else { await createExtendedDisplay() }
            for _ in 0..<100 {
                if !starting || Task.isCancelled { break }
                try? await Task.sleep(nanoseconds: 100_000_000)
            }
            guard !Task.isCancelled, connectionRequested else { return }
            if starting {
                stop(); connectionRequested = false
                connectionMessage = "macOS is still waiting to start capture. Finish any Screen Recording permission prompt, then click Connect again."
                return
            }
            guard capturing else { connectionRequested = false; connectionMessage = message; return }
            for _ in 0..<100 {
                if !wirelessStarting || Task.isCancelled { break }
                try? await Task.sleep(nanoseconds: 100_000_000)
            }
            guard !Task.isCancelled else { return }
            await checkUSB(explicit: true)
            guard !Task.isCancelled, connectionRequested else { return }
            usbWatcher?.cancel()
            usbWatcher = Task { [weak self] in
                while !Task.isCancelled {
                    try? await Task.sleep(nanoseconds: 3_000_000_000)
                    guard let self, !Task.isCancelled, self.connectionRequested else { return }
                    await self.checkUSB(explicit: false)
                }
            }
        }
    }

    func disconnect() {
        connectionRequested = false
        connectionTask?.cancel(); connectionTask = nil
        usbWatcher?.cancel(); usbWatcher = nil
        seenUSBDevices.removeAll()
        connecting = false
        stop()
        enableWireless(false)
        if !creatingExtendedDisplay { removeExtendedDisplay() }
        connectionMessage = "Disconnected. Pairing is remembered for next time."
    }

    private func checkUSB(explicit: Bool) async {
        guard !pairingDevice else { return }
        pairingDevice = true
        defer { pairingDevice = false }
        let pairPort = port, pairToken = token, pin = fingerprint.isEmpty ? nil : fingerprint, identity = hostID
        let address = wirelessAddresses.first
        let pairHost = wirelessEnabled && address != nil ? "https://\(address!):8788" : "http://127.0.0.1:\(port)"
        let oldDevices = seenUSBDevices
        do {
            let worker = Task.detached(priority: .utility) { () throws -> (Set<String>, Int, String?) in
                let devices = try DevicePairing.discover()
                var provisioned = 0
                var pairingError: String?
                for device in devices {
                    try Task.checkCancellation()
                    do {
                        try DevicePairing.ensureReverse(device: device, port: pairPort)
                        if explicit || !oldDevices.contains(device.serial) {
                            try Task.checkCancellation()
                            try DevicePairing.provision(device: device, port: pairPort, host: pairHost, token: pairToken, fingerprint: pin, hostID: identity)
                            provisioned += 1
                        }
                    } catch is CancellationError { throw CancellationError() }
                    catch { if explicit || !oldDevices.contains(device.serial) { pairingError = error.localizedDescription } }
                }
                return (Set(devices.map(\.serial)), provisioned, pairingError)
            }
            let result = try await withTaskCancellationHandler(operation: { try await worker.value }, onCancel: { worker.cancel() })
            guard connectionRequested, !Task.isCancelled else { return }
            seenUSBDevices = result.0
            if let error = result.2 { connectionMessage = "Desktop ready. " + error }
            else if result.1 > 0 { connectionMessage = "BOOX app paired for USB and Wi-Fi. Your desktop is ready; confirm the app displays it." }
            else if explicit { connectionMessage = wirelessEnabled ? "Desktop ready. Open the remembered BOOX app to reconnect over Wi-Fi, or plug in USB to pair." : "Desktop ready for USB. " + wirelessMessage }
        } catch {
            guard connectionRequested, !Task.isCancelled else { return }
            if explicit { connectionMessage = (wirelessEnabled ? "Desktop ready for remembered Wi-Fi. " : "") + error.localizedDescription }
        }
    }

    func forgetPairing() {
        disconnect()
        do {
            token = try credentialStore?.rotate() ?? PairingCredentialStore.randomToken()
            if !serverReady {
                try server.start(port: port, lan: lan)
            }
            connectionMessage = "Pairing forgotten. Connect the BOOX by USB and click Connect to pair again."
        } catch { connectionMessage = error.localizedDescription }
    }

    func applyProfile(_ name: String) {
        fps = 60
        switch name {
        case "Speed": maxWidth = 1240; grayscale = false; jpegQuality = 0.60
        case "Sharp text": maxWidth = 2480; grayscale = true; jpegQuality = 0.88
        default: maxWidth = 1240; grayscale = false; jpegQuality = 0.78
        }
        applySettings()
    }

    var wirelessAddresses: [String] { DevicePairing.addresses }

    func pairBOOX(useWiFi: Bool) {
        guard !pairingDevice else { return }
        let host: String
        let certificate: String?
        if useWiFi {
            guard wirelessEnabled, !fingerprint.isEmpty, let address = wirelessAddresses.first else {
                message = "Enable encrypted Wi-Fi and connect the Mac to your network first."
                return
            }
            host = "https://\(address):8788"
            certificate = fingerprint
        } else { host = "http://127.0.0.1:\(port)"; certificate = fingerprint.isEmpty ? nil : fingerprint }
        pairingDevice = true
        let pairPort = port, pairToken = token, pairID = hostID
        Task {
            do {
                try await Task.detached(priority: .userInitiated) {
                    try DevicePairing.pair(port: pairPort, host: host, token: pairToken, fingerprint: certificate, hostID: pairID, preferUSB: !useWiFi)
                }.value
                message = useWiFi ? "Wi-Fi pairing sent to the BOOX app. Confirm it connects, then unplug USB." : "USB pairing sent to the BOOX app."
            } catch { message = error.localizedDescription }
            pairingDevice = false
        }
    }

    func copyFingerprint() { NSPasteboard.general.clearContents(); NSPasteboard.general.setString(fingerprint, forType: .string) }

    func start() {
        guard !starting, !capturing else { return }
        if demo { startDemo(); return }
        // An explicit Start request reaches ScreenCaptureKit directly. Its
        // SCShareableContent/SCStream calls enforce consent and can present the
        // system permission prompt; a stale CGPreflight result must not block it.
        generation += 1
        let currentGeneration = generation
        let session = ScreenCapture()
        capture = session
        starting = true
        message = "Starting capture…"
        session.onFrame = { [weak self] frame in
            Task { @MainActor in
                guard let self, self.generation == currentGeneration else { return }
                self.frame = frame
                self.frameID += 1
            }
        }
        session.onError = { [weak self] text in
            Task { @MainActor in
                guard let self, self.generation == currentGeneration else { return }
                self.stop()
                self.message = "Capture stopped: \(text)"
            }
        }
        let id = displayID, rate = fps, width = maxWidth, gray = grayscale, quality = jpegQuality
        Task {
            do {
                try await session.start(displayID: id, fps: rate, maxWidth: width, grayscale: gray, jpegQuality: quality)
                guard generation == currentGeneration else { await session.stop(); return }
                starting = false
                capturing = true
                permission = true
                message = "Sharing the selected display. Keep private content off that display."
            } catch {
                guard generation == currentGeneration else { return }
                starting = false
                capturing = false
                capture = nil
                permission = CGPreflightScreenCaptureAccess()
                let failure = error as NSError
                message = "ScreenCaptureKit failed (\(failure.domain), \(failure.code)): \(error.localizedDescription)"
            }
        }
    }

    func stop() {
        generation += 1
        demoTimer?.invalidate()
        demoTimer = nil
        let oldCapture = capture
        capture = nil
        starting = false
        capturing = false
        frame = nil
        message = "Sharing stopped."
        Task { await oldCapture?.stop() }
    }

    func applySettings() {
        if !demo {
            let prefs = UserDefaults.standard
            prefs.set(fps, forKey: "capture.fps")
            prefs.set(maxWidth, forKey: "capture.width")
            prefs.set(grayscale, forKey: "capture.grayscale")
            prefs.set(jpegQuality, forKey: "capture.jpegQuality")
        }
        if capturing || starting { stop(); start() }
    }

    func enableInput(_ enabled: Bool) {
        if enabled {
            let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
            inputEnabled = AXIsProcessTrustedWithOptions(options)
            if !inputEnabled { message = "Allow Accessibility in System Settings, then enable remote input again." }
        } else { inputEnabled = false }
    }

    func copyLink() { NSPasteboard.general.clearContents(); NSPasteboard.general.setString(viewerURL, forType: .string) }
    func copyToken() { NSPasteboard.general.clearContents(); NSPasteboard.general.setString(token, forType: .string) }

    private func status() -> [String: Any] {
        ["protocol": 1, "capturing": capturing, "permission": demo || permission, "demo": demo, "inputEnabled": inputEnabled && AXIsProcessTrusted(), "frameID": frameID, "width": frame?.width ?? 0, "height": frame?.height ?? 0, "fps": fps, "maxWidth": maxWidth, "jpegQuality": jpegQuality, "jpegBytes": frame?.jpeg.count ?? 0, "encodeMilliseconds": frame?.encodingMilliseconds ?? 0, "grayscale": grayscale, "displayID": displayID, "virtualDisplayID": virtualDisplayID, "extendedDesktop": displayID == virtualDisplayID && virtualDisplayID != 0, "wirelessEnabled": wirelessEnabled, "wirelessAddresses": wirelessAddresses, "fingerprint": fingerprint, "host_id": hostID, "displayAsleep": displayAsleep, "message": message]
    }

    private func handle(_ request: HTTPRequest) -> HTTPResponse {
        // Prevent DNS rebinding in default loopback mode.
        if !lan && !request.secure {
            let allowed = ["127.0.0.1:\(port)", "localhost:\(port)"]
            guard let host = request.headers["host"], allowed.contains(host.lowercased()) else { return .error("Invalid Host", status: 403) }
        }
        if request.path.hasPrefix("/api/") {
            guard request.headers["authorization"] == "Bearer \(token)" else { return .error("Pairing token required", status: 401) }
        }
        if request.method != "GET" {
            if let origin = request.headers["origin"] {
                guard let url = URLComponents(string: origin), url.scheme == (request.secure ? "https" : "http"), let host = url.host,
                      "\(host):\(url.port ?? (request.secure ? 443 : 80))" == request.headers["host"] else { return .error("Cross-origin request rejected", status: 403) }
            }
            if let site = request.headers["sec-fetch-site"], site != "same-origin" && site != "none" { return .error("Cross-origin request rejected", status: 403) }
        }
        let getPaths = ["/health", "/api/status", "/api/displays", "/api/frame", "/", "/index.html", "/app.js", "/style.css"]
        let postPaths = ["/api/settings", "/api/input"]
        if getPaths.contains(request.path) && request.method != "GET" || postPaths.contains(request.path) && request.method != "POST" { return .error("Method not allowed", status: 405) }
        switch request.path {
        case "/health": return .json(["ok": true, "protocol": 1])
        case "/api/status": return .json(status())
        case "/api/displays": return .json(["displays": displays.map(\.json)])
        case "/api/frame":
            guard let after = Int(request.query["after"] ?? "-1"), after >= -1 else { return .error("Invalid frame ID", status: 400) }
            guard let frame, frameID > after else { return HTTPResponse(status: 204) }
            return HTTPResponse(type: "image/jpeg", headers: ["X-Frame-ID": String(frameID), "X-Frame-Width": String(frame.width), "X-Frame-Height": String(frame.height)], body: frame.jpeg)
        case "/api/settings", "/api/input":
            guard request.headers["content-type"]?.lowercased().hasPrefix("application/json") == true,
                  let object = try? JSONSerialization.jsonObject(with: request.body) as? [String: Any] else { return .error("Expected JSON object", status: 400) }
            return request.path == "/api/settings" ? settings(object) : input(object)
        case "/", "/index.html", "/app.js", "/style.css":
            let filename = request.path == "/" ? "index.html" : String(request.path.dropFirst())
            let root: URL
            if let path = ProcessInfo.processInfo.environment["BOOX_VIEWER_PATH"] { root = URL(fileURLWithPath: path, isDirectory: true) }
            else { root = (Bundle.main.resourceURL ?? Bundle.main.bundleURL).appendingPathComponent("viewer", isDirectory: true) }
            guard let data = try? Data(contentsOf: root.appendingPathComponent(filename)) else { return .error("Viewer resources missing. Build the app bundle or set BOOX_VIEWER_PATH.", status: 503) }
            let type = filename.hasSuffix(".js") ? "application/javascript; charset=utf-8" : filename.hasSuffix(".css") ? "text/css; charset=utf-8" : "text/html; charset=utf-8"
            return HTTPResponse(type: type, headers: ["Content-Security-Policy": "default-src 'self'; img-src 'self' blob:; style-src 'self'; script-src 'self'; connect-src 'self'; frame-ancestors 'none'; base-uri 'none'; form-action 'none'"], body: data)
        default: return .error("Not found", status: 404)
        }
    }

    private func number(_ value: Any?) -> Double? {
        guard let value = value as? NSNumber, CFGetTypeID(value) != CFBooleanGetTypeID(), value.doubleValue.isFinite else { return nil }
        return value.doubleValue
    }

    private func settings(_ object: [String: Any]) -> HTTPResponse {
        guard Set(object.keys).isSubset(of: ["fps", "grayscale", "maxWidth", "displayID", "jpegQuality"]) else { return .error("Unknown setting", status: 400) }
        var newFPS = fps, newWidth = maxWidth, newGray = grayscale, newID = displayID
        var newQuality = jpegQuality
        if let raw = object["fps"] {
            guard let value = number(raw), (1...60).contains(value), value.rounded() == value else { return .error("fps must be an integer from 1 to 60", status: 400) }
            newFPS = Int(value)
        }
        if let raw = object["jpegQuality"] {
            guard let value = number(raw), (0.4...0.95).contains(value) else { return .error("jpegQuality must be from 0.4 to 0.95", status: 400) }
            newQuality = value
        }
        if let raw = object["maxWidth"] {
            guard let value = number(raw), (600...2480).contains(value), value.rounded() == value else { return .error("maxWidth must be an integer from 600 to 2480", status: 400) }
            newWidth = Int(value)
        }
        if let raw = object["grayscale"] {
            guard let value = raw as? NSNumber, CFGetTypeID(value) == CFBooleanGetTypeID() else { return .error("grayscale must be boolean", status: 400) }
            newGray = value.boolValue
        }
        if let raw = object["displayID"] {
            guard let value = number(raw), value >= 0, value <= Double(UInt32.max), value.rounded() == value,
                  displays.contains(where: { $0.id == UInt32(value) }) else { return .error("Unknown display", status: 400) }
            newID = UInt32(value)
        }
        let changed = jpegQuality != newQuality || fps != newFPS || maxWidth != newWidth || grayscale != newGray || displayID != newID
        jpegQuality = newQuality; fps = newFPS; maxWidth = newWidth; grayscale = newGray; displayID = newID
        if changed { applySettings() }
        return .json(status())
    }

    private func input(_ object: [String: Any]) -> HTTPResponse {
        guard inputEnabled, AXIsProcessTrusted(), capturing, !demo else { return .error("Enable input locally on the Mac while sharing; Accessibility permission is required", status: 403) }
        guard let type = object["type"] as? String else { return .error("Input type required", status: 400) }
        if type == "tap" {
            guard let x = number(object["x"]), let y = number(object["y"]), (0...1).contains(x), (0...1).contains(y) else { return .error("Coordinates must be from 0 to 1", status: 400) }
            let bounds = CGDisplayBounds(displayID)
            let point = CGPoint(x: bounds.minX + x * max(0, bounds.width - 1), y: bounds.minY + y * max(0, bounds.height - 1))
            CGEvent(mouseEventSource: nil, mouseType: .mouseMoved, mouseCursorPosition: point, mouseButton: .left)?.post(tap: .cghidEventTap)
            CGEvent(mouseEventSource: nil, mouseType: .leftMouseDown, mouseCursorPosition: point, mouseButton: .left)?.post(tap: .cghidEventTap)
            CGEvent(mouseEventSource: nil, mouseType: .leftMouseUp, mouseCursorPosition: point, mouseButton: .left)?.post(tap: .cghidEventTap)
        } else if type == "scroll" {
            guard let delta = number(object["deltaY"]), (-1000...1000).contains(delta) else { return .error("deltaY must be from -1000 to 1000", status: 400) }
            let bounds = CGDisplayBounds(displayID)
            if let cursor = CGEvent(source: nil)?.location, !bounds.contains(cursor) {
                CGEvent(mouseEventSource: nil, mouseType: .mouseMoved, mouseCursorPosition: CGPoint(x: bounds.midX, y: bounds.midY), mouseButton: .left)?.post(tap: .cghidEventTap)
            }
            CGEvent(scrollWheelEvent2Source: nil, units: .pixel, wheelCount: 1, wheel1: Int32(delta), wheel2: 0, wheel3: 0)?.post(tap: .cghidEventTap)
        } else { return .error("Unsupported input type", status: 400) }
        return .json(["ok": true])
    }

    private func startDemo() {
        capturing = true
        starting = false
        message = "DEMO: synthetic test image. Your screen is not being captured."
        makeDemoFrame()
        demoTimer?.invalidate()
        demoTimer = Timer.scheduledTimer(withTimeInterval: 1.0 / Double(fps), repeats: true) { [weak self] _ in Task { @MainActor in self?.makeDemoFrame() } }
    }

    private func makeDemoFrame() {
        let width = min(maxWidth, 2480), height = min(maxWidth, 2480) * 3 / 4
        guard let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: width, pixelsHigh: height, bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0), let context = NSGraphicsContext(bitmapImageRep: bitmap) else { return }
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = context
        NSColor.white.setFill(); NSRect(x: 0, y: 0, width: width, height: height).fill()
        let title = "BOOX Sidecar · Demo" as NSString
        title.draw(at: NSPoint(x: 50, y: height - 100), withAttributes: [.font: NSFont.systemFont(ofSize: 38, weight: .bold), .foregroundColor: NSColor.black])
        let detail = "USB display sharing prototype\nFrame \(frameID + 1) · \(fps) FPS\nNo screen recording in demo mode" as NSString
        detail.draw(at: NSPoint(x: 50, y: height - 220), withAttributes: [.font: NSFont.systemFont(ofSize: 24), .foregroundColor: NSColor.black])
        for index in 0..<8 {
            if grayscale { NSColor(calibratedWhite: CGFloat(index) / 7, alpha: 1).setFill() }
            else { NSColor(calibratedHue: CGFloat(index) / 8, saturation: 0.85, brightness: 0.85, alpha: 1).setFill() }
            NSRect(x: 50 + index * (width - 100) / 8, y: 90, width: (width - 100) / 8, height: 160).fill()
        }
        NSGraphicsContext.restoreGraphicsState()
        let encodingStart = CFAbsoluteTimeGetCurrent()
        guard let jpeg = bitmap.representation(using: .jpeg, properties: [.compressionFactor: jpegQuality]) else { return }
        frame = CapturedFrame(jpeg: jpeg, width: bitmap.pixelsWide, height: bitmap.pixelsHigh, encodingMilliseconds: (CFAbsoluteTimeGetCurrent() - encodingStart) * 1000)
        frameID += 1
    }
}
