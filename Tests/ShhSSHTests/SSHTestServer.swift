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

enum TestServerExecMode: Sendable {
    case normal
    case noServer
    case notInstalled
    case malformed
    case missingExitStatus
}

struct SSHCommandTestResponse: Sendable {
    var exitCode: Int32
    var stdout: String
    var stderr: String
    var delay: TimeInterval?
    var omitExitStatus: Bool
    var rejectExec: Bool
    var closeAfterData: Bool

    init(
        exitCode: Int32 = 0,
        stdout: String = "",
        stderr: String = "",
        delay: TimeInterval? = nil,
        omitExitStatus: Bool = false,
        rejectExec: Bool = false,
        closeAfterData: Bool = true
    ) {
        self.exitCode = exitCode
        self.stdout = stdout
        self.stderr = stderr
        self.delay = delay
        self.omitExitStatus = omitExitStatus
        self.rejectExec = rejectExec
        self.closeAfterData = closeAfterData
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

final class TestServerChildHandler: ChannelDuplexHandler, @unchecked Sendable {
    typealias InboundIn = SSHChannelData
    typealias InboundOut = SSHChannelData
    typealias OutboundIn = SSHChannelData
    typealias OutboundOut = SSHChannelData

    private weak var server: SSHTestServer?

    init(server: SSHTestServer) {
        self.server = server
    }

    func userInboundEventTriggered(context: ChannelHandlerContext, event: Any) {
        guard let server = server else {
            context.fireUserInboundEventTriggered(event)
            return
        }

        switch event {
        case let pty as SSHChannelRequestEvent.PseudoTerminalRequest:
            server.sessionHandler.onPTY?(pty.terminalCharacterWidth, pty.terminalRowHeight)
            if pty.wantReply && !server.sessionHandler.suppressPTYReply {
                context.channel.triggerUserOutboundEvent(ChannelSuccessEvent(), promise: nil)
            }

        case let shell as SSHChannelRequestEvent.ShellRequest:
            server.sessionHandler.onShell?()
            if shell.wantReply && !server.sessionHandler.suppressShellReply {
                context.channel.triggerUserOutboundEvent(ChannelSuccessEvent(), promise: nil)
            }
            var buffer = context.channel.allocator.buffer(capacity: 32)
            buffer.writeString("Welcome to test shell\r\n$ ")
            let banner = SSHChannelData(type: .channel, data: .byteBuffer(buffer))
            context.channel.writeAndFlush(banner, promise: nil)

        case let resize as SSHChannelRequestEvent.WindowChangeRequest:
            server.sessionHandler.onResize?(resize.terminalCharacterWidth, resize.terminalRowHeight)
            var buffer = context.channel.allocator.buffer(capacity: 32)
            buffer.writeString("[resize:\(resize.terminalCharacterWidth)x\(resize.terminalRowHeight)]")
            let resizeEcho = SSHChannelData(type: .channel, data: .byteBuffer(buffer))
            context.channel.writeAndFlush(resizeEcho, promise: nil)

        case let exec as SSHChannelRequestEvent.ExecRequest:
            server.handleExec(request: exec, channel: context.channel)

        default:
            context.fireUserInboundEventTriggered(event)
        }
    }

    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        let channelData = self.unwrapInboundIn(data)
        guard case .byteBuffer(var buffer) = channelData.data else { return }
        let bytes = buffer.readBytes(length: buffer.readableBytes) ?? []
        server?.sessionHandler.onData?(Data(bytes))

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

    var execMode: TestServerExecMode = .normal
    var execDelay: TimeInterval? = nil
    var execHandler: (@Sendable (String) -> SSHCommandTestResponse)? = nil

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

        let bootstrap = ServerBootstrap(group: group)
            .serverChannelOption(ChannelOptions.socket(SocketOptionLevel(SOL_SOCKET), SO_REUSEADDR), value: 1)
            .childChannelOption(ChannelOptions.socket(SocketOptionLevel(IPPROTO_TCP), TCP_NODELAY), value: 1)
            .childChannelInitializer { [weak self] channel in
                self?.lock.withLock { self?.childChannels.append(channel) }
                let sshHandler = NIOSSHHandler(
                    role: .server(serverConfig),
                    allocator: channel.allocator,
                    inboundChildChannelInitializer: { [weak self] childChannel, channelType in
                        guard channelType == .session, let self = self else {
                            return childChannel.close()
                        }
                        self.lock.withLock { self.childChannels.append(childChannel) }
                        _ = childChannel.setOption(ChannelOptions.allowRemoteHalfClosure, value: true)
                        let handler = TestServerChildHandler(server: self)
                        return childChannel.pipeline.addHandler(handler)
                    }
                )
                return channel.pipeline.addHandler(sshHandler)
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

    func handleExec(request: SSHChannelRequestEvent.ExecRequest, channel: Channel) {
        let command = request.command
        let response: SSHCommandTestResponse
        if let custom = self.execHandler {
            response = custom(command)
        } else {
            response = defaultExecResponse(for: command)
        }

        if response.rejectExec {
            if request.wantReply {
                channel.triggerUserOutboundEvent(ChannelFailureEvent(), promise: nil)
            }
            channel.close(promise: nil)
            return
        }

        if request.wantReply {
            channel.triggerUserOutboundEvent(ChannelSuccessEvent(), promise: nil)
        }

        let effectiveDelay = response.delay ?? self.execDelay
        if let delay = effectiveDelay, delay > 0 {
            _ = channel.eventLoop.scheduleTask(in: .milliseconds(Int64(delay * 1000))) { [weak self] in
                guard channel.isActive else { return }
                self?.sendExecResponse(response, on: channel)
            }
        } else {
            sendExecResponse(response, on: channel)
        }
    }

    func sendExecResponse(_ response: SSHCommandTestResponse, on channel: Channel) {
        if !response.stdout.isEmpty {
            let chunkSize = 16384
            let utf8 = Array(response.stdout.utf8)
            for start in stride(from: 0, to: utf8.count, by: chunkSize) {
                let end = min(start + chunkSize, utf8.count)
                var buffer = channel.allocator.buffer(capacity: end - start)
                buffer.writeBytes(utf8[start..<end])
                channel.write(SSHChannelData(type: .channel, data: .byteBuffer(buffer)), promise: nil)
            }
        }

        if !response.stderr.isEmpty {
            let chunkSize = 16384
            let utf8 = Array(response.stderr.utf8)
            for start in stride(from: 0, to: utf8.count, by: chunkSize) {
                let end = min(start + chunkSize, utf8.count)
                var buffer = channel.allocator.buffer(capacity: end - start)
                buffer.writeBytes(utf8[start..<end])
                channel.write(SSHChannelData(type: .stdErr, data: .byteBuffer(buffer)), promise: nil)
            }
        }

        channel.flush()

        if !response.omitExitStatus {
            channel.triggerUserOutboundEvent(
                SSHChannelRequestEvent.ExitStatus(exitStatus: Int(response.exitCode)),
                promise: nil
            )
        }

        if response.closeAfterData {
            channel.close(promise: nil)
        }
    }

    func defaultExecResponse(for command: String) -> SSHCommandTestResponse {
        let trimmed = command.trimmingCharacters(in: .whitespacesAndNewlines)

        switch self.execMode {
        case .noServer:
            return SSHCommandTestResponse(
                exitCode: 1,
                stdout: "",
                stderr: "no server running on /private/tmp/tmux-501/default\n"
            )
        case .notInstalled:
            return SSHCommandTestResponse(
                exitCode: 127,
                stdout: "",
                stderr: "bash: line 1: tmux: command not found\n"
            )
        case .malformed:
            return SSHCommandTestResponse(
                exitCode: 0,
                stdout: "malformed_output_without_tabs\n",
                stderr: ""
            )
        case .missingExitStatus:
            return SSHCommandTestResponse(
                exitCode: 0,
                stdout: "output before closed without status\n",
                stderr: "",
                omitExitStatus: true
            )
        case .normal:
            break
        }

        if trimmed.contains("missing-exit-status") {
            return SSHCommandTestResponse(
                exitCode: 0,
                stdout: "output without status\n",
                stderr: "",
                omitExitStatus: true
            )
        }

        if trimmed.contains("reject-exec") {
            return SSHCommandTestResponse(rejectExec: true)
        }

        if trimmed.contains("large-output") {
            // Generate 2MB of output
            let chunk = String(repeating: "X", count: 1024)
            let largeOutput = (0..<2048).map { _ in chunk }.joined()
            return SSHCommandTestResponse(
                exitCode: 0,
                stdout: largeOutput,
                stderr: ""
            )
        }

        if trimmed.contains("timeout-delay") {
            return SSHCommandTestResponse(
                exitCode: 0,
                stdout: "delayed execution done\n",
                stderr: "",
                delay: 0.5
            )
        }

        if trimmed.contains("delayed") {
            return SSHCommandTestResponse(
                exitCode: 0,
                stdout: "delayed execution done\n",
                stderr: "",
                delay: 2.0
            )
        }

        if trimmed.contains("exit 42") || trimmed.contains("nonzero") {
            return SSHCommandTestResponse(
                exitCode: 42,
                stdout: "",
                stderr: "process exited with code 42\n"
            )
        }

        if trimmed.contains("no-server") {
            return SSHCommandTestResponse(
                exitCode: 1,
                stdout: "",
                stderr: "no server running on /private/tmp/tmux-501/default\n"
            )
        }

        if trimmed.contains("not-installed") {
            return SSHCommandTestResponse(
                exitCode: 127,
                stdout: "",
                stderr: "bash: line 1: tmux: command not found\n"
            )
        }

        if trimmed.contains("malformed") {
            return SSHCommandTestResponse(
                exitCode: 0,
                stdout: "malformed_output_without_tabs\n",
                stderr: ""
            )
        }

        if trimmed == TmuxCommand.probe || trimmed == "tmux -V" {
            return SSHCommandTestResponse(
                exitCode: 0,
                stdout: "tmux 3.4\n",
                stderr: ""
            )
        }

        if trimmed == TmuxCommand.listSessions || trimmed.contains("list-sessions") {
            if trimmed.contains("no-sessions") || trimmed.contains("empty") {
                return SSHCommandTestResponse(
                    exitCode: 1,
                    stdout: "",
                    stderr: "no server running on /private/tmp/tmux-501/default\n"
                )
            }
            let listOutput = "$0\tmain\t2\t1700000000\t1700000100\t1\n$1\tdev\t1\t1700000200\t1700000300\t0\n"
            return SSHCommandTestResponse(
                exitCode: 0,
                stdout: listOutput,
                stderr: ""
            )
        }

        if trimmed.contains("has-session") {
            if trimmed.contains("$0") || trimmed.contains("$1") || trimmed.contains("main") || trimmed.contains("dev") {
                return SSHCommandTestResponse(
                    exitCode: 0,
                    stdout: "",
                    stderr: ""
                )
            } else {
                return SSHCommandTestResponse(
                    exitCode: 1,
                    stdout: "",
                    stderr: "can't find session\n"
                )
            }
        }

        return SSHCommandTestResponse(
            exitCode: 0,
            stdout: "\(command)\n",
            stderr: ""
        )
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
