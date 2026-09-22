import Foundation
import NIOCore

final class SOCKS5BridgeSSHHandler: ChannelInboundHandler, @unchecked Sendable {
    typealias InboundIn = ByteBuffer
    private weak var clientChannel: Channel?
    private let counter: ForwardingTrafficCounter
    private var hasIncremented = false

    init(clientChannel: Channel, counter: ForwardingTrafficCounter) {
        self.clientChannel = clientChannel
        self.counter = counter
    }

    func handlerAdded(context: ChannelHandlerContext) {
        if context.channel.isActive && !hasIncremented {
            hasIncremented = true
            counter.incrementConnections()
        }
    }

    func channelActive(context: ChannelHandlerContext) {
        if !hasIncremented {
            hasIncremented = true
            counter.incrementConnections()
        }
        context.fireChannelActive()
    }

    func channelInactive(context: ChannelHandlerContext) {
        if hasIncremented {
            hasIncremented = false
            counter.decrementConnections()
        }
        _ = clientChannel?.close()
        context.fireChannelInactive()
    }

    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        let buffer = unwrapInboundIn(data)
        counter.recordReceived(buffer.readableBytes)
        clientChannel?.write(buffer, promise: nil)
    }

    func channelReadComplete(context: ChannelHandlerContext) {
        clientChannel?.flush()
    }

    func errorCaught(context: ChannelHandlerContext, error: Error) {
        _ = clientChannel?.close()
        context.fireErrorCaught(error)
    }
}

final class SOCKS5ServerHandler: ChannelInboundHandler, @unchecked Sendable {
    typealias InboundIn = ByteBuffer
    typealias OutboundOut = ByteBuffer

    enum State {
        case awaitingGreeting
        case awaitingRequest
        case connecting
        case bridged
        case failed
    }

    private var state: State = .awaitingGreeting
    private var cumulationBuffer: ByteBuffer?
    private var sshChannel: Channel?
    private let connection: LiveSSHConnection
    private let counter: ForwardingTrafficCounter
    private let onChannelOpened: (@Sendable (Channel) -> Void)?

    init(
        connection: LiveSSHConnection,
        counter: ForwardingTrafficCounter,
        onChannelOpened: (@Sendable (Channel) -> Void)? = nil
    ) {
        self.connection = connection
        self.counter = counter
        self.onChannelOpened = onChannelOpened
    }

    func channelActive(context: ChannelHandlerContext) {
        context.fireChannelActive()
    }

    func channelInactive(context: ChannelHandlerContext) {
        _ = sshChannel?.close()
        context.fireChannelInactive()
    }

    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        if state == .bridged, let sshChannel = self.sshChannel {
            let buffer = unwrapInboundIn(data)
            counter.recordSent(buffer.readableBytes)
            sshChannel.write(buffer, promise: nil)
            return
        }

        var input = unwrapInboundIn(data)
        if cumulationBuffer == nil {
            cumulationBuffer = input
        } else {
            cumulationBuffer?.writeBuffer(&input)
        }

        guard var buffer = cumulationBuffer else { return }

