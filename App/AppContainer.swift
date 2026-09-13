import Foundation
#if canImport(FileProvider)
import FileProvider
#endif
import ShhCore
import ShhSSH
import ShhTerminal
import ShhVoice
import SwiftUI

private final class VoiceInterruptionBridge: @unchecked Sendable {
    var onInterruption: (@Sendable () -> Void)?
    func trigger() {
        onInterruption?()
    }
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
    let terminalController: ShhTerminalController
    let restorationStore: any SessionRestorationStore
    let reachabilityMonitor: any ReachabilityMonitoring
    let reconnectCoordinator: ReconnectCoordinator
    private let didProvideCustomCatalog: Bool

    private static var isRunningInTestEnvironment: Bool {
        ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil ||
            ProcessInfo.processInfo.arguments.contains("-XCTest") ||
            NSClassFromString("XCTestCase") != nil
    }

    private var isRunningInTestEnvironment: Bool {
        Self.isRunningInTestEnvironment
    }

    @Published var useLegacyTerminalFallback: Bool
    @Published var activeSession: TerminalSession?
    @Published var terminalText = ""
    @Published var speechState: SpeechComposerState = .idle
    @Published var pendingTrustChallenge: HostKeyChallenge?
    @Published public var lastConnectionFailure: ConnectionFailure?
    @Published public var catalogUpdateToken: UUID = UUID()
    @Published var reconnectState: ReconnectState = .idle
    @Published var tmuxAvailability: TmuxAvailability = .unavailable(reason: "Not connected")
    @Published var tmuxSessions: [TmuxSessionInfo] = []
    @Published var isProbingTmux: Bool = false
    @Published var isTmuxServerRunning: Bool = false
    @Published var tmuxError: String? = nil
    @Published var activeTmuxSessionID: String? = nil

    // MARK: - Herdr Multiplexer & Agent State
    @Published public var herdrAvailability: HerdrAvailability = .unavailable(reason: "Not connected")
    @Published public var herdrWorkspaces: [HerdrWorkspace] = []
    @Published public var isProbingHerdr: Bool = false
    @Published public var isPollingHerdr: Bool = false
    @Published public var herdrError: String? = nil
    @Published public var activeHerdrWorkspaceID: String? = nil
    private var herdrRefreshGeneration: Int = 0
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

    // Previews & Editor
    @Published public var previewFile: RemoteFile? = nil
    @Published public var previewData: Data? = nil
    @Published public var isPreviewLoading: Bool = false
    @Published public var previewErrorMessage: String? = nil

    @Published public var activeEditingFile: RemoteFile? = nil
    @Published public var editingFileContent: String = ""
    @Published public var isSavingFile: Bool = false
    @Published public var editorErrorMessage: String? = nil
    private(set) var activeEditingHostID: Host.ID? = nil
    private var conflictQueue: [FileTransferConflict] = []

    // Directory Cache
    private var directoryCache: [RemotePath: (files: [RemoteFile], timestamp: Date)] = [:]
    private let directoryCacheTTL: TimeInterval = 60.0

    private(set) var activeHost: Host?
    private(set) var isExplicitDisconnect = false
    private var pendingTrustHost: Host?
    private(set) var connection: (any SSHConnection)?
    private var eventTask: Task<Void, Never>?
    private var outboundTask: Task<Void, Never>?
    private var terminalGrid = TerminalGrid()
    private var ansiParser = ANSIParser()
    private(set) var redactor = Redactor()
    private var tmuxRefreshGeneration: Int = 0
    private var voiceTranscriptionGeneration: Int = 0

    var isDemo: Bool {
        transport is DemoSSHTransport
    }

    public static let whisperProviderID = VoiceProviderRegistry.whisperProviderID
    public static let appleSpeechProviderID = VoiceProviderRegistry.appleSpeechProviderID

    public var isWhisperSelected: Bool {
        selectedVoiceProviderID == Self.whisperProviderID
    }

    public var selectedProviderDisplayName: String {
        isWhisperSelected ? "WhisperKit" : "Apple Speech"
    }

    var activeTranscriber: any LocalTranscriber {
        customTranscriber ?? voiceRegistry.activeTranscriber()
    }

    var accessibilityTerminalText: String {
        if useLegacyTerminalFallback {
            return terminalText.isEmpty ? "No terminal output" : terminalText
        }
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
        useLegacyTerminalFallback: Bool = false,
        restorationStore: (any SessionRestorationStore)? = nil,
        reachabilityMonitor: (any ReachabilityMonitoring)? = nil,
        reconnectCoordinator: ReconnectCoordinator? = nil,
        sftpRepository: (any SFTPRepository)? = nil,
        portForwardingManager: (any PortForwardingManaging)? = nil,
        hostResolver: LiveSSHTransport.HostResolver? = nil,
        fileProviderHelper: FileProviderManagerHelper = .shared
    ) {
        self.fileProviderHelper = fileProviderHelper
        self.didProvideCustomCatalog = (catalog != nil)
        let resolvedCredentialStore = credentialStore ?? KeychainCredentialStore(accessGroup: KeychainCredentialStore.defaultSharedAccessGroup)
        let fallbackArg = ProcessInfo.processInfo.arguments.contains("--legacy-terminal") ||
            ProcessInfo.processInfo.environment["SHH_LEGACY_TERMINAL"] == "1"

        let resolvedCatalog: InMemoryCatalog
        if let catalog {
            resolvedCatalog = catalog
        } else if !Self.isRunningInTestEnvironment {
            if let snapshot = fileProviderHelper.loadSharedSnapshot() {
                resolvedCatalog = InMemoryCatalog(snapshot: snapshot)
            } else if fileProviderHelper.hasPersistedSnapshot {
                resolvedCatalog = InMemoryCatalog(seedDemoData: false)
            } else {
                resolvedCatalog = InMemoryCatalog(seedDemoData: false)
            }
        } else {
            resolvedCatalog = InMemoryCatalog(seedDemoData: true)
        }
        self.catalog = resolvedCatalog

        let resolvedTrustStore: InMemoryTrustStore
        if let trustStore {
            resolvedTrustStore = trustStore
        } else if !Self.isRunningInTestEnvironment,
                  let records = fileProviderHelper.loadSharedTrustRecords(),
                  !records.isEmpty {
            resolvedTrustStore = InMemoryTrustStore(records: records)
        } else {
            resolvedTrustStore = InMemoryTrustStore()
        }
        self.trustStore = resolvedTrustStore
        self.credentialStore = resolvedCredentialStore
        let resolvedHostResolver: LiveSSHTransport.HostResolver = hostResolver ?? { [resolvedCatalog] (hostID: UUID) async throws -> (Host, IdentityDescriptor?) in
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
                let placeholder = try Host(name: ident.name, hostname: "localhost", username: "unknown")
                return (placeholder, ident)
            }
            throw TransportError.invalidConfiguration
        }
        let resolvedTransport = transport ?? LiveSSHTransport(
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
        self.useLegacyTerminalFallback = useLegacyTerminalFallback || fallbackArg
        self.terminalController = ShhTerminalController()
        self.restorationStore = restorationStore ?? UserDefaultsSessionRestorationStore()
        let monitor = reachabilityMonitor ?? NetworkPathReachabilityMonitor()
        self.reachabilityMonitor = monitor
        let coordinator = reconnectCoordinator ?? ReconnectCoordinator()
        self.reconnectCoordinator = coordinator

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
            self.startForwardingMonitoring(manager: portForwardingManager)
        } else if self.transport is DemoSSHTransport {
            let demoPF = DemoPortForwardingManager()
            self.portForwardingManager = demoPF
            self.startForwardingMonitoring(manager: demoPF)
        } else {
            self.portForwardingManager = nil
        }

        bridge.onInterruption = { [weak self] in
            Task { @MainActor [weak self] in
                await self?.cancelVoiceRecording()
            }
        }

        Task { [weak self] in
            await coordinator.setStateChangeHandler { [weak self] newState in
                Task { @MainActor [weak self] in
                    self?.reconnectState = newState
                }
            }
        }

        monitor.onReachabilityChange = { [weak self] reachable in
            Task { @MainActor [weak self] in
                self?.handleReachabilityChange(reachable)
            }
        }
        monitor.onInterfaceChange = { [weak self] newInterface, roamingState in
            Task { @MainActor [weak self] in
                await self?.handleNetworkInterfaceChange(newInterface, roamingState: roamingState)
            }
        }
        monitor.start()

        Task { [weak self] in
            await self?.refreshVoiceModels()
        }

        Task { [weak self] in
            await self?.loadDirectory(at: RemotePath("/home/dev"))
        }

