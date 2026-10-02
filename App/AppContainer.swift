import Combine
import Crypto
import Foundation
import ShhCore
import ShhSSH
import ShhTerminal
import ShhVoice
import SwiftUI

#if canImport(FileProvider)
import FileProvider
#endif
#if canImport(UIKit)
import UIKit

/// Coordinates finite background execution tasks during scene transitions.
public protocol BackgroundTaskManaging: AnyObject, Sendable {
    func beginBackgroundTask(withName name: String?, expirationHandler: (@Sendable () -> Void)?)
        -> UIBackgroundTaskIdentifier
    func endBackgroundTask(_ identifier: UIBackgroundTaskIdentifier)
}

/// Default implementation backed by `UIApplication.shared`.
public final class UIKitBackgroundTaskManager: BackgroundTaskManaging, @unchecked Sendable {
    public static let shared = UIKitBackgroundTaskManager()

    public func beginBackgroundTask(
        withName name: String?, expirationHandler: (@Sendable () -> Void)?
    ) -> UIBackgroundTaskIdentifier {
        UIApplication.shared.beginBackgroundTask(
            withName: name, expirationHandler: expirationHandler)
    }

    public func endBackgroundTask(_ identifier: UIBackgroundTaskIdentifier) {
        guard identifier != .invalid else { return }
        UIApplication.shared.endBackgroundTask(identifier)
    }
}

private final class BackgroundTaskBox: @unchecked Sendable {
    private let lock = NSLock()
    private var identifier: UIBackgroundTaskIdentifier = .invalid

    var value: UIBackgroundTaskIdentifier {
        get {
            lock.lock()
            defer { lock.unlock() }
            return identifier
        }
        set {
            lock.lock()
            identifier = newValue
            lock.unlock()
        }
    }
}
#endif

private final class VoiceInterruptionBridge: @unchecked Sendable {
    var onInterruption: (@Sendable () -> Void)?
    func trigger() {
        onInterruption?()
    }
}

/// Serializes external operations on a forwarding manager that may be reused
/// by successive auxiliary owners. A stale owner can only enter the manager
/// before a newer owner rebinds it; queued stale cleanup is discarded.
private actor PortForwardingManagerOperationGate {
    private var generation: UInt64 = 0
    private var isBusy = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func rebind() -> UInt64 {
        generation &+= 1
        return generation
    }

    func run<T: Sendable>(
        generation token: UInt64,
        operation: @Sendable () async throws -> T
    ) async rethrows -> T? {
        await acquire()
        guard generation == token else {
            release()
            return nil
        }
        defer { release() }
        return try await operation()
    }

    private func acquire() async {
        if !isBusy {
            isBusy = true
            return
        }
        await withCheckedContinuation { continuation in
            waiters.append(continuation)
        }
        isBusy = true
    }

    private func release() {
        if let waiter = waiters.first {
            waiters.removeFirst()
            waiter.resume()
        } else {
            isBusy = false
        }
    }
}

public enum SecondaryPaneMode: Equatable, Sendable {
    case none
    case sftp(Host)
    case terminal(Host)
}

@MainActor
final class AppContainer: ObservableObject {
    let catalog: InMemoryCatalog
    let transport: any SSHTransport
    let trustStore: InMemoryTrustStore
    let credentialStore: any CredentialStore
    let transcriber: any LocalTranscriber
    let voiceModelManager: WhisperModelManager
    let voiceRegistry: VoiceProviderRegistry
    let voiceRecorder: any AudioRecorder
    let voiceRouter: VoiceCommandRouter
    private let customTranscriber: (any LocalTranscriber)?
    public static let maximumConcurrentSessions = 8
    private let fallbackTerminalController: ShhTerminalController
    public let secondaryTerminalController: ShhTerminalController
    public var terminalController: ShhTerminalController {
        selectedSessionRuntime?.terminalController ?? fallbackTerminalController
    }
    @Published public var secondaryPaneMode: SecondaryPaneMode = .none
    let restorationStore: any SessionRestorationStore
    #if canImport(UIKit)
    let backgroundTaskManager: any BackgroundTaskManaging
    private var currentBackgroundTaskID: UIBackgroundTaskIdentifier = .invalid
    #endif
    let reachabilityMonitor: any ReachabilityMonitoring
    let reconnectCoordinator: ReconnectCoordinator
    private let liveActivityManager: SSHSessionLiveActivityManager
    private let didProvideCustomCatalog: Bool
    private var persistenceWriteBlocked = false
    @Published public var persistenceReadinessMessage: String? = nil
    /// Host identity references that do not have a descriptor in the current
    /// catalog. These are reported for UI diagnostics but never repaired by
    /// silently selecting another identity.
    @Published public private(set) var missingHostIdentityIDs: Set<UUID> = []

    private static var isRunningInTestEnvironment: Bool {
        ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil
            || ProcessInfo.processInfo.arguments.contains("-XCTest")
            || NSClassFromString("XCTestCase") != nil
    }

    private var isRunningInTestEnvironment: Bool {
        Self.isRunningInTestEnvironment
    }

    @Published public var appearance: AppearanceSetting
    @Published public var terminalTheme: TerminalThemePreset
    @Published public var keepScreenAwake: Bool {
        didSet {
            UserDefaults.standard.set(keepScreenAwake, forKey: Self.keepScreenAwakePreferenceKey)
            updateIdleTimerState()
        }
    }
    @Published public var commandDialPreferences: CommandDialPreferences {
        didSet { persistCommandDialPreferences() }
    }
    @Published var activeSession: TerminalSession? {
        didSet {
            updateIdleTimerState()
            syncLiveActivityState()
        }
    }
    @Published public private(set) var openSessions: [TerminalSession] = []
    @Published public private(set) var selectedSessionID: UUID?
    @Published public private(set) var pendingConnectingSession: TerminalSession?
    @Published var terminalText = ""
    @Published var speechState: SpeechComposerState = .idle
    @Published var pendingTrustChallenge: HostKeyChallenge?
    /// Connection failures are retained per failed attempt so one host's
    /// retry cannot erase another host's actionable detail.
    @Published public private(set) var connectionFailures: [UUID: ConnectionFailure] = [:]
    /// Compatibility projection for callers that need the most recently
    /// recorded failure. Views must use `connectionFailure(for:sessionID:)`.
    @Published public private(set) var lastConnectionFailure: ConnectionFailure?
    private var connectionFailureOrder: [UUID] = []
    @Published public var catalogUpdateToken: UUID = UUID()
    @Published var reconnectState: ReconnectState = .idle {
        didSet {
            syncLiveActivityState()
        }
    }
    /// True while foreground return is verifying the previous transport. The
    /// session is reported as connecting during this interval instead of
    /// presenting stale connected state while a probe is in flight.
    @Published var isForegroundRecoveryInProgress = false
    @Published var tmuxAvailability: TmuxAvailability = .unavailable(reason: "Not connected")
    @Published var tmuxSessions: [TmuxSessionInfo] = []
    @Published var isProbingTmux: Bool = false
    @Published var isTmuxServerRunning: Bool = false
    @Published var tmuxError: String? = nil
    @Published var activeTmuxSessionID: String? = nil {
        didSet {
            terminalController.copyModeFallbackEnabled = activeTmuxSessionID != nil
            // Primary-screen tmux wheel events remain application input.
            // Copy-mode fallback is only available when a dedicated handler is
            // explicitly registered for an alternate-screen mouse-off gesture.
        }
    }

    // MARK: - Herdr Multiplexer & Agent State
    @Published public var herdrAvailability: HerdrAvailability = .unavailable(
        reason: "Not connected")
    @Published public var herdrWorkspaces: [HerdrWorkspace] = []
    @Published public var isProbingHerdr: Bool = false
    @Published public var isPollingHerdr: Bool = false
    @Published public var herdrError: String? = nil
    @Published public var activeHerdrWorkspaceID: String? = nil
    private(set) var herdrRefreshGeneration: Int = 0
    private var herdrPollingGeneration: Int = 0
    private var herdrPollingTask: Task<Void, Never>?

    // MARK: - Mosh & Network Roaming State
    public let moshTransport: any MoshTransport
    @Published public var moshState: MoshState? = nil
    @Published public var moshSessionInfo: MoshSessionInfo? = nil
    @Published public var networkRoamingState: NetworkRoamingState? = nil
    private var moshStateTask: Task<Void, Never>?

    public var moshSessionPort: UInt16? {
        moshSessionInfo?.udpPort
    }
    @Published var selectedVoiceProviderID: String
    @Published var defaultVoiceMode: VoiceInputMode = .shellCommand
    @Published var voiceModels: [VoiceModelDescriptor] = []
    @Published var voiceErrorMessage: String? = nil
    @Published var voiceProgressFraction: Double = 0.0
    @Published var voiceRecordingDuration: TimeInterval = 0.0
    @Published var isRecordingVoice: Bool = false
    @Published var isTranscribingVoice: Bool = false
    @Published var activeVoicePreview: VoicePreviewState? = nil
    @Published var isSlideToCancelActive: Bool = false

    // MARK: - File Provider Domain Management
    public let fileProviderHelper: FileProviderManagerHelper
    @Published public var registeredFileProviderDomainIDs: Set<String> = []
    @Published public var fileProviderDomainError: String? = nil

    // MARK: - Port Forwarding & ProxyJump
    public let customPortForwardingManager: (any PortForwardingManaging)?
    @Published public var portForwardingManager: (any PortForwardingManaging)?
    @Published public var forwardingSessions: [ForwardingSessionState] = []
    @Published public var forwardingErrorMessage: String? = nil
    private var forwardingStreamTask: Task<Void, Never>?
    private var forwardingManagerOperationGeneration: UInt64?
    private var forwardingManagerGates: [ObjectIdentifier: PortForwardingManagerOperationGate] = [:]

    public var activeForwardersCount: Int {
        forwardingSessions.filter { $0.status == .active }.count
    }

    // MARK: - SFTP & File Management
    public let customSFTPRepository: (any SFTPRepository)?
    @Published public var sftpRepository: (any SFTPRepository)?
    @Published public var currentPath: RemotePath = RemotePath("/home/dev")
    @Published public var currentDirectoryFiles: [RemoteFile] = []
    @Published public var isLoadingDirectory: Bool = false
    @Published public var directoryErrorMessage: String? = nil
    @Published public var sftpErrorMessage: String? = nil
    @Published public var lastSFTPFailure: ConnectionFailure? = nil
    private var sftpSetupGeneration: Int = 0
    /// Monotonic list requests are scoped to the single-session auxiliary owner.
    /// A repository/session match alone cannot order two requests on that owner.
    private var directoryRequestGenerations: [UUID?: UInt64] = [:]

    // Sorting & Filtering
    @Published public var sortField: FileSortField = .type
    @Published public var sortAscending: Bool = true
    @Published public var fileSearchQuery: String = ""

    // Transfer Queue & Conflicts
    public let transferCoordinator = TransferQueueCoordinator()
    @Published public var transferQueueState: TransferQueueState = TransferQueueState()
    @Published public var isTransferQueueOpen: Bool = false
    @Published public var pendingConflict: FileTransferConflict? = nil
    private var activeTransferTasks: [UUID: Task<Void, Never>] = [:]
    @Published public var sendImageState: SendImageTransferState = .idle
    @Published public var sendImageErrorMessage: String?
    private var sendImageTask: Task<Void, Never>?
    private var activeSendImageTransferID: UUID?
    private var activeSendImageOperationID: UUID?
    private var transferQueueGeneration: UInt64 = 0
    private var sendImageGeneration: UInt64 = 0

    // Previews & Editor
    @Published public var previewFile: RemoteFile? = nil
    @Published public var previewData: Data? = nil
    @Published public var isPreviewLoading: Bool = false
    @Published public var previewErrorMessage: String? = nil

    // MARK: - Local Network Bonjour Discovery
    public let bonjourDiscovery: BonjourSSHDiscovery
    @Published public var discoveredSSHServices: [DiscoveredSSHService] = []
    private var cancellables = Set<AnyCancellable>()

    @Published public var activeEditingFile: RemoteFile? = nil
    @Published public var editingFileContent: String = ""
    @Published public var isSavingFile: Bool = false
    @Published public var editorErrorMessage: String? = nil
    private(set) var activeEditingHostID: Host.ID? = nil
    private var conflictQueue: [FileTransferConflict] = []

    // Server Telemetry
    @Published public var latestTelemetry: [UUID: ServerTelemetry] = [:]
    private var telemetryPollers: [UUID: ServerTelemetryPoller] = [:]

    // Directory Cache
    private var directoryCache: [RemotePath: (files: [RemoteFile], timestamp: Date)] = [:]
    private let directoryCacheTTL: TimeInterval = 60.0

    private(set) var activeHost: Host?
    private(set) var explicitlyDisconnectedSessionIDs: Set<UUID> = []
    private var fallbackExplicitDisconnect = false

    private(set) var isExplicitDisconnect: Bool {
        get {
            if let id = activeSession?.id {
                return explicitlyDisconnectedSessionIDs.contains(id)
            }
            return fallbackExplicitDisconnect
        }
        set {
            if let id = activeSession?.id {
                if newValue {
                    explicitlyDisconnectedSessionIDs.insert(id)
                } else {
                    explicitlyDisconnectedSessionIDs.remove(id)
                }
            }
            fallbackExplicitDisconnect = newValue
        }
    }
    // iOS manages background execution with finite grace periods via beginBackgroundTask.
    // While backgrounded, active SSH sessions, NIO channels, and port forwarding remain alive.
    // If iOS suspends the app (e.g. after the grace period expires), the process cannot
    // guarantee indefinite background TCP execution without a dedicated background mode.
    // Upon returning to the foreground (.active), Shh probes the existing connection before
    // deciding whether to reconnect, preserving the session with zero delay if it survived.
    private var isSceneInBackground = false
    private var isNetworkRecoveryInProgress = false
    /// Session that owns the current reconnect coordinator run. Projection
    /// updates must not be applied to a newly selected session.
    private var networkRecoverySessionID: UUID?
    /// TCP interface teardown can finish after selection moved. These owners
    /// are recovered only when the user selects them again.
    private var deferredInterfaceRecoverySessionIDs: Set<UUID> = []
    /// Background cancellation turns an in-flight recovery into a cancelled
    /// runtime state. Preserve the owner so foreground return can resume it
    /// without confusing cancellation with an explicit user disconnect.
    private var pendingForegroundRecoverySessionIDs: Set<UUID> = []
    private(set) var hasObservedTransportError = false
    private var lifecycleGeneration = 0
    private var foregroundRecoveryTask: Task<Void, Never>?
    private(set) var pendingTrustHost: Host?
    /// Legacy projection of the selected transport. SessionRuntime owns the
    /// connection and all terminal lifecycle callbacks.
    var connection: (any SSHConnection)? {
        sessionRuntime?.connection
    }
    private(set) var sessionRuntimes: [UUID: SessionRuntime] = [:]
    private var sessionOrder: [UUID] = []

    private struct LiveSessionRestorationTarget {
        let hostID: UUID
        let target: LastUsedMultiplexerTarget
    }

    private var restorationTargetsBySessionID: [UUID: LiveSessionRestorationTarget] = [:]
    /// Serializes restoration writes so an older selection cannot finish after
    /// a newer selection and overwrite its host or target metadata.
    private var restorationSaveTask: Task<Void, Never>?
    private var redactionValidityTokens: [UUID: UUID] = [:]
    private var selectionGeneration: UInt64 = 0
    private var auxiliarySetupGeneration: UInt64 = 0
    private var fileMutationGeneration: UInt64 = 0
    private var previewOperationGeneration: UInt64 = 0
    private var editorOperationGeneration: UInt64 = 0

    private struct RestorationWriteContext {
        let lifecycleGeneration: Int
        let selectionGeneration: UInt64
        let sessionID: UUID
        let hostID: UUID
        let runtimeIdentity: ObjectIdentifier
    }

    private enum SFTPOperationScope {
        case fileMutation
        case preview
        case editor
        case transfer
    }

    private struct SFTPOperationContext {
        let sessionID: UUID?
        let runtimeIdentity: ObjectIdentifier?
        let hostID: UUID?
        let repositoryIdentity: ObjectIdentifier
        let auxiliarySessionID: UUID?
        let auxiliarySetupGeneration: UInt64
        let sftpSetupGeneration: Int
        let transferQueueGeneration: UInt64
        let lifecycleGeneration: Int
        let operationGeneration: UInt64
        let scope: SFTPOperationScope
    }

    private struct AuxiliaryOwnerContext {
        let sessionID: UUID
        let runtimeIdentity: ObjectIdentifier
        let connectionIdentity: ObjectIdentifier
        let setupGeneration: UInt64
    }

    /// Auxiliary adapters remain intentionally single-session-only. This owner
    /// token prevents a selected-session change from reusing an adapter created
    /// for another host.
    private var auxiliarySessionID: UUID?

    public var selectedSessionRuntime: SessionRuntime? {
        guard let id = selectedSessionID else { return nil }
        return sessionRuntimes[id]
    }

    private var sessionRuntime: SessionRuntime? {
        selectedSessionRuntime
    }

    public var isConnectingSession: Bool {
        pendingConnectingSession != nil
            || sessionRuntimes.values.contains { $0.session.state == .connecting }
            || activeSession?.state == .connecting
    }

    public func host(for sessionID: UUID) -> Host? {
        sessionRuntimes[sessionID]?.host
    }

    public func runtime(for sessionID: UUID) -> SessionRuntime? {
        sessionRuntimes[sessionID]
    }

    private func beginRedactionValidity(for sessionID: UUID) -> UUID {
        let token = UUID()
        redactionValidityTokens[sessionID] = token
        return token
    }

    private func invalidateRedactionValidity(for sessionID: UUID) {
        redactionValidityTokens[sessionID] = UUID()
    }

    private func isCurrentRedactionValidity(sessionID: UUID, token: UUID) -> Bool {
        redactionValidityTokens[sessionID] == token
            && !explicitlyDisconnectedSessionIDs.contains(sessionID)
            && !isSceneInBackground
    }

    private func isExplicitDisconnect(for sessionID: UUID) -> Bool {
        explicitlyDisconnectedSessionIDs.contains(sessionID)
    }

    private func beginNetworkRecovery(for sessionID: UUID) {
        networkRecoverySessionID = sessionID
        isNetworkRecoveryInProgress = true
    }

    private func finishNetworkRecovery(for sessionID: UUID) {
        guard networkRecoverySessionID == sessionID else { return }
        isNetworkRecoveryInProgress = false
    }

    private func clearNetworkRecovery(for sessionID: UUID) {
        guard networkRecoverySessionID == sessionID else { return }
        isNetworkRecoveryInProgress = false
        networkRecoverySessionID = nil
    }

    private func auxiliaryOwnerContext(
        for runtime: SessionRuntime, connection: any SSHConnection
    ) -> AuxiliaryOwnerContext {
        AuxiliaryOwnerContext(
            sessionID: runtime.session.id,
            runtimeIdentity: ObjectIdentifier(runtime),
            connectionIdentity: ObjectIdentifier(connection as AnyObject),
            setupGeneration: auxiliarySetupGeneration
        )
    }

    private func isCurrentRuntimeConnection(
        sessionID: UUID, runtime: SessionRuntime, connection: any SSHConnection
    ) -> Bool {
        guard sessionRuntimes[sessionID] === runtime,
            runtime.session.state == .connected,
            !isExplicitDisconnect(for: sessionID)
        else { return false }
        return ObjectIdentifier(runtime.connection as AnyObject)
            == ObjectIdentifier(connection as AnyObject)
    }

    private func isCurrentAuxiliaryOwner(_ context: AuxiliaryOwnerContext) -> Bool {
        guard auxiliarySetupGeneration == context.setupGeneration,
            auxiliarySessionID == context.sessionID,
            selectedSessionID == context.sessionID,
            sessionRuntimes.count == 1,
            let runtime = sessionRuntimes[context.sessionID],
            ObjectIdentifier(runtime) == context.runtimeIdentity,
            runtime.session.state == .connected,
            !isExplicitDisconnect(for: context.sessionID)
        else { return false }
        return ObjectIdentifier(runtime.connection as AnyObject) == context.connectionIdentity
    }

    private func abortStaleAuxiliarySetup(
        sessionID: UUID, runtime: SessionRuntime, connection: any SSHConnection
    ) async {
        guard
            !isCurrentRuntimeConnection(
                sessionID: sessionID, runtime: runtime, connection: connection)
        else { return }
        await connection.close()
        updateOpenSessions()
    }

    @discardableResult
    private func enqueueRestorationSave(
        _ metadata: SessionRestorationMetadata,
        context: RestorationWriteContext? = nil
    ) -> Task<Void, Never> {
        let previous = restorationSaveTask
        let task = Task { @MainActor [weak self] in
            await previous?.value
            guard let self else { return }
            if let context, !self.isCurrentRestorationWrite(context) { return }
            try? await self.restorationStore.save(metadata)
        }
        restorationSaveTask = task
        return task
    }

    private func isCurrentRestorationWrite(_ context: RestorationWriteContext) -> Bool {
        guard lifecycleGeneration == context.lifecycleGeneration,
            selectionGeneration == context.selectionGeneration,
            selectedSessionID == context.sessionID,
            activeSession?.id == context.sessionID,
            activeHost?.id == context.hostID,
            let runtime = sessionRuntimes[context.sessionID],
            ObjectIdentifier(runtime) == context.runtimeIdentity,
            !isExplicitDisconnect(for: context.sessionID)
        else { return false }
        return true
    }

    private func restorationWriteContext(
        session: TerminalSession, host: Host
    ) -> RestorationWriteContext? {
        guard selectedSessionID == session.id,
            activeSession?.id == session.id,
            activeHost?.id == host.id,
            let runtime = sessionRuntimes[session.id]
        else { return nil }
        return RestorationWriteContext(
            lifecycleGeneration: lifecycleGeneration,
            selectionGeneration: selectionGeneration,
            sessionID: session.id,
            hostID: host.id,
            runtimeIdentity: ObjectIdentifier(runtime)
        )
    }

    private func saveRestorationMetadata(
        _ metadata: SessionRestorationMetadata,
        context: RestorationWriteContext
    ) async {
        guard isCurrentRestorationWrite(context) else { return }
        await enqueueRestorationSave(metadata, context: context).value
    }

    @discardableResult
    private func enqueueRestorationClear() -> Task<Void, Never> {
        let previous = restorationSaveTask
        let task = Task { @MainActor [weak self] in
            await previous?.value
            guard let self else { return }
            try? await self.restorationStore.clear()
        }
        restorationSaveTask = task
        return task
    }

    private func saveRestorationMetadata(_ metadata: SessionRestorationMetadata) async {
        await enqueueRestorationSave(metadata).value
    }

    private func clearRestorationMetadata() async {
        await enqueueRestorationClear().value
    }

    private func connectionFailure(
        for error: Error, host: Host, sessionID: UUID?
    ) -> ConnectionFailure {
        var failure = ConnectionFailure.from(error: error, host: host)
        failure.hostID = host.id
        failure.sessionID = sessionID
        return failure
    }

    private func recordConnectionFailure(_ failure: ConnectionFailure) {
        connectionFailures[failure.id] = failure
        connectionFailureOrder.removeAll { $0 == failure.id }
        connectionFailureOrder.append(failure.id)
        lastConnectionFailure = failure
    }

    private func clearConnectionFailures(forHostID hostID: UUID) {
        let removedIDs = connectionFailureOrder.filter {
            connectionFailures[$0]?.hostID == hostID
        }
        guard !removedIDs.isEmpty else { return }
        for id in removedIDs {
            connectionFailures.removeValue(forKey: id)
        }
        connectionFailureOrder.removeAll { removedIDs.contains($0) }
        lastConnectionFailure =
            connectionFailureOrder.reversed()
            .compactMap { connectionFailures[$0] }
            .first
    }

    private func clearConnectionFailure(forSessionID sessionID: UUID) {
        let matchingIDs = connectionFailureOrder.filter {
            connectionFailures[$0]?.sessionID == sessionID
        }
        guard !matchingIDs.isEmpty else { return }
        for id in matchingIDs {
            connectionFailures.removeValue(forKey: id)
        }
        connectionFailureOrder.removeAll { matchingIDs.contains($0) }
        lastConnectionFailure =
            connectionFailureOrder.reversed()
            .compactMap { connectionFailures[$0] }
            .first
    }

    func connectionFailure(for hostID: UUID, sessionID: UUID? = nil) -> ConnectionFailure? {
        connectionFailureOrder.reversed().compactMap { id in
            guard let failure = connectionFailures[id], failure.hostID == hostID else {
                return nil
            }
            if let sessionID {
                return failure.sessionID == sessionID ? failure : nil
            }
            return failure
        }.first
    }

    /// Copies one runtime's state into the selected-session legacy projection.
    /// The identity checks are required because reconnect work awaits transport
    /// and credential operations while selection may change.
    @discardableResult
    private func synchronizeSelectedSessionProjection(for runtime: SessionRuntime) -> Bool {
        let sessionID = runtime.session.id
        guard selectedSessionID == sessionID,
            let currentRuntime = sessionRuntimes[sessionID], currentRuntime === runtime
        else { return false }
        activeSession = runtime.session
        activeHost = runtime.host
        terminalText = runtime.terminalText
        reconnectState = runtime.reconnectState
        redactor = runtime.redactor
        updateOpenSessions()
        syncLiveActivityState()
        return true
    }

    /// Synchronizes failure/cancellation state for the owning runtime first,
    /// then updates selected projections only when that runtime is still current.
    private func synchronizeReconnectFailure(
        for runtime: SessionRuntime,
        sessionID: UUID,
        reason: String,
        cancelled: Bool = false
    ) {
        guard let currentRuntime = sessionRuntimes[sessionID], currentRuntime === runtime else {
            return
        }
        if runtime.session.state == .connecting {
            if cancelled {
                runtime.markReconnectCancelled()
            } else {
                runtime.markReconnectFailed(reason: reason)
            }
        }
        updateOpenSessions()
        finishNetworkRecovery(for: sessionID)
        guard selectedSessionID == sessionID else { return }
        _ = synchronizeSelectedSessionProjection(for: runtime)
        if cancelled {
            reconnectState = .cancelled
        } else {
            reconnectState = .failed(reason: reason)
        }
        isForegroundRecoveryInProgress = false
    }

    private func rememberCurrentRestorationTarget(for sessionID: UUID) {
        guard selectedSessionID == sessionID,
            let runtime = sessionRuntimes[sessionID],
            activeSession?.id == sessionID,
            activeHost?.id == runtime.host.id
        else { return }
        let target =
            activeTmuxSessionID.flatMap(LastUsedMultiplexerTarget.tmuxTarget)
            ?? activeHerdrWorkspaceID.flatMap(LastUsedMultiplexerTarget.herdrTarget)
        guard let target else { return }
        restorationTargetsBySessionID[sessionID] = LiveSessionRestorationTarget(
            hostID: runtime.host.id, target: target)
    }

    private func restorationTarget(for runtime: SessionRuntime) -> LastUsedMultiplexerTarget? {
        if let stored = restorationTargetsBySessionID[runtime.session.id],
            stored.hostID == runtime.host.id
        {
            return stored.target
        }
        guard selectedSessionID == runtime.session.id,
            activeSession?.id == runtime.session.id,
            activeHost?.id == runtime.host.id
        else { return nil }
        return activeTmuxSessionID.flatMap(LastUsedMultiplexerTarget.tmuxTarget)
            ?? activeHerdrWorkspaceID.flatMap(LastUsedMultiplexerTarget.herdrTarget)
    }

    func selectSession(id: UUID) {
        guard let runtime = sessionRuntimes[id] else { return }
        if selectedSessionID != id {
            selectionGeneration &+= 1
        }
        if let previousID = selectedSessionID, previousID != id {
            rememberCurrentRestorationTarget(for: previousID)
            transferQueueGeneration &+= 1
            cancelSendImage()
            let staleTransferIDs = Set(activeTransferTasks.keys)
            for taskID in staleTransferIDs {
                activeTransferTasks[taskID]?.cancel()
            }
            activeTransferTasks = activeTransferTasks.filter {
                !staleTransferIDs.contains($0.key)
            }
            transferQueueState = TransferQueueState()
            auxiliarySetupGeneration &+= 1
            // Invalidate old-owner projections synchronously. The asynchronous
            // teardown below must not leave A's forwarding or file state visible
            // after the UI has selected B.
            forwardingStreamTask?.cancel()
            forwardingStreamTask = nil
            forwardingSessions = []
            forwardingErrorMessage = nil
            closePreview()
            closeEditor()
            currentDirectoryFiles = []
            currentPath = RemotePath("/home/dev")
            isLoadingDirectory = false
            directoryErrorMessage = nil
            sftpErrorMessage = nil
            lastSFTPFailure = nil
            sftpSetupGeneration += 1
            directoryRequestGenerations.removeAll()
            directoryCache.removeAll()
            if !staleTransferIDs.isEmpty {
                Task { [weak self] in
                    guard let self else { return }
                    for taskID in staleTransferIDs {
                        await self.transferCoordinator.cancel(id: taskID)
                        await self.transferCoordinator.remove(id: taskID)
                    }
                }
            }
        }
        if sessionRuntimes.count > 1, auxiliarySessionID != nil {
            let staleTransferIDs = Set(activeTransferTasks.keys)
            auxiliarySessionID = nil
            let teardownGeneration = auxiliarySetupGeneration
            Task { [weak self] in
                guard let self,
                    self.auxiliarySetupGeneration == teardownGeneration,
                    self.auxiliarySessionID == nil
                else { return }
                await self.teardownAuxiliaryResources(transferTaskIDs: staleTransferIDs)
            }
        }
        if case .sftp(let host) = secondaryPaneMode, host.id != runtime.host.id {
            closeSecondaryPane()
        }
        if case .terminal(let host) = secondaryPaneMode, host.id != runtime.host.id {
            closeSecondaryPane()
        }
        selectedSessionID = id
        activeSession = runtime.session
        activeHost = runtime.host
        terminalText = runtime.terminalText
        reconnectState = runtime.reconnectState
        redactor = runtime.redactor
        synchronizeSelectedMoshState(for: runtime)
        syncLiveActivityState()

        // A runtime that was disconnected during an interface transition may
        // have become retryable while another session was selected. Start its
        // owner-scoped recovery only after it is selected again.
        if runtime.session.state == .failed || runtime.session.state == .disconnected,
            case .failed = runtime.reconnectState,
            deferredInterfaceRecoverySessionIDs.contains(id),
            !runtime.reconnectState.isReconnecting,
            !isExplicitDisconnect(for: id),
            reachabilityMonitor.isReachable
        {
            deferredInterfaceRecoverySessionIDs.remove(id)
            Task { @MainActor [weak self] in
                guard let self,
                    self.selectedSessionID == id,
                    self.sessionRuntimes[id] === runtime
                else { return }
                self.handleConnectionDrop(host: runtime.host, sessionID: id)
            }
        }

        let targetConnection = runtime.connection
        Task { [weak self] in
            guard let self, self.selectedSessionID == id else { return }
            _ = await self.synchronizeViewportAndResize(targetConnection, sessionID: id)
        }

        guard let currentRuntime = sessionRuntimes[id], currentRuntime === runtime else { return }
        let target = restorationTarget(for: runtime)
        let metadata = restorationMetadata(
            hostID: runtime.host.id, sessionID: runtime.session.id, target: target)
        _ = enqueueRestorationSave(metadata)
    }

