import Foundation

@main struct USBProvisioningTests {
    static func main() {
        var state = USBProvisioningState()
        state.updateDiscovered(["first", "second"])
        precondition(state.shouldProvision("first", now: 0))
        state.failed("first", now: 0)
        state.succeeded("second")
        precondition(!state.shouldProvision("first", now: 2.9))
        precondition(state.shouldProvision("first", now: 3))
        precondition(!state.shouldProvision("second", now: 100))
        precondition(state.shouldProvision("first", now: 1, explicit: true))
        precondition(state.shouldProvision("second", now: 1, explicit: true))
        var now: TimeInterval = 3
        for delay: TimeInterval in [6, 12, 24, 30, 30, 30] {
            state.failed("first", now: now)
            precondition(!state.shouldProvision("first", now: now + delay - 0.1))
            precondition(state.shouldProvision("first", now: now + delay))
            now += delay
        }
        state.succeeded("first")
        precondition(!state.shouldProvision("first", now: now + 1000))
        state.updateDiscovered(["second"])
        state.updateDiscovered(["first", "second"])
        precondition(state.shouldProvision("first", now: now))
        precondition(!state.shouldProvision("second", now: now))
        state.failed("first", now: now)
        state.updateDiscovered([])
        state.updateDiscovered(["first"])
        precondition(state.shouldProvision("first", now: now))
        state.succeeded("removed")
        precondition(!state.provisioned.contains("removed"))
        precondition(!state.shouldProvision("removed", now: now, explicit: true))
        print("PASS: USB provisioning retry, backoff, success and disconnect state")
    }
}
