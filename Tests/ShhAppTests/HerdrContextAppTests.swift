import XCTest
@testable import Shh
import ShhCore

private actor ReselectHerdrGate {
    private var delayed = false
    private var entered = false
    private var released = false
    private var continuations: [CheckedContinuation<Void, Never>] = []

    func delayNext() {
        delayed = true
        entered = false
        released = false
    }

    func waitForEntry() async {
        while !entered {
            await Task.yield()
        }
    }

    func waitIfDelayed() async {
        guard delayed else { return }
        delayed = false
        entered = true
        guard !released else { return }
        await withCheckedContinuation { continuations.append($0) }
    }

    func release() {
        released = true
        continuations.forEach { $0.resume() }
        continuations.removeAll()
    }
}

@MainActor
final class HerdrContextAppTests: XCTestCase {
    func testReselectingCurrentSessionPreservesInFlightHerdrContext() async throws {
        let mock = MockSSHConnection()
        let gate = ReselectHerdrGate()
        let transport = ControllableTransport()
        transport.onConnect = { _ in mock }
        let container = AppContainer(
            transport: transport,
            reachabilityMonitor: MockReachabilityMonitor(isReachable: true),
            reconnectCoordinator: ReconnectCoordinator(
                clock: { _ in }, jitter: ReconnectCoordinator.zeroJitter
            )
        )
        let host = try Host(
            name: "Reselect Herdr Host", hostname: "reselect-herdr.test", username: "user"
        )
        await container.connect(to: host)
        mock.onExecuteCommand = { command in
            if command == HerdrCommand.sessionList.renderedCommand {
                return SSHCommandResult(
                    exitCode: 0,
                    stdout: #"{"sessions":[{"name":"review","default":false,"running":true}]}"#
                )
            }
            if command.contains("--version") {
                return SSHCommandResult(exitCode: 0, stdout: "herdr 0.9.5\n")
            }
            if command.contains("workspace list") {
                return SSHCommandResult(
                    exitCode: 0,
                    stdout: #"{"workspaces":[{"workspace_id":"review-workspace","label":"review","pane_count":1}]}"#
                )
            }
            if command.contains("pane list") {
                return SSHCommandResult(
                    exitCode: 0,
                    stdout: #"{"panes":[{"pane_id":"review-pane","workspace_id":"review-workspace","label":"agent","agent_status":"idle"}]}"#
                )
            }
            if command.contains("pane read") {
                await gate.waitIfDelayed()
                return SSHCommandResult(exitCode: 0, stdout: "current output\n")
            }
            return SSHCommandResult(exitCode: 0, stdout: "")
        }

        let listedSessions = await container.listHerdrSessions()
        XCTAssertEqual(listedSessions.map(\.name), ["review"])
        let selected = await container.selectHerdrSession(name: "review")
        XCTAssertTrue(selected)
        let sessionID = try XCTUnwrap(container.selectedSessionID)
        let pane = try XCTUnwrap(container.herdrWorkspaces.first?.panes.first)
        let target = try XCTUnwrap(container.herdrPaneTarget(for: pane))
        let runtime = try XCTUnwrap(container.runtime(for: sessionID))
        let generationBefore = runtime.herdr.contextGeneration
        await gate.delayNext()
        let pendingRead = Task { @MainActor in
            try await container.readHerdrPaneOutput(
                paneID: target.pane.id, context: target.context
            )
        }
        await gate.waitForEntry()

        container.selectSession(id: sessionID)
        XCTAssertEqual(runtime.herdr.contextGeneration, generationBefore)

        await gate.release()
        _ = try await pendingRead.value
    }
}