    func closeSession(id: UUID) async {
        if networkRecoverySessionID == id {
            await reconnectCoordinator.cancel()
            clearNetworkRecovery(for: id)
        }
        guard let runtime = sessionRuntimes.removeValue(forKey: id) else { return }
        sessionOrder.removeAll { $0 == id }
        explicitlyDisconnectedSessionIDs.remove(id)
        pendingForegroundRecoverySessionIDs.remove(id)
        deferredInterfaceRecoverySessionIDs.remove(id)
        restorationTargetsBySessionID.removeValue(forKey: id)
        invalidateRedactionValidity(for: id)
        clearConnectionFailure(forSessionID: id)
        await runtime.disconnect()
        liveActivityManager.end(sessionID: id)
        updateOpenSessions()

        if case .sftp(let host) = secondaryPaneMode, host.id == runtime.host.id {
            closeSecondaryPane()
        }
        if case .terminal(let host) = secondaryPaneMode, host.id == runtime.host.id {
            closeSecondaryPane()
        }

        if selectedSessionID == id {
            if let nextID = sessionOrder.last {
                selectSession(id: nextID)
            } else {
                selectionGeneration &+= 1
                selectedSessionID = nil
                activeSession = nil
                activeHost = nil
                terminalText = ""
                reconnectState = .idle
                redactor = Redactor()
                fallbackExplicitDisconnect = false
                liveActivityManager.endAll()
                await clearRestorationMetadata()
                await teardownAuxiliaryResources()
            }
        } else if sessionOrder.isEmpty {
            selectionGeneration &+= 1
            selectedSessionID = nil
            activeSession = nil
            activeHost = nil
            terminalText = ""
            reconnectState = .idle
            redactor = Redactor()
            fallbackExplicitDisconnect = false
            liveActivityManager.endAll()
            await clearRestorationMetadata()
            await teardownAuxiliaryResources()
        }

        if sessionRuntimes.count == 1 {
            await rebindAuxiliaryResourcesIfNeeded()
        }
    }

    private func updateOpenSessions() {
        openSessions = sessionOrder.compactMap { sessionRuntimes[$0]?.session }
    }
    private var terminalGrid = TerminalGrid()
    private var ansiParser = ANSIParser()
    private(set) var redactor = Redactor()
    private(set) var tmuxRefreshGeneration: Int = 0
    private var voiceTranscriptionGeneration: Int = 0

    var isDemo: Bool {
        transport is DemoSSHTransport
    }

    private static let appearancePreferenceKey = "shh.appearance"
    private static let terminalThemePreferenceKey = UserDefaultsTerminalThemeStore.storageKey
    public static let keepScreenAwakePreferenceKey = "shh.preferences.keepScreenAwake"
    private static let commandDialPreferenceKey = "shh.preferences.commandDial"

    public static let whisperProviderID = VoiceProviderRegistry.whisperProviderID
    public static let appleSpeechProviderID = VoiceProviderRegistry.appleSpeechProviderID

    public var isWhisperSelected: Bool {
        selectedVoiceProviderID == Self.whisperProviderID
    }

    public var selectedProviderDisplayName: String {
        isWhisperSelected ? "WhisperKit" : "Apple Speech"
    }

    func setAppearance(_ value: AppearanceSetting) {
        appearance = value
        UserDefaults.standard.set(value.rawValue, forKey: Self.appearancePreferenceKey)
    }

    private func persistCommandDialPreferences() {
        guard let data = try? JSONEncoder().encode(commandDialPreferences) else { return }
        UserDefaults.standard.set(data, forKey: Self.commandDialPreferenceKey)
    }

    func setCommandDialPreferences(_ value: CommandDialPreferences) {
        commandDialPreferences = value
    }

    func toggleDialCategory(_ category: DialCategory) {
        var value = commandDialPreferences
        if value.pinnedCategories.contains(category) {
            value.pinnedCategories.removeAll { $0 == category }
        } else {
            value.pinnedCategories.append(category)
        }
        commandDialPreferences = value
    }

    func setTerminalTheme(_ value: TerminalThemePreset) {
        terminalTheme = value
        fallbackTerminalController.setTerminalTheme(value)
        secondaryTerminalController.setTerminalTheme(value)
        for runtime in sessionRuntimes.values {
            runtime.terminalController.setTerminalTheme(value)
        }
        UserDefaults.standard.set(value.rawValue, forKey: Self.terminalThemePreferenceKey)
    }

    func setTerminalFontSize(_ size: Double) {
        fallbackTerminalController.setTerminalFontSize(size)
        for runtime in sessionRuntimes.values {
            runtime.terminalController.setTerminalFontSize(size)
        }
    }

    public func setKeepScreenAwake(_ enabled: Bool) {
        keepScreenAwake = enabled
        UserDefaults.standard.set(enabled, forKey: Self.keepScreenAwakePreferenceKey)
        updateIdleTimerState()
    }

    private func updateIdleTimerState() {
        #if canImport(UIKit)
        let shouldDisable = keepScreenAwake && activeSession?.state == .connected
        UIApplication.shared.isIdleTimerDisabled = shouldDisable
        #endif
    }

    private func syncLiveActivityState() {
        guard let session = activeSession else {
            liveActivityManager.endAll()
            return
        }
        guard activeHost != nil, !isExplicitDisconnect else {
            liveActivityManager.end(sessionID: session.id)
            return
        }

        let mapped = SSHLiveActivityStatusMapper.map(
            sessionState: session.state,
            reconnectState: reconnectState
        )
        if mapped.status == .connected, session.state == .connected {
            liveActivityManager.startOrUpdate(session: session, host: activeHost!)
        } else {
            liveActivityManager.update(
                sessionID: session.id,
                status: mapped.status,
                reconnectAttempt: mapped.reconnectAttempt
            )
        }
    }

    var activeTranscriber: any LocalTranscriber {
        customTranscriber ?? voiceRegistry.activeTranscriber()
    }

    var accessibilityTerminalText: String {
        let transcript = terminalController.currentTranscript(limit: 50)
        if transcript.isEmpty {
            return terminalText.isEmpty ? "No terminal output" : terminalText
        }
        return transcript
    }

    init(
        catalog: InMemoryCatalog? = nil,
        trustStore: InMemoryTrustStore? = nil,
        credentialStore: (any CredentialStore)? = nil,
        transport: (any SSHTransport)? = nil,
        moshTransport: (any MoshTransport)? = nil,
        transcriber: (any LocalTranscriber)? = nil,
        modelManager: WhisperModelManager? = nil,
        voiceRegistry: VoiceProviderRegistry? = nil,
        voiceRecorder: (any AudioRecorder)? = nil,
        voiceRouter: VoiceCommandRouter = VoiceCommandRouter(),
        restorationStore: (any SessionRestorationStore)? = nil,
        reachabilityMonitor: (any ReachabilityMonitoring)? = nil,
        reconnectCoordinator: ReconnectCoordinator? = nil,
        sftpRepository: (any SFTPRepository)? = nil,
        portForwardingManager: (any PortForwardingManaging)? = nil,
        hostResolver: LiveSSHTransport.HostResolver? = nil,
        fileProviderHelper: FileProviderManagerHelper = .shared,
        bonjourDiscovery: BonjourSSHDiscovery? = nil,
        backgroundTaskManager: (any BackgroundTaskManaging)? = nil
    ) {
        #if canImport(UIKit)
        self.backgroundTaskManager = backgroundTaskManager ?? UIKitBackgroundTaskManager.shared
        #endif
        self.fileProviderHelper = fileProviderHelper
        self.didProvideCustomCatalog = (catalog != nil)
        let resolvedCredentialStore =
            credentialStore
            ?? KeychainCredentialStore(
                accessGroup: KeychainCredentialStore.defaultSharedAccessGroup)

        let resolvedCatalog: InMemoryCatalog
        let persistenceState: CatalogPersistenceReadState
        if let catalog {
            resolvedCatalog = catalog
            persistenceState = .notFound
        } else if !Self.isRunningInTestEnvironment || fileProviderHelper.customContainerURL != nil
            || fileProviderHelper.customLocalContainerURL != nil
        {
            let result = fileProviderHelper.loadCatalogSnapshot()
            persistenceState = result.state
            if let snapshot = result.snapshot {
                resolvedCatalog = InMemoryCatalog(snapshot: snapshot)
            } else {
                // Production never seeds demo data. A failed read is not an empty
                // persisted catalog and must not be synced back over real data.
                resolvedCatalog = InMemoryCatalog(seedDemoData: false)
            }
        } else {
            // Tests and production use explicit construction paths for demo data.
            resolvedCatalog = InMemoryCatalog(seedDemoData: false)
            persistenceState = .notFound
        }
        self.catalog = resolvedCatalog
        if catalog == nil {
            self.persistenceWriteBlocked =
                persistenceState == .invalid || persistenceState == .unavailable
        }
        if catalog == nil && !fileProviderHelper.isSharedContainerAvailable {
            self.persistenceReadinessMessage =
                "Shared App Group unavailable. Saved hosts remain available from local storage until provisioning is restored."
        }

        let resolvedTrustStore: InMemoryTrustStore
        if let trustStore {
            resolvedTrustStore = trustStore
        } else if !Self.isRunningInTestEnvironment || fileProviderHelper.customContainerURL != nil
            || fileProviderHelper.customLocalContainerURL != nil,
            let records = fileProviderHelper.loadSharedTrustRecords(),
            !records.isEmpty
        {
            resolvedTrustStore = InMemoryTrustStore(records: records)
        } else {
            resolvedTrustStore = InMemoryTrustStore()
        }
        self.trustStore = resolvedTrustStore
        self.credentialStore = resolvedCredentialStore
        let resolvedHostResolver: LiveSSHTransport.HostResolver =
            hostResolver ?? {
                [resolvedCatalog] (hostID: UUID) async throws -> (Host, IdentityDescriptor?) in
                let hosts = try await resolvedCatalog.listHosts()
                if let bastion = hosts.first(where: { $0.id == hostID }) {
                    var ident: IdentityDescriptor? = nil
                    if let identityID = bastion.identityID {
                        let idents = try await resolvedCatalog.identities()
                        ident = idents.first(where: { $0.id == identityID })
                    }
                    return (bastion, ident)
                }
                let idents = try await resolvedCatalog.identities()
                if let ident = idents.first(where: { $0.id == hostID }) {
                    let placeholder = try Host(
                        name: ident.name, hostname: "localhost", username: "unknown")
                    return (placeholder, ident)
                }
                throw TransportError.invalidConfiguration
            }
        let resolvedTransport =
            transport
            ?? LiveSSHTransport(
                credentialStore: resolvedCredentialStore,
                hostResolver: resolvedHostResolver
            )
        self.transport = resolvedTransport
        self.moshTransport = moshTransport ?? LiveMoshTransport(sshTransport: resolvedTransport)
        self.customTranscriber = transcriber

        let resolvedModelManager = modelManager ?? WhisperModelManager()
        self.voiceModelManager = resolvedModelManager

        let resolvedRegistry: VoiceProviderRegistry
        if let registry = voiceRegistry {
            resolvedRegistry = registry
        } else {
            let whisperTranscriber = WhisperKitTranscriber(modelManager: resolvedModelManager)
            let appleSpeechTranscriber = AppleSpeechTranscriber()
            resolvedRegistry = VoiceProviderRegistry(
                whisperTranscriber: whisperTranscriber,
                appleSpeechTranscriber: appleSpeechTranscriber,
                initialSelectedID: VoiceProviderRegistry.whisperProviderID
            )
        }
        self.voiceRegistry = resolvedRegistry
        self.selectedVoiceProviderID = resolvedRegistry.selectedProviderID

        let bridge = VoiceInterruptionBridge()
        if let recorder = voiceRecorder {
            self.voiceRecorder = recorder
        } else {
            self.voiceRecorder = AudioCaptureRecorder(
                onInterruption: {
                    bridge.trigger()
                }
            )
        }
        self.voiceRouter = voiceRouter
        self.transcriber = transcriber ?? resolvedRegistry.activeTranscriber()
        let storedAppearance =
            AppearanceSetting(
                rawValue: UserDefaults.standard.string(forKey: Self.appearancePreferenceKey) ?? ""
            ) ?? .default
        let storedTheme =
            TerminalThemePreset(
                rawValue: UserDefaults.standard.string(forKey: Self.terminalThemePreferenceKey)
                    ?? ""
            ) ?? .default
        let storedKeepScreenAwake =
            UserDefaults.standard.object(forKey: Self.keepScreenAwakePreferenceKey) as? Bool ?? true
        let storedDialPreferences: CommandDialPreferences = {
            guard let data = UserDefaults.standard.data(forKey: Self.commandDialPreferenceKey),
                let value = try? JSONDecoder().decode(CommandDialPreferences.self, from: data)
            else {
                return CommandDialPreferences()
            }
            return value
        }()
        self.appearance = storedAppearance
        self.terminalTheme = storedTheme
        self.keepScreenAwake = storedKeepScreenAwake
        self.commandDialPreferences = storedDialPreferences
        self.fallbackTerminalController = ShhTerminalController(
            configuration: ShhTerminalConfiguration(initialTheme: storedTheme)
        )
        self.secondaryTerminalController = ShhTerminalController(
            configuration: ShhTerminalConfiguration(initialTheme: storedTheme)
        )
        self.restorationStore = restorationStore ?? UserDefaultsSessionRestorationStore()
        let monitor = reachabilityMonitor ?? NetworkPathReachabilityMonitor()
        self.reachabilityMonitor = monitor
        let coordinator = reconnectCoordinator ?? ReconnectCoordinator()
        self.reconnectCoordinator = coordinator
        self.liveActivityManager = SSHSessionLiveActivityManager()
        let resolvedBonjour = bonjourDiscovery ?? BonjourSSHDiscovery()
        self.bonjourDiscovery = resolvedBonjour

        self.customSFTPRepository = sftpRepository
        if let sftpRepository {
            self.sftpRepository = sftpRepository
        } else if self.transport is DemoSSHTransport {
            self.sftpRepository = DemoSFTPRepository(seedDemoData: true)
        } else {
            self.sftpRepository = nil
        }

        self.customPortForwardingManager = portForwardingManager
        if let portForwardingManager {
            self.portForwardingManager = portForwardingManager
        } else if self.transport is DemoSSHTransport {
            self.portForwardingManager = DemoPortForwardingManager()
        } else {
            self.portForwardingManager = nil
        }

        bridge.onInterruption = { [weak self] in
            Task { @MainActor [weak self] in
                await self?.cancelVoiceRecording()
            }
        }

        Task { [weak self] in
            await coordinator.setGenerationStateChangeHandler { [weak self] newState, generation in
                Task { @MainActor [weak self] in
                    guard let self,
                        await coordinator.currentGeneration == generation
                    else { return }
                    guard let recoverySessionID = self.networkRecoverySessionID,
                        let runtime = self.sessionRuntimes[recoverySessionID],
                        !self.isExplicitDisconnect(for: recoverySessionID)
                    else { return }
                    runtime.updateReconnectState(newState)
                    self.updateOpenSessions()
                    if self.selectedSessionID == recoverySessionID {
                        self.reconnectState = newState
                        // A failed runtime is authoritative for the selected
                        // projection; coordinator state only adds exhausted or
                        // retryable status around that runtime state.
                        self.activeSession = runtime.session
                        self.redactor = runtime.redactor
                        self.syncLiveActivityState()
                    }
                    switch newState {
                    case .idle, .connected, .cancelled, .exhausted, .failed:
                        self.clearNetworkRecovery(for: recoverySessionID)
                    case .waiting, .connecting:
                        break
                    }
                }
            }
        }

        monitor.onReachabilityChange = { [weak self] reachable in
            Task { @MainActor [weak self] in
                self?.handleReachabilityChange(reachable)
            }
        }
        monitor.onInterfaceChange = { @Sendable [weak self] newInterface, roamingState in
            Task { @MainActor [weak self] in
                await self?.handleNetworkInterfaceChange(newInterface, roamingState: roamingState)
            }
        }
        monitor.start()

        resolvedBonjour.objectWillChange
            .sink { [weak self] _ in
                self?.objectWillChange.send()
            }
            .store(in: &cancellables)

        resolvedBonjour.$discoveredServices
            .assign(to: &$discoveredSSHServices)

        Task { [weak self] in
            await self?.refreshVoiceModels()
        }

        Task { [weak self] in
            await self?.loadDirectory(at: RemotePath("/home/dev"))
        }

        Task { [weak self] in
            let state = await self?.loadSharedStateIfNeeded()
            await self?.reconcileCatalogIdentities()
            if state == .valid || state == .notFound {
                try? await self?.syncSharedCatalogAndTrust()
            }
            #if canImport(FileProvider)
            await self?.refreshRegisteredDomains()
            #endif
        }

        updateIdleTimerState()
    }

    /// Reconciles host UUID references against catalog descriptors after every
    /// persistence load. This is intentionally metadata-only and preserves all
    /// stale host records for user repair.
    @MainActor
    public func reconcileCatalogIdentities() async {
        let hosts = (try? await catalog.listHosts()) ?? []
        let identities = (try? await catalog.identities()) ?? []
        let reconciliation = IdentityCatalogReconciliation(hosts: hosts, identities: identities)
        missingHostIdentityIDs = reconciliation.missingHostIdentityIDs
    }

    @discardableResult
    func loadSharedStateIfNeeded() async -> CatalogPersistenceReadState {
        guard !didProvideCustomCatalog else { return .notFound }
        guard
            !isRunningInTestEnvironment || fileProviderHelper.customContainerURL != nil
                || fileProviderHelper.customLocalContainerURL != nil
        else { return .unavailable }
        let result = fileProviderHelper.loadCatalogSnapshot()
        if let snapshot = result.snapshot {
            await catalog.replace(with: snapshot)
            catalogUpdateToken = UUID()
        }
        if let records = fileProviderHelper.loadSharedTrustRecords(), !records.isEmpty {
            await trustStore.addRecords(records)
        }
        return result.state
    }

    static func demo(
        catalog: InMemoryCatalog = InMemoryCatalog(),
        trustStore: InMemoryTrustStore = InMemoryTrustStore(),
        credentialStore: any CredentialStore = InMemoryCredentialStore(),
        transport: (any SSHTransport)? = nil,
        moshTransport: (any MoshTransport)? = nil,
        transcriber: (any LocalTranscriber)? = nil,
        modelManager: WhisperModelManager? = nil,
        voiceRegistry: VoiceProviderRegistry? = nil,
        voiceRecorder: (any AudioRecorder)? = nil,
        voiceRouter: VoiceCommandRouter = VoiceCommandRouter(),
        restorationStore: (any SessionRestorationStore)? = nil,
        reachabilityMonitor: (any ReachabilityMonitoring)? = nil,
        reconnectCoordinator: ReconnectCoordinator? = nil,
        sftpRepository: (any SFTPRepository)? = nil,
        portForwardingManager: (any PortForwardingManaging)? = nil,
        fileProviderHelper: FileProviderManagerHelper = .shared,
        bonjourDiscovery: BonjourSSHDiscovery? = nil
    ) -> AppContainer {
        let demoRecorder = voiceRecorder ?? DemoAudioRecorder()
        let demoTranscriber = transcriber ?? DemoTranscriber()
        let demoModelsDir = FileManager.default.temporaryDirectory.appendingPathComponent(
            "ShhDemoModels_\(UUID().uuidString)")
        let demoManager =
            modelManager
            ?? WhisperModelManager(
                modelsDirectory: demoModelsDir,
                downloader: DemoWhisperDownloader()
            )
        let demoRegistry =
            voiceRegistry
            ?? VoiceProviderRegistry(
                whisperTranscriber: demoTranscriber,
                appleSpeechTranscriber: demoTranscriber,
                initialSelectedID: VoiceProviderRegistry.whisperProviderID
            )
        return AppContainer(
            catalog: catalog,
            trustStore: trustStore,
            credentialStore: credentialStore,
            transport: transport ?? DemoSSHTransport(),
            moshTransport: moshTransport ?? DemoMoshTransport(),
            transcriber: demoTranscriber,
            modelManager: demoManager,
            voiceRegistry: demoRegistry,
            voiceRecorder: demoRecorder,
            voiceRouter: voiceRouter,
            restorationStore: restorationStore ?? InMemorySessionRestorationStore(),
            reachabilityMonitor: reachabilityMonitor ?? MockReachabilityMonitor(isReachable: true),
            reconnectCoordinator: reconnectCoordinator
                ?? ReconnectCoordinator(
                    clock: { _ in },
                    jitter: ReconnectCoordinator.zeroJitter
                ),
            sftpRepository: sftpRepository ?? DemoSFTPRepository(seedDemoData: true),
            portForwardingManager: portForwardingManager ?? DemoPortForwardingManager(),
            fileProviderHelper: fileProviderHelper,
            bonjourDiscovery: bonjourDiscovery
        )
    }

    static func statusMessage(for error: Error) -> String {
        guard let transportError = error as? TransportError else {
            return "Connection unavailable."
        }
        switch transportError {
        case .authenticationRequired:
            return "Authentication required."
        case .missingCredential:
            return "Saved credential could not be found in Keychain."
        case .missingIdentity:
            return
                "The saved host identity is missing. Edit the host and select an available identity."
        case .identityCollision:
            return "The saved host identity is ambiguous. Remove duplicate records or references."
        case .invalidPrivateKey:
            return "Private key format invalid or unreadable."
        case .timeout:
            return "Connection timed out."
        case .networkUnavailable:
            return "Network unavailable."
        case .dnsFailure(let detail):
            return detail.isEmpty ? "DNS resolution failed." : detail
        case .connectionRefused:
            return "Connection refused by remote server."
        case .unsupported, .invalidConfiguration:
            return "Unsupported configuration."
        case .cancelled:
            return "Connection cancelled."
        case .hostKeyChanged:
            return "Connection refused: host key has changed."
        case .hostKeyApprovalRequired:
            return "Host key approval required."
        case .remoteFailure:
            return "Connection failed."
        }
    }

    func connect(
        to host: Host,
        restoringTmuxSessionID: String? = nil,
        sessionID: UUID? = nil
    ) async {
        guard !isConnectingSession else { return }
        guard sessionRuntimes.count < Self.maximumConcurrentSessions else {
            let failure = ConnectionFailure(
                hostID: host.id,
                sessionID: UUID(),
                stage: .tcp,
                reason: "Maximum concurrent sessions reached (\(Self.maximumConcurrentSessions)).",
                technicalDetail:
                    "Cannot open more than \(Self.maximumConcurrentSessions) concurrent SSH sessions simultaneously.",
                recoveryAction:
                    "Close an existing session from the switcher before opening a new one."
            )
            recordConnectionFailure(failure)
            return
        }

        // Close secondary pane and tear down single-session adapters before
        // opening another host. They must never remain owned by the old host.
        closeSecondaryPane()
        if let selectedSessionID {
            rememberCurrentRestorationTarget(for: selectedSessionID)
        }
        if !sessionRuntimes.isEmpty {
            await teardownAuxiliaryResources()
        }

        lifecycleGeneration += 1
        isSceneInBackground = false
        isForegroundRecoveryInProgress = false
        isNetworkRecoveryInProgress = false
        hasObservedTransportError = false
        clearConnectionFailures(forHostID: host.id)
        await cancelVoiceRecording()
        resetVoiceState()
        fallbackExplicitDisconnect = false

        let isFirstSession = sessionRuntimes.isEmpty
        let priorSelectedSessionID = selectedSessionID

        if isFirstSession {
            liveActivityManager.endAll()
            foregroundRecoveryTask?.cancel()
            foregroundRecoveryTask = nil
            tmuxRefreshGeneration += 1
            herdrRefreshGeneration += 1
            stopHerdrPolling()
            herdrWorkspaces = []
            isProbingHerdr = false
            herdrAvailability = .unavailable(reason: "Not connected")
            herdrError = nil
            activeTmuxSessionID = nil
            tmuxSessions = []
            isTmuxServerRunning = false
            tmuxAvailability = .unavailable(reason: "Not connected")
            tmuxError = nil
            isProbingTmux = false
            moshStateTask?.cancel()
            moshStateTask = nil
            moshState = nil
            moshSessionInfo?.zeroize()
            moshSessionInfo = nil
            networkRoamingState = nil
            activeHerdrWorkspaceID = nil
            await reconnectCoordinator.cancel()
            reconnectState = .idle
            cancelSendImageForLifecycle()
            closePreview()
            closeEditor()
            currentDirectoryFiles = []
            currentPath = RemotePath("/home/dev")
            directoryErrorMessage = nil
            sftpErrorMessage = nil
            for (_, task) in activeTransferTasks {
                task.cancel()
            }
            activeTransferTasks.removeAll()
            drainPendingConflicts()
            directoryCache.removeAll()
            forwardingStreamTask?.cancel()
            forwardingStreamTask = nil
            forwardingSessions = []
            forwardingErrorMessage = nil
            if let manager = portForwardingManager,
                let managerGeneration = forwardingManagerOperationGeneration
            {
                await stopAllForwarding(manager: manager, generation: managerGeneration)
            }
            forwardingManagerOperationGeneration = nil
            if !isDemo {
                portForwardingManager = nil
            }
            fallbackTerminalController.reset()
        }

        pendingTrustChallenge = nil
        pendingTrustHost = nil
        let newSessionID = sessionID ?? UUID()
        explicitlyDisconnectedSessionIDs.remove(newSessionID)
        let redactionValidityToken = beginRedactionValidity(for: newSessionID)
        terminalController.synchronizeViewportMeasurement()
        let initialTerminalSize = terminalController.size

        var session = TerminalSession(
            id: newSessionID,
            hostID: host.id,
            state: .connecting,
            terminalSize: initialTerminalSize,
            capabilities: ["ansi", "resize"]
        )

        let runtimeTerminalController = ShhTerminalController(
            configuration: ShhTerminalConfiguration(
                initialSize: initialTerminalSize,
                initialFontSize: terminalController.terminalFontSize,
                initialTheme: terminalTheme
            )
        )

        pendingConnectingSession = session
        if isFirstSession {
            activeHost = host
            activeSession = session
            terminalText = ""
            reconnectState = .idle
        }

        var openedConnection: (any SSHConnection)? = nil
        var createdRuntime: SessionRuntime? = nil
        do {
            // Resolve descriptor by UUID before invoking transport. Never let a
            // missing descriptor degrade into password auth or an arbitrary
            // similarly-labelled identity. Credentials are queried only after
            // host-key acceptance.
            let selectedIdentity = try await resolveIdentity(for: host)
            // Identity resolution may yield to SwiftUI layout. Capture the
            // latest measured geometry immediately before PTY initialization
            // using the new runtime controller.
            runtimeTerminalController.synchronizeViewportMeasurement()
            let initialSize = runtimeTerminalController.size
            session.terminalSize = initialSize
            if isFirstSession {
                activeSession?.terminalSize = initialSize
            }
            let connection: any SSHConnection
            if case .mosh = host.connection {
                connection = try await moshTransport.connect(
                    host: host,
                    identity: selectedIdentity,
                    trustEvaluator: trustStore,
                    initialSize: initialSize
                )
            } else {
                connection = try await transport.connect(
                    host: host,
                    identity: selectedIdentity,
                    trustEvaluator: trustStore,
                    initialSize: initialSize
                )
            }
            openedConnection = connection
            guard pendingConnectingSession?.id == session.id,
                isCurrentRedactionValidity(
                    sessionID: session.id, token: redactionValidityToken)
            else {
                await connection.close()
                openedConnection = nil
                let shouldRestorePriorSelection = pendingConnectingSession == nil
                if pendingConnectingSession?.id == session.id {
                    pendingConnectingSession = nil
                }
                if shouldRestorePriorSelection,
                    let priorID = priorSelectedSessionID,
                    sessionRuntimes[priorID] != nil
                {
                    selectSession(id: priorID)
                }
                return
            }
            // Host key is accepted and connection succeeded; load redaction secret if available.
            // Use the newly opened connection rather than the selected-session projection.
            let connectionRedactor = await loadRedactionSecret(
                for: host,
                connection: connection,
                sessionID: session.id,
                validityToken: redactionValidityToken
            )
            guard pendingConnectingSession?.id == session.id,
                isCurrentRedactionValidity(
                    sessionID: session.id, token: redactionValidityToken)
            else {
                await connection.close()
                openedConnection = nil
                let shouldRestorePriorSelection = pendingConnectingSession == nil
                if pendingConnectingSession?.id == session.id {
                    pendingConnectingSession = nil
                }
                if shouldRestorePriorSelection,
                    let priorID = priorSelectedSessionID,
                    sessionRuntimes[priorID] != nil
                {
                    selectSession(id: priorID)
                }
                return
            }
            let runtime = SessionRuntime(
                host: host,
                session: session,
                connection: connection,
                terminalController: runtimeTerminalController,
                redactor: connectionRedactor
            )
            createdRuntime = runtime
            configureSessionRuntime(runtime, session: session, host: host)
            sessionRuntimes[session.id] = runtime
            if !sessionOrder.contains(session.id) {
                sessionOrder.append(session.id)
            }
            updateOpenSessions()
            selectSession(id: session.id)
            await runtime.activateAndWait()
            guard
                isCurrentRuntimeConnection(
                    sessionID: session.id, runtime: runtime, connection: connection)
            else {
                await abortStaleAuxiliarySetup(
                    sessionID: session.id, runtime: runtime, connection: connection)
                return
            }
            // SessionRuntime owns the admitted state. Only project it back to
            // legacy selected-session properties if selection still points at
            // this exact runtime after the activation await.
            _ = synchronizeSelectedSessionProjection(for: runtime)
            if pendingConnectingSession?.id == session.id {
                pendingConnectingSession = nil
            }
            let auxiliaryContext: AuxiliaryOwnerContext?
            if sessionRuntimes.count == 1 {
                auxiliarySessionID = session.id
                auxiliaryContext = auxiliaryOwnerContext(for: runtime, connection: connection)
            } else {
                auxiliaryContext = nil
            }

            let targetSession: String?
            if sessionRuntimes.count == 1 {
                targetSession = await automaticTmuxTarget(
                    for: host,
                    explicitTarget: restoringTmuxSessionID,
                    allowStoredTarget: restoringTmuxSessionID != nil
                )
            } else {
                targetSession = nil
            }
            guard
                isCurrentRuntimeConnection(
                    sessionID: session.id, runtime: runtime, connection: connection)
            else {
                await abortStaleAuxiliarySetup(
                    sessionID: session.id, runtime: runtime, connection: connection)
                return
            }

            // Auto-attach tmux session if requested by host preferences or restored.
            // The attachment boundary performs the final viewport reconciliation
            // after any awaited target validation. Without a target, still resize
            // the connected PTY to the latest measured viewport.
            if let target = targetSession {
                await self.handleTmuxTarget(target, on: connection, host: host, session: session)
            } else {
                _ = await synchronizeViewportAndResize(connection, sessionID: session.id)
            }
            guard
                isCurrentRuntimeConnection(
                    sessionID: session.id, runtime: runtime, connection: connection)
            else {
                await abortStaleAuxiliarySetup(
                    sessionID: session.id, runtime: runtime, connection: connection)
                return
            }

            if let auxiliaryContext {
                guard isCurrentAuxiliaryOwner(auxiliaryContext) else {
                    return
                }
            }
            if sessionRuntimes.count == 1 {
                let pfManager: any PortForwardingManaging
                if let custom = self.customPortForwardingManager {
                    pfManager = custom
                } else if self.isDemo {
                    pfManager = self.portForwardingManager ?? DemoPortForwardingManager()
                } else if let live = connection as? LiveSSHConnection {
                    pfManager = PortForwardingManager(connection: live)
                } else {
                    pfManager = UnavailablePortForwardingManager()
                }
                guard let auxiliaryContext,
                    isCurrentAuxiliaryOwner(auxiliaryContext)
                else {
                    await abortStaleAuxiliarySetup(
                        sessionID: session.id, runtime: runtime, connection: connection)
                    return
                }
                self.portForwardingManager = pfManager
                guard let managerGeneration = await self.rebindForwardingManager(pfManager),
                    isCurrentAuxiliaryOwner(auxiliaryContext)
                else { return }
                let started = await self.autoStartForwardingRules(
                    for: host, manager: pfManager, ownerContext: auxiliaryContext,
                    managerGeneration: managerGeneration)
                guard isCurrentAuxiliaryOwner(auxiliaryContext),
                    isCurrentForwardingManager(pfManager)
                else {
                    await self.stopAllForwarding(
                        manager: pfManager, generation: managerGeneration)
                    return
                }
                self.forwardingManagerOperationGeneration = managerGeneration
                publishForwardingSessions(started)
                self.startForwardingMonitoring(manager: pfManager, ownerContext: auxiliaryContext)

                Task { [weak self] in
                    await self?.refreshTmuxState()
                }
                Task { [weak self] in
                    await self?.setupSFTPForHost(host)
                }
            }
        } catch let error as TransportError {
            if let openedConnection {
                await openedConnection.close()
            }
            if let createdRuntime {
                await createdRuntime.disconnect()
                sessionRuntimes.removeValue(forKey: session.id)
                sessionOrder.removeAll { $0 == session.id }
                updateOpenSessions()
            }
            let shouldRestorePriorSelection =
                pendingConnectingSession == nil || pendingConnectingSession?.id == session.id
            if pendingConnectingSession?.id == session.id {
                pendingConnectingSession = nil
            }

            let failure = connectionFailure(for: error, host: host, sessionID: session.id)
            recordConnectionFailure(failure)
            let message = Self.statusMessage(for: error)
            runtimeTerminalController.feed("\r\n\u{1b}[31m[" + message + "]\u{1b}[0m\r\n")

            if isFirstSession {
                terminalText = message
                switch error {
                case .hostKeyApprovalRequired(let challenge):
                    pendingTrustChallenge = challenge
                    pendingTrustHost = host
                    activeSession?.state = .disconnected
                case .cancelled:
                    activeSession?.state = .disconnected
                default:
                    activeSession?.state = .failed
                }
            } else {
                if shouldRestorePriorSelection,
                    let priorID = priorSelectedSessionID,
                    sessionRuntimes[priorID] != nil
                {
                    selectSession(id: priorID)
                    await rebindAuxiliaryResourcesIfNeeded()
                }
                switch error {
                case .hostKeyApprovalRequired(let challenge):
                    pendingTrustChallenge = challenge
                    pendingTrustHost = host
                default:
                    break
                }
            }
        } catch {
            if let openedConnection {
                await openedConnection.close()
            }
            if let createdRuntime {
                await createdRuntime.disconnect()
                sessionRuntimes.removeValue(forKey: session.id)
                sessionOrder.removeAll { $0 == session.id }
                updateOpenSessions()
            }
            let shouldRestorePriorSelection =
                pendingConnectingSession == nil || pendingConnectingSession?.id == session.id
            if pendingConnectingSession?.id == session.id {
                pendingConnectingSession = nil
            }

            let failure = connectionFailure(for: error, host: host, sessionID: session.id)
            recordConnectionFailure(failure)
            let message = failure.reason
            runtimeTerminalController.feed("\r\n\u{1b}[31m[" + message + "]\u{1b}[0m\r\n")

            if isFirstSession {
                activeSession?.state = .failed
                terminalText = message
            } else {
                if shouldRestorePriorSelection,
                    let priorID = priorSelectedSessionID,
                    sessionRuntimes[priorID] != nil
                {
                    selectSession(id: priorID)
                    await rebindAuxiliaryResourcesIfNeeded()
                }
            }
        }
    }

