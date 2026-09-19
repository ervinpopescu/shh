import SwiftUI
import XCTest
@testable import Shh
import ShhCore
import ShhTerminal

private actor LifecycleGate {
    private var isOpen = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func wait() async {
        if isOpen { return }
        await withCheckedContinuation { continuation in
            waiters.append(continuation)
        }
    }

    func open() {
        isOpen = true
        waiters.forEach { $0.resume() }
        waiters.removeAll()
    }
}

@MainActor
final class RestorationAndReachabilityTests: XCTestCase {

    // MARK: - Persistence & No Secrets Stored

    func testUserDefaultsSessionRestorationStoreRoundTrip() async throws {
        let suiteName = "com.ervinpopescu.shh.tests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let store = UserDefaultsSessionRestorationStore(userDefaults: defaults, storageKey: "test.restoration")

        let initial = try await store.load()
        XCTAssertNil(initial, "Empty store must return nil")

        let hostID = UUID()
        let sessionID = UUID()
        let timestamp = Date(timeIntervalSince1970: 1700000000)

        let metadata = SessionRestorationMetadata(
            hostID: hostID,
            sessionID: sessionID,
            tmuxSessionID: "$3",
            timestamp: timestamp
        )

        try await store.save(metadata)

        let loaded = try await store.load()
        let unwrapped = try XCTUnwrap(loaded)
        XCTAssertEqual(unwrapped.hostID, hostID)
        XCTAssertEqual(unwrapped.sessionID, sessionID)
        XCTAssertEqual(unwrapped.tmuxSessionID, "$3")
        XCTAssertEqual(unwrapped.timestamp, timestamp)

        try await store.clear()
        let afterClear = try await store.load()
        XCTAssertNil(afterClear, "Cleared store must return nil")
    }

    func testUserDefaultsStoresNoSecretsOrTerminalBytes() async throws {
        let suiteName = "com.ervinpopescu.shh.tests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let store = UserDefaultsSessionRestorationStore(userDefaults: defaults, storageKey: "test.restoration")

        let hostID = UUID()
        let sessionID = UUID()
        let timestamp = Date()

        let metadata = SessionRestorationMetadata(
            hostID: hostID,
            sessionID: sessionID,
            tmuxSessionID: "$0",
            timestamp: timestamp
        )

        try await store.save(metadata)

        // Inspect raw stored dictionary representation in UserDefaults
        let dictionary = defaults.dictionaryRepresentation()
        let rawData = defaults.data(forKey: "test.restoration")
        let dataString = try XCTUnwrap(rawData.flatMap { String(data: $0, encoding: .utf8) })

        // 1. Verify expected keys are present
        XCTAssertTrue(dataString.contains("hostID"))
        XCTAssertTrue(dataString.contains("sessionID"))
        XCTAssertTrue(dataString.contains("tmuxSessionID"))

        // 2. Strict verification: ensure NO secrets, terminal bytes, or host keys are in UserDefaults
        let forbiddenPatterns = [
            "password",
            "privateKey",
            "BEGIN OPENSSH PRIVATE KEY",
            "BEGIN RSA PRIVATE KEY",
            "BEGIN EC PRIVATE KEY",
            "fingerprint",
            "SHA256:",
            "terminalText",
            "scrollback",
            "transcriptText",
            "grid"
        ]

        for pattern in forbiddenPatterns {
            XCTAssertFalse(
                dataString.localizedCaseInsensitiveContains(pattern),
                "Restoration store must never persist '\(pattern)' in UserDefaults"
            )
        }

        // Verify across entire UserDefaults dictionary
        for (key, value) in dictionary where key.contains("test.restoration") {
            let stringValue = String(describing: value)
            for pattern in forbiddenPatterns {
                XCTAssertFalse(
                    stringValue.localizedCaseInsensitiveContains(pattern),
                    "UserDefaults representation must not contain '\(pattern)'"
                )
            }
        }
    }

    // MARK: - Auto-Attach Tmux on Connect

