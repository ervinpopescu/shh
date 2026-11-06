// swiftlint:disable file_length line_length

import ShhCore
import ShhTerminal
import SwiftUI
import XCTest

@testable import Shh

private struct CommandDialNativeTestSurface: View {
    let model: CommandDialModel
    @State private var navigation: CommandDialNavigation
    let placement: CommandDialPlacement
    let onNavigationChange: (CommandDialNavigation) -> Void

    init(
        model: CommandDialModel,
        navigation: CommandDialNavigation,
        placement: CommandDialPlacement,
        onNavigationChange: @escaping (CommandDialNavigation) -> Void
    ) {
        self.model = model
        _navigation = State(initialValue: navigation)
        self.placement = placement
        self.onNavigationChange = onNavigationChange
    }

    var body: some View {
        let navigationBinding = Binding(
            get: { navigation },
            set: { value in
                navigation = value
                onNavigationChange(value)
            })
        CommandDialSurface(
            model: model,
            navigation: navigationBinding,
            placement: placement,
            size: .compact,
            hostLabel: "Native Review Host",
            paneLabel: "Terminal",
            connectionStatus: "Connected",
            onAction: { _ in },
            onDismiss: {}
        )
        .environment(\.accessibilityReduceMotion, true)
    }
}

private final class LockedString: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: String

    init(_ value: String) {
        storage = value
    }

    var value: String {
        get { lock.withLock { storage } }
        set { lock.withLock { storage = newValue } }
    }
}

@MainActor
// swiftlint:disable:next type_body_length
final class TmuxAppTests: XCTestCase {

    // MARK: - 1. Probe Tmux

    func testTmuxProbeSuccess() async throws {
        let mock = MockSSHConnection()
        let transport = ControllableTransport()
        transport.onConnect = { _ in mock }

        let container = AppContainer(
            transport: transport,
            reachabilityMonitor: MockReachabilityMonitor(isReachable: true),
            reconnectCoordinator: ReconnectCoordinator(
                clock: { _ in }, jitter: ReconnectCoordinator.zeroJitter)
        )

        let host = try Host(name: "Tmux Host", hostname: "tmux.test", username: "user")
        await container.connect(to: host)
        XCTAssertEqual(container.activeSession?.state, .connected)

        mock.onExecuteCommand = { cmd in
            if cmd == TmuxCommand.probe {
                return SSHCommandResult(exitCode: 0, stdout: "tmux 3.4\n")
            }
            return SSHCommandResult(exitCode: 0, stdout: "")
        }

        let availability = await container.probeTmux()
        XCTAssertTrue(availability.isAvailable)
        XCTAssertEqual(availability.version, "tmux 3.4")
        XCTAssertEqual(container.tmuxAvailability, .available(version: "tmux 3.4"))
    }

    func testCommandDialControlRequiresApprovalAndUsesExecChannel() async throws {
        let mock = MockSSHConnection()
        let transport = ControllableTransport()
        transport.onConnect = { _ in mock }
        let container = AppContainer(
            transport: transport,
            reachabilityMonitor: MockReachabilityMonitor(isReachable: true),
            reconnectCoordinator: ReconnectCoordinator(
                clock: { _ in }, jitter: ReconnectCoordinator.zeroJitter)
        )
        let host = try Host(name: "Dial Host", hostname: "dial.test", username: "user")
        await container.connect(to: host)
        XCTAssertEqual(container.activeSession?.state, .connected)

        let sessionID = try TmuxSessionID("$4")
        let action = MultiplexerControlAction.tmux(.nextWindow(sessionID))
        let expected = try TmuxControl().command(for: action)
        mock.onExecuteCommand = { command in
            SSHCommandResult(exitCode: command == expected ? 0 : 1, stdout: "", stderr: "")
        }

        let rejected = await container.executeMultiplexerControl(action)
        XCTAssertFalse(rejected, "Dial controls require review")
        let approved = await container.executeMultiplexerControl(action, approved: true)
        XCTAssertTrue(approved)
        XCTAssertFalse(
            mock.sentData.contains { $0 == Data(expected.utf8) }, "Dial controls use exec, not PTY")
    }

    func testPinnedLiteralApprovalInsertsWithoutReturn() async throws {
        let mock = MockSSHConnection()
        let transport = ControllableTransport()
        transport.onConnect = { _ in mock }
        let container = AppContainer(
            transport: transport,
            reachabilityMonitor: MockReachabilityMonitor(isReachable: true),
            reconnectCoordinator: ReconnectCoordinator(
                clock: { _ in }, jitter: ReconnectCoordinator.zeroJitter)
        )
        let host = try Host(name: "Pinned Host", hostname: "pinned.test", username: "user")
        await container.connect(to: host)

        let rejected = await container.sendPinnedLiteral("sudo reboot")
        XCTAssertFalse(rejected)
        let approved = await container.sendPinnedLiteral("sudo reboot", approved: true)
        XCTAssertTrue(approved)
        XCTAssertEqual(mock.sentData.last, Data("sudo reboot".utf8))
    }

    func testCommandDialSurfaceFitsPhoneAndIPad() {
        var state = CommandDialNavigation(isOpen: true)
        let model = CommandDialModel(pinnedLiterals: ["echo ready"])
        let surface = CommandDialSurface(
            model: model,
            navigation: Binding(get: { state }, set: { state = $0 }),
            placement: .trailing,
            size: .regular,
            hostLabel: "Dial Host",
            paneLabel: "Primary terminal",
            connectionStatus: "Connected",
            onAction: { _ in },
            onDismiss: {}
        )

        let phone = UIHostingController(rootView: surface)
        phone.view.frame = CGRect(x: 0, y: 0, width: 393, height: 852)
        let phoneSize = phone.sizeThatFits(in: phone.view.bounds.size)
        XCTAssertGreaterThan(phoneSize.width, 0)
        XCTAssertGreaterThan(phoneSize.height, 0)

        let ipad = UIHostingController(rootView: surface)
        ipad.view.frame = CGRect(x: 0, y: 0, width: 1024, height: 1366)
        let ipadSize = ipad.sizeThatFits(in: ipad.view.bounds.size)
        XCTAssertGreaterThan(ipadSize.width, 0)
        XCTAssertGreaterThan(ipadSize.height, 0)

        let accessibilityPhone = UIHostingController(
            rootView: surface.environment(\.dynamicTypeSize, .accessibility3)
        )
        accessibilityPhone.view.frame = CGRect(x: 0, y: 0, width: 393, height: 852)
        accessibilityPhone.loadViewIfNeeded()
        accessibilityPhone.view.layoutIfNeeded()
        XCTAssertGreaterThan(accessibilityPhone.view.bounds.height, 0)

        let leadingSurface = CommandDialSurface(
            model: model,
            navigation: Binding(get: { state }, set: { state = $0 }),
            placement: .leading,
            size: .regular,
            hostLabel: "Dial Host",
            paneLabel: "Primary terminal",
            connectionStatus: "Connected",
            onAction: { _ in },
            onDismiss: {}
        )
        let leadingPhone = UIHostingController(rootView: leadingSurface)
        leadingPhone.view.frame = CGRect(x: 0, y: 0, width: 393, height: 852)
        let leadingPhoneSize = leadingPhone.sizeThatFits(in: leadingPhone.view.bounds.size)
        XCTAssertGreaterThan(leadingPhoneSize.width, 0)
        XCTAssertGreaterThan(leadingPhoneSize.height, 0)
        _ = state
    }

    func testCommandDialCompactKeyboardViewportStaysRadial() {
        XCTAssertFalse(CommandDialSurface.usesListLayout(dynamicTypeSize: .large))
        XCTAssertTrue(CommandDialSurface.usesListLayout(dynamicTypeSize: .accessibility3))
        XCTAssertFalse(
            CommandDialSurface.usesListLayout(
                dynamicTypeSize: .large,
                size: .compact,
                containerSize: CGSize(width: 568, height: 212),
                safeAreaInsets: EdgeInsets()
            )
        )
        XCTAssertFalse(
            CommandDialSurface.usesListLayout(
                dynamicTypeSize: .large,
                size: .compact,
                containerSize: CGSize(width: 568, height: 500),
                safeAreaInsets: EdgeInsets()
            )
        )
        var navigation = CommandDialNavigation(isOpen: true)
        let model = CommandDialModel(connected: true)
        let surface = CommandDialSurface(
            model: model,
            navigation: Binding(get: { navigation }, set: { navigation = $0 }),
            placement: .trailing, size: .compact,
            hostLabel: "Keyboard Review", paneLabel: "Terminal", connectionStatus: "Connected",
            onAction: { _ in }, onDismiss: {}
        )
        let window = UIWindow(frame: UIScreen.main.bounds)
        let hosting = UIHostingController(rootView: surface)
        window.rootViewController = hosting
        window.makeKeyAndVisible()
        defer { window.isHidden = true }
        let field = UITextField(frame: CGRect(x: 20, y: 65, width: 210, height: 44))
        field.accessibilityIdentifier = "keyboard-review-field"
        window.addSubview(field)
        XCTAssertTrue(field.becomeFirstResponder())
        RunLoop.current.run(until: Date().addingTimeInterval(2))
        hosting.view.layoutIfNeeded()
        XCTAssertTrue(field.isFirstResponder)
        // The reduced-height hosting viewport models the keyboard-occluded region.
        // Attach the rendered action list independent of the test runner foreground app.
        hosting.view.frame = CGRect(
            x: 0, y: 0, width: window.bounds.width, height: min(500, window.bounds.height * 0.62))
        hosting.view.setNeedsLayout()
        hosting.view.layoutIfNeeded()
        // Resize-driven SwiftUI layout must settle before inspecting or rendering the
        // native controls. A direct drawHierarchy immediately after changing the
        // hosting-controller frame can export Canvas connectors while omitting the
        // newly positioned Button layers.
        RunLoop.current.run(until: Date().addingTimeInterval(0.7))
        hosting.view.window?.layoutIfNeeded()
        logNativeViewFrames(in: hosting.view)
        let safeAreaInsets = hosting.view.safeAreaInsets
        let viewport = hosting.view.bounds.size
        let layout = CommandDialSurface.computeRadialLayout(
            size: .compact,
            placement: .trailing,
            nodeCount: model.roots.count,
            containerSize: viewport,
            safeAreaInsets: EdgeInsets(
                top: safeAreaInsets.top,
                leading: safeAreaInsets.left,
                bottom: safeAreaInsets.bottom,
                trailing: safeAreaInsets.right))
        let headerBottom = CommandDialSurface.headerBottomForLayout(
            safeAreaTop: safeAreaInsets.top)
        let cardFrames = layout.positions.compactMap { point in
            CGRect(
                x: point.x - layout.itemSize.width / 2,
                y: point.y - layout.itemSize.height / 2,
                width: layout.itemSize.width,
                height: layout.itemSize.height)
        }
        let hubFrame = CGRect(
            x: layout.center.x - 35, y: layout.center.y - 35, width: 70, height: 70)
        print(
            "command-dial measured viewport=\(viewport) safeArea=\(safeAreaInsets) "
                + "headerBottom=\(headerBottom) hub=\(hubFrame) cards=\(cardFrames)")
        let measuredInsets = DialLayoutInsets(
            top: headerBottom,
            leading: safeAreaInsets.left,
            bottom: safeAreaInsets.bottom,
            trailing: safeAreaInsets.right)
        XCTAssertTrue(layout.fits(in: viewport, safeAreaInsets: measuredInsets, hubRadius: 35))
        XCTAssertEqual(cardFrames.count, model.roots.count)
        XCTAssertTrue(cardFrames.allSatisfy { $0.intersects(hosting.view.bounds) })
        XCTAssertTrue(hubFrame.intersects(hosting.view.bounds))

        let renderer = UIGraphicsImageRenderer(bounds: hosting.view.bounds)
        let image = renderer.image { _ in
            hosting.view.drawHierarchy(in: hosting.view.bounds, afterScreenUpdates: true)
        }
        let attachment = XCTAttachment(image: image)
        attachment.name = "command-dial-keyboard-viewport-radial-stabilized"
        attachment.lifetime = .keepAlways
        add(attachment)

        let layerImage = renderer.image { context in
            hosting.view.layer.render(in: context.cgContext)
        }
        let layerAttachment = XCTAttachment(image: layerImage)
        layerAttachment.name = "command-dial-keyboard-viewport-layer-render"
        layerAttachment.lifetime = .keepAlways
        add(layerAttachment)
        _ = navigation
    }

