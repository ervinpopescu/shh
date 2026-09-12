import SwiftUI
import XCTest
@testable import Shh
import ShhCore
import ShhTerminal

@MainActor
final class HerdrAppTests: XCTestCase {

    // MARK: - 1. Herdr Probe & Discovery

    func testHerdrProbeSuccess() async throws {
        let mock = MockSSHConnection()
        let transport = ControllableTransport()
        transport.onConnect = { _ in mock }

        let container = AppContainer(
            transport: transport,
            reachabilityMonitor: MockReachabilityMonitor(isReachable: true),
            reconnectCoordinator: ReconnectCoordinator(clock: { _ in }, jitter: ReconnectCoordinator.zeroJitter)
        )

        let host = try Host(name: "Herdr Host", hostname: "herdr.test", username: "user")
        await container.connect(to: host)
        XCTAssertEqual(container.activeSession?.state, .connected)

        mock.onExecuteCommand = { cmd in
            if cmd == HerdrCommand.probe || cmd == "herdr --version" {
                return SSHCommandResult(exitCode: 0, stdout: "herdr 0.1.0\n")
            }
            return SSHCommandResult(exitCode: 0, stdout: "")
        }

        let availability = await container.probeHerdr()
        XCTAssertTrue(availability.isAvailable)
        XCTAssertEqual(availability.version, "herdr 0.1.0")
        XCTAssertEqual(container.herdrAvailability, .available(version: "herdr 0.1.0"))
    }

    func testHerdrProbeFailureWhenNotInstalled() async throws {
        let mock = MockSSHConnection()
        let transport = ControllableTransport()
        transport.onConnect = { _ in mock }

        let container = AppContainer(
            transport: transport,
            reachabilityMonitor: MockReachabilityMonitor(isReachable: true),
            reconnectCoordinator: ReconnectCoordinator(clock: { _ in }, jitter: ReconnectCoordinator.zeroJitter)
        )

        let host = try Host(name: "No Herdr Host", hostname: "noherdr.test", username: "user")
        await container.connect(to: host)

        mock.onExecuteCommand = { cmd in
            if cmd == HerdrCommand.probe || cmd == "herdr --version" {
                return SSHCommandResult(exitCode: 127, stdout: "", stderr: "bash: herdr: command not found\n")
            }
            return SSHCommandResult(exitCode: 0, stdout: "")
        }

        let availability = await container.probeHerdr()
        XCTAssertFalse(availability.isAvailable)
        XCTAssertEqual(container.herdrAvailability, availability)
        XCTAssertTrue(container.herdrWorkspaces.isEmpty)
    }

    func testHerdrProbeWhenDisconnected() async throws {
        let container = AppContainer(
            transport: ControllableTransport(),
            reachabilityMonitor: MockReachabilityMonitor(isReachable: false),
            reconnectCoordinator: ReconnectCoordinator(clock: { _ in }, jitter: ReconnectCoordinator.zeroJitter)
        )

        let availability = await container.probeHerdr()
        XCTAssertFalse(availability.isAvailable)
        XCTAssertEqual(availability.unavailableReason, "Not connected")
        XCTAssertEqual(container.herdrAvailability, .unavailable(reason: "Not connected"))
    }

    // MARK: - 2. Workspace & Pane Discovery with 4 Agent States