    func testAppContainerAutoAttachTmuxOnConnect() async throws {
        let mockConnection = MockSSHConnection()
        let transport = ControllableTransport()
        transport.onConnect = { (_: Host) async throws -> any SSHConnection in mockConnection }

        let container = AppContainer(
            transport: transport,
            reachabilityMonitor: MockReachabilityMonitor(isReachable: true),
            reconnectCoordinator: ReconnectCoordinator(clock: { _ in }, jitter: ReconnectCoordinator.zeroJitter)
        )

        let host = try Host(
            name: "TmuxHost",
            hostname: "tmux.invalid",
            username: "dev",
            defaultTmuxSession: "$1",
            autoAttachTmux: true
        )

        await container.connect(to: host)
        XCTAssertEqual(container.activeSession?.state, .connected)

        // Verify auto-attach command was sent through connection
        let sentStrings = mockConnection.sentData.compactMap { String(data: $0, encoding: .utf8) }
        let hasAttach = sentStrings.contains { $0.contains("attach-session") }
        XCTAssertFalse(hasAttach, "Legacy host defaults must not trigger automatic attachment")
    }

    func testAppContainerAutoAttachTmuxCreatesNewSessionIfNameProvided() async throws {
        let mockConnection = MockSSHConnection()
        let transport = ControllableTransport()
        transport.onConnect = { (_: Host) async throws -> any SSHConnection in mockConnection }

        let container = AppContainer(
            transport: transport,
            reachabilityMonitor: MockReachabilityMonitor(isReachable: true),
            reconnectCoordinator: ReconnectCoordinator(clock: { _ in }, jitter: ReconnectCoordinator.zeroJitter)
        )

        let host = try Host(
            name: "TmuxCreateHost",
            hostname: "tmux.invalid",
            username: "dev",
            defaultTmuxSession: "my-work",
            autoAttachTmux: true
        )

        await container.connect(to: host)
        XCTAssertEqual(container.activeSession?.state, .connected)

        let sentStrings = mockConnection.sentData.compactMap { String(data: $0, encoding: .utf8) }
        let hasNewSession = sentStrings.contains { $0.contains("new-session") }
        XCTAssertFalse(hasNewSession, "Automatic restoration must never create a missing session")
    }

    func testLastUsedSessionTakesPrecedenceOverLegacyHostDefault() async throws {
        let hostID = UUID()
        let mockConnection = MockSSHConnection()
        mockConnection.onExecuteCommand = { command in
            if command.contains("has-session") { return SSHCommandResult(exitCode: 0, stdout: "") }
            return SSHCommandResult(exitCode: 0, stdout: "")
        }
        let transport = ControllableTransport()
        transport.onConnect = { _ in mockConnection }
        let store = InMemorySessionRestorationStore(initial: SessionRestorationMetadata(
            hostID: hostID,
            tmuxSessionID: "$7"
        ))
        let container = AppContainer(
            transport: transport,
            restorationStore: store,
            reachabilityMonitor: MockReachabilityMonitor(isReachable: true),
            reconnectCoordinator: ReconnectCoordinator(clock: { _ in }, jitter: ReconnectCoordinator.zeroJitter)
        )
        let host = try Host(
            id: hostID,
            name: "Precedence Host",
            hostname: "precedence.invalid",
            username: "dev",
            defaultTmuxSession: "$1",
            autoAttachTmux: true
        )

        await container.connect(to: host)
        let sentStrings = mockConnection.sentData.compactMap { String(data: $0, encoding: .utf8) }
        XCTAssertTrue(sentStrings.contains { $0.contains("attach-session") && $0.contains("'$7'") })
        XCTAssertFalse(sentStrings.contains { $0.contains("'$1'") })
    }

    // MARK: - Network Reachability & Foreground Triggers

