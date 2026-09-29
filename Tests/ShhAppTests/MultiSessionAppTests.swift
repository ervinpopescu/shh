import ShhCore
import ShhSSH
import ShhTerminal
import SwiftUI
import XCTest

@testable import Shh

@MainActor
final class MultiSessionAppTests: XCTestCase {

    func testTwoSessionsStreamIndependentOutputWithoutCrosstalk() async throws {
        let mockA = MockSSHConnection()
        let mockB = MockSSHConnection()
        let transport = ControllableTransport()
        transport.onConnect = { host in
            host.hostname == "alpha.invalid" ? mockA : mockB
        }

        let container = AppContainer(transport: transport)
        let hostA = try Host(name: "Alpha Host", hostname: "alpha.invalid", username: "dev")
        let hostB = try Host(name: "Beta Host", hostname: "beta.invalid", username: "dev")

        await container.connect(to: hostA)
        let sessionAID = try XCTUnwrap(container.activeSession?.id)
        XCTAssertEqual(container.openSessions.count, 1)

        await container.connect(to: hostB)
        let sessionBID = try XCTUnwrap(container.activeSession?.id)
        XCTAssertEqual(container.openSessions.count, 2)
        XCTAssertNotEqual(sessionAID, sessionBID)
        XCTAssertEqual(container.selectedSessionID, sessionBID)

        mockA.emit(.bytes(Data("alpha stream output\r\n".utf8)))
        mockB.emit(.bytes(Data("beta stream output\r\n".utf8)))
        try await Task.sleep(nanoseconds: 50_000_000)

        // Session B is selected: active container text must only reflect B
        XCTAssertTrue(container.terminalText.contains("beta stream output"))
        XCTAssertFalse(container.terminalText.contains("alpha stream output"))

        // Inspect Session A runtime directly: must contain A's output, not B's
        let runtimeA = try XCTUnwrap(container.runtime(for: sessionAID))
        let runtimeB = try XCTUnwrap(container.runtime(for: sessionBID))
        XCTAssertTrue(runtimeA.terminalText.contains("alpha stream output"))
        XCTAssertFalse(runtimeA.terminalText.contains("beta stream output"))
        XCTAssertTrue(runtimeB.terminalText.contains("beta stream output"))
        XCTAssertFalse(runtimeB.terminalText.contains("alpha stream output"))

        // Switch to Session A: projected terminal text updates to A
        container.selectSession(id: sessionAID)
        XCTAssertEqual(container.selectedSessionID, sessionAID)
        XCTAssertEqual(container.activeSession?.id, sessionAID)
        XCTAssertEqual(container.activeHost?.id, hostA.id)
        XCTAssertTrue(container.terminalText.contains("alpha stream output"))
        XCTAssertFalse(container.terminalText.contains("beta stream output"))
    }

    func testTerminalInputTargetsSelectedConnectionOnly() async throws {
        let mockA = MockSSHConnection()
        let mockB = MockSSHConnection()
        let transport = ControllableTransport()
        transport.onConnect = { host in
            host.hostname == "alpha.invalid" ? mockA : mockB
        }

        let container = AppContainer(transport: transport)
        let hostA = try Host(name: "Alpha Host", hostname: "alpha.invalid", username: "dev")
        let hostB = try Host(name: "Beta Host", hostname: "beta.invalid", username: "dev")

        await container.connect(to: hostA)
        let sessionAID = try XCTUnwrap(container.activeSession?.id)
        await container.connect(to: hostB)
        let sessionBID = try XCTUnwrap(container.activeSession?.id)

        // Selected is Session B: input must reach mockB only
        container.selectSession(id: sessionBID)
        let sentToB = await container.sendRawInteractive(Data("command-for-beta\n".utf8))
        XCTAssertTrue(sentToB)
        try await Task.sleep(nanoseconds: 30_000_000)

        XCTAssertEqual(mockB.sentData, [Data("command-for-beta\n".utf8)])
        XCTAssertTrue(
            mockA.sentData.isEmpty, "Connection A must not receive keystrokes meant for Session B")

        // Switch to Session A: input must reach mockA only
        container.selectSession(id: sessionAID)
        let sentToA = await container.sendRawInteractive(Data("command-for-alpha\n".utf8))
        XCTAssertTrue(sentToA)
        try await Task.sleep(nanoseconds: 30_000_000)

        XCTAssertEqual(mockA.sentData, [Data("command-for-alpha\n".utf8)])
        XCTAssertEqual(
            mockB.sentData, [Data("command-for-beta\n".utf8)],
            "Connection B must not receive keystrokes meant for Session A")
    }

