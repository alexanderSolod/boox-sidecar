import Foundation
import Darwin
import CryptoKit

@main struct SecurityIntegrationTests {
    struct CurlResult {
        let exitCode: Int32
        let output: String
        var status: Int { Int(output.split(separator: "\n").last ?? "") ?? 0 }
    }

    final class RequestState: @unchecked Sendable {
        private let lock = NSLock()
        private var count = 0
        private var pending: ((HTTPResponse) -> Void)?
        private var result: CurlResult?
        func received() { lock.lock(); count += 1; lock.unlock() }
        var requests: Int { lock.lock(); defer { lock.unlock() }; return count }
        func hold(_ reply: @escaping (HTTPResponse) -> Void) { lock.lock(); pending = reply; lock.unlock() }
        func reply() { lock.lock(); let reply = pending; pending = nil; lock.unlock(); reply?(HTTPResponse(body: Data("obsolete-frame".utf8))) }
        func finish(_ value: CurlResult) { lock.lock(); result = value; lock.unlock() }
        var completed: CurlResult? { lock.lock(); defer { lock.unlock() }; return result }
    }

    static func expect(_ condition: Bool, _ message: String) {
        if !condition { fatalError(message) }
    }

    static func expectFailure(_ message: String, _ operation: () throws -> Void) {
        do { try operation(); fatalError(message) } catch { }
    }

    static func permissions(_ url: URL) -> mode_t {
        var info = stat()
        expect(lstat(url.path, &info) == 0, "File must exist")
        return info.st_mode & 0o777
    }

