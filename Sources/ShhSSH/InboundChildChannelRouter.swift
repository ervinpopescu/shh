import Foundation
import NIOCore
@preconcurrency import NIOSSH

final class InboundChildChannelRouter: @unchecked Sendable {
    private let lock = NSLock()
    private var forwardedHandler: (@Sendable (Channel, SSHChannelType.ForwardedTCPIP) -> EventLoopFuture<Void>)?

    init() {}

    func register(_ handler: @escaping @Sendable (Channel, SSHChannelType.ForwardedTCPIP) -> EventLoopFuture<Void>) {
        lock.withLock {
            self.forwardedHandler = handler
        }
    }

    func handle(childChannel: Channel, type: SSHChannelType) -> EventLoopFuture<Void> {
        switch type {
        case .forwardedTCPIP(let forwarded):
            let handler = lock.withLock { self.forwardedHandler }
            if let handler {
                return handler(childChannel, forwarded)
            } else {
                return childChannel.close()
            }
        case .session, .directTCPIP:
            return childChannel.close()
        }
    }
}