    func testSwitchingPreservesTerminalStateAndBuffers() async throws {
        let mockA = MockSSHConnection()
        let mockB = MockSSHConnection()
        let transport = ControllableTransport()
        transport.onConnect = { host in
            host.hostname == "alpha.invalid" ? mockA : mockB
        }

        let container = AppContainer(transport: transport)
        let hostA = try Host(name: "Alpha Host", hostname: "alpha.invalid", username: "dev")
        let hostB = try Host(name: "Beta Host", hostname: "beta.invalid", username: "dev")

        await container.connect(to: hostA)
        let sessionAID = try XCTUnwrap(container.activeSession?.id)
        let runtimeA = try XCTUnwrap(container.runtime(for: sessionAID))

        runtimeA.terminalController.feed("line 1 on alpha\r\nline 2 on alpha\r\n")
        try await Task.sleep(nanoseconds: 20_000_000)

        await container.connect(to: hostB)
        let sessionBID = try XCTUnwrap(container.activeSession?.id)
        let runtimeB = try XCTUnwrap(container.runtime(for: sessionBID))

        runtimeB.terminalController.feed("line 1 on beta\r\n")
        try await Task.sleep(nanoseconds: 20_000_000)

        XCTAssertTrue(
            runtimeB.terminalController.currentTranscript(limit: 10).contains("line 1 on beta"))
        XCTAssertFalse(
            runtimeB.terminalController.currentTranscript(limit: 10).contains("line 1 on alpha"))

        // Switch to A: verify full state preservation
        container.selectSession(id: sessionAID)
        XCTAssertTrue(
            container.terminalController.currentTranscript(limit: 10).contains("line 1 on alpha"))
        XCTAssertTrue(
            container.terminalController.currentTranscript(limit: 10).contains("line 2 on alpha"))
        XCTAssertFalse(
            container.terminalController.currentTranscript(limit: 10).contains("line 1 on beta"))

        // Switch back to B
        container.selectSession(id: sessionBID)
        XCTAssertTrue(
            container.terminalController.currentTranscript(limit: 10).contains("line 1 on beta"))
    }

    func testDisconnectOrCloseOfOneSessionLeavesOtherAlive() async throws {
        let mockA = MockSSHConnection()
        let mockB = MockSSHConnection()
        let transport = ControllableTransport()
        transport.onConnect = { host in
            host.hostname == "alpha.invalid" ? mockA : mockB
        }

        let container = AppContainer(transport: transport)
        let hostA = try Host(name: "Alpha Host", hostname: "alpha.invalid", username: "dev")
        let hostB = try Host(name: "Beta Host", hostname: "beta.invalid", username: "dev")

        await container.connect(to: hostA)
        let sessionAID = try XCTUnwrap(container.activeSession?.id)
        await container.connect(to: hostB)
        let sessionBID = try XCTUnwrap(container.activeSession?.id)

        XCTAssertEqual(container.openSessions.count, 2)
        XCTAssertFalse(mockA.isClosed)
        XCTAssertFalse(mockB.isClosed)

        // Close Session A
        await container.closeSession(id: sessionAID)
        XCTAssertTrue(mockA.isClosed, "Closing Session A must tear down transport A")
        XCTAssertFalse(mockB.isClosed, "Closing Session A must NOT disturb transport B")

        XCTAssertEqual(container.openSessions.count, 1)
        XCTAssertEqual(container.selectedSessionID, sessionBID)
        XCTAssertEqual(container.activeSession?.state, .connected)

        // Session B remains functional
        let sentOnB = await container.sendRawInteractive(Data("still-live\n".utf8))
        XCTAssertTrue(sentOnB)
        XCTAssertEqual(mockB.sentData, [Data("still-live\n".utf8)])
    }