    private func configureSessionRuntime(
        _ runtime: SessionRuntime,
        session: TerminalSession,
        host: Host
    ) {
        runtime.onOutput = { [weak self] data in
            guard let self else { return }
            if self.selectedSessionID == session.id {
                self.terminalText = runtime.terminalText
            }
        }
        runtime.onResize = { [weak self] size in
            guard let self else { return }
            if self.selectedSessionID == session.id {
                self.activeSession?.terminalSize = size
            }
        }
        runtime.onTermination = { [weak self] event in
            await self?.handleSessionRuntimeTermination(event, session: session, host: host)
        }
    }

    private func handleSessionRuntimeTermination(
        _ event: TerminalEvent?,
        session: TerminalSession,
        host: Host
    ) async {
        guard !explicitlyDisconnectedSessionIDs.contains(session.id) else { return }
        guard let runtime = sessionRuntimes[session.id] else { return }

        let transportError: TransportError?
        if case .error(let error) = event {
            transportError = error
        } else {
            transportError = nil
        }

        updateOpenSessions()

        if let transportError {
            let message = Self.statusMessage(for: transportError)
            runtime.terminalController.feed("\r\n\u{1b}[31m[" + message + "]\u{1b}[0m\r\n")
        } else if case .closed = event {
            runtime.terminalController.feed("\r\n\u{1b}[90m[Connection closed]\u{1b}[0m\r\n")
        }

        if selectedSessionID == session.id {
            tmuxRefreshGeneration += 1
            herdrRefreshGeneration += 1
            stopHerdrPolling()
            isProbingTmux = false
            isProbingHerdr = false

            if transportError != nil {
                hasObservedTransportError = true
            }

            activeSession?.state = runtime.session.state
            let failureReason =
                transportError.map { Self.statusMessage(for: $0) } ?? "Connection failed."
            reconnectState =
                activeSession?.state == .failed
                ? .failed(reason: failureReason)
                : .idle
            redactor = Redactor()
            if let transportError {
                terminalText += "\n" + Self.statusMessage(for: transportError)
            }
            syncLiveActivityState()
            await teardownAuxiliaryResources()
            handleConnectionDrop(host: host, sessionID: session.id)
        }
    }

    private func handleConnectionDrop(host: Host, sessionID: UUID) {
        guard let runtime = sessionRuntimes[sessionID], runtime.host.id == host.id,
            !isExplicitDisconnect(for: sessionID),
            !isSceneInBackground,
            networkRecoverySessionID == nil || networkRecoverySessionID == sessionID
        else { return }
        let isSelected = selectedSessionID == sessionID
        if isSelected {
            cancelSendImageForLifecycle()
            isForegroundRecoveryInProgress = false
        }
        guard reachabilityMonitor.isReachable else {
            // Preserve an observed transport error while recovery waits for the
            // network. Only the selected owner may update the legacy projection.
            if isSelected {
                if activeSession?.state != .failed,
                    !hasObservedTransportError
                {
                    activeSession?.state = .disconnected
                }
                reconnectState = .failed(reason: "Network unavailable.")
            } else {
                runtime.markRetryAvailable(reason: "Network unavailable.")
                updateOpenSessions()
            }
            return
        }
        guard !runtime.reconnectState.isReconnecting else { return }

        let recoverySessionID = runtime.session.id
        pendingForegroundRecoverySessionIDs.remove(recoverySessionID)
        beginNetworkRecovery(for: recoverySessionID)
        Task { @MainActor [weak self] in
            guard let self else { return }
            guard self.networkRecoverySessionID == recoverySessionID,
                !self.isExplicitDisconnect(for: recoverySessionID),
                !self.isSceneInBackground,
                self.sessionRuntimes[recoverySessionID]?.host.id == host.id,
                self.reachabilityMonitor.isReachable
            else {
                self.finishNetworkRecovery(for: recoverySessionID)
                if self.selectedSessionID == recoverySessionID {
                    self.reconnectState = .failed(reason: "Network unavailable.")
                }
                return
            }
            let recoveryTask = await self.reconnectCoordinator.start { [weak self] attempt in
                guard let self else { return }
                try await self.performReconnect(to: host, attempt: attempt)
            }
            await recoveryTask.value
        }
    }

    func performReconnect(to host: Host, attempt: Int) async throws {
        guard !isSceneInBackground else {
            throw TransportError.cancelled
        }
        let recoverySessionID = networkRecoverySessionID ?? activeSession?.id
        guard let recoverySessionID,
            let runtime = sessionRuntimes[recoverySessionID],
            runtime.host.id == host.id,
            !isExplicitDisconnect(for: recoverySessionID),
            networkRecoverySessionID != nil || selectedSessionID == recoverySessionID
        else {
            throw TransportError.cancelled
        }
        let sessionID = runtime.session.id
        // Publish owner progress before any credential or transport await. The
        // selected projection is synchronized only when this owner is selected.
        runtime.updateReconnectState(.connecting(attempt: attempt))
        if selectedSessionID == sessionID {
            reconnectState = runtime.reconnectState
            activeSession = runtime.session
            updateOpenSessions()
        }
        // SessionRuntime invalidates the previous event stream atomically when
        // the replacement transport is admitted.
        // Keep the last selected target independent from transient tmux refreshes
        // while the replacement transport is being established.
        let ownerTarget = restorationTarget(for: runtime)
        let recoveryTmuxTarget: String? = {
            guard let ownerTarget, case .tmux(let target) = ownerTarget else { return nil }
            return target
        }()
        if selectedSessionID == sessionID {
            activeTmuxSessionID = nil
        }
        guard reachabilityMonitor.isReachable else {
            // The coordinator has already marked this attempt as connecting,
            // but no transport operation ran. Reconcile the owner now so an
            // exhausted run cannot leave its runtime stranded in connecting.
            synchronizeReconnectFailure(
                for: runtime,
                sessionID: sessionID,
                reason: Self.statusMessage(for: TransportError.networkUnavailable)
            )
            throw TransportError.networkUnavailable
        }
        if selectedSessionID == sessionID {
            tmuxRefreshGeneration += 1
            herdrRefreshGeneration += 1
            stopHerdrPolling()
            isProbingTmux = false
            isProbingHerdr = false
        }

        // Cleanly reset the owner runtime's terminal emulator buffer and parser
        // without mutating the selected-session projection when selection moved.
        runtime.terminalController.synchronizeViewportMeasurement()
        if selectedSessionID == sessionID {
            terminalGrid = TerminalGrid()
            ansiParser = ANSIParser()
            terminalText = ""
            redactor = Redactor()
        }
        runtime.setRedactor(Redactor())
        runtime.terminalController.reset()

        if selectedSessionID == sessionID {
            hasObservedTransportError = false
        }
        let session = TerminalSession(
            id: sessionID,
            hostID: host.id,
            state: .connecting,
            terminalSize: runtime.terminalController.size,
            capabilities: ["ansi", "resize"]
        )
        let redactionValidityToken = beginRedactionValidity(for: session.id)
        runtime.updateSessionState(.connecting)
        if selectedSessionID == sessionID {
            activeSession = session
            reconnectState = .connecting(attempt: attempt)
        }
        updateOpenSessions()
        let connection: any SSHConnection
        do {
            let selectedIdentity = try await resolveIdentity(for: host)
            // Identity resolution may yield to SwiftUI layout. Capture the
            // latest measured geometry immediately before PTY initialization.
            runtime.terminalController.synchronizeViewportMeasurement()
            let initialSize = runtime.terminalController.size
            if selectedSessionID == sessionID {
                activeSession?.terminalSize = initialSize
            }
            if case .mosh = host.connection {
                connection = try await moshTransport.connect(
                    host: host,
                    identity: selectedIdentity,
                    trustEvaluator: trustStore,
                    initialSize: initialSize
                )
            } else {
                connection = try await transport.connect(
                    host: host,
                    identity: selectedIdentity,
                    trustEvaluator: trustStore,
                    initialSize: initialSize
                )
            }
        } catch {
            let reason: String
            if let transportError = error as? TransportError {
                reason = Self.statusMessage(for: transportError)
            } else {
                reason = "Connection unavailable."
            }
            let cancelled: Bool
            if let transportError = error as? TransportError {
                if case .cancelled = transportError {
                    cancelled = true
                } else {
                    cancelled = false
                }
            } else {
                cancelled = false
            }
            synchronizeReconnectFailure(
                for: runtime,
                sessionID: sessionID,
                reason: reason,
                cancelled: cancelled
            )
            throw error
        }

        guard sessionRuntimes[sessionID] === runtime,
            isCurrentRedactionValidity(
                sessionID: session.id, token: redactionValidityToken)
        else {
            synchronizeReconnectFailure(
                for: runtime,
                sessionID: sessionID,
                reason: "Connection cancelled.",
                cancelled: true
            )
            await connection.close()
            throw TransportError.cancelled
        }

        guard sessionRuntimes[session.id] === runtime else {
            synchronizeReconnectFailure(
                for: runtime,
                sessionID: sessionID,
                reason: "Connection cancelled.",
                cancelled: true
            )
            await connection.close()
            throw TransportError.cancelled
        }
        configureSessionRuntime(runtime, session: session, host: host)
        let previousConnection = runtime.connection
        // Resolve secrets against the replacement connection before installing it
        // in this runtime. The selected-session projection may refer to another
        // open session while recovery is in flight.
        let connectionRedactor = await loadRedactionSecret(
            for: host,
            connection: connection,
            sessionID: session.id,
            validityToken: redactionValidityToken
        )
        guard sessionRuntimes[session.id] === runtime,
            runtime.session.state == .connecting,
            isCurrentRedactionValidity(
                sessionID: session.id, token: redactionValidityToken),
            (runtime.connection as AnyObject) === (previousConnection as AnyObject)
        else {
            synchronizeReconnectFailure(
                for: runtime,
                sessionID: sessionID,
                reason: "Connection cancelled.",
                cancelled: true
            )
            await connection.close()
            throw TransportError.cancelled
        }
        guard await runtime.reconnect(with: connection, redactor: connectionRedactor) else {
            let reason: String
            if case .failed(let failureReason) = runtime.reconnectState {
                reason = failureReason
            } else {
                reason = "Connection failed."
            }
            synchronizeReconnectFailure(
                for: runtime,
                sessionID: sessionID,
                reason: reason
            )
            await connection.close()
            throw TransportError.cancelled
        }
        guard sessionRuntimes[session.id] === runtime,
            isCurrentRedactionValidity(
                sessionID: session.id, token: redactionValidityToken),
            (runtime.connection as AnyObject) === (connection as AnyObject)
        else {
            await runtime.disconnect()
            synchronizeReconnectFailure(
                for: runtime,
                sessionID: sessionID,
                reason: "Connection cancelled.",
                cancelled: true
            )
            throw TransportError.cancelled
        }
        _ = synchronizeSelectedSessionProjection(for: runtime)
        if selectedSessionID == sessionID {
            synchronizeSelectedMoshState(for: runtime)
        } else {
            updateOpenSessions()
        }
        finishNetworkRecovery(for: sessionID)
        if selectedSessionID == sessionID {
            reconnectState = .connected
            syncLiveActivityState()
        }
        let auxiliaryContext: AuxiliaryOwnerContext?
        if sessionRuntimes.count == 1 {
            auxiliarySessionID = session.id
            auxiliaryContext = auxiliaryOwnerContext(for: runtime, connection: connection)
        } else {
            auxiliaryContext = nil
        }

        let targetSession: String?
        if sessionRuntimes.count == 1 {
            targetSession = await automaticTmuxTarget(
                for: host,
                explicitTarget: recoveryTmuxTarget,
                allowStoredTarget: true
            )
        } else {
            targetSession = nil
        }
        guard
            isCurrentRuntimeConnection(
                sessionID: session.id, runtime: runtime, connection: connection)
        else {
            await abortStaleAuxiliarySetup(
                sessionID: session.id, runtime: runtime, connection: connection)
            return
        }
        if let target = targetSession {
            _ = await self.handleTmuxTarget(target, on: connection, host: host, session: session)
        } else {
            _ = await synchronizeViewportAndResize(connection, sessionID: session.id)
        }
        guard
            isCurrentRuntimeConnection(
                sessionID: session.id, runtime: runtime, connection: connection)
        else {
            await abortStaleAuxiliarySetup(
                sessionID: session.id, runtime: runtime, connection: connection)
            return
        }

        let persistedTarget: LastUsedMultiplexerTarget? =
            (try? await restorationStore.load()).flatMap { metadata in
                guard metadata.hostID == host.id else { return nil }
                return lastUsedTarget(from: metadata)
            }
        guard
            isCurrentRuntimeConnection(
                sessionID: session.id, runtime: runtime, connection: connection)
        else {
            await abortStaleAuxiliarySetup(
                sessionID: session.id, runtime: runtime, connection: connection)
            return
        }
        let herdrTarget: LastUsedMultiplexerTarget? = {
            if let ownerTarget, case .herdr = ownerTarget { return ownerTarget }
            return persistedTarget
        }()
        let shouldRestoreHerdr: Bool = {
            guard let herdrTarget, case .herdr = herdrTarget else { return false }
            return true
        }()
        if sessionRuntimes.count == 1, shouldRestoreHerdr {
            await refreshHerdrState()
            guard
                isCurrentRuntimeConnection(
                    sessionID: session.id, runtime: runtime, connection: connection)
            else {
                await abortStaleAuxiliarySetup(
                    sessionID: session.id, runtime: runtime, connection: connection)
                return
            }
            await restoreHerdrTargetIfNeeded(
                for: host, session: session, preferredTarget: herdrTarget)
            guard
                isCurrentRuntimeConnection(
                    sessionID: session.id, runtime: runtime, connection: connection)
            else {
                await abortStaleAuxiliarySetup(
                    sessionID: session.id, runtime: runtime, connection: connection)
                return
            }
        }

        if let auxiliaryContext {
            guard isCurrentAuxiliaryOwner(auxiliaryContext) else {
                return
            }
        }
        if sessionRuntimes.count == 1 {
            let pfManager: any PortForwardingManaging
            if let custom = self.customPortForwardingManager {
                pfManager = custom
            } else if self.isDemo {
                pfManager = self.portForwardingManager ?? DemoPortForwardingManager()
            } else if let live = connection as? LiveSSHConnection {
                pfManager = PortForwardingManager(connection: live)
            } else {
                pfManager = UnavailablePortForwardingManager()
            }
            guard let auxiliaryContext,
                isCurrentAuxiliaryOwner(auxiliaryContext)
            else {
                await abortStaleAuxiliarySetup(
                    sessionID: session.id, runtime: runtime, connection: connection)
                return
            }
            self.portForwardingManager = pfManager
            guard let managerGeneration = await self.rebindForwardingManager(pfManager),
                isCurrentAuxiliaryOwner(auxiliaryContext)
            else { return }
            let started = await self.autoStartForwardingRules(
                for: host, manager: pfManager, ownerContext: auxiliaryContext,
                managerGeneration: managerGeneration)
            guard isCurrentAuxiliaryOwner(auxiliaryContext),
                isCurrentForwardingManager(pfManager)
            else {
                await self.stopAllForwarding(
                    manager: pfManager, generation: managerGeneration)
                return
            }
            self.forwardingManagerOperationGeneration = managerGeneration
            publishForwardingSessions(started)
            self.startForwardingMonitoring(manager: pfManager, ownerContext: auxiliaryContext)
            Task { [weak self] in
                await self?.refreshTmuxState()
                await self?.setupSFTPForHost(host)
            }
        }
        // Reconnect completion is intentionally published only after the
        // remembered tmux target has been attached successfully.
        finishNetworkRecovery(for: sessionID)
    }

    func cancelReconnect() async {
        // Capture the recovery owner before any await or selected-session side
        // effect. The user can switch sessions while coordinator cancellation
        // is suspended.
        let recoverySessionID = networkRecoverySessionID ?? activeSession?.id
        let recoveryRuntime = recoverySessionID.flatMap { sessionRuntimes[$0] }
        let recoveryWasSelected = selectedSessionID == recoverySessionID
        if let recoverySessionID {
            pendingForegroundRecoverySessionIDs.remove(recoverySessionID)
            explicitlyDisconnectedSessionIDs.insert(recoverySessionID)
            invalidateRedactionValidity(for: recoverySessionID)
        } else {
            fallbackExplicitDisconnect = true
        }
        if recoveryWasSelected {
            isExplicitDisconnect = true
        }
        liveActivityManager.end(sessionID: recoverySessionID ?? UUID())
        isForegroundRecoveryInProgress = false
        isNetworkRecoveryInProgress = false
        foregroundRecoveryTask?.cancel()
        foregroundRecoveryTask = nil
        lifecycleGeneration += 1
        if recoveryWasSelected {
            tmuxRefreshGeneration += 1
            herdrRefreshGeneration += 1
            stopHerdrPolling()
            isProbingTmux = false
            isProbingHerdr = false
        }
        await reconnectCoordinator.cancel()

        // Cancellation suspends at the coordinator hop. The selected runtime
        // may change while it is suspended, so only tear down the runtime and
        // recovery session captured before that hop if it still owns the same
        // session entry afterward.
        guard let recoverySessionID,
            let recoveryRuntime,
            sessionRuntimes[recoverySessionID] === recoveryRuntime
        else {
            if recoveryWasSelected, recoveryRuntime == nil {
                activeSession?.state = .disconnected
                reconnectState = .cancelled
            }
            updateOpenSessions()
            updateIdleTimerState()
            return
        }
        clearNetworkRecovery(for: recoverySessionID)
        await recoveryRuntime.disconnect()
        recoveryRuntime.markReconnectCancelled()
        updateOpenSessions()

        guard selectedSessionID == recoverySessionID,
            sessionRuntimes[recoverySessionID] === recoveryRuntime
        else {
            updateIdleTimerState()
            return
        }
        reconnectState = .cancelled
        moshStateTask?.cancel()
        moshStateTask = nil
        moshState = nil
        moshSessionInfo?.zeroize()
        moshSessionInfo = nil
        networkRoamingState = nil
        _ = synchronizeSelectedSessionProjection(for: recoveryRuntime)
        await teardownAuxiliaryResources()
        updateIdleTimerState()
    }

    func retryReconnect() async {
        guard let host = activeHost,
            let sessionID = activeSession?.id,
            sessionRuntimes[sessionID]?.host.id == host.id
        else { return }
        guard reachabilityMonitor.isReachable else {
            reconnectState = .failed(reason: "Network unavailable.")
            return
        }
        isExplicitDisconnect = false
        explicitlyDisconnectedSessionIDs.remove(sessionID)
        pendingForegroundRecoverySessionIDs.remove(sessionID)
        if let runtime = sessionRuntimes[sessionID] {
            runtime.updateReconnectState(.connecting(attempt: 1))
        }
        beginNetworkRecovery(for: sessionID)
        let recoveryTask = await reconnectCoordinator.start { [weak self] attempt in
            guard let self else { return }
            try await self.performReconnect(to: host, attempt: attempt)
        }
        await recoveryTask.value
    }

    func handleReachabilityChange(_ isReachable: Bool) {
        let selectedID = selectedSessionID
        let recoverySessionID = networkRecoverySessionID
        // Reachability belongs to the runtime that owns recovery, not to the
        // selected-session projection. A selected session may be explicitly
        // disconnected while another runtime is still progressing.
        if let recoverySessionID = networkRecoverySessionID {
            guard let runtime = sessionRuntimes[recoverySessionID],
                !isExplicitDisconnect(for: recoverySessionID)
            else { return }
            if !isReachable, runtime.reconnectState.isReconnecting {
                runtime.markReconnectFailed(reason: "Network unavailable.")
                updateOpenSessions()
                if selectedID == recoverySessionID {
                    _ = synchronizeSelectedSessionProjection(for: runtime)
                    reconnectState = .failed(reason: "Network unavailable.")
                    isNetworkRecoveryInProgress = false
                }
                finishNetworkRecovery(for: recoverySessionID)
                Task { [weak self] in
                    await self?.reconnectCoordinator.cancel()
                }
            } else if isReachable {
                // The owner coordinator remains authoritative. Do not inspect
                // or mutate the selected runtime while it is running.
                if runtime.reconnectState.isReconnecting { return }
                handleConnectionDrop(host: runtime.host, sessionID: recoverySessionID)
            }
            return
        }

        if let selectedID, isExplicitDisconnect(for: selectedID) { return }
        guard isReachable else {
            if reconnectState.isReconnecting, let recoverySessionID,
                let runtime = sessionRuntimes[recoverySessionID]
            {
                runtime.markReconnectFailed(reason: "Network unavailable.")
                updateOpenSessions()
                if selectedID == recoverySessionID {
                    _ = synchronizeSelectedSessionProjection(for: runtime)
                    reconnectState = .failed(reason: "Network unavailable.")
                    isNetworkRecoveryInProgress = false
                }
                finishNetworkRecovery(for: recoverySessionID)
                Task { [weak self] in
                    await self?.reconnectCoordinator.cancel()
                }
            } else if activeSession?.state == .connected {
                // Reachability can briefly report an unavailable path while an
                // established transport is still usable. Do not tear down a
                // healthy session or create a second reconnect cycle here; the
                // transport event remains authoritative for an actual drop.
                reconnectState = .failed(reason: "Network unavailable.")
                return
            } else if activeSession != nil {
                // Do not erase an actionable transport failure when the path
                // update arrives after the failure event.
                if activeSession?.state != .failed,
                    !hasObservedTransportError
                {
                    activeSession?.state = .disconnected
                }
                reconnectState = .failed(reason: "Network unavailable.")
            }
            return
        }

        guard let host = activeHost else { return }
        if activeSession?.state == .connected {
            if case .mosh = host.connection, !reconnectState.isReconnecting {
                Task { [weak self] in
                    await self?.performFastSessionRecovery()
                }
            } else {
                reconnectState = .idle
            }
            return
        }
        if activeSession?.state == .failed || activeSession?.state == .disconnected {
            if let sessionID = activeSession?.id {
                handleConnectionDrop(host: host, sessionID: sessionID)
            }
        }
    }

    // MARK: - Mosh Network Roaming & Fast Session Recovery

    private func isCurrentMoshOwner(
        sessionID: UUID,
        runtime: SessionRuntime,
        controller: any MoshSessionControlling
    ) -> Bool {
        sessionRuntimes[sessionID] === runtime
            && runtime.session.state == .connected
            && !isExplicitDisconnect(for: sessionID)
            && (runtime.connection as AnyObject) === (controller as AnyObject)
    }

    private func isSelectedMoshOwner(
        sessionID: UUID,
        runtime: SessionRuntime,
        controller: any MoshSessionControlling
    ) -> Bool {
        selectedSessionID == sessionID
            && isCurrentMoshOwner(sessionID: sessionID, runtime: runtime, controller: controller)
    }

    private func startMoshMonitoring(
        for controller: any MoshSessionControlling, runtime: SessionRuntime
    ) {
        moshStateTask?.cancel()
        let sessionID = runtime.session.id
        moshStateTask = Task { @MainActor [weak self] in
            let updates = await controller.moshStateUpdates()
            for await state in updates {
                guard let self,
                    self.isSelectedMoshOwner(
                        sessionID: sessionID, runtime: runtime, controller: controller)
                else { break }
                self.moshState = state
                if case .roaming(let roaming) = state {
                    self.networkRoamingState = roaming
                }
            }
        }
    }

    func handleNetworkInterfaceChange(
        _ newInterface: NetworkInterfaceType, roamingState: NetworkRoamingState
    ) async {
        let ownerSessionID = networkRecoverySessionID ?? selectedSessionID
        guard let ownerSessionID,
            let ownerRuntime = sessionRuntimes[ownerSessionID],
            let ownerHost = sessionRuntimes[ownerSessionID]?.host,
            ownerHost.id == ownerRuntime.host.id,
            !isExplicitDisconnect(for: ownerSessionID)
        else { return }
        if selectedSessionID == ownerSessionID {
            cancelSendImageForLifecycle()
            self.networkRoamingState = roamingState
        }

        if let ownerController = ownerRuntime.connection as? any MoshSessionControlling {
            do {
                try await ownerController.handleNetworkRoaming(roamingState)
                guard
                    isCurrentMoshOwner(
                        sessionID: ownerSessionID,
                        runtime: ownerRuntime,
                        controller: ownerController
                    )
                else { return }
                let state = await ownerController.moshState
                guard
                    isCurrentMoshOwner(
                        sessionID: ownerSessionID,
                        runtime: ownerRuntime,
                        controller: ownerController
                    )
                else { return }
                if selectedSessionID == ownerSessionID {
                    self.moshState = state
                }
            } catch {
                guard
                    isCurrentMoshOwner(
                        sessionID: ownerSessionID,
                        runtime: ownerRuntime,
                        controller: ownerController
                    )
                else { return }
                await performFastSessionRecovery(
                    for: ownerSessionID,
                    runtime: ownerRuntime,
                    host: ownerHost,
                    controller: ownerController,
                    roamingState: roamingState
                )
            }
        } else if ownerRuntime.session.state == .connected {
            // A path/interface change can leave an established TCP socket
            // half-alive without producing a channel callback. Replace it
            // through the normal reconnect path, but first detach the old
            // stream so its close event cannot start a second coordinator.
            isNetworkRecoveryInProgress = true
            if selectedSessionID == ownerSessionID {
                activeSession?.state = .disconnected
            }
            await ownerRuntime.disconnect()
            guard sessionRuntimes[ownerSessionID] === ownerRuntime else { return }

            // Teardown can yield while selection changes. Restrict the global
            // auxiliary projection to the captured owner and never let a
            // completed teardown restart or rewrite the newly selected runtime.
            if selectedSessionID == ownerSessionID {
                await teardownAuxiliaryResources(
                    expectedSessionID: ownerSessionID, expectedRuntime: ownerRuntime)
            }
            guard sessionRuntimes[ownerSessionID] === ownerRuntime else { return }
            isNetworkRecoveryInProgress = false
            if selectedSessionID == ownerSessionID {
                handleConnectionDrop(host: ownerHost, sessionID: ownerSessionID)
            } else {
                ownerRuntime.markRetryAvailable(reason: "Network changed. Retry connection.")
                deferredInterfaceRecoverySessionIDs.insert(ownerSessionID)
                updateOpenSessions()
            }
        }
    }

