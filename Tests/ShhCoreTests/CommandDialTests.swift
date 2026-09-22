import XCTest

@testable import ShhCore

final class CommandDialTests: XCTestCase {
    func testHierarchyUsesSparseIntentOrientedRootsAndStableLeafIDs() throws {
        let model = CommandDialModel()
        XCTAssertEqual(model.roots.map(\.id), ["root.input", "root.session", "root.share"])

        let input = try XCTUnwrap(model.roots.first { $0.id == "root.input" })
        XCTAssertEqual(
            input.children.map(\.id), ["input.navigate", "input.keyboard", "input.dictate"])

        let navigation = try XCTUnwrap(input.children.first { $0.id == "input.navigate" })
        XCTAssertEqual(
            navigation.children.map(\.id),
            [
                "input.navigate.cursor", "input.navigate.complete", "input.navigate.control",
            ])
        XCTAssertEqual(
            descendants(of: navigation).first { $0.id == "key.escape" }?.action, .commonKey(.escape)
        )
        XCTAssertEqual(
            descendants(of: navigation).first { $0.id == "key.enter" }?.action, .commonKey(.enter))
    }

    func testNavigationBackDismissAndDisabledNodes() throws {
        let disconnected = CommandDialModel(connected: false)
        var state = CommandDialNavigation()
        state.open()

        let session = try XCTUnwrap(disconnected.roots.first { $0.id == "root.session" })
        XCTAssertFalse(session.isEnabled)
        state.enter(session)
        XCTAssertTrue(state.path.isEmpty)

        let input = try XCTUnwrap(disconnected.roots.first { $0.id == "root.input" })
        XCTAssertTrue(
            input.isEnabled, "The local keyboard action remains useful while disconnected")
        state.enter(input)
        XCTAssertEqual(state.path, ["root.input"])
        state.back()
        XCTAssertTrue(state.path.isEmpty)
        state.dismiss()
        XCTAssertFalse(state.isOpen)
    }

    func testActivationDistinguishesNavigationDispatchAndIgnoredActions() throws {
        let model = CommandDialModel(connected: false)
        var state = CommandDialNavigation(isOpen: true)
        let input = try XCTUnwrap(model.roots.first { $0.id == "root.input" })
        let keyboard = try XCTUnwrap(input.children.first { $0.id == "input.keyboard" })
        let navigate = try XCTUnwrap(input.children.first { $0.id == "input.navigate" })

        XCTAssertEqual(state.activate(input), .navigated(nodeID: "root.input"))
        XCTAssertEqual(state.path, ["root.input"])
        XCTAssertEqual(state.activate(keyboard), .dispatch(.keyboard))
        XCTAssertEqual(state.activate(navigate), .ignored)
        XCTAssertEqual(state.path, ["root.input"])
    }

    func testRadialLayoutPlacesItemsOnOneOrbitAndMapsPolarSectors() throws {
        let layout = DialRadialLayout(
            center: CGPoint(x: 180, y: 420), orbitRadius: 140, itemRadius: 30,
            startAngle: 0, endAngle: -.pi, count: 5
        )
        XCTAssertEqual(layout.positions.count, 5)
        XCTAssertEqual(layout.positions[0].x, 320, accuracy: 0.001)
        XCTAssertEqual(layout.positions[0].y, 420, accuracy: 0.001)
        XCTAssertEqual(layout.positions[2].x, 180, accuracy: 0.001)
        XCTAssertEqual(layout.positions[2].y, 280, accuracy: 0.001)
        XCTAssertEqual(layout.index(at: try XCTUnwrap(layout.positions[3])), 3)
        XCTAssertNil(layout.index(at: layout.center))
        XCTAssertNil(layout.index(at: CGPoint(x: 180, y: 500)))
    }

    func testCornerGeometryMirrorsPlacementAndInsetsSparsePages() throws {
        let leading = DialRadialLayout.corner(
            center: CGPoint(x: 70, y: 700), radius: 240, itemRadius: 38,
            count: 4, placement: .leading
        )
        let trailing = DialRadialLayout.corner(
            center: CGPoint(x: 323, y: 700), radius: 240, itemRadius: 38,
            count: 4, placement: .trailing
        )
        XCTAssertEqual(leading.positions.count, 4)
        XCTAssertEqual(trailing.positions.count, 4)
        for (left, right) in zip(leading.positions, trailing.positions) {
            XCTAssertEqual(
                left.x - leading.center.x, -(right.x - trailing.center.x), accuracy: 0.001)
            XCTAssertEqual(left.y, right.y, accuracy: 0.001)
            XCTAssertEqual(
                hypot(left.x - leading.center.x, left.y - leading.center.y), 240, accuracy: 0.001)
            XCTAssertEqual(leading.index(at: left), leading.positions.firstIndex(of: left))
        }

        let sparse = DialRadialLayout.corner(
            center: CGPoint(x: 323, y: 700), radius: 240, itemRadius: 38,
            count: 2, placement: .trailing
        )
        XCTAssertLessThan(sparse.positions[0].y, sparse.center.y)
        XCTAssertLessThan(sparse.positions[1].y, sparse.center.y)
    }

