import Foundation

// MARK: - Voice Input Mode

public enum VoiceInputMode: String, Codable, CaseIterable, Sendable {
    case agentMessage
    case shellCommand
    case insertOnly

    public var displayName: String {
        switch self {
        case .agentMessage:
            return "Agent Message"
        case .shellCommand:
            return "Shell Command"
        case .insertOnly:
            return "Insert Text"
        }
    }

    public var description: String {
        switch self {
        case .agentMessage:
            return "Transcribed speech formatted as an agent prompt or message requiring explicit user dispatch."
        case .shellCommand:
            return "Transcribed speech classified through safety policy and staged for manual send."
        case .insertOnly:
            return "Transcribed speech inserted into the active buffer or editor without execution."
        }
    }
}

// MARK: - Per-Host Voice Policy

public struct HostVoicePolicy: Codable, Hashable, Sendable {
    public var isEnabled: Bool
    public var allowedModes: Set<VoiceInputMode>

    public init(
        isEnabled: Bool = false,
        allowedModes: Set<VoiceInputMode> = Set(VoiceInputMode.allCases)
    ) {
        self.isEnabled = isEnabled
        self.allowedModes = isEnabled ? allowedModes : []
    }

    public static let disabled = HostVoicePolicy(isEnabled: false, allowedModes: [])
    public static let enabled = HostVoicePolicy(isEnabled: true, allowedModes: Set(VoiceInputMode.allCases))

    public func allows(mode: VoiceInputMode) -> Bool {
        isEnabled && allowedModes.contains(mode)
    }

    enum CodingKeys: String, CodingKey {
        case isEnabled, allowedModes
    }

    public init(from decoder: Decoder) throws {
        if let singleVal = try? decoder.singleValueContainer() {
            if let boolVal = try? singleVal.decode(Bool.self) {
                self.init(isEnabled: boolVal)
                return
            }
            if let stringVal = try? singleVal.decode(String.self) {
                let enabled = stringVal.lowercased() == "enabled" || stringVal.lowercased() == "true"
                self.init(isEnabled: enabled)
                return
            }
        }
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let isEnabled = try container.decodeIfPresent(Bool.self, forKey: .isEnabled) ?? false
        let modes = try container.decodeIfPresent(Set<VoiceInputMode>.self, forKey: .allowedModes)
            ?? (isEnabled ? Set(VoiceInputMode.allCases) : [])
        self.init(isEnabled: isEnabled, allowedModes: modes)
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(isEnabled, forKey: .isEnabled)
        try container.encode(allowedModes, forKey: .allowedModes)
    }
}

// MARK: - Provider and Model Descriptors and States

public enum VoiceProviderKind: String, Codable, CaseIterable, Sendable {
    case localWhisper
    case systemSpeech
    case mock
}

public struct VoiceProviderDescriptor: Identifiable, Codable, Hashable, Sendable {
    public let id: String
    public var name: String
    public var kind: VoiceProviderKind
    public var supportedModes: Set<VoiceInputMode>
    public var isAvailable: Bool
    public var isLocalOnly: Bool
    public var providerDescription: String

    public init(
        id: String,
        name: String,
        kind: VoiceProviderKind,
        supportedModes: Set<VoiceInputMode> = Set(VoiceInputMode.allCases),
        isAvailable: Bool = true,
        isLocalOnly: Bool = true,
        providerDescription: String = ""
    ) {
        self.id = id
        self.name = name
        self.kind = kind
        self.supportedModes = supportedModes
        self.isAvailable = isAvailable
        self.isLocalOnly = isLocalOnly
        self.providerDescription = providerDescription
    }
}

public enum VoiceModelState: Codable, Hashable, Sendable {
    case notInstalled
    case downloading(fractionCompleted: Double)
    case installed(installedAt: Date)
    case degraded(reason: String)
    case unavailable(reason: String)

    public var isReady: Bool {
        if case .installed = self { return true }
        return false
    }
}

public struct VoiceModelDescriptor: Identifiable, Codable, Hashable, Sendable {
    public let id: String
    public var providerID: String
    public var name: String
    public var sizeBytes: Int64
    public var state: VoiceModelState
    public var supportedLanguages: [String]

