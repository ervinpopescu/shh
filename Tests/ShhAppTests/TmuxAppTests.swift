import SwiftUI
import XCTest
@testable import Shh
import ShhCore
import ShhTerminal

@MainActor
final class TmuxAppTests: XCTestCase {

    // MARK: - 1. Probe Tmux

    func testTmuxProbeSuccess() async throws {
        let mock = MockSSHConnection()
        let transport = ControllableTransport()
        transport.onConnect = { _ in mock }

        let container = AppContainer(
            transport: transport,
            reachabilityMonitor: MockReachabilityMonitor(isReachable: true),
            reconnectCoordinator: ReconnectCoordinator(clock: { _ in }, jitter: ReconnectCoordinator.zeroJitter)
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

    func testTmuxProbeFailureNoTmux() async throws {
        let mock = MockSSHConnection()
        let transport = ControllableTransport()
        transport.onConnect = { _ in mock }

        let container = AppContainer(
            transport: transport,
            reachabilityMonitor: MockReachabilityMonitor(isReachable: true),
            reconnectCoordinator: ReconnectCoordinator(clock: { _ in }, jitter: ReconnectCoordinator.zeroJitter)
        )

        let host = try Host(name: "No Tmux Host", hostname: "notmux.test", username: "user")
        await container.connect(to: host)

        mock.onExecuteCommand = { cmd in
            if cmd == TmuxCommand.probe {
                return SSHCommandResult(exitCode: 127, stdout: "", stderr: "bash: tmux: command not found\n")
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
            reconnectCoordinator: ReconnectCoordinator(clock: { _ in }, jitter: ReconnectCoordinator.zeroJitter)
        )

        let host = try Host(name: "List Host", hostname: "list.test", username: "user")
        await container.connect(to: host)

        mock.onExecuteCommand = { cmd in
            if cmd == TmuxCommand.probe {
                return SSHCommandResult(exitCode: 0, stdout: "tmux 3.4\n")
            }
            if cmd == TmuxCommand.listSessions {
                let out = "$0\twork\t3\t1700000000\t1700000500\t1\n$1\tbackground\t1\t1700000100\t1700000200\t0\n"
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
            reconnectCoordinator: ReconnectCoordinator(clock: { _ in }, jitter: ReconnectCoordinator.zeroJitter)
        )

        let host = try Host(name: "No Server Host", hostname: "noserver.test", username: "user")
        await container.connect(to: host)

        mock.onExecuteCommand = { cmd in
            if cmd == TmuxCommand.listSessions {
                return SSHCommandResult(exitCode: 1, stdout: "", stderr: "no server running on /tmp/tmux-501/default\n")
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
            reconnectCoordinator: ReconnectCoordinator(clock: { _ in }, jitter: ReconnectCoordinator.zeroJitter)
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
            reconnectCoordinator: ReconnectCoordinator(clock: { _ in }, jitter: ReconnectCoordinator.zeroJitter)
        )

        let host = try Host(name: "Attach Host", hostname: "attach.test", username: "user")
        await container.connect(to: host)

        let attachResult = await container.attachTmuxSession(id: "$2")
        XCTAssertTrue(attachResult)
        XCTAssertEqual(container.activeTmuxSessionID, "$2")
        XCTAssertNil(container.tmuxError)

        // Check command reached active connection PTY
        let sentStrings = mock.sentData.compactMap { String(data: $0, encoding: .utf8) }
        let hasAttachCmd = sentStrings.contains { $0.contains("env -u TMUX tmux attach-session -d -t '$2'") }
        XCTAssertTrue(hasAttachCmd, "PTY must receive exact attach command for $2")

        // Check restoration metadata persisted
        let loaded = try await store.load()
        XCTAssertNotNil(loaded)
        XCTAssertEqual(loaded?.tmuxSessionID, "$2")
        XCTAssertEqual(loaded?.hostID, host.id)
    }

    func testAttachRejectsNonSessionIDNames() async throws {
        let mock = MockSSHConnection()
        let transport = ControllableTransport()
        transport.onConnect = { _ in mock }

        let container = AppContainer(
            transport: transport,
            reachabilityMonitor: MockReachabilityMonitor(isReachable: true),
            reconnectCoordinator: ReconnectCoordinator(clock: { _ in }, jitter: ReconnectCoordinator.zeroJitter)
        )

        let host = try Host(name: "Reject Host", hostname: "reject.test", username: "user")
        await container.connect(to: host)

        let initialSentCount = mock.sentData.count

        // Attaching by name like "main" must be rejected - attach is strictly by session ID ($id)
        let attachResult = await container.attachTmuxSession(id: "main")
        XCTAssertFalse(attachResult)
        XCTAssertNil(container.activeTmuxSessionID)
        XCTAssertNotNil(container.tmuxError)
        XCTAssertTrue(container.tmuxError?.contains("Existing tmux sessions must attach by session ID") ?? false)

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
                return SSHCommandResult(exitCode: 0, stdout: "$1\tworkspace\t1\t1700000000\t1700000000\t1\n")
            }
            return SSHCommandResult(exitCode: 0, stdout: "")
        }
        let store = InMemorySessionRestorationStore()

        let container = AppContainer(
            transport: transport,
            restorationStore: store,
            reachabilityMonitor: MockReachabilityMonitor(isReachable: true),
            reconnectCoordinator: ReconnectCoordinator(clock: { _ in }, jitter: ReconnectCoordinator.zeroJitter)
        )

        let host = try Host(name: "Create Host", hostname: "create.test", username: "user")
        await container.connect(to: host)

        let createResult = await container.createTmuxSession(name: "workspace")
        XCTAssertTrue(createResult)
        XCTAssertEqual(container.activeTmuxSessionID, "workspace")
        XCTAssertNil(container.tmuxError)

        let sentStrings = mock.sentData.compactMap { String(data: $0, encoding: .utf8) }
        let hasNewSessionCmd = sentStrings.contains { $0.contains("tmux new-session -A -D -s 'workspace'") }
        XCTAssertTrue(hasNewSessionCmd, "PTY must receive exact new-session command for 'workspace'")

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
            reconnectCoordinator: ReconnectCoordinator(clock: { _ in }, jitter: ReconnectCoordinator.zeroJitter)
        )

        let host = try Host(name: "Invalid Host", hostname: "invalid.test", username: "user")
        await container.connect(to: host)

        let invalidNames = [
            "",
            "   ",
            "foo:bar",
            "foo.bar",
            "foo\u{07}bar",
            String(repeating: "a", count: 129)
        ]

        let initialSentCount = mock.sentData.count

        for name in invalidNames {
            let res = await container.createTmuxSession(name: name)
            XCTAssertFalse(res, "Name '\(name)' must be rejected")
            XCTAssertNotNil(container.tmuxError)
        }

        XCTAssertEqual(mock.sentData.count, initialSentCount, "No commands sent to PTY for invalid session names")
    }

    // MARK: - 5. Zero Terminal Pollution During Discovery

    func testNoTerminalPollutionDuringDiscovery() async throws {
        let mock = MockSSHConnection()
        let transport = ControllableTransport()
        transport.onConnect = { _ in mock }

        let container = AppContainer(
            transport: transport,
            reachabilityMonitor: MockReachabilityMonitor(isReachable: true),
            reconnectCoordinator: ReconnectCoordinator(clock: { _ in }, jitter: ReconnectCoordinator.zeroJitter)
        )

        let host = try Host(name: "Clean Host", hostname: "clean.test", username: "user")
        await container.connect(to: host)

        let sentCountBeforeDiscovery = mock.sentData.count

        await container.refreshTmuxState()
        _ = await container.probeTmux()
        _ = await container.listTmuxSessions()

        // Verify sentData to PTY remained completely untouched during probe & list
        XCTAssertEqual(mock.sentData.count, sentCountBeforeDiscovery, "Discovery operations must never write to the active PTY")
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
            reconnectCoordinator: ReconnectCoordinator(clock: { _ in }, jitter: ReconnectCoordinator.zeroJitter)
        )

        let host = try Host(name: "Safe Host", hostname: "safe.test", username: "user")
        await container.connect(to: host)

        let sentBefore = mock.sentData.count
        let blockedResult = await container.sendValidatedCommand("tmux kill-server\n", approved: true)
        XCTAssertFalse(blockedResult, "kill-server must be blocked by sendValidatedCommand")
        XCTAssertEqual(mock.sentData.count, sentBefore, "PTY must never receive kill-server")
    }

    // MARK: - 7. Missing Session Handling on Restoration

    func testRememberedRestorationMissingSessionHandling() async throws {
        let mock = MockSSHConnection()
        let transport = ControllableTransport()
        transport.onConnect = { _ in mock }

        let container = AppContainer(
            transport: transport,
            reachabilityMonitor: MockReachabilityMonitor(isReachable: true),
            reconnectCoordinator: ReconnectCoordinator(clock: { _ in }, jitter: ReconnectCoordinator.zeroJitter)
        )

        // Mock has-session to return failure (missing session)
        mock.onExecuteCommand = { cmd in
            if cmd.contains("has-session") && cmd.contains("$99") {
                return SSHCommandResult(exitCode: 1, stdout: "", stderr: "can't find session: $99\n")
            }
            return SSHCommandResult(exitCode: 0, stdout: "")
        }

        let host = try Host(
            name: "Missing Session Host",
            hostname: "missing.test",
            username: "user",
            defaultTmuxSession: "$99",
            autoAttachTmux: true
        )

        await container.connect(to: host)

        // Check explicit error message populated
        XCTAssertNotNil(container.tmuxError)
        XCTAssertTrue(container.tmuxError?.contains("Remembered tmux session $99 no longer exists") ?? false)

        // Verify attach was NOT sent to PTY
        let sentStrings = mock.sentData.compactMap { String(data: $0, encoding: .utf8) }
        let hasAttach = sentStrings.contains { $0.contains("attach-session") && $0.contains("'$99'") }
        XCTAssertFalse(hasAttach, "Missing session must not send failing attach command to PTY")

        // Finding 3: activeTmuxSessionID cleared and restoration metadata persisted with nil tmuxSessionID
        XCTAssertNil(container.activeTmuxSessionID)
        let savedMetadata = try await container.restorationStore.load()
        XCTAssertNil(savedMetadata?.tmuxSessionID)
    }

    // MARK: - 8. Reconnect Cancellation & Disconnect Races

    func testReconnectCancellationStopsCoordinator() async throws {
        let transport = ControllableTransport()
        let mockMonitor = MockReachabilityMonitor(isReachable: false)
        let coordinator = ReconnectCoordinator(clock: { _ in }, jitter: ReconnectCoordinator.zeroJitter)

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
            reconnectCoordinator: ReconnectCoordinator(clock: { _ in }, jitter: ReconnectCoordinator.zeroJitter)
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

        let demoChallenge = HostKeyChallenge(hostname: "demo.local", port: 22, algorithm: "ssh-ed25519", fingerprint: "SHA256:demo-fingerprint")
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
        XCTAssertEqual(sessions[0].name, "default")

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
        let demoChallenge = HostKeyChallenge(hostname: "demo.local", port: 22, algorithm: "ssh-ed25519", fingerprint: "SHA256:demo-fingerprint")
        await container.trustStore.save(demoChallenge)

        let host = try Host(name: "UI Host", hostname: "demo.local", username: "dev")
        await container.connect(to: host)

        let longSessionName = "a-very-long-tmux-session-name-that-tests-truncation-behavior-across-compact-and-regular-size-classes"
        container.tmuxAvailability = .available(version: "tmux 3.4")
        container.isTmuxServerRunning = true
        container.activeTmuxSessionID = "$0"
        container.tmuxSessions = [
            TmuxSessionInfo(
                sessionID: "$0",
                name: longSessionName,
                windowsCount: 2,
                createdAt: Date(timeIntervalSince1970: 1700000000),
                lastActivityAt: Date(),
                attachedClients: 1
            ),
            TmuxSessionInfo(
                sessionID: "$1",
                name: "dev",
                windowsCount: 1,
                createdAt: Date(timeIntervalSince1970: 1700000100),
                lastActivityAt: Date(),
                attachedClients: 0
            )
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
            reconnectCoordinator: ReconnectCoordinator(clock: { _ in }, jitter: ReconnectCoordinator.zeroJitter)
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
                return SSHCommandResult(exitCode: 0, stdout: "$0\tmain\t1\t1700000000\t1700000500\t1\n")
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
            reconnectCoordinator: ReconnectCoordinator(clock: { _ in }, jitter: ReconnectCoordinator.zeroJitter)
        )

        let gate = AsyncGate()
        mock.onExecuteCommand = { cmd in
            if cmd.contains("has-session") {
                await gate.wait()
                return SSHCommandResult(exitCode: 1, stdout: "", stderr: "no session")
            }
            return SSHCommandResult(exitCode: 0, stdout: "")
        }

        let host = try Host(name: "Slow Host", hostname: "slow.test", username: "user", defaultTmuxSession: "$99", autoAttachTmux: true)

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
            reconnectCoordinator: ReconnectCoordinator(clock: { _ in }, jitter: ReconnectCoordinator.zeroJitter)
        )

        let host = try Host(name: "Create Host", hostname: "create.test", username: "user")
        await container.connect(to: host)

        var sessionsOutput = "$0\tother\t1\t1700000000\t1700000500\t0\n"
        mock.onExecuteCommand = { cmd in
            if cmd == TmuxCommand.probe {
                return SSHCommandResult(exitCode: 0, stdout: "tmux 3.4\n")
            }
            if cmd == TmuxCommand.listSessions {
                return SSHCommandResult(exitCode: 0, stdout: sessionsOutput)
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
        sessionsOutput = "$0\tother\t1\t1700000000\t1700000500\t0\n$5\tproject-work\t1\t1700000000\t1700000500\t1\n"
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

        // Valid session name
        try await container.updateActiveHostPreferences(autoAttachTmux: true, defaultTmuxSession: "my-session")
        XCTAssertEqual(container.activeHost?.autoAttachTmux, true)
        XCTAssertEqual(container.activeHost?.defaultTmuxSession, "my-session")
        let reloadedHost = try await container.catalog.listHosts().first(where: { $0.id == host.id })
        XCTAssertEqual(reloadedHost?.defaultTmuxSession, "my-session")
        XCTAssertEqual(reloadedHost?.autoAttachTmux, true)

        // Valid session ID
        try await container.updateActiveHostPreferences(autoAttachTmux: true, defaultTmuxSession: "$3")
        XCTAssertEqual(container.activeHost?.defaultTmuxSession, "$3")

        // Invalid session name with colon
        do {
            try await container.updateActiveHostPreferences(autoAttachTmux: true, defaultTmuxSession: "invalid:name")
            XCTFail("Should throw for colon in session name")
        } catch {
            XCTAssertTrue(error is TmuxSessionNameError)
        }
        XCTAssertEqual(container.activeHost?.defaultTmuxSession, "$3", "Invalid preference must not mutate activeHost")

        // Invalid session ID format
        do {
            try await container.updateActiveHostPreferences(autoAttachTmux: true, defaultTmuxSession: "$notdigits")
            XCTFail("Should throw for invalid session ID")
        } catch {
            XCTAssertTrue(error is TmuxSessionIDError)
        }
        XCTAssertEqual(container.activeHost?.defaultTmuxSession, "$3", "Invalid session ID must not mutate activeHost")

        // Clearing default session with empty string
        try await container.updateActiveHostPreferences(autoAttachTmux: false, defaultTmuxSession: "   ")
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
            reconnectCoordinator: ReconnectCoordinator(clock: { _ in }, jitter: ReconnectCoordinator.zeroJitter)
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
            reconnectCoordinator: ReconnectCoordinator(clock: { _ in }, jitter: ReconnectCoordinator.zeroJitter)
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
                return SSHCommandResult(exitCode: 0, stdout: "$1\tother\t1\t1700000000\t1700000500\t1\n")
            }
            return SSHCommandResult(exitCode: 0, stdout: "")
        }

        _ = await container.listTmuxSessions()
        XCTAssertNil(container.activeTmuxSessionID, "Disappeared session must be cleared")
        var metadata = try await container.restorationStore.load()
        XCTAssertNil(metadata?.tmuxSessionID)

        // 2. Server stops
        await container.attachTmuxSession(id: "$1")
        XCTAssertEqual(container.activeTmuxSessionID, "$1")

        mock.onExecuteCommand = { cmd in
            if cmd == TmuxCommand.probe {
                return SSHCommandResult(exitCode: 0, stdout: "tmux 3.4\n")
            }
            if cmd == TmuxCommand.listSessions {
                return SSHCommandResult(exitCode: 1, stdout: "", stderr: "no server running on /tmp/tmux-1000/default\n")
            }
            return SSHCommandResult(exitCode: 0, stdout: "")
        }

        _ = await container.listTmuxSessions()
        XCTAssertNil(container.activeTmuxSessionID, "Stopped server must clear activeTmuxSessionID")
        XCTAssertFalse(container.isTmuxServerRunning)
        metadata = try await container.restorationStore.load()
        XCTAssertNil(metadata?.tmuxSessionID)
    }

    func testValidatedCommandSendFailureFedToProductionTerminalSurface() async throws {
        let mock = MockSSHConnection()
        let transport = ControllableTransport()
        transport.onConnect = { _ in mock }

        mock.onSend = { _ in
            throw TransportError.remoteFailure("channel error")
        }

        let container = AppContainer(
            transport: transport,
            useLegacyTerminalFallback: false
        )

        let host = try Host(name: "Send Fail Host", hostname: "sendfail.test", username: "user")
        await container.connect(to: host)

        let success = await container.sendValidatedCommand("echo hello\n", approved: true)
        XCTAssertFalse(success)
        XCTAssertTrue(container.terminalText.contains("Send failed"))
        let transcript = container.terminalController.currentTranscript(limit: 10)
        XCTAssertTrue(transcript.contains("[Send failed:"), "Send failure must be fed to production terminal surface")
    }
}

private actor AsyncGate {
    private var isOpen = false
    private var continuations: [CheckedContinuation<Void, Never>] = []

    func wait() async {
        if isOpen { return }
        await withCheckedContinuation { continuation in
            continuations.append(continuation)
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