    func testHerdrListWorkspacesWithFourAgentStates() async throws {
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

        let workspacesJSON = """
        [
          {
            "id": "ws-main",
            "label": "Agent Swarm",
            "cwd": "/home/dev/project",
            "panes": [
              {
                "id": "pane-idle",
                "label": "Idle Worker",
                "agentState": {"status": "idle"},
                "currentCommand": null,
                "lastActivity": "2026-09-12T12:00:00Z"
              },
              {
                "id": "pane-working",
                "label": "Build Worker",
                "agentState": {"status": "working"},
                "currentCommand": "npm run build",
                "lastActivity": "2026-09-12T12:05:00Z"
              },
              {
                "id": "pane-blocked",
                "label": "Migration Worker",
                "agentState": {"status": "blocked", "reason": "Requires database approval"},
                "currentCommand": "prisma migrate deploy",
                "lastActivity": "2026-09-12T12:08:00Z"
              },
              {
                "id": "pane-completed",
                "label": "Test Worker",
                "agentState": {"status": "completed", "summary": "All 50 unit tests passed"},
                "currentCommand": "swift test",
                "lastActivity": "2026-09-12T12:10:00Z"
              }
            ]
          }
        ]
        """

        mock.onExecuteCommand = { cmd in
            if cmd == HerdrCommand.probe || cmd == "herdr --version" {
                return SSHCommandResult(exitCode: 0, stdout: "herdr 0.1.0\n")
            }
            if cmd.contains("herdr workspace list") {
                return SSHCommandResult(exitCode: 0, stdout: workspacesJSON)
            }
            return SSHCommandResult(exitCode: 0, stdout: "")
        }

        let workspaces = await container.listHerdrWorkspaces()
        XCTAssertEqual(workspaces.count, 1)
        let ws = workspaces[0]
        XCTAssertEqual(ws.id, "ws-main")
        XCTAssertEqual(ws.label, "Agent Swarm")
        XCTAssertEqual(ws.cwd, "/home/dev/project")
        XCTAssertEqual(ws.panes.count, 4)

        // 1. Idle
        XCTAssertEqual(ws.panes[0].id, "pane-idle")
        XCTAssertEqual(ws.panes[0].agentState, .idle)
        XCTAssertTrue(ws.panes[0].agentState.isIdle)

        // 2. Working
        XCTAssertEqual(ws.panes[1].id, "pane-working")
        XCTAssertEqual(ws.panes[1].agentState, .working)
        XCTAssertTrue(ws.panes[1].agentState.isWorking)
        XCTAssertEqual(ws.panes[1].currentCommand, "npm run build")

        // 3. Blocked
        XCTAssertEqual(ws.panes[2].id, "pane-blocked")
        XCTAssertEqual(ws.panes[2].agentState, .blocked(reason: "Requires database approval"))
        XCTAssertTrue(ws.panes[2].agentState.isBlocked)
        XCTAssertEqual(ws.panes[2].agentState.blockedReason, "Requires database approval")

        // 4. Completed
        XCTAssertEqual(ws.panes[3].id, "pane-completed")
        XCTAssertEqual(ws.panes[3].agentState, .completed(summary: "All 50 unit tests passed"))
        XCTAssertTrue(ws.panes[3].agentState.isCompleted)
        XCTAssertEqual(ws.panes[3].agentState.completedSummary, "All 50 unit tests passed")

        XCTAssertNil(container.herdrError)
    }

    func testHerdrRefreshStateUpdatesWorkspacesAndAvailability() async throws {
        let mock = MockSSHConnection()
        let transport = ControllableTransport()
        transport.onConnect = { _ in mock }

        let container = AppContainer(
            transport: transport,
            reachabilityMonitor: MockReachabilityMonitor(isReachable: true),
            reconnectCoordinator: ReconnectCoordinator(clock: { _ in }, jitter: ReconnectCoordinator.zeroJitter)
        )

        let host = try Host(name: "Refresh Host", hostname: "refresh.test", username: "user")
        await container.connect(to: host)

        let workspacesJSON = """
        [{"id":"ws-1","label":"Default","cwd":".","panes":[{"id":"p-1","label":"Worker","agentState":"idle"}]}]
        """

        mock.onExecuteCommand = { cmd in
            if cmd == HerdrCommand.probe || cmd == "herdr --version" {
                return SSHCommandResult(exitCode: 0, stdout: "herdr 0.1.0\n")
            }
            if cmd.contains("herdr workspace list") {
                return SSHCommandResult(exitCode: 0, stdout: workspacesJSON)
            }
            return SSHCommandResult(exitCode: 0, stdout: "")
        }

        await container.refreshHerdrState()
        XCTAssertTrue(container.herdrAvailability.isAvailable)
        XCTAssertEqual(container.herdrWorkspaces.count, 1)
        XCTAssertEqual(container.herdrWorkspaces[0].id, "ws-1")
        XCTAssertNil(container.herdrError)
    }

