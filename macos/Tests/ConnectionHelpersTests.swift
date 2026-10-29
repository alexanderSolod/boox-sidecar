import Foundation
import Darwin

/// Standalone tests: run with the helper source files; never opens adb or the app.
@main struct ConnectionHelpersTests {
    static func expect(_ condition: @autoclosure () -> Bool, _ message: String) {
        if !condition() { fatalError(message) }
    }

    static func main() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("boox-pairing-tests-" + UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = PairingCredentialStore(directory: root)
        let first = try store.loadOrCreate()
        expect(PairingCredentialStore.valid(first), "Token must be 256-bit lowercase hex")
        let again = try store.loadOrCreate()
        expect(first == again, "Relaunch must retain pairing")
        var info = stat()
        expect(lstat(store.file.path, &info) == 0 && (info.st_mode & 0o777) == 0o600, "Credential must be 0600")
        expect(lstat(root.path, &info) == 0 && (info.st_mode & 0o777) == 0o700, "Directory must be 0700")
        chmod(store.file.path, 0o644)
        _ = try store.loadOrCreate()
        expect(lstat(store.file.path, &info) == 0 && (info.st_mode & 0o777) == 0o600, "Reload must correct excessive permissions")
        let second = try store.rotate()
        expect(second != first && second == (try? store.loadOrCreate()), "Explicit rotation must replace and persist token")
        try Data("invalid".utf8).write(to: store.file)
        do { _ = try store.loadOrCreate(); fatalError("Malformed credential accepted") } catch { }
        try FileManager.default.removeItem(at: store.file)
        let external = root.appendingPathComponent("not-a-credential")
        try Data(repeating: 97, count: 64).write(to: external)
        try FileManager.default.createSymbolicLink(at: store.file, withDestinationURL: external)
        do { _ = try store.loadOrCreate(); fatalError("Symlink credential accepted") } catch { }

        let listing = """
        List of devices attached
        BOOX123 device usb:1234 product:NoteAir4C model:NoteAir4C transport_id:1
        WAIT123 unauthorized usb:1235 transport_id:2
        10.0.0.8:5555 device product:NoteAir4C transport_id:3
        """
        let devices = DevicePairing.parseDevices(listing)
        expect(devices.count == 1 && devices.first?.serial == "BOOX123", "Only authorized physical USB devices should be considered")
        expect(DevicePairing.hasReverse("UsbFfs tcp:8787 tcp:8787\n", port: 8787), "Existing exact reverse tunnel must be reused")
        expect(!DevicePairing.hasReverse("UsbFfs tcp:8787 tcp:9999\n", port: 8787), "Incorrect reverse destination must be repaired")
        expect(DevicePairing.outputIndicatesFailure("Starting: Intent\nError type 3\nError: Activity class does not exist."), "adb exit-zero activity failures must be detected")
        expect(!DevicePairing.outputIndicatesFailure("Starting: Intent { cmp=local.boox.sidecar/.MainActivity }\nWarning: Activity not started, intent has been delivered to currently running top-most instance."), "Delivery to an existing activity is success")
        expect(DevicePairing.broadcastAccepted("Broadcasting: Intent { flg=0x20 cmp=local.boox.sidecar/.ProvisioningReceiver (has extras) }\nBroadcast completed: result=-1\n"), "Accepted pairing must be detected")
        expect(!DevicePairing.broadcastAccepted("Broadcasting: Intent { flg=0x20 cmp=local.boox.sidecar/.ProvisioningReceiver (has extras) }\nBroadcast completed: result=0, data=\"Update both apps and pair over USB again.\"\n"), "Rejected pairing must be detected")
        expect(!DevicePairing.broadcastAccepted("Broadcasting: Intent { flg=0x20 cmp=local.boox.sidecar/.ProvisioningReceiver (has extras) }\nBroadcast completed: result=0\n"), "A missing receiver must not count as pairing")
        expect(!DevicePairing.broadcastAccepted("Broadcast completed: result=-10"), "Only the exact accepted result counts")
        print("PASS: credential persistence, permissions, rotation, malformed/symlink refusal, USB parsing, tunnel reuse and adb error detection")
    }
}
