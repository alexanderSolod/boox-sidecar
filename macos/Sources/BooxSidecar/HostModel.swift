import AppKit
import ApplicationServices
import SwiftUI
import VirtualDisplayKit

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
    @Published private(set) var token: String = ""
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
    private(set) var hostID = ""
    private var tlsIdentity: TLSIdentity?
    private var tlsDirectory: URL?
    private var tlsMaintenanceTimer: Timer?
    private var configurationError: String?
    let wifiPort: UInt16
    let port: UInt16
    let developmentBrowser: Bool
    var browserEnabled: Bool { demo || developmentBrowser }
    let demo: Bool
    private let server = HTTPServer()
    private let wirelessServer = HTTPServer()
    private var capture: ScreenCapture?
    private var captureDisplayID: CGDirectDisplayID?
    private var generation = 0
    private let sharingAuthority = SharingAuthority()
    private var captureSession = ""
    private var frame: CapturedFrame?
    private var demoTimer: Timer?
    var viewerURL: String { "http://127.0.0.1:\(port)/#token=\(token)" }

    init() {
        let args = CommandLine.arguments
        demo = args.contains("--demo")
        developmentBrowser = args.contains("--development-browser")
        if let index = args.firstIndex(of: "--port"), args.indices.contains(index + 1), let value = UInt16(args[index + 1]), value > 0 { port = value } else { port = 8787 }
        if let index = args.firstIndex(of: "--wifi-port"), args.indices.contains(index + 1), let value = UInt16(args[index + 1]), value > 0 { wifiPort = value } else { wifiPort = 8788 }
        if demo || developmentBrowser { credentialStore = nil }
        else {
            let directory: URL
            if let index = args.firstIndex(of: "--pairing-directory"), args.indices.contains(index + 1) { directory = URL(fileURLWithPath: args[index + 1], isDirectory: true) }
            else { directory = PairingCredentialStore.applicationDirectory }
            credentialStore = PairingCredentialStore(directory: directory)
        }
        for option in ["--port", "--wifi-port"] {
            let positions = args.indices.filter { args[$0] == option }
            if positions.count > 1 { configurationError = "Specify \(option) only once." }
            if let index = positions.first,
               !args.indices.contains(index + 1) || UInt16(args[index + 1]).map({ $0 > 0 }) != true {
                configurationError = "\(option) requires a port from 1 through 65535."
            }
        }
        if !browserEnabled && port == wifiPort { configurationError = "USB and Wi-Fi require different listener ports." }
        if args.contains("--lan") || (browserEnabled && args.contains("--wireless")) {
            configurationError = "--lan is unsupported. Development browser mode is loopback-only and cannot enable Wi-Fi."
        }
        var credentialFailure: String?
        token = ""
        do {
            if let configurationError { throw NSError(domain: "BOOXSidecar.Configuration", code: 1, userInfo: [NSLocalizedDescriptionKey: configurationError]) }
            token = try credentialStore?.loadOrCreate() ?? PairingCredentialStore.randomToken()
            hostID = try credentialStore.map { try HostIdentityStore(directory: $0.directory).loadOrCreate() } ?? PairingCredentialStore.randomToken()
            if !browserEnabled {
                if let index = args.firstIndex(of: "--tls-directory"), args.indices.contains(index + 1) {
                    tlsDirectory = URL(fileURLWithPath: args[index + 1], isDirectory: true)
                } else { tlsDirectory = credentialStore?.directory.appendingPathComponent("TLS", isDirectory: true) }
                let tls = try TLSIdentity.load(directory: tlsDirectory)
                tlsIdentity = tls
                fingerprint = tls.spkiPin
                if let warning = tls.renewalError { wirelessMessage = warning }
            }
        }
        catch { token = ""; credentialFailure = error.localizedDescription }
        if !browserEnabled {
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
            if !token.isEmpty { try startLocalServer() }
            // CLI output is intentionally a local pairing credential; never transmitted to a third party.
            if demo { print("BOOX Sidecar DEMO viewer: \(viewerURL)"); fflush(stdout) }
        } catch { message = "Unable to start server: \(error.localizedDescription)" }
        if !browserEnabled, tlsIdentity != nil { scheduleTLSMaintenance() }
        if demo { startDemo() }
        if developmentBrowser {
            connectionMessage = "Development browser: loopback HTTP with a disposable credential. Native pairing and Wi-Fi are disabled."
            print("BOOX Sidecar DEVELOPMENT viewer: \(viewerURL)"); fflush(stdout)
        }
        if !browserEnabled, !token.isEmpty, args.contains("--wireless") { enableWireless(true) }
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

    private func startLocalServer() throws {
        if let configurationError { throw NSError(domain: "BOOXSidecar.Configuration", code: 1, userInfo: [NSLocalizedDescriptionKey: configurationError]) }
        if browserEnabled {
            try server.start(port: port, lan: false)
        } else {
            guard let identity = tlsIdentity, identity.valid(at: Date()) else {
                throw NSError(domain: "BOOXSidecar.TLS", code: 1, userInfo: [NSLocalizedDescriptionKey: "A valid TLS identity is required for native USB."])
            }
            try server.start(port: port, lan: false, tlsIdentity: identity.identity)
        }
    }

    private func scheduleTLSMaintenance() {
        tlsMaintenanceTimer?.invalidate()
        let remaining = tlsIdentity?.expiresAt.timeIntervalSinceNow ?? 60
        let delay = max(1, min(24 * 60 * 60, remaining))
        tlsMaintenanceTimer = Timer.scheduledTimer(withTimeInterval: delay, repeats: false) { [weak self] _ in
            Task { @MainActor in self?.refreshTLSIdentity() }
        }
    }

    private func refreshTLSIdentity() {
        guard !browserEnabled, configurationError == nil else { return }
        defer { scheduleTLSMaintenance() }
        do {
            let refreshed = try TLSIdentity.load(directory: tlsDirectory)
            let changed = refreshed.fingerprint != tlsIdentity?.fingerprint
            let restoreWiFi = wirelessEnabled || wirelessStarting
            tlsIdentity = refreshed
            fingerprint = refreshed.spkiPin
            if changed || !serverReady {
                server.stop()
                serverReady = false
                try startLocalServer()
                if restoreWiFi { enableWireless(false); enableWireless(true) }
            }
            if let warning = refreshed.renewalError { wirelessMessage = warning }
        } catch {
            wirelessMessage = "TLS renewal failed: " + error.localizedDescription
            if tlsIdentity?.valid(at: Date()) != true {
                stop()
                server.stop()
                serverReady = false
                enableWireless(false)
                tlsIdentity = nil
                message = "Secure connections stopped because the TLS identity expired. " + error.localizedDescription
            }
        }
    }

    func setWirelessPreference(_ enabled: Bool) {
        guard !browserEnabled, configurationError == nil else { return }
        UserDefaults.standard.set(enabled, forKey: "wireless.enabled")
        enableWireless(enabled)
    }

    func enableWireless(_ enabled: Bool) {
        guard !browserEnabled, configurationError == nil else { return }
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
            guard let tls = tlsIdentity, tls.valid(at: Date()) else {
                throw NSError(domain: "BOOXSidecar.TLS", code: 1, userInfo: [NSLocalizedDescriptionKey: "The secure host identity is unavailable."])
            }
            wirelessServer.handler = { [weak self] request, reply in
                Task { @MainActor in reply(self?.handle(request) ?? .error("Host unavailable", status: 503)) }
            }
            wirelessServer.onReady = { [weak self] in Task { @MainActor in
                guard let self, self.wirelessGeneration == attempt else { return }
                self.wirelessStarting = false
                self.wirelessEnabled = true
                self.advertiser.onError = { [weak self] text in self?.wirelessMessage = text }
                self.advertiser.start(hostID: self.hostID, port: self.wifiPort)
                self.wirelessMessage = "Encrypted Wi-Fi and automatic discovery are ready."
            } }
            wirelessServer.onError = { [weak self] text in Task { @MainActor in
                guard let self, self.wirelessGeneration == attempt else { return }
                self.wirelessStarting = false
                self.wirelessEnabled = false
                self.advertiser.stop()
                self.wirelessMessage = "Wi-Fi: \(text)"
            } }
            try wirelessServer.start(port: wifiPort, lan: true, tlsIdentity: tls.identity)
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
        if developmentBrowser {
            connectionRequested = true
            start()
            return
        }
        connectionRequested = true
        connecting = true
        connectionMessage = "Preparing your BOOX desktop…"
        connectionTask?.cancel()
        connectionTask = Task { [self] in
            defer { connecting = false }
            for _ in 0..<30 {
                if serverReady { break }
                if Task.isCancelled { return }
                try? await Task.sleep(nanoseconds: 100_000_000)
            }
            guard serverReady else { connectionRequested = false; connectionMessage = "The local server is unavailable. " + message; return }
            if UserDefaults.standard.object(forKey: "wireless.enabled") as? Bool ?? true { enableWireless(true) }
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
        guard !browserEnabled, !pairingDevice else { return }
        pairingDevice = true
        defer { pairingDevice = false }
        let pairPort = port, pairToken = token, pin = fingerprint.isEmpty ? nil : fingerprint, identity = hostID
        let address = wirelessAddresses.first
        let pairHost = wirelessEnabled && address != nil ? "https://\(address!):\(wifiPort)" : "https://127.0.0.1:\(port)"
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
        guard configurationError == nil else { return }
        disconnect()
        do {
            token = try credentialStore?.rotate() ?? PairingCredentialStore.randomToken()
            if !serverReady {
                try startLocalServer()
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
        guard !browserEnabled, !pairingDevice else { return }
        let host: String
        let certificate: String?
        if useWiFi {
            guard wirelessEnabled, !fingerprint.isEmpty, let address = wirelessAddresses.first else {
                message = "Enable encrypted Wi-Fi and connect the Mac to your network first."
                return
            }
            host = "https://\(address):\(wifiPort)"
            certificate = fingerprint
        } else { host = "https://127.0.0.1:\(port)"; certificate = fingerprint.isEmpty ? nil : fingerprint }
        pairingDevice = true
        let pairPort = port, pairToken = token, pairID = hostID
        let wifiHost = wirelessAddresses.first.map { "https://\($0):\(wifiPort)" }
        Task {
            do {
                try await Task.detached(priority: .userInitiated) {
                    try DevicePairing.pair(port: pairPort, host: host, token: pairToken, fingerprint: certificate, hostID: pairID, preferUSB: !useWiFi, wifiHost: wifiHost)
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
        sharingAuthority.invalidate()
        captureSession = UUID().uuidString
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
        captureDisplayID = id
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
                stop()
                permission = CGPreflightScreenCaptureAccess()
                let failure = error as NSError
                message = "ScreenCaptureKit failed (\(failure.domain), \(failure.code)): \(error.localizedDescription)"
            }
        }
    }

    func stop() {
        sharingAuthority.invalidate()
        captureSession = ""
        server.cancelSensitiveConnections()
        wirelessServer.cancelSensitiveConnections()
        generation += 1
        demoTimer?.invalidate()
        demoTimer = nil
        let oldCapture = capture
        capture = nil
        captureDisplayID = nil
        starting = false
        capturing = false
        frame = nil
        message = "Sharing stopped."
        Task { await oldCapture?.stop() }
    }

    func applySettings() {
        if !browserEnabled {
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
        ["protocol": 2, "capture_session": captureSession, "capturing": capturing, "permission": demo || permission, "demo": demo, "inputEnabled": inputEnabled && AXIsProcessTrusted(), "frameID": frameID, "width": frame?.width ?? 0, "height": frame?.height ?? 0, "fps": fps, "maxWidth": maxWidth, "jpegQuality": jpegQuality, "jpegBytes": frame?.jpeg.count ?? 0, "encodeMilliseconds": frame?.encodingMilliseconds ?? 0, "grayscale": grayscale, "displayID": displayID, "virtualDisplayID": virtualDisplayID, "extendedDesktop": displayID == virtualDisplayID && virtualDisplayID != 0, "wirelessEnabled": wirelessEnabled, "wirelessAddresses": wirelessAddresses, "spki_sha256": fingerprint, "host_id": hostID, "displayAsleep": displayAsleep, "message": message]
    }

    private func handle(_ request: HTTPRequest) -> HTTPResponse {
        var response = respond(to: request)
        if request.path.hasPrefix("/api/") {
            response.authority = sharingAuthority.ticket(expiresAt: browserEnabled ? nil : tlsIdentity?.expiresAt)
        }
        return response
    }

    private func respond(to request: HTTPRequest) -> HTTPResponse {
        if !browserEnabled && tlsIdentity?.valid(at: Date()) != true {
            return .error("TLS identity expired; renew it on the Mac", status: 503)
        }
        // Prevent DNS rebinding in default loopback mode.
        if request.loopback {
            let allowed = ["127.0.0.1:\(port)", "localhost:\(port)"]
            guard let host = request.headers["host"], allowed.contains(host.lowercased()) else { return .error("Invalid Host", status: 403) }
        }
        if request.path.hasPrefix("/api/") {
            guard SharingAuthority.matchesCredential(header: request.headers["authorization"], token: token) else { return .error("Pairing token required", status: 401) }
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
        case "/health": return .json(["ok": true, "protocol": 2])
        case "/api/status": return .json(status())
        case "/api/displays": return .json(["displays": displays.map(\.json)])
        case "/api/frame":
            if capturing && !demo && captureDisplayID.map({ CGDisplayIsActive($0) != 0 }) != true {
                stop()
                return HTTPResponse(status: 204)
            }
            guard let after = Int(request.query["after"] ?? "-1"), after >= -1 else { return .error("Invalid frame ID", status: 400) }
            guard capturing, !captureSession.isEmpty, let frame, frameID > after else { return HTTPResponse(status: 204) }
            return HTTPResponse(type: "image/jpeg", headers: ["X-Capture-Session": captureSession, "X-Frame-ID": String(frameID), "X-Frame-Width": String(frame.width), "X-Frame-Height": String(frame.height)], body: frame.jpeg)
        case "/api/settings", "/api/input":
            guard request.headers["content-type"]?.lowercased().hasPrefix("application/json") == true,
                  let object = try? JSONSerialization.jsonObject(with: request.body) as? [String: Any] else { return .error("Expected JSON object", status: 400) }
            return request.path == "/api/settings" ? settings(object) : input(object)
        case "/", "/index.html", "/app.js", "/style.css":
            guard browserEnabled else { return .error("Browser access requires --development-browser", status: 404) }
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
        guard object["displayID"] == nil else { return .error("Select the shared display locally on the Mac", status: 403) }
        guard Set(object.keys).isSubset(of: ["fps", "grayscale", "maxWidth", "jpegQuality"]) else { return .error("Unknown setting", status: 400) }
        var newFPS = fps, newWidth = maxWidth, newGray = grayscale
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
        let changed = jpegQuality != newQuality || fps != newFPS || maxWidth != newWidth || grayscale != newGray
        jpegQuality = newQuality; fps = newFPS; maxWidth = newWidth; grayscale = newGray
        if changed { applySettings() }
        return .json(status())
    }

    private func input(_ object: [String: Any]) -> HTTPResponse {
        guard !captureSession.isEmpty, object["capture_session"] as? String == captureSession else {
            return .error("Input belongs to an inactive capture session", status: 403)
        }
        guard let captureDisplayID, CGDisplayIsActive(captureDisplayID) != 0, inputEnabled, AXIsProcessTrusted(), capturing, !demo else { return .error("Enable input locally on the Mac while sharing; Accessibility permission is required", status: 403) }
        guard let type = object["type"] as? String else { return .error("Input type required", status: 400) }
        if type == "tap" {
            guard let x = number(object["x"]), let y = number(object["y"]), (0...1).contains(x), (0...1).contains(y) else { return .error("Coordinates must be from 0 to 1", status: 400) }
            let bounds = CGDisplayBounds(captureDisplayID)
            let point = CGPoint(x: bounds.minX + x * max(0, bounds.width - 1), y: bounds.minY + y * max(0, bounds.height - 1))
            CGEvent(mouseEventSource: nil, mouseType: .mouseMoved, mouseCursorPosition: point, mouseButton: .left)?.post(tap: .cghidEventTap)
            CGEvent(mouseEventSource: nil, mouseType: .leftMouseDown, mouseCursorPosition: point, mouseButton: .left)?.post(tap: .cghidEventTap)
            CGEvent(mouseEventSource: nil, mouseType: .leftMouseUp, mouseCursorPosition: point, mouseButton: .left)?.post(tap: .cghidEventTap)
        } else if type == "scroll" {
            guard let delta = number(object["deltaY"]), (-1000...1000).contains(delta) else { return .error("deltaY must be from -1000 to 1000", status: 400) }
            let bounds = CGDisplayBounds(captureDisplayID)
            if let cursor = CGEvent(source: nil)?.location, !bounds.contains(cursor) {
                CGEvent(mouseEventSource: nil, mouseType: .mouseMoved, mouseCursorPosition: CGPoint(x: bounds.midX, y: bounds.midY), mouseButton: .left)?.post(tap: .cghidEventTap)
            }
            CGEvent(scrollWheelEvent2Source: nil, units: .pixel, wheelCount: 1, wheel1: Int32(delta), wheel2: 0, wheel3: 0)?.post(tap: .cghidEventTap)
        } else { return .error("Unsupported input type", status: 400) }
        return .json(["ok": true])
    }

    private func startDemo() {
        sharingAuthority.invalidate()
        captureSession = UUID().uuidString
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