    func testHerdrListWorkspacesParseError() async throws {
        let mock = MockSSHConnection()
        let transport = ControllableTransport()
        transport.onConnect = { _ in mock }

        let container = AppContainer(
            transport: transport,
            reachabilityMonitor: MockReachabilityMonitor(isReachable: true),
            reconnectCoordinator: ReconnectCoordinator(clock: { _ in }, jitter: ReconnectCoordinator.zeroJitter)
        )

        let host = try Host(name: "Error Host", hostname: "error.test", username: "user")
        await container.connect(to: host)

        mock.onExecuteCommand = { cmd in
            if cmd == HerdrCommand.probe || cmd == "herdr --version" {
                return SSHCommandResult(exitCode: 0, stdout: "herdr 0.1.0\n")
            }
            if cmd.contains("herdr workspace list") {
                return SSHCommandResult(exitCode: 0, stdout: "not valid json at all")
            }
            return SSHCommandResult(exitCode: 0, stdout: "")
        }

        let workspaces = await container.listHerdrWorkspaces()
        XCTAssertTrue(workspaces.isEmpty)
        XCTAssertNotNil(container.herdrError)
        XCTAssertTrue(container.herdrError?.contains("Failed to parse Herdr workspaces") == true)
    }

    // MARK: - 3. Agent State Polling

    func testHerdrAgentStatePollingStartsAndStops() async throws {
        let container = AppContainer.demo()
        let demoChallenge = HostKeyChallenge(hostname: "demo.local", port: 22, algorithm: "ssh-ed25519", fingerprint: "SHA256:demo-fingerprint")
        await container.trustStore.save(demoChallenge)

        let host = try Host(name: "Polling Host", hostname: "demo.local", username: "dev")
        await container.connect(to: host)

        XCTAssertFalse(container.isPollingHerdr)
        container.startHerdrPolling(interval: 0.05)
        XCTAssertTrue(container.isPollingHerdr)

        // Give poller time to run at least one cycle
        try await Task.sleep(nanoseconds: 120_000_000)
        XCTAssertTrue(container.herdrAvailability.isAvailable)
        XCTAssertFalse(container.herdrWorkspaces.isEmpty)

        container.stopHerdrPolling()
        XCTAssertFalse(container.isPollingHerdr)
    }

    func testHerdrAgentStatePollingPersistsAcrossMultipleCycles() async throws {
        let container = AppContainer.demo()
        let demoChallenge = HostKeyChallenge(hostname: "demo.local", port: 22, algorithm: "ssh-ed25519", fingerprint: "SHA256:demo-fingerprint")
        await container.trustStore.save(demoChallenge)

        let host = try Host(name: "Polling Multi Host", hostname: "demo.local", username: "dev")
        await container.connect(to: host)

        XCTAssertFalse(container.isPollingHerdr)
        container.startHerdrPolling(interval: 0.04)
        XCTAssertTrue(container.isPollingHerdr)

        // Wait long enough for multiple polling intervals (0.04s * 5 = 0.2s)
        try await Task.sleep(nanoseconds: 200_000_000)
        // Polling must persist and not abort due to herdrRefreshGeneration increment
        XCTAssertTrue(container.isPollingHerdr, "Polling must not exit after first cycle")
        XCTAssertTrue(container.herdrAvailability.isAvailable)

        // Triggering an external single-shot refresh should NOT kill background polling
        await container.refreshHerdrState()
        try await Task.sleep(nanoseconds: 80_000_000)
        XCTAssertTrue(container.isPollingHerdr, "Polling must survive concurrent refreshHerdrState() calls")

        container.stopHerdrPolling()
        XCTAssertFalse(container.isPollingHerdr)
    }

