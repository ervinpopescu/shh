import Foundation

/// The terminal buffer and input capability at the beginning of a touch gesture.
public enum TerminalScrollSurface: Equatable, Sendable {
    case primary
    case alternate
}

public enum TerminalScrollDirection: Equatable, Sendable {
    case up
    case down
}

public enum TerminalScrollKey: Equatable, Sendable {
    case up
    case down
    case pageUp
    case pageDown
}

/// Actions emitted by ``TerminalScrollIntentReducer``. A native action deliberately
/// carries no bytes - SwiftTerm's UIScrollView remains the owner of primary scrollback.
public enum TerminalScrollIntent: Equatable, Sendable {
    case native
    case mouseWheel(TerminalScrollDirection)
    case key(TerminalScrollKey)
    case copyModeFallback
}

public struct TerminalScrollContext: Equatable, Sendable {
    public var surface: TerminalScrollSurface
    public var mouseReporting: Bool
    public var rowHeight: Double
    public var rowCount: Int
    public var copyModeFallbackAvailable: Bool

    public init(
        surface: TerminalScrollSurface,
        mouseReporting: Bool,
        rowHeight: Double = 24,
        rowCount: Int = 24,
        copyModeFallbackAvailable: Bool = false
    ) {
        self.surface = surface
        self.mouseReporting = mouseReporting
        self.rowHeight = max(1, rowHeight)
        self.rowCount = max(1, rowCount)
        self.copyModeFallbackAvailable = copyModeFallbackAvailable
    }
}

public struct TerminalScrollGesture: Equatable, Sendable {
    public enum Phase: Equatable, Sendable {
        case began
        case changed
        case ended
        case cancelled
    }

    public var phase: Phase
    /// Incremental vertical translation. Positive means the finger moved down.
    public var translationY: Double
    public var velocityY: Double

    public init(phase: Phase, translationY: Double = 0, velocityY: Double = 0) {
        self.phase = phase
        self.translationY = translationY
        self.velocityY = velocityY
    }
}

/// Pure, bounded reducer for touch scrolling. It quantizes movement into rows and
/// never emits more than four remote intents for one gesture update.
public struct TerminalScrollIntentReducer: Sendable {
    public struct State: Equatable, Sendable {
        fileprivate var remainder: Double = 0
        fileprivate var active = false
        fileprivate var fallbackEmitted = false

        public init() {}
    }

    public var thresholdRows: Double
    public var maximumVelocity: Double
    public var maximumIntentsPerUpdate: Int

    public init(thresholdRows: Double = 1.0, maximumVelocity: Double = 4_000, maximumIntentsPerUpdate: Int = 4) {
        self.thresholdRows = max(0.5, thresholdRows)
        self.maximumVelocity = max(100, maximumVelocity)
        self.maximumIntentsPerUpdate = min(max(1, maximumIntentsPerUpdate), 8)
    }

    public mutating func reduce(
        _ gesture: TerminalScrollGesture,
        context: TerminalScrollContext,
        state: inout State
    ) -> [TerminalScrollIntent] {
        switch gesture.phase {
        case .began:
            state = State()
            state.active = true
            if context.surface == .alternate && !context.mouseReporting && context.copyModeFallbackAvailable {
                state.fallbackEmitted = true
                return [.copyModeFallback]
            }
            return context.surface == .primary && !context.mouseReporting ? [.native] : []
        case .cancelled:
            state = State()
            return []
        case .ended:
            state = State()
            return []
        case .changed:
            guard state.active, !state.fallbackEmitted else { return [] }
            guard gesture.translationY.isFinite else { return [] }
            if context.surface == .alternate && !context.mouseReporting && context.copyModeFallbackAvailable {
                return []
            }
            guard context.surface == .alternate || context.mouseReporting else { return [.native] }

            let velocity = min(max(gesture.velocityY.isFinite ? gesture.velocityY : 0, -maximumVelocity), maximumVelocity)
            let effectiveTranslation = gesture.translationY + velocity * 0.002
            state.remainder += effectiveTranslation / context.rowHeight
            let rawSteps = Int(state.remainder / thresholdRows)
            guard rawSteps != 0 else { return [] }

            let steps = min(abs(rawSteps), maximumIntentsPerUpdate) * (rawSteps.signum())
            state.remainder -= Double(steps) * thresholdRows
            let direction: TerminalScrollDirection = steps > 0 ? .up : .down
            let count = abs(steps)

            if context.mouseReporting {
                return Array(repeating: .mouseWheel(direction), count: count)
            }

            let pageThreshold = max(8, context.rowCount / 2)
            if count >= pageThreshold || abs(velocity) >= 1_800 {
                return [direction == .up ? .key(.pageUp) : .key(.pageDown)]
            }
            return Array(repeating: .key(direction == .up ? .up : .down), count: count)
        }
    }
}
