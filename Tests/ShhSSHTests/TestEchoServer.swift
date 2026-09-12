import Foundation
import NIOCore
import NIOPosix

final class TestEchoHandler: ChannelInboundHandler, @unchecked Sendable {
    typealias InboundIn = ByteBuffer
    typealias OutboundOut = ByteBuffer

    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        context.writeAndFlush(data, promise: nil)
    }
}

final class TestEchoServer: @unchecked Sendable {
    let group: MultiThreadedEventLoopGroup
    private var serverChannel: Channel?
    private(set) var port: UInt16 = 0

    init() {
        self.group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
    }

    func start() async throws -> UInt16 {
        let bootstrap = ServerBootstrap(group: group)
            .serverChannelOption(ChannelOptions.socket(SocketOptionLevel(SOL_SOCKET), SO_REUSEADDR), value: 1)
            .childChannelOption(ChannelOptions.socket(SocketOptionLevel(IPPROTO_TCP), TCP_NODELAY), value: 1)
            .childChannelInitializer { channel in
                channel.pipeline.addHandler(TestEchoHandler())
            }

        let channel = try await bootstrap.bind(host: "127.0.0.1", port: 0).get()
        self.serverChannel = channel
        self.port = UInt16(channel.localAddress!.port!)
        return self.port
    }

    func stop() async throws {
        _ = try? await serverChannel?.close().get()
        try await group.shutdownGracefully()
    }
}