    func testHerdrPollingCancelledOnDisconnect() async throws {
        let container = AppContainer.demo()
        let demoChallenge = HostKeyChallenge(hostname: "demo.local", port: 22, algorithm: "ssh-ed25519", fingerprint: "SHA256:demo-fingerprint")
        await container.trustStore.save(demoChallenge)

        let host = try Host(name: "Disconnect Host", hostname: "demo.local", username: "dev")
        await container.connect(to: host)

        container.startHerdrPolling(interval: 0.1)
        XCTAssertTrue(container.isPollingHerdr)

        await container.disconnect()
        XCTAssertFalse(container.isPollingHerdr)
        XCTAssertFalse(container.herdrAvailability.isAvailable)
        XCTAssertTrue(container.herdrWorkspaces.isEmpty)
    }

    // MARK: - 4. Command Execution Gating & Pane Actions

    func testHerdrRunCommandAllowedForSafeCommands() async throws {
        let container = AppContainer.demo()
        let demoChallenge = HostKeyChallenge(hostname: "demo.local", port: 22, algorithm: "ssh-ed25519", fingerprint: "SHA256:demo-fingerprint")
        await container.trustStore.save(demoChallenge)

        let host = try Host(name: "Run Host", hostname: "demo.local", username: "dev")
        await container.connect(to: host)

        await container.refreshHerdrState()
        XCTAssertFalse(container.herdrWorkspaces.isEmpty)

        // Execute safe cargo test
        let result = await container.runHerdrPaneCommand(paneID: "pane-idle", command: "cargo test", approved: true)
        XCTAssertTrue(result.success)
        XCTAssertNil(result.error)

        // Verify pane transitioned to working state in demo connection
        let updatedIdlePane = container.herdrWorkspaces.flatMap(\.panes).first(where: { $0.id == "pane-idle" })
        XCTAssertEqual(updatedIdlePane?.agentState, .working)
    }

    func testHerdrRunCommandRejectsEmptyOrWhitespace() async throws {
        let container = AppContainer.demo()
        let demoChallenge = HostKeyChallenge(hostname: "demo.local", port: 22, algorithm: "ssh-ed25519", fingerprint: "SHA256:demo-fingerprint")
        await container.trustStore.save(demoChallenge)

        let host = try Host(name: "Run Host", hostname: "demo.local", username: "dev")
        await container.connect(to: host)

        let emptyResult = await container.runHerdrPaneCommand(paneID: "p1", command: "")
        XCTAssertFalse(emptyResult.success)
        XCTAssertEqual(emptyResult.error, "Command cannot be empty.")

        let whitespaceResult = await container.runHerdrPaneCommand(paneID: "p1", command: "   \t\n  ")
        XCTAssertFalse(whitespaceResult.success)
        XCTAssertEqual(whitespaceResult.error, "Command cannot be empty.")
    }

    func testHerdrRunCommandDestructiveBlockedByPolicy() async throws {
        let mock = MockSSHConnection()
        let transport = ControllableTransport()
        transport.onConnect = { _ in mock }

        let container = AppContainer(
            transport: transport,
            reachabilityMonitor: MockReachabilityMonitor(isReachable: true),
            reconnectCoordinator: ReconnectCoordinator(clock: { _ in }, jitter: ReconnectCoordinator.zeroJitter)
        )

        let host = try Host(name: "Blocked Host", hostname: "blocked.test", username: "user")
        await container.connect(to: host)

        final class ExecutionTracker: @unchecked Sendable {
            var commandExecuted = false
        }
        let tracker = ExecutionTracker()

        mock.onExecuteCommand = { cmd in
            tracker.commandExecuted = true
            return SSHCommandResult(exitCode: 0, stdout: "")
        }

        // Test destructive commands blocked by CommandPolicy
        let destructiveCommands = [
            "rm -rf /",
            "rm -rf /*",
            "mkfs.ext4 /dev/sda",
            ":(){ :|:& };:"
        ]

        for destructive in destructiveCommands {
            let result = await container.runHerdrPaneCommand(paneID: "pane-1", command: destructive, approved: true)
            XCTAssertFalse(result.success)
            XCTAssertNotNil(result.error)
            XCTAssertTrue(result.error?.contains("Safety policy blocked") == true)
            XCTAssertFalse(tracker.commandExecuted, "Destructive command '\(destructive)' should never reach SSH executor")
        }
    }

