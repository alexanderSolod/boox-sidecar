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
        print("29 click event checks passed")
    }
}
