import Foundation
import CoreGraphics

@main struct VirtualDisplayPlacementTests {
    static func expect(_ condition: @autoclosure () -> Bool, _ message: String) {
        if !condition() { fatalError(message) }
    }

    static func main() {
        let size = CGSize(width: 1240, height: 930)
        let main = CGRect(x: 0, y: 0, width: 1440, height: 900)
        let right = CGRect(x: 1440, y: -100, width: 1920, height: 1080)
        let left = CGRect(x: -1920, y: -100, width: 1920, height: 1080)
        let above = CGRect(x: 0, y: -1080, width: 1920, height: 1080)
        var placement = VirtualDisplayPlacement()
        expect(placement.preferredOrigin(size: size, otherDisplays: [main]) == CGPoint(x: 1440, y: 0), "First run must adjoin main display")
        expect(placement.preferredOrigin(size: size, otherDisplays: [main, right]) == CGPoint(x: 3360, y: -100), "Right monitor must not overlap")
        expect(placement.preferredOrigin(size: size, otherDisplays: [main, left]) == CGPoint(x: 1440, y: 0), "Negative origins must remain valid")
        expect(placement.preferredOrigin(size: size, otherDisplays: [main, above]) == CGPoint(x: 1920, y: -1080), "Staggered top monitor must remain reachable")

        placement.arranged(at: CGPoint(x: 1440, y: 0))
        placement.observe(origin: CGPoint(x: -1240, y: 0), size: size, otherDisplays: [main])
        let saved = placement.data
        placement.removed()
        expect(placement.savedOrigin == CGPoint(x: -1240, y: 0), "Removal must retain the chosen origin")
        placement = VirtualDisplayPlacement(data: saved)
        expect(placement.preferredOrigin(size: size, otherDisplays: [main]) == CGPoint(x: -1240, y: 0), "Restart must restore left placement without a display ID")
        placement.arranged(at: CGPoint(x: -1240, y: 0))
        placement.observe(origin: CGPoint(x: 0, y: -930), size: size, otherDisplays: [main])
        expect(VirtualDisplayPlacement(data: placement.data).savedOrigin == CGPoint(x: 0, y: -930), "Above placement must survive restart")

        placement = VirtualDisplayPlacement(data: saved)
        let fallback = placement.preferredOrigin(size: size, otherDisplays: [main, left])!
        placement.arranged(at: fallback)
        placement.observe(origin: fallback, size: size, otherDisplays: [main, left])
        expect(placement.savedOrigin == CGPoint(x: -1240, y: 0), "Automatic fallback callbacks must preserve the original preference")
        placement.removed()
        expect(placement.preferredOrigin(size: size, otherDisplays: [main]) == CGPoint(x: -1240, y: 0), "Returning topology must recover the saved position")
        placement.arranged(at: CGPoint(x: -1240, y: 0))
        placement.observe(origin: CGPoint(x: 0, y: 0), size: size, otherDisplays: [main])
        expect(placement.savedOrigin == CGPoint(x: -1240, y: 0), "Transient overlapping geometry must not overwrite placement")

        for origin in [CGPoint(x: 0, y: 0), CGPoint(x: 5000, y: 0), CGPoint(x: 1440, y: 900), CGPoint(x: CGFloat.infinity, y: 0), CGPoint(x: CGFloat(Int32.max) + 1, y: 0), CGPoint(x: 1440.5, y: 0)] {
            expect(!VirtualDisplayPlacement.isUsable(origin: origin, size: size, otherDisplays: [main]), "Invalid origin accepted: \(origin)")
        }
        for json in ["{}", "{\"version\":2,\"x\":1440,\"y\":0}", "{\"version\":1,\"x\":true,\"y\":0}", "{\"version\":1,\"x\":2147483648,\"y\":0}"] {
            expect(VirtualDisplayPlacement(data: Data(json.utf8)).savedOrigin == nil, "Malformed preferences must be ignored")
        }
        expect(placement.preferredOrigin(size: size, otherDisplays: []) == nil, "Missing desktop must not invent a placement")
        print("PASS: virtual display placement, persistence, topology changes and invalid geometry")
    }
}
