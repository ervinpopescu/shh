import Foundation
import Crypto
import NIOCore
import NIOPosix
@preconcurrency import NIOSSH
import ShhCore

final class LiveSSHUserAuthDelegate: NIOSSHClientUserAuthenticationDelegate, @unchecked Sendable {
    enum Credential: Sendable {
        case password(String)
        case privateKey(Curve25519.Signing.PrivateKey)
        case none
    }

    private let username: String
    private let resolveCredential: @Sendable () async throws -> Credential
    private let lock = NSLock()
    private var hasAttempted = false

    init(username: String, resolveCredential: @escaping @Sendable () async throws -> Credential) {
        self.username = username
        self.resolveCredential = resolveCredential
    }

    func nextAuthenticationType(
        availableMethods: NIOSSHAvailableUserAuthenticationMethods,
        nextChallengePromise: EventLoopPromise<NIOSSHUserAuthenticationOffer?>
    ) {
        let alreadyAttempted = lock.withLock {
            let prev = hasAttempted
            hasAttempted = true
            return prev
        }

        guard !alreadyAttempted else {
            nextChallengePromise.fail(TransportError.authenticationRequired)
            return
        }

        Task {
            do {
                let credential = try await resolveCredential()
                switch credential {
                case .password(let password):
                    guard availableMethods.contains(.password) else {
                        nextChallengePromise.fail(TransportError.authenticationRequired)
                        return
                    }
                    let offer = NIOSSHUserAuthenticationOffer(
                        username: username,
                        serviceName: "ssh-connection",
                        offer: .password(.init(password: password))
                    )
                    nextChallengePromise.succeed(offer)

                case .privateKey(let key):
                    guard availableMethods.contains(.publicKey) else {
                        nextChallengePromise.fail(TransportError.authenticationRequired)
                        return
                    }
                    let nioKey = NIOSSHPrivateKey(ed25519Key: key)
                    let offer = NIOSSHUserAuthenticationOffer(
                        username: username,
                        serviceName: "ssh-connection",
                        offer: .privateKey(.init(privateKey: nioKey))
                    )
                    nextChallengePromise.succeed(offer)

                case .none:
                    nextChallengePromise.fail(TransportError.authenticationRequired)
                }
            } catch {
                nextChallengePromise.fail(error)
            }
        }
    }
}

private final class LiveSSHHandshakeHandler: ChannelInboundHandler, @unchecked Sendable {
    typealias InboundIn = Any

    private let promise: EventLoopPromise<Void>
    private let lock = NSLock()
    private var completed = false

    init(promise: EventLoopPromise<Void>) {
        self.promise = promise
    }

    func succeed() {
        let shouldSucceed = lock.withLock {
            if !completed {
                completed = true
                return true
            }
            return false
        }
        if shouldSucceed {
            promise.succeed(())
        }
    }

    func fail(_ error: Error) {
        let shouldFail = lock.withLock {
            if !completed {
                completed = true
                return true
            }
            return false
        }
        if shouldFail {
            promise.fail(error)
        }
    }

    func userInboundEventTriggered(context: ChannelHandlerContext, event: Any) {
        if event is UserAuthSuccessEvent {
            succeed()
        }
        context.fireUserInboundEventTriggered(event)
    }

    func errorCaught(context: ChannelHandlerContext, error: Error) {
        fail(error)
        context.close(promise: nil)
    }

    func channelInactive(context: ChannelHandlerContext) {
        fail(TransportError.remoteFailure("SSH connection disconnected during handshake"))
        context.fireChannelInactive()
    }
}

private final class InboundEventRouter: @unchecked Sendable {
    private let lock = NSLock()
    private weak var connection: LiveSSHConnection?

    func setConnection(_ connection: LiveSSHConnection) {
        lock.withLock { self.connection = connection }
    }

    func onData(_ data: Data) {
        let conn = lock.withLock { self.connection }
        conn?.handleInboundData(data)
    }

    func onClosed() {
        let conn = lock.withLock { self.connection }
        conn?.handleChannelClosed()
    }

    func onError(_ error: Error) {
        let conn = lock.withLock { self.connection }
        conn?.handleChannelError(error)
    }
}

public struct LiveSSHTransport: SSHTransport {
    public let credentialStore: any CredentialStore
    private let customGroup: EventLoopGroup?

    public init(credentialStore: any CredentialStore = KeychainCredentialStore()) {
        self.credentialStore = credentialStore
        self.customGroup = nil
    }

    init(credentialStore: any CredentialStore, group: EventLoopGroup?) {
        self.credentialStore = credentialStore
        self.customGroup = group
    }