        Task { [weak self] in
            await self?.loadSharedStateIfNeeded()
            try? await self?.syncSharedCatalogAndTrust()
            #if canImport(FileProvider)
            await self?.refreshRegisteredDomains()
            #endif
        }
    }

    func loadSharedStateIfNeeded() async {
        guard !didProvideCustomCatalog else { return }
        guard !isRunningInTestEnvironment || fileProviderHelper.customContainerURL != nil else { return }
        if let snapshot = fileProviderHelper.loadSharedSnapshot() {
            await catalog.replace(with: snapshot)
            catalogUpdateToken = UUID()
        }
        if let records = fileProviderHelper.loadSharedTrustRecords(), !records.isEmpty {
            await trustStore.addRecords(records)
        }
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
        useLegacyTerminalFallback: Bool = false,
        restorationStore: (any SessionRestorationStore)? = nil,
        reachabilityMonitor: (any ReachabilityMonitoring)? = nil,
        reconnectCoordinator: ReconnectCoordinator? = nil,
        sftpRepository: (any SFTPRepository)? = nil,
        portForwardingManager: (any PortForwardingManaging)? = nil,
        fileProviderHelper: FileProviderManagerHelper = .shared
    ) -> AppContainer {
        let demoRecorder = voiceRecorder ?? DemoAudioRecorder()
        let demoTranscriber = transcriber ?? DemoTranscriber()
        let demoModelsDir = FileManager.default.temporaryDirectory.appendingPathComponent("ShhDemoModels_\(UUID().uuidString)")
        let demoManager = modelManager ?? WhisperModelManager(
            modelsDirectory: demoModelsDir,
            downloader: DemoWhisperDownloader()
        )
        let demoRegistry = voiceRegistry ?? VoiceProviderRegistry(
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
            useLegacyTerminalFallback: useLegacyTerminalFallback,
            restorationStore: restorationStore ?? InMemorySessionRestorationStore(),
            reachabilityMonitor: reachabilityMonitor ?? MockReachabilityMonitor(isReachable: true),
            reconnectCoordinator: reconnectCoordinator ?? ReconnectCoordinator(
                clock: { _ in },
                jitter: ReconnectCoordinator.zeroJitter
            ),
            sftpRepository: sftpRepository ?? DemoSFTPRepository(seedDemoData: true),
            portForwardingManager: portForwardingManager ?? DemoPortForwardingManager(),
            fileProviderHelper: fileProviderHelper
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

    func connect(to host: Host, restoringTmuxSessionID: String? = nil) async {
        guard activeSession?.state != .connecting else { return }
        lastConnectionFailure = nil
        await cancelVoiceRecording()
        resetVoiceState()
        tmuxRefreshGeneration += 1
        herdrRefreshGeneration += 1
        stopHerdrPolling()
        herdrWorkspaces = []
        isProbingHerdr = false
        herdrAvailability = .unavailable(reason: "Not connected")
        herdrError = nil
        isExplicitDisconnect = false
        activeHost = host
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
        eventTask?.cancel()
        detachCallbacks()
        await connection?.close()
        connection = nil
        pendingTrustChallenge = nil
        pendingTrustHost = nil
        terminalGrid = TerminalGrid()
        ansiParser = ANSIParser()
        terminalText = ""
        redactor = Redactor()
        terminalController.reset()

        // Reset previous SFTP session, editor, preview, and transfers on connecting to new host
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

        // Reset port forwarding state
        forwardingStreamTask?.cancel()
        forwardingStreamTask = nil
        await portForwardingManager?.stopAll()
        if !isDemo {
            portForwardingManager = nil
        }
        forwardingSessions = []
        forwardingErrorMessage = nil

        let session = TerminalSession(hostID: host.id, state: .connecting, capabilities: ["ansi", "resize"])
        activeSession = session
        let initialSize = terminalController.size
        do {
            let connection: any SSHConnection
            if case .mosh = host.connection {
                connection = try await moshTransport.connect(
                    host: host,
                    identity: await identity(for: host),
                    trustEvaluator: trustStore,
                    initialSize: initialSize
                )
            } else {
                connection = try await transport.connect(
                    host: host,
                    identity: await identity(for: host),
                    trustEvaluator: trustStore,
                    initialSize: initialSize
                )
            }
            guard activeSession?.id == session.id, activeSession?.state == .connecting else {
                await connection.close()
                return
            }
            if let moshController = connection as? any MoshSessionControlling {
                let info = await moshController.sessionInfo
                self.moshSessionInfo = info
                let st = await moshController.moshState
                self.moshState = st
                let roaming = await moshController.roamingState
                self.networkRoamingState = roaming
                startMoshMonitoring(for: moshController, session: session)
            }
            // Host key is accepted and connection succeeded; load redaction secret if available
            await loadRedactionSecret(for: host)
            self.connection = connection
            (connection as? LiveSSHConnection)?.setRedactor(redactor)
            activeSession?.state = .connected

            let targetSession = await automaticTmuxTarget(
                for: host,
                explicitTarget: restoringTmuxSessionID
            )
            if let targetSession {
                let metadata = SessionRestorationMetadata(
                    hostID: host.id,
                    sessionID: session.id,
                    tmuxSessionID: targetSession
                )
                try? await restorationStore.save(metadata)
            }

            // Wire debounced resize callback to active connection
            terminalController.onResize = { [weak self, sessionID = session.id] newSize in
                Task { @MainActor [weak self] in
                    guard let self,
                          self.activeSession?.id == sessionID,
                          self.activeSession?.state == .connected,
                          let activeConnection = self.connection else { return }
                    try? await activeConnection.resize(newSize)
                }
            }

            // Wire interactive terminal output to raw outbound path
            terminalController.onOutput = { [weak self, sessionID = session.id] data in
                guard let self,
                      self.activeSession?.id == sessionID,
                      self.activeSession?.state == .connected else { return }
                self.enqueueRawInteractive(data, sessionID: sessionID)
            }

            // Auto-attach tmux session if requested by host preferences or restored
            if let target = targetSession {
                await self.handleTmuxTarget(target, on: connection, host: host, session: session)
            }

            let events = await connection.events()
            startEventMonitoring(for: connection, events: events, session: session, host: host)

            // Wire port forwarding manager and auto-start enabled rules
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
            self.portForwardingManager = pfManager
            self.startForwardingMonitoring(manager: pfManager)
            await self.autoStartForwardingRules(for: host, manager: pfManager)

            Task { [weak self] in
                await self?.refreshTmuxState()
            }
            Task { [weak self] in
                await self?.setupSFTPForHost(host)
            }
        } catch let error as TransportError {
            guard activeSession?.id == session.id, activeSession?.state == .connecting else { return }
            detachCallbacks()
            let failure = ConnectionFailure.from(error: error, host: host)
            self.lastConnectionFailure = failure
            let message = Self.statusMessage(for: error)
            terminalText = message
            if !useLegacyTerminalFallback {
                terminalController.feed("\r\n\u{1b}[31m[" + message + "]\u{1b}[0m\r\n")
            }
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
        } catch {
            guard activeSession?.id == session.id, activeSession?.state == .connecting else { return }
            detachCallbacks()
            let failure = ConnectionFailure.from(error: error, host: host)
            self.lastConnectionFailure = failure
            let message = failure.reason
            activeSession?.state = .failed
            terminalText = message
            if !useLegacyTerminalFallback {
                terminalController.feed("\r\n\u{1b}[31m[" + message + "]\u{1b}[0m\r\n")
            }
        }
    }

    private func startEventMonitoring(
        for connection: any SSHConnection,
        events: AsyncThrowingStream<TerminalEvent, Error>,
        session: TerminalSession,
        host: Host
    ) {
        eventTask?.cancel()
        eventTask = Task { @MainActor [weak self] in
            do {
                for try await event in events {
                    guard let self, self.activeSession?.id == session.id else { return }
                    switch event {
                    case .bytes(let data):
                        let redactedData = self.redacted(data)
                        if self.useLegacyTerminalFallback {
                            self.ansiParser.consume(redactedData, into: &self.terminalGrid)
                            self.terminalText = self.terminalGrid.transcriptText
                        } else {
                            self.terminalController.feed(redactedData)
                        }
                    case .closed:
                        self.tmuxRefreshGeneration += 1
                        self.herdrRefreshGeneration += 1
                        self.stopHerdrPolling()
                        self.isProbingTmux = false
                        self.isProbingHerdr = false
                        self.activeSession?.state = .disconnected
                        self.detachCallbacks()
                        if !self.useLegacyTerminalFallback {
                            self.terminalController.feed("\r\n\u{1b}[90m[Connection closed]\u{1b}[0m\r\n")
                        }
                        self.redactor = Redactor()
                        self.forwardingStreamTask?.cancel()
                        self.forwardingStreamTask = nil
                        await self.portForwardingManager?.stopAll()
                        self.forwardingSessions = []
                        self.handleConnectionDrop(host: host)
                    case .error(let error):
                        self.tmuxRefreshGeneration += 1
                        self.herdrRefreshGeneration += 1
                        self.stopHerdrPolling()
                        self.isProbingTmux = false
                        self.isProbingHerdr = false
                        self.activeSession?.state = .failed
                        self.detachCallbacks()
                        let message = Self.statusMessage(for: error)
                        self.terminalText += "\n" + message
                        if !self.useLegacyTerminalFallback {
                            self.terminalController.feed("\r\n\u{1b}[31m[" + message + "]\u{1b}[0m\r\n")
                        }
                        self.redactor = Redactor()
                        self.forwardingStreamTask?.cancel()
                        self.forwardingStreamTask = nil
                        await self.portForwardingManager?.stopAll()
                        self.forwardingSessions = []
                        self.handleConnectionDrop(host: host)
                    }
                }
            } catch {
                guard let self, self.activeSession?.id == session.id else { return }
                self.tmuxRefreshGeneration += 1
                self.herdrRefreshGeneration += 1
                self.stopHerdrPolling()
                self.isProbingTmux = false
                self.isProbingHerdr = false
                self.activeSession?.state = .failed
                self.detachCallbacks()
                let message = Self.statusMessage(for: error)
                self.terminalText += "\n" + message
                if !self.useLegacyTerminalFallback {
                    self.terminalController.feed("\r\n\u{1b}[31m[" + message + "]\u{1b}[0m\r\n")
                }
                self.redactor = Redactor()
                self.forwardingStreamTask?.cancel()
                self.forwardingStreamTask = nil
                await self.portForwardingManager?.stopAll()
                self.forwardingSessions = []
                self.handleConnectionDrop(host: host)
            }
        }
    }

    private func handleConnectionDrop(host: Host) {
        guard !isExplicitDisconnect else { return }
        Task { [weak self] in
            guard let self else { return }
            await self.reconnectCoordinator.start { [weak self] attempt in
                guard let self else { return }
                try await self.performReconnect(to: host, attempt: attempt)
            }
        }
    }

    func performReconnect(to host: Host, attempt: Int) async throws {
        guard !isExplicitDisconnect else {
            throw TransportError.cancelled
        }
        guard reachabilityMonitor.isReachable else {
            throw TransportError.networkUnavailable
        }
        tmuxRefreshGeneration += 1
        herdrRefreshGeneration += 1
        stopHerdrPolling()
        isProbingTmux = false
        isProbingHerdr = false

        // Cleanly reset terminal emulator buffer and parser to avoid stream corruption
        terminalGrid = TerminalGrid()
        ansiParser = ANSIParser()
        terminalText = ""
        redactor = Redactor()
        terminalController.reset()

        let session = TerminalSession(hostID: host.id, state: .connecting, capabilities: ["ansi", "resize"])
        activeSession = session

        let initialSize = terminalController.size
        let connection: any SSHConnection
        if case .mosh = host.connection {
            connection = try await moshTransport.connect(
                host: host,
                identity: await identity(for: host),
                trustEvaluator: trustStore,
                initialSize: initialSize
            )
        } else {
            connection = try await transport.connect(
                host: host,
                identity: await identity(for: host),
                trustEvaluator: trustStore,
                initialSize: initialSize
            )
        }

        guard activeSession?.id == session.id, !isExplicitDisconnect else {
            await connection.close()
            throw TransportError.cancelled
        }

        if let moshController = connection as? any MoshSessionControlling {
            let info = await moshController.sessionInfo
            self.moshSessionInfo = info
            let st = await moshController.moshState
            self.moshState = st
            let roaming = await moshController.roamingState
            self.networkRoamingState = roaming
            startMoshMonitoring(for: moshController, session: session)
        }

        await loadRedactionSecret(for: host)
        self.connection = connection
        (connection as? LiveSSHConnection)?.setRedactor(redactor)
        activeSession?.state = .connected

        terminalController.onResize = { [weak self, sessionID = session.id] newSize in
            Task { @MainActor [weak self] in
                guard let self,
                      self.activeSession?.id == sessionID,
                      self.activeSession?.state == .connected,
                      let activeConnection = self.connection else { return }
                try? await activeConnection.resize(newSize)
            }
        }

        terminalController.onOutput = { [weak self, sessionID = session.id] data in
            guard let self,
                  self.activeSession?.id == sessionID,
                  self.activeSession?.state == .connected else { return }
            self.enqueueRawInteractive(data, sessionID: sessionID)
        }

        let targetSession = await automaticTmuxTarget(
            for: host,
            explicitTarget: activeTmuxSessionID
        )
        if let target = targetSession {
            let metadata = SessionRestorationMetadata(
                hostID: host.id,
                sessionID: session.id,
                tmuxSessionID: target
            )
            try? await restorationStore.save(metadata)
            await self.handleTmuxTarget(target, on: connection, host: host, session: session)
        }

        if herdrAvailability.isAvailable || activeHerdrWorkspaceID != nil {
            await refreshHerdrState()
        }

        let events = await connection.events()
        startEventMonitoring(for: connection, events: events, session: session, host: host)

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
        self.portForwardingManager = pfManager
        self.startForwardingMonitoring(manager: pfManager)
        await self.autoStartForwardingRules(for: host, manager: pfManager)

        Task { [weak self] in
            await self?.refreshTmuxState()
            await self?.setupSFTPForHost(host)
        }
    }

    func cancelReconnect() async {
        isExplicitDisconnect = true
        tmuxRefreshGeneration += 1
        herdrRefreshGeneration += 1
        stopHerdrPolling()
        isProbingTmux = false
        isProbingHerdr = false
        await reconnectCoordinator.cancel()
        reconnectState = .cancelled
        moshStateTask?.cancel()
        moshStateTask = nil
        moshState = nil
        moshSessionInfo?.zeroize()
        moshSessionInfo = nil
        networkRoamingState = nil
        await connection?.close()
        connection = nil
    }

    func retryReconnect() async {
        guard let host = activeHost else { return }
        isExplicitDisconnect = false
        await reconnectCoordinator.start { [weak self] attempt in
            guard let self else { return }
            try await self.performReconnect(to: host, attempt: attempt)
        }
    }

    func handleReachabilityChange(_ isReachable: Bool) {
        guard !isExplicitDisconnect else { return }
        if isReachable {
            if reconnectState.isReconnecting {
                Task { [weak self] in
                    guard let self, let host = self.activeHost else { return }
                    await self.reconnectCoordinator.retryNow { [weak self] attempt in
                        guard let self else { return }
                        try await self.performReconnect(to: host, attempt: attempt)
                    }
                }
            } else if let host = activeHost, (activeSession?.state == .failed || activeSession?.state == .disconnected) {
                handleConnectionDrop(host: host)
            } else if let host = activeHost, case .mosh = host.connection {
                Task { [weak self] in
                    await self?.performFastSessionRecovery()
                }
            }
        }
    }

    // MARK: - Mosh Network Roaming & Fast Session Recovery

    private func startMoshMonitoring(for controller: any MoshSessionControlling, session: TerminalSession) {
        moshStateTask?.cancel()
        moshStateTask = Task { @MainActor [weak self] in
            let updates = await controller.moshStateUpdates()
            for await state in updates {
                guard let self, self.activeSession?.id == session.id else { break }
                self.moshState = state
                if case .roaming(let roaming) = state {
                    self.networkRoamingState = roaming
                }
            }
        }
    }

    func handleNetworkInterfaceChange(_ newInterface: NetworkInterfaceType, roamingState: NetworkRoamingState) async {
        guard !isExplicitDisconnect else { return }
        self.networkRoamingState = roamingState

        if let moshController = connection as? any MoshSessionControlling {
            do {
                try await moshController.handleNetworkRoaming(roamingState)
                self.moshState = await moshController.moshState
            } catch {
                await performFastSessionRecovery()
            }
        }
    }

    func performFastSessionRecovery() async {
        guard let host = activeHost, !isExplicitDisconnect else { return }

        if reachabilityMonitor.isReachable, let moshController = connection as? any MoshSessionControlling {
            let roaming = networkRoamingState ?? NetworkRoamingState(currentInterface: reachabilityMonitor.currentInterfaceType)
            do {
                try await moshController.handleNetworkRoaming(roaming)
                self.moshState = await moshController.moshState
                return
            } catch {
                // In-place recovery probe failed; fall back to reconnect coordinator
            }
        }

        await reconnectCoordinator.start { [weak self] attempt in
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
        guard !isExplicitDisconnect else { return }
        switch phase {
        case .active:
            if reconnectState.isReconnecting {
                Task { [weak self] in
                    guard let self, let host = self.activeHost else { return }
                    await self.reconnectCoordinator.retryNow { [weak self] attempt in
                        guard let self else { return }
                        try await self.performReconnect(to: host, attempt: attempt)
                    }
                }
            } else if let host = activeHost, (activeSession?.state == .failed || activeSession?.state == .disconnected) {
                handleConnectionDrop(host: host)
            }
        case .background:
            if let session = activeSession, let host = activeHost, session.state == .connected {
                if let target = activeTmuxSessionID {
                    let metadata = SessionRestorationMetadata(
                        hostID: host.id,
                        sessionID: session.id,
                        tmuxSessionID: target
                    )
                    Task { [weak self] in
                        try? await self?.restorationStore.save(metadata)
                    }
                }
            }
        default:
            break
        }
    }

    func restoreLastSession() async {
        guard let metadata = try? await restorationStore.load(),
              let hosts = try? await catalog.listHosts(),
              let host = hosts.first(where: { $0.id == metadata.hostID }) else {
            return
        }
        await connect(to: host, restoringTmuxSessionID: metadata.tmuxSessionID)
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
        pendingTrustHost = nil
        lastConnectionFailure = nil
        lastSFTPFailure = nil
        sftpErrorMessage = nil
        await connect(to: host)
    }

    func rejectPendingHostKey() {
        pendingTrustChallenge = nil
        pendingTrustHost = nil
        activeSession?.state = .disconnected
        redactor = Redactor()
    }

    @discardableResult
    func sendRawInteractive(_ data: Data) async -> Bool {
        guard activeSession?.state == .connected,
              let connection else { return false }
        do {
            try await connection.send(data)
            return true
        } catch {
            return false
        }
    }

    @discardableResult
    func sendValidatedCommand(_ command: String, approved: Bool = false) async -> Bool {
        guard CommandPolicy().canSend(command, approved: approved),
              activeSession?.state == .connected,
              let connection else { return false }
        do {
            try await connection.send(Data(command.utf8))
            return true
        } catch {
            let message = "Send failed: \(error.localizedDescription)"
            terminalText += "\n" + message
            if !useLegacyTerminalFallback {
                terminalController.feed("\r\n\u{1b}[31m[" + message + "]\u{1b}[0m\r\n")
            }
            return false
        }
    }

    @discardableResult
    func send(_ command: String, approved: Bool = false) async -> Bool {
        await sendValidatedCommand(command, approved: approved)
    }

    func disconnect() async {
        await cancelVoiceRecording()
        resetVoiceState()
        isExplicitDisconnect = true
        tmuxRefreshGeneration += 1
        activeHost = nil
        await reconnectCoordinator.cancel()
        reconnectState = .idle
        try? await restorationStore.clear()
        detachCallbacks()
        eventTask?.cancel()
        eventTask = nil

        // Reset port forwarding state before closing SSH connection
        forwardingStreamTask?.cancel()
        forwardingStreamTask = nil
        await portForwardingManager?.stopAll()
        if !isDemo {
            portForwardingManager = nil
        }
        forwardingSessions = []
        forwardingErrorMessage = nil

        await connection?.close()
        connection = nil
        activeSession?.state = .disconnected
        redactor = Redactor()
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

        moshStateTask?.cancel()
        moshStateTask = nil
        moshState = nil
        moshSessionInfo?.zeroize()
        moshSessionInfo = nil
        networkRoamingState = nil

        // Reset SFTP session, preview, editor, and transfer state
        closePreview()
        closeEditor()
        currentDirectoryFiles = []
        currentPath = RemotePath("/home/dev")
        directoryErrorMessage = nil
        sftpErrorMessage = nil
        lastSFTPFailure = nil
        sftpSetupGeneration += 1

        for (_, task) in activeTransferTasks {
            task.cancel()
        }
        activeTransferTasks.removeAll()

        drainPendingConflicts()

        if customSFTPRepository == nil {
            if let live = sftpRepository as? LiveSFTPRepository {
                await live.close()
            }
            if !isDemo {
                sftpRepository = nil
            }
        }
        directoryCache.removeAll()
        cleanTemporaryTransfersDirectory(removeAll: true)
    }

    private func detachCallbacks() {
        terminalController.onResize = nil
        terminalController.onOutput = nil
        outboundTask?.cancel()
        outboundTask = nil
    }

    private func enqueueRawInteractive(_ data: Data, sessionID: UUID) {
        let previousTask = outboundTask
        outboundTask = Task { @MainActor [weak self] in
            _ = await previousTask?.value
            guard let self,
                  self.activeSession?.id == sessionID,
                  self.activeSession?.state == .connected else { return }
            _ = await self.sendRawInteractive(data)
        }
    }

    private func identity(for host: Host) async -> IdentityDescriptor? {
        guard let identityID = host.identityID,
              let identities = try? await catalog.identities() else { return nil }
        return identities.first(where: { $0.id == identityID })
    }

    private func loadRedactionSecret(for host: Host) async {
        redactor = Redactor()
        var secrets: [String] = []
        let identities = (try? await catalog.identities()) ?? []
        if let identityID = host.identityID,
           let identity = identities.first(where: { $0.id == identityID }),
           let secret = try? await credentialStore.load(reference: identity.keychainReference),
           let value = String(data: secret, encoding: .utf8), !value.isEmpty {
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
                   let secret = try? await credentialStore.load(reference: ident.keychainReference),
                   let value = String(data: secret, encoding: .utf8), !value.isEmpty {
                    secrets.append(value)
                }
            }
        }
        if let moshController = connection as? any MoshSessionControlling {
            let key = await moshController.sessionInfo.sessionKey.base64String
            if !key.isEmpty {
                secrets.append(key)
            }
        } else if let sessionInfo = self.moshSessionInfo {
            let key = sessionInfo.sessionKey.base64String
            if !key.isEmpty {
                secrets.append(key)
            }
        }
        if !secrets.isEmpty {
            redactor = Redactor(secrets: secrets)
        }
    }

    internal func redacted(_ data: Data) -> Data {
        guard !redactor.secrets.isEmpty else { return data }
        return Data(redactor.redact(String(decoding: data, as: UTF8.self)).utf8)
    }

    // MARK: - Live Tmux Management

    func isTmuxSessionActive(_ session: TmuxSessionInfo) -> Bool {
        guard let activeID = activeTmuxSessionID else { return false }
        return activeID == session.sessionID || activeID == session.name
    }

    func updateActiveHostPreferences(autoAttachTmux: Bool, defaultTmuxSession: String? = nil) async throws {
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

    private func automaticTmuxTarget(for host: Host, explicitTarget: String?) async -> String? {
        if let explicitTarget {
            let trimmed = explicitTarget.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed.isEmpty ? nil : trimmed
        }
        guard host.autoAttachTmux,
              let metadata = try? await restorationStore.load(),
              metadata?.hostID == host.id,
              let target = metadata?.tmuxSessionID?.trimmingCharacters(in: .whitespacesAndNewlines),
              !target.isEmpty else {
            return nil
        }
        return target
    }

    private func handleTmuxTarget(_ target: String, on connection: any SSHConnection, host: Host, session: TerminalSession) async {
        let trimmed = target.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.hasPrefix("$") {
            if let executor = connection as? SSHCommandExecuting {
                do {
                    let check = try await executor.executeCommand(TmuxCommand.hasSession(id: trimmed), timeout: 5.0)
                    guard activeSession?.id == session.id,
                          activeSession?.state == .connected,
                          !isExplicitDisconnect,
                          (self.connection as AnyObject) === (connection as AnyObject) else {
                        return
                    }
                    if !check.isSuccess {
                        self.activeTmuxSessionID = nil
                        let metadata = SessionRestorationMetadata(
                            hostID: host.id,
                            sessionID: session.id,
                            tmuxSessionID: nil
                        )
                        try? await restorationStore.save(metadata)
                        self.tmuxError = "Remembered tmux session \(trimmed) no longer exists on remote host."
                        return
                    }
                } catch {
                    guard activeSession?.id == session.id,
                          activeSession?.state == .connected,
                          !isExplicitDisconnect,
                          (self.connection as AnyObject) === (connection as AnyObject) else {
                        return
                    }
                    self.activeTmuxSessionID = nil
                    let metadata = SessionRestorationMetadata(
                        hostID: host.id,
                        sessionID: session.id,
                        tmuxSessionID: nil
                    )
                    try? await restorationStore.save(metadata)
                    self.tmuxError = "Failed to verify tmux session \(trimmed): \(error.localizedDescription)"
                    return
                }
            }
            guard activeSession?.id == session.id,
                  activeSession?.state == .connected,
                  !isExplicitDisconnect,
                  (self.connection as AnyObject) === (connection as AnyObject) else {
                return
            }
            _ = await attachTmuxSession(id: trimmed)
        } else if !trimmed.isEmpty {
            // A remembered name may be attached only if it already exists. Never
            // create a session during restoration.
            guard let executor = connection as? SSHCommandExecuting else { return }
            let result = try? await executor.executeCommand(TmuxCommand.listSessions, timeout: 5.0)
            guard activeSession?.id == session.id,
                  activeSession?.state == .connected,
                  !isExplicitDisconnect,
                  (self.connection as AnyObject) === (connection as AnyObject),
                  let result,
                  result.isSuccess else {
                return
            }
            guard let match = try? TmuxListSessionsParser.parse(result.stdout).first(where: { $0.name == trimmed }) else {
                activeTmuxSessionID = nil
                tmuxError = "Remembered tmux session \(trimmed) no longer exists on remote host."
                let metadata = SessionRestorationMetadata(
                    hostID: host.id,
                    sessionID: session.id,
                    tmuxSessionID: nil
                )
                try? await restorationStore.save(metadata)
                return
            }
            _ = await attachTmuxSession(id: match.sessionID)
        }
    }

    @discardableResult
    func probeTmux() async -> TmuxAvailability {
        if connection is any MoshSessionControlling {
            return tmuxAvailability
        }
        guard let currentSession = activeSession, currentSession.state == .connected,
              let executor = connection as? SSHCommandExecuting else {
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
                  (connection as AnyObject) === connObj else {
                return .unavailable(reason: "Session disconnected")
            }
            let avail = TmuxAvailability.parse(result: result)
            tmuxAvailability = avail
            return avail
        } catch {
            guard activeSession?.id == sessionID,
                  activeSession?.state == .connected,
                  !isExplicitDisconnect,
                  (connection as AnyObject) === connObj else {
                return .unavailable(reason: "Session disconnected")
            }
            let avail = TmuxAvailability.unavailable(reason: error.localizedDescription)
            tmuxAvailability = avail
            return avail
        }
    }

    @discardableResult
    func listTmuxSessions() async -> [TmuxSessionInfo] {
        guard let currentSession = activeSession, currentSession.state == .connected,
              let executor = connection as? SSHCommandExecuting else {
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
                  (connection as AnyObject) === connObj else {
                return []
            }
            if result.isSuccess {
                do {
                    let parsed = try TmuxListSessionsParser.parse(result.stdout)
                    tmuxSessions = parsed
                    isTmuxServerRunning = true
                    tmuxError = nil

                    if let active = activeTmuxSessionID {
                        if let matched = parsed.first(where: { $0.sessionID == active || $0.name == active }) {
                            if active != matched.sessionID {
                                activeTmuxSessionID = matched.sessionID
                                if let host = activeHost {
                                    let metadata = SessionRestorationMetadata(
                                        hostID: host.id,
                                        sessionID: sessionID,
                                        tmuxSessionID: matched.sessionID
                                    )
                                    try? await restorationStore.save(metadata)
                                }
                            }
                        } else {
                            activeTmuxSessionID = nil
                            if let host = activeHost {
                                let metadata = SessionRestorationMetadata(
                                    hostID: host.id,
                                    sessionID: sessionID,
                                    tmuxSessionID: nil
                                )
                                try? await restorationStore.save(metadata)
                            }
                        }
                    }

                    return parsed
                } catch {
                    tmuxSessions = []
                    isTmuxServerRunning = true
                    let parseMessage: String
                    if let parseError = error as? TmuxParseError {
                        parseMessage = "Failed to parse tmux sessions due to format incompatibility. Refresh sessions or check remote tmux version. (\(parseError.localizedDescription))"
                    } else {
                        parseMessage = "Failed to parse tmux sessions due to format incompatibility. Refresh sessions or check remote tmux version."
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
                        if let host = activeHost {
                            let metadata = SessionRestorationMetadata(
                                hostID: host.id,
                                sessionID: sessionID,
                                tmuxSessionID: nil
                            )
                            try? await restorationStore.save(metadata)
                        }
                    }
                } else if combinedErr.contains("no sessions") {
                    tmuxSessions = []
                    isTmuxServerRunning = true
                    tmuxError = nil
                    if activeTmuxSessionID != nil {
                        activeTmuxSessionID = nil
                        if let host = activeHost {
                            let metadata = SessionRestorationMetadata(
                                hostID: host.id,
                                sessionID: sessionID,
                                tmuxSessionID: nil
                            )
                            try? await restorationStore.save(metadata)
                        }
                    }
                } else {
                    tmuxSessions = []
                    isTmuxServerRunning = false
                    let msg = result.stderr.trimmingCharacters(in: .whitespacesAndNewlines)
                    tmuxError = msg.isEmpty ? "Failed to list tmux sessions (exit code \(result.exitCode))" : msg
                }
                return []
            }
        } catch {
            guard activeSession?.id == sessionID,
                  activeSession?.state == .connected,
                  !isExplicitDisconnect,
                  (connection as AnyObject) === connObj else {
                return []
            }
            tmuxSessions = []
            isTmuxServerRunning = false
            tmuxError = error.localizedDescription
            return []
        }
    }

    func refreshTmuxState() async {
        if connection is any MoshSessionControlling {
            return
        }
        guard let currentSession = activeSession, currentSession.state == .connected,
              let currentConnection = connection, currentConnection is SSHCommandExecuting else {
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
              (connection as AnyObject) === connObj else {
            return
        }

        if availability.isAvailable {
            _ = await listTmuxSessions()
            guard tmuxRefreshGeneration == generation,
                  activeSession?.id == sessionID,
                  activeSession?.state == .connected,
                  !isExplicitDisconnect,
                  (connection as AnyObject) === connObj else {
                return
            }
        } else {
            tmuxSessions = []
            isTmuxServerRunning = false
            if activeTmuxSessionID != nil {
                activeTmuxSessionID = nil
                if let host = activeHost {
                    let metadata = SessionRestorationMetadata(
                        hostID: host.id,
                        sessionID: sessionID,
                        tmuxSessionID: nil
                    )
                    try? await restorationStore.save(metadata)
                }
            }
        }
    }

    @discardableResult
    func attachTmuxSession(id: String) async -> Bool {
        guard activeSession?.state == .connected, let conn = connection else {
            tmuxError = "Not connected."
            return false
        }
        let sessionID = activeSession?.id
        let connObj = conn as AnyObject
        let validatedID: TmuxSessionID
        do {
            validatedID = try TmuxSessionID(id)
        } catch {
            tmuxError = error.localizedDescription
            return false
        }

        let cmd = TmuxCommand.attachSession(id: validatedID)
        guard CommandPolicy().canSend(cmd, approved: true) else {
            tmuxError = "Safety policy rejected command."
            return false
        }

        let sent = await sendValidatedCommand(cmd + "\n", approved: true)
        guard activeSession?.id == sessionID,
              activeSession?.state == .connected,
              !isExplicitDisconnect,
              (connection as AnyObject) === connObj else {
            return false
        }
        if sent {
            tmuxRefreshGeneration += 1
            activeTmuxSessionID = validatedID.value
            tmuxError = nil
            if let host = activeHost, let session = activeSession {
                let metadata = SessionRestorationMetadata(
                    hostID: host.id,
                    sessionID: session.id,
                    tmuxSessionID: validatedID.value
                )
                try? await restorationStore.save(metadata)
            }
            return true
        } else {
            tmuxError = "Failed to attach to tmux session \(validatedID.value)."
            return false
        }
    }

    @discardableResult
    func createTmuxSession(name: String) async -> Bool {
        guard activeSession?.state == .connected, let conn = connection else {
            tmuxError = "Not connected."
            return false
        }
        let sessionID = activeSession?.id
        let connObj = conn as AnyObject
        let validatedName: TmuxSessionName
        do {
            validatedName = try TmuxSessionName(name)
        } catch {
            tmuxError = error.localizedDescription
            return false
        }

        let cmd = TmuxCommand.newSession(name: validatedName)
        guard CommandPolicy().canSend(cmd, approved: true) else {
            tmuxError = "Safety policy rejected command."
            return false
        }

        let sent = await sendValidatedCommand(cmd + "\n", approved: true)
        guard activeSession?.id == sessionID,
              activeSession?.state == .connected,
              !isExplicitDisconnect,
              (connection as AnyObject) === connObj else {
            return false
        }
        if sent {
            tmuxRefreshGeneration += 1
            activeTmuxSessionID = validatedName.value
            tmuxError = nil
            if let host = activeHost, let session = activeSession {
                let metadata = SessionRestorationMetadata(
                    hostID: host.id,
                    sessionID: session.id,
                    tmuxSessionID: validatedName.value
                )
                try? await restorationStore.save(metadata)
            }
            return true
        } else {
            tmuxError = "Failed to create tmux session \(validatedName.value)."
            return false
        }
    }

    // MARK: - Live Herdr Workspace & Agent Management

    @discardableResult
    func probeHerdr() async -> HerdrAvailability {
        guard let currentSession = activeSession, currentSession.state == .connected,
              let executor = connection as? SSHCommandExecuting else {
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
                  (connection as AnyObject) === connObj else {
                return .unavailable(reason: "Session disconnected")
            }
            let avail = HerdrAvailability.parse(result: result)
            herdrAvailability = avail
            return avail
        } catch {
            guard activeSession?.id == sessionID,
                  activeSession?.state == .connected,
                  !isExplicitDisconnect,
                  (connection as AnyObject) === connObj else {
                return .unavailable(reason: "Session disconnected")
            }
            let avail = HerdrAvailability.unavailable(reason: error.localizedDescription)
            herdrAvailability = avail
            return avail
        }
    }

    @discardableResult
    func listHerdrWorkspaces() async -> [HerdrWorkspace] {
        guard let currentSession = activeSession, currentSession.state == .connected,
              let executor = connection as? SSHCommandExecuting else {
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
                  (connection as AnyObject) === connObj else {
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
                herdrError = !err.isEmpty ? err : (!out.isEmpty ? out : "Failed to list Herdr workspaces (exit code \(result.exitCode))")
                return []
            }
        } catch {
            guard activeSession?.id == sessionID,
                  activeSession?.state == .connected,
                  !isExplicitDisconnect,
                  (connection as AnyObject) === connObj else {
                return []
            }
            herdrWorkspaces = []
            herdrError = error.localizedDescription
            return []
        }
    }

    func refreshHerdrState() async {
        if connection is any MoshSessionControlling {
            return
        }
        guard let currentSession = activeSession, currentSession.state == .connected,
              let currentConnection = connection, currentConnection is SSHCommandExecuting else {
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
              (connection as AnyObject) === connObj else {
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
                      !self.isExplicitDisconnect else {
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
    func runHerdrPaneCommand(paneID: String, command: String, approved: Bool = false) async -> (success: Bool, error: String?) {
        let trimmed = command.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            let msg = "Command cannot be empty."
            herdrError = msg
            return (false, msg)
        }
        guard let currentSession = activeSession, currentSession.state == .connected,
              let executor = connection as? SSHCommandExecuting else {
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
                  (connection as AnyObject) === connObj else {
                return (false, "Session disconnected")
            }
            if result.isSuccess {
                herdrError = nil
                await refreshHerdrState()
                return (true, nil)
            } else {
                let err = result.stderr.trimmingCharacters(in: .whitespacesAndNewlines)
                let out = result.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
                let msg = !err.isEmpty ? err : (!out.isEmpty ? out : "Command failed with code \(result.exitCode)")
                herdrError = msg
                return (false, msg)
            }
        } catch {
            herdrError = error.localizedDescription
            return (false, error.localizedDescription)
        }
    }

    @discardableResult
    func splitHerdrPane(paneID: String, direction: String = "right") async -> (success: Bool, error: String?) {
        guard let currentSession = activeSession, currentSession.state == .connected,
              let executor = connection as? SSHCommandExecuting else {
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
                  (connection as AnyObject) === connObj else {
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

    func readHerdrPaneOutput(paneID: String, source: String = "recent-unwrapped") async throws -> String {
        guard let currentSession = activeSession, currentSession.state == .connected,
              let executor = connection as? SSHCommandExecuting else {
            throw HerdrParseError.emptyOutput
        }
        let sessionID = currentSession.id
        let connObj = connection as AnyObject

        let cmd = HerdrCommand.paneRead(pane: paneID, source: source).renderedCommand
        let result = try await executor.executeCommand(cmd, timeout: 5.0)
        guard activeSession?.id == sessionID,
              activeSession?.state == .connected,
              !isExplicitDisconnect,
              (connection as AnyObject) === connObj else {
            throw HerdrParseError.emptyOutput
        }
        guard result.isSuccess else {
            let err = result.stderr.trimmingCharacters(in: .whitespacesAndNewlines)
            throw HerdrParseError.executionFailed(!err.isEmpty ? err : "Read failed with code \(result.exitCode)")
        }
        let unwrapped = HerdrOutputParser.parseRecentUnwrapped(from: result.stdout)
        return redactor.redact(unwrapped)
    }

    func waitHerdrAgentStatus(paneID: String? = nil, status: String? = nil, timeout: TimeInterval = 10.0) async throws -> HerdrAgentState {
        guard let currentSession = activeSession, currentSession.state == .connected,
              let executor = connection as? SSHCommandExecuting else {
            throw HerdrParseError.emptyOutput
        }
        let sessionID = currentSession.id
        let connObj = connection as AnyObject

        let cmd = HerdrCommand.waitAgentStatus(pane: paneID, status: status).renderedCommand
        let result = try await executor.executeCommand(cmd, timeout: timeout)
        guard activeSession?.id == sessionID,
              activeSession?.state == .connected,
              !isExplicitDisconnect,
              (connection as AnyObject) === connObj else {
                throw HerdrParseError.emptyOutput
        }
        guard result.isSuccess else {
            let err = result.stderr.trimmingCharacters(in: .whitespacesAndNewlines)
            throw HerdrParseError.executionFailed(!err.isEmpty ? err : "Wait failed with code \(result.exitCode)")
        }
        let state = try HerdrOutputParser.parseAgentState(from: result.stdout)
        await refreshHerdrState()
        return state
    }

    @discardableResult
    func createHerdrWorkspace(label: String, cwd: String = ".") async -> (success: Bool, error: String?) {
        let trimmedLabel = label.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedLabel.isEmpty else {
            let msg = "Workspace label cannot be empty."
            herdrError = msg
            return (false, msg)
        }
        guard let currentSession = activeSession, currentSession.state == .connected,
              let executor = connection as? SSHCommandExecuting else {
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
                  (connection as AnyObject) === connObj else {
                return (false, "Session disconnected")
            }
            if result.isSuccess {
                herdrError = nil
                await refreshHerdrState()
                return (true, nil)
            } else {
                let err = result.stderr.trimmingCharacters(in: .whitespacesAndNewlines)
                let msg = !err.isEmpty ? err : "Failed to create workspace (exit code \(result.exitCode))"
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
                    if let index = self.voiceModels.firstIndex(where: { $0.id == tier.defaultModelID }) {
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
            let message = "Voice mode '\(effectiveMode.displayName)' is not permitted by host policy for '\(host.name)'."
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
                let err = TranscriptionError.modelNotInstalled(modelID: WhisperModelTier.tiny.defaultModelID)
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
            let transcript = try await transcriber.transcribe(recording: handle) { [weak self] fraction in
                Task { @MainActor [weak self] in
                    guard let self, self.voiceTranscriptionGeneration == gen, self.isTranscribingVoice else { return }
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
    func sendAgentMessage(preview: VoicePreviewState, confirmedProduction: Bool = false) async -> Bool {
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

    // MARK: - SFTP & File Management Methods

    func setupSFTPForHost(_ host: Host) async {
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
                    identity: await identity(for: host),
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
        guard let host = activeHost else { return }
        self.lastSFTPFailure = nil
        self.sftpErrorMessage = nil
        await setupSFTPForHost(host)
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
                return sortAscending ? (result == .orderedAscending) : (result == .orderedDescending)
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
        guard let repo = sftpRepository else {
            directoryErrorMessage = "SFTP repository unavailable."
            return
        }

        if !bypassCache, let cached = directoryCache[path], Date().timeIntervalSince(cached.timestamp) < directoryCacheTTL {
            currentPath = path
            currentDirectoryFiles = cached.files
            directoryErrorMessage = nil
            return
        }

        isLoadingDirectory = true
        directoryErrorMessage = nil

        do {
            let files = try await repo.listDirectory(at: path)
            directoryCache[path] = (files: files, timestamp: Date())
            currentPath = path
            currentDirectoryFiles = files
            isLoadingDirectory = false
        } catch {
            isLoadingDirectory = false
            directoryErrorMessage = error.localizedDescription
            if path != .root && currentDirectoryFiles.isEmpty {
                await loadDirectory(at: .root, bypassCache: true)
            }
        }
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
        guard let repo = sftpRepository else {
            directoryErrorMessage = "SFTP repository unavailable."
            return nil
        }

        let safeFileName = (file.name as NSString).lastPathComponent
        guard !safeFileName.isEmpty && safeFileName != "." && safeFileName != ".." else {
            directoryErrorMessage = "Invalid file name: '\(file.name)'"
            return nil
        }

        let defaultDir = FileManager.default.temporaryDirectory.appendingPathComponent("ShhDownloads", isDirectory: true)
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

        let task = await transferCoordinator.enqueue(
            direction: .download,
            remotePath: file.path,
            localURL: targetURL,
            totalBytes: file.size
        )
        self.transferQueueState = await transferCoordinator.snapshot()

        let taskID = task.id
        let executionTask = Task { @MainActor [weak self] in
            guard let self else { return }
            do {
                await self.transferCoordinator.registerCancellation(id: taskID) { [weak self] in
                    Task { @MainActor [weak self] in
                        self?.activeTransferTasks[taskID]?.cancel()
                    }
                }
                try await repo.download(from: file.path, to: targetURL) { [weak self] progress in
                    Task { @MainActor [weak self] in
                        guard let self else { return }
                        await self.transferCoordinator.updateProgress(
                            id: taskID,
                            bytesTransferred: progress.bytesTransferred,
                            totalBytes: progress.totalBytes
                        )
                        self.transferQueueState = await self.transferCoordinator.snapshot()
                    }
                }
                await self.transferCoordinator.markCompleted(id: taskID)
                self.transferQueueState = await self.transferCoordinator.snapshot()
            } catch {
                if Task.isCancelled || (error as? SFTPRepositoryError) == .cancelled {
                    await self.transferCoordinator.cancel(id: taskID)
                } else {
                    await self.transferCoordinator.markFailed(id: taskID, error: error.localizedDescription)
                }
                self.transferQueueState = await self.transferCoordinator.snapshot()
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
        guard let repo = sftpRepository else {
            directoryErrorMessage = "SFTP repository unavailable."
            return nil
        }

        let dir = destinationDirectory ?? currentPath
        let fileName = localURL.lastPathComponent
        guard !fileName.isEmpty && fileName != "." && fileName != ".." && !fileName.contains("/") else {
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
        } else if let _ = try? await repo.fetchAttributes(at: remotePath) {
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

        let fileSize = (try? FileManager.default.attributesOfItem(atPath: localURL.path)[.size] as? NSNumber)?.int64Value ?? 0

        let task = await transferCoordinator.enqueue(
            direction: .upload,
            remotePath: remotePath,
            localURL: localURL,
            totalBytes: fileSize
        )
        self.transferQueueState = await transferCoordinator.snapshot()

        let taskID = task.id
        let executionTask = Task { @MainActor [weak self] in
            guard let self else { return }
            do {
                await self.transferCoordinator.registerCancellation(id: taskID) { [weak self] in
                    Task { @MainActor [weak self] in
                        self?.activeTransferTasks[taskID]?.cancel()
                    }
                }
                try await repo.upload(from: localURL, to: remotePath) { [weak self] progress in
                    Task { @MainActor [weak self] in
                        guard let self else { return }
                        await self.transferCoordinator.updateProgress(
                            id: taskID,
                            bytesTransferred: progress.bytesTransferred,
                            totalBytes: progress.totalBytes
                        )
                        self.transferQueueState = await self.transferCoordinator.snapshot()
                    }
                }
                await self.transferCoordinator.markCompleted(id: taskID)
                self.transferQueueState = await self.transferCoordinator.snapshot()
                self.invalidateDirectoryCache(at: dir)
                if self.currentPath == dir {
                    await self.refreshCurrentDirectory()
                }
            } catch {
                if Task.isCancelled || (error as? SFTPRepositoryError) == .cancelled {
                    await self.transferCoordinator.cancel(id: taskID)
                } else {
                    await self.transferCoordinator.markFailed(id: taskID, error: error.localizedDescription)
                }
                self.transferQueueState = await self.transferCoordinator.snapshot()
            }
            self.activeTransferTasks.removeValue(forKey: taskID)
        }
        activeTransferTasks[taskID] = executionTask
        return task
    }

    public func cancelTransfer(id: UUID) async {
        activeTransferTasks[id]?.cancel()
        activeTransferTasks.removeValue(forKey: id)
        await transferCoordinator.cancel(id: id)
        transferQueueState = await transferCoordinator.snapshot()
    }

    public func retryTransfer(id: UUID) async {
        guard let task = transferQueueState.task(withID: id) else { return }
        await transferCoordinator.remove(id: id)
        if task.direction == .download {
            let file = RemoteFile(name: task.remotePath.lastComponent, path: task.remotePath)
            _ = await enqueueDownload(file: file, destinationURL: task.localURL, overwrite: true)
        } else {
            _ = await enqueueUpload(localURL: task.localURL, destinationDirectory: task.remotePath.parent, overwrite: true)
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
        let downloadDir = fileManager.temporaryDirectory.appendingPathComponent("ShhDownloads", isDirectory: true)
        let uploadDir = fileManager.temporaryDirectory.appendingPathComponent("ShhUploads", isDirectory: true)

        if removeAll {
            try? fileManager.removeItem(at: downloadDir)
            try? fileManager.removeItem(at: uploadDir)
        } else {
            if let contents = try? fileManager.contentsOfDirectory(at: downloadDir, includingPropertiesForKeys: nil) {
                let activeLocalURLs = Set(transferQueueState.activeTasks.map(\.localURL.standardizedFileURL))
                for fileURL in contents {
                    if !activeLocalURLs.contains(fileURL.standardizedFileURL) {
                        try? fileManager.removeItem(at: fileURL)
                    }
                }
            }
            if let stagedDirs = try? fileManager.contentsOfDirectory(at: uploadDir, includingPropertiesForKeys: nil) {
                let activeLocalURLs = Set(transferQueueState.activeTasks.map(\.localURL.standardizedFileURL))
                for stagedDir in stagedDirs {
                    if let files = try? fileManager.contentsOfDirectory(at: stagedDir, includingPropertiesForKeys: nil) {
                        let anyActive = files.contains { activeLocalURLs.contains($0.standardizedFileURL) }
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

    public func deleteFile(_ file: RemoteFile) async throws {
        guard let repo = sftpRepository else {
            throw SFTPRepositoryError.connectionClosed
        }
        if file.isDirectory {
            try await repo.removeDirectory(at: file.path)
        } else {
            try await repo.removeFile(at: file.path)
        }
        invalidateDirectoryCache(at: file.path.parent)
        await refreshCurrentDirectory()
    }

    public func renameFile(_ file: RemoteFile, to newName: String) async throws {
        guard let repo = sftpRepository else {
            throw SFTPRepositoryError.connectionClosed
        }
        let trimmed = newName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty && !trimmed.contains("/") && trimmed != ".." && trimmed != "." else {
            throw SFTPRepositoryError.invalidPath("Invalid file name: '\(newName)'")
        }
        let newPath = try file.path.parent.appendingSafely(trimmed)
        try await repo.rename(from: file.path, to: newPath)
        invalidateDirectoryCache(at: file.path.parent)
        await refreshCurrentDirectory()
    }

    public func moveFile(_ file: RemoteFile, to destinationDirectory: RemotePath) async throws {
        guard let repo = sftpRepository else {
            throw SFTPRepositoryError.connectionClosed
        }
        if file.isDirectory && destinationDirectory.isDescendantOrEqual(to: file.path) {
            throw SFTPRepositoryError.invalidPath("Cannot move directory into itself or descendant: '\(destinationDirectory.description)'")
        }
        let targetPath = try destinationDirectory.appendingSafely(file.name)
        try await repo.rename(from: file.path, to: targetPath)
        invalidateDirectoryCache(at: file.path.parent)
        invalidateDirectoryCache(at: destinationDirectory)
        await refreshCurrentDirectory()
    }

    public func createDirectory(named name: String) async throws {
        guard let repo = sftpRepository else {
            throw SFTPRepositoryError.connectionClosed
        }
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty && !trimmed.contains("/") && trimmed != ".." && trimmed != "." else {
            throw SFTPRepositoryError.invalidPath("Invalid directory name: '\(name)'")
        }
        let targetPath = try currentPath.appendingSafely(trimmed)
        try await repo.createDirectory(at: targetPath)
        invalidateDirectoryCache(at: currentPath)
        await refreshCurrentDirectory()
    }

    public func createFile(named name: String, content: Data = Data()) async throws {
        guard let repo = sftpRepository else {
            throw SFTPRepositoryError.connectionClosed
        }
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty && !trimmed.contains("/") && trimmed != ".." && trimmed != "." else {
            throw SFTPRepositoryError.invalidPath("Invalid file name: '\(name)'")
        }
        let targetPath = try currentPath.appendingSafely(trimmed)
        try await repo.writeFile(data: content, at: targetPath, progress: nil)
        invalidateDirectoryCache(at: currentPath)
        await refreshCurrentDirectory()
    }

    // MARK: - Previews & In-App Text Editor

    public func openItem(_ file: RemoteFile) async {
        if file.isDirectory {
            await navigateTo(file.path)
            return
        }
        if file.isSymlink {
            if let attrs = try? await sftpRepository?.fetchAttributes(at: file.path), attrs.isDirectory {
                await navigateTo(file.path)
                return
            }
            if let targetStr = file.symlinkTarget {
                let resolvedPath = targetStr.hasPrefix("/") ? RemotePath(targetStr) : file.path.parent.appending(targetStr)
                if let attrs = try? await sftpRepository?.fetchAttributes(at: resolvedPath), attrs.isDirectory {
                    await navigateTo(file.path)
                    return
                }
            }
        }
        await loadPreview(for: file)
    }

    public func loadPreview(for file: RemoteFile) async {
        guard let repo = sftpRepository else { return }
        previewFile = file
        previewData = nil
        previewErrorMessage = nil

        let maxPreviewSize: Int64 = 5 * 1024 * 1024 // 5 MB
        if file.size > maxPreviewSize {
            previewErrorMessage = "File size (\(ByteCountFormatter.string(fromByteCount: file.size, countStyle: .file))) exceeds 5 MB preview limit. Please download to view."
            isPreviewLoading = false
            return
        }

        isPreviewLoading = true
        do {
            let data = try await repo.readFile(at: file.path)
            previewData = data
            isPreviewLoading = false
        } catch {
            isPreviewLoading = false
            previewErrorMessage = error.localizedDescription
        }
    }

    public func closePreview() {
        previewFile = nil
        previewData = nil
        previewErrorMessage = nil
        isPreviewLoading = false
    }

    public func openEditor(for file: RemoteFile) async throws {
        guard let repo = sftpRepository else {
            throw SFTPRepositoryError.connectionClosed
        }
        isSavingFile = false
        editorErrorMessage = nil

        let maxEditorSize: Int64 = 2 * 1024 * 1024 // 2 MB
        if file.size > maxEditorSize {
            let err = SFTPRepositoryError.remoteFailure("File size (\(ByteCountFormatter.string(fromByteCount: file.size, countStyle: .file))) exceeds 2 MB editor limit. Please download to view.")
            editorErrorMessage = err.localizedDescription
            throw err
        }

        do {
            let data = try await repo.readFile(at: file.path)
            guard let text = String(data: data, encoding: .utf8) else {
                let err = SFTPRepositoryError.remoteFailure("Cannot edit '\(file.name)': File contains non-UTF-8 or binary data.")
                editorErrorMessage = err.localizedDescription
                throw err
            }
            editingFileContent = text
            activeEditingFile = file
            activeEditingHostID = activeHost?.id
        } catch {
            editorErrorMessage = error.localizedDescription
            throw error
        }
    }

    public func closeEditor() {
        activeEditingFile = nil
        editingFileContent = ""
        isSavingFile = false
        editorErrorMessage = nil
        activeEditingHostID = nil
    }

    public func saveEditedFile() async throws {
        guard let repo = sftpRepository, let file = activeEditingFile else {
            throw SFTPRepositoryError.connectionClosed
        }
        guard activeHost?.id == activeEditingHostID else {
            throw SFTPRepositoryError.remoteFailure("Host mismatch: File editor session belongs to a different host.")
        }
        isSavingFile = true
        editorErrorMessage = nil
        do {
            let data = Data(editingFileContent.utf8)
            try await repo.writeFile(data: data, at: file.path, progress: nil)
            invalidateDirectoryCache(at: file.path.parent)
            if currentPath == file.path.parent {
                await refreshCurrentDirectory()
            }
            isSavingFile = false
        } catch {
            isSavingFile = false
            editorErrorMessage = error.localizedDescription
            throw error
        }
    }

    // MARK: - Port Forwarding Management

    private func startForwardingMonitoring(manager: any PortForwardingManaging) {
        forwardingStreamTask?.cancel()
        forwardingStreamTask = Task { @MainActor [weak self] in
            let stream = await manager.sessionStatesStream()
            for await states in stream {
                guard let self else { return }
                self.forwardingSessions = states
            }
        }
    }

    private func autoStartForwardingRules(for host: Host, manager: any PortForwardingManaging) async {
        for rule in host.forwardingRules where rule.enabled {
            if rule.requiresNonLoopbackApproval {
                let message = "\(rule.name) requires approval to bind to \(rule.localHost)."
                forwardingErrorMessage = message
                terminalController.feed("\r\n\u{1b}[33m[\(message)]\u{1b}[0m\r\n")
                continue
            }
            do {
                _ = try await manager.startForwarding(rule: rule)
            } catch {
                let message = "Failed to auto-start \(rule.name): \(error.localizedDescription)"
                forwardingErrorMessage = message
                terminalController.feed("\r\n\u{1b}[33m[\(message)]\u{1b}[0m\r\n")
            }
        }
    }

    @discardableResult
    public func startForwarding(rule: PortForwardingRule) async throws -> ForwardingSessionState {
        guard let manager = portForwardingManager else {
            throw TransportError.unsupported
        }
        forwardingErrorMessage = nil
        do {
            let session = try await manager.startForwarding(rule: rule)
            return session
        } catch {
            forwardingErrorMessage = error.localizedDescription
            throw error
        }
    }

    public func stopForwarding(ruleID: UUID) async {
        guard let manager = portForwardingManager else { return }
        do {
            try await manager.stopForwarding(ruleID: ruleID)
        } catch {
            forwardingErrorMessage = error.localizedDescription
        }
    }

    public func stopAllForwarding() async {
        guard let manager = portForwardingManager else { return }
        await manager.stopAll()
    }

    public func addForwardingRule(_ rule: PortForwardingRule, for host: Host, autoStartIfConnected: Bool = true) async throws {
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
                    let ident = bastion.identityID.flatMap { identID in idents.first(where: { $0.id == identID }) }
                    result.append((bastion, ident))
                }
            case .endpoint(let ep):
                if let epHost = try? Host(name: ep.hostname, hostname: ep.hostname, port: ep.port, username: ep.username, identityID: ep.identityID) {
                    let ident = ep.identityID.flatMap { identID in idents.first(where: { $0.id == identID }) }
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
        guard !isRunningInTestEnvironment || fileProviderHelper.customContainerURL != nil else { return }
        let snapshot = await catalog.snapshot()
        let records = await trustStore.allRecords()
        #if canImport(FileProvider)
        try fileProviderHelper.syncSharedState(snapshot: snapshot, trustRecords: records)
        #endif
    }

    public func saveHost(_ host: Host) async throws {
        try await catalog.save(host)
        catalogUpdateToken = UUID()
        try await syncSharedCatalogAndTrust()
    }

    public func deleteHost(id: UUID) async throws {
        try await catalog.delete(id: id)
        catalogUpdateToken = UUID()
        try await syncSharedCatalogAndTrust()
    }

    // MARK: - SSH Keys & Credential Management

    public var keychain: any CredentialStore {
        credentialStore
    }

    @discardableResult
    public func createEd25519Identity(name: String, comment: String? = nil) async throws -> IdentityDescriptor {
        let trimmedName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedName.isEmpty else {
            throw ShhValidationError.empty(field: "identity name")
        }
        let commentValue = comment?.trimmingCharacters(in: .whitespacesAndNewlines)
        let effectiveComment = (commentValue?.isEmpty == false) ? (commentValue ?? trimmedName) : trimmedName
        let generated = Ed25519Parser.generateKeyPair(comment: effectiveComment)
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
        try? await syncSharedCatalogAndTrust()
        return descriptor
    }

    @discardableResult
    public func importPrivateKeyIdentity(name: String, privateKeyText: String) async throws -> IdentityDescriptor {
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
        try? await syncSharedCatalogAndTrust()
        return descriptor
    }

    @discardableResult
    public func createPasswordIdentity(name: String, password: String) async throws -> IdentityDescriptor {
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
        try? await syncSharedCatalogAndTrust()
        return descriptor
    }

    public func deleteIdentity(id: UUID) async throws {
        let identities = try await catalog.identities()
        if let target = identities.first(where: { $0.id == id }) {
            try? await credentialStore.delete(reference: target.keychainReference)
        }
        try await catalog.deleteIdentity(id: id)
        let hosts = try await catalog.listHosts()
        for host in hosts where host.identityID == id {
            var updated = host
            updated.identityID = nil
            try await catalog.save(updated)
        }
        catalogUpdateToken = UUID()
        try? await syncSharedCatalogAndTrust()
    }

    public func openSSHPublicKey(for identity: IdentityDescriptor, comment: String? = nil) async throws -> String? {
        guard identity.kind == .privateKey else { return nil }
        let data = try await credentialStore.load(reference: identity.keychainReference)
        let privateKey = try Ed25519Parser.parse(from: data)
        let effectiveComment = (comment?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false)
            ? comment!
            : identity.name
        return Ed25519Parser.openSSHPublicKeyString(from: privateKey.publicKey, comment: effectiveComment)
    }

    // MARK: - File Provider Domains

    public func registerFileProviderDomain(for host: Host) async throws {
        if case .mosh = host.connection {
            let err = FileProviderManagerError.unsupportedMoshHost(host.name)
            self.fileProviderDomainError = err.localizedDescription
            throw err
        }
        guard fileProviderHelper.containerURL != nil else {
            let err = FileProviderManagerError.containerUnavailable(fileProviderHelper.appGroupIdentifier)
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
                defaultTerminalFontSize: nil,
                voiceProvider: selectedVoiceProviderID,
                voiceAutoPunctuation: true,
                customSettings: [:]
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

    public func restoreCatalog(from snapshot: CatalogSnapshot, mode: RestoreMode) async throws {
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
    }
}
