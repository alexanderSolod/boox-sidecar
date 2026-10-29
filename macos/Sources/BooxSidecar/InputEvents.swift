import CoreGraphics
import Foundation

enum InputEvents {
    struct MouseAction: Equatable {
        let type: CGEventType
        let point: CGPoint
    }

    enum DragPhase: String { case start, move, end, cancel }

    struct DragCommand {
        let id: UUID
        let phase: DragPhase
        let point: CGPoint

        init?(_ object: [String: Any]) {
            guard let rawID = object["drag_id"] as? String, let id = UUID(uuidString: rawID),
                  let rawPhase = object["phase"] as? String, let phase = DragPhase(rawValue: rawPhase),
                  let point = InputEvents.normalizedPoint(object) else { return nil }
            self.id = id
            self.phase = phase
            self.point = point
        }
    }

    struct DragState {
        struct Active {
            let id: UUID
            let captureSession: String
            var point: CGPoint
            var deadline: TimeInterval
        }

        enum Failure: Error { case alreadyActive, inactive, expired }
        private(set) var active: Active?

        mutating func apply(_ command: DragCommand, captureSession: String, bounds: CGRect, now: TimeInterval) throws -> [MouseAction] {
            let point = InputEvents.displayPoint(command.point, bounds: bounds)
            if command.phase == .start {
                guard active == nil else { throw Failure.alreadyActive }
                active = Active(id: command.id, captureSession: captureSession, point: point, deadline: now + 2)
                return [MouseAction(type: .mouseMoved, point: point), MouseAction(type: .leftMouseDown, point: point)]
            }
            guard var current = active, current.id == command.id, current.captureSession == captureSession else { throw Failure.inactive }
            guard now < current.deadline else { throw Failure.expired }
            switch command.phase {
            case .move:
                current.point = point
                current.deadline = now + 2
                active = current
                return [MouseAction(type: .leftMouseDragged, point: point)]
            case .end:
                active = nil
                return [MouseAction(type: .leftMouseDragged, point: point), MouseAction(type: .leftMouseUp, point: point)]
            case .cancel:
                return release()
            case .start:
                throw Failure.alreadyActive
            }
        }

        mutating func release() -> [MouseAction] {
            guard let current = active else { return [] }
            active = nil
            return [MouseAction(type: .leftMouseUp, point: current.point)]
        }
    }

    static func normalizedPoint(_ object: [String: Any]) -> CGPoint? {
        guard let x = object["x"] as? NSNumber, CFGetTypeID(x) != CFBooleanGetTypeID(),
              let y = object["y"] as? NSNumber, CFGetTypeID(y) != CFBooleanGetTypeID(),
              x.doubleValue.isFinite, y.doubleValue.isFinite,
              (0...1).contains(x.doubleValue), (0...1).contains(y.doubleValue) else { return nil }
        return CGPoint(x: x.doubleValue, y: y.doubleValue)
    }

    static func displayPoint(_ normalized: CGPoint, bounds: CGRect) -> CGPoint {
        CGPoint(x: bounds.minX + normalized.x * max(0, bounds.width - 1),
                y: bounds.minY + normalized.y * max(0, bounds.height - 1))
    }

    static func mouse(_ actions: [MouseAction]) -> [CGEvent]? {
        var events: [CGEvent] = []
        for action in actions {
            guard let event = CGEvent(mouseEventSource: nil, mouseType: action.type,
                                      mouseCursorPosition: action.point, mouseButton: .left) else { return nil }
            if action.type != .mouseMoved { event.setIntegerValueField(.mouseEventClickState, value: 1) }
            events.append(event)
        }
        return events
    }

    static func scroll(delta: Double, at point: CGPoint?) -> [CGEvent]? {
        guard delta.isFinite, (-1000...1000).contains(delta),
              let scroll = CGEvent(scrollWheelEvent2Source: nil, units: .pixel, wheelCount: 1,
                                   wheel1: Int32(delta), wheel2: 0, wheel3: 0) else { return nil }
        var events: [CGEvent] = []
        if let point {
            scroll.location = point
            guard let move = CGEvent(mouseEventSource: nil, mouseType: .mouseMoved,
                                     mouseCursorPosition: point, mouseButton: .left) else { return nil }
            events.append(move)
        }
        events.append(scroll)
        return events
    }

    static func clickCount(_ value: Any?) -> Int? {
        guard let value else { return 1 }
        guard let number = value as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID(),
              number.doubleValue == 1 || number.doubleValue == 2 else { return nil }
        return number.intValue
    }

    static func click(at point: CGPoint, count: Int, button: CGMouseButton = .left) -> [CGEvent]? {
        guard (1...2).contains(count), button == .left || (button == .right && count == 1),
              let move = CGEvent(mouseEventSource: nil, mouseType: .mouseMoved, mouseCursorPosition: point, mouseButton: .left),
              let down = CGEvent(mouseEventSource: nil, mouseType: button == .right ? .rightMouseDown : .leftMouseDown, mouseCursorPosition: point, mouseButton: button),
              let up = CGEvent(mouseEventSource: nil, mouseType: button == .right ? .rightMouseUp : .leftMouseUp, mouseCursorPosition: point, mouseButton: button) else { return nil }
        down.setIntegerValueField(.mouseEventClickState, value: Int64(count))
        up.setIntegerValueField(.mouseEventClickState, value: Int64(count))
        return [move, down, up]
    }
}