    func testAppContainerNetworkReachabilityTriggerReconnect() async throws {
        let mockConnection1 = MockSSHConnection()
        let mockConnection2 = MockSSHConnection()
        let transport = ControllableTransport()
        var connectCount = 0
        transport.onConnect = { (_: Host) async throws -> any SSHConnection in
            connectCount += 1
            return connectCount == 1 ? mockConnection1 : mockConnection2
        }

        let reachability = MockReachabilityMonitor(isReachable: true)
        let coordinator = ReconnectCoordinator(
            clock: { _ in },
            jitter: ReconnectCoordinator.zeroJitter
        )

        let container = AppContainer(
            transport: transport,
            reachabilityMonitor: reachability,
            reconnectCoordinator: coordinator
        )

        let host = try Host(name: "NetHost", hostname: "net.invalid", username: "dev")

        // 1. Initial connect
        await container.connect(to: host)
        XCTAssertEqual(container.activeSession?.state, .connected)
        XCTAssertEqual(connectCount, 1)

        // 2. Mid-session network drop
        mockConnection1.emit(TerminalEvent.error(TransportError.networkUnavailable))
        try await Task.sleep(nanoseconds: 30_000_000)

        // Network is offline
        reachability.setReachable(false)
        try await Task.sleep(nanoseconds: 20_000_000)

        // 3. Network comes back online!
        reachability.setReachable(true)

        // Allow reconnect attempt to complete
        try await Task.sleep(nanoseconds: 80_000_000)

        XCTAssertEqual(container.activeSession?.state, .connected, "Network recovery must trigger reconnect and succeed")
        XCTAssertEqual(connectCount, 2, "A second connection attempt must have been performed")
    }

    func testAppContainerInterfaceTransitionTriggersReconnect() async throws {
        let firstConnection = MockSSHConnection()
        let secondConnection = MockSSHConnection()
        let transport = ControllableTransport()
        var connectCount = 0
        transport.onConnect = { _ in
            connectCount += 1
            return connectCount == 1 ? firstConnection : secondConnection
        }

        let reachability = MockReachabilityMonitor(isReachable: true, initialInterface: .wifi)
        let container = AppContainer(
            transport: transport,
            reachabilityMonitor: reachability,
            reconnectCoordinator: ReconnectCoordinator(clock: { _ in }, jitter: ReconnectCoordinator.zeroJitter)
        )
        let host = try Host(name: "RoamingHost", hostname: "roaming.invalid", username: "dev")

        await container.connect(to: host)
        XCTAssertEqual(container.activeSession?.state, .connected)

        reachability.transitionInterface(to: .cellular)
        try await Task.sleep(nanoseconds: 100_000_000)

        XCTAssertEqual(connectCount, 2, "An interface transition must recover the SSH session")
        XCTAssertEqual(container.activeSession?.state, .connected)
        XCTAssertTrue(firstConnection.isClosed)
        await container.disconnect()
    }

    func testAppContainerScenePhaseForegroundTriggerReconnect() async throws {
        let mockConnection1 = MockSSHConnection()
        let mockConnection2 = MockSSHConnection()
        let transport = ControllableTransport()
        var connectCount = 0
        transport.onConnect = { (_: Host) async throws -> any SSHConnection in
            connectCount += 1
            return connectCount == 1 ? mockConnection1 : mockConnection2
        }

        let reachability = MockReachabilityMonitor(isReachable: true)
        let coordinator = ReconnectCoordinator(
            clock: { _ in },
            jitter: ReconnectCoordinator.zeroJitter
        )

        let container = AppContainer(
            transport: transport,
            reachabilityMonitor: reachability,
            reconnectCoordinator: coordinator
        )

        let host = try Host(name: "ForeHost", hostname: "fore.invalid", username: "dev")

        // 1. Connect
        await container.connect(to: host)
        XCTAssertEqual(container.activeSession?.state, .connected)
        XCTAssertEqual(connectCount, 1)

        // 2. Connection drops unexpectedly
        mockConnection1.emit(TerminalEvent.closed)
        try await Task.sleep(nanoseconds: 30_000_000)

        // 3. App enters foreground (.active)
        container.handleScenePhaseChange(ScenePhase.active)

        // Allow reconnect attempt to complete
        try await Task.sleep(nanoseconds: 80_000_000)

        XCTAssertEqual(container.activeSession?.state, .connected, "Foregrounding scene phase must trigger reconnect and succeed")
        XCTAssertEqual(connectCount, 2)
    }

