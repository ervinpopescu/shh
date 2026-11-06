import XCTest

@testable import ShhCore

final class CommandDialRootPlacementTests: XCTestCase {
    func testNavigableRootsReserveFutureBackHubFootprint() throws {
        let model = CommandDialModel(connected: true)
        let navigableCounts = descendants(of: model.roots)
            .filter { !$0.children.isEmpty }
            .map { $0.children.count }
            .sorted()
        XCTAssertEqual(navigableCounts, [1, 1, 2, 3, 3, 4, 4])

        let cases: [(CGSize, DialLayoutInsets, CGPoint)] = [
            (
                CGSize(width: 393, height: 500), DialLayoutInsets(top: 50, bottom: 8),
                CGPoint(x: 346, y: 454)
            ),
            (
                CGSize(width: 568, height: 212), DialLayoutInsets(top: 101),
                CGPoint(x: 521, y: 174)
            ),
            (
                CGSize(width: 1024, height: 768), DialLayoutInsets(top: 50, bottom: 20),
                CGPoint(x: 977, y: 710)
            ),
        ]

        for placement in CommandDialPlacement.allCases {
            for (bounds, insets, center) in cases {
                let root = DialRadialLayout.cornerFitting(
                    center: placement == .trailing
                        ? center : CGPoint(x: bounds.width - center.x, y: center.y),
                    preferredRadius: 112, minimumRadius: 0, itemRadius: 35,
                    itemSize: CGSize(width: 44, height: 44), count: model.roots.count,
                    placement: placement, bounds: bounds, safeAreaInsets: insets,
                    requireSeparatedTargets: false)
                XCTAssertTrue(
                    root.fits(
                        in: bounds, safeAreaInsets: insets, hubRadius: 35,
                        requireSeparatedTargets: false),
                    "root targets must reserve the future Back hub: \(placement) \(bounds) \(insets)"
                )
                XCTAssertTrue(
                    root.positions.allSatisfy { point in
                        point.x >= insets.leading + 35
                            && point.x <= bounds.width - insets.trailing - 35
                            && point.y >= insets.top + 35
                            && point.y <= bounds.height - insets.bottom - 35
                    })
                XCTAssertTrue(
                    root.positions.allSatisfy { point in
                        let rectangle = CGRect(
                            x: point.x - 22, y: point.y - 22, width: 44, height: 44)
                        return rectangle.minX >= insets.leading
                            && rectangle.maxX <= bounds.width - insets.trailing
                            && rectangle.minY >= insets.top
                            && rectangle.maxY <= bounds.height - insets.bottom
                    })
            }
        }
    }

    func testNavigableNestedGroupCountsReserveBackHubSpaceOnPad() throws {
        let model = CommandDialModel(connected: true)
        let nestedCounts = descendants(of: model.roots)
            .filter { !$0.children.isEmpty }
            .map { $0.children.count }
            .sorted()
        let bounds = CGSize(width: 1024, height: 768)
        let insets = DialLayoutInsets(top: 50, bottom: 20)
        let parent = CGPoint(x: 700, y: 620)

        for placement in CommandDialPlacement.allCases {
            for count in nestedCounts {
                let child = DialRadialLayout.inwardFan(
                    center: placement == .trailing
                        ? parent : CGPoint(x: bounds.width - parent.x, y: parent.y),
                    preferredRadius: 142, itemRadius: 35,
                    itemSize: CGSize(width: 44, height: 44), count: count,
                    placement: placement, bounds: bounds, safeAreaInsets: insets,
                    requireSeparatedTargets: false)
                XCTAssertTrue(
                    child.fits(
                        in: bounds, safeAreaInsets: insets, hubRadius: 35,
                        requireSeparatedTargets: false),
                    "nested targets must reserve the future Back hub: count \(count)")
            }
        }
    }

