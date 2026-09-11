import Foundation
import NIOCore
@preconcurrency import NIOSSH
import ShhCore

public final class LiveSSHConnection: SSHConnection, SSHCommandExecuting, @unchecked Sendable {
    private let childChannel: Channel
    private let parentChannel: Channel
    private let eventLoopGroup: EventLoopGroup?
    private let ownsGroup: Bool
    private let lock = NSLock()
    private var isClosed = false
    private var bufferedData: [Data] = []
    private var continuations: [UUID: AsyncThrowingStream<TerminalEvent, Error>.Continuation] = [:]
    private var activeExecChannels: [UUID: Channel] = [:]
    private var redactor: Redactor

    init(
        childChannel: Channel,
        parentChannel: Channel,
        eventLoopGroup: EventLoopGroup?,
        ownsGroup: Bool,
        redactor: Redactor = Redactor()
    ) {
        self.childChannel = childChannel
        self.parentChannel = parentChannel
        self.eventLoopGroup = eventLoopGroup
        self.ownsGroup = ownsGroup
        self.redactor = redactor
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

    public func close() async {
        let (activeContinuations, activeChannels, shouldClose): ([AsyncThrowingStream<TerminalEvent, Error>.Continuation], [Channel], Bool) = lock.withLock {
            guard !isClosed else { return ([], [], false) }
            isClosed = true
            let list = Array(continuations.values)
            continuations.removeAll()
            bufferedData.removeAll()
            let execs = Array(activeExecChannels.values)
            activeExecChannels.removeAll()
            return (list, execs, true)
        }

        for continuation in activeContinuations {
            continuation.yield(.closed)
            continuation.finish()
        }

        for execChannel in activeChannels {
            _ = try? await execChannel.close().get()
        }

        guard shouldClose else { return }

        _ = try? await childChannel.close().get()
        _ = try? await parentChannel.close().get()

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
        let (activeContinuations, activeChannels, shouldClose): ([AsyncThrowingStream<TerminalEvent, Error>.Continuation], [Channel], Bool) = lock.withLock {
            guard !isClosed else { return ([], [], false) }
            isClosed = true
            let list = Array(continuations.values)
            continuations.removeAll()
            bufferedData.removeAll()
            let execs = Array(activeExecChannels.values)
            activeExecChannels.removeAll()
            return (list, execs, true)
        }

        for continuation in activeContinuations {
            continuation.yield(.closed)
            continuation.finish()
        }

        for execChannel in activeChannels {
            execChannel.close(promise: nil)
        }

        guard shouldClose else { return }

        Task {
            _ = try? await self.parentChannel.close().get()
            if self.ownsGroup, let group = self.eventLoopGroup {
                try? await group.shutdownGracefully()
            }
        }
    }

    func handleChannelError(_ error: Error) {
        let (activeContinuations, activeChannels, shouldClose): ([AsyncThrowingStream<TerminalEvent, Error>.Continuation], [Channel], Bool) = lock.withLock {
            guard !isClosed else { return ([], [], false) }
            isClosed = true
            let list = Array(continuations.values)
            continuations.removeAll()
            bufferedData.removeAll()
            let execs = Array(activeExecChannels.values)
            activeExecChannels.removeAll()
            return (list, execs, true)
        }

        for execChannel in activeChannels {
            execChannel.close(promise: nil)
        }

        let transportError = (error as? TransportError) ?? TransportError.remoteFailure(error.localizedDescription)
        for continuation in activeContinuations {
            continuation.yield(.error(transportError))
            continuation.finish(throwing: transportError)
        }

        guard shouldClose else { return }

        Task {
            _ = try? await self.childChannel.close().get()
            _ = try? await self.parentChannel.close().get()
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
        let (shouldClose, activeChannels): (Bool, [Channel]) = lock.withLock {
            if !isClosed {
                isClosed = true
                let execs = Array(activeExecChannels.values)
                activeExecChannels.removeAll()
                return (true, execs)
            }
            return (false, [])
        }
        for execChannel in activeChannels {
            execChannel.close(promise: nil)
        }
        let owns = ownsGroup
        let grp = eventLoopGroup
        let ch = childChannel
        let pch = parentChannel
        if shouldClose {
            Task {
                _ = try? await ch.close().get()
                _ = try? await pch.close().get()
                if owns, let grp {
                    try? await grp.shutdownGracefully()
                }
            }
        }
    }
}