    public func connect(
        host: ShhCore.Host,
        identity: IdentityDescriptor?,
        trustEvaluator: any HostTrustEvaluator,
        initialSize: TerminalSize = TerminalSize(columns: 80, rows: 24)
    ) async throws -> any SSHConnection {
        guard case .ssh(let options) = host.connection else {
            throw TransportError.unsupported
        }

        do {
            if options.connectTimeoutSeconds > 0 {
                return try await withThrowingTaskGroup(of: (any SSHConnection).self) { group in
                    group.addTask {
                        try await self.performConnect(
                            host: host,
                            identity: identity,
                            trustEvaluator: trustEvaluator,
                            initialSize: initialSize,
                            options: options
                        )
                    }
                    group.addTask {
                        let nanos = UInt64(max(0.001, options.connectTimeoutSeconds) * 1_000_000_000)
                        try await Task.sleep(nanoseconds: nanos)
                        throw TransportError.timeout
                    }

                    do {
                        let connection = try await group.next()!
                        group.cancelAll()
                        return connection
                    } catch {
                        group.cancelAll()
                        throw error
                    }
                }
            } else {
                return try await performConnect(
                    host: host,
                    identity: identity,
                    trustEvaluator: trustEvaluator,
                    initialSize: initialSize,
                    options: options
                )
            }
        } catch {
            if Task.isCancelled || error is CancellationError {
                throw TransportError.cancelled
            }
            throw error
        }
    }

    private func performConnect(
        host: ShhCore.Host,
        identity: IdentityDescriptor?,
        trustEvaluator: any HostTrustEvaluator,
        initialSize: TerminalSize,
        options: SSHOptions
    ) async throws -> any SSHConnection {
        if Task.isCancelled { throw TransportError.cancelled }

        let ownsGroup = (customGroup == nil)
        let eventLoopGroup = customGroup ?? MultiThreadedEventLoopGroup(numberOfThreads: 1)

        let validator = HostKeyValidatorDelegate(
            hostname: host.hostname,
            port: host.port,
            strictChecking: options.strictHostKeyChecking,
            trustEvaluator: trustEvaluator
        )

        let credStore = self.credentialStore
        let userAuthDelegate = LiveSSHUserAuthDelegate(
            username: host.username,
            resolveCredential: {
                try await Self.resolveAuthenticationCredential(identity: identity, credentialStore: credStore)
            }
        )

        let clientConfig = SSHClientConfiguration(
            userAuthDelegate: userAuthDelegate,
            serverAuthDelegate: validator
        )

        var rawChannel: Channel?
        var createdConnection: LiveSSHConnection?

        do {
            var bootstrap = ClientBootstrap(group: eventLoopGroup)
                .channelOption(ChannelOptions.socket(SocketOptionLevel(SOL_SOCKET), SO_REUSEADDR), value: 1)
                .channelOption(ChannelOptions.socket(SocketOptionLevel(IPPROTO_TCP), TCP_NODELAY), value: 1)

            if options.connectTimeoutSeconds > 0 {
                bootstrap = bootstrap.connectTimeout(.milliseconds(Int64(options.connectTimeoutSeconds * 1000)))
            }

            let handshakePromise = eventLoopGroup.next().makePromise(of: Void.self)
            let handshakeHandler = LiveSSHHandshakeHandler(promise: handshakePromise)

            bootstrap = bootstrap.channelInitializer { channel in
                let sshHandler = NIOSSHHandler(
                    role: .client(clientConfig),
                    allocator: channel.allocator,
                    inboundChildChannelInitializer: nil
                )
                return channel.pipeline.addHandlers([sshHandler, handshakeHandler])
            }

            let channel = try await withTaskCancellationHandler {
                try await bootstrap.connect(host: host.hostname, port: Int(host.port)).get()
            } onCancel: {}
            rawChannel = channel

            if Task.isCancelled { throw TransportError.cancelled }

            channel.closeFuture.whenComplete { _ in
                handshakeHandler.fail(TransportError.remoteFailure("Connection closed before handshake"))
            }

            try await withTaskCancellationHandler {
                try await handshakePromise.futureResult.get()
            } onCancel: {
                handshakeHandler.fail(TransportError.cancelled)
                channel.close(promise: nil)
            }

            if Task.isCancelled { throw TransportError.cancelled }

            if let captured = validator.capturedError {
                throw captured
            }

            let router = InboundEventRouter()
            let (childChannel, childHandler) = try await channel.eventLoop.flatSubmit {
                channel.pipeline.handler(type: NIOSSHHandler.self).flatMap { sshHandler in
                    let childPromise = channel.eventLoop.makePromise(of: Channel.self)
                    let handlerPromise = channel.eventLoop.makePromise(of: LiveSSHChildChannelHandler.self)
                    sshHandler.createChannel(childPromise, channelType: .session) { newChildChannel, channelType in
                        guard channelType == .session else {
                            return newChildChannel.close()
                        }
                        let handler = LiveSSHChildChannelHandler(
                            onData: { data in router.onData(data) },
                            onClosed: { router.onClosed() },
                            onError: { error in router.onError(error) }
                        )
                        handlerPromise.succeed(handler)
                        return newChildChannel.pipeline.addHandler(handler)
                    }
                    return childPromise.futureResult.flatMap { child in
                        handlerPromise.futureResult.map { handler in (child, handler) }
                    }
                }
            }.get()

            let connection = LiveSSHConnection(
                childChannel: childChannel,
                parentChannel: channel,
                eventLoopGroup: eventLoopGroup,
                ownsGroup: ownsGroup
            )
            createdConnection = connection
            router.setConnection(connection)

            let ptyRequest = SSHChannelRequestEvent.PseudoTerminalRequest(
                wantReply: true,
                term: "xterm-256color",
                terminalCharacterWidth: initialSize.columns,
                terminalRowHeight: initialSize.rows,
                terminalPixelWidth: 0,
                terminalPixelHeight: 0,
                terminalModes: SSHTerminalModes([:])
            )
            let ptyPromise = childChannel.eventLoop.makePromise(of: Void.self)
            childHandler.addPendingReplyPromise(ptyPromise)
            try await childChannel.triggerUserOutboundEvent(ptyRequest).get()
            try await withTaskCancellationHandler {
                try await ptyPromise.futureResult.get()
            } onCancel: {
                channel.close(promise: nil)
            }

            if Task.isCancelled { throw TransportError.cancelled }

            let shellRequest = SSHChannelRequestEvent.ShellRequest(wantReply: true)
            let shellPromise = childChannel.eventLoop.makePromise(of: Void.self)
            childHandler.addPendingReplyPromise(shellPromise)
            try await childChannel.triggerUserOutboundEvent(shellRequest).get()
            try await withTaskCancellationHandler {
                try await shellPromise.futureResult.get()
            } onCancel: {
                channel.close(promise: nil)
            }

            return connection
        } catch {
            if let createdConnection {
                await createdConnection.close()
            } else {
                await cleanup(channel: rawChannel, group: ownsGroup ? eventLoopGroup : nil)
            }
            if let captured = validator.capturedError {
                throw captured
            }
            throw mapError(error)
        }
    }

