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

        // Network changes and scene enters active
        reachability.setReachable(false)
        reachability.setReachable(true)
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

        container.handleScenePhaseChange(.background)
        try await Task.sleep(nanoseconds: 50_000_000)

        XCTAssertEqual(container.activeSession?.state, .disconnected)
        XCTAssertTrue(firstConnection.isClosed)
        let storedMetadata = try await store.load()
        let metadata = try XCTUnwrap(storedMetadata)
        XCTAssertEqual(metadata.hostID, host.id)
        XCTAssertEqual(metadata.tmuxSessionID, "$0")

        container.handleScenePhaseChange(.active)
        try await Task.sleep(nanoseconds: 100_000_000)

        XCTAssertEqual(connectCount, 2)
        XCTAssertEqual(container.activeSession?.state, .connected)
        XCTAssertTrue(
            secondConnection.sentData.compactMap { String(data: $0, encoding: .utf8) }
                .contains { $0.contains("attach-session") && $0.contains("'$0'") }
        )
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
