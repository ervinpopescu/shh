import CoreGraphics
import Foundation

public enum DialLevelTransition: Equatable, Sendable {
    case enter, back
}

public struct DialLayoutInsets: Equatable, Sendable {
    public let top: CGFloat
    public let leading: CGFloat
    public let bottom: CGFloat
    public let trailing: CGFloat

    public init(top: CGFloat = 0, leading: CGFloat = 0, bottom: CGFloat = 0, trailing: CGFloat = 0)
    {
        self.top = top
        self.leading = leading
        self.bottom = bottom
        self.trailing = trailing
    }
}

/// Geometry shared by the command dial's visual layout and polar hit testing.
/// Angles use UIKit coordinates: zero points east and positive values rotate
/// clockwise. The layout is an arc so a corner-mounted puck keeps every item
/// inside the reachable part of the screen.
public struct DialRadialLayout: Equatable, Sendable {
    /// Geometry is intentionally bounded so layout cost does not grow with a
    /// viewport's physical dimensions or with a search radius.
    public static let maximumGeometryCandidates = 12
    public static let minimumTargetDimension: CGFloat = 44

    public let center: CGPoint
    public let orbitRadius: CGFloat
    public let itemRadius: CGFloat
    public let itemSize: CGSize
    public let startAngle: CGFloat
    public let endAngle: CGFloat
    public let count: Int
    private let positionOverrides: [CGPoint]?

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
        self.positionOverrides = nil
    }

    public var positions: [CGPoint] {
        if let positionOverrides { return positionOverrides }
        guard count > 0 else { return [] }
        guard count > 1 else { return [point(atAngle: (startAngle + endAngle) / 2)] }
        let step = (endAngle - startAngle) / CGFloat(count - 1)
        return (0..<count).map { point(atAngle: startAngle + CGFloat($0) * step) }
    }

    public func point(at index: Int) -> CGPoint? {
        guard positions.indices.contains(index) else { return nil }
        return positions[index]
    }

    /// The actual rectangular target rendered at an index.
    public func targetRect(at index: Int) -> CGRect? {
        guard let point = point(at: index) else { return nil }
        return CGRect(
            x: point.x - itemSize.width / 2,
            y: point.y - itemSize.height / 2,
            width: itemSize.width,
            height: itemSize.height)
    }

    /// Returns whether the visible target rectangles are disjoint and remain
    /// outside the central hub. This is intentionally based on the rendered
    /// rectangles rather than a guessed orbit radius.
    public func hasSeparatedTargets(hubRadius: CGFloat = 0) -> Bool {
        let rectangles = positions.compactMap { point -> CGRect? in
            CGRect(
                x: point.x - itemSize.width / 2,
                y: point.y - itemSize.height / 2,
                width: itemSize.width,
                height: itemSize.height)
        }
        for index in rectangles.indices {
            for otherIndex in rectangles.indices where otherIndex > index {
                if rectangles[index].intersects(rectangles[otherIndex]) {
                    return false
                }
            }
            if hubRadius > 0 {
                let rectangle = rectangles[index]
                let nearestX = min(max(center.x, rectangle.minX), rectangle.maxX)
                let nearestY = min(max(center.y, rectangle.minY), rectangle.maxY)
                if hypot(nearestX - center.x, nearestY - center.y) < hubRadius {
                    return false
                }
            }
        }
        return true
    }

    /// Validates the complete geometry used by the native dial, including
    /// safe-area/header bounds, rectangular target separation, and room for
    /// the hub to remain visible when a child fan uses this center.
    public func fits(
        in bounds: CGSize, safeAreaInsets: DialLayoutInsets = DialLayoutInsets(),
        hubRadius: CGFloat = 0, requireSeparatedTargets: Bool = true
    ) -> Bool {
        guard !requireSeparatedTargets || hasSeparatedTargets(hubRadius: hubRadius) else {
            return false
        }
        guard center.x >= safeAreaInsets.leading + hubRadius,
            center.x <= bounds.width - safeAreaInsets.trailing - hubRadius,
            center.y >= safeAreaInsets.top + hubRadius,
            center.y <= bounds.height - safeAreaInsets.bottom - hubRadius
        else { return false }
        if hubRadius > 0 {
            guard
                positions.allSatisfy({ point in
                    point.x >= safeAreaInsets.leading + hubRadius
                        && point.x <= bounds.width - safeAreaInsets.trailing - hubRadius
                        && point.y >= safeAreaInsets.top + hubRadius
                        && point.y <= bounds.height - safeAreaInsets.bottom - hubRadius
                })
            else { return false }
        }
        return positions.indices.allSatisfy { index in
            guard let rectangle = targetRect(at: index) else { return false }
            return rectangle.minX >= safeAreaInsets.leading
                && rectangle.maxX <= bounds.width - safeAreaInsets.trailing
                && rectangle.minY >= safeAreaInsets.top
                && rectangle.maxY <= bounds.height - safeAreaInsets.bottom
        }
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
            end = -.pi * 0.46
        case .trailing:
            // The open wheel grows above and inward from the lower-right puck.
            start = .pi
            end = .pi * 1.46
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

    /// Creates a corner arc whose rectangular targets fit inside the viewport.
    ///
    /// This is a bounded geometry solver, not a pixel/radius search. It tries
    /// twelve deterministic span/offset combinations and derives the smallest
    /// orbit that can separate the rendered rectangles. If separation is
    /// impossible in the measured viewport, the best in-bounds candidate is a
    /// stable overlap fallback rather than an unbounded search.
    public static func cornerFitting(
        center: CGPoint, preferredRadius: CGFloat, minimumRadius: CGFloat,
        itemRadius: CGFloat, itemSize: CGSize, count: Int,
        placement: CommandDialPlacement, bounds: CGSize,
        safeAreaInsets: DialLayoutInsets = DialLayoutInsets(),
        requireSeparatedTargets: Bool = false
    ) -> Self {
        let actualCount = max(1, count)
        if requireSeparatedTargets,
            let separated = separatedFan(
                center: center, itemRadius: itemRadius, itemSize: itemSize,
                count: actualCount, placement: placement, bounds: bounds,
                safeAreaInsets: safeAreaInsets)
        {
            return separated
        }
        let baseStart: CGFloat = placement == .leading ? 0 : .pi
        let direction: CGFloat = placement == .leading ? -1 : 1
        let baseSpan = min(1.45, max(0.68, CGFloat(actualCount - 1) * 0.34))
        let spans = [baseSpan, max(baseSpan, 1.9), 2.5, .pi]
        let offsets = [CGFloat.zero, direction * 0.18, direction * 0.36]
        let normalizedSize = CGSize(
            width: max(minimumTargetDimension, itemSize.width),
            height: max(minimumTargetDimension, itemSize.height))
        let candidates = Array(offsets.enumerated().flatMap { offsetIndex, offset in
            spans.enumerated().map { spanIndex, span in
                let start = baseStart + offset
                let end = start + direction * span
                return boundedCandidate(
                    GeometryRequest(
                        center: center, preferredRadius: preferredRadius,
                        minimumRadius: minimumRadius, itemRadius: itemRadius,
                        itemSize: normalizedSize, count: actualCount,
                        startAngle: start, endAngle: end, bounds: bounds,
                        safeAreaInsets: safeAreaInsets,
                        requireSeparatedTargets: requireSeparatedTargets),
                    scoreBias: CGFloat(spanIndex) * 18 + CGFloat(offsetIndex) * 18)
            }
        }.prefix(maximumGeometryCandidates))
        return selectCandidate(
            candidates, bounds: bounds,
            safeAreaInsets: safeAreaInsets, hubRadius: itemRadius,
            requireSeparatedTargets: requireSeparatedTargets,
            fallback: corner(
                center: center, radius: max(minimumRadius, preferredRadius),
                itemRadius: itemRadius, itemSize: normalizedSize, count: actualCount,
                placement: placement))
    }

    /// Creates a fan around a selected parent. The fan points toward the
    /// viewport interior and uses the same bounded solver as root geometry.
    public static func inwardFan(
        center: CGPoint, preferredRadius: CGFloat, itemRadius: CGFloat,
        itemSize: CGSize? = nil, count: Int, placement: CommandDialPlacement,
        bounds: CGSize, safeAreaInsets: DialLayoutInsets = DialLayoutInsets(),
        requireSeparatedTargets: Bool = false
    ) -> Self {
        let requestedSize = itemSize ?? CGSize(width: itemRadius * 2, height: itemRadius * 2)
        let size = CGSize(
            width: max(minimumTargetDimension, requestedSize.width),
            height: max(minimumTargetDimension, requestedSize.height))
        if requireSeparatedTargets,
            let separated = separatedFan(
                center: center, itemRadius: itemRadius, itemSize: size,
                count: count, placement: placement, bounds: bounds,
                safeAreaInsets: safeAreaInsets)
        {
            return separated
        }
        guard count > 0 else {
            return Self(
                center: center, orbitRadius: 0, itemRadius: itemRadius, itemSize: size,
                startAngle: 0, endAngle: 0, count: 0)
        }

        let target = CGPoint(
            x: bounds.width / 2,
            y: max(safeAreaInsets.top + size.height, bounds.height * 0.45))
        let inwardAngle = atan2(target.y - center.y, target.x - center.x)
        let baseSpan = min(1.45, max(0.68, CGFloat(count - 1) * 0.34))
        let spans = [baseSpan, max(baseSpan, 1.9), 2.5, .pi]
        let offsets: [CGFloat] = [-0.36, 0, 0.36]
        let candidates = Array(offsets.enumerated().flatMap { offsetIndex, offset in
            spans.enumerated().map { spanIndex, span in
                boundedCandidate(
                    GeometryRequest(
                        center: center, preferredRadius: preferredRadius,
                        minimumRadius: max(itemRadius, hypot(size.width / 2, size.height / 2)),
                        itemRadius: itemRadius, itemSize: size, count: count,
                        startAngle: inwardAngle + offset - span / 2,
                        endAngle: inwardAngle + offset + span / 2,
                        bounds: bounds, safeAreaInsets: safeAreaInsets,
                        requireSeparatedTargets: requireSeparatedTargets),
                    scoreBias: CGFloat(spanIndex) * 18 + CGFloat(offsetIndex) * 18)
            }
        }.prefix(maximumGeometryCandidates))
        return selectCandidate(
            candidates, bounds: bounds,
            safeAreaInsets: safeAreaInsets, hubRadius: itemRadius,
            requireSeparatedTargets: requireSeparatedTargets,
            fallback: Self(
                center: center, orbitRadius: max(itemRadius, hypot(size.width / 2, size.height / 2)),
                itemRadius: itemRadius, itemSize: size,
                startAngle: inwardAngle - baseSpan / 2,
                endAngle: inwardAngle + baseSpan / 2, count: count))
    }

    private struct GeometryCandidate {
        let layout: DialRadialLayout
        let score: CGFloat
    }

    private struct GeometryRequest {
        let center: CGPoint
        let preferredRadius: CGFloat
        let minimumRadius: CGFloat
        let itemRadius: CGFloat
        let itemSize: CGSize
        let count: Int
        let startAngle: CGFloat
        let endAngle: CGFloat
        let bounds: CGSize
        let safeAreaInsets: DialLayoutInsets
        let requireSeparatedTargets: Bool
    }

    private static func boundedCandidate(
        _ request: GeometryRequest, scoreBias: CGFloat
    ) -> GeometryCandidate {
        let center = request.center
        let preferredRadius = request.preferredRadius
        let minimumRadius = request.minimumRadius
        let itemRadius = request.itemRadius
        let itemSize = request.itemSize
        let count = request.count
        let startAngle = request.startAngle
        let endAngle = request.endAngle
        let bounds = request.bounds
        let safeAreaInsets = request.safeAreaInsets
        let halfWidth = itemSize.width / 2
        let halfHeight = itemSize.height / 2
        let minimumX = max(safeAreaInsets.leading + halfWidth, safeAreaInsets.leading + itemRadius)
        let maximumX = min(
            bounds.width - safeAreaInsets.trailing - halfWidth,
            bounds.width - safeAreaInsets.trailing - itemRadius)
        let minimumY = max(safeAreaInsets.top + halfHeight, safeAreaInsets.top + itemRadius)
        let maximumY = min(
            bounds.height - safeAreaInsets.bottom - halfHeight,
            bounds.height - safeAreaInsets.bottom - itemRadius)
        let step = count > 1 ? (endAngle - startAngle) / CGFloat(count - 1) : 0
        var maximumRadius = CGFloat.greatestFiniteMagnitude

        for index in 0..<count {
            let angle = count > 1 ? startAngle + CGFloat(index) * step : (startAngle + endAngle) / 2
            let unit = CGPoint(x: cos(angle), y: sin(angle))
            if abs(unit.x) > 0.0001 {
                let bound = unit.x > 0
                    ? (maximumX - center.x) / unit.x
                    : (minimumX - center.x) / unit.x
                maximumRadius = min(maximumRadius, bound)
            }
            if abs(unit.y) > 0.0001 {
                let bound = unit.y > 0
                    ? (maximumY - center.y) / unit.y
                    : (minimumY - center.y) / unit.y
                maximumRadius = min(maximumRadius, bound)
            }
        }
        maximumRadius = max(0, maximumRadius)

        let separationRadius = request.requireSeparatedTargets
            ? minimumAxisAlignedSeparationRadius(startAngle: startAngle, endAngle: endAngle,
                count: count, itemSize: itemSize) : 0
        let hubClearanceRadius = request.requireSeparatedTargets
            ? minimumHubClearanceRadius(startAngle: startAngle, endAngle: endAngle, count: count,
                itemSize: itemSize, hubRadius: itemRadius) : 0
        let requiredRadius = request.requireSeparatedTargets
            ? max(minimumRadius, separationRadius, hubClearanceRadius)
            : minimumRadius
        let radius = min(max(requiredRadius, preferredRadius), maximumRadius)
        let layout = Self(
            center: center, orbitRadius: radius, itemRadius: itemRadius, itemSize: itemSize,
            startAngle: startAngle, endAngle: endAngle, count: count)
        return GeometryCandidate(
            layout: layout,
            score: abs(radius - preferredRadius) + scoreBias)
    }

    private static func selectCandidate(
        _ candidates: [GeometryCandidate], bounds: CGSize,
        safeAreaInsets: DialLayoutInsets, hubRadius: CGFloat,
        requireSeparatedTargets: Bool, fallback: Self
    ) -> Self {
        let valid = candidates.filter {
            $0.layout.fits(
                in: bounds, safeAreaInsets: safeAreaInsets, hubRadius: hubRadius,
                requireSeparatedTargets: requireSeparatedTargets)
        }
        if let best = valid.min(by: { $0.score < $1.score }) {
            return best.layout
        }

        // Separation can be mathematically impossible when a keyboard leaves
        // less than one card-height of vertical space. Prefer an in-bounds
        // deterministic overlap fallback so native buttons remain visible.
        if let best = candidates.filter({
            $0.layout.fits(
                in: bounds, safeAreaInsets: safeAreaInsets, hubRadius: hubRadius,
                requireSeparatedTargets: false)
        }).min(by: { $0.score < $1.score }) {
            return best.layout
        }
        return fallback
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

}

private extension DialRadialLayout {
    static func angularFan(
        center: CGPoint, itemRadius: CGFloat, itemSize: CGSize, count: Int,
        bounds: CGSize, safeAreaInsets: DialLayoutInsets,
        minimumX: CGFloat, maximumX: CGFloat, minimumY: CGFloat, maximumY: CGFloat,
        minimumCenterY: CGFloat, maximumCenterY: CGFloat, availableInteriorX: CGFloat
    ) -> Self? {
        guard maximumCenterY - minimumCenterY >= itemSize.height * 2 + itemRadius else {
            return nil
        }
        let span = min(1.45, max(0.68, CGFloat(count - 1) * 0.34))
        let target = CGPoint(
            x: availableInteriorX, y: (minimumCenterY + maximumCenterY) / 2)
        let heading = atan2(target.y - center.y, target.x - center.x)
        let startAngle = heading - span / 2
        let endAngle = heading + span / 2
        let step = count > 1 ? span / CGFloat(count - 1) : 0
        var maximumRadius = CGFloat.greatestFiniteMagnitude
        for index in 0..<count {
            let angle = count > 1 ? startAngle + CGFloat(index) * step : heading
            let unit = CGPoint(x: cos(angle), y: sin(angle))
            if abs(unit.x) > 0.0001 {
                let bound = unit.x > 0
                    ? (maximumX - center.x) / unit.x
                    : (minimumX - center.x) / unit.x
                maximumRadius = min(maximumRadius, bound)
            }
            if abs(unit.y) > 0.0001 {
                let bound = unit.y > 0
                    ? (maximumY - center.y) / unit.y
                    : (minimumY - center.y) / unit.y
                maximumRadius = min(maximumRadius, bound)
            }
        }
        let separationRadius = minimumAxisAlignedSeparationRadius(
            startAngle: startAngle, endAngle: endAngle, count: count, itemSize: itemSize)
        let hubClearanceRadius = minimumHubClearanceRadius(
            startAngle: startAngle, endAngle: endAngle, count: count,
            itemSize: itemSize, hubRadius: itemRadius)
        let requiredRadius = max(itemRadius, separationRadius, hubClearanceRadius)
        let radius = min(maximumRadius, requiredRadius + 0.001)
        guard radius >= requiredRadius else { return nil }
        let positions = (0..<count).map { index in
            let angle = count > 1 ? startAngle + CGFloat(index) * step : heading
            return CGPoint(
                x: center.x + cos(angle) * radius,
                y: center.y + sin(angle) * radius)
        }
        return Self(
            center: center, orbitRadius: radius, itemRadius: itemRadius,
            itemSize: itemSize, startAngle: startAngle, endAngle: endAngle,
            positions: positions)
    }

    static func separatedFan(
        center: CGPoint, itemRadius: CGFloat, itemSize: CGSize, count: Int,
        placement: CommandDialPlacement, bounds: CGSize, safeAreaInsets: DialLayoutInsets
    ) -> Self? {
        guard count > 0 else { return nil }
        if placement == .trailing {
            return mirroredTrailingFan(
                FanRequest(
                    center: center, itemRadius: itemRadius, itemSize: itemSize,
                    count: count, bounds: bounds, safeAreaInsets: safeAreaInsets))
        }
        let halfWidth = itemSize.width / 2
        let halfHeight = itemSize.height / 2
        let minimumX = safeAreaInsets.leading + halfWidth
        let maximumX = bounds.width - safeAreaInsets.trailing - halfWidth
        let minimumY = safeAreaInsets.top + halfHeight
        let maximumY = bounds.height - safeAreaInsets.bottom - halfHeight
        let minimumCenterX = max(minimumX, safeAreaInsets.leading + itemRadius)
        let maximumCenterX = min(maximumX, bounds.width - safeAreaInsets.trailing - itemRadius)
        let minimumCenterY = max(minimumY, safeAreaInsets.top + itemRadius)
        let maximumCenterY = min(maximumY, bounds.height - safeAreaInsets.bottom - itemRadius)
        guard minimumX <= maximumX, minimumY <= maximumY,
            minimumCenterX <= maximumCenterX, minimumCenterY <= maximumCenterY
        else { return nil }

        let availableInteriorX = (minimumCenterX + maximumCenterX) / 2
        let direction: CGFloat
        if abs(availableInteriorX - center.x) > 0.001 {
            direction = availableInteriorX > center.x ? 1 : -1
        } else {
            direction = placement == .leading ? 1 : -1
        }
        if let angular = angularFan(
            center: center, itemRadius: itemRadius, itemSize: itemSize, count: count,
            bounds: bounds, safeAreaInsets: safeAreaInsets,
            minimumX: minimumX, maximumX: maximumX, minimumY: minimumY, maximumY: maximumY,
            minimumCenterY: minimumCenterY, maximumCenterY: maximumCenterY,
            availableInteriorX: availableInteriorX), angular.fits(
                in: bounds, safeAreaInsets: safeAreaInsets,
                hubRadius: itemRadius, requireSeparatedTargets: true),
            angular.hasRectangularHubClearance(radius: itemRadius)
        {
            return angular
        }

        let gap = max(1, min(itemRadius * 0.12, min(halfWidth, halfHeight) * 0.25))
        let nearHubX = center.x + direction * (itemRadius + halfWidth + gap)
        let horizontalLastX = nearHubX + direction * CGFloat(count - 1) * (itemSize.width + gap)
        let horizontalFits = direction > 0
            ? horizontalLastX + halfWidth <= maximumX
            : horizontalLastX - halfWidth >= minimumX
        let aboveHubMaximumY = center.y - itemRadius - halfHeight - gap
        let aboveHubFits = aboveHubMaximumY >= minimumCenterY
        guard horizontalFits || aboveHubFits else { return nil }

        let firstX: CGFloat
        let xStep: CGFloat
        if horizontalFits {
            firstX = nearHubX
            xStep = direction * (itemSize.width + gap)
        } else {
            let usableWidth = maximumCenterX - minimumCenterX
            let step = count > 1 ? usableWidth / CGFloat(count - 1) : 0
            firstX = (minimumCenterX + maximumCenterX) / 2 - CGFloat(count - 1) * step / 2
            xStep = step
        }

        let headingTarget = CGPoint(x: availableInteriorX, y: (minimumY + maximumY) / 2)
        let heading = atan2(headingTarget.y - center.y, headingTarget.x - center.x)
        let amplitude = min(
            max(3, halfHeight * 0.35), max(0, (maximumY - minimumY) * 0.18))
        let baseline = horizontalFits
            ? center.y - itemRadius * 0.82
            : aboveHubMaximumY - amplitude / 2
        let curveCenter = min(
            max(baseline, minimumCenterY + amplitude), maximumCenterY - amplitude)
        let positions = (0..<count).map { index in
            let fraction = count > 1 ? CGFloat(index) / CGFloat(count - 1) : 0.5
            let curve = sin(.pi * fraction)
            let centerY = curveCenter - amplitude * curve * (sin(heading) >= 0 ? 1 : -1)
            return CGPoint(x: firstX + CGFloat(index) * xStep, y: centerY)
        }
        let orbitRadius = positions.map { hypot($0.x - center.x, $0.y - center.y) }.max() ?? 0
        let firstAngle = atan2(
            positions[0].y - center.y, positions[0].x - center.x)
        let lastAngle = atan2(
            positions[positions.count - 1].y - center.y,
            positions[positions.count - 1].x - center.x)
        let layout = Self(
            center: center, orbitRadius: orbitRadius, itemRadius: itemRadius,
            itemSize: itemSize, startAngle: firstAngle, endAngle: lastAngle,
            positions: positions)
        return layout.fits(
            in: bounds, safeAreaInsets: safeAreaInsets, hubRadius: itemRadius,
            requireSeparatedTargets: true) ? layout : nil
    }

    private struct FanRequest {
        let center: CGPoint
        let itemRadius: CGFloat
        let itemSize: CGSize
        let count: Int
        let bounds: CGSize
        let safeAreaInsets: DialLayoutInsets
    }

    private static func mirroredTrailingFan(_ request: FanRequest) -> Self? {
        let mirroredInsets = DialLayoutInsets(
            top: request.safeAreaInsets.top,
            leading: request.safeAreaInsets.trailing,
            bottom: request.safeAreaInsets.bottom,
            trailing: request.safeAreaInsets.leading)
        let mirroredCenter = CGPoint(
            x: request.bounds.width - request.center.x, y: request.center.y)
        guard let mirrored = separatedFan(
            center: mirroredCenter, itemRadius: request.itemRadius,
            itemSize: request.itemSize, count: request.count, placement: .leading,
            bounds: request.bounds, safeAreaInsets: mirroredInsets)
        else { return nil }
        let reflectedPositions = mirrored.positions.map {
            CGPoint(x: request.bounds.width - $0.x, y: $0.y)
        }
        return Self(
            center: request.center, orbitRadius: mirrored.orbitRadius,
            itemRadius: request.itemRadius, itemSize: request.itemSize,
            startAngle: .pi - mirrored.startAngle,
            endAngle: .pi - mirrored.endAngle, positions: reflectedPositions)
    }

    func hasRectangularHubClearance(radius: CGFloat) -> Bool {
        let hub = CGRect(
            x: center.x - radius, y: center.y - radius,
            width: radius * 2, height: radius * 2)
        return positions.indices.allSatisfy { index in
            guard let rectangle = targetRect(at: index) else { return false }
            return !rectangle.intersects(hub)
        }
    }

    init(
        center: CGPoint, orbitRadius: CGFloat, itemRadius: CGFloat,
        itemSize: CGSize, startAngle: CGFloat, endAngle: CGFloat,
        positions: [CGPoint]
    ) {
        self.center = center
        self.orbitRadius = max(0, orbitRadius)
        self.itemRadius = max(1, itemRadius)
        self.itemSize = itemSize
        self.startAngle = startAngle
        self.endAngle = endAngle
        self.count = positions.count
        self.positionOverrides = positions
    }

    func point(atAngle angle: CGFloat) -> CGPoint {
        CGPoint(
            x: center.x + cos(angle) * orbitRadius,
            y: center.y + sin(angle) * orbitRadius)
    }

    func distanceSquared(from lhs: CGPoint, to rhs: CGPoint) -> CGFloat {
        let dx = lhs.x - rhs.x
        let dy = lhs.y - rhs.y
        return dx * dx + dy * dy
    }

    static func minimumAxisAlignedSeparationRadius(
        startAngle: CGFloat, endAngle: CGFloat, count: Int, itemSize: CGSize
    ) -> CGFloat {
        guard count > 1 else { return 0 }
        let step = (endAngle - startAngle) / CGFloat(count - 1)
        var required: CGFloat = 0
        for first in 0..<count {
            let firstAngle = startAngle + CGFloat(first) * step
            for second in (first + 1)..<count {
                let secondAngle = startAngle + CGFloat(second) * step
                let xDelta = abs(cos(firstAngle) - cos(secondAngle))
                let yDelta = abs(sin(firstAngle) - sin(secondAngle))
                let xRadius = xDelta > 0 ? itemSize.width / xDelta : .greatestFiniteMagnitude
                let yRadius = yDelta > 0 ? itemSize.height / yDelta : .greatestFiniteMagnitude
                required = max(required, min(xRadius, yRadius))
            }
        }
        return required
    }

    static func minimumHubClearanceRadius(
        startAngle: CGFloat, endAngle: CGFloat, count: Int,
        itemSize: CGSize, hubRadius: CGFloat
    ) -> CGFloat {
        guard count > 0, hubRadius > 0 else { return 0 }
        let step = count > 1 ? (endAngle - startAngle) / CGFloat(count - 1) : 0
        var required: CGFloat = 0
        for index in 0..<count {
            let angle = count > 1
                ? startAngle + CGFloat(index) * step : (startAngle + endAngle) / 2
            required = max(
                required,
                hubClearanceRadius(
                    angle: angle, halfWidth: itemSize.width / 2,
                    halfHeight: itemSize.height / 2, hubRadius: hubRadius))
        }
        return required
    }

    static func hubClearanceRadius(
        angle: CGFloat, halfWidth: CGFloat, halfHeight: CGFloat, hubRadius: CGFloat
    ) -> CGFloat {
        let cosine = abs(cos(angle))
        let sine = abs(sin(angle))
        var candidates: [CGFloat] = []
        if cosine > 0 {
            let radius = (hubRadius + halfWidth) / cosine
            if radius * sine <= halfHeight { candidates.append(radius) }
        }
        if sine > 0 {
            let radius = (hubRadius + halfHeight) / sine
            if radius * cosine <= halfWidth { candidates.append(radius) }
        }
        let projection = cosine * halfWidth + sine * halfHeight
        let discriminant = projection * projection - halfWidth * halfWidth
            - halfHeight * halfHeight + hubRadius * hubRadius
        if discriminant >= 0 {
            let radius = projection + sqrt(discriminant)
            if radius * cosine >= halfWidth && radius * sine >= halfHeight {
                candidates.append(radius)
            }
        }
        return candidates.min() ?? .greatestFiniteMagnitude
    }
}
