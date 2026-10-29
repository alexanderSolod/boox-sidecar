import CoreGraphics
import Foundation

enum InputEvents {
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
