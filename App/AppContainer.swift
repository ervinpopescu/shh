import Foundation
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

    @Published var useLegacyTerminalFallback: Bool
    @Published var activeSession: TerminalSession?
    @Published var terminalText = ""
    @Published var speechState: SpeechComposerState = .idle
    @Published var pendingTrustChallenge: HostKeyChallenge?
    @Published var reconnectState: ReconnectState = .idle
    @Published var tmuxAvailability: TmuxAvailability = .unavailable(reason: "Not connected")
    @Published var tmuxSessions: [TmuxSessionInfo] = []
    @Published var isProbingTmux: Bool = false
    @Published var isTmuxServerRunning: Bool = false
    @Published var tmuxError: String? = nil
    @Published var activeTmuxSessionID: String? = nil
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
        catalog: InMemoryCatalog = InMemoryCatalog(),
        trustStore: InMemoryTrustStore = InMemoryTrustStore(),
        credentialStore: (any CredentialStore)? = nil,
        transport: (any SSHTransport)? = nil,
        transcriber: (any LocalTranscriber)? = nil,
        modelManager: WhisperModelManager? = nil,
        voiceRegistry: VoiceProviderRegistry? = nil,
        voiceRecorder: (any AudioRecorder)? = nil,
        voiceRouter: VoiceCommandRouter = VoiceCommandRouter(),
        useLegacyTerminalFallback: Bool = false,
        restorationStore: (any SessionRestorationStore)? = nil,
        reachabilityMonitor: (any ReachabilityMonitoring)? = nil,
        reconnectCoordinator: ReconnectCoordinator? = nil
    ) {
        let resolvedCredentialStore = credentialStore ?? KeychainCredentialStore()
        let fallbackArg = ProcessInfo.processInfo.arguments.contains("--legacy-terminal") ||
            ProcessInfo.processInfo.environment["SHH_LEGACY_TERMINAL"] == "1"
        self.catalog = catalog
        self.trustStore = trustStore
        self.credentialStore = resolvedCredentialStore
        self.transport = transport ?? LiveSSHTransport(credentialStore: resolvedCredentialStore)
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
        monitor.start()

        Task { [weak self] in
            await self?.refreshVoiceModels()
        }
    }

    static func demo(
        catalog: InMemoryCatalog = InMemoryCatalog(),
        trustStore: InMemoryTrustStore = InMemoryTrustStore(),
        credentialStore: any CredentialStore = InMemoryCredentialStore(),
        transcriber: (any LocalTranscriber)? = nil,
        modelManager: WhisperModelManager? = nil,
        voiceRegistry: VoiceProviderRegistry? = nil,
        voiceRecorder: (any AudioRecorder)? = nil,
        voiceRouter: VoiceCommandRouter = VoiceCommandRouter(),
        useLegacyTerminalFallback: Bool = false,
        restorationStore: (any SessionRestorationStore)? = nil,
        reachabilityMonitor: (any ReachabilityMonitoring)? = nil,
        reconnectCoordinator: ReconnectCoordinator? = nil
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
            transport: DemoSSHTransport(),
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
            )
        )
    }

    static func statusMessage(for error: Error) -> String {
        guard let transportError = error as? TransportError else {
            return "Connection unavailable."
        }
        switch transportError {
        case .authenticationRequired:
            return "Authentication required."
        case .timeout:
            return "Connection timed out."
        case .networkUnavailable:
            return "Network unavailable."
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
        await cancelVoiceRecording()
        resetVoiceState()
        tmuxRefreshGeneration += 1
        isExplicitDisconnect = false
        activeHost = host
        activeTmuxSessionID = nil
        tmuxSessions = []
        isTmuxServerRunning = false
        tmuxAvailability = .unavailable(reason: "Not connected")
        tmuxError = nil
        isProbingTmux = false
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

        let session = TerminalSession(hostID: host.id, state: .connecting, capabilities: ["ansi", "resize"])
        activeSession = session
        let initialSize = terminalController.size
        do {
            let connection = try await transport.connect(
                host: host,
                identity: await identity(for: host),
                trustEvaluator: trustStore,
                initialSize: initialSize
            )
            guard activeSession?.id == session.id, activeSession?.state == .connecting else {
                await connection.close()
                return
            }
            // Host key is accepted and connection succeeded; load redaction secret if available
            await loadRedactionSecret(for: host)
            self.connection = connection
            (connection as? LiveSSHConnection)?.setRedactor(redactor)
            activeSession?.state = .connected

            let targetSession = restoringTmuxSessionID ?? (host.autoAttachTmux ? (host.defaultTmuxSession ?? "default") : nil)
            let metadata = SessionRestorationMetadata(
                hostID: host.id,
                sessionID: session.id,
                tmuxSessionID: targetSession
            )
            try? await restorationStore.save(metadata)

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

            Task { [weak self] in
                await self?.refreshTmuxState()
            }
        } catch let error as TransportError {
            guard activeSession?.id == session.id, activeSession?.state == .connecting else { return }
            detachCallbacks()
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
            let message = "Connection unavailable."
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
                        self.isProbingTmux = false
                        self.activeSession?.state = .disconnected
                        self.detachCallbacks()
                        if !self.useLegacyTerminalFallback {
                            self.terminalController.feed("\r\n\u{1b}[90m[Connection closed]\u{1b}[0m\r\n")
                        }
                        self.redactor = Redactor()
                        self.handleConnectionDrop(host: host)
                    case .error(let error):
                        self.tmuxRefreshGeneration += 1
                        self.isProbingTmux = false
                        self.activeSession?.state = .failed
                        self.detachCallbacks()
                        let message = Self.statusMessage(for: error)
                        self.terminalText += "\n" + message
                        if !self.useLegacyTerminalFallback {
                            self.terminalController.feed("\r\n\u{1b}[31m[" + message + "]\u{1b}[0m\r\n")
                        }
                        self.redactor = Redactor()
                        self.handleConnectionDrop(host: host)
                    }
                }
            } catch {
                guard let self, self.activeSession?.id == session.id else { return }
                self.tmuxRefreshGeneration += 1
                self.isProbingTmux = false
                self.activeSession?.state = .failed
                self.detachCallbacks()
                let message = Self.statusMessage(for: error)
                self.terminalText += "\n" + message
                if !self.useLegacyTerminalFallback {
                    self.terminalController.feed("\r\n\u{1b}[31m[" + message + "]\u{1b}[0m\r\n")
                }
                self.redactor = Redactor()
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
        isProbingTmux = false

        let session = TerminalSession(hostID: host.id, state: .connecting, capabilities: ["ansi", "resize"])
        activeSession = session

        let initialSize = terminalController.size
        let connection = try await transport.connect(
            host: host,
            identity: await identity(for: host),
            trustEvaluator: trustStore,
            initialSize: initialSize
        )

        guard activeSession?.id == session.id, !isExplicitDisconnect else {
            await connection.close()
            throw TransportError.cancelled
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

        let targetSession = activeTmuxSessionID ?? (host.autoAttachTmux ? (host.defaultTmuxSession ?? "default") : nil)
        let metadata = SessionRestorationMetadata(
            hostID: host.id,
            sessionID: session.id,
            tmuxSessionID: targetSession
        )
        try? await restorationStore.save(metadata)

        if let target = targetSession {
            await self.handleTmuxTarget(target, on: connection, host: host, session: session)
        }

        let events = await connection.events()
        startEventMonitoring(for: connection, events: events, session: session, host: host)

        Task { [weak self] in
            await self?.refreshTmuxState()
        }
    }

    func cancelReconnect() async {
        isExplicitDisconnect = true
        tmuxRefreshGeneration += 1
        isProbingTmux = false
        await reconnectCoordinator.cancel()
        reconnectState = .cancelled
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
            }
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
                let metadata = SessionRestorationMetadata(
                    hostID: host.id,
                    sessionID: session.id,
                    tmuxSessionID: activeTmuxSessionID ?? host.defaultTmuxSession
                )
                Task { [weak self] in
                    try? await self?.restorationStore.save(metadata)
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
        } else {
            await trustStore.trustOnce(challenge)
        }
        pendingTrustChallenge = nil
        pendingTrustHost = nil
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
        guard let identityID = host.identityID,
              let identities = try? await catalog.identities(),
              let identity = identities.first(where: { $0.id == identityID }),
              let secret = try? await credentialStore.load(reference: identity.keychainReference),
              let value = String(data: secret, encoding: .utf8), !value.isEmpty else { return }
        redactor = Redactor(secrets: [value])
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

    func updateActiveHostPreferences(autoAttachTmux: Bool, defaultTmuxSession: String?) async throws {
        guard let host = activeHost else { return }
        let validatedSession: String?
        if let session = defaultTmuxSession?.trimmingCharacters(in: .whitespacesAndNewlines), !session.isEmpty {
            if session.hasPrefix("$") {
                _ = try TmuxSessionID(session)
            } else {
                _ = try TmuxSessionName(session)
            }
            validatedSession = session
        } else {
            validatedSession = nil
        }

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
                defaultSession: validatedSession,
                autoAttach: autoAttachTmux
            )
        )

        activeHost = updatedHost
        try await catalog.save(updatedHost)
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
            guard activeSession?.id == session.id,
                  activeSession?.state == .connected,
                  !isExplicitDisconnect,
                  (self.connection as AnyObject) === (connection as AnyObject) else {
                return
            }
            _ = await createTmuxSession(name: trimmed)
        } else {
            guard activeSession?.id == session.id,
                  activeSession?.state == .connected,
                  !isExplicitDisconnect,
                  (self.connection as AnyObject) === (connection as AnyObject) else {
                return
            }
            _ = await createTmuxSession(name: "default")
        }
    }

    @discardableResult
    func probeTmux() async -> TmuxAvailability {
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
                    let parseMessage = "Failed to parse tmux sessions: \(error.localizedDescription)"
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
}