    func testEveryNavigablePathUsesSeparatedHeightAwareFans() throws {
        let model = CommandDialModel(connected: true)
        let cases = [
            LayoutCase(
                bounds: CGSize(width: 393, height: 500),
                insets: DialLayoutInsets(top: 50, bottom: 8),
                center: CGPoint(x: 346, y: 454), itemSize: CGSize(width: 44, height: 44)),
            LayoutCase(
                bounds: CGSize(width: 568, height: 212), insets: DialLayoutInsets(top: 101),
                center: CGPoint(x: 521, y: 174), itemSize: CGSize(width: 44, height: 44)),
            LayoutCase(
                bounds: CGSize(width: 1024, height: 768),
                insets: DialLayoutInsets(top: 50, bottom: 20),
                center: CGPoint(x: 977, y: 710), itemSize: CGSize(width: 124, height: 80)),
            LayoutCase(
                bounds: CGSize(width: 1024, height: 768),
                insets: DialLayoutInsets(top: 101, bottom: 20),
                center: CGPoint(x: 977, y: 710), itemSize: CGSize(width: 124, height: 80)),
        ]

        for placement in CommandDialPlacement.allCases {
            for layoutCase in cases {
                let bounds = layoutCase.bounds
                let insets = layoutCase.insets
                let center = layoutCase.center
                let itemSize = layoutCase.itemSize
                let root = DialRadialLayout.cornerFitting(
                    center: placement == .trailing
                        ? center : CGPoint(x: bounds.width - center.x, y: center.y),
                    preferredRadius: 142, minimumRadius: 0, itemRadius: 35,
                    itemSize: itemSize, count: model.roots.count,
                    placement: placement, bounds: bounds, safeAreaInsets: insets,
                    requireSeparatedTargets: true)
                try assertValidHierarchy(
                    nodes: model.roots, layout: root, itemSize: itemSize,
                    placement: placement, bounds: bounds, insets: insets)
            }
        }
    }

    func testRegularMirroredFansReflectRectanglesAndAnchors() throws {
        let bounds = CGSize(width: 1024, height: 1366)
        let insets = DialLayoutInsets(top: 66, bottom: 20)
        let leading = DialRadialLayout.cornerFitting(
            center: CGPoint(x: 52, y: 1290), preferredRadius: 330, minimumRadius: 0,
            itemRadius: 40, itemSize: CGSize(width: 124, height: 80), count: 4,
            placement: .leading, bounds: bounds, safeAreaInsets: insets,
            requireSeparatedTargets: true)
        let trailing = DialRadialLayout.cornerFitting(
            center: CGPoint(x: 972, y: 1290), preferredRadius: 330, minimumRadius: 0,
            itemRadius: 40, itemSize: CGSize(width: 124, height: 80), count: 4,
            placement: .trailing, bounds: bounds, safeAreaInsets: insets,
            requireSeparatedTargets: true)

        XCTAssertEqual(leading.center.x + trailing.center.x, bounds.width, accuracy: 0.000001)
        XCTAssertEqual(leading.center.y, trailing.center.y, accuracy: 0.000001)
        XCTAssertEqual(leading.orbitRadius, trailing.orbitRadius, accuracy: 0.000001)
        XCTAssertTrue(leading.fits(in: bounds, safeAreaInsets: insets, hubRadius: 40))
        XCTAssertTrue(trailing.fits(in: bounds, safeAreaInsets: insets, hubRadius: 40))
        XCTAssertTrue(leading.hasSeparatedTargets(hubRadius: 40))
        XCTAssertTrue(trailing.hasSeparatedTargets(hubRadius: 40))
        for (leadingPoint, trailingPoint) in zip(leading.positions, trailing.positions) {
            XCTAssertEqual(leadingPoint.x + trailingPoint.x, bounds.width, accuracy: 0.000001)
            XCTAssertEqual(leadingPoint.y, trailingPoint.y, accuracy: 0.000001)
        }
        for index in leading.positions.indices {
            let leadingRect = try XCTUnwrap(leading.targetRect(at: index))
            let trailingRect = try XCTUnwrap(trailing.targetRect(at: index))
            XCTAssertEqual(leadingRect.minX + trailingRect.maxX, bounds.width, accuracy: 0.000001)
            XCTAssertEqual(leadingRect.minY, trailingRect.minY, accuracy: 0.000001)
        }
    }