    func testAppContainerExplicitDisconnectDoesNotAutoReconnect() async throws {
        let mockConnection = MockSSHConnection()
        let transport = ControllableTransport()
        var connectCount = 0
        transport.onConnect = { (_: Host) async throws -> any SSHConnection in
            connectCount += 1
            return mockConnection
        }

        let reachability = MockReachabilityMonitor(isReachable: true)
        let coordinator = ReconnectCoordinator(
            clock: { _ in },
            jitter: ReconnectCoordinator.zeroJitter
        )

        let container = AppContainer(
            transport: transport,
            reachabilityMonitor: reachability,
            reconnectCoordinator: coordinator
        )

        let host = try Host(name: "ExplicitHost", hostname: "explicit.invalid", username: "dev")

        await container.connect(to: host)
        XCTAssertEqual(container.activeSession?.state, .connected)
        XCTAssertEqual(connectCount, 1)

        // User explicitly disconnects
        await container.disconnect()
        XCTAssertEqual(container.activeSession?.state, .disconnected)
        XCTAssertTrue(container.isExplicitDisconnect)

        // Network changes and the scene cycles through inactive/background/active.
        // Explicit disconnect must suppress every lifecycle trigger.
        reachability.setReachable(false)
        reachability.setReachable(true)
        container.handleScenePhaseChange(ScenePhase.inactive)
        container.handleScenePhaseChange(ScenePhase.background)
        container.handleScenePhaseChange(ScenePhase.active)
        try await Task.sleep(nanoseconds: 50_000_000)

        // No new connection attempt must have occurred
        XCTAssertEqual(connectCount, 1, "Explicit disconnect must prevent automatic reconnect triggers")
        XCTAssertEqual(container.activeSession?.state, .disconnected)
    }

    func testAppContainerBackgroundForegroundReconnectsAndReattachesSafeTarget() async throws {
        let firstConnection = MockSSHConnection()
        let secondConnection = MockSSHConnection()
        let transport = ControllableTransport()
        var connectCount = 0
        transport.onConnect = { _ in
            connectCount += 1
            return connectCount == 1 ? firstConnection : secondConnection
        }
        let store = InMemorySessionRestorationStore()
        let container = AppContainer(
            transport: transport,
            restorationStore: store,
            reachabilityMonitor: MockReachabilityMonitor(isReachable: true),
            reconnectCoordinator: ReconnectCoordinator(clock: { _ in }, jitter: ReconnectCoordinator.zeroJitter)
        )
        let host = try Host(
            name: "Lifecycle Host",
            hostname: "lifecycle.invalid",
            username: "dev"
        )

        await container.connect(to: host)
        XCTAssertEqual(container.activeSession?.state, .connected)
        let attachSuccess = await container.attachTmuxSession(id: "$0")
        XCTAssertTrue(attachSuccess)
        XCTAssertEqual(container.activeTmuxSessionID, "$0")

        // 1. Enter background: connection must NOT be proactively disconnected
        container.handleScenePhaseChange(.background)
        try await Task.sleep(nanoseconds: 50_000_000)

        XCTAssertEqual(container.activeSession?.state, .connected, "Session must stay connected during background grace period")
        XCTAssertFalse(firstConnection.isClosed, "Live transport must not be proactively closed on backgrounding")
        let storedMetadata = try await store.load()
        let metadata = try XCTUnwrap(storedMetadata)
        XCTAssertEqual(metadata.hostID, host.id)
        XCTAssertEqual(metadata.tmuxSessionID, "$0")

        // 2. Simulate connection severed by OS during deep sleep
        firstConnection.isResponsive = false

        // 3. Return to foreground: responsiveness probe detects severed connection and restores target
        container.handleScenePhaseChange(.active)
        try await Task.sleep(nanoseconds: 100_000_000)

        XCTAssertEqual(connectCount, 2)
        XCTAssertEqual(container.activeSession?.state, .connected)
        XCTAssertTrue(
            secondConnection.sentData.compactMap { String(data: $0, encoding: .utf8) }
                .contains { $0.contains("attach-session") && $0.contains("'$0'") }
        )
    }