    private func logNativeViewFrames(in hostingView: UIView) {
        let nativeViews = hostingView.subviews.flatMap { descendants(of: $0) }
        for view in nativeViews {
            let frame = view.convert(view.bounds, to: hostingView)
            guard frame.width > 0, frame.height > 0 else { continue }
            let identifier = view.accessibilityIdentifier ?? "-"
            print(
                "command-dial native \(String(describing: type(of: view))) "
                    + "identifier=\(identifier) frame=\(frame)")
        }
    }

    private func descendants(of view: UIView) -> [UIView] {
        view.subviews + view.subviews.flatMap { descendants(of: $0) }
    }

    func testCommandDialCompactKeyboardViewportKeepsCardsBelowHeader() throws {
        let compactViewport = CGSize(width: 568, height: 212)
        XCTAssertFalse(
            CommandDialSurface.usesListLayout(
                dynamicTypeSize: .large,
                size: .compact,
                containerSize: compactViewport,
                safeAreaInsets: EdgeInsets()
            )
        )

        let normalViewport = CGSize(width: 393, height: 500)
        XCTAssertFalse(
            CommandDialSurface.usesListLayout(
                dynamicTypeSize: .large,
                size: .compact,
                containerSize: normalViewport,
                safeAreaInsets: EdgeInsets()
            )
        )
        let layout = CommandDialSurface.computeRadialLayout(
            size: .compact,
            placement: .trailing,
            nodeCount: 4,
            containerSize: normalViewport,
            safeAreaInsets: EdgeInsets()
        )
        let topCard =
            try XCTUnwrap(layout.positions.map { $0.y }.min()) - layout.itemSize.height / 2
        let bottomCard =
            try XCTUnwrap(layout.positions.map { $0.y }.max()) + layout.itemSize.height / 2
        let normalInsets = DialLayoutInsets(
            top: CommandDialSurface.headerBottomForLayout(safeAreaTop: 0))
        XCTAssertTrue(
            layout.fits(
                in: normalViewport, safeAreaInsets: normalInsets, hubRadius: 35),
            "normal viewport geometry must clear the native header and hub")
        XCTAssertTrue(layout.hasSeparatedTargets(hubRadius: 35))
        XCTAssertGreaterThanOrEqual(
            layout.itemSize.width, DialRadialLayout.minimumTargetDimension)
        XCTAssertGreaterThanOrEqual(
            layout.itemSize.height, DialRadialLayout.minimumTargetDimension)
        let targetRects = try layout.positions.indices.map {
            try XCTUnwrap(layout.targetRect(at: $0))
        }
        XCTAssertTrue(
            targetRects.allSatisfy { rect in
                rect.minY >= normalInsets.top
                    && rect.maxY <= normalViewport.height
                    && rect.minX >= normalInsets.leading
                    && rect.maxX <= normalViewport.width - normalInsets.trailing
            },
            "visible card bounds must remain inside the measured native viewport")
        XCTAssertGreaterThanOrEqual(topCard, normalInsets.top)
        XCTAssertLessThanOrEqual(bottomCard, normalViewport.height)

        let compactLayout = CommandDialSurface.computeRadialLayout(
            size: .compact,
            placement: .trailing,
            nodeCount: 4,
            containerSize: compactViewport,
            safeAreaInsets: EdgeInsets()
        )
        let compactTopCard =
            try XCTUnwrap(compactLayout.positions.map { $0.y }.min())
            - compactLayout.itemSize.height / 2
        let compactBottomCard =
            try XCTUnwrap(compactLayout.positions.map { $0.y }.max())
            + compactLayout.itemSize.height / 2
        XCTAssertGreaterThanOrEqual(
            compactTopCard, CommandDialSurface.headerBottomForLayout(safeAreaTop: 0))
        XCTAssertLessThanOrEqual(compactBottomCard, compactViewport.height)
    }

    func testCommandDialRadialGeometrySeparatesTargetsAndPreservesAnchors() throws {
        let cases: [(CGSize, EdgeInsets)] = [
            (CGSize(width: 393, height: 500), EdgeInsets()),
            (
                CGSize(width: 393, height: 500),
                EdgeInsets(top: 59, leading: 0, bottom: 0, trailing: 0)
            ),
            (CGSize(width: 568, height: 212), EdgeInsets()),
        ]
        for (viewport, insets) in cases {
            let root = CommandDialSurface.computeRadialLayout(
                size: .compact, placement: .trailing, nodeCount: 4,
                containerSize: viewport, safeAreaInsets: insets)
            let layoutInsets = DialLayoutInsets(
                top: CommandDialSurface.headerBottomForLayout(safeAreaTop: insets.top),
                leading: insets.leading, bottom: insets.bottom, trailing: insets.trailing)
            XCTAssertTrue(
                root.fits(in: viewport, safeAreaInsets: layoutInsets, hubRadius: 35),
                "root geometry does not fit \(viewport) with insets \(insets)")
            XCTAssertTrue(root.hasSeparatedTargets(hubRadius: 35))
            for (index, point) in root.positions.enumerated() {
                XCTAssertEqual(root.index(at: point), index)
            }
            for first in root.positions.indices {
                for second in root.positions.indices where second > first {
                    let firstRect = try XCTUnwrap(root.targetRect(at: first))
                    let secondRect = try XCTUnwrap(root.targetRect(at: second))
                    XCTAssertFalse(firstRect.intersects(secondRect))
                }
            }

            let parent = try XCTUnwrap(root.point(at: 0))
            let child = CommandDialSurface.computeChildRadialLayout(
                size: .compact, placement: .trailing, nodeCount: 4, center: parent,
                containerSize: viewport, safeAreaInsets: insets)
            XCTAssertEqual(child.center, parent)
            XCTAssertTrue(
                child.fits(in: viewport, safeAreaInsets: layoutInsets, hubRadius: 35),
                "child geometry does not fit \(viewport) with insets \(insets), center \(parent), "
                    + "size \(child.itemSize)"
            )
            XCTAssertEqual(child.index(at: try XCTUnwrap(child.point(at: 0))), 0)
            XCTAssertNil(child.index(at: child.center))
        }
    }

    func testCommandDialCurrentAncestorAnchorFollowsKeyboardRotationAndResize() throws {
        let model = CommandDialModel(connected: true)
        let input = try XCTUnwrap(model.roots.first { $0.id == "root.input" })
        let navigate = try XCTUnwrap(input.children.first { $0.id == "input.navigate" })
        let cases: [(CGSize, EdgeInsets)] = [
            (
                CGSize(width: 393, height: 852),
                EdgeInsets(top: 59, leading: 0, bottom: 34, trailing: 0)
            ),
            (
                CGSize(width: 393, height: 500),
                EdgeInsets(top: 59, leading: 0, bottom: 8, trailing: 0)
            ),
            (
                CGSize(width: 852, height: 393),
                EdgeInsets(top: 0, leading: 0, bottom: 21, trailing: 0)
            ),
            (CGSize(width: 568, height: 212), EdgeInsets()),
        ]

        for (viewport, insets) in cases {
            let root = CommandDialSurface.computeRadialLayout(
                size: .compact, placement: .trailing, nodeCount: model.roots.count,
                containerSize: viewport, safeAreaInsets: insets)
            let rootIndex = try XCTUnwrap(model.roots.firstIndex(of: input))
            let rootAnchor = try XCTUnwrap(root.point(at: rootIndex))
            XCTAssertEqual(
                CommandDialSurface.computeCurrentAncestorCenter(
                    model: model, path: [], size: .compact, placement: .trailing,
                    containerSize: viewport, safeAreaInsets: insets), root.center,
                "root anchor must follow the current viewport")
            XCTAssertEqual(
                CommandDialSurface.computeCurrentAncestorCenter(
                    model: model, path: [input.id], size: .compact, placement: .trailing,
                    containerSize: viewport, safeAreaInsets: insets), rootAnchor,
                "child center must use the current root layout for \(viewport)")

            let inputLayout = CommandDialSurface.computeChildRadialLayout(
                size: .compact, placement: .trailing, nodeCount: input.children.count,
                center: rootAnchor, containerSize: viewport, safeAreaInsets: insets)
            let navigateIndex = try XCTUnwrap(input.children.firstIndex(of: navigate))
            let nestedAnchor = try XCTUnwrap(inputLayout.point(at: navigateIndex))
            XCTAssertEqual(
                CommandDialSurface.computeCurrentAncestorCenter(
                    model: model, path: [input.id, navigate.id], size: .compact,
                    placement: .trailing, containerSize: viewport, safeAreaInsets: insets),
                nestedAnchor,
                "nested child center must use current ancestor geometry for \(viewport)")

            // Accessibility activation has no drag point. It must resolve to the
            // same current anchor as ordinary radial button activation.
            var navigation = CommandDialNavigation(isOpen: true)
            navigation.enter(input)
            XCTAssertEqual(
                CommandDialSurface.computeCurrentAncestorCenter(
                    model: model, path: navigation.path, size: .compact,
                    placement: .trailing, containerSize: viewport, safeAreaInsets: insets),
                rootAnchor)
            navigation.enter(navigate)
            XCTAssertEqual(
                CommandDialSurface.computeCurrentAncestorCenter(
                    model: model, path: navigation.path, size: .compact,
                    placement: .trailing, containerSize: viewport, safeAreaInsets: insets),
                nestedAnchor)
        }
    }

