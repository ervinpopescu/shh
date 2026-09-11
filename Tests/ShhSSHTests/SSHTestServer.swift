@preconcurrency import NIOSSH
import Foundation
import Crypto
import Citadel
import NIOCore
import NIOPosix
import ShhCore

extension NIOSSHPublicKey {
    static func ed25519(_ key: Curve25519.Signing.PublicKey) throws -> NIOSSHPublicKey {
        var buffer = ByteBufferAllocator().buffer(capacity: 64)
        let prefix = "ssh-ed25519"
        buffer.writeInteger(UInt32(prefix.utf8.count))
        buffer.writeBytes(prefix.utf8)
        let keyBytes = Array(key.rawRepresentation)
        buffer.writeInteger(UInt32(keyBytes.count))
        buffer.writeBytes(keyBytes)
        let base64 = Data(buffer.readableBytesView).base64EncodedString()
        return try NIOSSHPublicKey(openSSHPublicKey: "\(prefix) \(base64)")
    }
}

final class TestServerAuthDelegate: NIOSSHServerUserAuthenticationDelegate, @unchecked Sendable {
    var supportedAuthenticationMethods: NIOSSHAvailableUserAuthenticationMethods = [.password, .publicKey]
    var expectedPassword = "testpassword"
    var expectedUsername = "testuser"
    var expectedClientPublicKey: NIOSSHPublicKey?
    var onAuthAttempt: (@Sendable (NIOSSHUserAuthenticationRequest) -> Void)?
    private(set) var authAttemptsCount = 0
    private let lock = NSLock()

    func requestReceived(
        request: NIOSSHUserAuthenticationRequest,
        responsePromise: EventLoopPromise<NIOSSHUserAuthenticationOutcome>
    ) {
        lock.withLock {
            authAttemptsCount += 1
        }
        onAuthAttempt?(request)

        guard request.username == expectedUsername else {
            responsePromise.succeed(.failure)
            return
        }

        switch request.request {
        case .password(let pass):
            if pass.password == expectedPassword {
                responsePromise.succeed(.success)
            } else {
                responsePromise.succeed(.failure)
            }
        case .publicKey(let pub):
            if let expectedKey = expectedClientPublicKey {
                if pub.publicKey == expectedKey {
                    responsePromise.succeed(.success)
                } else {
                    responsePromise.succeed(.failure)
                }
            } else {
                responsePromise.succeed(.success)
            }
        default:
            responsePromise.succeed(.failure)
        }
    }
}

final class TestServerSessionChannelHandler: ChannelDuplexHandler, @unchecked Sendable {
    typealias InboundIn = SSHChannelData
    typealias InboundOut = SSHChannelData
    typealias OutboundIn = SSHChannelData
    typealias OutboundOut = SSHChannelData

    var onPTY: (@Sendable (Int, Int) -> Void)?
    var onShell: (@Sendable () -> Void)?
    var onResize: (@Sendable (Int, Int) -> Void)?
    var onData: (@Sendable (Data) -> Void)?
    var suppressPTYReply = false
    var suppressShellReply = false

    func userInboundEventTriggered(context: ChannelHandlerContext, event: Any) {
        switch event {
        case let pty as SSHChannelRequestEvent.PseudoTerminalRequest:
            onPTY?(pty.terminalCharacterWidth, pty.terminalRowHeight)
            if pty.wantReply && !suppressPTYReply {
                context.channel.triggerUserOutboundEvent(ChannelSuccessEvent(), promise: nil)
            }
        case let shell as SSHChannelRequestEvent.ShellRequest:
            onShell?()
            if shell.wantReply && !suppressShellReply {
                context.channel.triggerUserOutboundEvent(ChannelSuccessEvent(), promise: nil)
            }
            var buffer = context.channel.allocator.buffer(capacity: 32)
            buffer.writeString("Welcome to test shell\r\n$ ")
            let banner = SSHChannelData(type: .channel, data: .byteBuffer(buffer))
            context.channel.writeAndFlush(banner, promise: nil)
        case let resize as SSHChannelRequestEvent.WindowChangeRequest:
            onResize?(resize.terminalCharacterWidth, resize.terminalRowHeight)
            var buffer = context.channel.allocator.buffer(capacity: 32)
            buffer.writeString("[resize:\(resize.terminalCharacterWidth)x\(resize.terminalRowHeight)]")
            let resizeEcho = SSHChannelData(type: .channel, data: .byteBuffer(buffer))
            context.channel.writeAndFlush(resizeEcho, promise: nil)
        default:
            context.fireUserInboundEventTriggered(event)
        }
    }

    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        let channelData = self.unwrapInboundIn(data)
        guard case .byteBuffer(var buffer) = channelData.data else { return }
        let bytes = buffer.readBytes(length: buffer.readableBytes) ?? []
        onData?(Data(bytes))

