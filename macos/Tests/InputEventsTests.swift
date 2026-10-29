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
        print("22 click event checks passed")
    }
}
