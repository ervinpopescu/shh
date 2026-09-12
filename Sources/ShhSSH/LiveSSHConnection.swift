import Foundation
import NIOCore
@preconcurrency import NIOSSH
import ShhCore

public final class LiveSSHConnection: SSHConnection, SSHCommandExecuting, @unchecked Sendable {
    private let childChannel: Channel
    private let parentChannel: Channel
    private let hopChannels: [Channel]
    private let eventLoopGroup: EventLoopGroup?
    private let ownsGroup: Bool
    private let inboundRouter: InboundChildChannelRouter?
    private let lock = NSLock()
    private var isClosed = false
    private var bufferedData: [Data] = []
    private var continuations: [UUID: AsyncThrowingStream<TerminalEvent, Error>.Continuation] = [:]
    private var activeExecChannels: [UUID: Channel] = [:]
    private var activeForwardedChannels: [UUID: Channel] = [:]
    private var redactor: Redactor

    public var eventLoop: EventLoop { parentChannel.eventLoop }
    public var group: EventLoopGroup { eventLoopGroup ?? parentChannel.eventLoop }

    init(
        childChannel: Channel,
        parentChannel: Channel,
        hopChannels: [Channel] = [],
        eventLoopGroup: EventLoopGroup?,
        ownsGroup: Bool,
        redactor: Redactor = Redactor(),
        inboundRouter: InboundChildChannelRouter? = nil
    ) {
        self.childChannel = childChannel
        self.parentChannel = parentChannel
        self.hopChannels = hopChannels
        self.eventLoopGroup = eventLoopGroup
        self.ownsGroup = ownsGroup
        self.redactor = redactor
        self.inboundRouter = inboundRouter
    }

    public func setRedactor(_ redactor: Redactor) {
        lock.withLock {
            self.redactor = redactor
        }
    }

    public func events() async -> AsyncThrowingStream<TerminalEvent, Error> {
        let id = UUID()
        return AsyncThrowingStream { continuation in
            let (alreadyClosed, pendingData): (Bool, [Data]) = self.lock.withLock {
                if self.isClosed {
                    return (true, [])
                }
                self.continuations[id] = continuation
                let data = self.bufferedData
                self.bufferedData.removeAll()
                return (false, data)
            }

            if alreadyClosed {
                continuation.yield(.closed)
                continuation.finish()
                return
            }

            for chunk in pendingData {
                continuation.yield(.bytes(chunk))
            }

            continuation.onTermination = { [weak self] _ in
                self?.removeContinuation(id: id)
            }
        }
    }

    public func send(_ data: Data) async throws {
        let closed: Bool = lock.withLock { isClosed }
        guard !closed else {
            throw TransportError.remoteFailure("SSH connection is closed")
        }

        var buffer = childChannel.allocator.buffer(capacity: data.count)
        buffer.writeBytes(data)
        let channelData = SSHChannelData(type: .channel, data: .byteBuffer(buffer))

        do {
            try await childChannel.writeAndFlush(channelData)
        } catch {
            throw TransportError.remoteFailure("Failed to send data: \(error.localizedDescription)")
        }
    }

    public func resize(_ size: TerminalSize) async throws {
        let closed: Bool = lock.withLock { isClosed }
        guard !closed else {
            throw TransportError.remoteFailure("SSH connection is closed")
        }

        let request = SSHChannelRequestEvent.WindowChangeRequest(
            terminalCharacterWidth: size.columns,
            terminalRowHeight: size.rows,
            terminalPixelWidth: 0,
            terminalPixelHeight: 0
        )

        do {
            try await childChannel.triggerUserOutboundEvent(request).get()
        } catch {
            throw TransportError.remoteFailure("Failed to resize terminal: \(error.localizedDescription)")
        }
    }

    public func executeCommand(_ command: String) async throws -> SSHCommandResult {
        try await executeCommand(command, timeout: 15.0, maxOutputBytes: 1_048_576)
    }

