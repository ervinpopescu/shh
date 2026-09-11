import Foundation
import NIOCore
import NIOSSH
import ShhCore

final class LiveSSHExecChannelHandler: ChannelDuplexHandler, @unchecked Sendable {
    typealias InboundIn = SSHChannelData
    typealias InboundOut = SSHChannelData
    typealias OutboundIn = SSHChannelData
    typealias OutboundOut = SSHChannelData

    let promise: EventLoopPromise<SSHCommandResult>
    private let maxOutputBytes: Int
    private let lock = NSLock()

    private var stdoutBuffer: ByteBuffer
    private var stderrBuffer: ByteBuffer
    private var totalBytesReceived: Int = 0
    private var exitStatus: Int32?
    private var isCompleted: Bool = false
    private weak var channel: Channel?

    init(
        allocator: ByteBufferAllocator,
        promise: EventLoopPromise<SSHCommandResult>,
        maxOutputBytes: Int
    ) {
        self.stdoutBuffer = allocator.buffer(capacity: 1024)
        self.stderrBuffer = allocator.buffer(capacity: 256)
        self.promise = promise
        self.maxOutputBytes = maxOutputBytes
    }

    func handlerAdded(context: ChannelHandlerContext) {
        self.channel = context.channel
    }

    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        let channelData = self.unwrapInboundIn(data)
        guard case .byteBuffer(var buffer) = channelData.data else { return }
        let count = buffer.readableBytes
        guard count > 0 else { return }

        let exceeded: Bool = lock.withLock {
            totalBytesReceived += count
            if totalBytesReceived > maxOutputBytes {
                return true
            }
            switch channelData.type {
            case .channel:
                stdoutBuffer.writeBuffer(&buffer)
            case .stdErr:
                stderrBuffer.writeBuffer(&buffer)
            default:
                stdoutBuffer.writeBuffer(&buffer)
            }
            return false
        }

        if exceeded {
            failAndClose(TransportError.remoteFailure("Command output exceeded maximum allowed size of \(maxOutputBytes) bytes"))
        }
    }

    func userInboundEventTriggered(context: ChannelHandlerContext, event: Any) {
        switch event {
        case is ChannelFailureEvent:
            failAndClose(TransportError.remoteFailure("SSH exec request rejected by server"))

        case let status as SSHChannelRequestEvent.ExitStatus:
            lock.withLock {
                self.exitStatus = Int32(status.exitStatus)
            }

        case let signal as SSHChannelRequestEvent.ExitSignal:
            lock.withLock {
                self.exitStatus = 128
                self.stderrBuffer.writeString("Process terminated by signal: \(signal.signalName)\n")
            }

        case ChannelEvent.inputClosed:
            // Remote closed write end (EOF / half-closure).
            // Acknowledge remote closure by closing our side so the child channel reaches inactive state.
            if context.channel.isActive {
                context.close(promise: nil)
            }

        default:
            context.fireUserInboundEventTriggered(event)
        }
    }

    func channelInactive(context: ChannelHandlerContext) {
        let (status, stdout, stderr, shouldSucceed): (Int32?, String, String, Bool) = lock.withLock {
            guard !isCompleted else { return (nil, "", "", false) }
            isCompleted = true
            let code = self.exitStatus
            var outBuf = self.stdoutBuffer
            var errBuf = self.stderrBuffer
            let out = outBuf.readString(length: outBuf.readableBytes) ?? ""
            let err = errBuf.readString(length: errBuf.readableBytes) ?? ""
            return (code, out, err, true)
        }

        if shouldSucceed {
            if let exitCode = status {
                promise.succeed(SSHCommandResult(exitCode: exitCode, stdout: stdout, stderr: stderr))
            } else {
                promise.fail(TransportError.remoteFailure("Command terminated without exit status"))
            }
        }

        context.fireChannelInactive()
    }

    func errorCaught(context: ChannelHandlerContext, error: Error) {
        failAndClose(error)
    }

    func failAndClose(_ error: Error) {
        let shouldFail = lock.withLock {
            if !isCompleted {
                isCompleted = true
                return true
            }
            return false
        }
        if shouldFail {
            promise.fail(error)
        }
        channel?.close(promise: nil)
    }
}
