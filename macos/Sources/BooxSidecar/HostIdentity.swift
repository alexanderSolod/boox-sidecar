import Foundation
import Darwin

struct HostIdentityStore {
    let directory: URL
    var file: URL { directory.appendingPathComponent("installation-id") }

    func loadOrCreate() throws -> String {
        try PrivateIdentityFiles.prepare(directory)
        if try PrivateIdentityFiles.exists(file) {
            let data = try PrivateIdentityFiles.read(file)
            guard let value = String(data: data, encoding: .utf8), PairingCredentialStore.valid(value) else {
                throw PrivateIdentityFiles.failure("Saved installation identity is invalid. Reset the identity explicitly to replace it.")
            }
            return value
        }
        let value = try PairingCredentialStore.randomToken()
        try PrivateIdentityFiles.publish(Data(value.utf8), to: file, replace: false)
        return value
    }
}

enum PrivateIdentityFiles {
    static func prepare(_ directory: URL) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        var info = stat()
        guard lstat(directory.path, &info) == 0, info.st_mode & S_IFMT == S_IFDIR, info.st_uid == geteuid(),
              chmod(directory.path, 0o700) == 0 else { throw failure("Identity directory must be private, owned by this user, and not a symbolic link.") }
    }

    static func exists(_ file: URL) throws -> Bool {
        var info = stat()
        if lstat(file.path, &info) != 0 {
            guard errno == ENOENT else { throw failure("Could not inspect the saved identity.") }
            return false
        }
        guard info.st_mode & S_IFMT == S_IFREG, info.st_uid == geteuid() else {
            throw failure("Saved identity must be a regular file owned by this user.")
        }
        return true
    }

    static func read(_ file: URL) throws -> Data {
        let descriptor = open(file.path, O_RDONLY | O_NOFOLLOW)
        guard descriptor >= 0 else { throw failure("Could not read the saved identity.") }
        defer { close(descriptor) }
        var info = stat()
        guard fstat(descriptor, &info) == 0, info.st_mode & S_IFMT == S_IFREG, info.st_uid == geteuid(),
              info.st_size > 0, info.st_size <= 1_048_576,
              (info.st_mode & 0o777 == 0o600 || fchmod(descriptor, 0o600) == 0) else {
            throw failure("Saved identity is invalid or unsafe.")
        }
        var bytes = [UInt8](repeating: 0, count: Int(info.st_size))
        let count = bytes.withUnsafeMutableBytes { Darwin.read(descriptor, $0.baseAddress, $0.count) }
        guard count == bytes.count else { throw failure("Could not read the complete saved identity.") }
        return Data(bytes)
    }

    static func publish(_ data: Data, to file: URL, replace: Bool = true) throws {
        let temporary = file.deletingLastPathComponent().appendingPathComponent(".identity-" + UUID().uuidString)
        let descriptor = open(temporary.path, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW, mode_t(0o600))
        guard descriptor >= 0 else { throw failure("Could not stage the private identity.") }
        defer { close(descriptor); unlink(temporary.path) }
        let count = data.withUnsafeBytes { Darwin.write(descriptor, $0.baseAddress, $0.count) }
        guard count == data.count, fsync(descriptor) == 0 else { throw failure("Could not save the complete identity.") }
        if replace {
            _ = try exists(file)
            guard rename(temporary.path, file.path) == 0 else { throw failure("Could not replace the saved identity.") }
        } else {
            guard link(temporary.path, file.path) == 0 else { throw failure("Installation identity already exists or could not be saved.") }
        }
        let parent = open(file.deletingLastPathComponent().path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW)
        guard parent >= 0 else { throw failure("Could not synchronize the identity directory.") }
        defer { close(parent) }
        guard fsync(parent) == 0 else { throw failure("Could not synchronize the saved identity.") }
    }

    static func failure(_ message: String) -> NSError {
        NSError(domain: "BOOXSidecar.Identity", code: 1, userInfo: [NSLocalizedDescriptionKey: message])
    }
}
