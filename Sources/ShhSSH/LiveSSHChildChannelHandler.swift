import Foundation
import NIOCore
import NIOSSH
import ShhCore

final class LiveSSHChildChannelHandler: ChannelDuplexHandler, @unchecked Sendable {
    typealias InboundIn = SSHChannelData
    typealias InboundOut = SSHChannelData
    typealias OutboundIn = SSHChannelData
    typealias OutboundOut = SSHChannelData

    private let onData: @Sendable (Data) -> Void
    private let onClosed: @Sendable () -> Void
    private let onError: @Sendable (Error) -> Void
    private let lock = NSLock()
    private var pendingSuccessPromises: [EventLoopPromise<Void>] = []

    init(
        onData: @escaping @Sendable (Data) -> Void,
        onClosed: @escaping @Sendable () -> Void,
        onError: @escaping @Sendable (Error) -> Void
    ) {
        self.onData = onData
        self.onClosed = onClosed
        self.onError = onError
    }

    func addPendingReplyPromise(_ promise: EventLoopPromise<Void>) {
        lock.withLock {
            pendingSuccessPromises.append(promise)
        }
    }

    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        let channelData = self.unwrapInboundIn(data)
        guard case .byteBuffer(var buffer) = channelData.data else { return }
        if let bytes = buffer.readBytes(length: buffer.readableBytes), !bytes.isEmpty {
            onData(Data(bytes))
        }
    }

    func userInboundEventTriggered(context: ChannelHandlerContext, event: Any) {
        switch event {
        case is ChannelSuccessEvent:
            let promise: EventLoopPromise<Void>? = lock.withLock {
                guard !pendingSuccessPromises.isEmpty else { return nil }
                return pendingSuccessPromises.removeFirst()
            }
            promise?.succeed(())
        case is ChannelFailureEvent:
            let promise: EventLoopPromise<Void>? = lock.withLock {
                guard !pendingSuccessPromises.isEmpty else { return nil }
                return pendingSuccessPromises.removeFirst()
            }
            promise?.fail(TransportError.remoteFailure("SSH channel request failed"))
        default:
            context.fireUserInboundEventTriggered(event)
        }
    }

    func channelInactive(context: ChannelHandlerContext) {
        let promises: [EventLoopPromise<Void>] = lock.withLock {
            let list = pendingSuccessPromises
            pendingSuccessPromises.removeAll()
            return list
        }
        for promise in promises {
            promise.fail(TransportError.remoteFailure("SSH child channel closed"))
        }
        onClosed()
        context.fireChannelInactive()
    }

    func errorCaught(context: ChannelHandlerContext, error: Error) {
        let promises: [EventLoopPromise<Void>] = lock.withLock {
            let list = pendingSuccessPromises
            pendingSuccessPromises.removeAll()
            return list
        }
        for promise in promises {
            promise.fail(error)
        }
        onError(error)
        context.close(promise: nil)
    }
}
