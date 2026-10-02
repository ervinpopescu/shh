import Darwin
import NIOCore
import NIOPosix
@preconcurrency import NIOSSH
import XCTest

@testable import ShhCore
@testable import ShhSSH

final class LiveSSHConnectionLifecycleTests: XCTestCase {
    func testCloseDrainsAdmittedSendAndRejectsNewSend() async throws {
        let (connection, blocker, group, peerSocket, _) = try await makeConnection()
        let pendingSend = Task {
            try await connection.send(Data("admitted".utf8))
        }
        await blocker.waitForPendingWrite()
        let firstClose = Task {
            await connection.close()
        }
        let secondClose = Task {
            await connection.close()
        }
        while !connection.isClosed {
            await Task.yield()
        }

        do {
            try await connection.send(Data("rejected".utf8))
            XCTFail("send after close admission should fail")
        } catch {
            XCTAssertTrue(error is TransportError)
        }

        blocker.completePendingWrite()
        try await pendingSend.value
        await firstClose.value
        await secondClose.value

        Darwin.close(peerSocket)
        try await group.shutdownGracefully()
    }

    func testRedactorCleanupClosesAdmissionBarrierAtomically() async throws {
        let (connection, blocker, group, peerSocket, _) = try await makeConnection()
        connection.setRedactor(Redactor(secrets: ["cleanup-secret"]))
        let admittedSend = Task {
            try await connection.send(Data("admitted-before-cleanup".utf8))
        }
        await blocker.waitForPendingWrite()

        connection.clearRedactorAfterOperations()
        do {
            try await connection.send(Data("must-not-admit".utf8))
            XCTFail("writes admitted after redactor cleanup would race secret clearing")
        } catch {
            XCTAssertTrue(error is TransportError)
        }

        blocker.completePendingWrite()
        try await admittedSend.value
        await connection.close()
        Darwin.close(peerSocket)
        try await group.shutdownGracefully()
    }

    func testCloseQuarantinesUncooperativeWriteAfterDeadline() async throws {
        let (connection, blocker, group, peerSocket, _) = try await makeConnection()
        let pendingSend = Task {
            try await connection.send(Data("uncooperative".utf8))
        }
        await blocker.waitForPendingWrite()

        await connection.close()
        XCTAssertTrue(connection.didQuarantine)

        blocker.completePendingWrite()
        _ = try? await pendingSend.value
        Darwin.close(peerSocket)
        try await group.shutdownGracefully()
    }

    func testKeepaliveBlackholeClosesWithoutDuplicatePromiseCompletion() async throws {
        let (connection, group, peerSocket) = try await makeBlackholeConnection()

        let responsive = await connection.testResponsiveness(timeout: 0.1)
        XCTAssertFalse(responsive)
        await connection.close()

        Darwin.close(peerSocket)
        try await group.shutdownGracefully()
    }

    func testForwardedChannelRegistrationIsRejectedAfterClose() async throws {
        let (connection, _, group, peerSocket, channel) = try await makeConnection()

        await connection.close()
        XCTAssertNil(connection.trackForwardedChannel(channel))

        Darwin.close(peerSocket)
        try await group.shutdownGracefully()
    }

    func testEventsAfterCloseReturnFinishedStream() async throws {
        let (connection, _, group, peerSocket, _) = try await makeConnection()

        await connection.close()
        let stream = await connection.events()
        var iterator = stream.makeAsyncIterator()
        let firstEvent = try await iterator.next()
        let secondEvent = try await iterator.next()

        XCTAssertEqual(firstEvent, .closed)
        XCTAssertNil(secondEvent)
        Darwin.close(peerSocket)
        try await group.shutdownGracefully()
    }

