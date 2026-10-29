import Foundation
import Darwin

struct BOOXUSBDevice: Equatable, Hashable {
    let serial: String
    let description: String
}

/// adb output is held in memory only; commands containing tokens are never logged.
enum DevicePairing {
    static var addresses: [String] {
        var interfaces: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&interfaces) == 0, let first = interfaces else { return [] }
        defer { freeifaddrs(interfaces) }
        var results: [(String, String)] = []
        var current: UnsafeMutablePointer<ifaddrs>? = first
        while let entry = current {
            defer { current = entry.pointee.ifa_next }
            let name = String(cString: entry.pointee.ifa_name)
            guard name == "en0" || name == "en1", let address = entry.pointee.ifa_addr,
                  address.pointee.sa_family == UInt8(AF_INET), entry.pointee.ifa_flags & UInt32(IFF_UP) != 0 else { continue }
            var ipv4 = address.withMemoryRebound(to: sockaddr_in.self, capacity: 1) { $0.pointee.sin_addr }
            var buffer = [CChar](repeating: 0, count: Int(INET_ADDRSTRLEN))
            guard inet_ntop(AF_INET, &ipv4, &buffer, socklen_t(INET_ADDRSTRLEN)) != nil else { continue }
            let text = String(cString: buffer)
            if !text.hasPrefix("169.254.") { results.append((name, text)) }
        }
        return results.sorted { $0.0 < $1.0 }.map(\.1)
    }

    static func discover() throws -> [BOOXUSBDevice] {
        let adb = try executable()
        let candidates = parseDevices(try run(adb, ["devices", "-l"]))
        return candidates.filter { device in
            let lower = device.description.lowercased()
            if lower.contains("boox") || lower.contains("onyx") || lower.contains("noteair") { return true }
            let maker = (try? run(adb, ["-s", device.serial, "shell", "getprop", "ro.product.manufacturer"]))?.lowercased() ?? ""
            return maker.contains("onyx") || maker.contains("boox")
        }
    }

    static func parseDevices(_ output: String) -> [BOOXUSBDevice] {
        output.split(separator: "\n").compactMap { line in
            let fields = line.split(whereSeparator: \.isWhitespace)
            guard fields.count >= 2, fields[1] == "device", line.contains("usb:"), safe(String(fields[0])) else { return nil }
            return BOOXUSBDevice(serial: String(fields[0]), description: String(line))
        }
    }

    static func ensureReverse(device: BOOXUSBDevice, port: UInt16) throws {
        let adb = try executable()
        let current = try run(adb, ["-s", device.serial, "reverse", "--list"])
        if !hasReverse(current, port: port) {
            _ = try run(adb, ["-s", device.serial, "reverse", "tcp:\(port)", "tcp:\(port)"])
        }
    }

    static func hasReverse(_ output: String, port: UInt16) -> Bool {
        let endpoint = "tcp:\(port)"
        return output.split(separator: "\n").contains { line in
            let columns = line.split(whereSeparator: \.isWhitespace)
            return columns.count >= 2 && columns.suffix(2).allSatisfy { $0 == endpoint }
        }
    }

    static func provision(device: BOOXUSBDevice, port: UInt16, host: String, token: String, fingerprint: String?, hostID: String?, preferUSB: Bool? = nil, wifiHost: String? = nil) throws {
        guard [device.serial, host, token, fingerprint ?? "", hostID ?? "", wifiHost ?? ""].allSatisfy(safe), PairingCredentialStore.valid(token),
              PairingCredentialStore.valid(fingerprint ?? ""), PairingCredentialStore.valid(hostID ?? "") else { throw failure("Invalid pairing parameters.") }
        try Task.checkCancellation()
        let adb = try executable()
        try ensureReverse(device: device, port: port)
        let installed = try run(adb, ["-s", device.serial, "shell", "pm", "path", "local.boox.sidecar"])
        guard installed.contains("package:") else { throw failure("Install the BOOX Sidecar Android app before pairing.") }
        // BOOX app freezing can leave this exact installed package disabled.
        _ = try run(adb, ["-s", device.serial, "shell", "pm", "enable", "local.boox.sidecar"])
        var args = ["-s", device.serial, "shell", "am", "start", "-n", "local.boox.sidecar/.ProvisioningActivity", "--es", "host", host, "--ei", "pairing_version", "2", "--es", "usb_host", "https://127.0.0.1:\(port)", "--es", "token", token, "--ez", "auto_connect", "true"]
        if let fingerprint, !fingerprint.isEmpty { args += ["--es", "spki_sha256", fingerprint] }
        if let hostID, !hostID.isEmpty { args += ["--es", "host_id", hostID] }
        if let wifiHost, !wifiHost.isEmpty { args += ["--es", "wifi_host", wifiHost] }
        if let preferUSB { args += ["--es", "preferred_transport", preferUSB ? "usb" : "auto"] }
        try Task.checkCancellation()
        _ = try run(adb, args)
    }

    static func pair(port: UInt16, host: String, token: String, fingerprint: String?, hostID: String? = nil, preferUSB: Bool = false, wifiHost: String? = nil) throws {
        let devices = try discover()
        guard devices.count == 1, let device = devices.first else { throw failure("Connect exactly one BOOX by USB and approve USB debugging.") }
        try provision(device: device, port: port, host: host, token: token, fingerprint: fingerprint, hostID: hostID, preferUSB: preferUSB, wifiHost: wifiHost)
    }

    static func outputIndicatesFailure(_ output: String) -> Bool {
        let lower = output.lowercased()
        return lower.contains("error:") || lower.contains("error type") || lower.contains("exception") || lower.contains("does not exist") || lower.contains("unable to resolve intent") || lower.contains("failure [")
    }

    private static func safe(_ text: String) -> Bool {
        let characters = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789.:/-_")
        return text.unicodeScalars.allSatisfy(characters.contains)
    }

    private static func executable() throws -> String {
        let paths = ["/opt/homebrew/bin/adb", "/usr/local/bin/adb", NSHomeDirectory() + "/Library/Android/sdk/platform-tools/adb"]
        guard let path = paths.first(where: { FileManager.default.isExecutableFile(atPath: $0) }) else { throw failure("USB setup needs adb (brew install android-platform-tools). Remembered Wi-Fi pairing can still connect.") }
        return path
    }

    @discardableResult private static func run(_ executable: String, _ arguments: [String]) throws -> String {
        try Task.checkCancellation()
        let process = Process()
        let pipe = Pipe()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        process.standardOutput = pipe
        process.standardError = pipe
        try process.run()
        DispatchQueue.global().asyncAfter(deadline: .now() + 12) { if process.isRunning { process.terminate() } }
        // Drain while running, so diagnostics cannot fill the child pipe. Never
        // expose this text: am's success output includes the pairing intent.
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        try Task.checkCancellation()
        let output = String(data: data, encoding: .utf8) ?? ""
        guard process.terminationStatus == 0, !outputIndicatesFailure(output) else { throw failure("USB setup failed. Unlock the BOOX, approve USB debugging, and make sure BOOX Sidecar is installed and unfrozen.") }
        return output
    }

    private static func failure(_ message: String) -> NSError { NSError(domain: "BooxPairing", code: 1, userInfo: [NSLocalizedDescriptionKey: message]) }
}