    // MARK: - Background Grace Period, Expiration & Responsiveness Lifecycle Tests

    func testAppContainerRepeatedInactiveBackgroundForegroundTransitionsPreserveSession() async throws {
        let connection = MockSSHConnection()
        let transport = ControllableTransport()
        var connectCount = 0
        transport.onConnect = { _ in
            connectCount += 1
            return connection
        }
        let container = AppContainer(
            transport: transport,
            reachabilityMonitor: MockReachabilityMonitor(isReachable: true),
            reconnectCoordinator: ReconnectCoordinator(clock: { _ in }, jitter: ReconnectCoordinator.zeroJitter)
        )
        let host = try Host(name: "Repeated Lifecycle Host", hostname: "repeated.invalid", username: "dev")

        await container.connect(to: host)
        XCTAssertEqual(container.activeSession?.state, .connected)

        for _ in 0..<3 {
            container.handleScenePhaseChange(.inactive)
            container.handleScenePhaseChange(.background)
            XCTAssertEqual(container.activeSession?.state, .connected)
            XCTAssertFalse(connection.isClosed)

            container.handleScenePhaseChange(.active)
            for _ in 0..<8 { await Task.yield() }
            XCTAssertEqual(container.activeSession?.state, .connected)
            XCTAssertEqual(connectCount, 1, "A responsive session must not reconnect across repeated transitions")
        }

        await container.disconnect()
    }

    func testAppContainerInFlightConnectIsInvalidatedByBackgroundAndRecoveredOnForeground() async throws {
        let connectStarted = LifecycleGate()
        let connectGate = LifecycleGate()
        let initialConnection = MockSSHConnection()
        let recoveredConnection = MockSSHConnection()
        let recoveryExpectation = expectation(description: "foreground recovery connects")
        let transport = ControllableTransport()
        var connectCount = 0
        transport.onConnect = { _ in
            connectCount += 1
            if connectCount == 1 {
                await connectStarted.open()
                await connectGate.wait()
                return initialConnection
            }
            return recoveredConnection
        }

        let coordinator = ReconnectCoordinator(
            clock: { _ in },
            jitter: ReconnectCoordinator.zeroJitter,
            onStateChange: { state in
                if state == .connected {
                    recoveryExpectation.fulfill()
                }
            }
        )
        let container = AppContainer(
            transport: transport,
            reachabilityMonitor: MockReachabilityMonitor(isReachable: true),
            reconnectCoordinator: coordinator
        )
        let host = try Host(name: "In Flight Lifecycle Host", hostname: "in-flight.invalid", username: "dev")
        let initialConnectTask = Task { @MainActor in
            await container.connect(to: host)
        }

        await connectStarted.wait()
        container.handleScenePhaseChange(.inactive)
        container.handleScenePhaseChange(.background)
        XCTAssertEqual(container.activeSession?.state, .disconnected)

        await connectGate.open()
        await initialConnectTask.value
        XCTAssertEqual(container.activeSession?.state, .disconnected)
        XCTAssertTrue(initialConnection.isClosed, "A connection completing after backgrounding must be discarded")

        container.handleScenePhaseChange(.active)
        await fulfillment(of: [recoveryExpectation], timeout: 2.0)
        XCTAssertEqual(container.activeSession?.state, .connected)
        XCTAssertEqual(connectCount, 2)

        await container.disconnect()
    }