    private func makeBlackholeConnection() async throws -> (
        LiveSSHConnection,
        MultiThreadedEventLoopGroup,
        CInt
    ) {
        let group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
        var socketFDs: [CInt] = [-1, -1]
        guard Darwin.socketpair(AF_UNIX, SOCK_STREAM, 0, &socketFDs) == 0 else {
            throw POSIXError(.EIO)
        }
        let clientConfiguration = SSHClientConfiguration(
            userAuthDelegate: BlackholeAuthDelegate(),
            serverAuthDelegate: BlackholeHostKeyDelegate()
        )
        let channel = try await ClientBootstrap(group: group)
            .channelInitializer { channel in
                let handler = UncheckedSendableBox(
                    NIOSSHHandler(
                        role: .client(clientConfiguration),
                        allocator: channel.allocator,
                        inboundChildChannelInitializer: { childChannel, _ in
                            childChannel.close()
                        }
                    )
                )
                do {
                    try channel.pipeline.syncOperations.addHandler(handler.value)
                    return channel.eventLoop.makeSucceededFuture(())
                } catch {
                    return channel.eventLoop.makeFailedFuture(error)
                }
            }
            .withConnectedSocket(socketFDs[0])
            .get()
        let connection = LiveSSHConnection(
            childChannel: channel,
            parentChannel: channel,
            eventLoopGroup: nil,
            ownsGroup: false
        )
        return (connection, group, socketFDs[1])
    }

    private func makeConnection() async throws -> (
        LiveSSHConnection,
        BlockingWriteHandler,
        MultiThreadedEventLoopGroup,
        CInt,
        Channel
    ) {
        let group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
        var socketFDs: [CInt] = [-1, -1]
        guard Darwin.socketpair(AF_UNIX, SOCK_STREAM, 0, &socketFDs) == 0 else {
            throw POSIXError(.EIO)
        }
        let blocker = BlockingWriteHandler()
        let channel = try await ClientBootstrap(group: group)
            .channelInitializer { channel in
                channel.pipeline.addHandler(blocker)
            }
            .withConnectedSocket(socketFDs[0])
            .get()
        let connection = LiveSSHConnection(
            childChannel: channel,
            parentChannel: channel,
            eventLoopGroup: nil,
            ownsGroup: false
        )
        return (connection, blocker, group, socketFDs[1], channel)
    }
}

private final class UncheckedSendableBox<Value>: @unchecked Sendable {
    let value: Value

    init(_ value: Value) {
        self.value = value
    }
}

private struct BlackholeAuthDelegate: NIOSSHClientUserAuthenticationDelegate {
    func nextAuthenticationType(
        availableMethods: NIOSSHAvailableUserAuthenticationMethods,
        nextChallengePromise: EventLoopPromise<NIOSSHUserAuthenticationOffer?>
    ) {
        nextChallengePromise.succeed(nil)
    }
}

private struct BlackholeHostKeyDelegate: NIOSSHClientServerAuthenticationDelegate {
    func validateHostKey(
        hostKey: NIOSSHPublicKey,
        validationCompletePromise: EventLoopPromise<Void>
    ) {
        validationCompletePromise.succeed(())
    }
}

private final class BlockingWriteHandler: ChannelOutboundHandler, @unchecked Sendable {
    typealias OutboundIn = Any
    typealias OutboundOut = Any

    private let lock = NSLock()
    private var pendingPromise: EventLoopPromise<Void>?
    private var pendingWriteWaiters: [CheckedContinuation<Void, Never>] = []

    func write(
        context: ChannelHandlerContext,
        data: NIOAny,
        promise: EventLoopPromise<Void>?
    ) {
        let waiters = lock.withLock {
            pendingPromise = promise
            defer { pendingWriteWaiters.removeAll() }
            return pendingWriteWaiters
        }
        for waiter in waiters {
            waiter.resume()
        }
    }

    func waitForPendingWrite() async {
        await withCheckedContinuation { continuation in
            let alreadyPending = lock.withLock {
                if pendingPromise != nil {
                    return true
                }
                pendingWriteWaiters.append(continuation)
                return false
            }
            if alreadyPending {
                continuation.resume()
            }
        }
    }

    func completePendingWrite() {
        let promise = lock.withLock {
            defer { pendingPromise = nil }
            return pendingPromise
        }
        promise?.succeed()
    }
}