    func performFastSessionRecovery() async {
        guard let sessionID = selectedSessionID,
            let runtime = sessionRuntimes[sessionID],
            let host = activeHost,
            host.id == runtime.host.id
        else { return }
        let controller = runtime.connection as? any MoshSessionControlling
        await performFastSessionRecovery(
            for: sessionID,
            runtime: runtime,
            host: host,
            controller: controller,
            roamingState: nil
        )
    }

    private func performFastSessionRecovery(
        for sessionID: UUID,
        runtime: SessionRuntime,
        host: Host,
        controller: (any MoshSessionControlling)?,
        roamingState: NetworkRoamingState?
    ) async {
        guard sessionRuntimes[sessionID] === runtime,
            runtime.host.id == host.id,
            runtime.session.state == .connected,
            !isExplicitDisconnect(for: sessionID)
        else { return }

        if reachabilityMonitor.isReachable,
            let moshController = controller ?? (runtime.connection as? any MoshSessionControlling)
        {
            let roaming =
                roamingState
                ?? networkRoamingState
                ?? NetworkRoamingState(currentInterface: reachabilityMonitor.currentInterfaceType)
            do {
                try await moshController.handleNetworkRoaming(roaming)
                guard sessionRuntimes[sessionID] === runtime,
                    runtime.session.state == .connected,
                    !isExplicitDisconnect(for: sessionID),
                    (runtime.connection as AnyObject) === (moshController as AnyObject)
                else { return }
                let state = await moshController.moshState
                guard sessionRuntimes[sessionID] === runtime,
                    runtime.session.state == .connected,
                    !isExplicitDisconnect(for: sessionID),
                    (runtime.connection as AnyObject) === (moshController as AnyObject)
                else { return }
                if selectedSessionID == sessionID {
                    self.moshState = state
                }
                return
            } catch {
                // In-place recovery probe failed; fall back to reconnect coordinator.
            }
        }

        guard sessionRuntimes[sessionID] === runtime,
            runtime.session.state == .connected,
            !isExplicitDisconnect(for: sessionID),
            !runtime.reconnectState.isReconnecting,
            networkRecoverySessionID == nil || networkRecoverySessionID == sessionID
        else { return }
        beginNetworkRecovery(for: sessionID)
        _ = await reconnectCoordinator.start { [weak self] attempt in
            guard let self else { return }
            try await self.performReconnect(to: host, attempt: attempt)
        }
    }

    func handleScenePhaseChange(_ phase: ScenePhase) {
        if phase == .background {
            Task { [weak self] in
                await self?.cancelVoiceRecording()
            }
        }
        switch phase {
        case .inactive:
            // Inactive is also used for transient interruptions such as
            // system sheets and calls. It is not a suspension boundary.
            break
        case .background:
            enterBackground()
        case .active:
            let wasInBackground = isSceneInBackground
            if wasInBackground {
                lifecycleGeneration += 1
            }
            isSceneInBackground = false
            #if canImport(UIKit)
            endCurrentBackgroundTask()
            #endif
            let recoveryOwnerID = self.networkRecoverySessionID
            let recoveryOwnerIsActive =
                recoveryOwnerID.flatMap { ownerID in
                    self.sessionRuntimes[ownerID].map {
                        !self.isExplicitDisconnect(for: $0.session.id)
                    }
                } ?? false
            let pendingForegroundRecoveryIsActive =
                self.pendingForegroundRecoverySessionIDs.contains { sessionID in
                    guard let runtime = self.sessionRuntimes[sessionID] else { return false }
                    return !self.isExplicitDisconnect(for: sessionID)
                        && runtime.session.state != .connected
                }
            let hasConnectedSessions = self.sessionRuntimes.values.contains {
                $0.session.state == .connected
                    && !self.isExplicitDisconnect(for: $0.session.id)
            }
            guard
                hasConnectedSessions || recoveryOwnerIsActive
                    || pendingForegroundRecoveryIsActive
            else { return }

            if wasInBackground {
                let generation = lifecycleGeneration
                foregroundRecoveryTask?.cancel()
                let recoveryTask = Task { @MainActor [weak self] in
                    guard let self,
                        self.lifecycleGeneration == generation,
                        hasConnectedSessions || recoveryOwnerIsActive
                            || pendingForegroundRecoveryIsActive
                    else { return }
                    // Ensure a reconnect that was invalidated by backgrounding
                    // cannot cancel the new foreground recovery after it starts.
                    // Healthy sessions do not need a coordinator generation bump;
                    // avoiding that actor hop keeps repeated lifecycle probes
                    // ordered as connected -> connecting -> connected.
                    if let recoveryOwnerID,
                        self.selectedSessionID == recoveryOwnerID,
                        self.sessionRuntimes[recoveryOwnerID]?.reconnectState.isReconnecting
                    {
                        await self.reconnectCoordinator.cancel()
                        self.reconnectState = await self.reconnectCoordinator.state
                    }
                    guard self.lifecycleGeneration == generation,
                        hasConnectedSessions || recoveryOwnerIsActive
                            || pendingForegroundRecoveryIsActive
                    else {
                        return
                    }

                    // Collect all runtimes that were connected before backgrounding
                    let connectedRuntimes: [SessionRuntime]
                    if !self.sessionRuntimes.isEmpty {
                        connectedRuntimes = self.sessionRuntimes.values.filter {
                            $0.session.state == .connected
                                && !self.isExplicitDisconnect(for: $0.session.id)
                        }
                    } else if let runtime = self.sessionRuntime, runtime.session.state == .connected
                    {
                        connectedRuntimes = [runtime]
                    } else {
                        connectedRuntimes = []
                    }

                    if !connectedRuntimes.isEmpty {
                        // Mark active/probed sessions as connecting during probe
                        for runtime in connectedRuntimes {
                            runtime.updateSessionState(.connecting)
                            if runtime.session.id == self.selectedSessionID {
                                self.isForegroundRecoveryInProgress = true
                                self.activeSession?.state = .connecting
                            }
                        }
                        self.updateOpenSessions()

                        await withTaskGroup(of: Void.self) { group in
                            for runtime in connectedRuntimes {
                                let targetSessionID = runtime.session.id
                                let targetConnection = runtime.connection
                                let targetHost = runtime.host
                                group.addTask { @MainActor [weak self] in
                                    guard let self else { return }
                                    let isResponsive = await targetConnection.testResponsiveness(
                                        timeout: 2.5)

                                    // Stale-generation guards: ensure state was not superseded
                                    guard self.lifecycleGeneration == generation,
                                        !self.explicitlyDisconnectedSessionIDs.contains(
                                            targetSessionID),
                                        let currentRuntime = self.sessionRuntimes[targetSessionID],
                                        (currentRuntime.connection as AnyObject)
                                            === (targetConnection as AnyObject)
                                    else { return }

                                    if isResponsive {
                                        currentRuntime.updateSessionState(.connected)
                                        if self.selectedSessionID == targetSessionID {
                                            self.isForegroundRecoveryInProgress = false
                                            self.activeSession?.state = .connected
                                            self.syncLiveActivityState()
                                            self.updateIdleTimerState()
                                        }
                                        self.updateOpenSessions()
                                    } else {
                                        // Capture the probe owner and exact transport before
                                        // teardown. Selection may change while close awaits.
                                        let targetRuntime = currentRuntime
                                        let targetConnection = targetRuntime.connection
                                        await targetRuntime.disconnect()

                                        guard self.lifecycleGeneration == generation,
                                            !self.explicitlyDisconnectedSessionIDs.contains(
                                                targetSessionID),
                                            let stillCurrentRuntime = self.sessionRuntimes[
                                                targetSessionID],
                                            stillCurrentRuntime === targetRuntime,
                                            (stillCurrentRuntime.connection as AnyObject)
                                                === (targetConnection as AnyObject)
                                        else { return }

                                        guard self.selectedSessionID == targetSessionID else {
                                            // Keep a background-dropped runtime retryable, but
                                            // do not start recovery until the user selects it.
                                            targetRuntime.markRetryAvailable()
                                            self.updateOpenSessions()
                                            return
                                        }

                                        await self.teardownAuxiliaryResources(
                                            expectedSessionID: targetSessionID,
                                            expectedRuntime: targetRuntime,
                                            expectedConnection: targetConnection)
                                        guard self.lifecycleGeneration == generation,
                                            !self.explicitlyDisconnectedSessionIDs.contains(
                                                targetSessionID),
                                            self.selectedSessionID == targetSessionID,
                                            let stillCurrentRuntime = self.sessionRuntimes[
                                                targetSessionID],
                                            stillCurrentRuntime === targetRuntime,
                                            (stillCurrentRuntime.connection as AnyObject)
                                                === (targetConnection as AnyObject)
                                        else {
                                            if self.selectedSessionID != targetSessionID {
                                                targetRuntime.markRetryAvailable()
                                                self.updateOpenSessions()
                                            }
                                            return
                                        }

                                        self.isForegroundRecoveryInProgress = false
                                        self.activeSession = targetRuntime.session
                                        self.activeSession?.state = .disconnected
                                        self.updateOpenSessions()
                                        self.handleConnectionDrop(
                                            host: targetHost, sessionID: targetSessionID)
                                    }
                                }
                            }
                        }
                    } else if let host = self.activeHost,
                        self.activeSession?.state == .failed
                            || self.activeSession?.state == .disconnected
                    {
                        self.isForegroundRecoveryInProgress = false
                        // The foreground transition already invalidated any
                        // prior coordinator generation. Preserve its backoff
                        // if a newer coordinator is still active.
                        if !self.reconnectState.isReconnecting {
                            if let sessionID = self.activeSession?.id {
                                self.handleConnectionDrop(host: host, sessionID: sessionID)
                            }
                        }
                    }
                }
                foregroundRecoveryTask = recoveryTask
            } else if let host = activeHost,
                activeSession?.state == .failed || activeSession?.state == .disconnected
            {
                // An already-running coordinator owns its backoff. Do not
                // restart it for repeated .active notifications.
                if !reconnectState.isReconnecting,
                    let sessionID = activeSession?.id,
                    !isExplicitDisconnect(for: sessionID)
                {
                    handleConnectionDrop(host: host, sessionID: sessionID)
                }
            }
        default:
            break
        }
    }

    private func enterBackground() {
        guard !isSceneInBackground else { return }
        cancelSendImageForLifecycle()
        isSceneInBackground = true
        isForegroundRecoveryInProgress = false
        isNetworkRecoveryInProgress = false
        foregroundRecoveryTask?.cancel()
        foregroundRecoveryTask = nil
        lifecycleGeneration += 1
        let backgroundGeneration = lifecycleGeneration

        // A reconnect started before backgrounding cannot safely finish while the
        // scene is inactive. Invalidate every runtime owner, not only the
        // selected projection. Non-selected owners remain in a truthful,
        // retryable state so foreground return does not strand them as connecting.
        let reconnectingRuntimes = sessionRuntimes.values.filter {
            $0.reconnectState.isReconnecting || $0.session.state == .connecting
        }
        if sessionRuntimes.count == 1 {
            for runtime in reconnectingRuntimes
            where !isExplicitDisconnect(for: runtime.session.id) {
                pendingForegroundRecoverySessionIDs.insert(runtime.session.id)
            }
        }
        if reconnectState.isReconnecting || activeSession?.state == .connecting {
            activeSession?.state = .disconnected
            reconnectState = .cancelled
        }
        for runtime in reconnectingRuntimes {
            runtime.markReconnectCancelled()
            if selectedSessionID == runtime.session.id {
                _ = synchronizeSelectedSessionProjection(for: runtime)
                reconnectState = .cancelled
            }
        }
        if let recoveryOwnerID = networkRecoverySessionID {
            clearNetworkRecovery(for: recoveryOwnerID)
        }
        if !reconnectingRuntimes.isEmpty || reconnectState == .cancelled {
            Task { @MainActor [weak self] in
                await self?.reconnectCoordinator.cancel()
            }
            updateOpenSessions()
        }

        // Persist intent immediately so that if the app is suspended or terminated
        // by the system, the last active target and host are safely preserved.
        if let session = activeSession, let host = activeHost,
            let writeContext = restorationWriteContext(session: session, host: host)
        {
            let activeTarget: LastUsedMultiplexerTarget? =
                activeTmuxSessionID.flatMap { LastUsedMultiplexerTarget.tmuxTarget($0) }
                ?? activeHerdrWorkspaceID.flatMap { LastUsedMultiplexerTarget.herdrTarget($0) }
            Task { @MainActor [weak self] in
                guard let self else { return }
                let previous = try? await self.restorationStore.load()
                guard self.isCurrentRestorationWrite(writeContext),
                    self.lifecycleGeneration == backgroundGeneration
                else { return }
                let target =
                    activeTarget
                    ?? self.sessionRuntimes[session.id].flatMap {
                        self.restorationTarget(for: $0)
                    }
                    ?? previous.flatMap { metadata in
                        metadata.hostID == host.id ? self.lastUsedTarget(from: metadata) : nil
                    }
                guard self.isCurrentRestorationWrite(writeContext) else { return }
                let metadata = self.restorationMetadata(
                    hostID: host.id,
                    sessionID: session.id,
                    target: target
                )
                await self.saveRestorationMetadata(metadata, context: writeContext)
            }
        }

        // Only acquire a finite background task if we have an active connected session.
        // During this grace period (~30s to minutes depending on OS policy), the TCP
        // socket, NIO event loop, port forwarding channels, and terminal stream
        // remain completely active.
        #if canImport(UIKit)
        let hasConnectedRuntime =
            activeSession?.state == .connected
            || sessionRuntimes.values.contains { $0.session.state == .connected }
        if hasConnectedRuntime {
            endCurrentBackgroundTask()
            let taskBox = BackgroundTaskBox()
            let taskID = backgroundTaskManager.beginBackgroundTask(
                withName: "com.ervinpopescu.shh.keepalive"
            ) { [weak self, taskBox] in
                let id = taskBox.value
                self?.backgroundTaskManager.endBackgroundTask(id)
                Task { @MainActor [weak self] in
                    self?.handleBackgroundTaskExpiration(taskID: id)
                }
            }
            taskBox.value = taskID
            currentBackgroundTaskID = taskID
        }
        #endif
    }

    #if canImport(UIKit)
    private func handleBackgroundTaskExpiration(taskID: UIBackgroundTaskIdentifier) {
        if currentBackgroundTaskID == taskID {
            currentBackgroundTaskID = .invalid
        }

        // On expiration, save restoration metadata.
        // In accordance with App Store guidelines, iOS may suspend the process
        // and indefinite background TCP execution cannot be guaranteed without
        // an entitled background mode. However, we do NOT proactively close the
        // socket or cancel the session here; if the OS suspends the app while
        // keeping the socket open in the kernel, we will probe the existing
        // connection upon returning to the foreground and avoid reconnecting
        // if it survived.
        if let session = activeSession, let host = activeHost,
            let writeContext = restorationWriteContext(session: session, host: host)
        {
            let activeTarget: LastUsedMultiplexerTarget? =
                activeTmuxSessionID.flatMap { LastUsedMultiplexerTarget.tmuxTarget($0) }
                ?? activeHerdrWorkspaceID.flatMap { LastUsedMultiplexerTarget.herdrTarget($0) }
            Task { @MainActor [weak self] in
                guard let self else { return }
                let previous = try? await self.restorationStore.load()
                guard self.isCurrentRestorationWrite(writeContext) else { return }
                let target =
                    activeTarget
                    ?? self.sessionRuntimes[session.id].flatMap {
                        self.restorationTarget(for: $0)
                    }
                    ?? previous.flatMap { metadata in
                        metadata.hostID == host.id ? self.lastUsedTarget(from: metadata) : nil
                    }
                guard self.isCurrentRestorationWrite(writeContext) else { return }
                let metadata = self.restorationMetadata(
                    hostID: host.id,
                    sessionID: session.id,
                    target: target
                )
                await self.saveRestorationMetadata(metadata, context: writeContext)
            }
        }
    }

    private func endCurrentBackgroundTask() {
        let taskID = currentBackgroundTaskID
        currentBackgroundTaskID = .invalid
        if taskID != .invalid {
            backgroundTaskManager.endBackgroundTask(taskID)
        }
    }
    #endif

    func restoreLastSession() async {
        guard let metadata = try? await restorationStore.load(),
            let hosts = try? await catalog.listHosts(),
            let host = hosts.first(where: { $0.id == metadata.hostID })
        else {
            return
        }
        let target: String?
        if case .tmux(let sessionID) = lastUsedTarget(from: metadata) {
            target = sessionID
        } else {
            target = nil
        }
        await connect(to: host, restoringTmuxSessionID: target, sessionID: metadata.sessionID)
    }

    /// Opens a Live Activity deep link only when its opaque session ID matches
    /// the active session or locally persisted restoration metadata.
    @discardableResult
    func openLiveActivitySession(sessionID: UUID) async -> Bool {
        if let activeSession,
            activeSession.id == sessionID,
            activeSession.state != .disconnected
        {
            return true
        }
        if let runtime = sessionRuntimes[sessionID], runtime.session.state != .disconnected {
            selectSession(id: sessionID)
            return true
        }
        guard let metadata = try? await restorationStore.load(),
            metadata.sessionID == sessionID,
            let hosts = try? await catalog.listHosts(),
            let host = hosts.first(where: { $0.id == metadata.hostID })
        else {
            return false
        }
        let target: String?
        if case .tmux(let tmuxSessionID) = lastUsedTarget(from: metadata) {
            target = tmuxSessionID
        } else {
            target = nil
        }
        await connect(to: host, restoringTmuxSessionID: target, sessionID: sessionID)
        return activeSession?.id == sessionID
    }

    func approvePendingHostKey(permanently: Bool) async {
        guard let challenge = pendingTrustChallenge, let host = pendingTrustHost else { return }
        if permanently {
            await trustStore.save(challenge)
            try? await syncSharedCatalogAndTrust()
        } else {
            await trustStore.trustOnce(challenge)
        }
        pendingTrustChallenge = nil
        if let hostID = pendingTrustHost?.id {
            clearConnectionFailures(forHostID: hostID)
        }
        pendingTrustHost = nil
        lastSFTPFailure = nil
        sftpErrorMessage = nil
        await connect(to: host)
    }

    func rejectPendingHostKey() {
        let rejectedHost = pendingTrustHost
        if let hostID = rejectedHost?.id {
            clearConnectionFailures(forHostID: hostID)
        }
        pendingTrustChallenge = nil
        pendingTrustHost = nil
        if sessionRuntimes.isEmpty || activeHost?.id == rejectedHost?.id {
            activeSession?.state = .disconnected
            redactor = Redactor()
        }
    }

    @discardableResult
    func sendRawInteractive(_ data: Data) async -> Bool {
        guard activeSession?.state == .connected,
            let runtime = sessionRuntime
        else { return false }
        return await runtime.send(data)
    }

    @discardableResult
    func sendPinnedLiteral(_ literal: String, approved: Bool = false) async -> Bool {
        guard CommandDialModel.isInsertOnlyTerminalText(literal) else { return false }
        switch CommandPolicy().classify(literal) {
        case .safe: break
        case .reviewRequired: guard approved else { return false }
        case .blocked: return false
        }
        return await sendRawInteractive(Data(literal.utf8))
    }

    @discardableResult
    func sendValidatedCommand(_ command: String, approved: Bool = false) async -> Bool {
        guard CommandPolicy().canSend(command, approved: approved),
            activeSession?.state == .connected,
            let runtime = sessionRuntime
        else { return false }
        let sent = await runtime.send(Data(command.utf8))
        if !sent {
            let message = "Send failed: Connection failed."
            terminalText += "\n" + message
            terminalController.feed("\r\n\u{1b}[31m[" + message + "]\u{1b}[0m\r\n")
        }
        return sent
    }

    @discardableResult
    func send(_ command: String, approved: Bool = false) async -> Bool {
        await sendValidatedCommand(command, approved: approved)
    }

    private var canUseSingleSessionAuxiliaryFeatures: Bool {
        guard sessionRuntimes.count <= 1 else { return false }
        guard let selectedID = selectedSessionID else { return sessionRuntimes.isEmpty }
        return auxiliarySessionID == selectedID
            && activeSession?.id == selectedID
            && activeSession?.state == .connected
    }

    private func canUseSingleSessionAuxiliaryFeatures(for host: Host) -> Bool {
        canUseSingleSessionAuxiliaryFeatures
            && (sessionRuntimes.isEmpty || activeHost?.id == host.id)
    }

    private func rebindAuxiliaryResourcesIfNeeded() async {
        guard sessionRuntimes.count == 1,
            let selectedID = selectedSessionID,
            let runtime = sessionRuntimes[selectedID],
            runtime.session.state == .connected,
            activeHost?.id == runtime.host.id
        else { return }
        guard auxiliarySessionID != selectedID else { return }

        auxiliarySetupGeneration &+= 1
        let setupGeneration = auxiliarySetupGeneration
        let ownerRuntime = runtime
        let ownerConnection = runtime.connection
        let manager: any PortForwardingManaging
        if let custom = customPortForwardingManager {
            manager = custom
        } else if isDemo {
            manager = portForwardingManager ?? DemoPortForwardingManager()
        } else if let live = ownerConnection as? LiveSSHConnection {
            manager = PortForwardingManager(connection: live)
        } else {
            manager = UnavailablePortForwardingManager()
        }
        portForwardingManager = manager
        guard let managerGeneration = await rebindForwardingManager(manager) else { return }
        let started = await autoStartForwardingRules(
            for: ownerRuntime.host,
            manager: manager,
            ownerContext: AuxiliaryOwnerContext(
                sessionID: selectedID,
                runtimeIdentity: ObjectIdentifier(ownerRuntime),
                connectionIdentity: ObjectIdentifier(ownerConnection as AnyObject),
                setupGeneration: setupGeneration
            ),
            managerGeneration: managerGeneration
        )
        guard auxiliarySetupGeneration == setupGeneration,
            sessionRuntimes.count == 1,
            selectedSessionID == selectedID,
            sessionRuntimes[selectedID] === ownerRuntime,
            ownerRuntime.session.state == .connected,
            activeHost?.id == ownerRuntime.host.id,
            (ownerRuntime.connection as AnyObject) === (ownerConnection as AnyObject),
            isCurrentForwardingManager(manager)
        else {
            // The awaited starts belong to an obsolete owner. Stop them before
            // any newer selection/connect can observe them as active.
            await stopAllForwarding(manager: manager, generation: managerGeneration)
            return
        }

        auxiliarySessionID = selectedID
        portForwardingManager = manager
        forwardingManagerOperationGeneration = managerGeneration
        publishForwardingSessions(started)
        let ownerContext = auxiliaryOwnerContext(for: ownerRuntime, connection: ownerConnection)
        startForwardingMonitoring(manager: manager, ownerContext: ownerContext)
        Task { [weak self] in
            guard let self,
                self.auxiliarySetupGeneration == setupGeneration,
                self.selectedSessionID == selectedID,
                self.sessionRuntimes[selectedID] === ownerRuntime
            else { return }
            await self.refreshTmuxState()
            await self.setupSFTPForHost(ownerRuntime.host)
        }
    }

    private func synchronizeSelectedMoshState(for runtime: SessionRuntime) {
        moshStateTask?.cancel()
        moshStateTask = nil

        // Clear the old selected projection before awaiting the new controller.
        // MoshSessionInfo contains key material, so zeroize it synchronously as
        // part of the selection boundary rather than leaving A visible while B
        // is still being queried.
        moshState = nil
        moshSessionInfo?.zeroize()
        moshSessionInfo = nil
        networkRoamingState = nil

        guard let controller = runtime.connection as? any MoshSessionControlling else {
            return
        }

        let sessionID = runtime.session.id
        moshStateTask = Task { @MainActor [weak self] in
            guard let self else { return }
            let info = await controller.sessionInfo
            guard
                self.isSelectedMoshOwner(
                    sessionID: sessionID, runtime: runtime, controller: controller)
            else { return }
            let state = await controller.moshState
            guard
                self.isSelectedMoshOwner(
                    sessionID: sessionID, runtime: runtime, controller: controller)
            else { return }
            let roaming = await controller.roamingState
            guard
                self.isSelectedMoshOwner(
                    sessionID: sessionID, runtime: runtime, controller: controller)
            else { return }
            self.moshSessionInfo = info
            self.moshState = state
            self.networkRoamingState = roaming
            self.startMoshMonitoring(for: controller, runtime: runtime)
        }
    }

    func disconnect() async {
        #if canImport(UIKit)
        endCurrentBackgroundTask()
        #endif

        // Capture every owner before the first await. This operation may yield
        // to a new selection, so no continuation below may infer ownership from
        // the mutable selected-session projection.
        let ownerSessionID = selectedSessionID ?? activeSession?.id
        let ownerRuntime = ownerSessionID.flatMap { sessionRuntimes[$0] }
        let ownerConnection = ownerRuntime?.connection
        let ownerWasSelected = ownerSessionID != nil && selectedSessionID == ownerSessionID
        let ownerLifecycleGeneration = lifecycleGeneration
        let pendingSessionID = pendingConnectingSession?.id
        let initialPendingProjection =
            ownerRuntime == nil
            && pendingSessionID == ownerSessionID
            && selectedSessionID == nil
            && activeSession?.id == pendingSessionID
        let ownsPendingAdmission =
            pendingSessionID == ownerSessionID
            && (ownerWasSelected || initialPendingProjection)
        let recoveryOwnerID = networkRecoverySessionID
        let recoveryOwnerRuntime = recoveryOwnerID.flatMap { sessionRuntimes[$0] }
        pendingForegroundRecoverySessionIDs.remove(ownerSessionID)
        let ownerHost = ownerWasSelected ? activeHost : nil
        let ownerSession = ownerWasSelected ? activeSession : nil
        let ownerTarget: LastUsedMultiplexerTarget? = {
            guard ownerWasSelected else { return nil }
            return activeTmuxSessionID.flatMap(LastUsedMultiplexerTarget.tmuxTarget)
                ?? activeHerdrWorkspaceID.flatMap(LastUsedMultiplexerTarget.herdrTarget)
        }()

        func ownsCapturedRuntime() -> Bool {
            guard let ownerSessionID, let ownerRuntime, let ownerConnection,
                let currentRuntime = sessionRuntimes[ownerSessionID],
                currentRuntime === ownerRuntime
            else { return false }
            return (currentRuntime.connection as AnyObject) === (ownerConnection as AnyObject)
        }

        func ownsSelectedProjection() -> Bool {
            // Selection may move away and back while the captured runtime's
            // teardown awaits. The exact runtime identity is authoritative;
            // a stale selection generation alone must not reject reconciliation.
            ownsCapturedRuntime()
                && ownerWasSelected
                && selectedSessionID == ownerSessionID
                && activeSession?.id == ownerSessionID
        }

        // Invalidate owner-scoped lifecycle work before yielding. Do not write
        // this generation after an await, because a new connection may advance
        // it while voice cancellation is suspended.
        lifecycleGeneration = ownerLifecycleGeneration + 1
        isSceneInBackground = false

        cancelSendImageForLifecycle()
        resetVoiceState()
        await cancelVoiceRecording()
        // Voice cancellation is global, but all session state remains scoped to
        // the captured owner after this await.

        if let ownerSessionID {
            explicitlyDisconnectedSessionIDs.insert(ownerSessionID)
            invalidateRedactionValidity(for: ownerSessionID)
            deferredInterfaceRecoverySessionIDs.remove(ownerSessionID)
        } else {
            fallbackExplicitDisconnect = true
        }
        if let pendingSessionID, ownsPendingAdmission {
            invalidateRedactionValidity(for: pendingSessionID)
            // The pending slot is an admission token. Clear it before any
            // further await so a late transport result cannot clear a newer connection.
            pendingConnectingSession = nil
            if ownerRuntime == nil, activeSession?.id == pendingSessionID {
                activeSession?.state = .disconnected
                activeHost = nil
                terminalText = ""
                reconnectState = .cancelled
                redactor = Redactor()
                liveActivityManager.end(sessionID: pendingSessionID)
            }
        }

        // Only cancel a coordinator owned by this disconnect. A selection switch
        // can make another runtime the recovery owner while cancellation waits.
        let cancelsOwnerRecovery =
            recoveryOwnerID == ownerSessionID
            && recoveryOwnerRuntime != nil
        // The lifecycle generation above invalidates a pre-existing foreground
        // task without cancelling a task that a newly selected session may have
        // installed while voice cancellation was suspended.
        if ownsSelectedProjection() {
            isForegroundRecoveryInProgress = false
            isNetworkRecoveryInProgress = false
        }
        if ownsSelectedProjection() {
            tmuxRefreshGeneration += 1
        }

        if let ownerHost, let ownerSession, let ownerTarget {
            await saveRestorationMetadata(
                restorationMetadata(
                    hostID: ownerHost.id,
                    sessionID: ownerSession.id,
                    target: ownerTarget
                ))
            guard ownsCapturedRuntime() else { return }
        }

        if ownsSelectedProjection() {
            activeHost = nil
            liveActivityManager.end(sessionID: ownerSessionID ?? UUID())
        }

        if cancelsOwnerRecovery {
            await reconnectCoordinator.cancel()
            guard ownsCapturedRuntime() else { return }
            if let ownerSessionID, networkRecoverySessionID == ownerSessionID {
                clearNetworkRecovery(for: ownerSessionID)
            }
        }
        if ownsSelectedProjection() {
            reconnectState = .idle
        }

        if let ownerRuntime, ownsCapturedRuntime() {
            await ownerRuntime.disconnect()
            guard ownsCapturedRuntime() else { return }
            if ownsSelectedProjection() {
                activeSession = ownerRuntime.session
                activeSession?.state = .disconnected
                activeHost = ownerRuntime.host
            }
        }

        guard ownsCapturedRuntime() else { return }
        if ownsSelectedProjection() {
            moshStateTask?.cancel()
            moshStateTask = nil
            moshState = nil
            moshSessionInfo?.zeroize()
            moshSessionInfo = nil
            networkRoamingState = nil
            redactor = Redactor()
            tmuxError = nil
        }
        updateOpenSessions()

        // Auxiliary resources are single-session-only. Never tear down an
        // adapter after selection moved, because it may now belong to B.
        if ownsSelectedProjection(), let ownerSessionID, let ownerRuntime {
            await teardownAuxiliaryResources(
                expectedSessionID: ownerSessionID,
                expectedRuntime: ownerRuntime,
                expectedConnection: ownerConnection)
            guard ownsCapturedRuntime() else { return }
        } else if ownerSessionID == nil, selectedSessionID == nil {
            await teardownAuxiliaryResources()
            guard ownerSessionID == nil, selectedSessionID == nil else { return }
        }
    }

