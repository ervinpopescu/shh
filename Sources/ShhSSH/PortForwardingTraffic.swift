import Foundation
import NIOCore

final class ForwardingTrafficCounter: @unchecked Sendable {
    private let lock = NSLock()
    private(set) var bytesSent: Int64 = 0
    private(set) var bytesReceived: Int64 = 0
    private(set) var activeConnections: Int = 0
    private(set) var lastActivity: Date?
    private let onUpdate: (@Sendable () -> Void)?

    init(onUpdate: (@Sendable () -> Void)? = nil) {
        self.onUpdate = onUpdate
    }

    func incrementConnections() {
        lock.withLock {
            activeConnections += 1
            lastActivity = Date()
        }
        onUpdate?()
    }

    func decrementConnections() {
        lock.withLock {
            activeConnections = max(0, activeConnections - 1)
            lastActivity = Date()
        }
        onUpdate?()
    }

    func recordSent(_ count: Int) {
        lock.withLock {
            bytesSent += Int64(count)
            lastActivity = Date()
        }
        onUpdate?()
    }

    func recordReceived(_ count: Int) {
        lock.withLock {
            bytesReceived += Int64(count)
            lastActivity = Date()
        }
        onUpdate?()
    }

    func snapshot() -> (sent: Int64, received: Int64, activeConnections: Int, lastActivity: Date?) {
        lock.withLock {
            (bytesSent, bytesReceived, activeConnections, lastActivity)
        }
    }
}

final class TrafficCounterHandler: ChannelDuplexHandler, @unchecked Sendable {
    typealias InboundIn = ByteBuffer
    typealias InboundOut = ByteBuffer
    typealias OutboundIn = ByteBuffer
    typealias OutboundOut = ByteBuffer

    let counter: ForwardingTrafficCounter
    let isClientSide: Bool

    init(counter: ForwardingTrafficCounter, isClientSide: Bool) {
        self.counter = counter
        self.isClientSide = isClientSide
    }

    func channelActive(context: ChannelHandlerContext) {
        if isClientSide {
            counter.incrementConnections()
        }
        context.fireChannelActive()
    }

    func channelInactive(context: ChannelHandlerContext) {
        if isClientSide {
            counter.decrementConnections()
        }
        context.fireChannelInactive()
    }

    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        let buffer = unwrapInboundIn(data)
        if isClientSide {
            counter.recordSent(buffer.readableBytes)
        } else {
            counter.recordReceived(buffer.readableBytes)
        }
        context.fireChannelRead(data)
    }

    func write(context: ChannelHandlerContext, data: NIOAny, promise: EventLoopPromise<Void>?) {
        context.write(data, promise: promise)
    }
}