        do {
            try processBuffer(context: context, buffer: &buffer)
            self.cumulationBuffer = buffer
        } catch {
            state = .failed
            cumulationBuffer = nil
            _ = context.close()
        }
    }

    func channelReadComplete(context: ChannelHandlerContext) {
        if state == .bridged, let sshChannel = self.sshChannel {
            sshChannel.flush()
        }
        context.fireChannelReadComplete()
    }

    func errorCaught(context: ChannelHandlerContext, error: Error) {
        _ = sshChannel?.close()
        _ = context.close()
    }

    private func processBuffer(context: ChannelHandlerContext, buffer: inout ByteBuffer) throws {
        switch state {
        case .awaitingGreeting:
            guard buffer.readableBytes >= 2 else { return }

            let ver = buffer.getInteger(at: buffer.readerIndex, as: UInt8.self) ?? 0
            guard ver == 0x05 else {
                state = .failed
                _ = context.close()
                return
            }

            let nmethods = Int(buffer.getInteger(at: buffer.readerIndex + 1, as: UInt8.self) ?? 0)
            guard buffer.readableBytes >= 2 + nmethods else { return }

            buffer.moveReaderIndex(forwardBy: 2)
            let methods = buffer.readBytes(length: nmethods) ?? []

            if methods.contains(0x00) {
                var reply = context.channel.allocator.buffer(capacity: 2)
                reply.writeBytes([0x05, 0x00])
                context.writeAndFlush(self.wrapOutboundOut(reply), promise: nil)
                state = .awaitingRequest
                if buffer.readableBytes >= 4 {
                    try processBuffer(context: context, buffer: &buffer)
                }
            } else {
                var reply = context.channel.allocator.buffer(capacity: 2)
                reply.writeBytes([0x05, 0xFF])
                context.writeAndFlush(self.wrapOutboundOut(reply), promise: nil)
                state = .failed
                _ = context.close()
            }

        case .awaitingRequest:
            guard buffer.readableBytes >= 4 else { return }

            let ver = buffer.getInteger(at: buffer.readerIndex, as: UInt8.self) ?? 0
            let cmd = buffer.getInteger(at: buffer.readerIndex + 1, as: UInt8.self) ?? 0
            let atyp = buffer.getInteger(at: buffer.readerIndex + 3, as: UInt8.self) ?? 0

            guard ver == 0x05 else {
                state = .failed
                _ = context.close()
                return
            }

            guard cmd == 0x01 else {
                var reply = context.channel.allocator.buffer(capacity: 10)
                reply.writeBytes([0x05, 0x07, 0x00, 0x01, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00])
                context.writeAndFlush(self.wrapOutboundOut(reply), promise: nil)
                state = .failed
                _ = context.close()
                return
            }

            let targetHost: String
            let targetPort: Int

            switch atyp {
            case 0x01: // IPv4
                guard buffer.readableBytes >= 10 else { return }
                buffer.moveReaderIndex(forwardBy: 4)
                let b0 = buffer.readInteger(as: UInt8.self) ?? 0
                let b1 = buffer.readInteger(as: UInt8.self) ?? 0
                let b2 = buffer.readInteger(as: UInt8.self) ?? 0
                let b3 = buffer.readInteger(as: UInt8.self) ?? 0
                let port = buffer.readInteger(as: UInt16.self) ?? 0
                targetHost = "\(b0).\(b1).\(b2).\(b3)"
                targetPort = Int(port)

            case 0x03: // Domain name
                guard buffer.readableBytes >= 5 else { return }
                let domainLen = Int(buffer.getInteger(at: buffer.readerIndex + 4, as: UInt8.self) ?? 0)
                guard buffer.readableBytes >= 4 + 1 + domainLen + 2 else { return }
                buffer.moveReaderIndex(forwardBy: 5)
                guard let domainBytes = buffer.readBytes(length: domainLen) else {
                    state = .failed
                    _ = context.close()
                    return
                }
                targetHost = String(decoding: domainBytes, as: UTF8.self)
                let port = buffer.readInteger(as: UInt16.self) ?? 0
                targetPort = Int(port)

            case 0x04: // IPv6
                guard buffer.readableBytes >= 22 else { return }
                buffer.moveReaderIndex(forwardBy: 4)
                guard let ipv6Bytes = buffer.readBytes(length: 16) else {
                    state = .failed
                    _ = context.close()
                    return
                }
                targetHost = Self.formatIPv6(bytes: ipv6Bytes)
                let port = buffer.readInteger(as: UInt16.self) ?? 0
                targetPort = Int(port)

            default:
                var reply = context.channel.allocator.buffer(capacity: 10)
                reply.writeBytes([0x05, 0x08, 0x00, 0x01, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00])
                context.writeAndFlush(self.wrapOutboundOut(reply), promise: nil)
                state = .failed
                _ = context.close()
                return
            }

            state = .connecting

            let clientChannel = context.channel
            let counter = self.counter
            let connection = self.connection
            let onChannelOpened = self.onChannelOpened

            Task { [weak self] in
                var openedSSHChannel: Channel? = nil
                do {
                    let sshChannel = try await connection.createDirectTCPIPChannel(
                        targetHost: targetHost,
                        targetPort: targetPort,
                        originatorAddress: clientChannel.remoteAddress
                    )
                    openedSSHChannel = sshChannel

                    let sshBridge = SOCKS5BridgeSSHHandler(clientChannel: clientChannel, counter: counter)
                    _ = try await sshChannel.pipeline.addHandler(sshBridge).get()

                    guard let handler = self else {
                        _ = try? await sshChannel.close()
                        return
                    }
                    _ = try await clientChannel.eventLoop.submit { [handler] in
                        handler.sshChannel = sshChannel
                        handler.state = .bridged

                        var reply = clientChannel.allocator.buffer(capacity: 10)
                        reply.writeBytes([0x05, 0x00, 0x00, 0x01, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00])
                        clientChannel.writeAndFlush(reply, promise: nil)

                        if let pending = handler.cumulationBuffer, pending.readableBytes > 0 {
                            sshChannel.writeAndFlush(pending, promise: nil)
                            handler.cumulationBuffer = nil
                        }
                    }.get()

                    onChannelOpened?(sshChannel)
                } catch {
                    _ = try? await openedSSHChannel?.close()
                    if let handler = self {
                        _ = try? await clientChannel.eventLoop.submit { [handler] in
                            var reply = clientChannel.allocator.buffer(capacity: 10)
                            reply.writeBytes([0x05, 0x05, 0x00, 0x01, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00])
                            clientChannel.writeAndFlush(reply, promise: nil)
                            _ = clientChannel.close()
                            handler.state = .failed
                        }.get()
                    }
                }
            }

        case .connecting, .bridged, .failed:
            break
        }
    }

    private static func formatIPv6(bytes: [UInt8]) -> String {
        var parts: [String] = []
        for i in stride(from: 0, to: 16, by: 2) {
            let val = (UInt16(bytes[i]) << 8) | UInt16(bytes[i + 1])
            parts.append(String(val, radix: 16))
        }
        return parts.joined(separator: ":")
    }
}