    public init(
        id: String,
        providerID: String,
        name: String,
        sizeBytes: Int64,
        state: VoiceModelState = .notInstalled,
        supportedLanguages: [String] = ["en"]
    ) {
        self.id = id
        self.providerID = providerID
        self.name = name
        self.sizeBytes = sizeBytes
        self.state = state
        self.supportedLanguages = supportedLanguages
    }
}

public enum VoiceProviderState: Codable, Hashable, Sendable {
    case uninitialized
    case ready
    case busy
    case unavailable(reason: String)
    case failed(TranscriptionError)

    public var isReady: Bool {
        if case .ready = self { return true }
        return false
    }
}

// MARK: - Recorder & Transcription Errors

public enum AudioRecorderError: Error, LocalizedError, Codable, Hashable, Sendable {
    case permissionDenied
    case deviceUnavailable(reason: String)
    case alreadyRecording
    case notRecording
    case temporaryFileError(reason: String)
    case captureFailed(reason: String)
    case recordingTooShort
    case cancelled

    public var errorDescription: String? {
        switch self {
        case .permissionDenied:
            return "Microphone access denied. Please enable microphone permissions in iOS Settings."
        case .deviceUnavailable(let reason):
            return "Microphone unavailable: \(reason)"
        case .alreadyRecording:
            return "A recording is already in progress."
        case .notRecording:
            return "No active recording."
        case .temporaryFileError(let reason):
            return "Temporary file error: \(reason)"
        case .captureFailed(let reason):
            return "Audio capture failed: \(reason)"
        case .recordingTooShort:
            return "Recording was too short. Press and hold while speaking."
        case .cancelled:
            return "Recording cancelled."
        }
    }
}

public enum TranscriptionError: Error, LocalizedError, Codable, Hashable, Sendable {
    case modelUnavailable
    case cancelled
    case modelNotInstalled(modelID: String)
    case recorderError(AudioRecorderError)
    case audioFileUnreadable(reason: String)
    case unsupportedAudioFormat(reason: String)
    case transcriptionFailed(reason: String)
    case hostPolicyDisabled(hostID: UUID?)
    case timeout
    case unsupported

    public var errorDescription: String? {
        switch self {
        case .modelUnavailable:
            return "Voice model is unavailable."
        case .cancelled:
            return "Transcription cancelled."
        case .modelNotInstalled(let modelID):
            return "Voice model '\(modelID)' is not installed. Please download it in Voice Settings."
        case .recorderError(let error):
            return error.localizedDescription
        case .audioFileUnreadable(let reason):
            return "Audio file unreadable: \(reason)"
        case .unsupportedAudioFormat(let reason):
            return "Unsupported audio format: \(reason)"
        case .transcriptionFailed(let reason):
            return "Transcription failed: \(reason)"
        case .hostPolicyDisabled:
            return "Voice input is disabled by host policy."
        case .timeout:
            return "Transcription timed out."
        case .unsupported:
            return "Voice input is unsupported on this configuration."
        }
    }
}

// MARK: - Voice Progress

public struct VoiceProgress: Codable, Hashable, Sendable {
    public enum Phase: String, Codable, CaseIterable, Sendable {
        case idle
        case recording
        case transcribing
        case completing
    }

    public var phase: Phase
    public var fractionCompleted: Double
    public var message: String?

    public init(phase: Phase, fractionCompleted: Double = 0.0, message: String? = nil) {
        self.phase = phase
        self.fractionCompleted = min(max(fractionCompleted, 0.0), 1.0)
        self.message = message
    }
}

// MARK: - Audio Recording Handle

public struct AudioRecordingHandle: Identifiable, Hashable, Sendable {
    public let id: UUID
    public let url: URL
    public var fileURL: URL { url }
    public let createdAt: Date
    public var duration: TimeInterval?

    public init(
        id: UUID = UUID(),
        url: URL,
        createdAt: Date = Date(),
        duration: TimeInterval? = nil
    ) {
        self.id = id
        self.url = url
        self.createdAt = createdAt
        self.duration = duration
    }