    public func executeCommand(
        _ command: String,
        timeout: TimeInterval?,
        maxOutputBytes: Int?
    ) async throws -> SSHCommandResult {
        let effectiveTimeout = timeout ?? 15.0
        let effectiveMaxBytes = maxOutputBytes ?? 1_048_576

        let (closed, activeRedactor): (Bool, Redactor) = lock.withLock { (isClosed, redactor) }
        guard !closed else {
            throw TransportError.remoteFailure(activeRedactor.redact("SSH connection is closed"))
        }

        if Task.isCancelled {
            throw TransportError.cancelled
        }

        let promise = parentChannel.eventLoop.makePromise(of: SSHCommandResult.self)
        let handlerPromise = parentChannel.eventLoop.makePromise(of: LiveSSHExecChannelHandler.self)
        let childPromise = parentChannel.eventLoop.makePromise(of: Channel.self)

        let execChannel: Channel
        let execHandler: LiveSSHExecChannelHandler
        do {
            (execChannel, execHandler) = try await parentChannel.eventLoop.flatSubmit {
                self.parentChannel.pipeline.handler(type: NIOSSHHandler.self).flatMap { sshHandler in
                    sshHandler.createChannel(childPromise, channelType: .session) { newChildChannel, channelType in
                        guard channelType == .session else {
                            return newChildChannel.close()
                        }
                        let handler = LiveSSHExecChannelHandler(
                            allocator: newChildChannel.allocator,
                            promise: promise,
                            maxOutputBytes: effectiveMaxBytes
                        )
                        handlerPromise.succeed(handler)
                        _ = newChildChannel.setOption(ChannelOptions.allowRemoteHalfClosure, value: true)
                        return newChildChannel.pipeline.addHandler(handler)
                    }
                    return childPromise.futureResult.flatMap { child in
                        handlerPromise.futureResult.map { handler in (child, handler) }
                    }
                }
            }.get()
        } catch {
            throw TransportError.remoteFailure(activeRedactor.redact("Failed to create SSH exec channel: \(error.localizedDescription)"))
        }

        let execID = UUID()
        let registerSuccess: Bool = lock.withLock {
            if self.isClosed {
                return false
            }
            self.activeExecChannels[execID] = execChannel
            return true
        }

        guard registerSuccess else {
            execHandler.failAndClose(TransportError.remoteFailure("SSH connection is closed"))
            throw TransportError.remoteFailure(activeRedactor.redact("SSH connection is closed"))
        }

        defer {
            lock.withLock {
                _ = self.activeExecChannels.removeValue(forKey: execID)
            }
        }

        let execRequest = SSHChannelRequestEvent.ExecRequest(command: command, wantReply: true)
        do {
            try await execChannel.triggerUserOutboundEvent(execRequest).get()
        } catch {
            execHandler.failAndClose(error)
            throw TransportError.remoteFailure(activeRedactor.redact("Failed to send exec request: \(error.localizedDescription)"))
        }

        do {
            let result = try await withTaskCancellationHandler {
                try await withThrowingTaskGroup(of: SSHCommandResult.self) { group in
                    group.addTask {
                        try await promise.futureResult.get()
                    }
                    if effectiveTimeout > 0 {
                        group.addTask {
                            try await Task.sleep(nanoseconds: UInt64(effectiveTimeout * 1_000_000_000))
                            throw TransportError.timeout
                        }
                    }
                    let first = try await group.next()!
                    group.cancelAll()
                    return first
                }
            } onCancel: {
                execHandler.failAndClose(TransportError.cancelled)
            }

            let currentRedactor = lock.withLock { self.redactor }
            return SSHCommandResult(
                exitCode: result.exitCode,
                stdout: result.stdout,
                stderr: currentRedactor.redact(result.stderr)
            )
        } catch let error as TransportError {
            execHandler.failAndClose(error)
            let currentRedactor = lock.withLock { self.redactor }
            switch error {
            case .remoteFailure(let message):
                throw TransportError.remoteFailure(currentRedactor.redact(message))
            default:
                throw error
            }
        } catch is CancellationError {
            execHandler.failAndClose(TransportError.cancelled)
            throw TransportError.cancelled
        } catch {
            execHandler.failAndClose(error)
            let currentRedactor = lock.withLock { self.redactor }
            throw TransportError.remoteFailure(currentRedactor.redact(error.localizedDescription))
        }
    }

