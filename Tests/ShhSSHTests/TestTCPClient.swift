import Foundation
import NIOCore
import NIOPosix

final class TestTCPClientHandler: ChannelInboundHandler, @unchecked Sendable {
    typealias InboundIn = ByteBuffer
    private let onData: @Sendable (Data) -> Void
    private let onDisconnect: @Sendable (Error?) -> Void

    init(
        onData: @escaping @Sendable (Data) -> Void,
        onDisconnect: @escaping @Sendable (Error?) -> Void
    ) {
        self.onData = onData
        self.onDisconnect = onDisconnect
    }

    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        var buffer = unwrapInboundIn(data)
        if let bytes = buffer.readBytes(length: buffer.readableBytes) {
            onData(Data(bytes))
        }
    }

    func channelInactive(context: ChannelHandlerContext) {
        onDisconnect(nil)
        context.fireChannelInactive()
    }

    func errorCaught(context: ChannelHandlerContext, error: Error) {
        onDisconnect(error)
        context.fireErrorCaught(error)
    }
}

final class TestTCPClient: @unchecked Sendable {
    private let group: MultiThreadedEventLoopGroup
    private var channel: Channel?
    private let lock = NSLock()
    private var receivedData: [Data] = []
    private var waiters: [(id: UUID, continuation: CheckedContinuation<Data, Error>)] = []
    private var isClosed = false
    private var disconnectError: Error?

    init() {
        self.group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
    }

    func connect(host: String, port: Int) async throws {
        let client = self
        let bootstrap = ClientBootstrap(group: group)
            .channelOption(ChannelOptions.socket(SocketOptionLevel(IPPROTO_TCP), TCP_NODELAY), value: 1)
            .channelInitializer { ch in
                let handler = TestTCPClientHandler(
                    onData: { data in
                        client.handleData(data)
                    },
                    onDisconnect: { error in
                        client.handleDisconnect(error: error)
                    }
                )
                return ch.pipeline.addHandler(handler)
            }

        self.channel = try await bootstrap.connect(host: host, port: port).get()
    }

    private func handleData(_ data: Data) {
        let waiter: CheckedContinuation<Data, Error>? = lock.withLock {
            guard !isClosed else { return nil }
            if !waiters.isEmpty {
                return waiters.removeFirst().continuation
            } else {
                receivedData.append(data)
                return nil
            }
        }
        waiter?.resume(returning: data)
    }

    private func handleDisconnect(error: Error?) {
        let pendingWaiters: [CheckedContinuation<Data, Error>] = lock.withLock {
            guard !isClosed else { return [] }
            isClosed = true
            disconnectError = error
            let continuations = waiters.map(\.continuation)
            waiters.removeAll()
            return continuations
        }
        let failure = error ?? POSIXError(.ECONNRESET)
        for continuation in pendingWaiters {
            continuation.resume(throwing: failure)
        }
    }

    private func cancelWaiter(id: UUID) {
        let continuation: CheckedContinuation<Data, Error>? = lock.withLock {
            if let index = waiters.firstIndex(where: { $0.id == id }) {
                return waiters.remove(at: index).continuation
            }
            return nil
        }
        continuation?.resume(throwing: CancellationError())
    }

    func send(_ data: Data) async throws {
        let currentChannel: Channel? = lock.withLock {
            guard !isClosed else { return nil }
            return self.channel
        }
        guard let currentChannel else {
            throw POSIXError(.ENOTCONN)
        }
        var buffer = currentChannel.allocator.buffer(capacity: data.count)
        buffer.writeBytes(data)
        try await currentChannel.writeAndFlush(buffer).get()
    }

    func receiveNext(timeout: TimeInterval = 3.0) async throws -> Data {
        let immediate: Result<Data, Error>? = lock.withLock {
            if !receivedData.isEmpty {
                return .success(receivedData.removeFirst())
            }
            if let error = disconnectError {
                return .failure(error)
            }
            if isClosed {
                return .failure(POSIXError(.ECONNRESET))
            }
            return nil
        }
        if let immediate {
            return try immediate.get()
        }

        let waiterID = UUID()

        return try await withThrowingTaskGroup(of: Data.self) { group in
            group.addTask {
                try await withTaskCancellationHandler {
                    try await withCheckedThrowingContinuation { continuation in
                        self.lock.withLock {
                            if !self.receivedData.isEmpty {
                                continuation.resume(returning: self.receivedData.removeFirst())
                                return
                            }
                            if let error = self.disconnectError {
                                continuation.resume(throwing: error)
                                return
                            }
                            if self.isClosed {
                                continuation.resume(throwing: POSIXError(.ECONNRESET))
                                return
                            }
                            self.waiters.append((id: waiterID, continuation: continuation))
                        }
                    }
                } onCancel: {
                    self.cancelWaiter(id: waiterID)
                }
            }

            group.addTask {
                try await Task.sleep(nanoseconds: UInt64(timeout * 1_000_000_000))
                throw POSIXError(.ETIMEDOUT)
            }

            do {
                let result = try await group.next()!
                group.cancelAll()
                return result
            } catch {
                group.cancelAll()
                throw error
            }
        }
    }

    func close() async {
        let pendingWaiters: [CheckedContinuation<Data, Error>] = lock.withLock {
            isClosed = true
            let continuations = waiters.map(\.continuation)
            waiters.removeAll()
            return continuations
        }
        for continuation in pendingWaiters {
            continuation.resume(throwing: POSIXError(.ECONNRESET))
        }
        _ = try? await channel?.close().get()
        channel = nil
        try? await group.shutdownGracefully()
    }
}