    public static func createTemporary(
        fileExtension: String = "m4a",
        directory: URL? = nil
    ) throws -> AudioRecordingHandle {
        let dir = directory ?? FileManager.default.temporaryDirectory
        let filename = "shh_voice_\(UUID().uuidString).\(fileExtension)"
        let targetURL = dir.appendingPathComponent(filename)

        let attributes: [FileAttributeKey: Any] = [
            .posixPermissions: 0o600,
            .protectionKey: FileProtectionType.complete
        ]
        let created = FileManager.default.createFile(
            atPath: targetURL.path,
            contents: Data(),
            attributes: attributes
        )
        guard created else {
            throw AudioRecorderError.temporaryFileError(reason: "Failed to create secure temporary file at \(targetURL.path)")
        }

        return AudioRecordingHandle(
            id: UUID(),
            url: targetURL,
            createdAt: Date(),
            duration: nil
        )
    }

    public var exists: Bool {
        FileManager.default.fileExists(atPath: url.path)
    }

    public var sizeBytes: Int64? {
        guard let attrs = try? FileManager.default.attributesOfItem(atPath: url.path),
              let size = attrs[.size] as? NSNumber else {
            return nil
        }
        return size.int64Value
    }

    public func delete() throws {
        if FileManager.default.fileExists(atPath: url.path) {
            try FileManager.default.removeItem(at: url)
        }
    }

    public func cleanup() {
        try? delete()
    }

    public func readData() throws -> Data {
        guard exists else {
            throw TranscriptionError.audioFileUnreadable(reason: "Audio recording file does not exist at \(url.path)")
        }
        return try Data(contentsOf: url)
    }

    public static func withTemporaryHandle<T>(
        fileExtension: String = "m4a",
        directory: URL? = nil,
        _ body: (AudioRecordingHandle) async throws -> T
    ) async throws -> T {
        let handle = try createTemporary(fileExtension: fileExtension, directory: directory)
        defer { handle.cleanup() }
        return try await body(handle)
    }
}

// MARK: - Audio Recorder & Transcriber Protocols

public protocol AudioRecorder: Sendable {
    func start() async throws
    func stop() async throws -> AudioRecordingHandle
    func cancel() async
}

public extension AudioRecorder {
    func stopData() async throws -> Data {
        let handle = try await stop()
        defer { handle.cleanup() }
        return try handle.readData()
    }
}

public struct UnavailableAudioRecorder: AudioRecorder {
    public init() {}
    public func start() async throws { throw TranscriptionError.modelUnavailable }
    public func stop() async throws -> AudioRecordingHandle { throw TranscriptionError.modelUnavailable }
    public func cancel() async {}
}

public protocol LocalTranscriber: Sendable {
    func transcribe(
        recording: AudioRecordingHandle,
        progress: (@Sendable (Double) -> Void)?
    ) async throws -> String

    func transcribe(audio: Data) async throws -> String
}

public extension LocalTranscriber {
    func transcribe(recording: AudioRecordingHandle) async throws -> String {
        try await transcribe(recording: recording, progress: nil)
    }

    func transcribe(audio: Data) async throws -> String {
        let handle = try AudioRecordingHandle.createTemporary()
        try audio.write(to: handle.fileURL)
        defer { handle.cleanup() }
        return try await transcribe(recording: handle, progress: nil)
    }

    func transcribe(
        recording: AudioRecordingHandle,
        progress: (@Sendable (Double) -> Void)?
    ) async throws -> String {
        let data = try recording.readData()
        progress?(0.5)
        let result = try await transcribe(audio: data)
        progress?(1.0)
        return result
    }
}

public struct UnavailableTranscriber: LocalTranscriber {
    public init() {}
    public func transcribe(
        recording: AudioRecordingHandle,
        progress: (@Sendable (Double) -> Void)? = nil
    ) async throws -> String {
        throw TranscriptionError.modelUnavailable
    }
    public func transcribe(audio: Data) async throws -> String {
        throw TranscriptionError.modelUnavailable
    }
}

// MARK: - Routing Decisions & Command Router

public enum VoiceRoutingDecision: Equatable, Hashable, Sendable, Codable {
    case blocked(reason: String)
    case reviewRequired(command: String)
    case manualSendRequired(command: String)
    case insertPendingConfirmation(text: String)
    case agentDispatchPendingConfirmation(message: String)
    case rejected(reason: String)

    /// Invariant: Voice input can NEVER be automatically executed without user interaction.
    public var allowsAutomaticExecution: Bool {
        return false
    }