    public func createDirectTCPIPChannel(
        targetHost: String,
        targetPort: Int,
        originatorAddress: SocketAddress? = nil
    ) async throws -> Channel {
        let closed: Bool = lock.withLock { isClosed }
        guard !closed else {
            throw TransportError.remoteFailure("SSH connection is closed")
        }

        let defaultOrigin = try? SocketAddress(ipAddress: "127.0.0.1", port: 0)
        let origin = originatorAddress ?? parentChannel.localAddress ?? defaultOrigin!

        let channel = try await parentChannel.eventLoop.flatSubmit {
            self.parentChannel.pipeline.handler(type: NIOSSHHandler.self).flatMap { sshHandler in
                let childPromise = self.parentChannel.eventLoop.makePromise(of: Channel.self)
                let direct = SSHChannelType.DirectTCPIP(
                    targetHost: targetHost,
                    targetPort: targetPort,
                    originatorAddress: origin
                )
                sshHandler.createChannel(childPromise, channelType: .directTCPIP(direct)) { childChannel, channelType in
                    guard case .directTCPIP = channelType else {
                        return childChannel.eventLoop.makeFailedFuture(TransportError.remoteFailure("Invalid channel type created"))
                    }
                    return childChannel.pipeline.addHandler(DataToBufferCodec())
                }
                return childPromise.futureResult
            }
        }.get()

        let id = UUID()
        lock.withLock {
            self.activeForwardedChannels[id] = channel
        }
        channel.closeFuture.whenComplete { [weak self] _ in
            self?.lock.withLock {
                _ = self?.activeForwardedChannels.removeValue(forKey: id)
            }
        }
        return channel
    }

    public func requestRemoteForwarding(
        bindHost: String,
        bindPort: Int
    ) async throws -> Int? {
        let closed: Bool = lock.withLock { isClosed }
        guard !closed else {
            throw TransportError.remoteFailure("SSH connection is closed")
        }

        return try await parentChannel.eventLoop.flatSubmit {
            self.parentChannel.pipeline.handler(type: NIOSSHHandler.self).flatMap { sshHandler in
                let promise = self.parentChannel.eventLoop.makePromise(of: GlobalRequest.TCPForwardingResponse?.self)
                sshHandler.sendTCPForwardingRequest(.listen(host: bindHost, port: bindPort), promise: promise)
                return promise.futureResult.map { response in
                    response?.boundPort
                }
            }
        }.get()
    }

    public func cancelRemoteForwarding(
        bindHost: String,
        bindPort: Int
    ) async throws {
        let closed: Bool = lock.withLock { isClosed }
        guard !closed else { return }

        try await parentChannel.eventLoop.flatSubmit {
            self.parentChannel.pipeline.handler(type: NIOSSHHandler.self).flatMap { sshHandler in
                let promise = self.parentChannel.eventLoop.makePromise(of: GlobalRequest.TCPForwardingResponse?.self)
                sshHandler.sendTCPForwardingRequest(.cancel(host: bindHost, port: bindPort), promise: promise)
                return promise.futureResult.map { _ in () }
            }
        }.get()
    }

    public func registerForwardedTCPIPHandler(
        _ handler: @escaping @Sendable (Channel, SSHChannelType.ForwardedTCPIP) -> EventLoopFuture<Void>
    ) {
        inboundRouter?.register(handler)
    }

    func trackForwardedChannel(_ channel: Channel) -> UUID {
        let id = UUID()
        lock.withLock {
            self.activeForwardedChannels[id] = channel
        }
        channel.closeFuture.whenComplete { [weak self] _ in
            self?.lock.withLock {
                _ = self?.activeForwardedChannels.removeValue(forKey: id)
            }
        }
        return id
    }

    public func close() async {
        let (activeContinuations, activeChannels, forwardedChannels, shouldClose): (
            [AsyncThrowingStream<TerminalEvent, Error>.Continuation],
            [Channel],
            [Channel],
            Bool
        ) = lock.withLock {
            guard !isClosed else { return ([], [], [], false) }
            isClosed = true
            let list = Array(continuations.values)
            continuations.removeAll()
            bufferedData.removeAll()
            let execs = Array(activeExecChannels.values)
            activeExecChannels.removeAll()
            let fwds = Array(activeForwardedChannels.values)
            activeForwardedChannels.removeAll()
            return (list, execs, fwds, true)
        }

        for continuation in activeContinuations {
            continuation.yield(.closed)
            continuation.finish()
        }

        for execChannel in activeChannels {
            _ = try? await execChannel.close().get()
        }

        for forwardedChannel in forwardedChannels {
            _ = try? await forwardedChannel.close().get()
        }

        guard shouldClose else { return }

        _ = try? await childChannel.close().get()
        _ = try? await parentChannel.close().get()

        for hopChannel in hopChannels.reversed() {
            _ = try? await hopChannel.close().get()
        }

        if ownsGroup, let group = eventLoopGroup {
            try? await group.shutdownGracefully()
        }
    }

