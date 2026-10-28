import Foundation

struct USBProvisioningState: Sendable {
    private struct Retry: Sendable {
        var attempts = 0
        var deadline: TimeInterval = 0
    }

    private(set) var discovered = Set<String>()
    private(set) var provisioned = Set<String>()
    private var retries: [String: Retry] = [:]

    mutating func updateDiscovered(_ devices: Set<String>) {
        discovered = devices
        provisioned.formIntersection(devices)
        retries = retries.filter { devices.contains($0.key) }
    }

    func shouldProvision(_ serial: String, now: TimeInterval, explicit: Bool = false) -> Bool {
        discovered.contains(serial) && (explicit || (!provisioned.contains(serial) && now >= (retries[serial]?.deadline ?? 0)))
    }

    mutating func succeeded(_ serial: String) {
        guard discovered.contains(serial) else { return }
        provisioned.insert(serial)
        retries.removeValue(forKey: serial)
    }

    mutating func failed(_ serial: String, now: TimeInterval) {
        guard discovered.contains(serial) else { return }
        provisioned.remove(serial)
        var retry = retries[serial] ?? Retry()
        let delay = min(30, 3 * pow(2, Double(min(retry.attempts, 4))))
        retry.attempts = min(4, retry.attempts + 1)
        retry.deadline = now + delay
        retries[serial] = retry
    }
}
