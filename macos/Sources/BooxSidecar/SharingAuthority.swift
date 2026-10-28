import Foundation

final class SharingAuthority: @unchecked Sendable {
    private let lock = NSLock()
    private var generation: UInt64 = 0

    struct Ticket: Sendable {
        fileprivate let authority: SharingAuthority
        fileprivate let generation: UInt64
        fileprivate let expiresAt: Date?

        @discardableResult func perform(_ operation: () -> Void) -> Bool {
            authority.lock.lock()
            defer { authority.lock.unlock() }
            guard generation == authority.generation,
                  expiresAt.map({ Date() < $0 }) ?? true else { return false }
            operation()
            return true
        }
    }

    func invalidate() {
        lock.lock()
        defer { lock.unlock() }
        generation &+= 1
    }

    func ticket(expiresAt: Date? = nil) -> Ticket {
        lock.lock()
        defer { lock.unlock() }
        return Ticket(authority: self, generation: generation, expiresAt: expiresAt)
    }

    static func matchesCredential(header: String?, token: String) -> Bool {
        let expected = Array(token.utf8)
        guard expected.count == 64, expected.allSatisfy({ (48...57).contains($0) || (97...102).contains($0) }),
              let header else { return false }
        let supplied = Array(header.utf8)
        let prefix = Array("Bearer ".utf8)
        guard supplied.count == prefix.count + expected.count,
              supplied.prefix(prefix.count).elementsEqual(prefix) else { return false }
        var difference: UInt8 = 0
        for index in expected.indices { difference |= expected[index] ^ supplied[index + prefix.count] }
        return difference == 0
    }
}