    /// Teardown auxiliary services (port forwarding, SFTP, telemetry, multiplexer)
    /// safely and idempotently when closing or disconnecting single/final sessions.
    func teardownAuxiliaryResources(
        expectedSessionID: UUID? = nil,
        expectedRuntime: SessionRuntime? = nil,
        expectedConnection: (any SSHConnection)? = nil,
        transferTaskIDs: Set<UUID>? = nil
    ) async {
        if let expectedSessionID {
            guard selectedSessionID == expectedSessionID,
                let expectedRuntime,
                sessionRuntimes[expectedSessionID] === expectedRuntime,
                auxiliarySessionID == expectedSessionID
            else { return }
            if let expectedConnection {
                guard
                    (expectedRuntime.connection as AnyObject) === (expectedConnection as AnyObject)
                else { return }
            }
        }
        auxiliarySetupGeneration &+= 1
        let teardownGeneration = auxiliarySetupGeneration
        auxiliarySessionID = nil
        closeSecondaryPane()

        // Clear every selected-session projection before any asynchronous stop.
        // A new selection must never observe the old owner's forwarding, SFTP,
        // editor, or loading state while its teardown is in flight.
        forwardingStreamTask?.cancel()
        forwardingStreamTask = nil
        forwardingSessions = []
        forwardingErrorMessage = nil
        activeTmuxSessionID = nil
        tmuxSessions = []
        isTmuxServerRunning = false
        isProbingTmux = false
        tmuxAvailability = .unavailable(reason: "Not connected")
        tmuxError = nil
        herdrRefreshGeneration += 1
        stopHerdrPolling()
        herdrWorkspaces = []
        isProbingHerdr = false
        herdrAvailability = .unavailable(reason: "Not connected")
        herdrError = nil
        activeHerdrWorkspaceID = nil
        for poller in telemetryPollers.values { poller.stopPolling() }
        telemetryPollers.removeAll()
        moshStateTask?.cancel()
        moshStateTask = nil
        moshState = nil
        moshSessionInfo?.zeroize()
        moshSessionInfo = nil
        networkRoamingState = nil
        closePreview()
        closeEditor()
        currentDirectoryFiles = []
        currentPath = RemotePath("/home/dev")
        isLoadingDirectory = false
        directoryErrorMessage = nil
        sftpErrorMessage = nil
        lastSFTPFailure = nil
        sftpSetupGeneration += 1
        directoryRequestGenerations.removeAll()
        transferQueueGeneration &+= 1
        cancelSendImage()
        let capturedTransferTaskIDs = transferTaskIDs ?? Set(activeTransferTasks.keys)
        for taskID in capturedTransferTaskIDs {
            activeTransferTasks[taskID]?.cancel()
            activeTransferTasks.removeValue(forKey: taskID)
        }
        drainPendingConflicts()
        directoryCache.removeAll()
        cleanTemporaryTransfersDirectory(removeAll: true)
        fallbackTerminalController.reset()
        updateIdleTimerState()

        let manager = portForwardingManager
        let managerGeneration = forwardingManagerOperationGeneration
        let liveSFTP = customSFTPRepository == nil ? sftpRepository as? LiveSFTPRepository : nil
        if let manager, let managerGeneration {
            await stopAllForwarding(manager: manager, generation: managerGeneration)
        }
        for taskID in capturedTransferTaskIDs {
            await transferCoordinator.cancel(id: taskID)
            await transferCoordinator.remove(id: taskID)
        }
        // The captured manager belongs to the teardown owner. Revalidate before
        // closing the second captured resource so a new selection is never
        // mistaken for the old owner's adapter.
        let ownsAfterForwardingStop: Bool = {
            guard auxiliarySetupGeneration == teardownGeneration else { return false }
            if let expectedSessionID {
                guard selectedSessionID == expectedSessionID,
                    let expectedRuntime,
                    sessionRuntimes[expectedSessionID] === expectedRuntime
                else { return false }
                if let expectedConnection {
                    guard
                        (expectedRuntime.connection as AnyObject)
                            === (expectedConnection as AnyObject)
                    else { return false }
                }
            }
            return true
        }()
        await liveSFTP?.close()

        let stillOwner: Bool = {
            guard ownsAfterForwardingStop,
                auxiliarySetupGeneration == teardownGeneration
            else { return false }
            if let expectedSessionID {
                guard selectedSessionID == expectedSessionID,
                    let expectedRuntime,
                    sessionRuntimes[expectedSessionID] === expectedRuntime
                else { return false }
                if let expectedConnection {
                    guard
                        (expectedRuntime.connection as AnyObject)
                            === (expectedConnection as AnyObject)
                    else { return false }
                }
            }
            return true
        }()
        guard stillOwner else { return }
        transferQueueState = await transferCoordinator.snapshot()
        forwardingManagerOperationGeneration = nil
        if !isDemo { portForwardingManager = nil }
        if customSFTPRepository == nil, !isDemo { sftpRepository = nil }
    }

    /// Resolves the exact identity selected by a host without exposing secret
    /// material or querying credentials before host-key acceptance. The host
    /// remains unchanged when the descriptor is stale.
    private func resolveIdentity(for host: Host) async throws -> IdentityDescriptor? {
        guard let identityID = host.identityID else { return nil }
        let identities = try await catalog.identities()
        guard let identity = identities.first(where: { $0.id == identityID }) else {
            throw TransportError.missingIdentity(id: identityID)
        }
        let reconciliation = IdentityCatalogReconciliation(hosts: [host], identities: identities)
        guard !reconciliation.duplicateIdentityIDs.contains(identityID) else {
            throw TransportError.identityCollision(id: identityID)
        }
        return identity
    }

    /// Loads sensitive private key and Mosh secrets for one newly opened
    /// connection. The caller installs the returned redactor on that connection's
    /// runtime, so opening a session cannot borrow the selected-session projection.
    /// All readable credentials are protected unconditionally regardless of
    /// catalog collision status.
    @discardableResult
    func loadRedactionSecret(
        for host: Host,
        connection: any SSHConnection,
        sessionID: UUID? = nil,
        validityToken: UUID? = nil
    ) async -> Redactor {
        var secrets: [String] = []
        let identities = (try? await catalog.identities()) ?? []
        if let identityID = host.identityID,
            let identity = identities.first(where: { $0.id == identityID }),
            let secret = try? await credentialStore.load(reference: identity.keychainReference),
            let value = String(data: secret, encoding: .utf8), !value.isEmpty
        {
            secrets.append(value)
        }
        if case .cloudflareAccess(let options) = host.connection,
            !options.clientSecretKeychainRef.isEmpty,
            let secret = try? await credentialStore.load(
                reference: options.clientSecretKeychainRef),
            let value = String(data: secret, encoding: .utf8),
            !value.isEmpty
        {
            secrets.append(value)
        }
        if case .proxyJump(let jumpOpts) = host.connection {
            let hosts = (try? await catalog.listHosts()) ?? []
            for hop in jumpOpts.config.hops {
                let idID: UUID?
                switch hop {
                case .hostID(let hid):
                    idID = hosts.first(where: { $0.id == hid })?.identityID
                case .endpoint(let ep):
                    idID = ep.identityID
                }
                if let idID,
                    let ident = identities.first(where: { $0.id == idID }),
                    let secret = try? await credentialStore.load(
                        reference: ident.keychainReference),
                    let value = String(data: secret, encoding: .utf8), !value.isEmpty
                {
                    secrets.append(value)
                }
            }
        }
        if let moshController = connection as? any MoshSessionControlling {
            let key = await moshController.sessionInfo.sessionKey.base64String
            if !key.isEmpty {
                secrets.append(key)
            }
        }
        if let sessionID, let validityToken,
            !isCurrentRedactionValidity(sessionID: sessionID, token: validityToken)
        {
            return Redactor()
        }
        return Redactor(secrets: secrets)
    }

    internal func redacted(_ data: Data) -> Data {
        let selectedRedactor = selectedSessionRuntime?.redactor ?? redactor
        guard !selectedRedactor.secrets.isEmpty else { return data }
        return Data(selectedRedactor.redact(String(decoding: data, as: UTF8.self)).utf8)
    }

    // MARK: - Live Tmux Management

    func isTmuxSessionActive(_ session: TmuxSessionInfo) -> Bool {
        guard let activeID = activeTmuxSessionID else { return false }
        return activeID == session.sessionID || activeID == session.name
    }

    func updateActiveHostPreferences(autoAttachTmux: Bool, defaultTmuxSession: String? = nil)
        async throws
    {
        guard let host = activeHost else { return }

        // The legacy default target is intentionally ignored. Automatic attachment
        // is resolved only from the last successfully used restoration target.
        let updatedHost = try Host(
            id: host.id,
            name: host.name,
            hostname: host.hostname,
            port: host.port,
            username: host.username,
            groupID: host.groupID,
            tagIDs: host.tagIDs,
            identityID: host.identityID,
            connection: host.connection,
            health: host.health,
            lastUsedAt: host.lastUsedAt,
            tmuxPreferences: HostTmuxPreferences(
                defaultSession: nil,
                autoAttach: autoAttachTmux
            )
        )

        activeHost = updatedHost
        try await catalog.save(updatedHost)
    }

    private func automaticTmuxTarget(
        for host: Host,
        explicitTarget: String?,
        allowStoredTarget: Bool
    ) async -> String? {
        if let explicitTarget {
            let trimmed = explicitTarget.trimmingCharacters(in: .whitespacesAndNewlines)
            return LastUsedMultiplexerTarget.tmuxTarget(trimmed) == nil ? nil : trimmed
        }
        guard allowStoredTarget || host.autoAttachTmux,
            let metadata = try? await restorationStore.load(),
            metadata.hostID == host.id,
            let target = lastUsedTarget(from: metadata),
            case .tmux(let sessionID) = target
        else {
            return nil
        }
        return sessionID
    }

    private func lastUsedTarget(from metadata: SessionRestorationMetadata)
        -> LastUsedMultiplexerTarget?
    {
        if let target = metadata.lastUsedMultiplexerTarget {
            return target
        }
        // Decode old records for compatibility. Host defaults are never read
        // here, so this cannot revive a default configured on a Host.
        if let legacy = metadata.tmuxSessionID {
            return LastUsedMultiplexerTarget.tmuxTarget(legacy)
        }
        return nil
    }

    private func restorationMetadata(
        hostID: UUID,
        sessionID: UUID,
        target: LastUsedMultiplexerTarget?,
        timestamp: Date = Date()
    ) -> SessionRestorationMetadata {
        let tmuxID: String?
        if case .tmux(let id) = target {
            tmuxID = id
        } else {
            tmuxID = nil
        }
        return SessionRestorationMetadata(
            hostID: hostID,
            sessionID: sessionID,
            tmuxSessionID: tmuxID,
            lastUsedMultiplexerTarget: target,
            timestamp: timestamp
        )
    }

    private func restoreHerdrTargetIfNeeded(
        for host: Host,
        session: TerminalSession,
        preferredTarget: LastUsedMultiplexerTarget? = nil
    ) async {
        let target: LastUsedMultiplexerTarget?
        if let preferredTarget {
            target = preferredTarget
        } else {
            target = (try? await restorationStore.load()).flatMap { metadata in
                guard metadata.hostID == host.id else { return nil }
                return lastUsedTarget(from: metadata)
            }
        }
        guard let target, case .herdr(let workspaceID) = target else { return }
        guard activeSession?.id == session.id,
            activeSession?.state == .connected,
            !isExplicitDisconnect(for: session.id)
        else { return }
        guard let workspace = herdrWorkspaces.first(where: { $0.id == workspaceID }) else {
            activeHerdrWorkspaceID = nil
            herdrError =
                "Remembered Herdr workspace is no longer available. Select a workspace to recover it."
            return
        }
        activeHerdrWorkspaceID = workspace.id
    }

    @discardableResult
    private func handleTmuxTarget(
        _ target: String,
        on connection: any SSHConnection,
        host: Host,
        session: TerminalSession
    ) async -> Bool {
        let trimmed = target.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.hasPrefix("$") {
            if let executor = connection as? SSHCommandExecuting {
                do {
                    let check = try await executor.executeCommand(
                        TmuxCommand.hasSession(id: trimmed), timeout: 5.0)
                    guard activeSession?.id == session.id,
                        activeSession?.state == .connected,
                        !isExplicitDisconnect,
                        (self.connection as AnyObject) === (connection as AnyObject)
                    else {
                        return false
                    }
                    if !check.isSuccess {
                        self.activeTmuxSessionID = nil
                        self.tmuxError =
                            "Remembered tmux session \(trimmed) no longer exists on remote host. Select a session to recover it."
                        return false
                    }
                } catch {
                    guard activeSession?.id == session.id,
                        activeSession?.state == .connected,
                        !isExplicitDisconnect,
                        (self.connection as AnyObject) === (connection as AnyObject)
                    else {
                        return false
                    }
                    self.activeTmuxSessionID = nil
                    self.tmuxError =
                        "Failed to verify tmux session \(trimmed): \(error.localizedDescription) Select a session to recover it."
                    return false
                }
            }
            guard activeSession?.id == session.id,
                activeSession?.state == .connected,
                !isExplicitDisconnect,
                (self.connection as AnyObject) === (connection as AnyObject)
            else {
                return false
            }
            return await attachTmuxSession(id: trimmed)
        } else if !trimmed.isEmpty {
            // A remembered name may be attached only if it already exists. Never
            // create a session during restoration.
            guard let executor = connection as? SSHCommandExecuting else { return false }
            let result = try? await executor.executeCommand(TmuxCommand.listSessions, timeout: 5.0)
            guard activeSession?.id == session.id,
                activeSession?.state == .connected,
                !isExplicitDisconnect,
                (self.connection as AnyObject) === (connection as AnyObject),
                let result,
                result.isSuccess
            else {
                return false
            }
            guard
                let match = try? TmuxListSessionsParser.parse(result.stdout).first(where: {
                    $0.name == trimmed
                })
            else {
                activeTmuxSessionID = nil
                tmuxError =
                    "Remembered tmux session \(trimmed) no longer exists on remote host. Select a session to recover it."
                return false
            }
            return await attachTmuxSession(id: match.sessionID)
        }
        return false
    }

    @discardableResult
    func probeTmux() async -> TmuxAvailability {
        guard canUseSingleSessionAuxiliaryFeatures else {
            return .unavailable(reason: "Auxiliary features require one selected session")
        }
        if connection is any MoshSessionControlling {
            return tmuxAvailability
        }
        guard let currentSession = activeSession, currentSession.state == .connected,
            let executor = connection as? SSHCommandExecuting
        else {
            let avail = TmuxAvailability.unavailable(reason: "Not connected")
            if activeSession == nil || activeSession?.state != .connected {
                tmuxAvailability = avail
            }
            return avail
        }
        let sessionID = currentSession.id
        let connObj = connection as AnyObject
        do {
            let result = try await executor.executeCommand(TmuxCommand.probe, timeout: 5.0)
            guard activeSession?.id == sessionID,
                activeSession?.state == .connected,
                !isExplicitDisconnect,
                (connection as AnyObject) === connObj
            else {
                return .unavailable(reason: "Session disconnected")
            }
            let avail = TmuxAvailability.parse(result: result)
            tmuxAvailability = avail
            return avail
        } catch {
            guard activeSession?.id == sessionID,
                activeSession?.state == .connected,
                !isExplicitDisconnect,
                (connection as AnyObject) === connObj
            else {
                return .unavailable(reason: "Session disconnected")
            }
            let avail = TmuxAvailability.unavailable(reason: error.localizedDescription)
            tmuxAvailability = avail
            return avail
        }
    }

    @discardableResult
    func listTmuxSessions(expectedGeneration: Int? = nil) async -> [TmuxSessionInfo] {
        guard canUseSingleSessionAuxiliaryFeatures,
            let currentSession = activeSession, currentSession.state == .connected,
            let executor = connection as? SSHCommandExecuting
        else {
            tmuxSessions = []
            isTmuxServerRunning = false
            return []
        }
        let sessionID = currentSession.id
        let connObj = connection as AnyObject
        do {
            let result = try await executor.executeCommand(TmuxCommand.listSessions, timeout: 5.0)
            guard activeSession?.id == sessionID,
                activeSession?.state == .connected,
                !isExplicitDisconnect,
                (connection as AnyObject) === connObj,
                expectedGeneration == nil || expectedGeneration == tmuxRefreshGeneration
            else {
                return []
            }
            if result.isSuccess {
                guard expectedGeneration == nil || expectedGeneration == tmuxRefreshGeneration
                else {
                    return []
                }
                do {
                    let parsed = try TmuxListSessionsParser.parse(result.stdout)
                    guard expectedGeneration == nil || expectedGeneration == tmuxRefreshGeneration
                    else {
                        return []
                    }
                    tmuxSessions = parsed
                    isTmuxServerRunning = true
                    tmuxError = nil

                    if let active = activeTmuxSessionID {
                        if let matched = parsed.first(where: {
                            $0.sessionID == active || $0.name == active
                        }) {
                            if active != matched.sessionID {
                                activeTmuxSessionID = matched.sessionID
                                if let host = activeHost,
                                    let target = LastUsedMultiplexerTarget.tmuxTarget(
                                        matched.sessionID)
                                {
                                    await saveRestorationMetadata(
                                        restorationMetadata(
                                            hostID: host.id,
                                            sessionID: sessionID,
                                            target: target
                                        ))
                                }
                            }
                        } else {
                            // A remote disappearance is recovery state, not a
                            // failed selection. Keep the last target for an
                            // explicit recovery attempt.
                            activeTmuxSessionID = nil
                            tmuxError =
                                "Remembered tmux session is no longer available. Select a session to recover it."
                        }
                    }

                    return parsed
                } catch {
                    tmuxSessions = []
                    isTmuxServerRunning = true
                    let parseMessage: String
                    if let parseError = error as? TmuxParseError {
                        parseMessage =
                            "Failed to parse tmux sessions due to format incompatibility. Refresh sessions or check remote tmux version. (\(parseError.localizedDescription))"
                    } else {
                        parseMessage =
                            "Failed to parse tmux sessions due to format incompatibility. Refresh sessions or check remote tmux version."
                    }
                    tmuxError = parseMessage
                    return []
                }
            } else {
                let combinedErr = (result.stderr + " " + result.stdout).lowercased()
                if combinedErr.contains("no server running") {
                    tmuxSessions = []
                    isTmuxServerRunning = false
                    tmuxError = nil
                    if activeTmuxSessionID != nil {
                        activeTmuxSessionID = nil
                        tmuxError =
                            "Remembered tmux session is no longer available. Select a session to recover it."
                    }
                } else if combinedErr.contains("no sessions") {
                    tmuxSessions = []
                    isTmuxServerRunning = true
                    tmuxError = nil
                    if activeTmuxSessionID != nil {
                        activeTmuxSessionID = nil
                        tmuxError =
                            "Remembered tmux session is no longer available. Select a session to recover it."
                    }
                } else {
                    tmuxSessions = []
                    isTmuxServerRunning = false
                    let msg = result.stderr.trimmingCharacters(in: .whitespacesAndNewlines)
                    tmuxError =
                        msg.isEmpty
                        ? "Failed to list tmux sessions (exit code \(result.exitCode))" : msg
                }
                return []
            }
        } catch {
            guard activeSession?.id == sessionID,
                activeSession?.state == .connected,
                !isExplicitDisconnect,
                (connection as AnyObject) === connObj
            else {
                return []
            }
            tmuxSessions = []
            isTmuxServerRunning = false
            tmuxError = error.localizedDescription
            return []
        }
    }

    func refreshTmuxState() async {
        guard canUseSingleSessionAuxiliaryFeatures else { return }
        if connection is any MoshSessionControlling {
            return
        }
        guard let currentSession = activeSession, currentSession.state == .connected,
            let currentConnection = connection, currentConnection is SSHCommandExecuting
        else {
            tmuxAvailability = .unavailable(reason: "Not connected")
            tmuxSessions = []
            isTmuxServerRunning = false
            return
        }
        let sessionID = currentSession.id
        let connObj = currentConnection as AnyObject
        tmuxRefreshGeneration += 1
        let generation = tmuxRefreshGeneration
        isProbingTmux = true
        defer {
            if tmuxRefreshGeneration == generation {
                isProbingTmux = false
            }
        }

        let availability = await probeTmux()
        guard tmuxRefreshGeneration == generation,
            activeSession?.id == sessionID,
            activeSession?.state == .connected,
            !isExplicitDisconnect,
            (connection as AnyObject) === connObj
        else {
            return
        }

        if availability.isAvailable {
            _ = await listTmuxSessions(expectedGeneration: generation)
            guard tmuxRefreshGeneration == generation,
                activeSession?.id == sessionID,
                activeSession?.state == .connected,
                !isExplicitDisconnect,
                (connection as AnyObject) === connObj
            else {
                return
            }
        } else {
            tmuxSessions = []
            isTmuxServerRunning = false
            if activeTmuxSessionID != nil {
                activeTmuxSessionID = nil
                tmuxError = "Tmux is unavailable. Select a session to recover it."
            }
        }
    }

    private func resizePTY(
        _ size: TerminalSize,
        on conn: any SSHConnection,
        sessionID: UUID
    ) async -> Bool {
        guard activeSession?.id == sessionID,
            activeSession?.state == .connected,
            !isExplicitDisconnect,
            let currentConnection = connection,
            (currentConnection as AnyObject) === (conn as AnyObject),
            let runtime = sessionRuntime
        else {
            return false
        }
        let resized = await runtime.resize(size)
        if !resized {
            tmuxError = "Failed to resize terminal."
        }
        return resized
    }

    private func synchronizeViewportAndResize(
        _ conn: any SSHConnection,
        sessionID: UUID
    ) async -> Bool {
        guard activeSession?.id == sessionID,
            activeSession?.state == .connected,
            !isExplicitDisconnect,
            let currentConnection = connection,
            (currentConnection as AnyObject) === (conn as AnyObject)
        else {
            return false
        }

        // A viewport can change while resize() is suspended, including while a
        // debounced callback is queued. Reconcile until the measured viewport
        // equals the size the remote PTY most recently accepted.
        for _ in 0..<8 {
            terminalController.synchronizeViewportMeasurement()
            guard terminalController.hasMeasuredViewport else {
                return true
            }
            let requestedSize = terminalController.size
            guard await resizePTY(requestedSize, on: conn, sessionID: sessionID) else {
                if tmuxError == nil,
                    activeSession?.id == sessionID,
                    activeSession?.state == .connected,
                    !isExplicitDisconnect,
                    let currentConnection = connection,
                    (currentConnection as AnyObject) === (conn as AnyObject)
                {
                    tmuxError = "Failed to resize terminal."
                }
                return false
            }
            terminalController.synchronizeViewportMeasurement()
            guard terminalController.hasMeasuredViewport else { return true }
            if terminalController.size == requestedSize {
                return true
            }
        }

        tmuxError =
            "Terminal viewport changed repeatedly while resizing; tmux attachment cancelled."
        return false
    }

    private func sendTmuxCommandAfterViewportReconciliation(
        _ command: String,
        on conn: any SSHConnection,
        sessionID: UUID
    ) async -> Bool {
        tmuxError = nil
        guard await synchronizeViewportAndResize(conn, sessionID: sessionID) else {
            return false
        }
        return await sendValidatedCommand(command + "\n", approved: true)
    }

    @discardableResult
    func executeMultiplexerControl(_ action: MultiplexerControlAction, approved: Bool = false) async
        -> Bool
    {
        guard canUseSingleSessionAuxiliaryFeatures,
            activeSession?.state == .connected, let conn = connection,
            let executor = conn as? SSHCommandExecuting
        else { return false }
        let sessionID = activeSession?.id
        let connObj = conn as AnyObject
        let command: String
        do {
            switch action {
            case .tmux: command = try TmuxControl().command(for: action)
            case .herdr: command = try HerdrControl().command(for: action)
            }
        } catch { return false }
        switch CommandPolicy().classify(command) {
        case .safe: break
        case .reviewRequired: guard approved else { return false }
        case .blocked: return false
        }
        do {
            let result = try await executor.executeCommand(command, timeout: 10.0)
            guard activeSession?.id == sessionID,
                activeSession?.state == .connected,
                !isExplicitDisconnect,
                (connection as AnyObject) === connObj
            else { return false }
            guard result.isSuccess else { return false }
            if case .herdr = action { await refreshHerdrState() }
            if case .tmux = action { tmuxRefreshGeneration += 1 }
            return true
        } catch { return false }
    }

    @discardableResult
    func attachTmuxSession(id: String) async -> Bool {
        guard canUseSingleSessionAuxiliaryFeatures,
            activeSession?.state == .connected,
            let conn = connection
        else {
            tmuxError = "Not connected."
            return false
        }
        guard let sessionID = activeSession?.id else { return false }
        let connObj = conn as AnyObject
        let validatedID: TmuxSessionID
        do {
            validatedID = try TmuxSessionID(id)
        } catch {
            tmuxError = error.localizedDescription
            return false
        }

        let cmd: String
        do {
            cmd = try TmuxControl().command(for: .tmux(.attachSession(validatedID)))
        } catch {
            tmuxError = error.localizedDescription
            return false
        }
        guard CommandPolicy().canSend(cmd, approved: true) else {
            tmuxError = "Safety policy rejected command."
            return false
        }

        let sent = await sendTmuxCommandAfterViewportReconciliation(
            cmd,
            on: conn,
            sessionID: sessionID
        )
        guard activeSession?.id == sessionID,
            activeSession?.state == .connected,
            !isExplicitDisconnect,
            (connection as AnyObject) === connObj
        else {
            return false
        }
        if sent {
            tmuxRefreshGeneration += 1
            activeTmuxSessionID = validatedID.value
            tmuxError = nil
            if let host = activeHost, let session = activeSession {
                guard let target = LastUsedMultiplexerTarget.tmuxTarget(validatedID.value) else {
                    return false
                }
                await saveRestorationMetadata(
                    restorationMetadata(
                        hostID: host.id,
                        sessionID: session.id,
                        target: target
                    ))
            }
            return true
        } else {
            if tmuxError == nil {
                tmuxError = "Failed to attach to tmux session \(validatedID.value)."
            }
            return false
        }
    }

    @discardableResult
    func createTmuxSession(name: String) async -> Bool {
        guard canUseSingleSessionAuxiliaryFeatures,
            activeSession?.state == .connected,
            let conn = connection
        else {
            tmuxError = "Not connected."
            return false
        }
        guard let sessionID = activeSession?.id else { return false }
        let connObj = conn as AnyObject
        let validatedName: TmuxSessionName
        do {
            validatedName = try TmuxSessionName(name)
        } catch {
            tmuxError = error.localizedDescription
            return false
        }

        let cmd: String
        do {
            cmd = try TmuxControl().command(for: .tmux(.createSession(validatedName)))
        } catch {
            tmuxError = error.localizedDescription
            return false
        }
        guard CommandPolicy().canSend(cmd, approved: true) else {
            tmuxError = "Safety policy rejected command."
            return false
        }

        let sent = await sendTmuxCommandAfterViewportReconciliation(
            cmd,
            on: conn,
            sessionID: sessionID
        )
        guard activeSession?.id == sessionID,
            activeSession?.state == .connected,
            !isExplicitDisconnect,
            (connection as AnyObject) === connObj
        else {
            return false
        }
        if sent {
            tmuxRefreshGeneration += 1
            _ = await listTmuxSessions()
            activeTmuxSessionID =
                tmuxSessions.first(where: { $0.name == validatedName.value })?.sessionID
                ?? validatedName.value
            tmuxError = nil
            if let host = activeHost, let session = activeSession,
                let targetID = activeTmuxSessionID,
                let target = LastUsedMultiplexerTarget.tmuxTarget(targetID)
            {
                await saveRestorationMetadata(
                    restorationMetadata(
                        hostID: host.id,
                        sessionID: session.id,
                        target: target
                    ))
            }
            return true
        } else {
            if tmuxError == nil {
                tmuxError = "Failed to create tmux session \(validatedName.value)."
            }
            return false
        }
    }

    // MARK: - Live Herdr Workspace & Agent Management

    @discardableResult
    func probeHerdr() async -> HerdrAvailability {
        guard canUseSingleSessionAuxiliaryFeatures,
            let currentSession = activeSession, currentSession.state == .connected,
            let executor = connection as? SSHCommandExecuting
        else {
            let avail = HerdrAvailability.unavailable(reason: "Not connected")
            if activeSession == nil || activeSession?.state != .connected {
                herdrAvailability = avail
            }
            return avail
        }
        let sessionID = currentSession.id
        let connObj = connection as AnyObject
        do {
            let result = try await executor.executeCommand(HerdrCommand.probe, timeout: 5.0)
            guard activeSession?.id == sessionID,
                activeSession?.state == .connected,
                !isExplicitDisconnect,
                (connection as AnyObject) === connObj
            else {
                return .unavailable(reason: "Session disconnected")
            }
            let avail = HerdrAvailability.parse(result: result)
            herdrAvailability = avail
            return avail
        } catch {
            guard activeSession?.id == sessionID,
                activeSession?.state == .connected,
                !isExplicitDisconnect,
                (connection as AnyObject) === connObj
            else {
                return .unavailable(reason: "Session disconnected")
            }
            let avail = HerdrAvailability.unavailable(reason: error.localizedDescription)
            herdrAvailability = avail
            return avail
        }
    }

