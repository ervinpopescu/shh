import XCTest
import Crypto
import NIOCore
@preconcurrency import NIOSSH
@testable import ShhSSH
@testable import ShhCore

final class HerdrIntegrationTests: XCTestCase {

    private func makeConnectedClient(
        server: SSHTestServer,
        redactor: Redactor = Redactor()
    ) async throws -> (LiveSSHTransport, LiveSSHConnection) {
        let credStore = InMemoryCredentialStore()
        try await credStore.save(Data("testpassword".utf8), reference: "ref-pass")
        let identity = try IdentityDescriptor(name: "Test Pass", kind: .password, keychainReference: "ref-pass")

        let trustStore = InMemoryTrustStore()
        let challenge = HostKeyChallenge(
            hostname: "127.0.0.1",
            port: server.port,
            algorithm: "ssh-ed25519",
            fingerprint: server.fingerprint
        )
        await trustStore.save(challenge)

        let transport = LiveSSHTransport(credentialStore: credStore)
        let host = try ShhCore.Host(
            name: "Localhost",
            hostname: "127.0.0.1",
            port: server.port,
            username: "testuser",
            identityID: identity.id,
            connection: .ssh(SSHOptions(connectTimeoutSeconds: 5, strictHostKeyChecking: .trustedOnly))
        )

        let rawConnection = try await transport.connect(host: host, identity: identity, trustEvaluator: trustStore)
        guard let connection = rawConnection as? LiveSSHConnection else {
            XCTFail("Expected LiveSSHConnection")
            throw TransportError.remoteFailure("Cast failed")
        }
        connection.setRedactor(redactor)
        return (transport, connection)
    }

    // MARK: - 1. Herdr CLI Probe

    func testLiveSSHHerdrProbeAvailable() async throws {
        let server = SSHTestServer()
        _ = try await server.start()
        addTeardownBlock { try await server.stop() }

        let (_, connection) = try await makeConnectedClient(server: server)
        addTeardownBlock { await connection.close() }

        let result = try await connection.executeCommand(HerdrCommand.probe)
        XCTAssertTrue(result.isSuccess)
        XCTAssertEqual(result.exitCode, 0)
        XCTAssertEqual(result.stdout, "herdr 0.1.0\n")

        let availability = HerdrAvailability.parse(result: result)
        XCTAssertTrue(availability.isAvailable)
        XCTAssertEqual(availability.version, "herdr 0.1.0")
        XCTAssertEqual(availability.capability, .available)
    }

    // MARK: - 2. Workspaces with All 4 Agent States

    func testLiveSSHHerdrWorkspacesListAndParseFourStates() async throws {
        let server = SSHTestServer()
        _ = try await server.start()
        addTeardownBlock { try await server.stop() }

        let (_, connection) = try await makeConnectedClient(server: server)
        addTeardownBlock { await connection.close() }

        let result = try await connection.executeCommand(HerdrCommand.workspaceList().renderedCommand)
        XCTAssertTrue(result.isSuccess)

        let workspaces = try HerdrOutputParser.parseWorkspaces(from: result.stdout)
        XCTAssertFalse(workspaces.isEmpty)

        let panes = workspaces.flatMap(\.panes)
        XCTAssertGreaterThanOrEqual(panes.count, 4)

        let idlePane = panes.first(where: { $0.agentState.isIdle })
        XCTAssertNotNil(idlePane, "Must have an idle pane")
        XCTAssertEqual(idlePane?.id, "pane-idle")

        let workingPane = panes.first(where: { $0.agentState.isWorking })
        XCTAssertNotNil(workingPane, "Must have a working pane")
        XCTAssertEqual(workingPane?.id, "pane-working")

        let blockedPane = panes.first(where: { $0.agentState.isBlocked })
        XCTAssertNotNil(blockedPane, "Must have a blocked pane")
        XCTAssertEqual(blockedPane?.id, "pane-blocked")
        XCTAssertFalse(blockedPane?.agentState.blockedReason?.isEmpty ?? true)

        let completedPane = panes.first(where: { $0.agentState.isCompleted })
        XCTAssertNotNil(completedPane, "Must have a completed pane")
        XCTAssertEqual(completedPane?.id, "pane-completed")
        XCTAssertFalse(completedPane?.agentState.completedSummary?.isEmpty ?? true)
    }

    // MARK: - 3. Bounded Output Reading

    func testLiveSSHHerdrPaneRead() async throws {
        let server = SSHTestServer()
        _ = try await server.start()
        addTeardownBlock { try await server.stop() }

        let (_, connection) = try await makeConnectedClient(server: server)
        addTeardownBlock { await connection.close() }

        let readCmd = HerdrCommand.paneRead(pane: "pane-working", source: "recent-unwrapped").renderedCommand
        let result = try await connection.executeCommand(readCmd, timeout: 5.0, maxOutputBytes: 65536)
        XCTAssertTrue(result.isSuccess)

        let unwrapped = HerdrOutputParser.parseRecentUnwrapped(from: result.stdout)
        XCTAssertTrue(unwrapped.contains("Running build pipeline"))
    }

