import Foundation
import NIOCore
import NIOPosix

final class TestTCPClientHandler: ChannelInboundHandler, @unchecked Sendable {
    typealias InboundIn = ByteBuffer
    private let onData: @Sendable (Data) -> Void

    init(onData: @escaping @Sendable (Data) -> Void) {
        self.onData = onData
    }

    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        var buffer = unwrapInboundIn(data)
        if let bytes = buffer.readBytes(length: buffer.readableBytes) {
            onData(Data(bytes))
        }
    }
}

final class TestTCPClient: @unchecked Sendable {
    private let group: MultiThreadedEventLoopGroup
    private var channel: Channel?
    private let lock = NSLock()
    private var receivedData: [Data] = []
    private var dataContinuations: [AsyncStream<Data>.Continuation] = []

    init() {
        self.group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
    }

    func connect(host: String, port: Int) async throws {
        let client = self
        let bootstrap = ClientBootstrap(group: group)
            .channelOption(ChannelOptions.socket(SocketOptionLevel(IPPROTO_TCP), TCP_NODELAY), value: 1)
            .channelInitializer { ch in
                let handler = TestTCPClientHandler { data in
                    client.handleData(data)
                }
                return ch.pipeline.addHandler(handler)
            }

        self.channel = try await bootstrap.connect(host: host, port: port).get()
    }

    private func handleData(_ data: Data) {
        let continuation: AsyncStream<Data>.Continuation? = lock.withLock {
            if !dataContinuations.isEmpty {
                return dataContinuations.removeFirst()
            } else {
                receivedData.append(data)
                return nil
            }
        }
        continuation?.yield(data)
        continuation?.finish()
    }

    func send(_ data: Data) async throws {
        guard let channel = self.channel else {
            throw POSIXError(.ENOTCONN)
        }
        var buffer = channel.allocator.buffer(capacity: data.count)
        buffer.writeBytes(data)
        try await channel.writeAndFlush(buffer).get()
    }

    func receiveNext(timeout: TimeInterval = 3.0) async throws -> Data {
        let existing: Data? = lock.withLock {
            if !receivedData.isEmpty {
                return receivedData.removeFirst()
            }
            return nil
        }
        if let existing {
            return existing
        }

        return try await withThrowingTaskGroup(of: Data.self) { group in
            group.addTask {
                let stream = AsyncStream<Data> { continuation in
                    self.lock.withLock {
                        self.dataContinuations.append(continuation)
                    }
                }
                for await chunk in stream {
                    return chunk
                }
                throw POSIXError(.ECONNRESET)
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
        _ = try? await channel?.close().get()
        channel = nil
        try? await group.shutdownGracefully()
    }
}