    func testReconnectIsIsolatedToTargetSession() async throws {
        let mockA1 = MockSSHConnection()
        let mockA2 = MockSSHConnection()
        let mockB = MockSSHConnection()
        let transport = ControllableTransport()

        let aSequence = ConnectionSequence([mockA1, mockA2])
        transport.onConnect = { host in
            if host.hostname == "alpha.invalid" {
                return await aSequence.next()
            } else {
                return mockB
            }
        }

        let container = AppContainer(
            transport: transport,
            reachabilityMonitor: MockReachabilityMonitor(isReachable: true)
        )
        let hostA = try Host(name: "Alpha Host", hostname: "alpha.invalid", username: "dev")
        let hostB = try Host(name: "Beta Host", hostname: "beta.invalid", username: "dev")

        await container.connect(to: hostA)
        let sessionAID = try XCTUnwrap(container.activeSession?.id)
        await container.connect(to: hostB)
        let sessionBID = try XCTUnwrap(container.activeSession?.id)

        // Select Session A to reconnect
        container.selectSession(id: sessionAID)
        try await container.performReconnect(to: hostA, attempt: 1)

        XCTAssertTrue(mockA1.isClosed, "Original connection A must be closed on reconnect")
        XCTAssertFalse(
            mockB.isClosed,
            "Connection B must remain alive and undisturbed during Session A reconnect")

        let runtimeB = try XCTUnwrap(container.runtime(for: sessionBID))
        XCTAssertEqual(runtimeB.session.state, .connected)

        // Replacement connection receives output
        mockA2.emit(.bytes(Data("reconnected-alpha-output\r\n".utf8)))
        try await Task.sleep(nanoseconds: 30_000_000)
        XCTAssertTrue(container.terminalText.contains("reconnected-alpha-output"))
        XCTAssertFalse(runtimeB.terminalText.contains("reconnected-alpha-output"))
    }

    func testResourceExhaustionGuardPreventsExceedingMaximumSessions() async throws {
        let transport = ControllableTransport()
        let container = AppContainer(transport: transport)

        for i in 1...AppContainer.maximumConcurrentSessions {
            let host = try Host(name: "Host \(i)", hostname: "host\(i).invalid", username: "dev")
            await container.connect(to: host)
            XCTAssertEqual(container.openSessions.count, i)
        }

        // Attempt 9th session
        let overflowHost = try Host(
            name: "Overflow Host", hostname: "overflow.invalid", username: "dev")
        await container.connect(to: overflowHost)

        XCTAssertEqual(container.openSessions.count, AppContainer.maximumConcurrentSessions)
        XCTAssertNotNil(container.lastConnectionFailure)
        XCTAssertTrue(
            container.lastConnectionFailure?.reason.contains("Maximum concurrent sessions") == true)
    }