    func handleInboundData(_ data: Data) {
        let activeContinuations: [AsyncThrowingStream<TerminalEvent, Error>.Continuation] = lock.withLock {
            if isClosed { return [] }
            if continuations.isEmpty {
                bufferedData.append(data)
                return []
            }
            return Array(continuations.values)
        }

        for continuation in activeContinuations {
            continuation.yield(.bytes(data))
        }
    }

    func handleChannelClosed() {
        let (activeContinuations, activeChannels, forwardedChannels, shouldClose): (
            [AsyncThrowingStream<TerminalEvent, Error>.Continuation],
            [Channel],
            [Channel],
            Bool
        ) = lock.withLock {
            guard !isClosed else { return ([], [], [], false) }
            isClosed = true
            let list = Array(continuations.values)
            continuations.removeAll()
            bufferedData.removeAll()
            let execs = Array(activeExecChannels.values)
            activeExecChannels.removeAll()
            let fwds = Array(activeForwardedChannels.values)
            activeForwardedChannels.removeAll()
            return (list, execs, fwds, true)
        }

        for continuation in activeContinuations {
            continuation.yield(.closed)
            continuation.finish()
        }

        for execChannel in activeChannels {
            execChannel.close(promise: nil)
        }

        for forwardedChannel in forwardedChannels {
            forwardedChannel.close(promise: nil)
        }

        guard shouldClose else { return }

        let hops = hopChannels
        Task {
            _ = try? await self.parentChannel.close().get()
            for hop in hops.reversed() {
                _ = try? await hop.close().get()
            }
            if self.ownsGroup, let group = self.eventLoopGroup {
                try? await group.shutdownGracefully()
            }
        }
    }

    func handleChannelError(_ error: Error) {
        let (activeContinuations, activeChannels, forwardedChannels, shouldClose): (
            [AsyncThrowingStream<TerminalEvent, Error>.Continuation],
            [Channel],
            [Channel],
            Bool
        ) = lock.withLock {
            guard !isClosed else { return ([], [], [], false) }
            isClosed = true
            let list = Array(continuations.values)
            continuations.removeAll()
            bufferedData.removeAll()
            let execs = Array(activeExecChannels.values)
            activeExecChannels.removeAll()
            let fwds = Array(activeForwardedChannels.values)
            activeForwardedChannels.removeAll()
            return (list, execs, fwds, true)
        }

        for execChannel in activeChannels {
            execChannel.close(promise: nil)
        }

        for forwardedChannel in forwardedChannels {
            forwardedChannel.close(promise: nil)
        }

        let transportError = (error as? TransportError) ?? TransportError.remoteFailure(error.localizedDescription)
        for continuation in activeContinuations {
            continuation.yield(.error(transportError))
            continuation.finish(throwing: transportError)
        }

        guard shouldClose else { return }

        let hops = hopChannels
        Task {
            _ = try? await self.childChannel.close().get()
            _ = try? await self.parentChannel.close().get()
            for hop in hops.reversed() {
                _ = try? await hop.close().get()
            }
            if self.ownsGroup, let group = self.eventLoopGroup {
                try? await group.shutdownGracefully()
            }
        }
    }

    private func removeContinuation(id: UUID) {
        lock.withLock {
            _ = continuations.removeValue(forKey: id)
        }
    }

    deinit {
        let (shouldClose, activeChannels, forwardedChannels): (Bool, [Channel], [Channel]) = lock.withLock {
            if !isClosed {
                isClosed = true
                let execs = Array(activeExecChannels.values)
                activeExecChannels.removeAll()
                let fwds = Array(activeForwardedChannels.values)
                activeForwardedChannels.removeAll()
                return (true, execs, fwds)
            }
            return (false, [], [])
        }
        for execChannel in activeChannels {
            execChannel.close(promise: nil)
        }
        for forwardedChannel in forwardedChannels {
            forwardedChannel.close(promise: nil)
        }
        let owns = ownsGroup
        let grp = eventLoopGroup
        let ch = childChannel
        let pch = parentChannel
        let hops = hopChannels
        if shouldClose {
            Task {
                _ = try? await ch.close().get()
                _ = try? await pch.close().get()
                for hop in hops.reversed() {
                    _ = try? await hop.close().get()
                }
                if owns, let grp {
                    try? await grp.shutdownGracefully()
                }
            }
        }
    }
}
