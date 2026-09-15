import Foundation
import ShhCore

public enum ServerTelemetryError: LocalizedError, Sendable, Equatable {
    case commandPolicyRejected(String)
    case executionFailed(String)

    public var errorDescription: String? {
        switch self {
        case .commandPolicyRejected(let cmd):
            return "Telemetry command rejected by CommandPolicy: \(cmd)"
        case .executionFailed(let reason):
            return "Telemetry execution failed: \(reason)"
        }
    }
}

public final class ServerTelemetryPoller: @unchecked Sendable {
    public static let defaultCommand = "cat /proc/loadavg 2>/dev/null; cat /proc/meminfo 2>/dev/null; uptime 2>/dev/null"
    public static let defaultInterval: TimeInterval = 5.0

    public let command: String
    public let interval: TimeInterval
    private let executor: any SSHCommandExecuting
    private let parser: ServerTelemetryParser
    private let lock = NSLock()
    private var pollingTask: Task<Void, Never>?
    private var updateHandler: (@Sendable (ServerTelemetry) -> Void)?

    public init(
        executor: any SSHCommandExecuting,
        command: String = ServerTelemetryPoller.defaultCommand,
        interval: TimeInterval = ServerTelemetryPoller.defaultInterval,
        parser: ServerTelemetryParser = ServerTelemetryParser()
    ) {
        self.executor = executor
        self.command = command
        self.interval = interval
        self.parser = parser
    }

    deinit {
        stopPolling()
    }

    public var isPolling: Bool {
        lock.lock()
        defer { lock.unlock() }
        return pollingTask != nil && !(pollingTask?.isCancelled ?? true)
    }

    public func fetchTelemetry() async throws -> ServerTelemetry {
        let risk = CommandPolicy.validate(command)
        guard risk == .safe else {
            throw ServerTelemetryError.commandPolicyRejected(command)
        }

        let result = try await executor.executeCommand(command, timeout: 5.0, maxOutputBytes: 65536)
        return parser.parse(result.output)
    }

    private func currentHandler() -> (@Sendable (ServerTelemetry) -> Void)? {
        lock.lock()
        defer { lock.unlock() }
        return updateHandler
    }

    public func startPolling(
        interval: TimeInterval? = nil,
        onUpdate: @escaping @Sendable (ServerTelemetry) -> Void
    ) {
        lock.lock()
        defer { lock.unlock() }

        pollingTask?.cancel()
        self.updateHandler = onUpdate
        let pollInterval = interval ?? self.interval

        pollingTask = Task { [weak self] in
            while !Task.isCancelled {
                guard let self = self else { break }
                do {
                    let telemetry = try await self.fetchTelemetry()
                    let callback = self.currentHandler()
                    callback?(telemetry)
                } catch {
                    // Transient errors do not terminate polling loop
                }

                do {
                    let nanos = UInt64(max(0.1, pollInterval) * 1_000_000_000)
                    try await Task.sleep(nanoseconds: nanos)
                } catch {
                    break
                }
            }
        }
    }

    public func stopPolling() {
        lock.lock()
        defer { lock.unlock() }
        pollingTask?.cancel()
        pollingTask = nil
        updateHandler = nil
    }
}
