import ShhCore
import ShhSSH
import ShhTerminal
import XCTest
@testable import Shh

@MainActor
final class SessionRuntimeTests: XCTestCase {
    func testTwoSessionRuntimesKeepOutputInputResizeAndDisconnectIndependent() async throws {
        let hostA = try Host(name: "Alpha", hostname: "alpha.invalid", username: "dev")
        let hostB = try Host(name: "Beta", hostname: "beta.invalid", username: "dev")
        let connectionA = MockSSHConnection()
        let connectionB = MockSSHConnection()
        let runtimeA = SessionRuntime(
            host: hostA,
            session: TerminalSession(hostID: hostA.id, state: .connecting),
            connection: connectionA
        )
        let runtimeB = SessionRuntime(
            host: hostB,
            session: TerminalSession(hostID: hostB.id, state: .connecting),
            connection: connectionB
        )

        runtimeA.activate()
        runtimeB.activate()
        await waitForCallbacks()

        connectionA.emit(.bytes(Data("alpha\n".utf8)))
        connectionB.emit(.bytes(Data("beta\n".utf8)))
        await waitForCallbacks()

        XCTAssertEqual(runtimeA.terminalText, "alpha\n")
        XCTAssertEqual(runtimeB.terminalText, "beta\n")
        XCTAssertNotEqual(runtimeA.session.id, runtimeB.session.id)
        XCTAssertEqual(runtimeA.session.hostID, hostA.id)
        XCTAssertEqual(runtimeB.session.hostID, hostB.id)

        let sentA = await runtimeA.send(Data("input-a".utf8))
        let sentB = await runtimeB.send(Data("input-b".utf8))
        let resizedA = await runtimeA.resize(TerminalSize(columns: 100, rows: 40))
        let resizedB = await runtimeB.resize(TerminalSize(columns: 120, rows: 50))
        XCTAssertTrue(sentA)
        XCTAssertTrue(sentB)
        XCTAssertTrue(resizedA)
        XCTAssertTrue(resizedB)
        XCTAssertEqual(connectionA.sentData, [Data("input-a".utf8)])
        XCTAssertEqual(connectionB.sentData, [Data("input-b".utf8)])
        XCTAssertEqual(connectionA.resizeCalls, [TerminalSize(columns: 100, rows: 40)])
        XCTAssertEqual(connectionB.resizeCalls, [TerminalSize(columns: 120, rows: 50)])

        await runtimeA.disconnect()
        XCTAssertEqual(runtimeA.session.state, .disconnected)
        XCTAssertTrue(connectionA.isClosed)
        XCTAssertEqual(runtimeB.session.state, .connected)
        let sentAfterDisconnect = await runtimeB.send(Data("still-live".utf8))
        let rejectedAfterDisconnect = await runtimeA.send(Data("rejected".utf8))
        XCTAssertTrue(sentAfterDisconnect)
        XCTAssertFalse(rejectedAfterDisconnect)
        XCTAssertEqual(connectionB.sentData, [Data("input-b".utf8), Data("still-live".utf8)])
    }

    func testReconnectPreservesSessionIdentityAndRejectsStaleCallbacks() async throws {
        let host = try Host(name: "Reconnect", hostname: "reconnect.invalid", username: "dev")
        let original = MockSSHConnection()
        let replacement = MockSSHConnection()
        let sessionID = UUID()
        let runtime = SessionRuntime(
            host: host,
            session: TerminalSession(id: sessionID, hostID: host.id, state: .connecting),
            connection: original
        )

        runtime.activate()
        await waitForCallbacks()
        let staleToken = runtime.callbackToken
        original.emit(.bytes(Data("before\n".utf8)))
        await waitForCallbacks()

        await runtime.reconnect(with: replacement)
        await waitForCallbacks()

        XCTAssertEqual(runtime.session.id, sessionID)
        XCTAssertEqual(runtime.session.hostID, host.id)
        XCTAssertEqual(runtime.session.state, .connected)
        XCTAssertEqual(runtime.reconnectGeneration, 1)
        XCTAssertFalse(runtime.accepts(staleToken))

        replacement.emit(.bytes(Data("after\n".utf8)))
        await waitForCallbacks()
        XCTAssertEqual(runtime.terminalText, "after\n")
        XCTAssertTrue(original.isClosed)
        let sentOnReplacement = await runtime.send(Data("new-connection".utf8))
        XCTAssertTrue(sentOnReplacement)
        XCTAssertEqual(replacement.sentData, [Data("new-connection".utf8)])
    }

    private func waitForCallbacks() async {
        await Task.yield()
        try? await Task.sleep(nanoseconds: 20_000_000)
    }
}