    func testAccessibilityLabelsExposeSafetyAndConnectionState() throws {
        let model = CommandDialModel(pinnedLiterals: ["sudo reboot", "rm -rf /"])
        XCTAssertEqual(
            node(id: "literal.sudo reboot", in: model)?.accessibilityLabel,
            "sudo reboot, approval required")
        XCTAssertEqual(
            node(id: "literal.rm -rf /", in: model)?.accessibilityLabel,
            "rm -rf /, blocked: Safety policy")

        let disconnected = CommandDialModel(connected: false)
        let session = try XCTUnwrap(disconnected.roots.first { $0.id == "root.session" })
        XCTAssertEqual(session.accessibilityLabel, "Session, unavailable: Connect to a host")
    }

    func testPinnedLiteralsAreBoundedDeduplicatedAndPaged() {
        let values =
            (0..<12).map { "echo \($0)" } + [" echo 0 ", "", String(repeating: "x", count: 65)]
        let model = CommandDialModel(pinnedLiterals: values)
        let literalNodes = descendants(of: model.roots).filter { $0.id.hasPrefix("literal.") }
        XCTAssertEqual(literalNodes.map(\.title), (0..<12).map { "echo \($0)" })

        let quickText = node(id: "run.quick-text", in: model)
        XCTAssertNotNil(quickText)
        XCTAssertLessThanOrEqual(quickText?.children.count ?? .max, 4)
        XCTAssertTrue(
            descendants(of: quickText?.children ?? []).contains { $0.id == "run.quick-text.more.1" }
        )
    }

    func testPinnedLiteralsAreInsertOnlyAndPolicyGated() {
        XCTAssertFalse(CommandDialModel.isInsertOnlyTerminalText("ls\n"))
        XCTAssertFalse(CommandDialModel.isInsertOnlyTerminalText("ls\u{03}"))
        let model = CommandDialModel(pinnedLiterals: ["sudo reboot", "rm -rf /", "echo hello"])
        XCTAssertEqual(
            node(id: "literal.rm -rf /", in: model)?.availability, .blocked(reason: "Safety policy")
        )
        XCTAssertEqual(node(id: "literal.sudo reboot", in: model)?.availability, .reviewRequired)
        XCTAssertEqual(
            node(id: "literal.echo hello", in: model)?.action, .pinnedLiteral("echo hello"))
    }

    func testMultiplexerControlsAreGroupedByUserIntentAndRemainTyped() throws {
        let sessionID = try TmuxSessionID("$1")
        let windowID = try TmuxWindowID("@2")
        let paneID = try TmuxPaneID("%3")
        let windowTarget = TmuxWindowTarget(sessionID: sessionID, windowID: windowID)
        let paneTarget = TmuxPaneTarget(sessionID: sessionID, windowID: windowID, paneID: paneID)
        let controls = CommandDialMultiplexerMenu.nodes(
            tmuxSessionID: sessionID, tmuxPaneTarget: paneTarget, tmuxWindowTarget: windowTarget,
            capabilities: .tmux
        )
        let model = CommandDialModel(multiplexerChildren: controls)
        let current = try XCTUnwrap(node(id: "session.current", in: model))
        XCTAssertEqual(
            current.children.map(\.id),
            [
                "session.current.windows", "session.current.focus", "session.current.layout",
                "session.current.actions",
            ])

        let actions = descendants(of: current).compactMap { item -> MultiplexerControlAction? in
            guard case .multiplexerControl(let action) = item.action else { return nil }
            return action
        }
        XCTAssertEqual(actions.count, controls.count)
        XCTAssertTrue(actions.allSatisfy(\.requiresConfirmation))
        XCTAssertEqual(node(id: "session.browser", in: model)?.action, .multiplexer)
    }