    @discardableResult
    func listHerdrWorkspaces() async -> [HerdrWorkspace] {
        guard canUseSingleSessionAuxiliaryFeatures,
            let currentSession = activeSession, currentSession.state == .connected,
            let executor = connection as? SSHCommandExecuting
        else {
            herdrWorkspaces = []
            return []
        }
        let sessionID = currentSession.id
        let connObj = connection as AnyObject
        do {
            let cmd = HerdrCommand.workspaceList().renderedCommand
            let result = try await executor.executeCommand(cmd, timeout: 5.0)
            guard activeSession?.id == sessionID,
                activeSession?.state == .connected,
                !isExplicitDisconnect,
                (connection as AnyObject) === connObj
            else {
                return []
            }
            if result.isSuccess {
                do {
                    let parsed = try HerdrOutputParser.parseWorkspaces(from: result.stdout)
                    herdrWorkspaces = parsed
                    herdrError = nil
                    return parsed
                } catch {
                    herdrWorkspaces = []
                    herdrError = "Failed to parse Herdr workspaces: \(error.localizedDescription)"
                    return []
                }
            } else {
                herdrWorkspaces = []
                let err = result.stderr.trimmingCharacters(in: .whitespacesAndNewlines)
                let out = result.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
                herdrError =
                    !err.isEmpty
                    ? err
                    : (!out.isEmpty
                        ? out : "Failed to list Herdr workspaces (exit code \(result.exitCode))")
                return []
            }
        } catch {
            guard activeSession?.id == sessionID,
                activeSession?.state == .connected,
                !isExplicitDisconnect,
                (connection as AnyObject) === connObj
            else {
                return []
            }
            herdrWorkspaces = []
            herdrError = error.localizedDescription
            return []
        }
    }

    @discardableResult
    func selectHerdrWorkspace(id: String) async -> Bool {
        guard canUseSingleSessionAuxiliaryFeatures,
            let target = LastUsedMultiplexerTarget.herdrTarget(id),
            activeSession?.state == .connected
        else {
            herdrError = "Not connected."
            return false
        }
        guard let workspace = herdrWorkspaces.first(where: { $0.id == id }) else {
            herdrError =
                "Herdr workspace is not available. Refresh and select an existing workspace."
            return false
        }
        guard let host = activeHost, let session = activeSession else { return false }
        activeHerdrWorkspaceID = workspace.id
        herdrError = nil
        await saveRestorationMetadata(
            restorationMetadata(
                hostID: host.id,
                sessionID: session.id,
                target: target
            ))
        return true
    }

    func refreshHerdrState() async {
        guard canUseSingleSessionAuxiliaryFeatures else { return }
        if connection is any MoshSessionControlling {
            return
        }
        guard let currentSession = activeSession, currentSession.state == .connected,
            let currentConnection = connection, currentConnection is SSHCommandExecuting
        else {
            herdrAvailability = .unavailable(reason: "Not connected")
            herdrWorkspaces = []
            return
        }
        let sessionID = currentSession.id
        let connObj = currentConnection as AnyObject
        herdrRefreshGeneration += 1
        let generation = herdrRefreshGeneration
        isProbingHerdr = true
        defer {
            if herdrRefreshGeneration == generation {
                isProbingHerdr = false
            }
        }

        let availability = await probeHerdr()
        guard herdrRefreshGeneration == generation,
            activeSession?.id == sessionID,
            activeSession?.state == .connected,
            !isExplicitDisconnect,
            (connection as AnyObject) === connObj
        else {
            return
        }

        if availability.isAvailable {
            _ = await listHerdrWorkspaces()
        } else {
            herdrWorkspaces = []
        }
    }

    func startHerdrPolling(interval: TimeInterval = 3.0) {
        stopHerdrPolling()
        isPollingHerdr = true
        herdrPollingGeneration += 1
        let generation = herdrPollingGeneration
        herdrPollingTask = Task { @MainActor [weak self] in
            defer {
                if let self, self.herdrPollingGeneration == generation {
                    self.isPollingHerdr = false
                }
            }
            while !Task.isCancelled {
                guard let self,
                    self.herdrPollingGeneration == generation,
                    self.activeSession?.state == .connected,
                    !self.isExplicitDisconnect
                else {
                    break
                }
                await self.refreshHerdrState()
                do {
                    try await Task.sleep(nanoseconds: UInt64(interval * 1_000_000_000))
                } catch {
                    break
                }
            }
        }
    }

    func stopHerdrPolling() {
        herdrPollingGeneration += 1
        herdrPollingTask?.cancel()
        herdrPollingTask = nil
        isPollingHerdr = false
    }

    @discardableResult
    func runHerdrPaneCommand(paneID: String, command: String, approved: Bool = false) async -> (
        success: Bool, error: String?
    ) {
        guard canUseSingleSessionAuxiliaryFeatures else {
            return (false, "Auxiliary features require one selected session")
        }
        let trimmed = command.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            let msg = "Command cannot be empty."
            herdrError = msg
            return (false, msg)
        }
        guard let currentSession = activeSession, currentSession.state == .connected,
            let executor = connection as? SSHCommandExecuting
        else {
            let msg = "Not connected."
            herdrError = msg
            return (false, msg)
        }
        let sessionID = currentSession.id
        let connObj = connection as AnyObject

        let rendered = HerdrCommand.paneRun(pane: paneID, command: trimmed).renderedCommand
        let policy = CommandPolicy()
        let risk = policy.classify(rendered)

        guard risk != .blocked else {
            let msg = "Safety policy blocked destructive command: '\(command)'."
            herdrError = msg
            return (false, msg)
        }

        if risk == .reviewRequired && !approved {
            let msg = "Command requires explicit approval: '\(command)'."
            herdrError = msg
            return (false, msg)
        }

