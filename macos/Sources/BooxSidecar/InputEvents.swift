import CoreGraphics
import Foundation

enum InputEvents {
    static func clickCount(_ value: Any?) -> Int? {
        guard let value else { return 1 }
        guard let number = value as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID(),
              number.doubleValue == 1 || number.doubleValue == 2 else { return nil }
        return number.intValue
    }

    static func click(at point: CGPoint, count: Int) -> [CGEvent]? {
        guard (1...2).contains(count),
              let move = CGEvent(mouseEventSource: nil, mouseType: .mouseMoved, mouseCursorPosition: point, mouseButton: .left),
              let down = CGEvent(mouseEventSource: nil, mouseType: .leftMouseDown, mouseCursorPosition: point, mouseButton: .left),
              let up = CGEvent(mouseEventSource: nil, mouseType: .leftMouseUp, mouseCursorPosition: point, mouseButton: .left) else { return nil }
        down.setIntegerValueField(.mouseEventClickState, value: Int64(count))
        up.setIntegerValueField(.mouseEventClickState, value: Int64(count))
        return [move, down, up]
    }
}