    static func unusedPort() throws -> UInt16 {
        let descriptor = socket(AF_INET, SOCK_STREAM, 0)
        guard descriptor >= 0 else { throw PrivateIdentityFiles.failure("Could not reserve a test port") }
        defer { close(descriptor) }
        var address = sockaddr_in()
        address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        address.sin_family = sa_family_t(AF_INET)
        address.sin_addr.s_addr = inet_addr("127.0.0.1")
        let bound = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(descriptor, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) }
        }
        expect(bound == 0, "Test port must bind")
        var length = socklen_t(MemoryLayout<sockaddr_in>.size)
        let read = withUnsafeMutablePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { getsockname(descriptor, $0, &length) }
        }
        expect(read == 0, "Test port must be readable")
        return UInt16(bigEndian: address.sin_port)
    }

    static func request(port: UInt16, pin: String?, token: String? = nil, path: String = "/api/status", headers: [String] = [], secure: Bool = true) throws -> CurlResult {
        let process = Process(), output = Pipe(), input = Pipe()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/curl")
        var arguments = ["--silent", "--insecure", "--http1.1", "--noproxy", "*", "--max-time", "5", "--write-out", "\n%{http_code}", "--config", "-"]
        if let pin {
            let bytes = stride(from: 0, to: pin.count, by: 2).map { offset -> UInt8 in
                let start = pin.index(pin.startIndex, offsetBy: offset)
                return UInt8(pin[start..<pin.index(start, offsetBy: 2)], radix: 16)!
            }
            arguments += ["--pinnedpubkey", "sha256//" + Data(bytes).base64EncodedString()]
        }
        for header in headers { arguments += ["--header", header] }
        arguments.append("\(secure ? "https" : "http")://127.0.0.1:\(port)\(path)")
        process.arguments = arguments
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        process.standardInput = input
        try process.run()
        if let token { input.fileHandleForWriting.write(Data("header = \"Authorization: Bearer \(token)\"\n".utf8)) }
        try input.fileHandleForWriting.close()
        let data = output.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return CurlResult(exitCode: process.terminationStatus, output: String(decoding: data, as: UTF8.self))
    }

    static func checkIdentity(_ root: URL) throws -> (String, TLSIdentity) {
        let store = HostIdentityStore(directory: root)
        let hostID = try store.loadOrCreate()
        expect(PairingCredentialStore.valid(hostID), "Host identity must be valid")
        expect(try store.loadOrCreate() == hostID, "Restart must retain host identity")
        expect(permissions(root) == 0o700 && permissions(store.file) == 0o600, "Host identity must be private")
        chmod(store.file.path, 0o644)
        _ = try store.loadOrCreate()
        expect(permissions(store.file) == 0o600, "Loading must repair host identity permissions")
        let credentials = PairingCredentialStore(directory: root)
        _ = try credentials.loadOrCreate()
        _ = try credentials.rotate()
        expect(try store.loadOrCreate() == hostID, "Credential rotation must not replace host identity")
        try Data("invalid".utf8).write(to: store.file)
        expectFailure("Malformed host identity accepted") { _ = try store.loadOrCreate() }
        try FileManager.default.removeItem(at: store.file)
        let target = root.appendingPathComponent("external-id")
        try Data(hostID.utf8).write(to: target)
        try FileManager.default.createSymbolicLink(at: store.file, withDestinationURL: target)
        expectFailure("Symlink host identity accepted") { _ = try store.loadOrCreate() }
        try FileManager.default.removeItem(at: store.file)
        try PrivateIdentityFiles.publish(Data(hostID.utf8), to: store.file)

        let tlsRoot = root.appendingPathComponent("TLS", isDirectory: true)
        let first = try TLSIdentity.load(directory: tlsRoot)
        let bundle = tlsRoot.appendingPathComponent("identity.p12")
        expect(permissions(tlsRoot) == 0o700 && permissions(bundle) == 0o600, "TLS identity must be private")
        expect(first.valid(at: first.notBefore), "Certificate must be valid at its start")
        expect(!first.valid(at: first.notBefore.addingTimeInterval(-1)), "Future certificate accepted")
        expect(first.valid(at: first.expiresAt.addingTimeInterval(-1)), "Certificate must be valid before expiry")
        expect(!first.valid(at: first.expiresAt), "Expired certificate accepted")
        expect(!first.needsRenewal(at: first.expiresAt.addingTimeInterval(-TLSIdentity.renewalWindow)), "Renewal boundary must remain exclusive")
        expect(first.needsRenewal(at: first.expiresAt.addingTimeInterval(1 - TLSIdentity.renewalWindow)), "Certificate inside renewal window must renew")
        let reload = try TLSIdentity.load(directory: tlsRoot)
        expect(reload.fingerprint == first.fingerprint && reload.spkiPin == first.spkiPin, "Ordinary restart must retain certificate and key")
        let reissued = try TLSIdentity.load(directory: tlsRoot, now: first.notBefore.addingTimeInterval(-1))
        expect(reissued.spkiPin == first.spkiPin && reissued.renewalError == nil, "Not-yet-valid certificate must be reissued with the paired key")
        let renewed = try TLSIdentity.load(directory: tlsRoot, now: first.expiresAt.addingTimeInterval(-24 * 60 * 60))
        expect(renewed.spkiPin == first.spkiPin, "Renewal must retain the paired public key")
        expect(renewed.fingerprint != first.fingerprint && renewed.renewalError == nil, "Renewal must publish a fresh certificate")
        let beforeFailure = try Data(contentsOf: bundle)
        expectFailure("Renewal outside fixture lifetime must fail closed") { _ = try TLSIdentity.load(directory: tlsRoot, now: renewed.expiresAt.addingTimeInterval(60)) }
        expect(try Data(contentsOf: bundle) == beforeFailure, "Failed renewal must preserve the complete previous identity")
        expect(permissions(bundle) == 0o600, "Renewal must retain private file permissions")
        expect(try store.loadOrCreate() == hostID, "TLS lifecycle must not change host identity")
        expect(try FileManager.default.contentsOfDirectory(atPath: tlsRoot.path) == ["identity.p12"], "TLS staging files must be cleaned up")
        return (hostID, renewed)
    }

    static func checkAuthority() {
        let authority = SharingAuthority(), token = String(repeating: "a", count: 64)
        expect(SharingAuthority.matchesCredential(header: "Bearer " + token, token: token), "Valid credential rejected")
        let invalidHeaders: [String?] = [
            nil,
            "bearer " + token,
            "Bearer " + token + "a",
            "Bearer b" + String(token.dropFirst()),
            "Bearer " + String(token.dropLast()) + "b"
        ]
        for header in invalidHeaders {
            expect(!SharingAuthority.matchesCredential(header: header, token: token), "Invalid credential accepted")
        }
        expect(!authority.ticket(expiresAt: .distantPast).perform { fatalError("Expired ticket executed") }, "Expired authority accepted")
        let ticket = authority.ticket()
        let entered = DispatchSemaphore(value: 0), release = DispatchSemaphore(value: 0), completed = DispatchSemaphore(value: 0)
        DispatchQueue.global().async {
            _ = ticket.perform { entered.signal(); expect(release.wait(timeout: .now() + 5) == .success, "Concurrent authority operation timed out") }
            completed.signal()
        }
        expect(entered.wait(timeout: .now() + 5) == .success, "Authority operation must start")
        let invalidating = DispatchSemaphore(value: 0), invalidated = DispatchSemaphore(value: 0)
        DispatchQueue.global().async { invalidating.signal(); authority.invalidate(); invalidated.signal() }
        expect(invalidating.wait(timeout: .now() + 5) == .success, "Invalidation must start")
        expect(invalidated.wait(timeout: .now() + 0.05) == .timedOut, "Invalidation must serialize with an active delivery")
        release.signal()
        expect(completed.wait(timeout: .now() + 5) == .success && invalidated.wait(timeout: .now() + 5) == .success, "Authority operations must finish")
        expect(!ticket.perform { fatalError("Obsolete ticket executed") }, "Old ticket survived invalidation")
        expect(authority.ticket().perform {}, "Fresh ticket must work")
    }

    static func checkSockets(_ root: URL, hostID: String, identity: TLSIdentity) throws {
        let server = HTTPServer(), authority = SharingAuthority(), state = RequestState()
        let token = String(repeating: "a", count: 64), held = DispatchSemaphore(value: 0)
        server.handler = { request, reply in
            state.received()
            expect(request.secure && request.loopback, "Native test requests must use loopback TLS")
            guard SharingAuthority.matchesCredential(header: request.headers["authorization"], token: token) else {
                reply(.error("Pairing token required", status: 401)); return
            }
            if request.path == "/api/held" { state.hold(reply); held.signal(); return }
            if request.path == "/api/frame" {
                let ticket = authority.ticket()
                authority.invalidate()
                reply(HTTPResponse(body: Data("obsolete-frame".utf8), authority: ticket))
            } else { reply(.json(["host_id": hostID, "secure": request.secure])) }
        }
        defer { server.stop() }
        let port = try unusedPort()
        func start(_ identity: TLSIdentity) throws {
            let ready = DispatchSemaphore(value: 0)
            server.onReady = { ready.signal() }
            server.onError = { _ in fatalError("TLS listener failed") }
            try server.start(port: port, lan: false, tlsIdentity: identity.identity)
            expect(ready.wait(timeout: .now() + 5) == .success, "TLS listener must become ready")
        }
        try start(identity)
        expect(try request(port: port, pin: identity.spkiPin).status == 401, "Missing authorization must fail")
        expect(try request(port: port, pin: identity.spkiPin, token: String(repeating: "b", count: 64)).status == 401, "Wrong authorization must fail")
        let valid = try request(port: port, pin: identity.spkiPin, token: token)
        expect(valid.exitCode == 0 && valid.status == 200 && valid.output.contains(hostID), "Pinned native status must succeed")
        let beforeWrongPin = state.requests
        expect(try request(port: port, pin: String(repeating: "0", count: 64), token: token).exitCode != 0, "Wrong pin must fail")
        expect(state.requests == beforeWrongPin, "Wrong pin must fail before authenticated HTTP")
        expect(try request(port: port, pin: nil, token: token, secure: false).exitCode != 0, "Plaintext must not reach native listener")
        expect(state.requests == beforeWrongPin, "Plaintext must not invoke the handler")
        expect(try request(port: port, pin: identity.spkiPin, token: token, headers: ["X-Duplicate: one", "X-Duplicate: two"]).status == 400, "Duplicate headers must fail in the real parser")
        expect(try request(port: port, pin: identity.spkiPin, token: token, headers: ["Content-Length: 65536"]).status == 400, "Oversized body must fail before reading it")
        let revoked = try request(port: port, pin: identity.spkiPin, token: token, path: "/api/frame")
        expect(revoked.exitCode != 0 && !revoked.output.contains("obsolete-frame"), "Invalidated queued frame must not be delivered")
        let finished = DispatchSemaphore(value: 0)
        DispatchQueue.global().async {
            do { state.finish(try request(port: port, pin: identity.spkiPin, token: token, path: "/api/held")) }
            catch { fatalError("Held request could not run") }
            finished.signal()
        }
        expect(held.wait(timeout: .now() + 5) == .success, "Held request must reach the listener")
        server.cancelSensitiveConnections()
        state.reply()
        expect(finished.wait(timeout: .now() + 5) == .success, "Cancelled request must complete")
        expect(state.completed?.exitCode != 0 && state.completed?.output.contains("obsolete-frame") == false, "Cancelled sensitive response must not be delivered")
        server.stop()
        let reloaded = try TLSIdentity.load(directory: root.appendingPathComponent("TLS", isDirectory: true))
        try start(reloaded)
        let restarted = try request(port: port, pin: identity.spkiPin, token: token)
        expect(restarted.status == 200 && restarted.output.contains(hostID), "USB-only restart must preserve pinned identity")
    }

    @discardableResult static func openssl(_ arguments: [String]) throws -> Data {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/openssl")
        process.arguments = arguments
        let output = Pipe()
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        try process.run()
        let data = output.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        expect(process.terminationStatus == 0, "openssl \(arguments[0]) failed")
        return data
    }

    static func checkLegacyCleanup(_ root: URL) throws {
        let tlsRoot = root.appendingPathComponent("LegacyTLS", isDirectory: true)
        try PrivateIdentityFiles.prepare(tlsRoot)
        let legacyKey = tlsRoot.appendingPathComponent("private-key.pem")
        let legacyCertificate = tlsRoot.appendingPathComponent("certificate.pem")
        try openssl(["genrsa", "-out", legacyKey.path, "2048"])
        try Data("legacy".utf8).write(to: legacyCertificate)
        let spki = try openssl(["pkey", "-in", legacyKey.path, "-pubout", "-outform", "DER"])
        let legacyPin = SHA256.hash(data: spki).map { String(format: "%02x", $0) }.joined()
        let stale = tlsRoot.appendingPathComponent(".tls-interrupted", isDirectory: true)
        try PrivateIdentityFiles.prepare(stale)
        try FileManager.default.copyItem(at: legacyKey, to: stale.appendingPathComponent("private-key.pem"))
        try Data("partial".utf8).write(to: tlsRoot.appendingPathComponent(".identity-interrupted"))

        let migrated = try TLSIdentity.load(directory: tlsRoot)
        expect(migrated.spkiPin == legacyPin, "Legacy key must be migrated into the identity bundle")
        expect(try FileManager.default.contentsOfDirectory(atPath: tlsRoot.path) == ["identity.p12"], "Legacy and interrupted key material must be removed")

        try Data("legacy".utf8).write(to: legacyKey)
        try Data("legacy".utf8).write(to: legacyCertificate)
        let reloaded = try TLSIdentity.load(directory: tlsRoot)
        expect(reloaded.spkiPin == legacyPin, "Existing bundle must take precedence over legacy files")
        expect(try FileManager.default.contentsOfDirectory(atPath: tlsRoot.path) == ["identity.p12"], "Legacy files beside a saved bundle must be removed")
    }

    static func checkConcurrentLoads(_ root: URL, identity: TLSIdentity) {
        let tlsRoot = root.appendingPathComponent("TLS", isDirectory: true)
        let lock = NSLock()
        var pins: [String] = []
        DispatchQueue.concurrentPerform(iterations: 6) { _ in
            let pin = (try? TLSIdentity.load(directory: tlsRoot))?.spkiPin ?? ""
            lock.lock(); pins.append(pin); lock.unlock()
        }
        expect(pins.count == 6 && pins.allSatisfy { $0 == identity.spkiPin }, "Concurrent loads must not disrupt each other")
        expect(try! FileManager.default.contentsOfDirectory(atPath: tlsRoot.path) == ["identity.p12"], "Concurrent loads must clean up staging")
    }

    static func main() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("boox-security-tests-" + UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let (hostID, identity) = try checkIdentity(root)
        try checkLegacyCleanup(root)
        checkConcurrentLoads(root, identity: identity)
        checkAuthority()
        try checkSockets(root, hostID: hostID, identity: identity)
        print("PASS: private identity persistence, TLS time boundaries, renewal and legacy key cleanup, authority invalidation, pinned HTTP/TLS sockets and cancellation")
    }
}
