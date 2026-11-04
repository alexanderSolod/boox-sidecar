import CoreGraphics
import Foundation

@main
struct InputEventsTests {
    static func main() throws {
        precondition(InputEvents.clickCount(nil) == 1)
        precondition(InputEvents.clickCount(1) == 1)
        precondition(InputEvents.clickCount(2) == 2)
        for value: Any in [0, 3, -1, 1.5, true, "2", NSNull(), Double.nan] {
            precondition(InputEvents.clickCount(value) == nil)
        }
        for count in [1, 2] {
            let point = CGPoint(x: -200, y: 300)
            let events = InputEvents.click(at: point, count: count)!
            precondition(events.count == 3)
            precondition(events.map(\.type) == [.mouseMoved, .leftMouseDown, .leftMouseUp])
            precondition(events.allSatisfy { $0.location == point })
            precondition(events[1].getIntegerValueField(.mouseEventClickState) == count)
            precondition(events[2].getIntegerValueField(.mouseEventClickState) == count)
        }
        precondition(InputEvents.click(at: .zero, count: 3) == nil)
        let right = InputEvents.click(at: CGPoint(x: 40, y: 50), count: 1, button: .right)!
        precondition(right.map(\.type) == [.mouseMoved, .rightMouseDown, .rightMouseUp])
        precondition(right[1].getIntegerValueField(.mouseEventButtonNumber) == 1)
        precondition(right[2].getIntegerValueField(.mouseEventButtonNumber) == 1)
        precondition(right[1].getIntegerValueField(.mouseEventClickState) == 1)
        precondition(right[2].getIntegerValueField(.mouseEventClickState) == 1)
        precondition(InputEvents.click(at: .zero, count: 2, button: .right) == nil)
        precondition(InputEvents.click(at: .zero, count: 1, button: .center) == nil)
        let anchor = CGPoint(x: -420, y: -210)
        let scroll = InputEvents.scroll(delta: 120, at: anchor)!
        precondition(scroll.map(\.type) == [.mouseMoved, .scrollWheel])
        precondition(scroll.allSatisfy { $0.location == anchor })
        precondition(InputEvents.scroll(delta: -120, at: nil)!.map(\.type) == [.scrollWheel])
        precondition(InputEvents.scroll(delta: .nan, at: anchor) == nil)
        precondition(InputEvents.scroll(delta: 1001, at: anchor) == nil)
        dragChecks()
        print("PASS: click, anchored scroll, drag ownership, lease and release events")
    }

    private static func dragChecks() {
        let id = UUID(uuidString: "FB9FD984-E6D8-43FC-B9DC-2739B069FC9B")!
        let other = UUID(uuidString: "7EBCBA8D-7390-454A-B333-B57C544C03EF")!
        let bounds = CGRect(x: -1000, y: -500, width: 801, height: 601)
        func command(_ phase: String, _ x: Double = 0, _ y: Double = 0, _ identity: UUID = id) -> InputEvents.DragCommand {
            InputEvents.DragCommand(["drag_id": identity.uuidString, "phase": phase, "x": x, "y": y])!
        }
        let valid: [String: Any] = ["drag_id": id.uuidString, "phase": "start", "x": 0.5, "y": 0.5]
        for (key, value) in [("drag_id", "not-a-uuid" as Any), ("phase", "unknown" as Any),
                             ("x", true as Any), ("x", -0.1 as Any), ("y", 1.1 as Any),
                             ("y", Double.nan as Any), ("x", "0.5" as Any)] {
            var invalid = valid
            invalid[key] = value
            precondition(InputEvents.DragCommand(invalid) == nil)
        }
        var missing = valid
        missing.removeValue(forKey: "y")
        precondition(InputEvents.DragCommand(missing) == nil)
        var state = InputEvents.DragState()
        let start = try! state.apply(command("start"), captureSession: "capture-one", bounds: bounds, now: 10)
        precondition(start.map(\.type) == [.mouseMoved, .leftMouseDown])
        precondition(start.allSatisfy { $0.point == bounds.origin })
        precondition(state.active?.deadline == 12)
        let startEvents = InputEvents.mouse(start)!
        precondition(startEvents.last?.getIntegerValueField(.mouseEventClickState) == 1)
        reject { _ = try state.apply(command("start"), captureSession: "capture-one", bounds: bounds, now: 10.1) }
        reject { _ = try state.apply(command("start", 0, 0, other), captureSession: "capture-one", bounds: bounds, now: 10.1) }
        reject { _ = try state.apply(command("move", 1, 1, other), captureSession: "capture-one", bounds: bounds, now: 10.1) }
        reject { _ = try state.apply(command("move", 1, 1), captureSession: "capture-two", bounds: bounds, now: 10.1) }
        precondition(state.active?.point == bounds.origin && state.active?.deadline == 12)
        let moved = try! state.apply(command("move", 1, 1), captureSession: "capture-one", bounds: bounds, now: 10.5)
        precondition(moved == [.init(type: .leftMouseDragged, point: CGPoint(x: -200, y: 100))])
        precondition(state.active?.deadline == 12.5)
        let heartbeat = try! state.apply(command("move", 1, 1), captureSession: "capture-one", bounds: bounds, now: 11)
        precondition(heartbeat == moved && state.active?.deadline == 13)
        let ended = try! state.apply(command("end", 0.5, 0.5), captureSession: "capture-one", bounds: bounds, now: 11.5)
        precondition(ended.map(\.type) == [.leftMouseDragged, .leftMouseUp])
        precondition(ended.allSatisfy { $0.point == CGPoint(x: -600, y: -200) })
        precondition(InputEvents.mouse(ended)!.last?.getIntegerValueField(.mouseEventClickState) == 1)
        precondition(state.active == nil && state.release().isEmpty)
        reject { _ = try state.apply(command("move"), captureSession: "capture-one", bounds: bounds, now: 11.6) }
        reject { _ = try state.apply(command("end"), captureSession: "capture-one", bounds: bounds, now: 11.6) }

        _ = try! state.apply(command("start"), captureSession: "capture-one", bounds: bounds, now: 20)
        _ = try! state.apply(command("move", 0.25, 0.75), captureSession: "capture-one", bounds: bounds, now: 20.5)
        let cancelled = try! state.apply(command("cancel", 0.9, 0.9), captureSession: "capture-one", bounds: bounds, now: 21)
        precondition(cancelled == [.init(type: .leftMouseUp, point: CGPoint(x: -800, y: -50))])
        precondition(state.release().isEmpty)
        reject { _ = try state.apply(command("cancel"), captureSession: "capture-one", bounds: bounds, now: 21.1) }

        _ = try! state.apply(command("start"), captureSession: "capture-one", bounds: bounds, now: 30)
        let revoked = state.release()
        precondition(revoked == [.init(type: .leftMouseUp, point: bounds.origin)])
        precondition(state.release().isEmpty)
        reject { _ = try state.apply(command("move"), captureSession: "capture-one", bounds: bounds, now: 30.5) }

        _ = try! state.apply(command("start"), captureSession: "capture-one", bounds: bounds, now: 40)
        reject { _ = try state.apply(command("move"), captureSession: "capture-one", bounds: bounds, now: 42) }
        precondition(state.active?.deadline == 42)
        precondition(state.release().map(\.type) == [.leftMouseUp])
        precondition(state.release().isEmpty)
        reject { _ = try state.apply(command("move"), captureSession: "capture-one", bounds: bounds, now: 42.1) }
    }

    private static func reject(_ operation: () throws -> Void) {
        do { try operation(); preconditionFailure("Invalid drag was accepted") }
        catch { }
    }
}