    func testReviewAndBlockedSnippetsKeepAvailabilityThroughPagination() {
        let reviewID = UUID()
        let blockedID = UUID()
        let filler = (0..<4).map {
            DialSnippetDescriptor(id: UUID(), name: "Safe \($0)", preview: "echo \($0)")
        }
        let model = CommandDialModel(
            snippets: filler + [
                DialSnippetDescriptor(
                    id: reviewID, name: "Review", preview: "sudo", availability: .reviewRequired),
                DialSnippetDescriptor(
                    id: blockedID, name: "Blocked", preview: "fork",
                    availability: .blocked(reason: "Safety policy")),
            ])
        XCTAssertTrue(node(id: "snippet.\(reviewID.uuidString)", in: model)?.isEnabled == true)
        XCTAssertFalse(node(id: "snippet.\(blockedID.uuidString)", in: model)?.isEnabled == true)
        XCTAssertEqual(
            node(id: "snippet.\(reviewID.uuidString)", in: model)?.action, .snippet(reviewID))
    }

    func testPreferencesRoundTripAndNoTransientState() throws {
        let preferences = CommandDialPreferences(
            placement: .leading, size: .regular, hapticsEnabled: false,
            pinnedCategories: [.commonKeys], pinnedLiterals: ["~/"])
        let data = try JSONEncoder().encode(preferences)
        let decoded = try JSONDecoder().decode(CommandDialPreferences.self, from: data)
        XCTAssertEqual(decoded, preferences)
        XCTAssertFalse(String(decoding: data, as: UTF8.self).contains("secret"))
    }

    func testDialCategoriesPlacementsAndSizes() {
        for category in DialCategory.allCases {
            XCTAssertEqual(category.id, category.rawValue)
            XCTAssertFalse(category.title.isEmpty)
        }
        for placement in CommandDialPlacement.allCases {
            XCTAssertEqual(placement.id, placement.rawValue)
            XCTAssertEqual(placement.title, placement.rawValue.capitalized)
        }
        for size in CommandDialSize.allCases {
            XCTAssertEqual(size.id, size.rawValue)
            XCTAssertEqual(size.title, size.rawValue.capitalized)
        }
    }

    func testNavigationSelectionAndBreadcrumb() {
        var state = CommandDialNavigation(isOpen: true)
        XCTAssertEqual(state.breadcrumb, "Shh")
        state.highlight("test-node")
        XCTAssertEqual(state.selectedNodeID, "test-node")
        state.clearSelection()
        XCTAssertNil(state.selectedNodeID)

        let node = DialNode(
            id: "sub-category",
            title: "Sub",
            action: .category(.commonKeys),
            children: [
                DialNode(id: "leaf", title: "Leaf", action: .category(.commonKeys))
            ]
        )
        state.enter(node)
        XCTAssertEqual(state.breadcrumb, "Shh / sub-category")

        let haptics = NoopDialHaptics()
        haptics.emit(.open)
    }

    func testRadialLayoutEdgeCases() {
        let layout = DialRadialLayout(
            center: CGPoint(x: 100, y: 100),
            orbitRadius: 50,
            itemRadius: 10,
            startAngle: 0,
            endAngle: .pi,
            count: 3
        )
        XCTAssertNotNil(layout.point(at: 0))
        XCTAssertNil(layout.point(at: -1))
        XCTAssertNil(layout.point(at: 10))

        let single = DialRadialLayout(
            center: CGPoint(x: 100, y: 100),
            orbitRadius: 50,
            itemRadius: 10,
            startAngle: 0,
            endAngle: 0,
            count: 1
        )
        XCTAssertEqual(single.positions.count, 1)
        XCTAssertEqual(single.index(at: CGPoint(x: 150, y: 100)), 0)
        XCTAssertNil(single.index(at: CGPoint(x: 50, y: 100)))

        let empty = DialRadialLayout(
            center: .zero,
            orbitRadius: 50,
            itemRadius: 10,
            startAngle: 0,
            endAngle: .pi,
            count: 0
        )
        XCTAssertTrue(empty.positions.isEmpty)
        XCTAssertNil(empty.index(at: .zero))
    }

    private func node(id: String, in model: CommandDialModel) -> DialNode? {
        descendants(of: model.roots).first { $0.id == id }
    }

    private func descendants(of nodes: [DialNode]) -> [DialNode] {
        nodes.flatMap { [$0] + descendants(of: $0.children) }
    }

    private func descendants(of node: DialNode) -> [DialNode] {
        descendants(of: node.children)
    }
}
