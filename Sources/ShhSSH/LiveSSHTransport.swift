import Foundation
import Crypto
import NIOCore
import NIOPosix
@preconcurrency import NIOSSH
import ShhCore

#if swift(>=6.0)
extension NIOSSHHandler: @retroactive @unchecked Sendable {}
#else
extension NIOSSHHandler: @unchecked Sendable {}
#endif

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

final class LiveSSHHandshakeHandler: ChannelInboundHandler, @unchecked Sendable {
    typealias InboundIn = Any

    private let promise: EventLoopPromise<Void>
    private let lock = NSLock()
    private var completed = false

    init(promise: EventLoopPromise<Void>) {
        self.promise = promise
    }

    deinit {
        let shouldFail = lock.withLock {
            if !completed {
                completed = true
                return true
            }
            return false
        }
        if shouldFail {
            promise.fail(TransportError.cancelled)
        }
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

public struct CloudflareAccessResolvedCredentials: Equatable, Sendable {
    public let clientID: String
    public let clientSecret: String?

    public init(clientID: String, clientSecret: String? = nil) {
        self.clientID = clientID
        self.clientSecret = clientSecret
    }
}

public struct ResolvedTransportTarget: Equatable, Sendable {
    public let hostname: String
    public let port: UInt16
    public let username: String
    public let options: SSHOptions
    public let cloudflareHeaders: [String: String]?
    public let cloudflareCredentials: CloudflareAccessResolvedCredentials?
    public let tailscaleOptions: TailscaleOptions?
    public let cloudflareOptions: CloudflareAccessOptions?

    public init(
        hostname: String,
        port: UInt16,
        username: String,
        options: SSHOptions,
        cloudflareHeaders: [String: String]? = nil,
        cloudflareCredentials: CloudflareAccessResolvedCredentials? = nil,
        tailscaleOptions: TailscaleOptions? = nil,
        cloudflareOptions: CloudflareAccessOptions? = nil
    ) {
        self.hostname = hostname
        self.port = port
        self.username = username
        self.options = options
        self.cloudflareHeaders = cloudflareHeaders
        self.cloudflareCredentials = cloudflareCredentials
        self.tailscaleOptions = tailscaleOptions
        self.cloudflareOptions = cloudflareOptions
    }
}

public struct LiveSSHTransport: SSHTransport {
    public typealias HostResolver = @Sendable (UUID) async throws -> (ShhCore.Host, IdentityDescriptor?)
    public let credentialStore: any CredentialStore
    public let hostResolver: HostResolver?
    public let keepaliveInterval: TimeInterval
    public let keepaliveTimeout: TimeInterval
    private let customGroup: EventLoopGroup?

    public init(
        credentialStore: any CredentialStore = KeychainCredentialStore(),
        hostResolver: HostResolver? = nil,
        keepaliveInterval: TimeInterval = 30.0,
        keepaliveTimeout: TimeInterval = 8.0
    ) {
        self.credentialStore = credentialStore
        self.hostResolver = hostResolver
        self.keepaliveInterval = max(0, keepaliveInterval)
        self.keepaliveTimeout = max(0.1, keepaliveTimeout)
        self.customGroup = nil
    }

    init(
        credentialStore: any CredentialStore,
        hostResolver: HostResolver? = nil,
        group: EventLoopGroup?,
        keepaliveInterval: TimeInterval = 30.0,
        keepaliveTimeout: TimeInterval = 8.0
    ) {
        self.credentialStore = credentialStore
        self.hostResolver = hostResolver
        self.keepaliveInterval = max(0, keepaliveInterval)
        self.keepaliveTimeout = max(0.1, keepaliveTimeout)
        self.customGroup = group
    }

    public func connect(
        host: ShhCore.Host,
        identity: IdentityDescriptor?,
        trustEvaluator: any HostTrustEvaluator,
        initialSize: TerminalSize = TerminalSize(columns: 80, rows: 24)
    ) async throws -> any SSHConnection {
        switch host.connection {
        case .ssh(let options):
            return try await performConnectWithTimeout(
                host: host,
                identity: identity,
                trustEvaluator: trustEvaluator,
                initialSize: initialSize,
                options: options
            )
        case .proxyJump(let jumpOptions):
            var resolvedHops: [(ShhCore.Host, IdentityDescriptor?)] = []
            if !jumpOptions.config.hops.isEmpty {
                for hop in jumpOptions.config.hops {
                    switch hop {
                    case .hostID(let id):
                        guard let hostResolver else { throw TransportError.unsupported }
                        let resolved = try await hostResolver(id)
                        resolvedHops.append(resolved)
                    case .endpoint(let ep):
                        let epHost = try ShhCore.Host(
                            name: ep.hostname,
                            hostname: ep.hostname,
                            port: ep.port,
                            username: ep.username,
                            identityID: ep.identityID
                        )
                        var epIdent: IdentityDescriptor? = nil
                        if let idID = ep.identityID, let hostResolver {
                            let (_, resolvedIdent) = try await hostResolver(idID)
                            epIdent = resolvedIdent
                        }
                        resolvedHops.append((epHost, epIdent))
                    }
                }
            } else if !jumpOptions.hopHostIDs.isEmpty {
                guard let hostResolver else { throw TransportError.unsupported }
                for hopID in jumpOptions.hopHostIDs {
                    let resolved = try await hostResolver(hopID)
                    resolvedHops.append(resolved)
                }
            }

            if resolvedHops.isEmpty {
                return try await performConnectWithTimeout(
                    host: host,
                    identity: identity,
                    trustEvaluator: trustEvaluator,
                    initialSize: initialSize,
                    options: jumpOptions.sshOptions
                )
            } else {
                return try await performConnectProxyJumpWithTimeout(
                    hops: resolvedHops,
                    target: host,
                    targetIdentity: identity,
                    trustEvaluator: trustEvaluator,
                    initialSize: initialSize,
                    options: jumpOptions.sshOptions
                )
            }
        case .mosh:
            let moshTransport: any SSHTransport = LiveMoshTransport(sshTransport: self)
            return try await moshTransport.connect(
                host: host,
                identity: identity,
                trustEvaluator: trustEvaluator,
                initialSize: initialSize
            )
        case .cloudflareAccess(let cfOptions):
            let target = try await resolveTransportTarget(for: host)
            let effectiveHost = try ShhCore.Host(
                id: host.id,
                name: host.name,
                hostname: target.hostname,
                port: target.port,
                username: host.username,
                groupID: host.groupID,
                tagIDs: host.tagIDs,
                identityID: host.identityID,
                connection: .cloudflareAccess(cfOptions),
                health: host.health,
                lastUsedAt: host.lastUsedAt,
                tmuxPreferences: host.tmuxPreferences,
                voicePolicy: host.voicePolicy,
                isProduction: host.isProduction,
                forwardingRules: host.forwardingRules
            )
            return try await performConnectWithTimeout(
                host: effectiveHost,
                identity: identity,
                trustEvaluator: trustEvaluator,
                initialSize: initialSize,
                options: target.options,
                additionalSecretRefs: [cfOptions.clientSecretKeychainRef]
            )
        case .tailscale(let tsOptions):
            let target = try await resolveTransportTarget(for: host)
            let effectiveHost = try ShhCore.Host(
                id: host.id,
                name: host.name,
                hostname: target.hostname,
                port: target.port,
                username: host.username,
                groupID: host.groupID,
                tagIDs: host.tagIDs,
                identityID: host.identityID,
                connection: .tailscale(tsOptions),
                health: host.health,
                lastUsedAt: host.lastUsedAt,
                tmuxPreferences: host.tmuxPreferences,
                voicePolicy: host.voicePolicy,
                isProduction: host.isProduction,
                forwardingRules: host.forwardingRules
            )
            return try await performConnectWithTimeout(
                host: effectiveHost,
                identity: identity,
                trustEvaluator: trustEvaluator,
                initialSize: initialSize,
                options: target.options
            )
        }
    }

    public func connectProxyJump(
        hops: [(ShhCore.Host, IdentityDescriptor?)],
        target: ShhCore.Host,
        targetIdentity: IdentityDescriptor?,
        trustEvaluator: any HostTrustEvaluator,
        initialSize: TerminalSize = TerminalSize(columns: 80, rows: 24),
        options: SSHOptions? = nil
    ) async throws -> any SSHConnection {
        let effectiveOptions: SSHOptions
        if let options {
            effectiveOptions = options
        } else if case .ssh(let opts) = target.connection {
            effectiveOptions = opts
        } else if case .proxyJump(let jumpOpts) = target.connection {
            effectiveOptions = jumpOpts.sshOptions
        } else if case .cloudflareAccess = target.connection {
            effectiveOptions = SSHOptions()
        } else if case .tailscale(let tsOpts) = target.connection {
            effectiveOptions = SSHOptions(strictHostKeyChecking: tsOpts.checkHostKey ? .trustedOnly : .prompt)
        } else {
            effectiveOptions = SSHOptions()
        }

        if hops.isEmpty {
            return try await connect(
                host: target,
                identity: targetIdentity,
                trustEvaluator: trustEvaluator,
                initialSize: initialSize
            )
        }

        return try await performConnectProxyJumpWithTimeout(
            hops: hops,
            target: target,
            targetIdentity: targetIdentity,
            trustEvaluator: trustEvaluator,
            initialSize: initialSize,
            options: effectiveOptions
        )
    }

    public func resolveTransportTarget(for host: ShhCore.Host) async throws -> ResolvedTransportTarget {
        try await Self.resolveTransportTarget(for: host, credentialStore: credentialStore)
    }

    public static func resolveTransportTarget(
        for host: ShhCore.Host,
        credentialStore: (any CredentialStore)? = nil
    ) async throws -> ResolvedTransportTarget {
        switch host.connection {
        case .ssh(let opts):
            return ResolvedTransportTarget(
                hostname: host.hostname,
                port: host.port,
                username: host.username,
                options: opts
            )
        case .proxyJump(let jumpOpts):
            return ResolvedTransportTarget(
                hostname: host.hostname,
                port: host.port,
                username: host.username,
                options: jumpOpts.sshOptions
            )
        case .mosh(let moshOpts):
            return ResolvedTransportTarget(
                hostname: host.hostname,
                port: host.port,
                username: host.username,
                options: moshOpts.sshOptions
            )
        case .tailscale(let tsOpts):
            let trimmed = tsOpts.tailscaleHostname.trimmingCharacters(in: .whitespacesAndNewlines)
            let resolvedHostname = trimmed.isEmpty ? host.hostname : trimmed
            let resolvedPort = host.port != 0 ? host.port : 22
            let effectiveOptions = SSHOptions(
                strictHostKeyChecking: tsOpts.checkHostKey ? .trustedOnly : .prompt
            )
            return ResolvedTransportTarget(
                hostname: resolvedHostname,
                port: resolvedPort,
                username: host.username,
                options: effectiveOptions,
                tailscaleOptions: tsOpts
            )
        case .cloudflareAccess(let cfOpts):
            let trimmed = cfOpts.tunnelDomain.trimmingCharacters(in: .whitespacesAndNewlines)
            let resolvedHostname = trimmed.isEmpty ? host.hostname : trimmed
            let resolvedPort = host.port != 0 ? host.port : 22

            var headers: [String: String] = [:]
            var secretString: String? = nil

            if !cfOpts.clientID.isEmpty {
                headers["CF-Access-Client-Id"] = cfOpts.clientID
            }

            if let store = credentialStore, !cfOpts.clientSecretKeychainRef.isEmpty {
                if let secretData = try? await store.load(reference: cfOpts.clientSecretKeychainRef),
                   let secret = String(data: secretData, encoding: .utf8),
                   !secret.isEmpty {
                    secretString = secret
                    headers["CF-Access-Client-Secret"] = secret
                }
            }

            let credentials = CloudflareAccessResolvedCredentials(
                clientID: cfOpts.clientID,
                clientSecret: secretString
            )

            return ResolvedTransportTarget(
                hostname: resolvedHostname,
                port: resolvedPort,
                username: host.username,
                options: SSHOptions(),
                cloudflareHeaders: headers.isEmpty ? nil : headers,
                cloudflareCredentials: credentials,
                cloudflareOptions: cfOpts
            )
        }
    }

    private func performConnectWithTimeout(
        host: ShhCore.Host,
        identity: IdentityDescriptor?,
        trustEvaluator: any HostTrustEvaluator,
        initialSize: TerminalSize,
        options: SSHOptions,
        additionalSecretRefs: [String] = []
    ) async throws -> any SSHConnection {
        do {
            if options.connectTimeoutSeconds > 0 {
                return try await withThrowingTaskGroup(of: (any SSHConnection).self) { group in
                    group.addTask {
                        try await self.performConnect(
                            host: host,
                            identity: identity,
                            trustEvaluator: trustEvaluator,
                            initialSize: initialSize,
                            options: options,
                            additionalSecretRefs: additionalSecretRefs
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
                    options: options,
                    additionalSecretRefs: additionalSecretRefs
                )
            }
        } catch {
            if Task.isCancelled || error is CancellationError {
                throw TransportError.cancelled
            }
            throw error
        }
    }

    private func performConnectProxyJumpWithTimeout(
        hops: [(ShhCore.Host, IdentityDescriptor?)],
        target: ShhCore.Host,
        targetIdentity: IdentityDescriptor?,
        trustEvaluator: any HostTrustEvaluator,
        initialSize: TerminalSize,
        options: SSHOptions
    ) async throws -> any SSHConnection {
        do {
            if options.connectTimeoutSeconds > 0 {
                return try await withThrowingTaskGroup(of: (any SSHConnection).self) { group in
                    group.addTask {
                        try await self.performConnectProxyJump(
                            hops: hops,
                            target: target,
                            targetIdentity: targetIdentity,
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
                return try await performConnectProxyJump(
                    hops: hops,
                    target: target,
                    targetIdentity: targetIdentity,
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
        options: SSHOptions,
        additionalSecretRefs: [String] = []
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
                .channelOption(ChannelOptions.socket(SocketOptionLevel(SOL_SOCKET), SO_KEEPALIVE), value: 1)
                .channelOption(ChannelOptions.socket(SocketOptionLevel(IPPROTO_TCP), TCP_NODELAY), value: 1)

            if options.connectTimeoutSeconds > 0 {
                bootstrap = bootstrap.connectTimeout(.milliseconds(Int64(options.connectTimeoutSeconds * 1000)))
            }

            let handshakePromise = eventLoopGroup.next().makePromise(of: Void.self)
            let handshakeHandler = LiveSSHHandshakeHandler(promise: handshakePromise)
            defer {
                handshakeHandler.fail(TransportError.cancelled)
            }

            let inboundRouter = InboundChildChannelRouter()
            bootstrap = bootstrap.channelInitializer { channel in
                let sshHandler = NIOSSHHandler(
                    role: .client(clientConfig),
                    allocator: channel.allocator,
                    inboundChildChannelInitializer: { [weak inboundRouter] childChannel, channelType in
                        guard let inboundRouter else { return childChannel.close() }
                        return inboundRouter.handle(childChannel: childChannel, type: channelType)
                    }
                )
                return channel.pipeline.addHandler(sshHandler).flatMap {
                    channel.pipeline.addHandler(handshakeHandler)
                }
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
                    childPromise.futureResult.whenFailure { error in
                        handlerPromise.fail(error)
                    }
                    sshHandler.createChannel(childPromise, channelType: .session) { newChildChannel, channelType in
                        guard channelType == .session else {
                            handlerPromise.fail(TransportError.remoteFailure("Unexpected channel type: \(channelType)"))
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

            var redactionSecrets: [String] = []
            if let identity = identity,
               let secretData = try? await credentialStore.load(reference: identity.keychainReference),
               let secretString = String(data: secretData, encoding: .utf8),
               !secretString.isEmpty {
                redactionSecrets.append(secretString)
            }
            for ref in additionalSecretRefs {
                if !ref.isEmpty,
                   let secretData = try? await credentialStore.load(reference: ref),
                   let secretString = String(data: secretData, encoding: .utf8),
                   !secretString.isEmpty {
                    redactionSecrets.append(secretString)
                }
            }
            let redactor = Redactor(secrets: redactionSecrets)

            let connection = LiveSSHConnection(
                childChannel: childChannel,
                parentChannel: channel,
                hopChannels: [channel],
                eventLoopGroup: eventLoopGroup,
                ownsGroup: ownsGroup,
                redactor: redactor,
                inboundRouter: inboundRouter
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

            connection.startSSHKeepalive(interval: keepaliveInterval, timeout: keepaliveTimeout)
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
            throw Self.mapError(error)
        }
    }

    private func performConnectProxyJump(
        hops: [(ShhCore.Host, IdentityDescriptor?)],
        target: ShhCore.Host,
        targetIdentity: IdentityDescriptor?,
        trustEvaluator: any HostTrustEvaluator,
        initialSize: TerminalSize,
        options: SSHOptions
    ) async throws -> any SSHConnection {
        if Task.isCancelled { throw TransportError.cancelled }

        let ownsGroup = (customGroup == nil)
        let eventLoopGroup = customGroup ?? MultiThreadedEventLoopGroup(numberOfThreads: 1)

        var openedChannels: [Channel] = []
        var redactionSecrets: [String] = []
        var lastValidator: HostKeyValidatorDelegate?
        var createdConnection: LiveSSHConnection?

        do {
            guard let firstHop = hops.first else {
                throw TransportError.unsupported
            }

            // Hop 1: Direct TCP bootstrap
            let (b1Host, b1Identity) = firstHop
            let b1Validator = HostKeyValidatorDelegate(
                hostname: b1Host.hostname,
                port: b1Host.port,
                strictChecking: options.strictHostKeyChecking,
                trustEvaluator: trustEvaluator
            )
            lastValidator = b1Validator

            let credStore = self.credentialStore
            let b1AuthDelegate = LiveSSHUserAuthDelegate(
                username: b1Host.username,
                resolveCredential: {
                    try await Self.resolveAuthenticationCredential(identity: b1Identity, credentialStore: credStore)
                }
            )

            let b1Config = SSHClientConfiguration(
                userAuthDelegate: b1AuthDelegate,
                serverAuthDelegate: b1Validator
            )

            var bootstrap = ClientBootstrap(group: eventLoopGroup)
                .channelOption(ChannelOptions.socket(SocketOptionLevel(SOL_SOCKET), SO_REUSEADDR), value: 1)
                .channelOption(ChannelOptions.socket(SocketOptionLevel(SOL_SOCKET), SO_KEEPALIVE), value: 1)
                .channelOption(ChannelOptions.socket(SocketOptionLevel(IPPROTO_TCP), TCP_NODELAY), value: 1)

            if options.connectTimeoutSeconds > 0 {
                bootstrap = bootstrap.connectTimeout(.milliseconds(Int64(options.connectTimeoutSeconds * 1000)))
            }

            let b1HandshakePromise = eventLoopGroup.next().makePromise(of: Void.self)
            let b1HandshakeHandler = LiveSSHHandshakeHandler(promise: b1HandshakePromise)
            defer {
                b1HandshakeHandler.fail(TransportError.cancelled)
            }

            bootstrap = bootstrap.channelInitializer { channel in
                let sshHandler = NIOSSHHandler(
                    role: .client(b1Config),
                    allocator: channel.allocator,
                    inboundChildChannelInitializer: nil
                )
                return channel.pipeline.addHandler(sshHandler).flatMap {
                    channel.pipeline.addHandler(b1HandshakeHandler)
                }
            }

            let b1Channel = try await withTaskCancellationHandler {
                try await bootstrap.connect(host: b1Host.hostname, port: Int(b1Host.port)).get()
            } onCancel: {}
            openedChannels.append(b1Channel)

            if Task.isCancelled { throw TransportError.cancelled }

            b1Channel.closeFuture.whenComplete { _ in
                b1HandshakeHandler.fail(TransportError.remoteFailure("Bastion connection closed before handshake"))
            }

            try await withTaskCancellationHandler {
                try await b1HandshakePromise.futureResult.get()
            } onCancel: {
                b1HandshakeHandler.fail(TransportError.cancelled)
                _ = b1Channel.close()
            }

            if let captured = b1Validator.capturedError {
                throw captured
            }

            if let b1Identity = b1Identity,
               let secretData = try? await credentialStore.load(reference: b1Identity.keychainReference),
               let secretString = String(data: secretData, encoding: .utf8),
               !secretString.isEmpty {
                redactionSecrets.append(secretString)
            }

            var currentChannel = b1Channel

            // Intermediate hops: Bastion 2, Bastion 3, etc.
            if hops.count > 1 {
                for i in 1..<hops.count {
                    if Task.isCancelled { throw TransportError.cancelled }

                    let (hopHost, hopIdentity) = hops[i]
                    let hopValidator = HostKeyValidatorDelegate(
                        hostname: hopHost.hostname,
                        port: hopHost.port,
                        strictChecking: options.strictHostKeyChecking,
                        trustEvaluator: trustEvaluator
                    )
                    lastValidator = hopValidator

                    let hopAuthDelegate = LiveSSHUserAuthDelegate(
                        username: hopHost.username,
                        resolveCredential: {
                            try await Self.resolveAuthenticationCredential(identity: hopIdentity, credentialStore: credStore)
                        }
                    )

                    let hopConfig = SSHClientConfiguration(
                        userAuthDelegate: hopAuthDelegate,
                        serverAuthDelegate: hopValidator
                    )

                    let hopHandshakePromise = eventLoopGroup.next().makePromise(of: Void.self)
                    let hopHandshakeHandler = LiveSSHHandshakeHandler(promise: hopHandshakePromise)
                    defer {
                        hopHandshakeHandler.fail(TransportError.cancelled)
                    }

                    let defaultOrigin = try? SocketAddress(ipAddress: "127.0.0.1", port: 0)
                    let localOrigin = currentChannel.localAddress ?? defaultOrigin!
                    let directSettings = SSHChannelType.DirectTCPIP(
                        targetHost: hopHost.hostname,
                        targetPort: Int(hopHost.port),
                        originatorAddress: localOrigin
                    )

                    let nextChannel = try await currentChannel.eventLoop.flatSubmit {
                        currentChannel.pipeline.handler(type: NIOSSHHandler.self).flatMap { currentSSHHandler in
                            let childPromise = currentChannel.eventLoop.makePromise(of: Channel.self)
                            currentSSHHandler.createChannel(childPromise, channelType: .directTCPIP(directSettings)) { childChannel, channelType in
                                guard case .directTCPIP = channelType else {
                                    return childChannel.eventLoop.makeFailedFuture(TransportError.remoteFailure("Failed to open direct-tcpip channel for hop"))
                                }
                                let codec = DataToBufferCodec()
                                let nestedSSHHandler = NIOSSHHandler(
                                    role: .client(hopConfig),
                                    allocator: childChannel.allocator,
                                    inboundChildChannelInitializer: nil
                                )
                                return childChannel.pipeline.addHandler(codec).flatMap {
                                    childChannel.pipeline.addHandler(nestedSSHHandler)
                                }.flatMap {
                                    childChannel.pipeline.addHandler(hopHandshakeHandler)
                                }
                            }
                            return childPromise.futureResult
                        }
                    }.get()
                    openedChannels.append(nextChannel)

                    if Task.isCancelled { throw TransportError.cancelled }

                    nextChannel.closeFuture.whenComplete { _ in
                        hopHandshakeHandler.fail(TransportError.remoteFailure("Bastion hop connection closed before handshake"))
                    }

                    try await withTaskCancellationHandler {
                        try await hopHandshakePromise.futureResult.get()
                    } onCancel: {
                        hopHandshakeHandler.fail(TransportError.cancelled)
                        _ = nextChannel.close()
                    }

                    if let captured = hopValidator.capturedError {
                        throw captured
                    }

                    if let hopIdentity = hopIdentity,
                       let secretData = try? await credentialStore.load(reference: hopIdentity.keychainReference),
                       let secretString = String(data: secretData, encoding: .utf8),
                       !secretString.isEmpty {
                        redactionSecrets.append(secretString)
                    }

                    currentChannel = nextChannel
                }
            }

            // Target connection over direct-tcpip on the last bastion
            if Task.isCancelled { throw TransportError.cancelled }

            let targetValidator = HostKeyValidatorDelegate(
                hostname: target.hostname,
                port: target.port,
                strictChecking: options.strictHostKeyChecking,
                trustEvaluator: trustEvaluator
            )
            lastValidator = targetValidator

            let targetAuthDelegate = LiveSSHUserAuthDelegate(
                username: target.username,
                resolveCredential: {
                    try await Self.resolveAuthenticationCredential(identity: targetIdentity, credentialStore: credStore)
                }
            )

            let targetConfig = SSHClientConfiguration(
                userAuthDelegate: targetAuthDelegate,
                serverAuthDelegate: targetValidator
            )

            let targetHandshakePromise = eventLoopGroup.next().makePromise(of: Void.self)
            let targetHandshakeHandler = LiveSSHHandshakeHandler(promise: targetHandshakePromise)
            defer {
                targetHandshakeHandler.fail(TransportError.cancelled)
            }

            let targetInboundRouter = InboundChildChannelRouter()
            let defaultOrigin = try? SocketAddress(ipAddress: "127.0.0.1", port: 0)
            let localOrigin = currentChannel.localAddress ?? defaultOrigin!
            let targetDirectSettings = SSHChannelType.DirectTCPIP(
                targetHost: target.hostname,
                targetPort: Int(target.port),
                originatorAddress: localOrigin
            )

            let targetTransportChannel = try await currentChannel.eventLoop.flatSubmit {
                currentChannel.pipeline.handler(type: NIOSSHHandler.self).flatMap { currentSSHHandler in
                    let childPromise = currentChannel.eventLoop.makePromise(of: Channel.self)
                    currentSSHHandler.createChannel(childPromise, channelType: .directTCPIP(targetDirectSettings)) { childChannel, channelType in
                        guard case .directTCPIP = channelType else {
                            return childChannel.eventLoop.makeFailedFuture(TransportError.remoteFailure("Failed to open direct-tcpip channel for target"))
                        }
                        let codec = DataToBufferCodec()
                        let nestedSSHHandler = NIOSSHHandler(
                            role: .client(targetConfig),
                            allocator: childChannel.allocator,
                            inboundChildChannelInitializer: { [weak targetInboundRouter] child, type in
                                guard let targetInboundRouter else { return child.close() }
                                return targetInboundRouter.handle(childChannel: child, type: type)
                            }
                        )
                        return childChannel.pipeline.addHandler(codec).flatMap {
                            childChannel.pipeline.addHandler(nestedSSHHandler)
                        }.flatMap {
                            childChannel.pipeline.addHandler(targetHandshakeHandler)
                        }
                    }
                    return childPromise.futureResult
                }
            }.get()
            openedChannels.append(targetTransportChannel)

            if Task.isCancelled { throw TransportError.cancelled }

            targetTransportChannel.closeFuture.whenComplete { _ in
                targetHandshakeHandler.fail(TransportError.remoteFailure("Target connection closed before handshake"))
            }

            try await withTaskCancellationHandler {
                try await targetHandshakePromise.futureResult.get()
            } onCancel: {
                targetHandshakeHandler.fail(TransportError.cancelled)
                _ = targetTransportChannel.close()
            }

            if let captured = targetValidator.capturedError {
                throw captured
            }

            if let targetIdentity = targetIdentity,
               let secretData = try? await credentialStore.load(reference: targetIdentity.keychainReference),
               let secretString = String(data: secretData, encoding: .utf8),
               !secretString.isEmpty {
                redactionSecrets.append(secretString)
            }

            // Interactive session channel on target
            let router = InboundEventRouter()
            let (sessionChannel, sessionHandler) = try await targetTransportChannel.eventLoop.flatSubmit {
                targetTransportChannel.pipeline.handler(type: NIOSSHHandler.self).flatMap { targetSSHHandler in
                    let childPromise = targetTransportChannel.eventLoop.makePromise(of: Channel.self)
                    let handlerPromise = targetTransportChannel.eventLoop.makePromise(of: LiveSSHChildChannelHandler.self)
                    childPromise.futureResult.whenFailure { error in
                        handlerPromise.fail(error)
                    }
                    targetSSHHandler.createChannel(childPromise, channelType: .session) { newChildChannel, channelType in
                        guard channelType == .session else {
                            handlerPromise.fail(TransportError.remoteFailure("Unexpected channel type: \(channelType)"))
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

            let redactor = Redactor(secrets: redactionSecrets)
            let connection = LiveSSHConnection(
                childChannel: sessionChannel,
                parentChannel: targetTransportChannel,
                hopChannels: openedChannels,
                eventLoopGroup: eventLoopGroup,
                ownsGroup: ownsGroup,
                redactor: redactor,
                inboundRouter: targetInboundRouter
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
            let ptyPromise = sessionChannel.eventLoop.makePromise(of: Void.self)
            sessionHandler.addPendingReplyPromise(ptyPromise)
            try await sessionChannel.triggerUserOutboundEvent(ptyRequest).get()
            try await withTaskCancellationHandler {
                try await ptyPromise.futureResult.get()
            } onCancel: {
                _ = targetTransportChannel.close()
            }

            if Task.isCancelled { throw TransportError.cancelled }

            let shellRequest = SSHChannelRequestEvent.ShellRequest(wantReply: true)
            let shellPromise = sessionChannel.eventLoop.makePromise(of: Void.self)
            sessionHandler.addPendingReplyPromise(shellPromise)
            try await sessionChannel.triggerUserOutboundEvent(shellRequest).get()
            try await withTaskCancellationHandler {
                try await shellPromise.futureResult.get()
            } onCancel: {
                _ = targetTransportChannel.close()
            }

            connection.startSSHKeepalive(interval: keepaliveInterval, timeout: keepaliveTimeout)
            return connection
        } catch {
            if let createdConnection {
                await createdConnection.close()
            } else {
                for ch in openedChannels.reversed() {
                    _ = try? await ch.close().get()
                }
                if ownsGroup {
                    try? await eventLoopGroup.shutdownGracefully()
                }
            }
            if let captured = lastValidator?.capturedError {
                throw captured
            }
            throw Self.mapError(error)
        }
    }

    static func resolveAuthenticationCredential(
        identity: IdentityDescriptor?,
        credentialStore: any CredentialStore
    ) async throws -> LiveSSHUserAuthDelegate.Credential {
        guard let identity else {
            return .none
        }

        switch identity.kind {
        case .password:
            let data: Data
            do {
                data = try await credentialStore.load(reference: identity.keychainReference)
            } catch {
                throw TransportError.missingCredential(reference: identity.keychainReference)
            }
            guard let password = String(data: data, encoding: .utf8), !password.isEmpty else {
                throw TransportError.authenticationRequired
            }
            return .password(password)
        case .privateKey:
            let data: Data
            do {
                data = try await credentialStore.load(reference: identity.keychainReference)
            } catch {
                throw TransportError.missingCredential(reference: identity.keychainReference)
            }
            do {
                let privateKey = try Ed25519Parser.parse(from: data)
                return .privateKey(privateKey)
            } catch {
                throw TransportError.invalidPrivateKey(detail: "Failed to parse Ed25519 private key from credential")
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

    static func mapError(_ error: Error) -> TransportError {
        if let transportError = error as? TransportError {
            return transportError
        }
        if Task.isCancelled || error is CancellationError {
            return .cancelled
        }

        if let channelError = error as? ChannelError {
            switch channelError {
            case .connectTimeout:
                return .timeout
            default:
                break
            }
        }

        if let posixError = error as? POSIXError {
            switch posixError.code {
            case .ECONNREFUSED:
                return .connectionRefused
            case .EHOSTUNREACH, .ENETUNREACH, .ENETDOWN:
                return .networkUnavailable
            case .ETIMEDOUT:
                return .timeout
            default:
                break
            }
        }

        let description = error.localizedDescription.lowercased()

        if description.contains("timed out") || description.contains("timeout") {
            return .timeout
        }

        if description.contains("connection refused") {
            return .connectionRefused
        }

        if description.contains("nodename nor servname") ||
            description.contains("unknownhost") ||
            description.contains("hostname could not be resolved") ||
            description.contains("name resolution") ||
            description.contains("eai_") ||
            description.contains("no address associated") {
            return .dnsFailure("DNS resolution failed for hostname")
        }

        if description.contains("unreachable") || description.contains("network is down") || description.contains("network unreachable") {
            return .networkUnavailable
        }

        if description.contains("authentication") || description.contains("auth failed") || description.contains("permission denied") {
            return .authenticationRequired
        }

        let safeMessage = Redactor().redact(error.localizedDescription)
        return .remoteFailure(safeMessage)
    }
}
