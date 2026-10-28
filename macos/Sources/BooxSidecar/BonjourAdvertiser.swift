import Foundation

/// Discovery contains public identity only. Token and TLS pin are provisioned over USB.
@MainActor final class BonjourAdvertiser: NSObject, NetServiceDelegate {
    private var service: NetService?
    var onError: ((String) -> Void)?

    func start(hostID: String) {
        stop()
        guard PairingCredentialStore.valid(hostID) else { return }
        let service = NetService(domain: "local.", type: "_boox-sidecar._tcp.", name: "BOOX Sidecar " + hostID.prefix(8), port: 8788)
        service.delegate = self
        service.setTXTRecord(NetService.data(fromTXTRecord: ["host_id": Data(hostID.utf8)]))
        self.service = service
        service.publish()
    }

    func stop() { service?.stop(); service = nil }

    nonisolated func netService(_ sender: NetService, didNotPublish errorDict: [String: NSNumber]) {
        Task { @MainActor in self.onError?("Network discovery could not start. The saved Wi-Fi address and USB are still available.") }
    }
}
