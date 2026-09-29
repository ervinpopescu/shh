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

    func testOldConnectionEventsAreIgnoredAfterReconnect() async throws {
        let host = try Host(name: "Stale", hostname: "stale.invalid", username: "dev")
        let original = RuntimeControlledConnection(finishEventsOnClose: false)
        let replacement = RuntimeControlledConnection(finishEventsOnClose: false)
        let runtime = SessionRuntime(
            host: host,
            session: TerminalSession(hostID: host.id, state: .connecting),
            connection: original
        )

        runtime.activate()
        await original.waitForEventsSubscription()
        await runtime.reconnect(with: replacement)
        await replacement.waitForEventsSubscription()

        await original.emit(.bytes(Data("stale\n".utf8)))
        await replacement.emit(.bytes(Data("current\n".utf8)))
        await waitForCallbacks()

        let originalSnapshot = await original.snapshot()
        XCTAssertEqual(runtime.terminalText, "current\n")
        XCTAssertEqual(originalSnapshot.closeCallCount, 1)
        XCTAssertEqual(runtime.session.state, .connected)
    }

    func testReconnectCancelsInFlightSendAndResizeBeforeReplacement() async throws {
        let host = try Host(name: "Barrier", hostname: "barrier.invalid", username: "dev")
        let original = RuntimeControlledConnection(blocksIO: true)
        let replacement = RuntimeControlledConnection()
        let runtime = SessionRuntime(
            host: host,
            session: TerminalSession(hostID: host.id, state: .connecting),
            connection: original
        )
        runtime.activate()
        await original.waitForEventsSubscription()
        let pendingSend = Task { @MainActor in
            await runtime.send(Data("old-output\n".utf8))
        }
        await original.waitForSendStart()
        await runtime.reconnect(with: replacement)
        await replacement.waitForEventsSubscription()
        _ = await pendingSend.value

        let replacementSent = await runtime.send(Data("new-output\n".utf8))
        let originalSnapshot = await original.snapshot()
        let replacementSnapshot = await replacement.snapshot()
        XCTAssertTrue(replacementSent)
        XCTAssertEqual(originalSnapshot.closeCallCount, 1)
        XCTAssertEqual(originalSnapshot.sentData, [Data("old-output\n".utf8)])
        XCTAssertEqual(replacementSnapshot.sentData, [Data("new-output\n".utf8)])

        let secondOriginal = RuntimeControlledConnection(blocksIO: true)
        let secondReplacement = RuntimeControlledConnection()
        let secondRuntime = SessionRuntime(
            host: host,
            session: TerminalSession(hostID: host.id, state: .connecting),
            connection: secondOriginal
        )
        secondRuntime.activate()
        await secondOriginal.waitForEventsSubscription()
        let pendingResize = Task { @MainActor in
            await secondRuntime.resize(TerminalSize(columns: 101, rows: 41))
        }
        await secondOriginal.waitForResizeStart()
        await secondRuntime.reconnect(with: secondReplacement)
        await secondReplacement.waitForEventsSubscription()
        _ = await pendingResize.value

        let replacementResized = await secondRuntime.resize(TerminalSize(columns: 121, rows: 51))
        let secondOriginalSnapshot = await secondOriginal.snapshot()
        let secondReplacementSnapshot = await secondReplacement.snapshot()
        XCTAssertTrue(replacementResized)
        XCTAssertEqual(secondOriginalSnapshot.closeCallCount, 1)
        XCTAssertEqual(secondOriginalSnapshot.resizeCalls, [TerminalSize(columns: 101, rows: 41)])
        XCTAssertEqual(
            secondReplacementSnapshot.resizeCalls,
            [TerminalSize(columns: 121, rows: 51)]
        )
    }

    func testReconnectQuiescesBeforeConcurrentSend() async throws {
        let host = try Host(name: "Quiesce", hostname: "quiesce.invalid", username: "dev")
        let original = RuntimeControlledConnection(blocksClose: true)
        let replacement = RuntimeControlledConnection()
        let runtime = SessionRuntime(
            host: host,
            session: TerminalSession(hostID: host.id, state: .connecting),
            connection: original
        )
        runtime.activate()
        await original.waitForEventsSubscription()

        let reconnectTask = Task { @MainActor in
            await runtime.reconnect(with: replacement)
        }
        await original.waitForCloseStart()

        let sentDuringReconnect = await runtime.send(Data("stale-output".utf8))
        let originalDuringReconnect = await original.snapshot()
        XCTAssertFalse(sentDuringReconnect)
        XCTAssertEqual(originalDuringReconnect.sentData, [])

        await original.releaseClose()
        let reconnectSucceeded = await reconnectTask.value
        XCTAssertTrue(reconnectSucceeded)
        await replacement.waitForEventsSubscription()
        let replacementSent = await runtime.send(Data("replacement-output".utf8))
        let replacementSnapshot = await replacement.snapshot()
        XCTAssertTrue(replacementSent)
        XCTAssertEqual(replacementSnapshot.sentData, [Data("replacement-output".utf8)])
    }

    func testReconnectFailsWithinBoundForNonCooperativeConnection() async throws {
        let host = try Host(
            name: "Uncooperative", hostname: "uncooperative.invalid", username: "dev")
        let original = RuntimeControlledConnection(
            blocksIO: true,
            cooperativeIO: false,
            interruptsIOOnClose: false
        )
        let replacement = RuntimeControlledConnection()
        let runtime = SessionRuntime(
            host: host,
            session: TerminalSession(hostID: host.id, state: .connecting),
            connection: original
        )
        runtime.activate()
        await original.waitForEventsSubscription()
        let pendingSend = Task { @MainActor in
            await runtime.send(Data("blocked-output".utf8))
        }
        await original.waitForSendStart()

        let reconnectSucceeded = await runtime.reconnect(with: replacement)
        let replacementSnapshot = await replacement.snapshot()
        let originalSnapshot = await original.snapshot()
        let rejectedSend = await runtime.send(Data("rejected-output".utf8))
        XCTAssertFalse(reconnectSucceeded)
        XCTAssertEqual(runtime.session.state, .failed)
        XCTAssertEqual(runtime.reconnectState, .failed(reason: "Connection shutdown timed out."))
        XCTAssertFalse(rejectedSend)
        XCTAssertEqual(replacementSnapshot.closeCallCount, 0)
        XCTAssertEqual(originalSnapshot.closeCallCount, 1)
        pendingSend.cancel()
        await original.releaseIO()
        _ = await pendingSend.value
    }

    func testRedactorAndErrorCleanupRemainPerRuntime() async throws {
        let hostA = try Host(name: "Redacted A", hostname: "redacted-a.invalid", username: "dev")
        let hostB = try Host(name: "Redacted B", hostname: "redacted-b.invalid", username: "dev")
        let connectionA = RuntimeControlledConnection()
        let connectionB = RuntimeControlledConnection()
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
        runtimeA.setRedactor(Redactor(secrets: ["secret-a"]))
        runtimeB.setRedactor(Redactor(secrets: ["secret-b"]))
        runtimeA.activate()
        runtimeB.activate()
        await connectionA.waitForEventsSubscription()
        await connectionB.waitForEventsSubscription()

        await connectionA.emit(.bytes(Data("secret-a\n".utf8)))
        await connectionB.emit(.bytes(Data("secret-b\n".utf8)))
        await waitForCallbacks()
        XCTAssertEqual(runtimeA.terminalText, "[REDACTED]\n")
        XCTAssertEqual(runtimeB.terminalText, "[REDACTED]\n")
        XCTAssertEqual(runtimeA.redactor.secrets, ["secret-a"])
        XCTAssertEqual(runtimeB.redactor.secrets, ["secret-b"])

        await connectionA.emit(.error(.networkUnavailable))
        await waitForCallbacks()
        let connectionASnapshot = await connectionA.snapshot()
        let connectionBSnapshot = await connectionB.snapshot()
        XCTAssertEqual(runtimeA.session.state, .failed)
        XCTAssertTrue(runtimeA.redactor.secrets.isEmpty)
        XCTAssertEqual(runtimeB.session.state, .connected)
        XCTAssertEqual(runtimeB.redactor.secrets, ["secret-b"])
        XCTAssertEqual(connectionASnapshot.closeCallCount, 1)
        XCTAssertEqual(connectionBSnapshot.closeCallCount, 0)
    }

    private func waitForCallbacks() async {
        await Task.yield()
        try? await Task.sleep(nanoseconds: 20_000_000)
    }
}