    // MARK: - 4. Deterministic State Transitions

    func testLiveSSHHerdrStateTransitions() async throws {
        let server = SSHTestServer()
        _ = try await server.start()
        addTeardownBlock { try await server.stop() }

        let (_, connection) = try await makeConnectedClient(server: server)
        addTeardownBlock { await connection.close() }

        // 1. Initial state: pane-idle is idle
        let initialList = try await connection.executeCommand(HerdrCommand.workspaceList().renderedCommand)
        let initialWorkspaces = try HerdrOutputParser.parseWorkspaces(from: initialList.stdout)
        let paneBeforeRun = initialWorkspaces.flatMap(\.panes).first(where: { $0.id == "pane-idle" })
        XCTAssertEqual(paneBeforeRun?.agentState, .idle)

        // 2. Run command in pane-idle -> transitions to working
        let runCmd = HerdrCommand.paneRun(pane: "pane-idle", command: "swift build").renderedCommand
        let runResult = try await connection.executeCommand(runCmd)
        XCTAssertTrue(runResult.isSuccess)

        let afterRunList = try await connection.executeCommand(HerdrCommand.workspaceList().renderedCommand)
        let afterRunWorkspaces = try HerdrOutputParser.parseWorkspaces(from: afterRunList.stdout)
        let paneAfterRun = afterRunWorkspaces.flatMap(\.panes).first(where: { $0.id == "pane-idle" })
        XCTAssertEqual(paneAfterRun?.agentState, .working)

        // 3. Wait agent-status -> transitions to completed
        let waitCmd = HerdrCommand.waitAgentStatus(pane: "pane-idle", status: "done").renderedCommand
        let waitResult = try await connection.executeCommand(waitCmd)
        XCTAssertTrue(waitResult.isSuccess)

        let waitState = try HerdrOutputParser.parseAgentState(from: waitResult.stdout)
        XCTAssertTrue(waitState.isCompleted)

        let afterWaitList = try await connection.executeCommand(HerdrCommand.workspaceList().renderedCommand)
        let afterWaitWorkspaces = try HerdrOutputParser.parseWorkspaces(from: afterWaitList.stdout)
        let paneAfterWait = afterWaitWorkspaces.flatMap(\.panes).first(where: { $0.id == "pane-idle" })
        XCTAssertTrue(paneAfterWait?.agentState.isCompleted ?? false)
    }

    // MARK: - 5. Zero Terminal Pollution

    func testLiveSSHHerdrZeroTerminalPollution() async throws {
        let server = SSHTestServer()
        _ = try await server.start()
        addTeardownBlock { try await server.stop() }

        let (_, connection) = try await makeConnectedClient(server: server)
        addTeardownBlock { await connection.close() }

        // Start listening on interactive PTY channel
        let stream = await connection.events()
        let receivedTerminalBytes = ArcBox<[Data]>([])

        let listenerTask = Task {
            for try await event in stream {
                if case .bytes(let data) = event {
                    receivedTerminalBytes.value.append(data)
                }
            }
        }
        addTeardownBlock { listenerTask.cancel() }

        // Allow welcome banner to arrive
        try await Task.sleep(nanoseconds: 50_000_000)
        let initialCount = receivedTerminalBytes.value.count

        // Execute several out-of-band Herdr commands
        _ = try await connection.executeCommand(HerdrCommand.probe)
        _ = try await connection.executeCommand(HerdrCommand.workspaceList().renderedCommand)
        _ = try await connection.executeCommand(HerdrCommand.paneRead(pane: "pane-working").renderedCommand)

        try await Task.sleep(nanoseconds: 50_000_000)

        // Zero additional terminal PTY bytes must have leaked
        XCTAssertEqual(receivedTerminalBytes.value.count, initialCount, "Exec commands must not pollute terminal PTY")
    }

    // MARK: - 6. Workspace Create and List

    func testLiveSSHHerdrWorkspaceCreate() async throws {
        let server = SSHTestServer()
        _ = try await server.start()
        addTeardownBlock { try await server.stop() }

        let (_, connection) = try await makeConnectedClient(server: server)
        addTeardownBlock { await connection.close() }

        let createCmd = HerdrCommand.workspaceCreate(cwd: "/tmp", label: "feat-herdr").renderedCommand
        let createResult = try await connection.executeCommand(createCmd)
        XCTAssertTrue(createResult.isSuccess)

        let createdWorkspace = try HerdrOutputParser.parseWorkspace(from: createResult.stdout)
        XCTAssertEqual(createdWorkspace.label, "feat-herdr")

        let listResult = try await connection.executeCommand(HerdrCommand.workspaceList().renderedCommand)
        let workspaces = try HerdrOutputParser.parseWorkspaces(from: listResult.stdout)
        XCTAssertTrue(workspaces.contains(where: { $0.label == "feat-herdr" }))
    }
}

// Thread-safe box helper for terminal byte tracking in test
private final class ArcBox<T>: @unchecked Sendable {
    var value: T
    init(_ value: T) { self.value = value }
}