    private static func resolveAuthenticationCredential(
        identity: IdentityDescriptor?,
        credentialStore: any CredentialStore
    ) async throws -> LiveSSHUserAuthDelegate.Credential {
        guard let identity else {
            return .none
        }

        switch identity.kind {
        case .password:
            do {
                let data = try await credentialStore.load(reference: identity.keychainReference)
                guard let password = String(data: data, encoding: .utf8), !password.isEmpty else {
                    throw TransportError.authenticationRequired
                }
                return .password(password)
            } catch let error as TransportError {
                throw error
            } catch {
                throw TransportError.authenticationRequired
            }
        case .privateKey:
            do {
                let data = try await credentialStore.load(reference: identity.keychainReference)
                let privateKey = try Ed25519Parser.parse(from: data)
                return .privateKey(privateKey)
            } catch let error as TransportError {
                throw error
            } catch {
                throw TransportError.authenticationRequired
            }
        case .agent:
            throw TransportError.unsupported
        }
    }

    private func cleanup(channel: Channel?, group: EventLoopGroup?) async {
        _ = try? await channel?.close().get()
        if let group {
            try? await group.shutdownGracefully()
        }
    }

    private func mapError(_ error: Error) -> TransportError {
        if let transportError = error as? TransportError {
            return transportError
        }
        if Task.isCancelled || error is CancellationError {
            return .cancelled
        }

        let description = error.localizedDescription.lowercased()

        if let channelError = error as? ChannelError {
            switch channelError {
            case .connectTimeout:
                return .timeout
            default:
                break
            }
        }
        if description.contains("timed out") || description.contains("timeout") {
            return .timeout
        }

        if let posixError = error as? POSIXError {
            switch posixError.code {
            case .ECONNREFUSED, .EHOSTUNREACH, .ENETUNREACH, .ENETDOWN:
                return .networkUnavailable
            case .ETIMEDOUT:
                return .timeout
            default:
                return .networkUnavailable
            }
        }

        if description.contains("connection refused") || description.contains("unreachable") || description.contains("network") {
            return .networkUnavailable
        }

        if description.contains("authentication") || description.contains("auth failed") {
            return .authenticationRequired
        }

        return .remoteFailure(error.localizedDescription)
    }
}