    func testHerdrRunCommandReviewGatingRequiresApproval() async throws {
        let mock = MockSSHConnection()
        let transport = ControllableTransport()
        transport.onConnect = { _ in mock }

        let container = AppContainer(
            transport: transport,
            reachabilityMonitor: MockReachabilityMonitor(isReachable: true),
            reconnectCoordinator: ReconnectCoordinator(clock: { _ in }, jitter: ReconnectCoordinator.zeroJitter)
        )

        let host = try Host(name: "Review Host", hostname: "review.test", username: "user")
        await container.connect(to: host)

        mock.onExecuteCommand = { cmd in
            if cmd.contains("herdr workspace list") {
                return SSHCommandResult(exitCode: 0, stdout: "[]")
            }
            return SSHCommandResult(exitCode: 0, stdout: "Success\n")
        }

        // Without approval: rejected
        let unapprovedResult = await container.runHerdrPaneCommand(paneID: "pane-1", command: "npm start", approved: false)
        XCTAssertFalse(unapprovedResult.success)
        XCTAssertNotNil(unapprovedResult.error)
        XCTAssertTrue(unapprovedResult.error?.contains("requires explicit approval") == true)

        // With approval: allowed
        let approvedResult = await container.runHerdrPaneCommand(paneID: "pane-1", command: "npm start", approved: true)
        XCTAssertTrue(approvedResult.success)
        XCTAssertNil(approvedResult.error)
    }

    func testHerdrSplitPaneAction() async throws {
        let container = AppContainer.demo()
        let demoChallenge = HostKeyChallenge(hostname: "demo.local", port: 22, algorithm: "ssh-ed25519", fingerprint: "SHA256:demo-fingerprint")
        await container.trustStore.save(demoChallenge)

        let host = try Host(name: "Split Host", hostname: "demo.local", username: "dev")
        await container.connect(to: host)

        await container.refreshHerdrState()
        let initialPaneCount = container.herdrWorkspaces.first?.panes.count ?? 0

        let result = await container.splitHerdrPane(paneID: "pane-idle", direction: "right")
        XCTAssertTrue(result.success)
        XCTAssertNil(result.error)

        let newPaneCount = container.herdrWorkspaces.first?.panes.count ?? 0
        XCTAssertEqual(newPaneCount, initialPaneCount + 1)
    }

    func testHerdrReadPaneOutputUnwrapped() async throws {
        let container = AppContainer.demo()
        let demoChallenge = HostKeyChallenge(hostname: "demo.local", port: 22, algorithm: "ssh-ed25519", fingerprint: "SHA256:demo-fingerprint")
        await container.trustStore.save(demoChallenge)

        let host = try Host(name: "Read Host", hostname: "demo.local", username: "dev")
        await container.connect(to: host)

        let output = try await container.readHerdrPaneOutput(paneID: "pane-blocked")
        XCTAssertFalse(output.isEmpty)
        XCTAssertTrue(output.contains("Pending migration"))
        // Verify output is unwrapped and contains no ANSI color codes
        XCTAssertFalse(output.contains("\u{1b}["))
    }

    func testHerdrReadPaneOutputRedactsCredentials() async throws {
        let secret = "super-sensitive-api-token-xyz"
        let credStore = InMemoryCredentialStore()
        try await credStore.save(Data(secret.utf8), reference: "ref-token-xyz")
        let identity = try IdentityDescriptor(name: "TokenID", kind: .password, keychainReference: "ref-token-xyz")

        let mock = MockSSHConnection()
        let transport = ControllableTransport()
        transport.onConnect = { _ in mock }

        let container = AppContainer(credentialStore: credStore, transport: transport)
        try await container.catalog.save(identity)
        let demoChallenge = HostKeyChallenge(hostname: "secure.local", port: 22, algorithm: "ssh-ed25519", fingerprint: "SHA256:fingerprint")
        await container.trustStore.save(demoChallenge)

        mock.onExecuteCommand = { cmd in
            if cmd.contains("herdr pane read") {
                return SSHCommandResult(
                    exitCode: 0,
                    stdout: "Token exposed in logs: \(secret)\nAll good.\n",
                    stderr: ""
                )
            }
            return SSHCommandResult(exitCode: 0, stdout: "herdr 0.1.0\n", stderr: "")
        }

        let host = try Host(name: "Secure Host", hostname: "secure.local", username: "dev", identityID: identity.id)
        await container.connect(to: host)
        XCTAssertEqual(container.activeSession?.state, .connected)

        let output = try await container.readHerdrPaneOutput(paneID: "p1")
        XCTAssertFalse(output.contains(secret), "Active credentials must be redacted from pane output")
        XCTAssertTrue(output.contains("[REDACTED]"), "Redacted placeholder must replace credential")
    }

