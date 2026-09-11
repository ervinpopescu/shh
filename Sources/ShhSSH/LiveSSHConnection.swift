import Foundation
import NIOCore
import NIOSSH
import ShhCore

public final class LiveSSHConnection: SSHConnection, @unchecked Sendable {
    private let childChannel: Channel
    private let parentChannel: Channel
    private let eventLoopGroup: EventLoopGroup?
    private let ownsGroup: Bool
    private let lock = NSLock()
    private var isClosed = false
    private var bufferedData: [Data] = []
    private var continuations: [UUID: AsyncThrowingStream<TerminalEvent, Error>.Continuation] = [:]

    init(
        childChannel: Channel,
        parentChannel: Channel,
        eventLoopGroup: EventLoopGroup?,
        ownsGroup: Bool
    ) {
        self.childChannel = childChannel
        self.parentChannel = parentChannel
        self.eventLoopGroup = eventLoopGroup
        self.ownsGroup = ownsGroup
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

    public func close() async {
        let (activeContinuations, shouldClose): ([AsyncThrowingStream<TerminalEvent, Error>.Continuation], Bool) = lock.withLock {
            guard !isClosed else { return ([], false) }
            isClosed = true
            let list = Array(continuations.values)
            continuations.removeAll()
            bufferedData.removeAll()
            return (list, true)
        }

        for continuation in activeContinuations {
            continuation.yield(.closed)
            continuation.finish()
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
        let (activeContinuations, shouldClose): ([AsyncThrowingStream<TerminalEvent, Error>.Continuation], Bool) = lock.withLock {
            guard !isClosed else { return ([], false) }
            isClosed = true
            let list = Array(continuations.values)
            continuations.removeAll()
            bufferedData.removeAll()
            return (list, true)
        }

        for continuation in activeContinuations {
            continuation.yield(.closed)
            continuation.finish()
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
        let (activeContinuations, shouldClose): ([AsyncThrowingStream<TerminalEvent, Error>.Continuation], Bool) = lock.withLock {
            guard !isClosed else { return ([], false) }
            isClosed = true
            let list = Array(continuations.values)
            continuations.removeAll()
            bufferedData.removeAll()
            return (list, true)
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
        let shouldClose: Bool = lock.withLock {
            if !isClosed {
                isClosed = true
                return true
            }
            return false
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