    func testRoomyFansKeepCurvedAngularSilhouetteWhileTightFansStayBounded() {
        let roomyBounds = CGSize(width: 1024, height: 768)
        let roomyInsets = DialLayoutInsets(top: 50, bottom: 20)
        let roomyCenters = [
            CGPoint(x: 700, y: 620), CGPoint(x: roomyBounds.width - 700, y: 620),
        ]
        for center in roomyCenters {
            let layout = DialRadialLayout.inwardFan(
                center: center, preferredRadius: 142, itemRadius: 35,
                itemSize: CGSize(width: 44, height: 44), count: 4,
                placement: center.x > roomyBounds.width / 2 ? .trailing : .leading,
                bounds: roomyBounds, safeAreaInsets: roomyInsets,
                requireSeparatedTargets: true)
            let verticalSpread = layout.positions.map(\.y).max()! - layout.positions.map(\.y).min()!
            XCTAssertGreaterThan(verticalSpread, 22)
            XCTAssertTrue(
                layout.fits(in: roomyBounds, safeAreaInsets: roomyInsets, hubRadius: 35))
        }

        let tightBounds = CGSize(width: 568, height: 212)
        let tight = DialRadialLayout.cornerFitting(
            center: CGPoint(x: 521, y: 174), preferredRadius: 142, minimumRadius: 0,
            itemRadius: 35, itemSize: CGSize(width: 44, height: 44), count: 4,
            placement: .trailing, bounds: tightBounds,
            safeAreaInsets: DialLayoutInsets(top: 101), requireSeparatedTargets: true)
        XCTAssertTrue(
            tight.fits(
                in: tightBounds, safeAreaInsets: DialLayoutInsets(top: 101), hubRadius: 35))
        XCTAssertTrue(tight.hasSeparatedTargets(hubRadius: 35))
    }

    private func assertValidHierarchy(
        nodes: [DialNode], layout: DialRadialLayout, itemSize: CGSize,
        placement: CommandDialPlacement, bounds: CGSize, insets: DialLayoutInsets
    ) throws {
        XCTAssertEqual(layout.positions.count, nodes.count)
        XCTAssertTrue(
            layout.fits(
                in: bounds, safeAreaInsets: insets, hubRadius: 35,
                requireSeparatedTargets: true),
            "invalid fan center \(layout.center), count \(nodes.count), bounds \(bounds), top \(insets.top), points \(layout.positions)"
        )
        XCTAssertTrue(
            layout.hasSeparatedTargets(hubRadius: 35),
            "overlapping fan center \(layout.center), count \(nodes.count), points \(layout.positions)"
        )
        let hub = CGRect(
            x: layout.center.x - 35, y: layout.center.y - 35, width: 70, height: 70)
        XCTAssertTrue(
            layout.positions.indices.allSatisfy { index in
                guard let rectangle = layout.targetRect(at: index) else { return false }
                return !rectangle.intersects(hub)
            },
            "card intersects the future 70x70 Back hub at \(layout.center)"
        )
        for (index, node) in nodes.enumerated() where !node.children.isEmpty {
            let parent = try XCTUnwrap(layout.point(at: index))
            let child = DialRadialLayout.inwardFan(
                center: parent, preferredRadius: 142, itemRadius: 35,
                itemSize: itemSize, count: node.children.count,
                placement: placement, bounds: bounds, safeAreaInsets: insets,
                requireSeparatedTargets: true)
            try assertValidHierarchy(
                nodes: node.children, layout: child, itemSize: itemSize,
                placement: placement, bounds: bounds, insets: insets)
        }
    }

    private struct LayoutCase {
        let bounds: CGSize
        let insets: DialLayoutInsets
        let center: CGPoint
        let itemSize: CGSize
    }

    private func descendants(of nodes: [DialNode]) -> [DialNode] {
        nodes.flatMap { [$0] + descendants(of: $0.children) }
    }
}
