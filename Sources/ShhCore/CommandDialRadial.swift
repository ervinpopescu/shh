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
    public let startAngle: CGFloat
    public let endAngle: CGFloat
    public let count: Int

    public init(
        center: CGPoint, orbitRadius: CGFloat, itemRadius: CGFloat,
        startAngle: CGFloat, endAngle: CGFloat, count: Int
    ) {
        self.center = center
        self.orbitRadius = max(0, orbitRadius)
        self.itemRadius = max(1, itemRadius)
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

    /// Returns the item under a touch only when it is in the annulus around
    /// the orbit and within the configured arc. The center puck and the space
    /// outside the orbit are intentionally not selectable by polar gestures.
    public func index(at point: CGPoint) -> Int? {
        guard count > 0 else { return nil }
        let dx = point.x - center.x
        let dy = point.y - center.y
        let distance = hypot(dx, dy)
        let minimumDistance = max(itemRadius * 0.85, orbitRadius * 0.36, 30)
        let maximumDistance = orbitRadius + max(itemRadius * 1.45, 34)
        guard distance >= minimumDistance, distance <= maximumDistance else { return nil }

        guard count > 1 else {
            return angularDistance(from: atan2(dy, dx), to: (startAngle + endAngle) / 2) <= .pi / 2
                ? 0 : nil
        }

        let span = endAngle - startAngle
        guard span != 0 else { return 0 }
        let angle = unwrap(angle: atan2(dy, dx), around: startAngle)
        let progress = (angle - startAngle) / span
        let step = 1 / CGFloat(count - 1)
        let index = Int((progress / step).rounded())
        guard index >= 0, index < count else { return nil }
        let nearestProgress = CGFloat(index) * step
        guard abs(progress - nearestProgress) <= step / 2 else { return nil }
        return index
    }

    public static func corner(
        center: CGPoint, radius: CGFloat, itemRadius: CGFloat,
        count: Int, placement: CommandDialPlacement
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

    private func unwrap(angle: CGFloat, around reference: CGFloat) -> CGFloat {
        var result = angle
        while result - reference > .pi { result -= 2 * .pi }
        while result - reference < -.pi { result += 2 * .pi }
        return result
    }

    private func angularDistance(from lhs: CGFloat, to rhs: CGFloat) -> CGFloat {
        abs(unwrap(angle: lhs, around: rhs) - rhs)
    }
}
