import Foundation
import Security
import CryptoKit

struct TLSIdentity {
    let identity: SecIdentity
    let fingerprint: String
    let spkiPin: String
    let notBefore: Date
    let expiresAt: Date
    var renewalError: String?

    static let renewalWindow: TimeInterval = 30 * 24 * 60 * 60
    private static let password = "boox-local-identity"

    func valid(at now: Date) -> Bool { now >= notBefore && now < expiresAt }
    func needsRenewal(at now: Date) -> Bool { expiresAt.timeIntervalSince(now) < Self.renewalWindow }

    static func load(directory: URL? = nil, now: Date = Date()) throws -> TLSIdentity {
        guard #available(macOS 15.0, *) else { throw failure("Secure native connections require macOS 15 or later.") }
        let root = directory ?? PairingCredentialStore.applicationDirectory.appendingPathComponent("TLS", isDirectory: true)
        try PrivateIdentityFiles.prepare(root)
        let bundle = root.appendingPathComponent("identity.p12")
        let stage = root.appendingPathComponent(".tls-" + UUID().uuidString, isDirectory: true)
        try PrivateIdentityFiles.prepare(stage)
        defer { try? FileManager.default.removeItem(at: stage) }

        var current: TLSIdentity?
        if try PrivateIdentityFiles.exists(bundle) {
            let data = try PrivateIdentityFiles.read(bundle)
            current = try decode(data, stage: stage)
            if let current, current.valid(at: now), !current.needsRenewal(at: now) { return current }
        }
        do {
            let key = stage.appendingPathComponent("private-key.pem")
            let certificate = stage.appendingPathComponent("certificate.pem")
            let replacement = stage.appendingPathComponent("replacement.p12")
            if current != nil {
                let saved = stage.appendingPathComponent("saved.p12")
                try PrivateIdentityFiles.publish(try PrivateIdentityFiles.read(bundle), to: saved)
                try run(["pkcs12", "-in", saved.path, "-passin", "pass:" + password, "-nocerts", "-nodes", "-out", key.path])
            } else {
                let legacyKey = root.appendingPathComponent("private-key.pem")
                let legacyCert = root.appendingPathComponent("certificate.pem")
                if try PrivateIdentityFiles.exists(legacyKey) {
                    try PrivateIdentityFiles.publish(try PrivateIdentityFiles.read(legacyKey), to: key)
                } else {
                    guard try !PrivateIdentityFiles.exists(legacyCert) else { throw failure("The saved TLS private key is missing. Re-pair after an explicit identity reset.") }
                    try run(["genrsa", "-out", key.path, "2048"])
                }
            }
            try run(["req", "-new", "-x509", "-key", key.path, "-sha256", "-days", "365",
                     "-set_serial", "0x" + String(try PairingCredentialStore.randomToken().prefix(32)),
                     "-subj", "/CN=BOOX Sidecar Local", "-out", certificate.path])
            try run(["pkcs12", "-export", "-inkey", key.path, "-in", certificate.path,
                     "-out", replacement.path, "-passout", "pass:" + password])
            let data = try PrivateIdentityFiles.read(replacement)
            let renewed = try decode(data, stage: stage)
            guard renewed.valid(at: max(now, Date())) else { throw failure("The renewed TLS certificate is outside its validity period. Check this Mac's clock.") }
            if let current, current.spkiPin != renewed.spkiPin { throw failure("Certificate renewal changed the paired key.") }
            try PrivateIdentityFiles.publish(data, to: bundle, replace: current != nil)
            return renewed
        } catch {
            if var current, current.valid(at: now) {
                current.renewalError = "Certificate renewal failed: " + error.localizedDescription
                return current
            }
            throw error
        }
    }

    @available(macOS 15.0, *)
    private static func decode(_ data: Data, stage: URL) throws -> TLSIdentity {
        var items: CFArray?
        let options = [kSecImportExportPassphrase as String: password,
                       kSecImportToMemoryOnly as String: true] as [String: Any]
        let status = SecPKCS12Import(data as CFData, options as CFDictionary, &items)
        guard status == errSecSuccess, let entries = items as? [[String: Any]],
              let rawIdentity = entries.first?[kSecImportItemIdentity as String] else {
            throw failure("Unable to load the local TLS identity (Security error \(status)).")
        }
        let identity = rawIdentity as! SecIdentity
        var certificate: SecCertificate?
        guard SecIdentityCopyCertificate(identity, &certificate) == errSecSuccess, let certificate else {
            throw failure("The TLS identity has no certificate.")
        }
        let der = SecCertificateCopyData(certificate) as Data
        let input = stage.appendingPathComponent("public-certificate.der")
        let publicKey = stage.appendingPathComponent("public-key.pem")
        let spki = stage.appendingPathComponent("public-key.der")
        try PrivateIdentityFiles.publish(der, to: input)
        try PrivateIdentityFiles.publish(try run(["x509", "-in", input.path, "-inform", "DER", "-pubkey", "-noout"]), to: publicKey)
        try run(["pkey", "-pubin", "-in", publicKey.path, "-outform", "DER", "-out", spki.path])
        guard let values = SecCertificateCopyValues(certificate, [kSecOIDX509V1ValidityNotBefore, kSecOIDX509V1ValidityNotAfter] as CFArray, nil) as? [String: [String: Any]],
              let before = values[kSecOIDX509V1ValidityNotBefore as String]?[kSecPropertyKeyValue as String] as? NSNumber,
              let after = values[kSecOIDX509V1ValidityNotAfter as String]?[kSecPropertyKeyValue as String] as? NSNumber else {
            throw failure("The TLS certificate has no valid lifetime.")
        }
        return TLSIdentity(identity: identity, fingerprint: digest(der), spkiPin: digest(try PrivateIdentityFiles.read(spki)),
                           notBefore: Date(timeIntervalSinceReferenceDate: before.doubleValue),
                           expiresAt: Date(timeIntervalSinceReferenceDate: after.doubleValue))
    }

    private static func digest(_ data: Data) -> String { SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined() }

    @discardableResult private static func run(_ arguments: [String]) throws -> Data {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/openssl")
        process.arguments = arguments
        let output = Pipe()
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        try process.run()
        let data = output.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else { throw failure("Could not generate or inspect the local TLS identity (openssl \(arguments[0])).") }
        return data
    }

    private static func failure(_ message: String) -> NSError {
        NSError(domain: "BOOXSidecar.TLS", code: 1, userInfo: [NSLocalizedDescriptionKey: message])
    }
}