    func testAppContainerBackgroundTaskAcquisitionAndInstantForegroundResume() async throws {
        let mockConnection = MockSSHConnection()
        let transport = ControllableTransport()
        var connectCount = 0
        transport.onConnect = { _ in
            connectCount += 1
            return mockConnection
        }
        let bgManager = MockBackgroundTaskManager()
        let store = InMemorySessionRestorationStore()
        let container = AppContainer(
            transport: transport,
            restorationStore: store,
            reachabilityMonitor: MockReachabilityMonitor(isReachable: true),
            reconnectCoordinator: ReconnectCoordinator(clock: { _ in }, jitter: ReconnectCoordinator.zeroJitter),
            backgroundTaskManager: bgManager
        )
        let host = try Host(name: "GraceHost", hostname: "grace.invalid", username: "dev")

        // 1. Connect
        await container.connect(to: host)
        XCTAssertEqual(container.activeSession?.state, .connected)
        XCTAssertEqual(connectCount, 1)

        // 2. Enter background
        container.handleScenePhaseChange(.background)
        try await Task.sleep(nanoseconds: 50_000_000)

        // Verify background task acquired with exact name
        XCTAssertEqual(bgManager.beginTaskCallCount, 1)
        XCTAssertEqual(bgManager.registeredNames.first, "com.ervinpopescu.shh.keepalive")
        XCTAssertEqual(bgManager.activeIdentifiers.count, 1)
        XCTAssertEqual(container.activeSession?.state, .connected, "Active session must survive without disconnect")
        XCTAssertFalse(mockConnection.isClosed, "Connection must remain open in background")

        // 3. Return to foreground while responsive before expiration: INSTANT resume, 0 delay, NO reconnect
        container.handleScenePhaseChange(.active)
        try await Task.sleep(nanoseconds: 50_000_000)

        XCTAssertEqual(bgManager.endTaskCallCount, 1, "Background task must be ended upon returning to active")
        XCTAssertEqual(connectCount, 1, "No reconnect cycle must occur when returning to foreground with responsive socket")
        XCTAssertEqual(container.activeSession?.state, .connected)
    }

    func testAppContainerBackgroundTaskExpirationDoesNotProactivelyCloseSocket() async throws {
        let mockConnection = MockSSHConnection()
        let transport = ControllableTransport()
        var connectCount = 0
        transport.onConnect = { _ in
            connectCount += 1
            return mockConnection
        }
        let bgManager = MockBackgroundTaskManager()
        let store = InMemorySessionRestorationStore()
        let container = AppContainer(
            transport: transport,
            restorationStore: store,
            reachabilityMonitor: MockReachabilityMonitor(isReachable: true),
            backgroundTaskManager: bgManager
        )
        let host = try Host(name: "ExpHost", hostname: "exp.invalid", username: "dev")

        await container.connect(to: host)
        container.handleScenePhaseChange(.background)
        try await Task.sleep(nanoseconds: 50_000_000)

        XCTAssertEqual(bgManager.beginTaskCallCount, 1)

        // Trigger expiration handler (OS ending finite grace period)
        bgManager.triggerAllExpirations()
        try await Task.sleep(nanoseconds: 50_000_000)

        // Expiration MUST end background task
        XCTAssertEqual(bgManager.endTaskCallCount, 1, "Expiration must immediately end the background task")
        // But MUST NOT proactively close the socket!
        XCTAssertFalse(mockConnection.isClosed, "Socket must not be proactively closed upon background task expiration")

        // Restoration metadata must be saved
        let metadata = try await store.load()
        XCTAssertEqual(metadata?.hostID, host.id)

        // If the socket survived in OS kernel when coming to foreground:
        container.handleScenePhaseChange(.active)
        try await Task.sleep(nanoseconds: 50_000_000)

        XCTAssertEqual(connectCount, 1, "If socket survived in OS, session resumes without reconnect")
        XCTAssertEqual(container.activeSession?.state, .connected)
    }

    func testAppContainerForegroundReconnectsWhenConnectionSeveredDuringSleep() async throws {
        let firstConnection = MockSSHConnection()
        let secondConnection = MockSSHConnection()
        let transport = ControllableTransport()
        var connectCount = 0
        transport.onConnect = { _ in
            connectCount += 1
            return connectCount == 1 ? firstConnection : secondConnection
        }
        let bgManager = MockBackgroundTaskManager()
        let container = AppContainer(
            transport: transport,
            reachabilityMonitor: MockReachabilityMonitor(isReachable: true),
            reconnectCoordinator: ReconnectCoordinator(clock: { _ in }, jitter: ReconnectCoordinator.zeroJitter),
            backgroundTaskManager: bgManager
        )
        let host = try Host(name: "SeverHost", hostname: "sever.invalid", username: "dev")

        await container.connect(to: host)
        container.handleScenePhaseChange(.background)
        try await Task.sleep(nanoseconds: 50_000_000)

        // Simulate OS/NAT severing the connection during deep sleep
        firstConnection.isResponsive = false

        container.handleScenePhaseChange(.active)
        try await Task.sleep(nanoseconds: 100_000_000)

        // Probing detected dead connection -> triggers reconnect
        XCTAssertEqual(connectCount, 2, "Severed connection must trigger reconnect on active transition")
        XCTAssertEqual(container.activeSession?.state, .connected)
    }