    public var isBlocked: Bool {
        if case .blocked = self { return true }
        return false
    }

    public var isRejected: Bool {
        if case .rejected = self { return true }
        return false
    }

    public var requiresReview: Bool {
        if case .reviewRequired = self { return true }
        return false
    }

    public var requiresManualAction: Bool {
        switch self {
        case .manualSendRequired, .insertPendingConfirmation, .agentDispatchPendingConfirmation, .reviewRequired:
            return true
        case .blocked, .rejected:
            return false
        }
    }
}

public struct VoiceCommandRouter: Sendable {
    public let commandPolicy: CommandPolicy

    public init(commandPolicy: CommandPolicy = CommandPolicy()) {
        self.commandPolicy = commandPolicy
    }

    public func route(
        transcript: String,
        mode: VoiceInputMode,
        hostPolicy: HostVoicePolicy = .disabled
    ) -> VoiceRoutingDecision {
        guard hostPolicy.isEnabled else {
            return .rejected(reason: "Voice input is disabled for this host")
        }
        guard hostPolicy.allowedModes.contains(mode) else {
            return .rejected(reason: "Voice mode '\(mode.rawValue)' is not permitted by host policy")
        }
        let trimmed = transcript.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            return .rejected(reason: "Voice transcript is empty")
        }

        switch mode {
        case .shellCommand:
            switch commandPolicy.classify(trimmed) {
            case .blocked:
                return .blocked(reason: "Command is blocked by safety policy")
            case .reviewRequired:
                return .reviewRequired(command: trimmed)
            case .safe:
                return .manualSendRequired(command: trimmed)
            }
        case .insertOnly:
            return .insertPendingConfirmation(text: transcript)
        case .agentMessage:
            return .agentDispatchPendingConfirmation(message: trimmed)
        }
    }
}

// MARK: - Voice Preview State & Speech Composer State

public struct VoicePreviewState: Equatable, Hashable, Sendable, Codable {
    public var originalTranscript: String
    public var text: String
    public var mode: VoiceInputMode
    public var decision: VoiceRoutingDecision
    public var duration: TimeInterval?

    public var isEdited: Bool {
        originalTranscript != text
    }

    public init(
        originalTranscript: String,
        text: String? = nil,
        mode: VoiceInputMode = .shellCommand,
        decision: VoiceRoutingDecision? = nil,
        duration: TimeInterval? = nil,
        router: VoiceCommandRouter = VoiceCommandRouter(),
        hostPolicy: HostVoicePolicy = .enabled
    ) {
        self.originalTranscript = originalTranscript
        let effectiveText = text ?? originalTranscript
        self.text = effectiveText
        self.mode = mode
        self.duration = duration
        if let decision {
            self.decision = decision
        } else {
            self.decision = router.route(transcript: effectiveText, mode: mode, hostPolicy: hostPolicy)
        }
    }

    public mutating func updateText(
        _ newText: String,
        router: VoiceCommandRouter = VoiceCommandRouter(),
        hostPolicy: HostVoicePolicy = .enabled
    ) {
        self.text = newText
        self.decision = router.route(transcript: newText, mode: self.mode, hostPolicy: hostPolicy)
    }

    public mutating func updateMode(
        _ newMode: VoiceInputMode,
        router: VoiceCommandRouter = VoiceCommandRouter(),
        hostPolicy: HostVoicePolicy = .enabled
    ) {
        self.mode = newMode
        self.decision = router.route(transcript: self.text, mode: newMode, hostPolicy: hostPolicy)
    }
}

public enum SpeechComposerState: Equatable, Sendable {
    case idle
    case recording
    case recordingWithDuration(TimeInterval)
    case transcribing
    case transcribingWithProgress(fractionCompleted: Double)
    case preview(VoicePreviewState)
    case unavailable
    case unavailableWithReason(String)
    case failed(TranscriptionError)
    case cancelled

    public static func preview(text: String) -> SpeechComposerState {
        .preview(VoicePreviewState(originalTranscript: text))
    }

    public var previewState: VoicePreviewState? {
        if case .preview(let state) = self { return state }
        return nil
    }

    public var previewText: String? {
        previewState?.text
    }

    public var isRecording: Bool {
        switch self {
        case .recording, .recordingWithDuration: return true
        default: return false
        }
    }

