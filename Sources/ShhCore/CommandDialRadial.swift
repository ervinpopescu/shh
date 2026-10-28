import CoreGraphics
import Foundation

public enum DialLevelTransition: Equatable, Sendable {
    case enter, back
}

/// Geometry shared by the command dial's visual layout and polar hit testing.
/// Angles use UIKit coordinates: zero points east and positive values rotate
/// clockwise. The layout is an arc so a corner-mounted puck keeps every item
/// inside the reachable part of the screen.
public struct DialRadialLayout: Equatable, Sendable {
    public let center: CGPoint
    public let orbitRadius: CGFloat
    public let itemRadius: CGFloat
    public let itemSize: CGSize
    public let startAngle: CGFloat
    public let endAngle: CGFloat
    public let count: Int

    public init(
        center: CGPoint, orbitRadius: CGFloat, itemRadius: CGFloat,
        itemSize: CGSize? = nil,
        startAngle: CGFloat, endAngle: CGFloat, count: Int
    ) {
        self.center = center
        self.orbitRadius = max(0, orbitRadius)
        self.itemRadius = max(1, itemRadius)
        self.itemSize = itemSize ?? CGSize(width: itemRadius * 2, height: itemRadius * 2)
        self.startAngle = startAngle
        self.endAngle = endAngle
        self.count = max(0, count)
    }

    public var positions: [CGPoint] {
        guard count > 0 else { return [] }
        guard count > 1 else { return [point(atAngle: (startAngle + endAngle) / 2)] }
        let step = (endAngle - startAngle) / CGFloat(count - 1)
        return (0..<count).map { point(atAngle: startAngle + CGFloat($0) * step) }
    }

    public func point(at index: Int) -> CGPoint? {
        guard positions.indices.contains(index) else { return nil }
        return positions[index]
    }

    /// Returns the item under a touch using the visible card bounds, with a
    /// small touch slop. Cards are not circles, so hit testing their actual
    /// rectangles keeps drag release and button taps aligned with what is seen.
    public func index(at point: CGPoint) -> Int? {
        guard count > 0 else { return nil }
        let halfWidth = itemSize.width / 2 + 10
        let halfHeight = itemSize.height / 2 + 10
        return positions.enumerated()
            .filter { _, position in
                abs(point.x - position.x) <= halfWidth
                    && abs(point.y - position.y) <= halfHeight
            }
            .min { lhs, rhs in
                let left = positions[lhs.offset]
                let right = positions[rhs.offset]
                return distanceSquared(from: point, to: left)
                    < distanceSquared(from: point, to: right)
            }?.offset
    }

    public static func corner(
        center: CGPoint, radius: CGFloat, itemRadius: CGFloat,
        itemSize: CGSize? = nil, count: Int, placement: CommandDialPlacement
    ) -> Self {
        let start: CGFloat
        let end: CGFloat
        switch placement {
        case .leading:
            // The open wheel grows above and inward from the lower-left puck.
            start = 0
            end = -.pi * 0.54
        case .trailing:
            // The open wheel grows above and inward from the lower-right puck.
            start = .pi
            end = .pi * 1.54
        }
        let insetFraction: CGFloat
        switch count {
        case 0, 1: insetFraction = 0
        case 2: insetFraction = 0.16
        case 3: insetFraction = 0.07
        default: insetFraction = 0
        }
        let span = end - start
        return Self(
            center: center, orbitRadius: radius, itemRadius: itemRadius,
            itemSize: itemSize,
            startAngle: start + span * insetFraction,
            endAngle: end - span * insetFraction, count: count)
    }

    /// A drag crossing the outer edge drills into a highlighted group; a drag
    /// from the orbit toward the puck returns one level. Neither crossing fires
    /// a leaf action. The view keeps taps and release-to-activate separate.
    public func levelTransition(
        from previous: CGPoint, to location: CGPoint,
        selectedGroup: Bool, hasParent: Bool
    ) -> DialLevelTransition? {
        let oldDistance = hypot(previous.x - center.x, previous.y - center.y)
        let newDistance = hypot(location.x - center.x, location.y - center.y)
        if hasParent && oldDistance > itemRadius * 1.15
            && newDistance <= itemRadius * 1.15
        {
            return .back
        }
        if selectedGroup && oldDistance <= orbitRadius + itemRadius * 1.15
            && newDistance > orbitRadius + itemRadius * 1.15
        {
            return .enter
        }
        return nil
    }

    private func point(atAngle angle: CGFloat) -> CGPoint {
        CGPoint(
            x: center.x + cos(angle) * orbitRadius,
            y: center.y + sin(angle) * orbitRadius)
    }

    private func distanceSquared(from lhs: CGPoint, to rhs: CGPoint) -> CGFloat {
        let dx = lhs.x - rhs.x
        let dy = lhs.y - rhs.y
        return dx * dx + dy * dy
    }

}