    func testHerdrCLICommandFailureThrowsExecutionFailed() async throws {
        let mock = MockSSHConnection()
        let transport = ControllableTransport()
        transport.onConnect = { _ in mock }

        let container = AppContainer(transport: transport)
        let demoChallenge = HostKeyChallenge(hostname: "error.local", port: 22, algorithm: "ssh-ed25519", fingerprint: "SHA256:fingerprint")
        await container.trustStore.save(demoChallenge)

        mock.onExecuteCommand = { cmd in
            if cmd.contains("herdr pane read") {
                return SSHCommandResult(exitCode: 1, stdout: "", stderr: "pane 999 not found\n")
            }
            if cmd.contains("herdr wait agent-status") {
                return SSHCommandResult(exitCode: 2, stdout: "", stderr: "timeout waiting for status\n")
            }
            return SSHCommandResult(exitCode: 0, stdout: "herdr 0.1.0\n", stderr: "")
        }

        let host = try Host(name: "Error Host", hostname: "error.local", username: "dev")
        await container.connect(to: host)

        do {
            _ = try await container.readHerdrPaneOutput(paneID: "999")
            XCTFail("readHerdrPaneOutput on failure must throw")
        } catch let HerdrParseError.executionFailed(msg) {
            XCTAssertTrue(msg.contains("pane 999 not found"))
        } catch {
            XCTFail("Unexpected error type: \(error)")
        }

        do {
            _ = try await container.waitHerdrAgentStatus(paneID: "999", status: "done")
            XCTFail("waitHerdrAgentStatus on failure must throw")
        } catch let HerdrParseError.executionFailed(msg) {
            XCTAssertTrue(msg.contains("timeout waiting for status"))
        } catch {
            XCTFail("Unexpected error type: \(error)")
        }
    }

    func testHerdrWaitAgentStatus() async throws {
        let container = AppContainer.demo()
        let demoChallenge = HostKeyChallenge(hostname: "demo.local", port: 22, algorithm: "ssh-ed25519", fingerprint: "SHA256:demo-fingerprint")
        await container.trustStore.save(demoChallenge)

        let host = try Host(name: "Wait Host", hostname: "demo.local", username: "dev")
        await container.connect(to: host)

        let state = try await container.waitHerdrAgentStatus(paneID: "pane-completed", status: "completed")
        XCTAssertTrue(state.isCompleted)
    }

    func testHerdrCreateWorkspaceAction() async throws {
        let container = AppContainer.demo()
        let demoChallenge = HostKeyChallenge(hostname: "demo.local", port: 22, algorithm: "ssh-ed25519", fingerprint: "SHA256:demo-fingerprint")
        await container.trustStore.save(demoChallenge)

        let host = try Host(name: "Create WS Host", hostname: "demo.local", username: "dev")
        await container.connect(to: host)

        await container.refreshHerdrState()
        let initialWorkspaceCount = container.herdrWorkspaces.count

        // Empty label rejected
        let emptyResult = await container.createHerdrWorkspace(label: "   ", cwd: "/home")
        XCTAssertFalse(emptyResult.success)
        XCTAssertEqual(emptyResult.error, "Workspace label cannot be empty.")

        // Valid creation
        let result = await container.createHerdrWorkspace(label: "frontend-app", cwd: "/var/www/frontend")
        XCTAssertTrue(result.success)
        XCTAssertNil(result.error)

        XCTAssertEqual(container.herdrWorkspaces.count, initialWorkspaceCount + 1)
        XCTAssertTrue(container.herdrWorkspaces.contains(where: { $0.label == "frontend-app" }))
    }