        do {
            let result = try await executor.executeCommand(rendered, timeout: 10.0)
            guard activeSession?.id == sessionID,
                activeSession?.state == .connected,
                !isExplicitDisconnect,
                (connection as AnyObject) === connObj
            else {
                return (false, "Session disconnected")
            }
            if result.isSuccess {
                herdrError = nil
                await refreshHerdrState()
                return (true, nil)
            } else {
                let err = result.stderr.trimmingCharacters(in: .whitespacesAndNewlines)
                let out = result.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
                let msg =
                    !err.isEmpty
                    ? err : (!out.isEmpty ? out : "Command failed with code \(result.exitCode)")
                herdrError = msg
                return (false, msg)
            }
        } catch {
            herdrError = error.localizedDescription
            return (false, error.localizedDescription)
        }
    }

    @discardableResult
    func splitHerdrPane(paneID: String, direction: String = "right") async -> (
        success: Bool, error: String?
    ) {
        guard canUseSingleSessionAuxiliaryFeatures,
            let currentSession = activeSession, currentSession.state == .connected,
            let executor = connection as? SSHCommandExecuting
        else {
            let msg = "Not connected."
            herdrError = msg
            return (false, msg)
        }
        let sessionID = currentSession.id
        let connObj = connection as AnyObject

        let cmd = HerdrCommand.paneSplit(pane: paneID, direction: direction).renderedCommand
        let policy = CommandPolicy()
        let risk = policy.classify(cmd)
        guard risk != .blocked else {
            let msg = "Safety policy blocked pane split."
            herdrError = msg
            return (false, msg)
        }

        do {
            let result = try await executor.executeCommand(cmd, timeout: 5.0)
            guard activeSession?.id == sessionID,
                activeSession?.state == .connected,
                !isExplicitDisconnect,
                (connection as AnyObject) === connObj
            else {
                return (false, "Session disconnected")
            }
            if result.isSuccess {
                herdrError = nil
                await refreshHerdrState()
                return (true, nil)
            } else {
                let err = result.stderr.trimmingCharacters(in: .whitespacesAndNewlines)
                let msg = !err.isEmpty ? err : "Failed to split pane (exit code \(result.exitCode))"
                herdrError = msg
                return (false, msg)
            }
        } catch {
            herdrError = error.localizedDescription
            return (false, error.localizedDescription)
        }
    }

    func readHerdrPaneOutput(paneID: String, source: String = "recent-unwrapped") async throws
        -> String
    {
        guard canUseSingleSessionAuxiliaryFeatures,
            let currentSession = activeSession, currentSession.state == .connected,
            let executor = connection as? SSHCommandExecuting
        else {
            throw HerdrParseError.emptyOutput
        }
        let sessionID = currentSession.id
        let connObj = connection as AnyObject

        let cmd = HerdrCommand.paneRead(pane: paneID, source: source).renderedCommand
        let result = try await executor.executeCommand(cmd, timeout: 5.0)
        guard activeSession?.id == sessionID,
            activeSession?.state == .connected,
            !isExplicitDisconnect,
            (connection as AnyObject) === connObj
        else {
            throw HerdrParseError.emptyOutput
        }
        guard result.isSuccess else {
            let err = result.stderr.trimmingCharacters(in: .whitespacesAndNewlines)
            throw HerdrParseError.executionFailed(
                !err.isEmpty ? err : "Read failed with code \(result.exitCode)")
        }
        let unwrapped = HerdrOutputParser.parseRecentUnwrapped(from: result.stdout)
        // Herdr is selected-session-only, but its output must use the owning
        // runtime in case the legacy projection is awaiting synchronization.
        return sessionRuntime?.redactor.redact(unwrapped) ?? redactor.redact(unwrapped)
    }

    func waitHerdrAgentStatus(
        paneID: String? = nil, status: String? = nil, timeout: TimeInterval = 10.0
    ) async throws -> HerdrAgentState {
        guard let currentSession = activeSession, currentSession.state == .connected,
            let executor = connection as? SSHCommandExecuting
        else {
            throw HerdrParseError.emptyOutput
        }
        let sessionID = currentSession.id
        let connObj = connection as AnyObject

        let cmd = HerdrCommand.waitAgentStatus(pane: paneID, status: status).renderedCommand
        let result = try await executor.executeCommand(cmd, timeout: timeout)
        guard activeSession?.id == sessionID,
            activeSession?.state == .connected,
            !isExplicitDisconnect,
            (connection as AnyObject) === connObj
        else {
            throw HerdrParseError.emptyOutput
        }
        guard result.isSuccess else {
            let err = result.stderr.trimmingCharacters(in: .whitespacesAndNewlines)
            throw HerdrParseError.executionFailed(
                !err.isEmpty ? err : "Wait failed with code \(result.exitCode)")
        }
        let state = try HerdrOutputParser.parseAgentState(from: result.stdout)
        await refreshHerdrState()
        return state
    }

    @discardableResult
    func createHerdrWorkspace(label: String, cwd: String = ".") async -> (
        success: Bool, error: String?
    ) {
        guard canUseSingleSessionAuxiliaryFeatures else {
            return (false, "Auxiliary features require one selected session")
        }
        let trimmedLabel = label.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedLabel.isEmpty else {
            let msg = "Workspace label cannot be empty."
            herdrError = msg
            return (false, msg)
        }
        guard let currentSession = activeSession, currentSession.state == .connected,
            let executor = connection as? SSHCommandExecuting
        else {
            let msg = "Not connected."
            herdrError = msg
            return (false, msg)
        }
        let sessionID = currentSession.id
        let connObj = connection as AnyObject

        let cleanCwd = cwd.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "." : cwd
        let cmd = HerdrCommand.workspaceCreate(cwd: cleanCwd, label: trimmedLabel).renderedCommand
        let policy = CommandPolicy()
        let risk = policy.classify(cmd)
        guard risk != .blocked else {
            let msg = "Safety policy blocked workspace creation."
            herdrError = msg
            return (false, msg)
        }

        do {
            let result = try await executor.executeCommand(cmd, timeout: 5.0)
            guard activeSession?.id == sessionID,
                activeSession?.state == .connected,
                !isExplicitDisconnect,
                (connection as AnyObject) === connObj
            else {
                return (false, "Session disconnected")
            }
            if result.isSuccess {
                herdrError = nil
                await refreshHerdrState()
                return (true, nil)
            } else {
                let err = result.stderr.trimmingCharacters(in: .whitespacesAndNewlines)
                let msg =
                    !err.isEmpty ? err : "Failed to create workspace (exit code \(result.exitCode))"
                herdrError = msg
                return (false, msg)
            }
        } catch {
            herdrError = error.localizedDescription
            return (false, error.localizedDescription)
        }
    }

    // MARK: - Live Voice & Local AI Management

    func refreshVoiceModels() async {
        self.voiceModels = await voiceModelManager.listModels()
    }

    func hasInstalledWhisperModel() async -> Bool {
        let models = await voiceModelManager.listModels()
        return models.contains { $0.state.isReady }
    }

    func selectVoiceProvider(id: String) {
        do {
            try voiceRegistry.selectProvider(id: id)
            self.selectedVoiceProviderID = id
            self.voiceErrorMessage = nil
        } catch {
            self.voiceErrorMessage = error.localizedDescription
        }
    }

    func downloadVoiceModel(_ tier: WhisperModelTier) async throws {
        voiceErrorMessage = nil
        await refreshVoiceModels()
        do {
            _ = try await voiceModelManager.downloadModel(tier) { [weak self] fraction in
                Task { @MainActor [weak self] in
                    guard let self else { return }
                    if let index = self.voiceModels.firstIndex(where: {
                        $0.id == tier.defaultModelID
                    }) {
                        self.voiceModels[index].state = .downloading(fractionCompleted: fraction)
                    }
                }
            }
            await refreshVoiceModels()
        } catch {
            await refreshVoiceModels()
            voiceErrorMessage = error.localizedDescription
            throw error
        }
    }

    func cancelVoiceModelDownload(_ tier: WhisperModelTier) async {
        await voiceModelManager.cancelDownload(tier)
        await refreshVoiceModels()
    }

    func deleteVoiceModel(_ tier: WhisperModelTier) async throws {
        try await voiceModelManager.deleteModel(tier)
        await refreshVoiceModels()
    }

    func startVoiceRecording(mode: VoiceInputMode? = nil) async throws {
        guard let host = activeHost, activeSession?.state == .connected else {
            let message = "Connect to a host before recording voice commands."
            voiceErrorMessage = message
            speechState = .failed(.recorderError(.deviceUnavailable(reason: message)))
            throw AudioRecorderError.deviceUnavailable(reason: message)
        }
        guard host.isVoiceEnabled else {
            let message = "Voice input is disabled for host '\(host.name)'."
            voiceErrorMessage = message
            let err = TranscriptionError.hostPolicyDisabled(hostID: host.id)
            speechState = .failed(err)
            throw err
        }
        let effectiveMode = mode ?? defaultVoiceMode
        guard host.voicePolicy.allowedModes.contains(effectiveMode) else {
            let message =
                "Voice mode '\(effectiveMode.displayName)' is not permitted by host policy for '\(host.name)'."
            voiceErrorMessage = message
            let err = TranscriptionError.transcriptionFailed(reason: message)
            speechState = .failed(err)
            throw err
        }
        if selectedVoiceProviderID == VoiceProviderRegistry.whisperProviderID {
            let hasModel = await hasInstalledWhisperModel()
            guard hasModel else {
                let message = "Download required: on-device Whisper model is not installed."
                voiceErrorMessage = message
                let err = TranscriptionError.modelNotInstalled(
                    modelID: WhisperModelTier.tiny.defaultModelID)
                speechState = .failed(err)
                throw err
            }
        }

        voiceErrorMessage = nil
        activeVoicePreview = nil
        isRecordingVoice = true
        isSlideToCancelActive = false
        speechState = .recording
        voiceProgressFraction = 0.0
        voiceRecordingDuration = 0.0

        do {
            try await voiceRecorder.start()
        } catch {
            isRecordingVoice = false
            speechState = .idle
            voiceErrorMessage = error.localizedDescription
            throw error
        }
    }

    @discardableResult
    func stopVoiceRecording(mode: VoiceInputMode? = nil) async throws -> VoicePreviewState {
        guard isRecordingVoice else {
            throw AudioRecorderError.notRecording
        }
        guard let host = activeHost else {
            await cancelVoiceRecording()
            throw AudioRecorderError.deviceUnavailable(reason: "No active host")
        }

        voiceTranscriptionGeneration += 1
        let gen = voiceTranscriptionGeneration
        let effectiveMode = mode ?? defaultVoiceMode
        isRecordingVoice = false
        isSlideToCancelActive = false
        isTranscribingVoice = true
        speechState = .transcribing
        voiceProgressFraction = 0.0

        let handle: AudioRecordingHandle
        do {
            handle = try await voiceRecorder.stop()
        } catch {
            guard voiceTranscriptionGeneration == gen else {
                throw TranscriptionError.cancelled
            }
            isTranscribingVoice = false
            speechState = .idle
            voiceErrorMessage = error.localizedDescription
            throw error
        }

        // Guaranteed audio deletion regardless of outcome
        defer {
            handle.cleanup()
        }

        do {
            guard voiceTranscriptionGeneration == gen && isTranscribingVoice else {
                throw TranscriptionError.cancelled
            }
            try Task.checkCancellation()
            let transcriber = activeTranscriber
            let transcript = try await transcriber.transcribe(recording: handle) {
                [weak self] fraction in
                Task { @MainActor [weak self] in
                    guard let self, self.voiceTranscriptionGeneration == gen,
                        self.isTranscribingVoice
                    else { return }
                    self.voiceProgressFraction = fraction
                    self.speechState = .transcribingWithProgress(fractionCompleted: fraction)
                }
            }
            guard voiceTranscriptionGeneration == gen && isTranscribingVoice else {
                throw TranscriptionError.cancelled
            }
            try Task.checkCancellation()

            let preview = VoicePreviewState(
                originalTranscript: transcript,
                mode: effectiveMode,
                duration: handle.duration,
                router: voiceRouter,
                hostPolicy: host.voicePolicy
            )

            // Strict invariant: NO transcription callback may auto-send!
            self.activeVoicePreview = preview
            self.speechState = .preview(preview)
            self.isTranscribingVoice = false
            return preview
        } catch is CancellationError {
            guard voiceTranscriptionGeneration == gen else {
                throw TranscriptionError.cancelled
            }
            self.isTranscribingVoice = false
            self.speechState = .cancelled
            throw TranscriptionError.cancelled
        } catch let err as TranscriptionError {
            guard voiceTranscriptionGeneration == gen else {
                throw TranscriptionError.cancelled
            }
            self.isTranscribingVoice = false
            self.speechState = (err == .cancelled) ? .cancelled : .failed(err)
            self.voiceErrorMessage = err.localizedDescription
            throw err
        } catch {
            guard voiceTranscriptionGeneration == gen else {
                throw TranscriptionError.cancelled
            }
            self.isTranscribingVoice = false
            let err = TranscriptionError.transcriptionFailed(reason: error.localizedDescription)
            self.speechState = .failed(err)
            self.voiceErrorMessage = error.localizedDescription
            throw err
        }
    }

    func cancelVoiceRecording() async {
        voiceTranscriptionGeneration += 1
        isRecordingVoice = false
        isSlideToCancelActive = false
        isTranscribingVoice = false
        voiceProgressFraction = 0.0
        await voiceRecorder.cancel()
        speechState = .cancelled
    }

    func resetVoiceState() {
        voiceTranscriptionGeneration += 1
        isRecordingVoice = false
        isSlideToCancelActive = false
        isTranscribingVoice = false
        voiceProgressFraction = 0.0
        voiceErrorMessage = nil
        activeVoicePreview = nil
        speechState = .idle
    }

    @discardableResult
    func sendVoiceCommand(preview: VoicePreviewState) async -> Bool {
        guard preview.mode == .shellCommand else { return false }
        let value = preview.text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty else { return false }
        switch CommandPolicy().classify(value) {
        case .safe:
            let success = await sendValidatedCommand(value + "\n", approved: true)
            if success { resetVoiceState() }
            return success
        case .reviewRequired, .blocked:
            return false
        }
    }

    @discardableResult
    func sendAgentMessage(preview: VoicePreviewState, confirmedProduction: Bool = false) async
        -> Bool
    {
        guard preview.mode == .agentMessage else { return false }
        let value = preview.text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty else { return false }
        if let host = activeHost, host.isProduction && !confirmedProduction {
            return false
        }
        let payload = Data((value + "\n").utf8)
        let success = await sendRawInteractive(payload)
        if success { resetVoiceState() }
        return success
    }

    @discardableResult
    func insertVoiceText(preview: VoicePreviewState) async -> Bool {
        guard preview.mode == .insertOnly else { return false }
        guard !preview.text.isEmpty else { return false }
        let bracketed = TerminalKeyEncoder.encodePaste(preview.text, bracketed: true)
        let success = await sendRawInteractive(bracketed)
        if success { resetVoiceState() }
        return success
    }

    // MARK: - Secondary Split Pane Management

    public func openSecondarySFTP(for host: Host) {
        guard canUseSingleSessionAuxiliaryFeatures(for: host) else { return }
        secondaryPaneMode = .sftp(host)
        if sftpRepository == nil || activeHost?.id != host.id {
            Task {
                await setupSFTPForHost(host)
            }
        }
    }

    public func openSecondaryTerminal(for host: Host) {
        secondaryPaneMode = .terminal(host)
    }

    public func closeSecondaryPane() {
        secondaryPaneMode = .none
    }

    // MARK: - SFTP & File Management Methods

    func setupSFTPForHost(_ host: Host) async {
        guard canUseSingleSessionAuxiliaryFeatures(for: host) else { return }
        guard customSFTPRepository == nil else {
            await loadDirectory(at: currentPath)
            return
        }
        if case .mosh = host.connection {
            // Mosh connections operate over UDP and do not establish an SFTP subsystem channel
            self.sftpRepository = nil
            self.sftpErrorMessage = nil
            self.lastSFTPFailure = nil
            return
        }

        sftpSetupGeneration += 1
        let currentGen = sftpSetupGeneration

        if isDemo {
            if sftpRepository == nil {
                sftpRepository = DemoSFTPRepository(seedDemoData: true)
            }
            guard sftpSetupGeneration == currentGen else { return }
            self.sftpErrorMessage = nil
            self.lastSFTPFailure = nil
            await loadDirectory(at: currentPath)
        } else {
            do {
                let repo = try await LiveSFTPRepository.connect(
                    host: host,
                    identity: try await resolveIdentity(for: host),
                    trustEvaluator: trustStore,
                    credentialStore: credentialStore
                )
                guard sftpSetupGeneration == currentGen else {
                    Task { await repo.close() }
                    return
                }
                self.sftpRepository = repo
                self.sftpErrorMessage = nil
                self.lastSFTPFailure = nil
                await loadDirectory(at: currentPath)
            } catch {
                guard sftpSetupGeneration == currentGen else { return }
                self.sftpRepository = nil
                let failure = ConnectionFailure.from(error: error, host: host)
                self.lastSFTPFailure = failure
                self.sftpErrorMessage = failure.reason
            }
        }
    }

    public func retrySFTP() async {
        guard canUseSingleSessionAuxiliaryFeatures, let host = activeHost else { return }
        self.lastSFTPFailure = nil
        self.sftpErrorMessage = nil
        await setupSFTPForHost(host)
    }

    // MARK: - Command Dial Send Image

    /// Starts an image upload without putting image bytes in the terminal or
    /// sending a line ending. The operation is owned by the transfer queue so
    /// the existing queue UI and explicit disconnect cancellation remain the
    /// source of truth.
    public func beginSendImage(data: Data) {
        sendImageGeneration &+= 1
        cancelSendImage()
        let operationID = UUID()
        activeSendImageOperationID = operationID
        sendImageErrorMessage = nil
        sendImageState = .preparing
        let operation = Task { @MainActor [weak self] in
            guard let self else { return }
            await self.performSendImage(data: data, operationID: operationID)
        }
        sendImageTask = operation
    }

    public func cancelSendImage() {
        let operationID = activeSendImageOperationID
        sendImageTask?.cancel()
        if let transferID = activeSendImageTransferID {
            activeTransferTasks[transferID]?.cancel()
            Task { [transferCoordinator] in
                await transferCoordinator.cancel(id: transferID)
            }
        }
        if operationID != nil {
            activeSendImageOperationID = nil
            sendImageTask = nil
            activeSendImageTransferID = nil
            if sendImageState.isActive { sendImageState = .cancelled }
        }
    }

    private func performSendImage(data: Data, operationID: UUID) async {
        let stagingDirectory = FileManager.default.temporaryDirectory.appendingPathComponent(
            "ShhImageUploads", isDirectory: true)
        var stagingURL: URL?
        defer {
            if let stagingURL { try? FileManager.default.removeItem(at: stagingURL) }
            if activeSendImageOperationID == operationID {
                sendImageTask = nil
                activeSendImageOperationID = nil
                activeSendImageTransferID = nil
            }
        }

        // A cancelled operation may remain queued long enough to start after a
        // replacement upload. Never let that stale task mutate the replacement.
        guard activeSendImageOperationID == operationID else { return }
        guard canUseSingleSessionAuxiliaryFeatures,
            let host = activeHost,
            activeSession?.state == .connected,
            let repo = sftpRepository
        else {
            sendImageErrorMessage = SendImageError.unavailable.localizedDescription
            sendImageState = .failed
            return
        }
        let hostID = host.id
        let sessionID = activeSession?.id
        let generation = lifecycleGeneration
        let connection = self.connection
        let connectionIdentity = connection.map { ObjectIdentifier($0 as AnyObject) }
        let transferContext = captureSFTPOperation(
            repository: repo, operationGeneration: transferQueueGeneration, scope: .transfer)
        let capturedSendImageGeneration = sendImageGeneration
        var imageRemotePath: RemotePath?
        do {
            let image = try SendImageValidator.validate(data)
            try Task.checkCancellation()
            guard
                isCurrentSendImage(
                    operationID: operationID, hostID: hostID, sessionID: sessionID,
                    generation: generation, connectionIdentity: connectionIdentity,
                    repository: repo, transferContext: transferContext,
                    sendImageGeneration: capturedSendImageGeneration
                )
            else {
                throw SendImageError.hostChanged
            }

            try FileManager.default.createDirectory(
                at: stagingDirectory, withIntermediateDirectories: true)
            let filename = SendImageNaming.fileName(extension: image.fileExtension)
            let localURL = stagingDirectory.appendingPathComponent(filename, isDirectory: false)
            try image.data.write(to: localURL, options: [.atomic, .completeFileProtection])
            stagingURL = localURL

            let destination =
                try SendImageDestination.configuredDirectory(host.sendImageDestination)
                ?? SendImageDestination.defaultDirectory(username: host.username)
            try await createSendImageDirectory(destination, using: repo)
            let remotePath = try await uniqueSendImagePath(
                in: destination, extension: image.fileExtension, using: repo)
            imageRemotePath = remotePath
            try Task.checkCancellation()

            let fileSize = Int64(image.data.count)
            let transfer = await transferCoordinator.enqueue(
                direction: .upload,
                remotePath: remotePath,
                localURL: localURL,
                totalBytes: fileSize
            )
            let transferID = transfer.id
            guard
                isCurrentSendImage(
                    operationID: operationID, hostID: hostID, sessionID: sessionID,
                    generation: generation, connectionIdentity: connectionIdentity,
                    repository: repo, transferContext: transferContext,
                    sendImageGeneration: capturedSendImageGeneration)
            else { throw SendImageError.cancelled }
            activeSendImageTransferID = transferID
            activeTransferTasks[transferID] = sendImageTask
            await transferCoordinator.registerCancellation(id: transferID) { [weak self] in
                Task { @MainActor [weak self] in
                    guard self?.activeSendImageOperationID == operationID else { return }
                    self?.sendImageTask?.cancel()
                }
            }
            guard await publishTransferQueueState(transferContext) else {
                throw SendImageError.cancelled
            }

            do {
                let uploadProgress: @Sendable (TransferProgress) -> Void = { [weak self] progress in
                    Task { @MainActor [weak self] in
                        guard let self else { return }
                        guard self.activeSendImageOperationID == operationID,
                            self.activeSendImageTransferID == transferID,
                            self.sendImageState.isActive,
                            self.isCurrentSendImage(
                                operationID: operationID, hostID: hostID,
                                sessionID: sessionID, generation: generation,
                                connectionIdentity: connectionIdentity, repository: repo,
                                transferContext: transferContext,
                                sendImageGeneration: capturedSendImageGeneration)
                        else {
                            return
                        }
                        self.sendImageState = .transferring(progress)
                        await self.transferCoordinator.updateProgress(
                            id: transferID,
                            bytesTransferred: progress.bytesTransferred,
                            totalBytes: progress.totalBytes
                        )
                        guard
                            self.isCurrentSendImage(
                                operationID: operationID, hostID: hostID, sessionID: sessionID,
                                generation: generation, connectionIdentity: connectionIdentity,
                                repository: repo, transferContext: transferContext,
                                sendImageGeneration: capturedSendImageGeneration)
                        else { return }
                        _ = await self.publishTransferQueueState(transferContext)
                    }
                }
                if let restrictedRepo = repo as? any SFTPRestrictedUploader {
                    try await restrictedRepo.upload(
                        from: localURL, to: remotePath, permissions: .secureFile,
                        progress: uploadProgress)
                } else {
                    try await repo.upload(from: localURL, to: remotePath, progress: uploadProgress)
                }
                guard
                    isCurrentSendImage(
                        operationID: operationID, hostID: hostID, sessionID: sessionID,
                        generation: generation, connectionIdentity: connectionIdentity,
                        repository: repo, transferContext: transferContext,
                        sendImageGeneration: capturedSendImageGeneration)
                else {
                    throw SendImageError.hostChanged
                }
                try Task.checkCancellation()
                guard
                    isCurrentSendImage(
                        operationID: operationID, hostID: hostID, sessionID: sessionID,
                        generation: generation, connectionIdentity: connectionIdentity,
                        repository: repo, transferContext: transferContext,
                        sendImageGeneration: capturedSendImageGeneration)
                else { throw SendImageError.cancelled }
                await transferCoordinator.markCompleted(id: transferID)
                guard
                    isCurrentSendImage(
                        operationID: operationID, hostID: hostID, sessionID: sessionID,
                        generation: generation, connectionIdentity: connectionIdentity,
                        repository: repo, transferContext: transferContext,
                        sendImageGeneration: capturedSendImageGeneration)
                else { throw SendImageError.cancelled }
                activeSendImageTransferID = nil
                guard await publishTransferQueueState(transferContext) else {
                    throw SendImageError.cancelled
                }
                let quotedPath = try SendImageNaming.shellQuote(remotePath.description)
                guard
                    await sendImageInsertion(
                        quotedPath, operationID: operationID, hostID: hostID,
                        sessionID: sessionID, generation: generation,
                        connectionIdentity: connectionIdentity, connection: connection,
                        transferContext: transferContext,
                        sendImageGeneration: capturedSendImageGeneration)
                else {
                    throw SendImageError.unavailable
                }
                guard
                    isCurrentSendImage(
                        operationID: operationID, hostID: hostID, sessionID: sessionID,
                        generation: generation, connectionIdentity: connectionIdentity,
                        repository: repo, transferContext: transferContext,
                        sendImageGeneration: capturedSendImageGeneration)
                else { throw SendImageError.cancelled }
                sendImageState = .completed(remotePath)
            } catch {
                if isCurrentSendImage(
                    operationID: operationID, hostID: hostID, sessionID: sessionID,
                    generation: generation, connectionIdentity: connectionIdentity,
                    repository: repo, transferContext: transferContext,
                    sendImageGeneration: capturedSendImageGeneration),
                    let imageRemotePath
                {
                    try? await repo.removeFile(at: imageRemotePath)
                }
                guard
                    isCurrentSendImage(
                        operationID: operationID, hostID: hostID, sessionID: sessionID,
                        generation: generation, connectionIdentity: connectionIdentity,
                        repository: repo, transferContext: transferContext,
                        sendImageGeneration: capturedSendImageGeneration)
                else { return }
                if Task.isCancelled || error is CancellationError
                    || error as? SendImageError == .cancelled
                {
                    await transferCoordinator.cancel(id: transferID)
                    guard
                        isCurrentSendImage(
                            operationID: operationID, hostID: hostID, sessionID: sessionID,
                            generation: generation, connectionIdentity: connectionIdentity,
                            repository: repo, transferContext: transferContext,
                            sendImageGeneration: capturedSendImageGeneration)
                    else { return }
                    sendImageState = .cancelled
                } else {
                    guard
                        isCurrentSendImage(
                            operationID: operationID, hostID: hostID, sessionID: sessionID,
                            generation: generation, connectionIdentity: connectionIdentity,
                            repository: repo, transferContext: transferContext,
                            sendImageGeneration: capturedSendImageGeneration)
                    else { return }
                    await transferCoordinator.markFailed(
                        id: transferID, error: "Image upload failed")
                    guard
                        isCurrentSendImage(
                            operationID: operationID, hostID: hostID, sessionID: sessionID,
                            generation: generation, connectionIdentity: connectionIdentity,
                            repository: repo, transferContext: transferContext,
                            sendImageGeneration: capturedSendImageGeneration)
                    else { return }
                    if let imageError = error as? SendImageError, imageError == .hostChanged {
                        sendImageState = .cancelled
                    } else {
                        sendImageErrorMessage = userSafeSendImageError(error)
                        sendImageState = .failed
                    }
                }
                guard
                    isCurrentSendImage(
                        operationID: operationID, hostID: hostID, sessionID: sessionID,
                        generation: generation, connectionIdentity: connectionIdentity,
                        repository: repo, transferContext: transferContext,
                        sendImageGeneration: capturedSendImageGeneration)
                else { return }
                guard await publishTransferQueueState(transferContext) else { return }
            }
            activeTransferTasks.removeValue(forKey: transferID)
            if isCurrentSendImage(
                operationID: operationID, hostID: hostID, sessionID: sessionID,
                generation: generation, connectionIdentity: connectionIdentity,
                repository: repo, transferContext: transferContext,
                sendImageGeneration: capturedSendImageGeneration)
            {
                activeSendImageTransferID = nil
            }
        } catch {
            guard
                isCurrentSendImage(
                    operationID: operationID, hostID: hostID, sessionID: sessionID,
                    generation: generation, connectionIdentity: connectionIdentity,
                    repository: repo, transferContext: transferContext,
                    sendImageGeneration: capturedSendImageGeneration)
            else { return }
            if Task.isCancelled || error is CancellationError
                || error as? SendImageError == .cancelled
            {
                sendImageState = .cancelled
            } else {
                sendImageErrorMessage = userSafeSendImageError(error)
                sendImageState = .failed
            }
        }
    }

    private func userSafeSendImageError(_ error: Error) -> String {
        if let imageError = error as? SendImageError { return imageError.localizedDescription }
        return "Image upload failed. Check the connection and destination."
    }

    private func isCurrentSendImage(
        operationID: UUID, hostID: UUID, sessionID: UUID?, generation: Int,
        connectionIdentity: ObjectIdentifier?, repository: any SFTPRepository,
        transferContext: SFTPOperationContext, sendImageGeneration: UInt64
    ) -> Bool {
        activeSendImageOperationID == operationID
            && self.sendImageGeneration == sendImageGeneration
            && activeHost?.id == hostID
            && activeSession?.id == sessionID
            && lifecycleGeneration == generation
            && activeSession?.state == .connected
            && connection.map { ObjectIdentifier($0 as AnyObject) } == connectionIdentity
            && sftpRepository.map {
                ObjectIdentifier($0 as AnyObject) == ObjectIdentifier(repository as AnyObject)
            } == true
            && isCurrentSFTPOperation(transferContext)
    }

    private func sendImageInsertion(
        _ quotedPath: String, operationID: UUID, hostID: UUID, sessionID: UUID?,
        generation: Int, connectionIdentity: ObjectIdentifier?,
        connection: (any SSHConnection)?, transferContext: SFTPOperationContext,
        sendImageGeneration: UInt64
    ) async -> Bool {
        guard activeSendImageOperationID == operationID,
            self.sendImageGeneration == sendImageGeneration,
            isCurrentSFTPOperation(transferContext),
            activeHost?.id == hostID,
            activeSession?.id == sessionID,
            activeSession?.state == .connected,
            lifecycleGeneration == generation,
            self.connection.map({ ObjectIdentifier($0 as AnyObject) }) == connectionIdentity,
            let connection
        else { return false }
        do {
            try await connection.send(Data(quotedPath.utf8))
            return true
        } catch {
            return false
        }
    }

    private func createSendImageDirectory(_ path: RemotePath, using repo: any SFTPRepository)
        async throws
    {
        var current = RemotePath.root
        for component in path.components {
            current = current.appending(component)
            do {
                let attributes = try await repo.fetchAttributes(at: current)
                guard attributes.isDirectory else { throw SendImageError.invalidDestination }
            } catch let error as SFTPRepositoryError {
                guard case .notFound = error else { throw error }
                try await repo.createDirectory(at: current)
            }
        }
    }

    private func uniqueSendImagePath(
        in directory: RemotePath, extension fileExtension: String, using repo: any SFTPRepository
    ) async throws -> RemotePath {
        for _ in 0..<8 {
            let path = directory.appending(SendImageNaming.fileName(extension: fileExtension))
            do {
                _ = try await repo.fetchAttributes(at: path)
            } catch let error as SFTPRepositoryError {
                if case .notFound = error { return path }
                throw error
            }
        }
        throw SFTPRepositoryError.alreadyExists(path: directory.description)
    }

    private func cancelSendImageForLifecycle() {
        guard sendImageTask != nil || activeSendImageTransferID != nil else { return }
        cancelSendImage()
    }

    public var sortedAndFilteredFiles: [RemoteFile] {
        let query = fileSearchQuery.trimmingCharacters(in: .whitespacesAndNewlines)
        let filtered: [RemoteFile]
        if query.isEmpty {
            filtered = currentDirectoryFiles
        } else {
            filtered = currentDirectoryFiles.filter {
                $0.name.localizedCaseInsensitiveContains(query)
            }
        }

        return filtered.sorted { lhs, rhs in
            switch sortField {
            case .type:
                let lhsRank = typeRank(lhs.entryType)
                let rhsRank = typeRank(rhs.entryType)
                if lhsRank != rhsRank {
                    return sortAscending ? (lhsRank < rhsRank) : (lhsRank > rhsRank)
                }
                return lhs.name.localizedStandardCompare(rhs.name) == .orderedAscending
            case .name:
                let result = lhs.name.localizedStandardCompare(rhs.name)
                return sortAscending
                    ? (result == .orderedAscending) : (result == .orderedDescending)
            case .date:
                let lDate = lhs.modificationDate ?? Date.distantPast
                let rDate = rhs.modificationDate ?? Date.distantPast
                if lDate != rDate {
                    return sortAscending ? (lDate < rDate) : (lDate > rDate)
                }
                return lhs.name.localizedStandardCompare(rhs.name) == .orderedAscending
            case .size:
                if lhs.size != rhs.size {
                    return sortAscending ? (lhs.size < rhs.size) : (lhs.size > rhs.size)
                }
                return lhs.name.localizedStandardCompare(rhs.name) == .orderedAscending
            }
        }
    }

    private func typeRank(_ type: RemoteFileEntryType) -> Int {
        switch type {
        case .directory: return 0
        case .symlink: return 1
        case .file: return 2
        case .other: return 3
        }
    }

    public func loadDirectory(at path: RemotePath, bypassCache: Bool = false) async {
        guard canUseSingleSessionAuxiliaryFeatures else { return }
        guard let repo = sftpRepository else {
            directoryErrorMessage = "SFTP repository unavailable."
            return
        }

        let capturedSessionID = selectedSessionID
        let capturedRuntime = selectedSessionRuntime
        let capturedHostID = capturedRuntime?.host.id ?? activeHost?.id
        let capturedAuxiliaryOwnerID = auxiliarySessionID
        let capturedSetupGeneration = auxiliarySetupGeneration
        let capturedRepositoryIdentity = ObjectIdentifier(repo as AnyObject)
        let capturedDirectoryOwnerID =
            capturedSessionID ?? capturedAuxiliaryOwnerID ?? capturedHostID
        let capturedRequestToken = nextDirectoryRequestToken(for: capturedDirectoryOwnerID)

        if !bypassCache, let cached = directoryCache[path],
            isCurrentDirectoryLoad(
                sessionID: capturedSessionID,
                runtime: capturedRuntime,
                hostID: capturedHostID,
                auxiliaryOwnerID: capturedAuxiliaryOwnerID,
                setupGeneration: capturedSetupGeneration,
                repositoryIdentity: capturedRepositoryIdentity,
                requestToken: capturedRequestToken,
                ownerID: capturedDirectoryOwnerID
            ),
            Date().timeIntervalSince(cached.timestamp) < directoryCacheTTL
        {
            currentPath = path
            currentDirectoryFiles = cached.files
            isLoadingDirectory = false
            directoryErrorMessage = nil
            return
        }

        isLoadingDirectory = true
        directoryErrorMessage = nil

        do {
            let files = try await repo.listDirectory(at: path)
            let isCurrentLoad = isCurrentDirectoryLoad(
                sessionID: capturedSessionID,
                runtime: capturedRuntime,
                hostID: capturedHostID,
                auxiliaryOwnerID: capturedAuxiliaryOwnerID,
                setupGeneration: capturedSetupGeneration,
                repositoryIdentity: capturedRepositoryIdentity,
                requestToken: capturedRequestToken,
                ownerID: capturedDirectoryOwnerID
            )
            guard isCurrentLoad else { return }
            directoryCache[path] = (files: files, timestamp: Date())
            currentPath = path
            currentDirectoryFiles = files
            isLoadingDirectory = false
        } catch {
            let isCurrentLoad = isCurrentDirectoryLoad(
                sessionID: capturedSessionID,
                runtime: capturedRuntime,
                hostID: capturedHostID,
                auxiliaryOwnerID: capturedAuxiliaryOwnerID,
                setupGeneration: capturedSetupGeneration,
                repositoryIdentity: capturedRepositoryIdentity,
                requestToken: capturedRequestToken,
                ownerID: capturedDirectoryOwnerID
            )
            guard isCurrentLoad else { return }
            isLoadingDirectory = false
            directoryErrorMessage = error.localizedDescription
            if path != .root && currentDirectoryFiles.isEmpty {
                await loadDirectory(at: .root, bypassCache: true)
            }
        }
    }

    private func nextDirectoryRequestToken(for ownerID: UUID?) -> UInt64 {
        let next = directoryRequestGenerations[ownerID, default: 0] &+ 1
        directoryRequestGenerations[ownerID] = next
        return next
    }

    private func isCurrentDirectoryLoad(
        sessionID: UUID?,
        runtime: SessionRuntime?,
        hostID: UUID?,
        auxiliaryOwnerID: UUID?,
        setupGeneration: UInt64,
        repositoryIdentity: ObjectIdentifier,
        requestToken: UInt64,
        ownerID: UUID?
    ) -> Bool {
        guard canUseSingleSessionAuxiliaryFeatures,
            selectedSessionID == sessionID,
            selectedSessionRuntime === runtime,
            activeHost?.id == hostID,
            auxiliarySessionID == auxiliaryOwnerID,
            auxiliarySetupGeneration == setupGeneration,
            directoryRequestGenerations[ownerID] == requestToken,
            let currentRepository = sftpRepository,
            ObjectIdentifier(currentRepository as AnyObject) == repositoryIdentity
        else { return false }
        return true
    }

    public func navigateTo(_ path: RemotePath) async {
        await loadDirectory(at: path)
    }

    public func navigateUp() async {
        guard !currentPath.isRoot else { return }
        await loadDirectory(at: currentPath.parent)
    }

    public func refreshCurrentDirectory() async {
        await loadDirectory(at: currentPath, bypassCache: true)
    }

    public func invalidateDirectoryCache(at path: RemotePath? = nil) {
        if let path {
            directoryCache.removeValue(forKey: path)
            directoryCache.removeValue(forKey: path.parent)
        } else {
            directoryCache.removeAll()
        }
    }

    // MARK: - Transfers & Conflict Handling

    @discardableResult
    public func enqueueDownload(
        file: RemoteFile,
        destinationURL: URL? = nil,
        overwrite: Bool? = nil
    ) async -> TransferTask? {
        guard canUseSingleSessionAuxiliaryFeatures, let repo = sftpRepository else {
            directoryErrorMessage = "SFTP repository unavailable."
            return nil
        }
        let transferContext = captureSFTPOperation(
            repository: repo, operationGeneration: 0, scope: .transfer)

        let safeFileName = (file.name as NSString).lastPathComponent
        guard !safeFileName.isEmpty && safeFileName != "." && safeFileName != ".." else {
            directoryErrorMessage = "Invalid file name: '\(file.name)'"
            return nil
        }

        let defaultDir = FileManager.default.temporaryDirectory.appendingPathComponent(
            "ShhDownloads", isDirectory: true)
        try? FileManager.default.createDirectory(at: defaultDir, withIntermediateDirectories: true)
        let targetURL = destinationURL ?? defaultDir.appendingPathComponent(safeFileName)

        if destinationURL == nil {
            let standardizedTarget = targetURL.standardizedFileURL.path
            let standardizedDefault = defaultDir.standardizedFileURL.path
            guard standardizedTarget.hasPrefix(standardizedDefault) else {
                directoryErrorMessage = "Invalid destination path."
                return nil
            }
        }

        let fileExists = FileManager.default.fileExists(atPath: targetURL.path)

        let proceed: Bool
        if let overwrite {
            proceed = overwrite
        } else if fileExists {
            proceed = await requestConflictResolution(
                direction: .download,
                remotePath: file.path,
                localURL: targetURL,
                existingItemName: file.name,
                destinationDescription: targetURL.lastPathComponent
            )
        } else {
            proceed = true
        }

        guard proceed else { return nil }

        // Atomic safety: Do NOT remove targetURL up front.
        // The SFTP repository downloads to a temporary file and atomically replaces destination on success.
        guard isCurrentSFTPOperation(transferContext) else { return nil }

        let task = await transferCoordinator.enqueue(
            direction: .download,
            remotePath: file.path,
            localURL: targetURL,
            totalBytes: file.size
        )
        guard isCurrentSFTPOperation(transferContext) else {
            await transferCoordinator.cancel(id: task.id)
            await transferCoordinator.remove(id: task.id)
            return nil
        }
        guard await publishTransferQueueState(transferContext) else {
            await transferCoordinator.cancel(id: task.id)
            await transferCoordinator.remove(id: task.id)
            return nil
        }

        let taskID = task.id
        let executionTask = Task { @MainActor [weak self] in
            guard let self else { return }
            guard self.isCurrentSFTPOperation(transferContext) else {
                await self.transferCoordinator.cancel(id: taskID)
                return
            }
            do {
                await self.transferCoordinator.registerCancellation(id: taskID) { [weak self] in
                    Task { @MainActor [weak self] in
                        self?.activeTransferTasks[taskID]?.cancel()
                    }
                }
                guard self.isCurrentSFTPOperation(transferContext) else {
                    await self.transferCoordinator.cancel(id: taskID)
                    self.activeTransferTasks.removeValue(forKey: taskID)
                    return
                }
                try await repo.download(from: file.path, to: targetURL) { [weak self] progress in
                    Task { @MainActor [weak self] in
                        guard let self,
                            self.isCurrentSFTPOperation(transferContext)
                        else { return }
                        await self.transferCoordinator.updateProgress(
                            id: taskID,
                            bytesTransferred: progress.bytesTransferred,
                            totalBytes: progress.totalBytes
                        )
                        guard await self.publishTransferQueueState(transferContext) else { return }
                    }
                }
                guard self.isCurrentSFTPOperation(transferContext) else {
                    await self.transferCoordinator.cancel(id: taskID)
                    self.activeTransferTasks.removeValue(forKey: taskID)
                    return
                }
                await self.transferCoordinator.markCompleted(id: taskID)
                guard self.isCurrentSFTPOperation(transferContext) else {
                    self.activeTransferTasks.removeValue(forKey: taskID)
                    return
                }
                guard await self.publishTransferQueueState(transferContext) else {
                    self.activeTransferTasks.removeValue(forKey: taskID)
                    return
                }
            } catch {
                guard self.isCurrentSFTPOperation(transferContext) else {
                    await self.transferCoordinator.cancel(id: taskID)
                    self.activeTransferTasks.removeValue(forKey: taskID)
                    return
                }
                if Task.isCancelled || (error as? SFTPRepositoryError) == .cancelled {
                    await self.transferCoordinator.cancel(id: taskID)
                } else {
                    await self.transferCoordinator.markFailed(
                        id: taskID, error: error.localizedDescription)
                }
                guard await self.publishTransferQueueState(transferContext) else {
                    self.activeTransferTasks.removeValue(forKey: taskID)
                    return
                }
            }
            self.activeTransferTasks.removeValue(forKey: taskID)
        }
        activeTransferTasks[taskID] = executionTask
        return task
    }

    @discardableResult
    public func enqueueUpload(
        localURL: URL,
        destinationDirectory: RemotePath? = nil,
        overwrite: Bool? = nil
    ) async -> TransferTask? {
        guard canUseSingleSessionAuxiliaryFeatures, let repo = sftpRepository else {
            directoryErrorMessage = "SFTP repository unavailable."
            return nil
        }
        let transferContext = captureSFTPOperation(
            repository: repo, operationGeneration: 0, scope: .transfer)

        let dir = destinationDirectory ?? currentPath
        let fileName = localURL.lastPathComponent
        guard !fileName.isEmpty && fileName != "." && fileName != ".." && !fileName.contains("/")
        else {
            directoryErrorMessage = "Invalid upload file name: '\(fileName)'"
            return nil
        }
        guard let remotePath = try? dir.appendingSafely(fileName) else {
            directoryErrorMessage = "Invalid remote path for upload: '\(fileName)'"
            return nil
        }

        var existsRemote = false
        if currentPath == dir && currentDirectoryFiles.contains(where: { $0.name == fileName }) {
            existsRemote = true
        } else if (try? await repo.fetchAttributes(at: remotePath)) != nil {
            existsRemote = true
        }

        let proceed: Bool
        if let overwrite {
            proceed = overwrite
        } else if existsRemote {
            proceed = await requestConflictResolution(
                direction: .upload,
                remotePath: remotePath,
                localURL: localURL,
                existingItemName: fileName,
                destinationDescription: remotePath.description
            )
        } else {
            proceed = true
        }

        guard proceed else { return nil }

        let fileSize =
            (try? FileManager.default.attributesOfItem(atPath: localURL.path)[.size] as? NSNumber)?
            .int64Value ?? 0

        guard isCurrentSFTPOperation(transferContext) else { return nil }
        let task = await transferCoordinator.enqueue(
            direction: .upload,
            remotePath: remotePath,
            localURL: localURL,
            totalBytes: fileSize
        )
        guard isCurrentSFTPOperation(transferContext) else {
            await transferCoordinator.cancel(id: task.id)
            await transferCoordinator.remove(id: task.id)
            return nil
        }
        guard await publishTransferQueueState(transferContext) else {
            await transferCoordinator.cancel(id: task.id)
            await transferCoordinator.remove(id: task.id)
            return nil
        }

        let taskID = task.id
        let executionTask = Task { @MainActor [weak self] in
            guard let self else { return }
            guard self.isCurrentSFTPOperation(transferContext) else {
                await self.transferCoordinator.cancel(id: taskID)
                return
            }
            do {
                await self.transferCoordinator.registerCancellation(id: taskID) { [weak self] in
                    Task { @MainActor [weak self] in
                        self?.activeTransferTasks[taskID]?.cancel()
                    }
                }
                guard self.isCurrentSFTPOperation(transferContext) else {
                    await self.transferCoordinator.cancel(id: taskID)
                    self.activeTransferTasks.removeValue(forKey: taskID)
                    return
                }
                try await repo.upload(from: localURL, to: remotePath) { [weak self] progress in
                    Task { @MainActor [weak self] in
                        guard let self,
                            self.isCurrentSFTPOperation(transferContext)
                        else { return }
                        await self.transferCoordinator.updateProgress(
                            id: taskID,
                            bytesTransferred: progress.bytesTransferred,
                            totalBytes: progress.totalBytes
                        )
                        guard await self.publishTransferQueueState(transferContext) else { return }
                    }
                }
                guard self.isCurrentSFTPOperation(transferContext) else {
                    await self.transferCoordinator.cancel(id: taskID)
                    self.activeTransferTasks.removeValue(forKey: taskID)
                    return
                }
                await self.transferCoordinator.markCompleted(id: taskID)
                guard await self.publishTransferQueueState(transferContext) else {
                    self.activeTransferTasks.removeValue(forKey: taskID)
                    return
                }
                self.invalidateDirectoryCache(at: dir)
                if self.currentPath == dir {
                    guard self.isCurrentSFTPOperation(transferContext) else {
                        self.activeTransferTasks.removeValue(forKey: taskID)
                        return
                    }
                    await self.refreshCurrentDirectory()
                }
            } catch {
                guard self.isCurrentSFTPOperation(transferContext) else {
                    await self.transferCoordinator.cancel(id: taskID)
                    self.activeTransferTasks.removeValue(forKey: taskID)
                    return
                }
                if Task.isCancelled || (error as? SFTPRepositoryError) == .cancelled {
                    await self.transferCoordinator.cancel(id: taskID)
                } else {
                    await self.transferCoordinator.markFailed(
                        id: taskID, error: error.localizedDescription)
                }
                guard await self.publishTransferQueueState(transferContext) else {
                    self.activeTransferTasks.removeValue(forKey: taskID)
                    return
                }
            }
            self.activeTransferTasks.removeValue(forKey: taskID)
        }
        activeTransferTasks[taskID] = executionTask
        return task
    }

    public func cancelTransfer(id: UUID) async {
        let transferContext = sftpRepository.map {
            captureSFTPOperation(repository: $0, operationGeneration: 0, scope: .transfer)
        }
        activeTransferTasks[id]?.cancel()
        activeTransferTasks.removeValue(forKey: id)
        await transferCoordinator.cancel(id: id)
        if let transferContext {
            _ = await publishTransferQueueState(transferContext)
        }
    }

    public func retryTransfer(id: UUID) async {
        guard let task = transferQueueState.task(withID: id) else { return }
        await transferCoordinator.remove(id: id)
        if task.direction == .download {
            let file = RemoteFile(name: task.remotePath.lastComponent, path: task.remotePath)
            _ = await enqueueDownload(file: file, destinationURL: task.localURL, overwrite: true)
        } else {
            _ = await enqueueUpload(
                localURL: task.localURL, destinationDirectory: task.remotePath.parent,
                overwrite: true)
        }
    }

    public func clearCompletedTransfers() async {
        await transferCoordinator.clearTerminal()
        transferQueueState = await transferCoordinator.snapshot()
        cleanTemporaryTransfersDirectory(removeAll: false)
    }

    public func resolvePendingConflict(overwrite: Bool) {
        guard !conflictQueue.isEmpty else {
            pendingConflict = nil
            return
        }
        let current = conflictQueue.removeFirst()
        self.pendingConflict = conflictQueue.first
        current.continuation(overwrite)
    }

    private func requestConflictResolution(
        direction: TransferDirection,
        remotePath: RemotePath,
        localURL: URL,
        existingItemName: String,
        destinationDescription: String
    ) async -> Bool {
        await withCheckedContinuation { continuation in
            let conflict = FileTransferConflict(
                direction: direction,
                remotePath: remotePath,
                localURL: localURL,
                existingItemName: existingItemName,
                destinationDescription: destinationDescription,
                continuation: { choice in
                    continuation.resume(returning: choice)
                }
            )
            self.conflictQueue.append(conflict)
            if self.pendingConflict == nil {
                self.pendingConflict = conflict
            }
        }
    }

    private func drainPendingConflicts() {
        let conflicts = conflictQueue
        conflictQueue.removeAll()
        pendingConflict = nil
        for conflict in conflicts {
            conflict.continuation(false)
        }
    }

    private func cleanTemporaryTransfersDirectory(removeAll: Bool = false) {
        let fileManager = FileManager.default
        let downloadDir = fileManager.temporaryDirectory.appendingPathComponent(
            "ShhDownloads", isDirectory: true)
        let uploadDir = fileManager.temporaryDirectory.appendingPathComponent(
            "ShhUploads", isDirectory: true)

        if removeAll {
            try? fileManager.removeItem(at: downloadDir)
            try? fileManager.removeItem(at: uploadDir)
        } else {
            if let contents = try? fileManager.contentsOfDirectory(
                at: downloadDir, includingPropertiesForKeys: nil)
            {
                let activeLocalURLs = Set(
                    transferQueueState.activeTasks.map(\.localURL.standardizedFileURL))
                for fileURL in contents {
                    if !activeLocalURLs.contains(fileURL.standardizedFileURL) {
                        try? fileManager.removeItem(at: fileURL)
                    }
                }
            }
            if let stagedDirs = try? fileManager.contentsOfDirectory(
                at: uploadDir, includingPropertiesForKeys: nil)
            {
                let activeLocalURLs = Set(
                    transferQueueState.activeTasks.map(\.localURL.standardizedFileURL))
                for stagedDir in stagedDirs {
                    if let files = try? fileManager.contentsOfDirectory(
                        at: stagedDir, includingPropertiesForKeys: nil)
                    {
                        let anyActive = files.contains {
                            activeLocalURLs.contains($0.standardizedFileURL)
                        }
                        if !anyActive {
                            try? fileManager.removeItem(at: stagedDir)
                        }
                    } else {
                        try? fileManager.removeItem(at: stagedDir)
                    }
                }
            }
        }
    }

    // MARK: - File Actions (Delete, Rename, Move, Create)

    private func nextSFTPOperationGeneration() -> UInt64 {
        fileMutationGeneration &+= 1
        return fileMutationGeneration
    }

    private func captureSFTPOperation(
        repository: any SFTPRepository,
        operationGeneration: UInt64,
        scope: SFTPOperationScope = .fileMutation
    ) -> SFTPOperationContext {
        let runtime = selectedSessionRuntime
        return SFTPOperationContext(
            sessionID: selectedSessionID,
            runtimeIdentity: runtime.map { ObjectIdentifier($0) },
            hostID: runtime?.host.id ?? activeHost?.id,
            repositoryIdentity: ObjectIdentifier(repository as AnyObject),
            auxiliarySessionID: auxiliarySessionID,
            auxiliarySetupGeneration: auxiliarySetupGeneration,
            sftpSetupGeneration: sftpSetupGeneration,
            transferQueueGeneration: transferQueueGeneration,
            lifecycleGeneration: lifecycleGeneration,
            operationGeneration: operationGeneration,
            scope: scope
        )
    }

    private func isCurrentSFTPOperation(_ context: SFTPOperationContext) -> Bool {
        guard canUseSingleSessionAuxiliaryFeatures,
            selectedSessionID == context.sessionID,
            selectedSessionRuntime.map { ObjectIdentifier($0) } == context.runtimeIdentity,
            activeHost?.id == context.hostID,
            auxiliarySessionID == context.auxiliarySessionID,
            auxiliarySetupGeneration == context.auxiliarySetupGeneration,
            sftpSetupGeneration == context.sftpSetupGeneration,
            transferQueueGeneration == context.transferQueueGeneration,
            lifecycleGeneration == context.lifecycleGeneration,
            operationGeneration(for: context.scope) == context.operationGeneration,
            let repository = sftpRepository,
            ObjectIdentifier(repository as AnyObject) == context.repositoryIdentity
        else { return false }
        return true
    }

    private func operationGeneration(for scope: SFTPOperationScope) -> UInt64 {
        switch scope {
        case .fileMutation: return fileMutationGeneration
        case .preview: return previewOperationGeneration
        case .editor: return editorOperationGeneration
        case .transfer: return 0
        }
    }

    private func publishTransferQueueState(_ context: SFTPOperationContext) async -> Bool {
        guard isCurrentSFTPOperation(context) else { return false }
        let snapshot = await transferCoordinator.snapshot()
        guard isCurrentSFTPOperation(context) else { return false }
        transferQueueState = snapshot
        return true
    }

    public func deleteFile(_ file: RemoteFile) async throws {
        guard canUseSingleSessionAuxiliaryFeatures, let repo = sftpRepository else {
            throw SFTPRepositoryError.connectionClosed
        }
        let context = captureSFTPOperation(
            repository: repo, operationGeneration: nextSFTPOperationGeneration())
        if file.isDirectory {
            try await repo.removeDirectory(at: file.path)
        } else {
            try await repo.removeFile(at: file.path)
        }
        guard isCurrentSFTPOperation(context) else { return }
        invalidateDirectoryCache(at: file.path.parent)
        guard isCurrentSFTPOperation(context) else { return }
        await refreshCurrentDirectory()
        guard isCurrentSFTPOperation(context) else { return }
    }

    public func renameFile(_ file: RemoteFile, to newName: String) async throws {
        guard canUseSingleSessionAuxiliaryFeatures, let repo = sftpRepository else {
            throw SFTPRepositoryError.connectionClosed
        }
        let trimmed = newName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty && !trimmed.contains("/") && trimmed != ".." && trimmed != "." else {
            throw SFTPRepositoryError.invalidPath("Invalid file name: '\(newName)'")
        }
        let newPath = try file.path.parent.appendingSafely(trimmed)
        let context = captureSFTPOperation(
            repository: repo, operationGeneration: nextSFTPOperationGeneration())
        try await repo.rename(from: file.path, to: newPath)
        guard isCurrentSFTPOperation(context) else { return }
        invalidateDirectoryCache(at: file.path.parent)
        guard isCurrentSFTPOperation(context) else { return }
        await refreshCurrentDirectory()
        guard isCurrentSFTPOperation(context) else { return }
    }

    public func moveFile(_ file: RemoteFile, to destinationDirectory: RemotePath) async throws {
        guard canUseSingleSessionAuxiliaryFeatures, let repo = sftpRepository else {
            throw SFTPRepositoryError.connectionClosed
        }
        if file.isDirectory && destinationDirectory.isDescendantOrEqual(to: file.path) {
            throw SFTPRepositoryError.invalidPath(
                "Cannot move directory into itself or descendant: '\(destinationDirectory.description)'"
            )
        }
        let targetPath = try destinationDirectory.appendingSafely(file.name)
        let context = captureSFTPOperation(
            repository: repo, operationGeneration: nextSFTPOperationGeneration())
        try await repo.rename(from: file.path, to: targetPath)
        guard isCurrentSFTPOperation(context) else { return }
        invalidateDirectoryCache(at: file.path.parent)
        invalidateDirectoryCache(at: destinationDirectory)
        guard isCurrentSFTPOperation(context) else { return }
        await refreshCurrentDirectory()
        guard isCurrentSFTPOperation(context) else { return }
    }

    public func createDirectory(named name: String) async throws {
        guard canUseSingleSessionAuxiliaryFeatures, let repo = sftpRepository else {
            throw SFTPRepositoryError.connectionClosed
        }
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty && !trimmed.contains("/") && trimmed != ".." && trimmed != "." else {
            throw SFTPRepositoryError.invalidPath("Invalid directory name: '\(name)'")
        }
        let directory = currentPath
        let targetPath = try directory.appendingSafely(trimmed)
        let context = captureSFTPOperation(
            repository: repo, operationGeneration: nextSFTPOperationGeneration())
        try await repo.createDirectory(at: targetPath)
        guard isCurrentSFTPOperation(context) else { return }
        invalidateDirectoryCache(at: directory)
        guard isCurrentSFTPOperation(context) else { return }
        await refreshCurrentDirectory()
        guard isCurrentSFTPOperation(context) else { return }
    }

    public func createFile(named name: String, content: Data = Data()) async throws {
        guard canUseSingleSessionAuxiliaryFeatures, let repo = sftpRepository else {
            throw SFTPRepositoryError.connectionClosed
        }
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty && !trimmed.contains("/") && trimmed != ".." && trimmed != "." else {
            throw SFTPRepositoryError.invalidPath("Invalid file name: '\(name)'")
        }
        let directory = currentPath
        let targetPath = try directory.appendingSafely(trimmed)
        let context = captureSFTPOperation(
            repository: repo, operationGeneration: nextSFTPOperationGeneration())
        try await repo.writeFile(data: content, at: targetPath, progress: nil)
        guard isCurrentSFTPOperation(context) else { return }
        invalidateDirectoryCache(at: directory)
        guard isCurrentSFTPOperation(context) else { return }
        await refreshCurrentDirectory()
        guard isCurrentSFTPOperation(context) else { return }
    }

    // MARK: - Previews & In-App Text Editor

    public func openItem(_ file: RemoteFile) async {
        guard canUseSingleSessionAuxiliaryFeatures, let repo = sftpRepository else { return }
        previewOperationGeneration &+= 1
        let context = captureSFTPOperation(
            repository: repo,
            operationGeneration: previewOperationGeneration,
            scope: .preview)
        if file.isDirectory {
            guard isCurrentSFTPOperation(context) else { return }
            await navigateTo(file.path)
            return
        }
        if file.isSymlink {
            if let attrs = try? await repo.fetchAttributes(at: file.path) {
                guard isCurrentSFTPOperation(context) else { return }
                if attrs.isDirectory {
                    await navigateTo(file.path)
                    return
                }
            }
            if let targetStr = file.symlinkTarget {
                let resolvedPath =
                    targetStr.hasPrefix("/")
                    ? RemotePath(targetStr) : file.path.parent.appending(targetStr)
                if let attrs = try? await repo.fetchAttributes(at: resolvedPath) {
                    guard isCurrentSFTPOperation(context) else { return }
                    if attrs.isDirectory {
                        await navigateTo(file.path)
                        return
                    }
                }
            }
        }
        guard isCurrentSFTPOperation(context) else { return }
        await loadPreview(for: file)
    }

    public func loadPreview(for file: RemoteFile) async {
        guard canUseSingleSessionAuxiliaryFeatures, let repo = sftpRepository else { return }
        previewOperationGeneration &+= 1
        let generation = previewOperationGeneration
        let context = captureSFTPOperation(
            repository: repo, operationGeneration: generation, scope: .preview)
        guard isCurrentSFTPOperation(context) else { return }
        previewFile = file
        previewData = nil
        previewErrorMessage = nil

        let maxPreviewSize: Int64 = 5 * 1024 * 1024  // 5 MB
        if file.size > maxPreviewSize {
            guard isCurrentSFTPOperation(context) else { return }
            previewErrorMessage =
                "File size (\(ByteCountFormatter.string(fromByteCount: file.size, countStyle: .file))) exceeds 5 MB preview limit. Please download to view."
            isPreviewLoading = false
            return
        }

        isPreviewLoading = true
        do {
            let data = try await repo.readFile(at: file.path)
            guard isCurrentSFTPOperation(context) else { return }
            previewData = data
            isPreviewLoading = false
        } catch {
            guard isCurrentSFTPOperation(context) else { return }
            isPreviewLoading = false
            previewErrorMessage = error.localizedDescription
        }
    }

    public func closePreview() {
        previewOperationGeneration &+= 1
        previewFile = nil
        previewData = nil
        previewErrorMessage = nil
        isPreviewLoading = false
    }

    public func openEditor(for file: RemoteFile) async throws {
        guard canUseSingleSessionAuxiliaryFeatures, let repo = sftpRepository else {
            throw SFTPRepositoryError.connectionClosed
        }
        editorOperationGeneration &+= 1
        let context = captureSFTPOperation(
            repository: repo, operationGeneration: editorOperationGeneration, scope: .editor)
        guard isCurrentSFTPOperation(context) else { return }
        isSavingFile = false
        editorErrorMessage = nil

        let maxEditorSize: Int64 = 2 * 1024 * 1024  // 2 MB
        if file.size > maxEditorSize {
            guard isCurrentSFTPOperation(context) else { return }
            let err = SFTPRepositoryError.remoteFailure(
                "File size (\(ByteCountFormatter.string(fromByteCount: file.size, countStyle: .file))) exceeds 2 MB editor limit. Please download to view."
            )
            editorErrorMessage = err.localizedDescription
            throw err
        }

        do {
            let data = try await repo.readFile(at: file.path)
            guard isCurrentSFTPOperation(context) else { return }
            guard let text = String(data: data, encoding: .utf8) else {
                let err = SFTPRepositoryError.remoteFailure(
                    "Cannot edit '\(file.name)': File contains non-UTF-8 or binary data.")
                guard isCurrentSFTPOperation(context) else { return }
                editorErrorMessage = err.localizedDescription
                throw err
            }
            guard isCurrentSFTPOperation(context) else { return }
            editingFileContent = text
            activeEditingFile = file
            activeEditingHostID = activeHost?.id
        } catch {
            guard isCurrentSFTPOperation(context) else { return }
            editorErrorMessage = error.localizedDescription
            throw error
        }
    }

    public func closeEditor() {
        editorOperationGeneration &+= 1
        activeEditingFile = nil
        editingFileContent = ""
        isSavingFile = false
        editorErrorMessage = nil
        activeEditingHostID = nil
    }

    public func saveEditedFile() async throws {
        guard canUseSingleSessionAuxiliaryFeatures,
            let repo = sftpRepository, let file = activeEditingFile
        else {
            throw SFTPRepositoryError.connectionClosed
        }
        guard activeHost?.id == activeEditingHostID else {
            throw SFTPRepositoryError.remoteFailure(
                "Host mismatch: File editor session belongs to a different host.")
        }
        editorOperationGeneration &+= 1
        let context = captureSFTPOperation(
            repository: repo, operationGeneration: editorOperationGeneration, scope: .editor)
        guard isCurrentSFTPOperation(context) else { return }
        isSavingFile = true
        editorErrorMessage = nil
        do {
            let data = Data(editingFileContent.utf8)
            try await repo.writeFile(data: data, at: file.path, progress: nil)
            guard isCurrentSFTPOperation(context) else { return }
            invalidateDirectoryCache(at: file.path.parent)
            if currentPath == file.path.parent {
                guard isCurrentSFTPOperation(context) else { return }
                await refreshCurrentDirectory()
                guard isCurrentSFTPOperation(context) else { return }
            }
            isSavingFile = false
        } catch {
            guard isCurrentSFTPOperation(context) else { return }
            isSavingFile = false
            editorErrorMessage = error.localizedDescription
            throw error
        }
    }

    // MARK: - Port Forwarding Management

    private func forwardingManagerGate(
        for manager: any PortForwardingManaging
    ) -> PortForwardingManagerOperationGate {
        let identity = ObjectIdentifier(manager as AnyObject)
        if let gate = forwardingManagerGates[identity] { return gate }
        let gate = PortForwardingManagerOperationGate()
        forwardingManagerGates[identity] = gate
        return gate
    }

    private func rebindForwardingManager(
        _ manager: any PortForwardingManaging
    ) async -> UInt64? {
        let gate = forwardingManagerGate(for: manager)
        let token = await gate.rebind()
        do {
            guard await gate.run(generation: token, operation: { await manager.stopAll() }) != nil
            else { return nil }
        } catch {
            return nil
        }
        return token
    }

    private func stopAllForwarding(
        manager: any PortForwardingManaging, generation token: UInt64
    ) async {
        let gate = forwardingManagerGate(for: manager)
        _ = try? await gate.run(generation: token, operation: { await manager.stopAll() })
    }

    private func stopForwarding(
        ruleID: UUID, manager: any PortForwardingManaging, generation token: UInt64
    ) async throws {
        let gate = forwardingManagerGate(for: manager)
        guard
            try await gate.run(
                generation: token,
                operation: { try await manager.stopForwarding(ruleID: ruleID) }
            ) != nil
        else {
            throw TransportError.cancelled
        }
    }

    private func isCurrentForwardingManager(_ manager: any PortForwardingManaging) -> Bool {
        guard let currentManager = portForwardingManager else { return false }
        return ObjectIdentifier(currentManager as AnyObject)
            == ObjectIdentifier(manager as AnyObject)
    }

    private func isCurrentForwardingOperation(
        _ ownerContext: AuxiliaryOwnerContext,
        manager: any PortForwardingManaging
    ) -> Bool {
        isCurrentAuxiliaryOwner(ownerContext) && isCurrentForwardingManager(manager)
    }

    private func publishForwardingSessions(_ sessions: [ForwardingSessionState]) {
        for session in sessions {
            if let idx = forwardingSessions.firstIndex(where: { $0.ruleID == session.ruleID }) {
                forwardingSessions[idx] = session
            } else {
                forwardingSessions.append(session)
            }
        }
    }

    private func startForwardingMonitoring(
        manager: any PortForwardingManaging,
        ownerContext: AuxiliaryOwnerContext
    ) {
        forwardingStreamTask?.cancel()
        forwardingStreamTask = Task { @MainActor [weak self] in
            let stream = await manager.sessionStatesStream()
            guard let self, !Task.isCancelled,
                self.isCurrentForwardingOperation(ownerContext, manager: manager)
            else { return }
            for await states in stream {
                guard !Task.isCancelled,
                    self.isCurrentForwardingOperation(ownerContext, manager: manager)
                else { return }
                self.forwardingSessions = states
            }
        }
    }

    private func autoStartForwardingRules(
        for host: Host,
        manager: any PortForwardingManaging,
        ownerContext: AuxiliaryOwnerContext,
        managerGeneration: UInt64
    ) async -> [ForwardingSessionState] {
        var started: [ForwardingSessionState] = []
        for rule in host.forwardingRules where rule.enabled {
            guard isCurrentForwardingOperation(ownerContext, manager: manager) else { break }
            if rule.requiresNonLoopbackApproval {
                let message = "\(rule.name) requires approval to bind to \(rule.localHost)."
                guard isCurrentForwardingOperation(ownerContext, manager: manager) else { break }
                forwardingErrorMessage = message
                terminalController.feed("\r\n\u{1b}[33m[\(message)]\u{1b}[0m\r\n")
                continue
            }
            do {
                guard
                    let session = try await forwardingManagerGate(for: manager).run(
                        generation: managerGeneration,
                        operation: { try await manager.startForwarding(rule: rule) }
                    )
                else { break }
                guard isCurrentForwardingOperation(ownerContext, manager: manager) else {
                    // A non-cooperative manager may complete after selection
                    // moved. The generation gate prevents stale cleanup from
                    // touching a newer owner of the reused manager.
                    await stopForwarding(
                        ruleID: rule.id, manager: manager, generation: managerGeneration)
                    continue
                }
                started.append(session)
            } catch {
                guard isCurrentForwardingOperation(ownerContext, manager: manager) else {
                    continue
                }
                let message = "Failed to auto-start \(rule.name): \(error.localizedDescription)"
                forwardingErrorMessage = message
                terminalController.feed("\r\n\u{1b}[33m[\(message)]\u{1b}[0m\r\n")
            }
        }
        return started
    }

    @discardableResult
    public func startForwarding(rule: PortForwardingRule) async throws -> ForwardingSessionState {
        guard canUseSingleSessionAuxiliaryFeatures, let manager = portForwardingManager,
            let runtime = selectedSessionRuntime,
            auxiliarySessionID == runtime.session.id
        else {
            throw TransportError.unsupported
        }
        let connection = runtime.connection
        let ownerContext = auxiliaryOwnerContext(for: runtime, connection: connection)
        guard isCurrentForwardingOperation(ownerContext, manager: manager),
            let managerGeneration = forwardingManagerOperationGeneration
        else {
            throw TransportError.cancelled
        }
        forwardingErrorMessage = nil
        do {
            guard
                let session = try await forwardingManagerGate(for: manager).run(
                    generation: managerGeneration,
                    operation: { try await manager.startForwarding(rule: rule) }
                )
            else { throw TransportError.cancelled }
            guard isCurrentForwardingOperation(ownerContext, manager: manager) else {
                await stopForwarding(
                    ruleID: rule.id, manager: manager, generation: managerGeneration)
                throw TransportError.cancelled
            }
            publishForwardingSessions([session])
            return session
        } catch {
            guard isCurrentForwardingOperation(ownerContext, manager: manager) else {
                throw error
            }
            forwardingErrorMessage = error.localizedDescription
            throw error
        }
    }

    public func stopForwarding(ruleID: UUID) async {
        guard canUseSingleSessionAuxiliaryFeatures,
            let manager = portForwardingManager,
            let runtime = selectedSessionRuntime,
            auxiliarySessionID == runtime.session.id
        else { return }
        let connection = runtime.connection
        let ownerContext = auxiliaryOwnerContext(for: runtime, connection: connection)
        guard isCurrentForwardingOperation(ownerContext, manager: manager),
            let managerGeneration = forwardingManagerOperationGeneration
        else { return }
        do {
            try await stopForwarding(
                ruleID: ruleID, manager: manager, generation: managerGeneration)
            guard isCurrentForwardingOperation(ownerContext, manager: manager) else { return }
            if let idx = forwardingSessions.firstIndex(where: { $0.ruleID == ruleID }) {
                forwardingSessions[idx].status = .stopped
                forwardingSessions[idx].activeConnectionsCount = 0
            }
        } catch {
            guard isCurrentForwardingOperation(ownerContext, manager: manager) else { return }
            forwardingErrorMessage = error.localizedDescription
        }
    }

    public func stopAllForwarding() async {
        guard canUseSingleSessionAuxiliaryFeatures,
            let manager = portForwardingManager,
            let runtime = selectedSessionRuntime,
            auxiliarySessionID == runtime.session.id
        else { return }
        let connection = runtime.connection
        let ownerContext = auxiliaryOwnerContext(for: runtime, connection: connection)
        guard isCurrentForwardingOperation(ownerContext, manager: manager),
            let managerGeneration = forwardingManagerOperationGeneration
        else { return }
        await stopAllForwarding(manager: manager, generation: managerGeneration)
        guard isCurrentForwardingOperation(ownerContext, manager: manager) else { return }
        for idx in forwardingSessions.indices {
            forwardingSessions[idx].status = .stopped
            forwardingSessions[idx].activeConnectionsCount = 0
        }
    }

    public func addForwardingRule(
        _ rule: PortForwardingRule, for host: Host, autoStartIfConnected: Bool = true
    ) async throws {
        var updatedHost = (activeHost?.id == host.id ? activeHost! : host)
        if let idx = updatedHost.forwardingRules.firstIndex(where: { $0.id == rule.id }) {
            updatedHost.forwardingRules[idx] = rule
        } else {
            updatedHost.forwardingRules.append(rule)
        }
        try await saveHost(updatedHost)
        if activeHost?.id == host.id {
            activeHost = updatedHost
            await stopForwarding(ruleID: rule.id)
            if autoStartIfConnected && rule.enabled && !rule.requiresNonLoopbackApproval {
                _ = try? await startForwarding(rule: rule)
            }
        }
    }

    public func removeForwardingRule(ruleID: UUID, for host: Host) async throws {
        await stopForwarding(ruleID: ruleID)
        var updatedHost = (activeHost?.id == host.id ? activeHost! : host)
        updatedHost.forwardingRules.removeAll { $0.id == ruleID }
        try await saveHost(updatedHost)
        if activeHost?.id == host.id {
            activeHost = updatedHost
        }
    }

    // MARK: - ProxyJump Bastion Resolution

    public func resolveBastionHops(for host: Host) async -> [(Host, IdentityDescriptor?)] {
        guard case .proxyJump(let jumpOpts) = host.connection else { return [] }
        var result: [(Host, IdentityDescriptor?)] = []
        let hosts = (try? await catalog.listHosts()) ?? []
        let idents = (try? await catalog.identities()) ?? []
        for hop in jumpOpts.config.hops {
            switch hop {
            case .hostID(let id):
                if let bastion = hosts.first(where: { $0.id == id }) {
                    let ident = bastion.identityID.flatMap { identID in
                        idents.first(where: { $0.id == identID })
                    }
                    result.append((bastion, ident))
                }
            case .endpoint(let ep):
                if let epHost = try? Host(
                    name: ep.hostname, hostname: ep.hostname, port: ep.port, username: ep.username,
                    identityID: ep.identityID)
                {
                    let ident = ep.identityID.flatMap { identID in
                        idents.first(where: { $0.id == identID })
                    }
                    result.append((epHost, ident))
                }
            }
        }
        return result
    }

    public func resolveBastionNames(for host: Host) async -> [String] {
        let hops = await resolveBastionHops(for: host)
        return hops.map { $0.0.name }
    }

    // MARK: - Host Management & Shared Catalog Sync

    public func syncSharedCatalogAndTrust() async throws {
        guard
            !isRunningInTestEnvironment || fileProviderHelper.customContainerURL != nil
                || fileProviderHelper.customLocalContainerURL != nil
        else { return }
        let snapshot = await catalog.snapshot()
        let records = await trustStore.allRecords()
        #if canImport(FileProvider)
        if persistenceWriteBlocked {
            // Preserve an unreadable shared catalog. Explicit edits are retained
            // locally until the original shared state can be read safely again.
            try fileProviderHelper.syncLocalState(snapshot: snapshot, trustRecords: records)
        } else {
            try fileProviderHelper.syncSharedState(snapshot: snapshot, trustRecords: records)
        }
        #else
        try fileProviderHelper.syncLocalState(snapshot: snapshot, trustRecords: records)
        #endif
    }

    public func saveHost(_ host: Host) async throws {
        try await catalog.save(host)
        catalogUpdateToken = UUID()
        await reconcileCatalogIdentities()
        try await syncSharedCatalogAndTrust()
    }

    public func deleteHost(id: UUID) async throws {
        try await catalog.delete(id: id)
        catalogUpdateToken = UUID()
        await reconcileCatalogIdentities()
        try await syncSharedCatalogAndTrust()
    }

    // MARK: - SSH Keys & Credential Management

    public var keychain: any CredentialStore {
        credentialStore
    }

    @discardableResult
    public func createEd25519Identity(
        name: String,
        comment: String? = nil,
        keyPair: (
            privateKey: Curve25519.Signing.PrivateKey, openSSHPrivateKey: String,
            openSSHPublicKey: String, fingerprint: String
        )? = nil
    ) async throws -> IdentityDescriptor {
        let trimmedName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedName.isEmpty else {
            throw ShhValidationError.empty(field: "identity name")
        }
        let commentValue = comment?.trimmingCharacters(in: .whitespacesAndNewlines)
        let effectiveComment =
            (commentValue?.isEmpty == false) ? (commentValue ?? trimmedName) : trimmedName
        let generated = keyPair ?? Ed25519Parser.generateKeyPair(comment: effectiveComment)
        let reference = "id-\(UUID().uuidString)"
        try await credentialStore.save(Data(generated.openSSHPrivateKey.utf8), reference: reference)
        let descriptor = try IdentityDescriptor(
            name: trimmedName,
            kind: .privateKey,
            publicFingerprint: generated.fingerprint,
            keychainReference: reference
        )
        try await catalog.save(descriptor)
        catalogUpdateToken = UUID()
        await reconcileCatalogIdentities()
        try? await syncSharedCatalogAndTrust()
        return descriptor
    }

    @discardableResult
    public func importPrivateKeyIdentity(name: String, privateKeyText: String) async throws
        -> IdentityDescriptor
    {
        let trimmedName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedName.isEmpty else {
            throw ShhValidationError.empty(field: "identity name")
        }
        let trimmedKey = privateKeyText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedKey.isEmpty else {
            throw ShhValidationError.empty(field: "private key")
        }
        let privateKey = try Ed25519Parser.parse(from: trimmedKey)
        let publicKey = privateKey.publicKey
        let fingerprint = Ed25519Parser.fingerprint(from: publicKey)
        let reference = "id-\(UUID().uuidString)"
        let storeData: Data
        if trimmedKey.contains("-----BEGIN") {
            storeData = Data(trimmedKey.utf8)
        } else {
            let openSSH = privateKey.makeSSHRepresentation(comment: trimmedName)
            storeData = Data(openSSH.utf8)
        }
        try await credentialStore.save(storeData, reference: reference)
        let descriptor = try IdentityDescriptor(
            name: trimmedName,
            kind: .privateKey,
            publicFingerprint: fingerprint,
            keychainReference: reference
        )
        try await catalog.save(descriptor)
        catalogUpdateToken = UUID()
        await reconcileCatalogIdentities()
        try? await syncSharedCatalogAndTrust()
        return descriptor
    }

    @discardableResult
    public func createPasswordIdentity(name: String, password: String) async throws
        -> IdentityDescriptor
    {
        let trimmedName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedName.isEmpty else {
            throw ShhValidationError.empty(field: "identity name")
        }
        guard !password.isEmpty else {
            throw ShhValidationError.empty(field: "password")
        }
        let reference = "pwd-\(UUID().uuidString)"
        try await credentialStore.save(Data(password.utf8), reference: reference)
        let descriptor = try IdentityDescriptor(
            name: trimmedName,
            kind: .password,
            publicFingerprint: nil,
            keychainReference: reference
        )
        try await catalog.save(descriptor)
        catalogUpdateToken = UUID()
        await reconcileCatalogIdentities()
        try? await syncSharedCatalogAndTrust()
        return descriptor
    }

    /// Deletes an identity descriptor from the catalog, clears references from
    /// associated hosts, and deletes the underlying Keychain credential only if
    /// no other identity descriptor shares the same Keychain reference.
    public func deleteIdentity(id: UUID) async throws {
        let identities = try await catalog.identities()
        if let target = identities.first(where: { $0.id == id }) {
            let hasOtherReferences = identities.contains {
                $0.id != id && $0.keychainReference == target.keychainReference
            }
            if !hasOtherReferences {
                try? await credentialStore.delete(reference: target.keychainReference)
            }
        }
        try await catalog.deleteIdentity(id: id)
        let hosts = try await catalog.listHosts()
        for host in hosts where host.identityID == id {
            var updated = host
            updated.identityID = nil
            try await catalog.save(updated)
        }
        catalogUpdateToken = UUID()
        await reconcileCatalogIdentities()
        try? await syncSharedCatalogAndTrust()
    }

    public func openSSHPublicKey(for identity: IdentityDescriptor, comment: String? = nil)
        async throws -> String?
    {
        guard identity.kind == .privateKey else { return nil }
        let data = try await credentialStore.load(reference: identity.keychainReference)
        let privateKey = try Ed25519Parser.parse(from: data)
        let effectiveComment =
            (comment?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false)
            ? comment!
            : identity.name
        return Ed25519Parser.openSSHPublicKeyString(
            from: privateKey.publicKey, comment: effectiveComment)
    }

    // MARK: - File Provider Domains

    public func registerFileProviderDomain(for host: Host) async throws {
        if case .mosh = host.connection {
            let err = FileProviderManagerError.unsupportedMoshHost(host.name)
            self.fileProviderDomainError = err.localizedDescription
            throw err
        }
        guard fileProviderHelper.appGroupContainerURL != nil else {
            let err = FileProviderManagerError.containerUnavailable(
                fileProviderHelper.appGroupIdentifier)
            self.fileProviderDomainError = err.localizedDescription
            throw err
        }
        do {
            try await syncSharedCatalogAndTrust()
            try await fileProviderHelper.registerDomain(for: host)
            self.fileProviderDomainError = nil
            await refreshRegisteredDomains()
        } catch {
            self.fileProviderDomainError = error.localizedDescription
            throw error
        }
    }

    public func unregisterFileProviderDomain(for host: Host) async throws {
        do {
            try await fileProviderHelper.unregisterDomain(for: host)
            self.fileProviderDomainError = nil
            await refreshRegisteredDomains()
        } catch {
            self.fileProviderDomainError = error.localizedDescription
            throw error
        }
    }

    public func refreshRegisteredDomains() async {
        #if canImport(FileProvider)
        do {
            let domains = try await fileProviderHelper.registeredDomains()
            self.registeredFileProviderDomainIDs = Set(domains.map(\.identifier.rawValue))
        } catch {
            // Silently ignore if query fails in simulator/unentitled environment
        }
        #endif
    }

    // MARK: - Vault Backup & Sync

    public func exportVaultBackup(passphrase: String) async throws -> Data {
        let snapshot = await catalog.snapshot()
        let service = EncryptedVaultService()
        return try service.exportBackupData(
            catalog: snapshot,
            preferences: VaultPreferences(
                defaultTerminalFont: nil,
                defaultTerminalFontSize: terminalController.terminalFontSize,
                voiceProvider: selectedVoiceProviderID,
                voiceAutoPunctuation: true,
                customSettings: [:],
                appearance: appearance,
                terminalTheme: terminalTheme
            ),
            passphrase: passphrase
        )
    }

    public func previewVaultBackup(data: Data, passphrase: String) throws -> VaultPayload {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        guard let backup = try? decoder.decode(EncryptedVaultBackup.self, from: data) else {
            throw VaultBackupError.corruptedPayload("Invalid backup file format.")
        }
        let service = EncryptedVaultService()
        return try service.restoreBackup(backup: backup, passphrase: passphrase)
    }

    public func restoreCatalog(
        from snapshot: CatalogSnapshot,
        mode: RestoreMode,
        preferences: VaultPreferences? = nil
    ) async throws {
        switch mode {
        case .merge:
            await catalog.merge(with: snapshot)
        case .replace:
            #if canImport(FileProvider)
            let newHostIDs = Set(snapshot.hosts.map(\.id.uuidString))
            let existingHosts = (try? await catalog.listHosts()) ?? []
            let activeDomainIDs: Set<String>
            if let domains = try? await fileProviderHelper.registeredDomains() {
                activeDomainIDs = Set(domains.map(\.identifier.rawValue))
            } else {
                activeDomainIDs = registeredFileProviderDomainIDs
            }

            for host in existingHosts where !newHostIDs.contains(host.id.uuidString) {
                if activeDomainIDs.contains(host.id.uuidString) {
                    try? await fileProviderHelper.unregisterDomain(for: host)
                }
            }
            #endif
            await catalog.replace(with: snapshot)
        }
        try await syncSharedCatalogAndTrust()
        #if canImport(FileProvider)
        await refreshRegisteredDomains()
        #endif
        if let preferences {
            setAppearance(preferences.appearance)
            setTerminalTheme(preferences.terminalTheme)
            if let fontSize = preferences.defaultTerminalFontSize {
                terminalController.setTerminalFontSize(fontSize)
            }
        }
    }

    // MARK: - Server Telemetry

    public func fetchTelemetry(for host: Host) async {
        if isDemo {
            let demo = ServerTelemetry(
                cpuUsagePercentage: 18.5,
                memoryUsedBytes: 1_374_389_534,
                memoryTotalBytes: 4_294_967_296,
                loadAverage: (0.21, 0.15, 0.10),
                uptimeSeconds: 388800
            )
            latestTelemetry[host.id] = demo
            return
        }

        guard activeHost?.id == host.id, let executor = connection as? SSHCommandExecuting else {
            return
        }
        let poller = telemetryPollers[host.id] ?? ServerTelemetryPoller(executor: executor)
        telemetryPollers[host.id] = poller
        if let telemetry = try? await poller.fetchTelemetry() {
            latestTelemetry[host.id] = telemetry
        }
    }

    public func startTelemetryPolling(for host: Host) {
        if isDemo {
            let demo = ServerTelemetry(
                cpuUsagePercentage: 18.5,
                memoryUsedBytes: 1_374_389_534,
                memoryTotalBytes: 4_294_967_296,
                loadAverage: (0.21, 0.15, 0.10),
                uptimeSeconds: 388800
            )
            latestTelemetry[host.id] = demo
            return
        }

        guard activeHost?.id == host.id, let executor = connection as? SSHCommandExecuting else {
            return
        }
        let poller = telemetryPollers[host.id] ?? ServerTelemetryPoller(executor: executor)
        telemetryPollers[host.id] = poller

        poller.startPolling { [weak self] telemetry in
            Task { @MainActor [weak self] in
                self?.latestTelemetry[host.id] = telemetry
            }
        }
    }

    public func stopTelemetryPolling(for host: Host) {
        telemetryPollers[host.id]?.stopPolling()
        telemetryPollers.removeValue(forKey: host.id)
    }
}