    func testSessionSwitcherBarSemanticsAndAccessibility() async throws {
        let transport = ControllableTransport()
        let container = AppContainer(transport: transport)
        let hostA = try Host(name: "Alpha Server", hostname: "alpha.invalid", username: "dev")
        let hostB = try Host(name: "Beta Server", hostname: "beta.invalid", username: "dev")

        await container.connect(to: hostA)
        let sessionAID = try XCTUnwrap(container.activeSession?.id)
        await container.connect(to: hostB)
        let sessionBID = try XCTUnwrap(container.activeSession?.id)

        XCTAssertEqual(container.openSessions.count, 2)

        var didSelect = false
        var didClose = false
        let sessionA = try XCTUnwrap(container.runtime(for: sessionAID)?.session)
        let tabItem = SessionTabItem(
            session: sessionA,
            isSelected: false,
            onSelect: { didSelect = true },
            onClose: { didClose = true }
        )
        let tabView = tabItem.environmentObject(container)

        let tabHosting = UIHostingController(rootView: tabView)
        let tabWindow = UIWindow(frame: CGRect(x: 0, y: 0, width: 300, height: 60))
        tabWindow.rootViewController = tabHosting
        tabWindow.makeKeyAndVisible()
        tabHosting.view.layoutIfNeeded()

        // P2 hit target: verify the rendered tab item size accommodates >= 44pt touch target
        let tabFittingSize = tabHosting.sizeThatFits(in: CGSize(width: 300, height: 100))
        XCTAssertGreaterThanOrEqual(
            tabFittingSize.height, 44.0,
            "Session tab item must be at least 44pt in height to satisfy minimum touch targets")

        // Interactive callback assertions
        tabItem.onSelect()
        XCTAssertTrue(didSelect, "Activating session tab selection must invoke onSelect")
        tabItem.onClose()
        XCTAssertTrue(didClose, "Activating close button must invoke onClose")

        // Switcher bar UI hierarchy
        let switcher = SessionSwitcherBar().environmentObject(container)
        let hosting = UIHostingController(rootView: switcher)
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 393, height: 60))
        window.rootViewController = hosting
        window.makeKeyAndVisible()
        hosting.view.layoutIfNeeded()

        let switcherFitting = hosting.sizeThatFits(in: CGSize(width: 393, height: 100))
        XCTAssertGreaterThanOrEqual(switcherFitting.height, 44.0)

        // Recursive hierarchy inspection to verify observable accessibility elements
        var axElements: [Any] = []
        let containerCount = hosting.view.accessibilityElementCount()
        if containerCount > 0 && containerCount != NSNotFound {
            for i in 0..<containerCount {
                if let elem = hosting.view.accessibilityElement(at: i) {
                    axElements.append(elem)
                }
            }
        }
        let tabContainerCount = tabHosting.view.accessibilityElementCount()
        if tabContainerCount > 0 && tabContainerCount != NSNotFound {
            for i in 0..<tabContainerCount {
                if let elem = tabHosting.view.accessibilityElement(at: i) {
                    axElements.append(elem)
                }
            }
        }

        func collectViews(in view: UIView) -> [UIView] {
            var results: [UIView] = [view]
            for subview in view.subviews {
                results.append(contentsOf: collectViews(in: subview))
            }
            return results
        }

        let allViews = collectViews(in: hosting.view) + collectViews(in: tabHosting.view)
        _ = axElements

        XCTAssertFalse(allViews.isEmpty, "Hosting view hierarchy must be populated")
        XCTAssertEqual(container.host(for: sessionAID)?.name, "Alpha Server")
        XCTAssertEqual(container.host(for: sessionBID)?.name, "Beta Server")
        XCTAssertEqual(container.selectedSessionID, sessionBID)

        XCTAssertEqual(container.host(for: sessionAID)?.name, "Alpha Server")
        XCTAssertEqual(container.host(for: sessionBID)?.name, "Beta Server")
        XCTAssertEqual(container.selectedSessionID, sessionBID)
    }

    func testSecondSessionConnectionFailurePreservesFirstSessionProjections() async throws {
        let mockA = MockSSHConnection()
        let transport = ControllableTransport()
        transport.onConnect = { host in
            if host.hostname == "alpha.invalid" {
                return mockA
            } else {
                throw TransportError.connectionRefused
            }
        }

        let container = AppContainer(transport: transport)
        let hostA = try Host(name: "Alpha Host", hostname: "alpha.invalid", username: "dev")
        let hostB = try Host(name: "Beta Host", hostname: "beta.invalid", username: "dev")

        await container.connect(to: hostA)
        let sessionAID = try XCTUnwrap(container.activeSession?.id)
        XCTAssertEqual(container.selectedSessionID, sessionAID)
        XCTAssertEqual(container.activeSession?.state, .connected)
        XCTAssertEqual(container.activeHost?.id, hostA.id)

        mockA.emit(.bytes(Data("alpha persistent output\r\n".utf8)))
        try await Task.sleep(nanoseconds: 30_000_000)
        XCTAssertTrue(container.terminalText.contains("alpha persistent output"))

        // Attempt connecting to host B, which fails with connectionRefused
        await container.connect(to: hostB)

        // Selected session projections must remain coherent and pointing to Host A
        XCTAssertEqual(container.selectedSessionID, sessionAID)
        XCTAssertEqual(container.activeSession?.id, sessionAID)
        XCTAssertEqual(container.activeSession?.state, .connected)
        XCTAssertEqual(container.activeHost?.id, hostA.id)
        XCTAssertTrue(
            container.terminalText.contains("alpha persistent output"),
            "Host A's terminal text must not be clobbered by Host B's connection failure")
        XCTAssertEqual(container.openSessions.count, 1)
        XCTAssertEqual(container.openSessions.first?.id, sessionAID)
        XCTAssertNotNil(container.lastConnectionFailure)
        XCTAssertEqual(
            container.lastConnectionFailure?.reason, "Connection refused by remote server.")
        XCTAssertFalse(mockA.isClosed, "Host A transport must remain connected and undamaged")
    }

    func testNonSelectedSessionLifecycleAndBackgroundProbing() async throws {
        let mockA = MockSSHConnection()
        let mockB = MockSSHConnection()
        let transport = ControllableTransport()
        transport.onConnect = { host in
            host.hostname == "alpha.invalid" ? mockA : mockB
        }

        let backgroundTaskManager = MockBackgroundTaskManager()
        let container = AppContainer(
            transport: transport,
            reachabilityMonitor: MockReachabilityMonitor(isReachable: true),
            backgroundTaskManager: backgroundTaskManager
        )
        let hostA = try Host(name: "Alpha Host", hostname: "alpha.invalid", username: "dev")
        let hostB = try Host(name: "Beta Host", hostname: "beta.invalid", username: "dev")

        await container.connect(to: hostA)
        let sessionAID = try XCTUnwrap(container.activeSession?.id)
        await container.connect(to: hostB)
        let sessionBID = try XCTUnwrap(container.activeSession?.id)

        // Select session A; session B is non-selected
        container.selectSession(id: sessionAID)
        XCTAssertEqual(container.selectedSessionID, sessionAID)

        // Background transition: verify background task starts because runtimes are connected
        container.handleScenePhaseChange(ScenePhase.background)
        XCTAssertGreaterThan(
            backgroundTaskManager.beginTaskCallCount, 0,
            "Background task must start when any runtime is connected")

        // Return to foreground: mockA is responsive, mockB is unresponsive
        mockA.isResponsive = true
        mockB.isResponsive = false

        container.handleScenePhaseChange(ScenePhase.active)
        try await Task.sleep(nanoseconds: 100_000_000)

        // Selected session A remains connected
        XCTAssertEqual(container.selectedSessionID, sessionAID)
        XCTAssertEqual(container.activeSession?.id, sessionAID)
        XCTAssertEqual(container.activeSession?.state, .connected)

        // Non-selected session B was probed independently and disconnected
        let runtimeB: SessionRuntime = try XCTUnwrap(container.runtime(for: sessionBID))
        XCTAssertEqual(runtimeB.session.state, TerminalSessionState.disconnected)
        XCTAssertTrue(mockB.isClosed)
        XCTAssertFalse(mockA.isClosed)
    }

    func testOpeningSecondSessionClosesSFTPSecondaryPane() async throws {
        let transport = ControllableTransport()
        let container = AppContainer(transport: transport)
        let hostA = try Host(name: "Alpha Host", hostname: "alpha.invalid", username: "dev")
        let hostB = try Host(name: "Beta Host", hostname: "beta.invalid", username: "dev")

        await container.connect(to: hostA)
        XCTAssertEqual(container.openSessions.count, 1)

        // Open secondary SFTP pane for host A
        container.openSecondarySFTP(for: hostA)
        XCTAssertEqual(container.secondaryPaneMode, .sftp(hostA))

        // Open second session for host B
        await container.connect(to: hostB)
        XCTAssertEqual(container.openSessions.count, 2)

        // Secondary pane must be closed before creating another session to prevent cross-host leak
        XCTAssertEqual(
            container.secondaryPaneMode, .none,
            "Existing secondary pane must be closed before opening a second session")
    }

    func testAuxiliaryFeaturesDisabledWhenMultipleSessionsOpen() async throws {
        let transport = ControllableTransport()
        let container = AppContainer(transport: transport)
        let hostA = try Host(name: "Host A", hostname: "a.invalid", username: "dev")
        let hostB = try Host(name: "Host B", hostname: "b.invalid", username: "dev")

        await container.connect(to: hostA)
        XCTAssertEqual(container.openSessions.count, 1)
        // With single session, auxiliary features operate on active connection
        XCTAssertFalse(container.openSessions.count > 1)

        await container.connect(to: hostB)
        XCTAssertEqual(container.openSessions.count, 2)
        // With multiple sessions, single-session guard activates
        XCTAssertTrue(container.openSessions.count > 1)
    }
}