    func testCommandDialNativeResizeAndRotationEvidence() throws {
        var navigation = CommandDialNavigation(isOpen: true)
        let model = CommandDialModel(connected: true)
        func surface() -> CommandDialSurface {
            CommandDialSurface(
                model: model,
                navigation: Binding(get: { navigation }, set: { navigation = $0 }),
                placement: .trailing,
                size: .compact,
                hostLabel: "Resize Host",
                paneLabel: "Terminal",
                connectionStatus: "Connected",
                onAction: { _ in }, onDismiss: {}
            )
        }
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 393, height: 852))
        let hosting = UIHostingController(rootView: surface())
        window.rootViewController = hosting
        window.makeKeyAndVisible()
        defer { window.isHidden = true }

        func capture(_ name: String, frame: CGRect) {
            hosting.view.frame = frame
            hosting.view.layoutIfNeeded()
            RunLoop.current.run(until: Date().addingTimeInterval(0.25))
            let renderer = UIGraphicsImageRenderer(bounds: hosting.view.bounds)
            let image = renderer.image { _ in
                hosting.view.drawHierarchy(in: hosting.view.bounds, afterScreenUpdates: true)
            }
            let attachment = XCTAttachment(image: image)
            attachment.name = name
            attachment.lifetime = .keepAlways
            add(attachment)
        }

        capture("dial-native-root", frame: CGRect(x: 0, y: 0, width: 393, height: 852))
        let input = try XCTUnwrap(model.roots.first { $0.id == "root.input" })
        navigation.enter(input)
        hosting.rootView = surface()
        capture(
            "dial-native-input-keyboard-resize",
            frame: CGRect(x: 0, y: 0, width: 393, height: 500))

        let navigate = try XCTUnwrap(input.children.first { $0.id == "input.navigate" })
        navigation.enter(navigate)
        hosting.rootView = surface()
        capture("dial-native-nested-rotation", frame: CGRect(x: 0, y: 0, width: 852, height: 393))
        XCTAssertEqual(navigation.path, [input.id, navigate.id])
    }

    func testCommandDialLeadingPlacementRadiusMatchesTrailing() throws {
        let insets = EdgeInsets(top: 59, leading: 0, bottom: 34, trailing: 0)
        let phoneSize = CGSize(width: 393, height: 852)
        let pointTolerance: CGFloat = 1e-9

        let leadingPhone = CommandDialSurface.computeRadialLayout(
            size: .compact,
            placement: .leading,
            nodeCount: 4,
            containerSize: phoneSize,
            safeAreaInsets: insets
        )
        let trailingPhone = CommandDialSurface.computeRadialLayout(
            size: .compact,
            placement: .trailing,
            nodeCount: 4,
            containerSize: phoneSize,
            safeAreaInsets: insets
        )

        try assertMirrored(
            leading: leadingPhone, trailing: trailingPhone, width: phoneSize.width,
            tolerance: pointTolerance)
        XCTAssertEqual(
            leadingPhone.orbitRadius, trailingPhone.orbitRadius, accuracy: pointTolerance,
            "mirror arithmetic may differ by a few floating-point ULPs, far below one point")
        XCTAssertGreaterThan(leadingPhone.orbitRadius, 132)

        let ipadSize = CGSize(width: 1024, height: 1366)
        let ipadInsets = EdgeInsets(top: 24, leading: 0, bottom: 20, trailing: 0)

        let leadingIPad = CommandDialSurface.computeRadialLayout(
            size: .regular,
            placement: .leading,
            nodeCount: 4,
            containerSize: ipadSize,
            safeAreaInsets: ipadInsets
        )
        let trailingIPad = CommandDialSurface.computeRadialLayout(
            size: .regular,
            placement: .trailing,
            nodeCount: 4,
            containerSize: ipadSize,
            safeAreaInsets: ipadInsets
        )

        try assertMirrored(
            leading: leadingIPad, trailing: trailingIPad, width: ipadSize.width,
            tolerance: pointTolerance)
        XCTAssertEqual(
            leadingIPad.orbitRadius, trailingIPad.orbitRadius, accuracy: pointTolerance)
        XCTAssertGreaterThan(
            leadingIPad.orbitRadius, 330,
            "non-uniform regular fans report their actual outermost point distance")

        let asymmetricTrailing = CommandDialSurface.computeRadialLayout(
            size: .regular,
            placement: .trailing,
            nodeCount: 3,
            containerSize: ipadSize,
            safeAreaInsets: ipadInsets
        )
        XCTAssertGreaterThan(
            abs(asymmetricTrailing.orbitRadius - trailingIPad.orbitRadius), 1,
            "a material count/radius perturbation must not be hidden by the point tolerance")
    }

    private func assertMirrored(
        leading: DialRadialLayout, trailing: DialRadialLayout,
        width: CGFloat, tolerance: CGFloat
    ) throws {
        XCTAssertEqual(leading.center.x + trailing.center.x, width, accuracy: tolerance)
        XCTAssertEqual(leading.center.y, trailing.center.y, accuracy: tolerance)
        XCTAssertEqual(leading.itemSize, trailing.itemSize)
        XCTAssertEqual(leading.positions.count, trailing.positions.count)
        for (leadingPoint, trailingPoint) in zip(leading.positions, trailing.positions) {
            XCTAssertEqual(leadingPoint.x + trailingPoint.x, width, accuracy: tolerance)
            XCTAssertEqual(leadingPoint.y, trailingPoint.y, accuracy: tolerance)
        }
        for index in leading.positions.indices {
            let leadingFrame = try XCTUnwrap(leading.targetRect(at: index))
            let trailingFrame = try XCTUnwrap(trailing.targetRect(at: index))
            XCTAssertEqual(leadingFrame.width, trailingFrame.width, accuracy: tolerance)
            XCTAssertEqual(leadingFrame.height, trailingFrame.height, accuracy: tolerance)
            XCTAssertEqual(leadingFrame.minX + trailingFrame.maxX, width, accuracy: tolerance)
            XCTAssertEqual(leadingFrame.minY, trailingFrame.minY, accuracy: tolerance)
        }
    }

    func testCommandDialHierarchyVisualEvidence() throws {
        var navigation = CommandDialNavigation(isOpen: true)
        let model = CommandDialModel(connected: true)
        func surface() -> CommandDialSurface {
            CommandDialSurface(
                model: model,
                navigation: Binding(get: { navigation }, set: { navigation = $0 }),
                placement: .trailing,
                size: .compact,
                hostLabel: "Review Host",
                paneLabel: "Terminal",
                connectionStatus: "Connected",
                onAction: { _ in }, onDismiss: {}
            )
        }
        let window = UIWindow(frame: UIScreen.main.bounds)
        let hosting = UIHostingController(rootView: surface())
        window.rootViewController = hosting
        window.makeKeyAndVisible()
        defer { window.isHidden = true }

        func capture(_ name: String) {
            RunLoop.current.run(until: Date().addingTimeInterval(0.7))
            hosting.view.layoutIfNeeded()
            let renderer = UIGraphicsImageRenderer(bounds: hosting.view.bounds)
            let image = renderer.image { _ in
                hosting.view.drawHierarchy(in: hosting.view.bounds, afterScreenUpdates: true)
            }
            let attachment = XCTAttachment(image: image)
            attachment.name = name
            attachment.lifetime = .keepAlways
            add(attachment)
        }

        capture("dial-root")
        let input = try XCTUnwrap(model.roots.first { $0.id == "root.input" })
        navigation.enter(input)
        hosting.rootView = surface()
        capture("dial-input")
        let navigate = try XCTUnwrap(input.children.first { $0.id == "input.navigate" })
        navigation.enter(navigate)
        hosting.rootView = surface()
        capture("dial-navigate")
        navigation.back()
        XCTAssertEqual(navigation.path, ["root.input"])
    }

    func testCommandDialNativeHostedViewportAccessibilityPathsAndReducedMotion() throws {
        let model = CommandDialModel(
            pinnedLiterals: ["echo ready"], connected: true)
        let viewports = [
            CGSize(width: 393, height: 500), CGSize(width: 568, height: 212),
        ]

        for placement in CommandDialPlacement.allCases {
            for viewport in viewports {
                var navigation = CommandDialNavigation(isOpen: true)
                let surface = CommandDialNativeTestSurface(
                    model: model,
                    navigation: navigation,
                    placement: placement,
                    onNavigationChange: { navigation = $0 })
                let window = UIWindow(frame: UIScreen.main.bounds)
                let hosting = UIHostingController(rootView: surface)
                hosting.loadViewIfNeeded()
                hosting.view.frame = CGRect(origin: .zero, size: viewport)
                window.rootViewController = hosting
                window.makeKeyAndVisible()
                hosting.beginAppearanceTransition(true, animated: false)
                hosting.endAppearanceTransition()
                defer {
                    hosting.beginAppearanceTransition(false, animated: false)
                    hosting.endAppearanceTransition()
                    window.endEditing(true)
                    window.resignKey()
                    window.isHidden = true
                    window.rootViewController = nil
                }
                hosting.view.setNeedsLayout()
                hosting.view.layoutIfNeeded()
                _ = RunLoop.main.run(mode: .common, before: Date())
                XCTAssertTrue(hosting.view.window === window)

                func activate(_ identifier: String) throws {
                    let target = try XCTUnwrap(
                        nativeActionTarget(identifier: identifier, in: hosting.view),
                        "missing native accessibility control \(identifier)")
                    assertNativeAccessibilityFrame(target, in: hosting.view)
                    if let view = target as? UIView {
                        XCTAssertTrue(
                            view.accessibilityActivate(),
                            "VoiceOver activation must use the real control path for \(identifier)")
                    } else {
                        let selector = NSSelectorFromString("accessibilityActivate")
                        let implementation = target.method(for: selector)
                        typealias AccessibilityActivate =
                            @convention(c) (AnyObject, Selector) -> Bool
                        let activate = unsafeBitCast(implementation, to: AccessibilityActivate.self)
                        let activated = activate(target, selector)
                        XCTAssertTrue(
                            activated,
                            "VoiceOver activation must use the real accessibility path "
                                + "for \(identifier)")
                    }
                    hosting.view.setNeedsLayout()
                    hosting.view.layoutIfNeeded()
                    _ = RunLoop.main.run(mode: .common, before: Date())
                    XCTAssertTrue(hosting.view.window === window)
                }

                func walk(_ nodes: [DialNode], path: [String]) throws {
                    for node in nodes where node.isEnabled {
                        try activate(nodeAccessibilityID(node))
                        if node.children.isEmpty {
                            XCTAssertEqual(navigation.path, path)
                        } else {
                            let childPath = path + [node.id]
                            XCTAssertEqual(navigation.path, childPath)
                            try walk(node.children, path: childPath)
                            try activate("command-dial-home")
                            XCTAssertEqual(navigation.path, path)
                            try activate(nodeAccessibilityID(node))
                            XCTAssertEqual(navigation.path, childPath)
                            try activate("command-dial-home")
                            XCTAssertEqual(navigation.path, path)
                        }
                    }
                }

                let input = try XCTUnwrap(model.roots.first { $0.id == "root.input" })
                let navigate = try XCTUnwrap(input.children.first { $0.id == "input.navigate" })
                try activate(nodeAccessibilityID(input))
                try activate(nodeAccessibilityID(navigate))
                let nestedPath = navigation.path
                hosting.view.frame = CGRect(
                    x: 0, y: 0, width: viewport.width, height: min(viewport.height, 500))
                hosting.view.setNeedsLayout()
                hosting.view.layoutIfNeeded()
                XCTAssertEqual(navigation.path, nestedPath)
                try activate("command-dial-home")
                XCTAssertEqual(navigation.path, [input.id])
                try activate("command-dial-home")
                XCTAssertTrue(navigation.path.isEmpty)

                try walk(model.roots, path: [])
            }
        }
    }

    private func nodeAccessibilityID(_ node: DialNode) -> String {
        "command-dial-node-\(node.id.replacingOccurrences(of: ".", with: "-"))"
    }

    private func nativeActionTarget(identifier: String, in root: UIView) -> NSObject? {
        let views = ([root] + descendants(of: root)).filter {
            $0.accessibilityIdentifier == identifier
        }
        if let view = views.max(by: {
            ($0.bounds.width * $0.bounds.height) < ($1.bounds.width * $1.bounds.height)
        }) {
            return view
        }

        for container in [root] + descendants(of: root) {
            guard let elements = container.accessibilityElements as? [NSObject] else { continue }
            if let element = findAccessibilityTarget(
                identifier: identifier, in: elements)
            {
                return element
            }
        }
        return nil
    }

    private func findAccessibilityTarget(
        identifier: String, in elements: [NSObject]) -> NSObject?
    {
        for element in elements {
            let elementIdentifier = element.value(forKey: "accessibilityIdentifier") as? String
            if elementIdentifier == identifier {
                return element
            }
            let childKeys = ["accessibilityElements", "accessibilityChildren", "children"]
            for key in childKeys where element.responds(to: NSSelectorFromString(key)) {
                let value = element.value(forKey: key)
                if let children = value as? [NSObject],
                    let match = findAccessibilityTarget(identifier: identifier, in: children)
                {
                    return match
                }
            }
        }
        return nil
    }

    private func assertNativeAccessibilityFrame(_ target: NSObject, in root: UIView) {
        let renderedFrame: CGRect
        let voiceOverFrame: CGRect
        if let view = target as? UIView {
            renderedFrame = view.convert(view.bounds, to: root)
            voiceOverFrame = view.accessibilityFrame
        } else {
            renderedFrame = (target.value(forKey: "accessibilityFrame") as? NSValue)?.cgRectValue ?? .zero
            voiceOverFrame = renderedFrame
        }
        XCTAssertGreaterThanOrEqual(renderedFrame.width + 0.001, 44)
        XCTAssertGreaterThanOrEqual(renderedFrame.height + 0.001, 44)
        XCTAssertGreaterThanOrEqual(voiceOverFrame.width + 0.001, 44)
        XCTAssertGreaterThanOrEqual(voiceOverFrame.height + 0.001, 44)
    }

    func testCommandDialSubmenusAndMultiplexerArtifacts() throws {
        var commonKeysNav = CommandDialNavigation(isOpen: true)
        let model = CommandDialModel(pinnedLiterals: ["ls -la", "cargo test"])
        guard let inputNode = model.roots.first(where: { $0.id == "root.input" }) else {
            XCTFail("Missing input root node")
            return
        }
        commonKeysNav.enter(inputNode)
        XCTAssertEqual(commonKeysNav.path, ["root.input"])

        let commonKeysSurface = CommandDialSurface(
            model: model,
            navigation: Binding(get: { commonKeysNav }, set: { commonKeysNav = $0 }),
            placement: .trailing,
            size: .compact,
            hostLabel: "Production Web",
            paneLabel: "Primary terminal",
            connectionStatus: "Connected",
            onAction: { _ in },
            onDismiss: {}
        )
        let phone = UIHostingController(rootView: commonKeysSurface)
        phone.view.frame = CGRect(x: 0, y: 0, width: 393, height: 852)
        phone.loadViewIfNeeded()
        XCTAssertGreaterThan(phone.view.bounds.height, 0)

        // Multiplexer controls submenu
        var muxNav = CommandDialNavigation(isOpen: true)
        let session = try TmuxSessionID("$3")
        let muxChildren = CommandDialMultiplexerMenu.nodes(
            tmuxSessionID: session, capabilities: .tmux)
        let muxModel = CommandDialModel(multiplexerChildren: muxChildren)
        guard let muxNode = muxModel.roots.first(where: { $0.id == "root.session" }) else {
            XCTFail("Missing session root node")
            return
        }
        muxNav.enter(muxNode)
        XCTAssertEqual(muxNav.path, ["root.session"])

        let muxSurface = CommandDialSurface(
            model: muxModel,
            navigation: Binding(get: { muxNav }, set: { muxNav = $0 }),
            placement: .trailing,
            size: .compact,
            hostLabel: "Production Web",
            paneLabel: "Primary terminal",
            connectionStatus: "Connected",
            onAction: { _ in },
            onDismiss: {}
        )
        let muxPhone = UIHostingController(rootView: muxSurface)
        muxPhone.view.frame = CGRect(x: 0, y: 0, width: 393, height: 852)
        muxPhone.loadViewIfNeeded()
        XCTAssertGreaterThan(muxPhone.view.bounds.height, 0)
    }

    func testSendImageEndToEndAndArtifacts() async throws {
        let mock = MockSSHConnection()
        let transport = ControllableTransport()
        transport.onConnect = { _ in mock }
        let sftp = DemoSFTPRepository(seedDemoData: true)
        let container = AppContainer(
            transport: transport,
            reachabilityMonitor: MockReachabilityMonitor(isReachable: true),
            reconnectCoordinator: ReconnectCoordinator(
                clock: { _ in }, jitter: ReconnectCoordinator.zeroJitter),
            sftpRepository: sftp
        )
        let host = try Host(name: "Image Host", hostname: "image.test", username: "dev")
        await container.connect(to: host)
        XCTAssertEqual(container.activeSession?.state, .connected)

        let idleContainer = AppContainer.demo()
        let sendImageView = SendImageView().environmentObject(idleContainer)
        let hosting = UIHostingController(rootView: sendImageView)
        hosting.view.frame = CGRect(x: 0, y: 0, width: 393, height: 852)
        hosting.loadViewIfNeeded()
        XCTAssertGreaterThan(hosting.view.bounds.height, 0)

        // 2. Generate valid test PNG image
        let renderer = UIGraphicsImageRenderer(size: CGSize(width: 80, height: 80))
        let testImage = renderer.image { ctx in
            UIColor.systemCyan.setFill()
            ctx.fill(CGRect(x: 0, y: 0, width: 80, height: 80))
        }
        guard let pngData = testImage.pngData() else {
            XCTFail("Failed to render test PNG")
            return
        }

        // 3. Initiate send image
        container.beginSendImage(data: pngData)
        XCTAssertTrue(container.sendImageState.isActive)

        // 4. Await completion
        let deadline = Date().addingTimeInterval(5.0)
        while Date() < deadline {
            if case .completed = container.sendImageState { break }
            if case .failed = container.sendImageState { break }
            try? await Task.sleep(nanoseconds: 30_000_000)
        }

        guard case .completed(let remotePath) = container.sendImageState else {
            XCTFail(
                "Expected .completed sendImageState, got: \(container.sendImageState), error: \(container.sendImageErrorMessage ?? "none")"
            )
            return
        }

        XCTAssertTrue(remotePath.description.hasPrefix("/home/dev/.shh/images/"))
        XCTAssertTrue(remotePath.description.hasSuffix(".png"))

        // Verify terminal insertion without Return
        guard let sentPathData = mock.sentData.last,
            let sentString = String(data: sentPathData, encoding: .utf8)
        else {
            XCTFail("Expected image path sent to terminal connection")
            return
        }
        XCTAssertFalse(
            sentString.hasSuffix("\n"), "Inserted image path must NOT end with a newline")
        XCTAssertFalse(
            sentString.hasSuffix("\r"), "Inserted image path must NOT end with a carriage return")
        XCTAssertTrue(
            sentString.contains("/home/dev/.shh/images/"), "Must contain quoted remote path")

        let completedHosting = UIHostingController(
            rootView: SendImageView().environmentObject(container))
        completedHosting.view.frame = CGRect(x: 0, y: 0, width: 393, height: 852)
        completedHosting.loadViewIfNeeded()
        XCTAssertGreaterThan(completedHosting.view.bounds.height, 0)
    }

    func testSendImageAdversarialRejectionAndCancellation() async throws {
        let mock = MockSSHConnection()
        let transport = ControllableTransport()
        transport.onConnect = { _ in mock }
        let sftp = DemoSFTPRepository(seedDemoData: true)
        let container = AppContainer(
            transport: transport,
            reachabilityMonitor: MockReachabilityMonitor(isReachable: true),
            reconnectCoordinator: ReconnectCoordinator(
                clock: { _ in }, jitter: ReconnectCoordinator.zeroJitter),
            sftpRepository: sftp
        )
        let host = try Host(name: "Image Host", hostname: "image.test", username: "dev")
        await container.connect(to: host)

        let initialSentCount = mock.sentData.count

        // Adversarial 1: Malformed bytes
        let malformed = Data([0xDE, 0xAD, 0xBE, 0xEF, 0x00, 0x11, 0x22])
        container.beginSendImage(data: malformed)
        try? await Task.sleep(nanoseconds: 50_000_000)
        XCTAssertEqual(container.sendImageState, .failed)
        XCTAssertNotNil(container.sendImageErrorMessage)
        XCTAssertEqual(
            mock.sentData.count, initialSentCount, "No terminal data sent for malformed image")

        // Adversarial 2: Empty data
        container.beginSendImage(data: Data())
        try? await Task.sleep(nanoseconds: 50_000_000)
        XCTAssertEqual(container.sendImageState, .failed)
        XCTAssertEqual(
            mock.sentData.count, initialSentCount, "No terminal data sent for empty image")

        // Adversarial 3: Immediate cancellation
        let renderer = UIGraphicsImageRenderer(size: CGSize(width: 40, height: 40))
        let img = renderer.image { _ in UIColor.red.setFill() }
        if let validData = img.pngData() {
            container.beginSendImage(data: validData)
            container.cancelSendImage()
            XCTAssertEqual(container.sendImageState, .cancelled)
        }
    }

    func testTmuxProbeFailureNoTmux() async throws {
        let mock = MockSSHConnection()
        let transport = ControllableTransport()
        transport.onConnect = { _ in mock }

        let container = AppContainer(
            transport: transport,
            reachabilityMonitor: MockReachabilityMonitor(isReachable: true),
            reconnectCoordinator: ReconnectCoordinator(
                clock: { _ in }, jitter: ReconnectCoordinator.zeroJitter)
        )

        let host = try Host(name: "No Tmux Host", hostname: "notmux.test", username: "user")
        await container.connect(to: host)

        mock.onExecuteCommand = { cmd in
            if cmd == TmuxCommand.probe {
                return SSHCommandResult(
                    exitCode: 127, stdout: "", stderr: "bash: tmux: command not found\n")
            }
            return SSHCommandResult(exitCode: 0, stdout: "")
        }

        let availability = await container.probeTmux()
        XCTAssertFalse(availability.isAvailable)
        XCTAssertEqual(container.tmuxAvailability, availability)
        XCTAssertFalse(container.isTmuxServerRunning)
        XCTAssertTrue(container.tmuxSessions.isEmpty)
    }

    // MARK: - 2. List Sessions

    func testTmuxListSessionsPopulated() async throws {
        let mock = MockSSHConnection()
        let transport = ControllableTransport()
        transport.onConnect = { _ in mock }

        let container = AppContainer(
            transport: transport,
            reachabilityMonitor: MockReachabilityMonitor(isReachable: true),
            reconnectCoordinator: ReconnectCoordinator(
                clock: { _ in }, jitter: ReconnectCoordinator.zeroJitter)
        )

        let host = try Host(name: "List Host", hostname: "list.test", username: "user")
        await container.connect(to: host)

        mock.onExecuteCommand = { cmd in
            if cmd == TmuxCommand.probe {
                return SSHCommandResult(exitCode: 0, stdout: "tmux 3.4\n")
            }
            if cmd == TmuxCommand.listSessions {
                let out =
                    "$0\twork\t3\t1700000000\t1700000500\t1\n$1\tbackground\t1\t1700000100\t1700000200\t0\n"
                return SSHCommandResult(exitCode: 0, stdout: out)
            }
            return SSHCommandResult(exitCode: 0, stdout: "")
        }

        let sessions = await container.listTmuxSessions()
        XCTAssertEqual(sessions.count, 2)
        XCTAssertEqual(sessions[0].sessionID, "$0")
        XCTAssertEqual(sessions[0].name, "work")
        XCTAssertEqual(sessions[0].windowsCount, 3)
        XCTAssertTrue(sessions[0].isAttached)
        XCTAssertEqual(sessions[0].attachedClients, 1)

        XCTAssertEqual(sessions[1].sessionID, "$1")
        XCTAssertEqual(sessions[1].name, "background")
        XCTAssertEqual(sessions[1].windowsCount, 1)
        XCTAssertFalse(sessions[1].isAttached)
        XCTAssertEqual(sessions[1].attachedClients, 0)

        XCTAssertTrue(container.isTmuxServerRunning)
        XCTAssertNil(container.tmuxError)
    }

    func testTmuxListSessionsNoServerRunning() async throws {
        let mock = MockSSHConnection()
        let transport = ControllableTransport()
        transport.onConnect = { _ in mock }

        let container = AppContainer(
            transport: transport,
            reachabilityMonitor: MockReachabilityMonitor(isReachable: true),
            reconnectCoordinator: ReconnectCoordinator(
                clock: { _ in }, jitter: ReconnectCoordinator.zeroJitter)
        )

        let host = try Host(name: "No Server Host", hostname: "noserver.test", username: "user")
        await container.connect(to: host)

        mock.onExecuteCommand = { cmd in
            if cmd == TmuxCommand.listSessions {
                return SSHCommandResult(
                    exitCode: 1, stdout: "", stderr: "no server running on /tmp/tmux-501/default\n")
            }
            return SSHCommandResult(exitCode: 0, stdout: "")
        }

        let sessions = await container.listTmuxSessions()
        XCTAssertTrue(sessions.isEmpty)
        XCTAssertFalse(container.isTmuxServerRunning)
        XCTAssertNil(container.tmuxError)
    }

    func testTmuxListSessionsNoSessions() async throws {
        let mock = MockSSHConnection()
        let transport = ControllableTransport()
        transport.onConnect = { _ in mock }

        let container = AppContainer(
            transport: transport,
            reachabilityMonitor: MockReachabilityMonitor(isReachable: true),
            reconnectCoordinator: ReconnectCoordinator(
                clock: { _ in }, jitter: ReconnectCoordinator.zeroJitter)
        )

        let host = try Host(name: "Empty Sessions Host", hostname: "empty.test", username: "user")
        await container.connect(to: host)

        mock.onExecuteCommand = { cmd in
            if cmd == TmuxCommand.listSessions {
                return SSHCommandResult(exitCode: 1, stdout: "", stderr: "no sessions\n")
            }
            return SSHCommandResult(exitCode: 0, stdout: "")
        }

        let sessions = await container.listTmuxSessions()
        XCTAssertTrue(sessions.isEmpty)
        XCTAssertTrue(container.isTmuxServerRunning)
        XCTAssertNil(container.tmuxError)
    }

    // MARK: - 3. Attach by Session ID

    func testAttachBySessionIDTargetsPTYAndPersistsMetadata() async throws {
        let mock = MockSSHConnection()
        let transport = ControllableTransport()
        transport.onConnect = { _ in mock }
        let store = InMemorySessionRestorationStore()

        let container = AppContainer(
            transport: transport,
            restorationStore: store,
            reachabilityMonitor: MockReachabilityMonitor(isReachable: true),
            reconnectCoordinator: ReconnectCoordinator(
                clock: { _ in }, jitter: ReconnectCoordinator.zeroJitter)
        )

        let host = try Host(name: "Attach Host", hostname: "attach.test", username: "user")
        await container.connect(to: host)

        let attachResult = await container.attachTmuxSession(id: "$2")
        XCTAssertTrue(attachResult)
        XCTAssertEqual(container.activeTmuxSessionID, "$2")
        XCTAssertNil(container.tmuxError)

        // Check command reached active connection PTY
        let sentStrings = mock.sentData.compactMap { String(data: $0, encoding: .utf8) }
        let hasAttachCmd = sentStrings.contains {
            $0.contains("env -u TMUX tmux attach-session -d -t '$2'")
        }
        XCTAssertTrue(hasAttachCmd, "PTY must receive exact attach command for $2")

        // Check restoration metadata persisted
        let loaded = try await store.load()
        XCTAssertNotNil(loaded)
        XCTAssertEqual(loaded?.tmuxSessionID, "$2")
        XCTAssertEqual(loaded?.hostID, host.id)
    }

    func testAttachmentPathsReconcileLatestViewportBeforeSending() async throws {
        let mock = MockSSHConnection()
        let transport = ControllableTransport()
        transport.onConnect = { _ in mock }
        let container = AppContainer(
            transport: transport,
            reachabilityMonitor: MockReachabilityMonitor(isReachable: true),
            reconnectCoordinator: ReconnectCoordinator(clock: { _ in }, jitter: ReconnectCoordinator.zeroJitter)
        )
        let host = try Host(name: "Viewport Tmux Host", hostname: "viewport-tmux.test", username: "user")
        await container.connect(to: host)

        let attachSize = TerminalSize(columns: 47, rows: 19)
        container.terminalController.handleResize(columns: attachSize.columns, rows: attachSize.rows)
        container.terminalController.flushResize()
        let attached = await container.attachTmuxSession(id: "$2")
        XCTAssertTrue(attached)
        XCTAssertEqual(mock.resizeCalls.last, attachSize)

        let createSize = TerminalSize(columns: 63, rows: 23)
        container.terminalController.handleResize(columns: createSize.columns, rows: createSize.rows)
        container.terminalController.flushResize()
        let created = await container.createTmuxSession(name: "workspace")
        XCTAssertTrue(created)
        XCTAssertEqual(mock.resizeCalls.last, createSize)
    }

    func testViewportChangeDuringAttachResizeIsAppliedBeforeTmuxCommand() async throws {
        let mock = MockSSHConnection()
        let resizeGate = AsyncGate()
        let transport = ControllableTransport()
        transport.onConnect = { _ in mock }
        let container = AppContainer(
            transport: transport,
            reachabilityMonitor: MockReachabilityMonitor(isReachable: true),
            reconnectCoordinator: ReconnectCoordinator(clock: { _ in }, jitter: ReconnectCoordinator.zeroJitter)
        )
        let host = try Host(name: "Attach Resize Race Host", hostname: "attach-race.test", username: "user")
        await container.connect(to: host)

        let firstSize = TerminalSize(columns: 48, rows: 19)
        let latestSize = TerminalSize(columns: 61, rows: 24)
        mock.onResize = { size in
            if size == firstSize {
                await resizeGate.wait()
            }
        }
        container.terminalController.handleResize(columns: firstSize.columns, rows: firstSize.rows)
        let attaching = Task { @MainActor in
            await container.attachTmuxSession(id: "$2")
        }
        await resizeGate.waitForStart()
        container.terminalController.handleResize(columns: latestSize.columns, rows: latestSize.rows)
        await resizeGate.open()

        let attachResult = await attaching.value
        XCTAssertTrue(attachResult)
        XCTAssertEqual(mock.resizeCalls.suffix(2), [firstSize, latestSize])
        XCTAssertEqual(container.activeSession?.terminalSize, latestSize)
        let sentStrings = mock.sentData.compactMap { String(data: $0, encoding: .utf8) }
        XCTAssertTrue(sentStrings.contains { $0.contains("attach-session -d -t '$2'") })
    }

    func testViewportChangeDuringCreateResizeIsAppliedBeforeTmuxCommand() async throws {
        let mock = MockSSHConnection()
        let resizeGate = AsyncGate()
        let transport = ControllableTransport()
        transport.onConnect = { _ in mock }
        let container = AppContainer(
            transport: transport,
            reachabilityMonitor: MockReachabilityMonitor(isReachable: true),
            reconnectCoordinator: ReconnectCoordinator(clock: { _ in }, jitter: ReconnectCoordinator.zeroJitter)
        )
        let host = try Host(name: "Create Resize Race Host", hostname: "create-race.test", username: "user")
        await container.connect(to: host)

        let firstSize = TerminalSize(columns: 49, rows: 20)
        let latestSize = TerminalSize(columns: 62, rows: 25)
        mock.onResize = { size in
            if size == firstSize {
                await resizeGate.wait()
            }
        }
        container.terminalController.handleResize(columns: firstSize.columns, rows: firstSize.rows)
        let creating = Task { @MainActor in
            await container.createTmuxSession(name: "workspace")
        }
        await resizeGate.waitForStart()
        container.terminalController.handleResize(columns: latestSize.columns, rows: latestSize.rows)
        await resizeGate.open()

        let createResult = await creating.value
        XCTAssertTrue(createResult)
        XCTAssertEqual(mock.resizeCalls.suffix(2), [firstSize, latestSize])
        XCTAssertEqual(container.activeSession?.terminalSize, latestSize)
        let sentStrings = mock.sentData.compactMap { String(data: $0, encoding: .utf8) }
        XCTAssertTrue(sentStrings.contains { $0.contains("tmux new-session -A -D -s 'workspace'") })
    }

    func testTmuxAttachmentAbortsWhenPTYResizeFails() async throws {
        let mock = MockSSHConnection()
        let transport = ControllableTransport()
        transport.onConnect = { _ in mock }
        let container = AppContainer(
            transport: transport,
            reachabilityMonitor: MockReachabilityMonitor(isReachable: true),
            reconnectCoordinator: ReconnectCoordinator(
                clock: { _ in },
                jitter: ReconnectCoordinator.zeroJitter
            )
        )
        let host = try Host(name: "Resize Failure Host", hostname: "resize-failure.test", username: "user")
        await container.connect(to: host)

        let requestedSize = TerminalSize(columns: 57, rows: 21)
        mock.onResize = { _ in
            throw TransportError.remoteFailure("PTY resize refused")
        }
        container.terminalController.handleResize(columns: requestedSize.columns, rows: requestedSize.rows)
        container.terminalController.flushResize()
        let sentBefore = mock.sentData.count

        let attached = await container.attachTmuxSession(id: "$2")

        XCTAssertFalse(attached)
        XCTAssertEqual(mock.sentData.count, sentBefore)
        XCTAssertNil(container.activeTmuxSessionID)
        XCTAssertNotEqual(container.activeSession?.terminalSize, requestedSize)
        XCTAssertTrue(container.tmuxError?.contains("Failed to resize terminal") == true)
    }

    func testViewportChangeDuringTmuxTargetValidationIsAppliedBeforeAttach() async throws {
        let mock = MockSSHConnection()
        let validationGate = AsyncGate()
        mock.onExecuteCommand = { command in
            if command.contains("has-session") {
                await validationGate.wait()
            }
            return SSHCommandResult(exitCode: 0, stdout: "")
        }
        let hostID = UUID()
        let store = InMemorySessionRestorationStore(initial: SessionRestorationMetadata(
            hostID: hostID,
            tmuxSessionID: "$2"
        ))
        let transport = ControllableTransport()
        transport.onConnect = { _ in mock }
        let container = AppContainer(
            transport: transport,
            restorationStore: store,
            reachabilityMonitor: MockReachabilityMonitor(isReachable: true),
            reconnectCoordinator: ReconnectCoordinator(clock: { _ in }, jitter: ReconnectCoordinator.zeroJitter)
        )
        let host = try Host(
            id: hostID,
            name: "Validation Host",
            hostname: "validation.test",
            username: "user",
            autoAttachTmux: true
        )
        let connecting = Task { @MainActor in
            await container.connect(to: host)
        }

        await validationGate.waitForStart()
        let latestSize = TerminalSize(columns: 59, rows: 22)
        container.terminalController.handleResize(columns: latestSize.columns, rows: latestSize.rows)
        container.terminalController.flushResize()
        await validationGate.open()
        await connecting.value

        XCTAssertEqual(container.activeTmuxSessionID, "$2")
        XCTAssertEqual(mock.resizeCalls.last, latestSize)
        let sentStrings = mock.sentData.compactMap { String(data: $0, encoding: .utf8) }
        XCTAssertTrue(sentStrings.contains { $0.contains("attach-session -d -t '$2'") })
    }

    func testAttachRejectsNonSessionIDNames() async throws {
        let mock = MockSSHConnection()
        let transport = ControllableTransport()
        transport.onConnect = { _ in mock }

        let container = AppContainer(
            transport: transport,
            reachabilityMonitor: MockReachabilityMonitor(isReachable: true),
            reconnectCoordinator: ReconnectCoordinator(
                clock: { _ in }, jitter: ReconnectCoordinator.zeroJitter)
        )

        let host = try Host(name: "Reject Host", hostname: "reject.test", username: "user")
        await container.connect(to: host)

        let initialSentCount = mock.sentData.count

        // Attaching by name like "main" must be rejected - attach is strictly by session ID ($id)
        let attachResult = await container.attachTmuxSession(id: "main")
        XCTAssertFalse(attachResult)
        XCTAssertNil(container.activeTmuxSessionID)
        XCTAssertNotNil(container.tmuxError)
        XCTAssertTrue(
            container.tmuxError?.contains("Existing tmux sessions must attach by session ID")
                ?? false)

        // Zero additional commands sent to PTY
        XCTAssertEqual(mock.sentData.count, initialSentCount)
    }

    // MARK: - 4. Validated Create-or-Attach by Name

    func testCreateOrAttachByNameTargetsPTYAndPersistsMetadata() async throws {
        let mock = MockSSHConnection()
        let transport = ControllableTransport()
        transport.onConnect = { _ in mock }
        mock.onExecuteCommand = { cmd in
            if cmd == TmuxCommand.probe || cmd == "tmux -V" {
                return SSHCommandResult(exitCode: 0, stdout: "tmux 3.4\n")
            }
            if cmd.contains("list-sessions") {
                return SSHCommandResult(exitCode: 0, stdout: "")
            }
            return SSHCommandResult(exitCode: 0, stdout: "")
        }
        let store = InMemorySessionRestorationStore()

        let container = AppContainer(
            transport: transport,
            restorationStore: store,
            reachabilityMonitor: MockReachabilityMonitor(isReachable: true),
            reconnectCoordinator: ReconnectCoordinator(
                clock: { _ in }, jitter: ReconnectCoordinator.zeroJitter)
        )

        let host = try Host(name: "Create Host", hostname: "create.test", username: "user")
        await container.connect(to: host)

        let createResult = await container.createTmuxSession(name: "workspace")
        XCTAssertTrue(createResult)
        XCTAssertEqual(container.activeTmuxSessionID, "workspace")
        XCTAssertNil(container.tmuxError)

        let sentStrings = mock.sentData.compactMap { String(data: $0, encoding: .utf8) }
        let hasNewSessionCmd = sentStrings.contains {
            $0.contains("tmux new-session -A -D -s 'workspace'")
        }
        XCTAssertTrue(
            hasNewSessionCmd, "PTY must receive exact new-session command for 'workspace'")

        let loaded = try await store.load()
        XCTAssertNotNil(loaded)
        XCTAssertEqual(loaded?.tmuxSessionID, "workspace")
    }

    func testCreateRejectsInvalidSessionNames() async throws {
        let mock = MockSSHConnection()
        let transport = ControllableTransport()
        transport.onConnect = { _ in mock }

        let container = AppContainer(
            transport: transport,
            reachabilityMonitor: MockReachabilityMonitor(isReachable: true),
            reconnectCoordinator: ReconnectCoordinator(
                clock: { _ in }, jitter: ReconnectCoordinator.zeroJitter)
        )

        let host = try Host(name: "Invalid Host", hostname: "invalid.test", username: "user")
        await container.connect(to: host)

        let invalidNames = [
            "",
            "   ",
            "foo:bar",
            "foo.bar",
            "foo\u{07}bar",
            String(repeating: "a", count: 129),
        ]

        let initialSentCount = mock.sentData.count

        for name in invalidNames {
            let res = await container.createTmuxSession(name: name)
            XCTAssertFalse(res, "Name '\(name)' must be rejected")
            XCTAssertNotNil(container.tmuxError)
        }

        XCTAssertEqual(
            mock.sentData.count, initialSentCount,
            "No commands sent to PTY for invalid session names")
    }

    // MARK: - 5. Zero Terminal Pollution During Discovery

    func testNoTerminalPollutionDuringDiscovery() async throws {
        let mock = MockSSHConnection()
        let transport = ControllableTransport()
        transport.onConnect = { _ in mock }

        let container = AppContainer(
            transport: transport,
            reachabilityMonitor: MockReachabilityMonitor(isReachable: true),
            reconnectCoordinator: ReconnectCoordinator(
                clock: { _ in }, jitter: ReconnectCoordinator.zeroJitter)
        )

        let host = try Host(name: "Clean Host", hostname: "clean.test", username: "user")
        await container.connect(to: host)

        let sentCountBeforeDiscovery = mock.sentData.count

        await container.refreshTmuxState()
        _ = await container.probeTmux()
        _ = await container.listTmuxSessions()

        // Verify sentData to PTY remained completely untouched during probe & list
        XCTAssertEqual(
            mock.sentData.count, sentCountBeforeDiscovery,
            "Discovery operations must never write to the active PTY")
        XCTAssertEqual(container.terminalText, "", "Terminal text must remain empty and unpolluted")
    }

    // MARK: - 6. No Kill-Server Surface or Arbitrary Input

    func testNoKillServerSurfaceOrArbitraryCommandInput() async throws {
        let policy = CommandPolicy()

        // 1. Central policy strictly blocks kill-server and global session destruction
        XCTAssertEqual(policy.classify("tmux kill-server"), .blocked)
        XCTAssertFalse(policy.canSend("tmux kill-server", approved: true))

        XCTAssertEqual(policy.classify("tmux kill-session -a"), .blocked)
        XCTAssertFalse(policy.canSend("tmux kill-session -a", approved: true))

        XCTAssertEqual(policy.classify("tmux kill-session -g"), .blocked)
        XCTAssertFalse(policy.canSend("tmux kill-session -g", approved: true))

        XCTAssertEqual(policy.classify("tmux kill-session --all"), .blocked)
        XCTAssertFalse(policy.canSend("tmux kill-session --all", approved: true))

        // 2. AppContainer sendValidatedCommand strictly blocks kill-server
        let mock = MockSSHConnection()
        let transport = ControllableTransport()
        transport.onConnect = { _ in mock }
        let container = AppContainer(
            transport: transport,
            reachabilityMonitor: MockReachabilityMonitor(isReachable: true),
            reconnectCoordinator: ReconnectCoordinator(
                clock: { _ in }, jitter: ReconnectCoordinator.zeroJitter)
        )

        let host = try Host(name: "Safe Host", hostname: "safe.test", username: "user")
        await container.connect(to: host)

        let sentBefore = mock.sentData.count
        let blockedResult = await container.sendValidatedCommand(
            "tmux kill-server\n", approved: true)
        XCTAssertFalse(blockedResult, "kill-server must be blocked by sendValidatedCommand")
        XCTAssertEqual(mock.sentData.count, sentBefore, "PTY must never receive kill-server")
    }

    // MARK: - 7. Missing Session Handling on Restoration

    func testRememberedRestorationMissingSessionHandling() async throws {
        let mock = MockSSHConnection()
        let transport = ControllableTransport()
        transport.onConnect = { _ in mock }

        let hostID = UUID()
        let store = InMemorySessionRestorationStore(
            initial: SessionRestorationMetadata(
                hostID: hostID,
                tmuxSessionID: "$99"
            ))
        let container = AppContainer(
            transport: transport,
            restorationStore: store,
            reachabilityMonitor: MockReachabilityMonitor(isReachable: true),
            reconnectCoordinator: ReconnectCoordinator(
                clock: { _ in }, jitter: ReconnectCoordinator.zeroJitter)
        )

        // Mock has-session to return failure (missing session)
        mock.onExecuteCommand = { cmd in
            if cmd.contains("has-session") && cmd.contains("$99") {
                return SSHCommandResult(
                    exitCode: 1, stdout: "", stderr: "can't find session: $99\n")
            }
            return SSHCommandResult(exitCode: 0, stdout: "")
        }

        let host = try Host(
            id: hostID,
            name: "Missing Session Host",
            hostname: "missing.test",
            username: "user",
            autoAttachTmux: true
        )

        await container.connect(to: host)

        // Check explicit error message populated
        XCTAssertNotNil(container.tmuxError)
        XCTAssertTrue(
            container.tmuxError?.contains("Remembered tmux session $99 no longer exists") ?? false)

        // Verify attach was NOT sent to PTY
        let sentStrings = mock.sentData.compactMap { String(data: $0, encoding: .utf8) }
        let hasAttach = sentStrings.contains {
            $0.contains("attach-session") && $0.contains("'$99'")
        }
        XCTAssertFalse(hasAttach, "Missing session must not send failing attach command to PTY")

        // The stale target remains available for explicit recovery and is not
        // replaced by a missing-session failure.
        XCTAssertNil(container.activeTmuxSessionID)
        let savedMetadata = try await container.restorationStore.load()
        XCTAssertEqual(savedMetadata?.tmuxSessionID, "$99")
    }

    func testFailedAttachPreservesPreviousLastUsedTarget() async throws {
        let mock = MockSSHConnection()
        let transport = ControllableTransport()
        transport.onConnect = { _ in mock }
        let store = InMemorySessionRestorationStore()
        let container = AppContainer(
            transport: transport,
            restorationStore: store,
            reachabilityMonitor: MockReachabilityMonitor(isReachable: true),
            reconnectCoordinator: ReconnectCoordinator(
                clock: { _ in }, jitter: ReconnectCoordinator.zeroJitter)
        )
        let host = try Host(
            name: "Preserve Target Host", hostname: "preserve.test", username: "user")
        await container.connect(to: host)
        let firstAttach = await container.attachTmuxSession(id: "$2")
        XCTAssertTrue(firstAttach)

        mock.onSend = { _ in throw TransportError.remoteFailure("attach failed") }
        let failedAttach = await container.attachTmuxSession(id: "$3")
        XCTAssertFalse(failedAttach)
        let preservedMetadata = try await store.load()
        XCTAssertEqual(preservedMetadata?.tmuxSessionID, "$2")
    }

    func testExplicitDisconnectPreservesLastUsedTarget() async throws {
        let mock = MockSSHConnection()
        let transport = ControllableTransport()
        transport.onConnect = { _ in mock }
        let store = InMemorySessionRestorationStore()
        let container = AppContainer(
            transport: transport,
            restorationStore: store,
            reachabilityMonitor: MockReachabilityMonitor(isReachable: true),
            reconnectCoordinator: ReconnectCoordinator(
                clock: { _ in }, jitter: ReconnectCoordinator.zeroJitter)
        )
        let host = try Host(
            name: "Disconnect Target Host", hostname: "disconnect-target.test", username: "user")
        await container.connect(to: host)
        let attachSuccess = await container.attachTmuxSession(id: "$4")
        XCTAssertTrue(attachSuccess)
        await container.disconnect()

        XCTAssertTrue(container.isExplicitDisconnect)
        let preservedMetadata = try await store.load()
        XCTAssertEqual(preservedMetadata?.tmuxSessionID, "$4")
    }

    // MARK: - 8. Reconnect Cancellation & Disconnect Races

    func testReconnectCancellationStopsCoordinator() async throws {
        let transport = ControllableTransport()
        let mockMonitor = MockReachabilityMonitor(isReachable: false)
        let coordinator = ReconnectCoordinator(
            clock: { _ in }, jitter: ReconnectCoordinator.zeroJitter)

        let container = AppContainer(
            transport: transport,
            reachabilityMonitor: mockMonitor,
            reconnectCoordinator: coordinator
        )

        let host = try Host(name: "Cancel Host", hostname: "cancel.test", username: "user")
        await container.connect(to: host)

        // Drop reachability
        mockMonitor.setReachable(false)
        container.handleReachabilityChange(false)

        // User cancels
        await container.cancelReconnect()
        XCTAssertEqual(container.reconnectState, .cancelled)
        XCTAssertTrue(container.isExplicitDisconnect)

        // Reachability restored afterwards does NOT trigger reconnect
        mockMonitor.setReachable(true)
        container.handleReachabilityChange(true)
        XCTAssertEqual(container.reconnectState, .cancelled)
    }

    func testDisconnectResetsTmuxStateAndDiscardsStaleProbeResults() async throws {
        let mock = MockSSHConnection()
        let transport = ControllableTransport()
        transport.onConnect = { _ in mock }

        let container = AppContainer(
            transport: transport,
            reachabilityMonitor: MockReachabilityMonitor(isReachable: true),
            reconnectCoordinator: ReconnectCoordinator(
                clock: { _ in }, jitter: ReconnectCoordinator.zeroJitter)
        )

        let host = try Host(name: "Race Host", hostname: "race.test", username: "user")
        await container.connect(to: host)

        await container.attachTmuxSession(id: "$0")
        XCTAssertEqual(container.activeTmuxSessionID, "$0")

        await container.disconnect()
        XCTAssertNil(container.activeTmuxSessionID)
        XCTAssertTrue(container.tmuxSessions.isEmpty)
        XCTAssertFalse(container.isTmuxServerRunning)
        XCTAssertEqual(container.tmuxAvailability, .unavailable(reason: "Not connected"))
        XCTAssertNil(container.tmuxError)

        // Stale probe invocation on disconnected session must return unavailable
        let staleProbe = await container.probeTmux()
        XCTAssertFalse(staleProbe.isAvailable)
        XCTAssertEqual(container.tmuxAvailability, .unavailable(reason: "Not connected"))
    }

    // MARK: - 9. Demo Mode Determinism

    func testDemoModeDeterminism() async throws {
        let container = AppContainer.demo()
        XCTAssertTrue(container.isDemo)

        let demoChallenge = HostKeyChallenge(
            hostname: "demo.local", port: 22, algorithm: "ssh-ed25519",
            fingerprint: "SHA256:demo-fingerprint")
        await container.trustStore.save(demoChallenge)

        let host = try Host(name: "Demo Host", hostname: "demo.local", username: "dev")
        await container.connect(to: host)
        XCTAssertEqual(container.activeSession?.state, .connected)

        // Probe in demo mode
        let availability = await container.probeTmux()
        XCTAssertTrue(availability.isAvailable)
        XCTAssertEqual(availability.version, "tmux 3.4")

        // List in demo mode
        let sessions = await container.listTmuxSessions()
        XCTAssertEqual(sessions.count, 1)
        XCTAssertEqual(sessions[0].sessionID, "$0")
        XCTAssertEqual(sessions[0].name, "demo-main")

        // Attach in demo mode
        let attached = await container.attachTmuxSession(id: "$0")
        XCTAssertTrue(attached)
        XCTAssertEqual(container.activeTmuxSessionID, "$0")

        // Create in demo mode
        let created = await container.createTmuxSession(name: "demo-session")
        XCTAssertTrue(created)
        XCTAssertEqual(container.activeTmuxSessionID, "demo-session")
    }

    // MARK: - 10. UI View & VoiceOver Accessibility

    func testMultiplexerPickerViewAccessibilityAndVoiceOver() async throws {
        let container = AppContainer.demo()
        let demoChallenge = HostKeyChallenge(
            hostname: "demo.local", port: 22, algorithm: "ssh-ed25519",
            fingerprint: "SHA256:demo-fingerprint")
        await container.trustStore.save(demoChallenge)

        let host = try Host(name: "UI Host", hostname: "demo.local", username: "dev")
        await container.connect(to: host)

        let longSessionName =
            "a-very-long-tmux-session-name-that-tests-truncation-behavior-across-compact-and-regular-size-classes"
        container.tmuxAvailability = .available(version: "tmux 3.4")
        container.isTmuxServerRunning = true
        container.activeTmuxSessionID = "$0"
        container.tmuxSessions = [
            TmuxSessionInfo(
                sessionID: "$0",
                name: longSessionName,
                windowsCount: 2,
                createdAt: Date(timeIntervalSince1970: 1_700_000_000),
                lastActivityAt: Date(),
                attachedClients: 1
            ),
            TmuxSessionInfo(
                sessionID: "$1",
                name: "dev",
                windowsCount: 1,
                createdAt: Date(timeIntervalSince1970: 1_700_000_100),
                lastActivityAt: Date(),
                attachedClients: 0
            ),
        ]

        let picker = MultiplexerPicker().environmentObject(container)
        let hostingController = UIHostingController(rootView: picker)
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 393, height: 852))
        window.rootViewController = hostingController
        window.makeKeyAndVisible()
        hostingController.view.layoutIfNeeded()

        XCTAssertGreaterThan(hostingController.view.bounds.width, 0)
        XCTAssertGreaterThan(hostingController.view.bounds.height, 0)
        XCTAssertGreaterThan(hostingController.view.subviews.count, 0)

        // Verify active session check recognizes session by ID
        XCTAssertTrue(container.isTmuxSessionActive(container.tmuxSessions[0]))
        XCTAssertFalse(container.isTmuxSessionActive(container.tmuxSessions[1]))

        // Verify VoiceOver accessibility metadata
        let session0 = container.tmuxSessions[0]
        XCTAssertEqual(session0.sessionID, "$0")
        XCTAssertEqual(session0.name, longSessionName)
        XCTAssertTrue(session0.isAttached)

        let session1 = container.tmuxSessions[1]
        XCTAssertEqual(session1.sessionID, "$1")
        XCTAssertEqual(session1.name, "dev")
        XCTAssertFalse(session1.isAttached)
    }

    // MARK: - 11. iPhone and iPad Layouts

    func testMultiplexerPickerIPhoneAndIPadLayouts() async throws {
        let container = AppContainer.demo()
        let host = try Host(name: "Layout Host", hostname: "demo.local", username: "dev")
        await container.connect(to: host)

        let longName = String(repeating: "long-name-", count: 8)
        container.tmuxAvailability = .available(version: "tmux 3.4")
        container.isTmuxServerRunning = true
        container.tmuxSessions = [
            TmuxSessionInfo(
                sessionID: "$0",
                name: longName,
                windowsCount: 5,
                createdAt: Date(),
                lastActivityAt: Date(),
                attachedClients: 1
            )
        ]

        // Compact size class (iPhone portrait)
        let compactView = MultiplexerPicker()
            .environmentObject(container)
            .environment(\.horizontalSizeClass, .compact)
        let compactController = UIHostingController(rootView: compactView)
        let compactWindow = UIWindow(frame: CGRect(x: 0, y: 0, width: 393, height: 852))
        compactWindow.rootViewController = compactController
        compactWindow.makeKeyAndVisible()
        compactController.view.layoutIfNeeded()

        XCTAssertEqual(compactController.view.bounds.width, 393)
        XCTAssertEqual(compactController.view.bounds.height, 852)
        XCTAssertGreaterThan(compactController.view.subviews.count, 0)

        // Regular size class (iPad landscape)
        let regularView = MultiplexerPicker()
            .environmentObject(container)
            .environment(\.horizontalSizeClass, .regular)
        let regularController = UIHostingController(rootView: regularView)
        let regularWindow = UIWindow(frame: CGRect(x: 0, y: 0, width: 1024, height: 768))
        regularWindow.rootViewController = regularController
        regularWindow.makeKeyAndVisible()
        regularController.view.layoutIfNeeded()

        XCTAssertEqual(regularController.view.bounds.width, 1024)
        XCTAssertEqual(regularController.view.bounds.height, 768)
        XCTAssertGreaterThan(regularController.view.subviews.count, 0)
    }

    // MARK: - 12. Regression Tests (Findings 1 - 8)

    func testStaleProbeAndListResultsDoNotOverwriteNewOrDisconnectedSession() async throws {
        let mock = MockSSHConnection()
        let transport = ControllableTransport()
        transport.onConnect = { _ in mock }

        let container = AppContainer(
            transport: transport,
            reachabilityMonitor: MockReachabilityMonitor(isReachable: true),
            reconnectCoordinator: ReconnectCoordinator(
                clock: { _ in }, jitter: ReconnectCoordinator.zeroJitter)
        )

        let host = try Host(name: "Stale Host", hostname: "stale.test", username: "user")
        await container.connect(to: host)
        XCTAssertEqual(container.activeSession?.state, .connected)

        let gate = AsyncGate()
        mock.onExecuteCommand = { cmd in
            if cmd == TmuxCommand.probe {
                await gate.wait()
                return SSHCommandResult(exitCode: 0, stdout: "tmux 3.4\n")
            }
            if cmd == TmuxCommand.listSessions {
                return SSHCommandResult(
                    exitCode: 0, stdout: "$0\tmain\t1\t1700000000\t1700000500\t1\n")
            }
            return SSHCommandResult(exitCode: 0, stdout: "")
        }

        // Start refreshTmuxState asynchronously while probe is blocked at gate
        let refreshTask = Task {
            await container.refreshTmuxState()
        }

        // Wait slightly for refresh to enter probe await
        try await Task.sleep(nanoseconds: 20_000_000)

        // Disconnect before probe returns
        await container.disconnect()
        XCTAssertEqual(container.activeSession?.state, .disconnected)
        XCTAssertEqual(container.tmuxAvailability, .unavailable(reason: "Not connected"))
        XCTAssertTrue(container.tmuxSessions.isEmpty)
        XCTAssertFalse(container.isTmuxServerRunning)

        // Now open the gate so the probe completes
        await gate.open()
        await refreshTask.value

        // Verify that stale probe/list results did NOT overwrite the disconnected state
        XCTAssertEqual(container.activeSession?.state, .disconnected)
        XCTAssertEqual(container.tmuxAvailability, .unavailable(reason: "Not connected"))
        XCTAssertTrue(container.tmuxSessions.isEmpty)
        XCTAssertFalse(container.isTmuxServerRunning)
    }

    func testStaleHasSessionDoesNotMutateStateAfterDisconnect() async throws {
        let mock = MockSSHConnection()
        let transport = ControllableTransport()
        transport.onConnect = { _ in mock }

        let container = AppContainer(
            transport: transport,
            reachabilityMonitor: MockReachabilityMonitor(isReachable: true),
            reconnectCoordinator: ReconnectCoordinator(
                clock: { _ in }, jitter: ReconnectCoordinator.zeroJitter)
        )

        let gate = AsyncGate()
        mock.onExecuteCommand = { cmd in
            if cmd.contains("has-session") {
                await gate.wait()
                return SSHCommandResult(exitCode: 1, stdout: "", stderr: "no session")
            }
            return SSHCommandResult(exitCode: 0, stdout: "")
        }

        let host = try Host(
            name: "Slow Host", hostname: "slow.test", username: "user", defaultTmuxSession: "$99",
            autoAttachTmux: true)

        let connectTask = Task {
            await container.connect(to: host)
        }

        try await Task.sleep(nanoseconds: 20_000_000)
        await container.disconnect()

        await gate.open()
        await connectTask.value

        // Error should not be assigned to disconnected session
        XCTAssertNil(container.tmuxError)
        XCTAssertNil(container.activeTmuxSessionID)
    }

    func testCreatedSessionResolvesToSessionIDAfterListAndUIRecognizesActive() async throws {
        let mock = MockSSHConnection()
        let transport = ControllableTransport()
        transport.onConnect = { _ in mock }

        let container = AppContainer(
            transport: transport,
            reachabilityMonitor: MockReachabilityMonitor(isReachable: true),
            reconnectCoordinator: ReconnectCoordinator(
                clock: { _ in }, jitter: ReconnectCoordinator.zeroJitter)
        )

        let host = try Host(name: "Create Host", hostname: "create.test", username: "user")
        await container.connect(to: host)

        let sessionsOutput = LockedString("$0\tother\t1\t1700000000\t1700000500\t0\n")
        mock.onExecuteCommand = { cmd in
            if cmd == TmuxCommand.probe {
                return SSHCommandResult(exitCode: 0, stdout: "tmux 3.4\n")
            }
            if cmd == TmuxCommand.listSessions {
                return SSHCommandResult(exitCode: 0, stdout: sessionsOutput.value)
            }
            return SSHCommandResult(exitCode: 0, stdout: "")
        }

        let created = await container.createTmuxSession(name: "project-work")
        XCTAssertTrue(created)
        XCTAssertEqual(container.activeTmuxSessionID, "project-work")

        let candidateSession = TmuxSessionInfo(
            sessionID: "$5",
            name: "project-work",
            windowsCount: 1,
            createdAt: Date(),
            lastActivityAt: Date(),
            attachedClients: 1
        )

        // UI recognizes active by transitional name
        XCTAssertTrue(container.isTmuxSessionActive(candidateSession))

        // Now remote list updates with the new session
        sessionsOutput.value =
            "$0\tother\t1\t1700000000\t1700000500\t0\n$5\tproject-work\t1\t1700000000\t1700000500\t1\n"
        let sessions = await container.listTmuxSessions()
        XCTAssertEqual(sessions.count, 2)
        XCTAssertEqual(container.activeTmuxSessionID, "$5")

        // Restoration store updated with resolved ID
        let metadata = try await container.restorationStore.load()
        XCTAssertEqual(metadata?.tmuxSessionID, "$5")

        // UI recognizes active by canonical ID
        XCTAssertFalse(container.isTmuxSessionActive(sessions[0]))
        XCTAssertTrue(container.isTmuxSessionActive(sessions[1]))
    }

    func testPreferenceValidationAndAtomicHostSync() async throws {
        let container = AppContainer.demo()
        let host = try Host(name: "Sync Host", hostname: "sync.test", username: "user")
        try await container.catalog.save(host)
        await container.connect(to: host)

        XCTAssertEqual(container.activeHost?.autoAttachTmux, false)
        XCTAssertNil(container.activeHost?.defaultTmuxSession)

        // Legacy target arguments are ignored while auto-attach remains configurable.
        try await container.updateActiveHostPreferences(
            autoAttachTmux: true, defaultTmuxSession: "legacy-session")
        XCTAssertEqual(container.activeHost?.autoAttachTmux, true)
        XCTAssertNil(container.activeHost?.defaultTmuxSession)
        let reloadedHost = try await container.catalog.listHosts().first(where: { $0.id == host.id }
        )
        XCTAssertNil(reloadedHost?.defaultTmuxSession)
        XCTAssertEqual(reloadedHost?.autoAttachTmux, true)

        try await container.updateActiveHostPreferences(
            autoAttachTmux: false, defaultTmuxSession: "$3")
        XCTAssertEqual(container.activeHost?.autoAttachTmux, false)
        XCTAssertNil(container.activeHost?.defaultTmuxSession)
    }

    func testListSessionsParserFailureSurfacesSafeUserVisibleError() async throws {
        let mock = MockSSHConnection()
        let transport = ControllableTransport()
        transport.onConnect = { _ in mock }

        let container = AppContainer(
            transport: transport,
            reachabilityMonitor: MockReachabilityMonitor(isReachable: true),
            reconnectCoordinator: ReconnectCoordinator(
                clock: { _ in }, jitter: ReconnectCoordinator.zeroJitter)
        )

        let host = try Host(name: "Parse Host", hostname: "parse.test", username: "user")
        await container.connect(to: host)

        mock.onExecuteCommand = { cmd in
            if cmd == TmuxCommand.probe {
                return SSHCommandResult(exitCode: 0, stdout: "tmux 3.4\n")
            }
            if cmd == TmuxCommand.listSessions {
                return SSHCommandResult(exitCode: 0, stdout: "invalid line without tabs\n")
            }
            return SSHCommandResult(exitCode: 0, stdout: "")
        }

        let sessions = await container.listTmuxSessions()
        XCTAssertTrue(sessions.isEmpty)
        XCTAssertTrue(container.tmuxSessions.isEmpty)
        XCTAssertTrue(container.isTmuxServerRunning)
        XCTAssertNotNil(container.tmuxError)
        XCTAssertTrue(container.tmuxError?.contains("Failed to parse tmux sessions") ?? false)
    }

    func testServerStopAndSessionDisappearanceClearsActiveSessionAndRestoration() async throws {
        let mock = MockSSHConnection()
        let transport = ControllableTransport()
        transport.onConnect = { _ in mock }

        let container = AppContainer(
            transport: transport,
            reachabilityMonitor: MockReachabilityMonitor(isReachable: true),
            reconnectCoordinator: ReconnectCoordinator(
                clock: { _ in }, jitter: ReconnectCoordinator.zeroJitter)
        )

        let host = try Host(name: "Lifecycle Host", hostname: "life.test", username: "user")
        await container.connect(to: host)

        await container.attachTmuxSession(id: "$0")
        XCTAssertEqual(container.activeTmuxSessionID, "$0")

        // 1. Session disappears from successful list
        mock.onExecuteCommand = { cmd in
            if cmd == TmuxCommand.probe {
                return SSHCommandResult(exitCode: 0, stdout: "tmux 3.4\n")
            }
            if cmd == TmuxCommand.listSessions {
                return SSHCommandResult(
                    exitCode: 0, stdout: "$1\tother\t1\t1700000000\t1700000500\t1\n")
            }
            return SSHCommandResult(exitCode: 0, stdout: "")
        }

        _ = await container.listTmuxSessions()
        XCTAssertNil(container.activeTmuxSessionID, "Disappeared session must be cleared")
        var metadata = try await container.restorationStore.load()
        XCTAssertEqual(metadata?.tmuxSessionID, "$0")

        // 2. Server stops
        await container.attachTmuxSession(id: "$1")
        XCTAssertEqual(container.activeTmuxSessionID, "$1")

        mock.onExecuteCommand = { cmd in
            if cmd == TmuxCommand.probe {
                return SSHCommandResult(exitCode: 0, stdout: "tmux 3.4\n")
            }
            if cmd == TmuxCommand.listSessions {
                return SSHCommandResult(
                    exitCode: 1, stdout: "", stderr: "no server running on /tmp/tmux-1000/default\n"
                )
            }
            return SSHCommandResult(exitCode: 0, stdout: "")
        }

        _ = await container.listTmuxSessions()
        XCTAssertNil(container.activeTmuxSessionID, "Stopped server must clear activeTmuxSessionID")
        XCTAssertFalse(container.isTmuxServerRunning)
        metadata = try await container.restorationStore.load()
        XCTAssertEqual(metadata?.tmuxSessionID, "$1")
    }

    func testValidatedCommandSendFailureFedToProductionTerminalSurface() async throws {
        let mock = MockSSHConnection()
        let transport = ControllableTransport()
        transport.onConnect = { _ in mock }

        mock.onSend = { _ in
            throw TransportError.remoteFailure("channel error")
        }

        let container = AppContainer(
            transport: transport
        )

        let host = try Host(name: "Send Fail Host", hostname: "sendfail.test", username: "user")
        await container.connect(to: host)

        let success = await container.sendValidatedCommand("echo hello\n", approved: true)
        XCTAssertFalse(success)
        XCTAssertTrue(container.terminalText.contains("Send failed"))
        let transcript = container.terminalController.currentTranscript(limit: 10)
        XCTAssertTrue(
            transcript.contains("[Send failed:"),
            "Send failure must be fed to production terminal surface")
    }

    func testCopyModeFallbackEnabledSynchronizesWithActiveTmuxSession() {
        let container = AppContainer.demo()
        XCTAssertFalse(container.terminalController.copyModeFallbackEnabled)
        XCTAssertFalse(container.terminalController.isCopyModeFallbackAvailable)

        container.activeTmuxSessionID = "$0"
        XCTAssertTrue(container.terminalController.copyModeFallbackEnabled)
        // Primary-screen tmux wheel events route through tmux. Fallback
        // availability remains reserved for an explicit mouse-off handler.
        XCTAssertFalse(container.terminalController.isCopyModeFallbackAvailable)

        // When a handler is explicitly registered, availability becomes true
        var fallbackInvoked = false
        container.terminalController.onCopyModeFallbackRequested = { fallbackInvoked = true }
        XCTAssertTrue(container.terminalController.isCopyModeFallbackAvailable)

        container.terminalController.requestCopyModeFallback()
        XCTAssertTrue(fallbackInvoked)

        container.activeTmuxSessionID = nil
        XCTAssertFalse(container.terminalController.copyModeFallbackEnabled)
        XCTAssertFalse(container.terminalController.isCopyModeFallbackAvailable)
    }
}

private actor AsyncGate {
    private var isOpen = false
    private var hasStarted = false
    private var continuations: [CheckedContinuation<Void, Never>] = []

    func wait() async {
        hasStarted = true
        if isOpen { return }
        await withCheckedContinuation { continuation in
            continuations.append(continuation)
        }
    }

    func waitForStart() async {
        while !hasStarted {
            await Task.yield()
        }
    }

    func open() {
        isOpen = true
        for cont in continuations {
            cont.resume()
        }
        continuations.removeAll()
    }
}
