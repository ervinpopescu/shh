import Foundation

public enum ReconnectState: Equatable, Sendable {
    case idle
    case waiting(attempt: Int, delay: TimeInterval)
    case connecting(attempt: Int)
    case connected
    case exhausted(attempts: Int)
    case cancelled
    case failed(reason: String)

    public var isReconnecting: Bool {
        switch self {
        case .waiting, .connecting:
            return true
        default:
            return false
        }
    }

    public var attempt: Int? {
        switch self {
        case .waiting(let a, _), .connecting(let a):
            return a
        case .exhausted(let a):
            return a
        default:
            return nil
        }
    }
}

public typealias ReconnectClock = @Sendable (TimeInterval) async throws -> Void
public typealias ReconnectJitter = @Sendable (_ baseDelay: TimeInterval) -> TimeInterval
public typealias ReconnectConnectAction = @Sendable (_ attempt: Int) async throws -> Void

public actor ReconnectCoordinator {
    public static let maxAttempts: Int = 8
    public static let maxBackoff: TimeInterval = 32.0

    public private(set) var state: ReconnectState = .idle
    public private(set) var currentAttempt: Int = 0
    public private(set) var currentGeneration: Int = 0

    private let maxAttemptsLimit: Int
    private let clock: ReconnectClock
    private let jitter: ReconnectJitter
    private var activeTask: Task<Void, Never>?
    private var stateChangeHandler: (@Sendable (ReconnectState) -> Void)?
    private var generationStateChangeHandler: (@Sendable (ReconnectState, Int) -> Void)?

    public static let defaultClock: ReconnectClock = { seconds in
        try await Task.sleep(nanoseconds: UInt64(max(0, seconds) * 1_000_000_000))
    }

    public static let defaultJitter: ReconnectJitter = { baseDelay in
        guard baseDelay > 0 else { return 0 }
        let maxJitter = min(1.0, baseDelay * 0.25)
        return Double.random(in: 0...maxJitter)
    }

    public static let zeroJitter: ReconnectJitter = { _ in 0 }

    public init(
        maxAttempts: Int = ReconnectCoordinator.maxAttempts,
        clock: @escaping ReconnectClock = ReconnectCoordinator.defaultClock,
        jitter: @escaping ReconnectJitter = ReconnectCoordinator.defaultJitter,
        onStateChange: (@Sendable (ReconnectState) -> Void)? = nil
    ) {
        self.maxAttemptsLimit = maxAttempts
        self.clock = clock
        self.jitter = jitter
        self.stateChangeHandler = onStateChange
    }

    public func setStateChangeHandler(_ handler: (@Sendable (ReconnectState) -> Void)?) {
        self.stateChangeHandler = handler
    }

    /// Installs a state observer that also receives the coordinator generation.
    /// Consumers that launch asynchronous UI work can reject notifications from
    /// a cancelled recovery run after a newer run has started.
    public func setGenerationStateChangeHandler(_ handler: (@Sendable (ReconnectState, Int) -> Void)?) {
        self.generationStateChangeHandler = handler
    }

    /// Computes base backoff: 1s for attempt 1, 2s for attempt 2, 4s for attempt 3,
    /// 8s for attempt 4, 16s for attempt 5, capped at 32s.
    public static func baseDelay(for attempt: Int) -> TimeInterval {
        guard attempt > 0 else { return 0 }
        let exponent = min(attempt - 1, 5)
        let base = pow(2.0, Double(exponent))
        return min(base, maxBackoff)
    }

    /// Computes total delay with bounded jitter, capped at maxBackoff (32s).
    public static func delay(for attempt: Int, jitter: ReconnectJitter) -> TimeInterval {
        let base = baseDelay(for: attempt)
        let offset = jitter(base)
        return min(max(base, base + offset), maxBackoff)
    }

    public func start(connect: @escaping ReconnectConnectAction) {
        cancel()

        currentGeneration += 1
        let generation = currentGeneration
        currentAttempt = 0

        activeTask = Task { [weak self] in
            await self?.run(generation: generation, connect: connect)
        }
    }

    public func retryNow(connect: @escaping ReconnectConnectAction) {
        start(connect: connect)
    }

    public func cancel() {
        currentGeneration += 1
        activeTask?.cancel()
        activeTask = nil
        if state.isReconnecting {
            updateState(.cancelled, generation: currentGeneration)
        }
    }

    public func reset() {
        currentGeneration += 1
        activeTask?.cancel()
        activeTask = nil
        currentAttempt = 0
        updateState(.idle, generation: currentGeneration)
    }

    private func run(generation: Int, connect: @escaping ReconnectConnectAction) async {
        while currentAttempt < maxAttemptsLimit {
            guard self.currentGeneration == generation else { return }

            currentAttempt += 1
            let attempt = currentAttempt
            let delay = Self.delay(for: attempt, jitter: self.jitter)

            updateState(.waiting(attempt: attempt, delay: delay), generation: generation)

            do {
                try await clock(delay)
            } catch {
                guard self.currentGeneration == generation else { return }
                updateState(.cancelled, generation: generation)
                return
            }

            guard self.currentGeneration == generation else { return }

            updateState(.connecting(attempt: attempt), generation: generation)

            do {
                try await connect(attempt)

                guard self.currentGeneration == generation else { return }
                updateState(.connected, generation: generation)
                return
            } catch {
                guard self.currentGeneration == generation else { return }

                if let transportError = error as? TransportError {
                    switch transportError {
                    case .cancelled:
                        updateState(.cancelled, generation: generation)
                        return
                    case .hostKeyChanged, .hostKeyApprovalRequired, .authenticationRequired, .unsupported, .invalidConfiguration, .missingCredential, .invalidPrivateKey:
                        updateState(.failed(reason: "Non-retryable error: \(transportError)"), generation: generation)
                        return
                    default:
                        break
                    }
                }

                if currentAttempt >= maxAttemptsLimit {
                    updateState(.exhausted(attempts: currentAttempt), generation: generation)
                    return
                }
            }
        }
    }

    private func updateState(_ newState: ReconnectState, generation: Int) {
        guard self.currentGeneration == generation else { return }
        self.state = newState
        self.stateChangeHandler?(newState)
        self.generationStateChangeHandler?(newState, generation)
    }
}