        var echoBuffer = context.channel.allocator.buffer(capacity: bytes.count)
        echoBuffer.writeBytes(bytes)
        let echo = SSHChannelData(type: .channel, data: .byteBuffer(echoBuffer))
        context.channel.writeAndFlush(echo, promise: nil)
    }
}

final class SSHTestServer: @unchecked Sendable {
    let group: MultiThreadedEventLoopGroup
    let authDelegate = TestServerAuthDelegate()
    let hostPrivateKey: Curve25519.Signing.PrivateKey
    let hostPublicKey: NIOSSHPublicKey
    private var serverChannel: Channel?
    private var childChannels: [Channel] = []
    private let lock = NSLock()
    private(set) var port: UInt16 = 0
    let sessionHandler = TestServerSessionChannelHandler()

    init(hostKey: Curve25519.Signing.PrivateKey = Curve25519.Signing.PrivateKey()) {
        self.group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
        self.hostPrivateKey = hostKey
        self.hostPublicKey = try! NIOSSHPublicKey.ed25519(hostKey.publicKey)
    }

    var fingerprint: String {
        var buffer = ByteBufferAllocator().buffer(capacity: 256)
        _ = hostPublicKey.write(to: &buffer)
        let bytes = buffer.readBytes(length: buffer.readableBytes) ?? []
        let digest = SHA256.hash(data: bytes)
        let base64 = Data(digest).base64EncodedString().trimmingCharacters(in: CharacterSet(charactersIn: "="))
        return "SHA256:\(base64)"
    }

    func start() async throws -> UInt16 {
        let nioKey = NIOSSHPrivateKey(ed25519Key: hostPrivateKey)
        let serverConfig = SSHServerConfiguration(
            hostKeys: [nioKey],
            userAuthDelegate: authDelegate,
            globalRequestDelegate: nil
        )

        let sessionHandler = self.sessionHandler
        let bootstrap = ServerBootstrap(group: group)
            .serverChannelOption(ChannelOptions.socket(SocketOptionLevel(SOL_SOCKET), SO_REUSEADDR), value: 1)
            .childChannelOption(ChannelOptions.socket(SocketOptionLevel(IPPROTO_TCP), TCP_NODELAY), value: 1)
            .childChannelInitializer { [weak self] channel in
                self?.lock.withLock { self?.childChannels.append(channel) }
                return channel.pipeline.addHandlers([
                    NIOSSHHandler(
                        role: .server(serverConfig),
                        allocator: channel.allocator,
                        inboundChildChannelInitializer: { childChannel, channelType in
                            guard channelType == .session else {
                                return childChannel.close()
                            }
                            return childChannel.pipeline.addHandler(sessionHandler)
                        }
                    )
                ])
            }

        let channel = try await bootstrap.bind(host: "127.0.0.1", port: 0).get()
        self.serverChannel = channel
        self.port = UInt16(channel.localAddress!.port!)
        return self.port
    }

    func stop() async throws {
        _ = try? await serverChannel?.close().get()
        let children = lock.withLock { childChannels }
        for child in children {
            _ = try? await child.close().get()
        }
        try await group.shutdownGracefully()
    }
}

final class HangingTCPServer: @unchecked Sendable {
    private let group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
    private var channel: Channel?
    private var childChannels: [Channel] = []
    private let lock = NSLock()
    private(set) var port: UInt16 = 0

    func start() async throws -> UInt16 {
        let bootstrap = ServerBootstrap(group: group)
            .serverChannelOption(ChannelOptions.socket(SocketOptionLevel(SOL_SOCKET), SO_REUSEADDR), value: 1)
            .childChannelInitializer { [weak self] channel in
                self?.lock.withLock { self?.childChannels.append(channel) }
                return channel.eventLoop.makeSucceededFuture(())
            }
        let ch = try await bootstrap.bind(host: "127.0.0.1", port: 0).get()
        self.channel = ch
        self.port = UInt16(ch.localAddress!.port!)
        return self.port
    }

    func stop() async throws {
        _ = try? await channel?.close().get()
        let children = lock.withLock { childChannels }
        for child in children {
            _ = try? await child.close().get()
        }
        try await group.shutdownGracefully()
    }
}