    public var isTranscribing: Bool {
        switch self {
        case .transcribing, .transcribingWithProgress: return true
        default: return false
        }
    }
}

// MARK: - Voice Session Coordinator

public actor VoiceSessionCoordinator {
    public private(set) var state: SpeechComposerState = .idle
    private let recorder: any AudioRecorder
    private let transcriber: any LocalTranscriber
    private let router: VoiceCommandRouter
    private var currentRecordingHandle: AudioRecordingHandle?

    public init(
        recorder: any AudioRecorder = UnavailableAudioRecorder(),
        transcriber: any LocalTranscriber = UnavailableTranscriber(),
        router: VoiceCommandRouter = VoiceCommandRouter()
    ) {
        self.recorder = recorder
        self.transcriber = transcriber
        self.router = router
    }

    public func startRecording(
        host: Host,
        mode: VoiceInputMode
    ) async throws {
        guard host.voicePolicy.isEnabled else {
            let err = TranscriptionError.hostPolicyDisabled(hostID: host.id)
            state = .failed(err)
            throw err
        }
        guard host.voicePolicy.allowedModes.contains(mode) else {
            let err = TranscriptionError.transcriptionFailed(reason: "Voice mode '\(mode.rawValue)' is not permitted by host policy")
            state = .failed(err)
            throw err
        }
        guard case .idle = state else {
            let err = AudioRecorderError.alreadyRecording
            state = .failed(.recorderError(err))
            throw err
        }

        do {
            state = .recording
            try await recorder.start()
        } catch {
            let transcriptionErr = (error as? TranscriptionError)
                ?? (error as? AudioRecorderError).map { TranscriptionError.recorderError($0) }
                ?? TranscriptionError.recorderError(.captureFailed(reason: error.localizedDescription))
            state = .failed(transcriptionErr)
            throw transcriptionErr
        }
    }

    public func stopRecordingAndTranscribe(
        host: Host,
        mode: VoiceInputMode,
        progress: (@Sendable (Double) -> Void)? = nil
    ) async throws -> VoicePreviewState {
        guard state.isRecording else {
            let err = AudioRecorderError.notRecording
            state = .failed(.recorderError(err))
            throw TranscriptionError.recorderError(err)
        }

        let handle: AudioRecordingHandle
        do {
            handle = try await recorder.stop()
            self.currentRecordingHandle = handle
        } catch {
            let transcriptionErr = (error as? TranscriptionError)
                ?? (error as? AudioRecorderError).map { TranscriptionError.recorderError($0) }
                ?? TranscriptionError.recorderError(.captureFailed(reason: error.localizedDescription))
            state = .failed(transcriptionErr)
            throw transcriptionErr
        }

        state = .transcribing
        defer {
            handle.cleanup()
            self.currentRecordingHandle = nil
        }

        do {
            try Task.checkCancellation()
            let rawTranscript = try await transcriber.transcribe(
                recording: handle,
                progress: { [weak self] fraction in
                    progress?(fraction)
                    Task { [weak self] in
                        await self?.updateTranscribingProgress(fraction)
                    }
                }
            )
            try Task.checkCancellation()

            let preview = VoicePreviewState(
                originalTranscript: rawTranscript,
                mode: mode,
                duration: handle.duration,
                router: router,
                hostPolicy: host.voicePolicy
            )
            state = .preview(preview)
            return preview
        } catch is CancellationError {
            state = .cancelled
            throw TranscriptionError.cancelled
        } catch let err as TranscriptionError {
            if err == .cancelled {
                state = .cancelled
            } else {
                state = .failed(err)
            }
            throw err
        } catch {
            let err = TranscriptionError.transcriptionFailed(reason: error.localizedDescription)
            state = .failed(err)
            throw err
        }
    }

    public func cancel() async {
        await recorder.cancel()
        currentRecordingHandle?.cleanup()
        currentRecordingHandle = nil
        state = .cancelled
    }

    public func reset() {
        currentRecordingHandle?.cleanup()
        currentRecordingHandle = nil
        state = .idle
    }

    private func updateTranscribingProgress(_ fraction: Double) {
        if state.isTranscribing {
            state = .transcribingWithProgress(fractionCompleted: fraction)
        }
    }
}
