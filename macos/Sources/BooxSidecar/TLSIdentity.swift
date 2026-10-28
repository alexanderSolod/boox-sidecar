import Foundation
import Security
import CryptoKit

/// An app-local identity, pinned through USB provisioning. Never changes system trust.
struct TLSIdentity {
    let identity: SecIdentity
    let fingerprint: String

    static func load(directory: URL? = nil) throws -> TLSIdentity {
        guard #available(macOS 15.0, *) else {
            throw failure("Encrypted Wi-Fi requires macOS 15 or later; USB remains available.")
        }
        let fm = FileManager.default
        let root = directory ?? fm.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("BOOX Sidecar/TLS", isDirectory: true)
        try fm.createDirectory(at: root, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        try fm.setAttributes([.posixPermissions: 0o700], ofItemAtPath: root.path)
        let bundle = root.appendingPathComponent("identity.p12")
        let key = root.appendingPathComponent("private-key.pem")
        let cert = root.appendingPathComponent("certificate.pem")
        // The directory permissions protect the key; this import password is not a network secret.
        let password = "boox-local-identity"
        if !fm.fileExists(atPath: bundle.path) {
            try run(["req", "-x509", "-newkey", "rsa:2048", "-nodes", "-sha256", "-days", "365",
                     "-subj", "/CN=BOOX Sidecar Local", "-keyout", key.path, "-out", cert.path])
            try run(["pkcs12", "-export", "-inkey", key.path, "-in", cert.path,
                     "-out", bundle.path, "-passout", "pass:" + password])
            for file in [key, cert, bundle] { try fm.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path) }
        }
        let data = try Data(contentsOf: bundle)
        var items: CFArray?
        let options = [kSecImportExportPassphrase as String: password,
                       kSecImportToMemoryOnly as String: true] as [String: Any]
        let status = SecPKCS12Import(data as CFData, options as CFDictionary, &items)
        guard status == errSecSuccess, let entries = items as? [[String: Any]],
              let rawIdentity = entries.first?[kSecImportItemIdentity as String] else {
            throw failure("Unable to load the local Wi-Fi identity (Security error \(status)).")
        }
        let identity = rawIdentity as! SecIdentity
        var certificate: SecCertificate?
        guard SecIdentityCopyCertificate(identity, &certificate) == errSecSuccess, let certificate else {
            throw failure("The Wi-Fi identity has no certificate.")
        }
        let der = SecCertificateCopyData(certificate) as Data
        let fingerprint = SHA256.hash(data: der).map { String(format: "%02x", $0) }.joined()
        return TLSIdentity(identity: identity, fingerprint: fingerprint)
    }

    private static func run(_ arguments: [String]) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/openssl")
        process.arguments = arguments
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try process.run()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else { throw failure("Could not generate the local Wi-Fi certificate.") }
    }

    private static func failure(_ message: String) -> NSError {
        NSError(domain: "BOOXSidecar.TLS", code: 1, userInfo: [NSLocalizedDescriptionKey: message])
    }
}