    func testBackgroundDuringReconnectIsInvalidatedAndForegroundStartsOneFreshRecovery() async throws {
        let reconnectGate = LifecycleGate()
        let firstConnection = MockSSHConnection()
        let staleConnection = MockSSHConnection()
        let recoveredConnection = MockSSHConnection()
        let transport = ControllableTransport()
        var connectCount = 0
        transport.onConnect = { _ in
            connectCount += 1
            switch connectCount {
            case 1:
                return firstConnection
            case 2:
                await reconnectGate.wait()
                return staleConnection
            default:
                return recoveredConnection
            }
        }

        let container = AppContainer(
            transport: transport,
            reachabilityMonitor: MockReachabilityMonitor(isReachable: true),
            reconnectCoordinator: ReconnectCoordinator(clock: { _ in }, jitter: ReconnectCoordinator.zeroJitter)
        )
        let host = try Host(name: "Reconnect Lifecycle Host", hostname: "reconnect-lifecycle.invalid", username: "dev")

        await container.connect(to: host)
        firstConnection.emit(.closed)
        try await Task.sleep(nanoseconds: 50_000_000)

        container.handleScenePhaseChange(.background)
        XCTAssertEqual(container.activeSession?.state, .disconnected)
        container.handleScenePhaseChange(.active)
        await reconnectGate.open()
        try await Task.sleep(nanoseconds: 100_000_000)

        XCTAssertEqual(connectCount, 3, "Foreground must replace the cancelled reconnect exactly once")
        XCTAssertTrue(staleConnection.isClosed, "The stale pre-background connection must be closed")
        XCTAssertEqual(container.activeSession?.state, .connected)
        XCTAssertFalse(container.reconnectState.isReconnecting)
    }

    func testNetworkUnavailableDefersReconnectWithoutStormAndExplicitDisconnectWins() async throws {
        let firstConnection = MockSSHConnection()
        let recoveredConnection = MockSSHConnection()
        let transport = ControllableTransport()
        var connectCount = 0
        transport.onConnect = { _ in
            connectCount += 1
            return connectCount == 1 ? firstConnection : recoveredConnection
        }
        let reachability = MockReachabilityMonitor(isReachable: true)
        let container = AppContainer(
            transport: transport,
            reachabilityMonitor: reachability,
            reconnectCoordinator: ReconnectCoordinator(clock: { _ in }, jitter: ReconnectCoordinator.zeroJitter)
        )
        let host = try Host(name: "Offline Recovery Host", hostname: "offline-recovery.invalid", username: "dev")

        await container.connect(to: host)
        reachability.setReachable(false)
        firstConnection.emit(.error(.networkUnavailable))
        try await Task.sleep(nanoseconds: 50_000_000)

        XCTAssertEqual(connectCount, 1, "Offline transport events must not spin reconnect attempts")
        XCTAssertEqual(container.reconnectState, .failed(reason: "Network unavailable."))
        XCTAssertEqual(container.activeSession?.state, .disconnected)

        reachability.setReachable(true)
        try await Task.sleep(nanoseconds: 100_000_000)
        XCTAssertEqual(connectCount, 2)
        XCTAssertEqual(container.activeSession?.state, .connected)

        await container.disconnect()
        reachability.setReachable(false)
        reachability.setReachable(true)
        container.handleScenePhaseChange(.active)
        try await Task.sleep(nanoseconds: 50_000_000)
        XCTAssertEqual(connectCount, 2, "Explicit disconnect must block later reachability recovery")
        XCTAssertEqual(container.activeSession?.state, .disconnected)
    }

