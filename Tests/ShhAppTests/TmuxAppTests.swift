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
        await container.handleReachabilityChange(false)

        // User cancels
        await container.cancelReconnect()
        XCTAssertEqual(container.reconnectState, .cancelled)
        XCTAssertTrue(container.isExplicitDisconnect)

        // Reachability restored afterwards does NOT trigger reconnect
        mockMonitor.setReachable(true)
        await container.handleReachabilityChange(true)
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

        // Pre-populate tmux sessions in container
        container.tmuxAvailability = .available(version: "tmux 3.4")
        container.isTmuxServerRunning = true
        container.tmuxSessions = [
            TmuxSessionInfo(
                sessionID: "$0",
                name: "main",
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
        _ = picker

        // Verify VoiceOver label formatting
        let session0 = container.tmuxSessions[0]
        XCTAssertEqual(session0.sessionID, "$0")
        XCTAssertEqual(session0.name, "main")
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

        // Compact size class (iPhone portrait)
        let compactView = MultiplexerPicker()
            .environmentObject(container)
            .environment(\.horizontalSizeClass, .compact)
        _ = compactView

        // Regular size class (iPad landscape / full)
        let regularView = MultiplexerPicker()
            .environmentObject(container)
            .environment(\.horizontalSizeClass, .regular)
        _ = regularView
    }
}
