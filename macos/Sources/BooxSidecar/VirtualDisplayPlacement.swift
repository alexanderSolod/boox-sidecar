import Foundation
import CoreGraphics

struct VirtualDisplayPlacement {
    private struct Preference: Codable {
        let version: Int
        let x: Double
        let y: Double
    }

    private(set) var savedOrigin: CGPoint?
    private(set) var observedOrigin: CGPoint?

    init(data: Data? = nil) {
        if let data, let preference = try? JSONDecoder().decode(Preference.self, from: data), preference.version == 1 {
            let origin = CGPoint(x: preference.x, y: preference.y)
            if Self.validOrigin(origin) { savedOrigin = origin }
        }
    }

    var data: Data? {
        savedOrigin.flatMap { try? JSONEncoder().encode(Preference(version: 1, x: $0.x, y: $0.y)) }
    }

    func preferredOrigin(size: CGSize, otherDisplays: [CGRect], mainDisplay: CGRect? = nil, onLeft: Bool = false) -> CGPoint? {
        if let savedOrigin, Self.isUsable(origin: savedOrigin, size: size, otherDisplays: otherDisplays) { return savedOrigin }
        if let mainDisplay {
            let origin = CGPoint(x: onLeft ? mainDisplay.minX - size.width : mainDisplay.maxX, y: mainDisplay.minY)
            if Self.isUsable(origin: origin, size: size, otherDisplays: otherDisplays) { return origin }
        }
        guard let outermost = otherDisplays.filter(Self.validBounds).sorted(by: {
            let first = onLeft ? $0.minX : $0.maxX
            let second = onLeft ? $1.minX : $1.maxX
            if first != second { return onLeft ? first < second : first > second }
            return $0.minY < $1.minY
        }).first else { return nil }
        let origin = CGPoint(x: onLeft ? outermost.minX - size.width : outermost.maxX, y: outermost.minY)
        return Self.isUsable(origin: origin, size: size, otherDisplays: otherDisplays) ? origin : nil
    }

    mutating func arranged(at origin: CGPoint) {
        observedOrigin = origin
        if savedOrigin == nil { savedOrigin = origin }
    }

    mutating func observe(origin: CGPoint, size: CGSize, otherDisplays: [CGRect]) {
        guard Self.isUsable(origin: origin, size: size, otherDisplays: otherDisplays) else { return }
        if let observedOrigin, observedOrigin != origin { savedOrigin = origin }
        observedOrigin = origin
    }

    mutating func removed() { observedOrigin = nil }

    static func isUsable(origin: CGPoint, size: CGSize, otherDisplays: [CGRect]) -> Bool {
        let bounds = CGRect(origin: origin, size: size)
        guard validOrigin(origin), validBounds(bounds), !otherDisplays.isEmpty,
              otherDisplays.allSatisfy(validBounds) else { return false }
        var adjoining = false
        for other in otherDisplays {
            let overlapX = min(bounds.maxX, other.maxX) - max(bounds.minX, other.minX)
            let overlapY = min(bounds.maxY, other.maxY) - max(bounds.minY, other.minY)
            if overlapX > 0 && overlapY > 0 { return false }
            if (bounds.maxX == other.minX || bounds.minX == other.maxX) && overlapY > 0 { adjoining = true }
            if (bounds.maxY == other.minY || bounds.minY == other.maxY) && overlapX > 0 { adjoining = true }
        }
        return adjoining
    }

    private static func validOrigin(_ origin: CGPoint) -> Bool {
        [origin.x, origin.y].allSatisfy { $0.isFinite && $0.rounded() == $0 && $0 >= CGFloat(Int32.min) && $0 <= CGFloat(Int32.max) }
    }

    private static func validBounds(_ bounds: CGRect) -> Bool {
        bounds.origin.x.isFinite && bounds.origin.y.isFinite && bounds.width.isFinite && bounds.height.isFinite && bounds.width > 0 && bounds.height > 0 && bounds.maxX.isFinite && bounds.maxY.isFinite
    }
}