    func testAppContainerBackgroundWithoutActiveSessionDoesNotAcquireBackgroundTask() async throws {
        let bgManager = MockBackgroundTaskManager()
        let container = AppContainer(
            reachabilityMonitor: MockReachabilityMonitor(isReachable: true),
            backgroundTaskManager: bgManager
        )

        // No active connected session
        container.handleScenePhaseChange(.background)
        try await Task.sleep(nanoseconds: 30_000_000)

        XCTAssertEqual(bgManager.beginTaskCallCount, 0, "No background task should be acquired without an active session")
    }

    func testAppContainerExplicitDisconnectEndsActiveBackgroundTask() async throws {
        let mockConnection = MockSSHConnection()
        let transport = ControllableTransport()
        transport.onConnect = { _ in mockConnection }
        let bgManager = MockBackgroundTaskManager()
        let container = AppContainer(
            transport: transport,
            reachabilityMonitor: MockReachabilityMonitor(isReachable: true),
            backgroundTaskManager: bgManager
        )
        let host = try Host(name: "DiscHost", hostname: "disc.invalid", username: "dev")

        await container.connect(to: host)
        container.handleScenePhaseChange(.background)
        try await Task.sleep(nanoseconds: 30_000_000)

        XCTAssertEqual(bgManager.beginTaskCallCount, 1)

        await container.disconnect()
        XCTAssertEqual(bgManager.endTaskCallCount, 1, "Explicit disconnect must end active background task")
    }

    func testStaleForegroundReconnectCannotRestoreAfterExplicitDisconnect() async throws {
        let gate = LifecycleGate()
        let firstConnection = MockSSHConnection()
        let lateConnection = MockSSHConnection()
        let transport = ControllableTransport()
        var connectCount = 0
        transport.onConnect = { _ in
            connectCount += 1
            if connectCount == 1 { return firstConnection }
            await gate.wait()
            return lateConnection
        }
        let container = AppContainer(
            transport: transport,
            reachabilityMonitor: MockReachabilityMonitor(isReachable: true),
            reconnectCoordinator: ReconnectCoordinator(clock: { _ in }, jitter: ReconnectCoordinator.zeroJitter)
        )
        let host = try Host(name: "Stale Host", hostname: "stale.invalid", username: "dev")

        await container.connect(to: host)
        firstConnection.isResponsive = false
        container.handleScenePhaseChange(.background)
        container.handleScenePhaseChange(.active)
        try await Task.sleep(nanoseconds: 50_000_000)
        await container.disconnect()
        await gate.open()
        try await Task.sleep(nanoseconds: 50_000_000)

        XCTAssertEqual(connectCount, 2)
        XCTAssertTrue(lateConnection.isClosed)
        XCTAssertEqual(container.activeSession?.state, .disconnected)
    }

    func testAppContainerScenePhaseBackgroundSavesRestorationMetadata() async throws {
        let suiteName = "com.ervinpopescu.shh.tests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let store = UserDefaultsSessionRestorationStore(userDefaults: defaults, storageKey: "test.bg.restoration")
        let mockConnection = MockSSHConnection()
        let transport = ControllableTransport()
        transport.onConnect = { (_: Host) async throws -> any SSHConnection in mockConnection }

        let container = AppContainer(
            transport: transport,
            restorationStore: store,
            reachabilityMonitor: MockReachabilityMonitor(isReachable: true)
        )

        let host = try Host(
            name: "BgHost",
            hostname: "bg.invalid",
            username: "dev"
        )

        await container.connect(to: host)
        XCTAssertEqual(container.activeSession?.state, .connected)
        let attachSuccess = await container.attachTmuxSession(id: "$0")
        XCTAssertTrue(attachSuccess)

        container.handleScenePhaseChange(ScenePhase.background)
        try await Task.sleep(nanoseconds: 50_000_000)

        let metadata = try await store.load()
        let loaded = try XCTUnwrap(metadata)
        XCTAssertEqual(loaded.hostID, host.id)
        XCTAssertEqual(loaded.tmuxSessionID, "$0")
    }
}
