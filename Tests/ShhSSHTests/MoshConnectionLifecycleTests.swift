import Foundation
import XCTest

@testable import ShhCore
@preconcurrency @testable import ShhSSH

final class MoshConnectionLifecycleTests: XCTestCase {
    func testCloseRejectsNewSendAndDrainsAdmittedSend() async throws {
        let channel = ControlledMoshDatagramChannel()
        let connection = makeConnection(channel: channel)
        try await connection.start()

        let pendingSend = Task {
            try await connection.send(Data("admitted".utf8))
        }
        await channel.waitForSendStart()

        let firstClose = Task {
            await connection.close()
        }
        while !(await connection.isClosed) {
            await Task.yield()
        }
        let secondClose = Task {
            await connection.close()
        }

        do {
            try await connection.send(Data("rejected".utf8))
            XCTFail("send after close admission should fail")
        } catch let error as TransportError {
            XCTAssertEqual(error, .networkUnavailable)
        }

        channel.releaseSend()
        _ = try? await pendingSend.value
        await firstClose.value
        await secondClose.value

        let snapshot = channel.snapshot()
        XCTAssertEqual(snapshot.closeCount, 1)
        XCTAssertEqual(snapshot.teardownCount, 1)
    }

    func testCloseQuarantinesNonCooperativeSendWithinDeadline() async throws {
        let channel = ControlledMoshDatagramChannel(cooperativeSendCancellation: false)
        let connection = makeConnection(channel: channel)
        try await connection.start()

        let pendingSend = Task {
            try await connection.send(Data("blocked".utf8))
        }
        await channel.waitForSendStart()

        await connection.close()
        let didQuarantine = await connection.didQuarantine
        let channelSnapshot = channel.snapshot()
        let closeCount = channelSnapshot.closeCount
        XCTAssertTrue(didQuarantine)
        XCTAssertEqual(closeCount, 1)

        channel.releaseSend()
        _ = try? await pendingSend.value
    }

    func testEventsAfterCloseReturnClosedFinishedStream() async throws {
        let channel = ControlledMoshDatagramChannel()
        let connection = makeConnection(channel: channel)
        try await connection.start()

        await connection.close()
        let stream = await connection.events()
        var iterator = stream.makeAsyncIterator()
        let firstEvent = try await iterator.next()
        let secondEvent = try await iterator.next()

        XCTAssertEqual(firstEvent, .closed)
        XCTAssertNil(secondEvent)
    }

    private func makeConnection(channel: ControlledMoshDatagramChannel) -> MoshConnection {
        MoshConnection(
            sessionInfo: MoshSessionInfo(
                udpPort: 60001,
                sessionKey: "moshLifecycleTestKey",
                pid: 9000
            ),
            remoteHostname: "192.0.2.10",
            channel: channel
        )
    }
}

private final class ControlledMoshDatagramChannel: MoshDatagramChannel, @unchecked Sendable {
    private let cooperativeSendCancellation: Bool
    private let lock = NSLock()
    private var streamContinuation: AsyncThrowingStream<Data, Error>.Continuation?
    private var sendContinuation: CheckedContinuation<Void, Error>?
    private var sendStarted = false
    private var isClosed = false
    private var closeCount = 0
    private var sentDatagrams: [Data] = []

    init(cooperativeSendCancellation: Bool = true) {
        self.cooperativeSendCancellation = cooperativeSendCancellation
    }

    func start() async throws {}

    func send(datagram: Data) async throws {
        let isTeardown = MoshDatagram.decode(from: datagram)?.kind == .teardown
        lock.withLock {
            sentDatagrams.append(datagram)
            sendStarted = true
        }
        guard !isTeardown else { return }
        let shouldCancel = cooperativeSendCancellation
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation {
                (continuation: CheckedContinuation<Void, Error>) in
                if Task.isCancelled, shouldCancel {
                    continuation.resume(throwing: CancellationError())
                } else {
                    lock.withLock {
                        sendContinuation = continuation
                    }
                }
            }
        } onCancel: {
            if shouldCancel {
                self.cancelSend()
            }
        }
        try Task.checkCancellation()
    }

    func incomingDatagrams() -> AsyncThrowingStream<Data, Error> {
        AsyncThrowingStream { continuation in
            lock.withLock {
                streamContinuation = continuation
            }
        }
    }

    func updateEndpoint(host: String, port: UInt16) async throws {}

    func close() async {
        let (stream, send):
            (
                AsyncThrowingStream<Data, Error>.Continuation?,
                CheckedContinuation<Void, Error>?
            ) = lock.withLock {
                closeCount += 1
                isClosed = true
                let stream = streamContinuation
                streamContinuation = nil
                let send = cooperativeSendCancellation ? sendContinuation : nil
                if cooperativeSendCancellation {
                    sendContinuation = nil
                }
                return (stream, send)
            }
        stream?.finish()
        send?.resume(throwing: CancellationError())
    }

    func waitForSendStart() async {
        while !lock.withLock({ sendStarted }) {
            try? await Task.sleep(nanoseconds: 1_000_000)
        }
    }

    func releaseSend() {
        let continuation = lock.withLock {
            defer { sendContinuation = nil }
            return sendContinuation
        }
        continuation?.resume()
    }

    func snapshot() -> (closeCount: Int, teardownCount: Int) {
        lock.withLock {
            let teardownCount = sentDatagrams.reduce(into: 0) { count, datagram in
                if MoshDatagram.decode(from: datagram)?.kind == .teardown {
                    count += 1
                }
            }
            return (closeCount, teardownCount)
        }
    }

    private func cancelSend() {
        let continuation = lock.withLock {
            defer { sendContinuation = nil }
            return sendContinuation
        }
        continuation?.resume(throwing: CancellationError())
    }
}