private actor RuntimeControlledConnection: SSHConnection {
    private let blocksIO: Bool
    private let cooperativeIO: Bool
    private let interruptsIOOnClose: Bool
    private let blocksClose: Bool
    private let finishEventsOnClose: Bool
    private var streamContinuation: AsyncThrowingStream<TerminalEvent, Error>.Continuation?
    private var sendContinuation: CheckedContinuation<Void, Error>?
    private var resizeContinuation: CheckedContinuation<Void, Error>?
    private var closeContinuation: CheckedContinuation<Void, Never>?
    private var sendCallCount = 0
    private var resizeCallCount = 0
    private(set) var sentData: [Data] = []
    private(set) var resizeCalls: [TerminalSize] = []
    private(set) var closeCallCount = 0

    init(
        blocksIO: Bool = false,
        cooperativeIO: Bool = true,
        interruptsIOOnClose: Bool = true,
        blocksClose: Bool = false,
        finishEventsOnClose: Bool = true
    ) {
        self.blocksIO = blocksIO
        self.cooperativeIO = cooperativeIO
        self.interruptsIOOnClose = interruptsIOOnClose
        self.blocksClose = blocksClose
        self.finishEventsOnClose = finishEventsOnClose
    }

    func events() async -> AsyncThrowingStream<TerminalEvent, Error> {
        AsyncThrowingStream { continuation in
            streamContinuation = continuation
        }
    }

    func send(_ data: Data) async throws {
        sentData.append(data)
        sendCallCount += 1
        guard blocksIO else { return }
        let shouldCancelIO = cooperativeIO
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation {
                (continuation: CheckedContinuation<Void, Error>) in
                if Task.isCancelled {
                    continuation.resume(throwing: CancellationError())
                } else {
                    sendContinuation = continuation
                }
            }
        } onCancel: {
            if shouldCancelIO {
                Task { await self.cancelSend() }
            }
        }
        try Task.checkCancellation()
    }

    func resize(_ size: TerminalSize) async throws {
        resizeCalls.append(size)
        resizeCallCount += 1
        guard blocksIO else { return }
        let shouldCancelIO = cooperativeIO
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation {
                (continuation: CheckedContinuation<Void, Error>) in
                if Task.isCancelled {
                    continuation.resume(throwing: CancellationError())
                } else {
                    resizeContinuation = continuation
                }
            }
        } onCancel: {
            if shouldCancelIO {
                Task { await self.cancelResize() }
            }
        }
        try Task.checkCancellation()
    }

    func close() async {
        closeCallCount += 1
        if blocksClose {
            await withCheckedContinuation { continuation in
                closeContinuation = continuation
            }
        }
        if interruptsIOOnClose {
            cancelSend()
            cancelResize()
        }
        if finishEventsOnClose {
            streamContinuation?.finish()
        }
    }

    func emit(_ event: TerminalEvent) {
        streamContinuation?.yield(event)
    }

    func waitForEventsSubscription() async {
        while streamContinuation == nil {
            try? await Task.sleep(nanoseconds: 1_000_000)
        }
    }

    func waitForSendStart() async {
        while sendCallCount == 0 {
            try? await Task.sleep(nanoseconds: 1_000_000)
        }
    }

    func waitForResizeStart() async {
        while resizeCallCount == 0 {
            try? await Task.sleep(nanoseconds: 1_000_000)
        }
    }

    func waitForCloseStart() async {
        while closeContinuation == nil {
            try? await Task.sleep(nanoseconds: 1_000_000)
        }
    }

    func releaseClose() {
        closeContinuation?.resume()
        closeContinuation = nil
    }

    func releaseIO() {
        cancelSend()
        cancelResize()
    }

    func snapshot() -> (closeCallCount: Int, sentData: [Data], resizeCalls: [TerminalSize]) {
        (closeCallCount, sentData, resizeCalls)
    }

    private func cancelSend() {
        sendContinuation?.resume(throwing: CancellationError())
        sendContinuation = nil
    }

    private func cancelResize() {
        resizeContinuation?.resume(throwing: CancellationError())
        resizeContinuation = nil
    }
}