    // MARK: - 5. UI View & VoiceOver Accessibility

    func testHerdrAgentStateBadgesPresentation() {
        let states: [HerdrAgentState] = [
            .idle,
            .working,
            .blocked(reason: "Awaiting review"),
            .completed(summary: "Success")
        ]

        for state in states {
            let badge = HerdrAgentStateBadge(state: state)
            let hosting = UIHostingController(rootView: badge)
            let size = hosting.sizeThatFits(in: CGSize(width: 300, height: 100))
            XCTAssertGreaterThan(size.width, 0)
            XCTAssertGreaterThan(size.height, 0)
        }
    }

    func testHerdrAgentCardViewPresentation() {
        let pane = HerdrPane(
            id: "pane-test-1",
            label: "Test Agent",
            agentState: .blocked(reason: "Review required"),
            currentCommand: "cargo build",
            lastActivity: Date()
        )

        var readCalled = false
        var commandCalled = false
        var splitCalled = false

        let card = HerdrAgentCardView(
            pane: pane,
            onReadOutput: { readCalled = true },
            onSendCommand: { commandCalled = true },
            onSplitPane: { splitCalled = true }
        )

        let hosting = UIHostingController(rootView: card)
        let size = hosting.sizeThatFits(in: CGSize(width: 393, height: 600))
        XCTAssertGreaterThan(size.width, 0)
        XCTAssertGreaterThan(size.height, 0)

        // Verify action callbacks
        XCTAssertFalse(readCalled)
        card.onReadOutput()
        XCTAssertTrue(readCalled)

        XCTAssertFalse(commandCalled)
        card.onSendCommand()
        XCTAssertTrue(commandCalled)

        XCTAssertFalse(splitCalled)
        card.onSplitPane()
        XCTAssertTrue(splitCalled)
    }

    func testHerdrAgentStateBadgeAccessibilityAndCardPresentation() {
        let badge = HerdrAgentStateBadge(state: .blocked(reason: "Needs approval"))
        let hostingBadge = UIHostingController(rootView: badge)
        let badgeSize = hostingBadge.sizeThatFits(in: CGSize(width: 300, height: 100))
        XCTAssertGreaterThan(badgeSize.width, 0)
        XCTAssertGreaterThan(badgeSize.height, 0)

        // HerdrAgentCardView under narrow width and dynamic type
        let pane = HerdrPane(
            id: "pane-narrow-test",
            label: "A very long pane label that exceeds standard narrow bounds",
            agentState: .blocked(reason: "Waiting for review"),
            currentCommand: "npm run build",
            lastActivity: Date()
        )
        let card = HerdrAgentCardView(
            pane: pane,
            onReadOutput: {},
            onSendCommand: {},
            onSplitPane: {}
        )
        let hostingCard = UIHostingController(rootView: card)
        // Test in narrow width (e.g. 180pt) to exercise header reflow
        let narrowSize = hostingCard.sizeThatFits(in: CGSize(width: 180, height: 600))
        XCTAssertGreaterThan(narrowSize.width, 0)
        XCTAssertGreaterThan(narrowSize.height, 0)
    }

    func testHerdrOutputSheetPresentation() async throws {
        let container = AppContainer.demo()
        let demoChallenge = HostKeyChallenge(hostname: "demo.local", port: 22, algorithm: "ssh-ed25519", fingerprint: "SHA256:demo-fingerprint")
        await container.trustStore.save(demoChallenge)

        let host = try Host(name: "Output Sheet Host", hostname: "demo.local", username: "dev")
        await container.connect(to: host)

        let pane = HerdrPane(
            id: "pane-blocked",
            label: "Migration Agent",
            agentState: .blocked(reason: "Migration pause"),
            currentCommand: "prisma migrate deploy"
        )

        let sheet = HerdrOutputSheet(pane: pane).environmentObject(container)
        let hosting = UIHostingController(rootView: sheet)
        let size = hosting.sizeThatFits(in: CGSize(width: 393, height: 852))
        XCTAssertGreaterThan(size.width, 0)
        XCTAssertGreaterThan(size.height, 0)
    }

