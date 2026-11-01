import Foundation
import Security
import Darwin

/// Persistent pairing secret. Normal host launches reuse it; demos never touch it.
struct PairingCredentialStore {
    let directory: URL
    var file: URL { directory.appendingPathComponent("pairing-token-v2") }

    static var applicationDirectory: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("BOOX Sidecar", isDirectory: true)
    }

    static func randomToken() throws -> String {
        var bytes = [UInt8](repeating: 0, count: 32)
        guard SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes) == errSecSuccess else { throw failure("Could not generate a secure pairing credential.") }
        return bytes.map { String(format: "%02x", $0) }.joined()
    }

    func loadOrCreate() throws -> String {
        try prepareDirectory()
        if FileManager.default.fileExists(atPath: file.path) { return try read() }
        let token = try Self.randomToken()
        let descriptor = open(file.path, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW, mode_t(0o600))
        if descriptor < 0 {
            if errno == EEXIST { return try read() }
            throw Self.failure("Could not create the private pairing credential.")
        }
        do { try write(token, to: descriptor); close(descriptor) }
        catch { close(descriptor); unlink(file.path); throw error }
        return token
    }

    func rotate() throws -> String {
        try prepareDirectory()
        let token = try Self.randomToken()
        let temporary = directory.appendingPathComponent(".pairing-" + UUID().uuidString)
        let descriptor = open(temporary.path, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW, mode_t(0o600))
        guard descriptor >= 0 else { throw Self.failure("Could not replace the pairing credential.") }
        defer { close(descriptor) }
        do {
            try write(token, to: descriptor)
            guard rename(temporary.path, file.path) == 0 else { throw Self.failure("Could not save the new pairing credential.") }
        } catch { unlink(temporary.path); throw error }
        return token
    }

    private func prepareDirectory() throws {
        let fm = FileManager.default
        try fm.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        var info = stat()
        guard lstat(directory.path, &info) == 0, (info.st_mode & S_IFMT) == S_IFDIR, info.st_uid == geteuid() else { throw Self.failure("Pairing directory must be owned by this user and must not be a symbolic link.") }
        guard chmod(directory.path, 0o700) == 0 else { throw Self.failure("Could not secure the pairing directory.") }
    }

    private func read() throws -> String {
        let descriptor = open(file.path, O_RDONLY | O_NOFOLLOW)
        guard descriptor >= 0 else { throw Self.failure("Could not read the saved pairing credential.") }
        defer { close(descriptor) }
        var info = stat()
        guard fstat(descriptor, &info) == 0, (info.st_mode & S_IFMT) == S_IFREG, info.st_uid == geteuid(), info.st_size == 64,
              fchmod(descriptor, 0o600) == 0 else { throw Self.failure("Saved pairing credential is invalid or unsafe.") }
        var bytes = [UInt8](repeating: 0, count: 64)
        guard Darwin.read(descriptor, &bytes, bytes.count) == bytes.count,
              let token = String(bytes: bytes, encoding: .utf8), Self.valid(token) else { throw Self.failure("Saved pairing credential is invalid. Use Forget pairing to replace it.") }
        return token
    }

    static func valid(_ token: String) -> Bool {
        token.utf8.count == 64 && token.utf8.allSatisfy { (48...57).contains($0) || (97...102).contains($0) }
    }

    private func write(_ token: String, to descriptor: Int32) throws {
        let bytes = Array(token.utf8)
        let count = bytes.withUnsafeBytes { Darwin.write(descriptor, $0.baseAddress, $0.count) }
        guard count == bytes.count, fsync(descriptor) == 0 else { throw Self.failure("Could not save the pairing credential.") }
    }

    private static func failure(_ message: String) -> NSError {
        NSError(domain: "BooxPairingCredential", code: 1, userInfo: [NSLocalizedDescriptionKey: message])
    }
}