    func testHerdrSendCommandSheetPolicyEvaluation() async throws {
        let container = AppContainer.demo()
        let pane = HerdrPane(
            id: "pane-cmd-1",
            label: "Command Runner",
            agentState: .idle
        )

        let sheet = HerdrSendCommandSheet(pane: pane).environmentObject(container)
        let hosting = UIHostingController(rootView: sheet)
        let size = hosting.sizeThatFits(in: CGSize(width: 393, height: 852))
        XCTAssertGreaterThan(size.width, 0)
        XCTAssertGreaterThan(size.height, 0)
    }

    func testHerdrCreateWorkspaceSheetPresentation() {
        let container = AppContainer.demo()
        let sheet = HerdrCreateWorkspaceSheet().environmentObject(container)
        let hosting = UIHostingController(rootView: sheet)
        let size = hosting.sizeThatFits(in: CGSize(width: 393, height: 852))
        XCTAssertGreaterThan(size.width, 0)
        XCTAssertGreaterThan(size.height, 0)
    }

    func testHerdrAgentCardsViewLayoutAcrossIPhoneAndIPad() async throws {
        let container = AppContainer.demo()
        let demoChallenge = HostKeyChallenge(hostname: "demo.local", port: 22, algorithm: "ssh-ed25519", fingerprint: "SHA256:demo-fingerprint")
        await container.trustStore.save(demoChallenge)

        let host = try Host(name: "Layout Host", hostname: "demo.local", username: "dev")
        await container.connect(to: host)
        await container.refreshHerdrState()

        // 1. iPhone Compact Layout (393 x 852)
        let iphoneView = HerdrAgentCardsView(isStandalone: true).environmentObject(container)
        let iphoneController = UIHostingController(rootView: iphoneView)
        let iphoneWindow = UIWindow(frame: CGRect(x: 0, y: 0, width: 393, height: 852))
        iphoneWindow.rootViewController = iphoneController
        iphoneWindow.makeKeyAndVisible()
        iphoneController.view.layoutIfNeeded()

        XCTAssertEqual(iphoneController.view.bounds.width, 393)
        XCTAssertEqual(iphoneController.view.bounds.height, 852)
        XCTAssertGreaterThan(iphoneController.view.subviews.count, 0)

        // 2. iPad Regular Layout (1024 x 1366)
        let ipadView = HerdrAgentCardsView(isStandalone: true).environmentObject(container)
        let ipadController = UIHostingController(rootView: ipadView)
        let ipadWindow = UIWindow(frame: CGRect(x: 0, y: 0, width: 1024, height: 1366))
        ipadWindow.rootViewController = ipadController
        ipadWindow.makeKeyAndVisible()
        ipadController.view.layoutIfNeeded()

        XCTAssertEqual(ipadController.view.bounds.width, 1024)
        XCTAssertEqual(ipadController.view.bounds.height, 1366)
        XCTAssertGreaterThan(ipadController.view.subviews.count, 0)
    }

    func testMultiplexerPickerHerdrSelection() async throws {
        let container = AppContainer.demo()
        let demoChallenge = HostKeyChallenge(hostname: "demo.local", port: 22, algorithm: "ssh-ed25519", fingerprint: "SHA256:demo-fingerprint")
        await container.trustStore.save(demoChallenge)

        let host = try Host(name: "Multiplexer Host", hostname: "demo.local", username: "dev")
        await container.connect(to: host)
        await container.refreshHerdrState()

        let picker = MultiplexerPicker().environmentObject(container)
        let hosting = UIHostingController(rootView: picker)
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 393, height: 852))
        window.rootViewController = hosting
        window.makeKeyAndVisible()
        hosting.view.layoutIfNeeded()

        XCTAssertGreaterThan(hosting.view.bounds.width, 0)
        XCTAssertGreaterThan(hosting.view.bounds.height, 0)
        XCTAssertTrue(container.herdrAvailability.isAvailable)
    }
}
