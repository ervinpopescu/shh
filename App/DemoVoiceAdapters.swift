import Foundation
import ShhCore
import ShhVoice

// MARK: - Demo Voice Adapters for Offline / Simulator Demo Mode

public actor DemoAudioRecorder: AudioRecorder {
    private var _isRecording = false
    public var simulateStartError: Error?
    public var simulateStopError: Error?

    public init() {}

    public var isRecording: Bool {
        _isRecording
    }

    public func setSimulateStartError(_ error: Error?) {
        self.simulateStartError = error
    }

    public func setSimulateStopError(_ error: Error?) {
        self.simulateStopError = error
    }

    public func start() async throws {
        if let err = simulateStartError {
            throw err
        }
        if _isRecording {
            throw AudioRecorderError.alreadyRecording
        }
        _isRecording = true
    }

    public func stop() async throws -> AudioRecordingHandle {
        if let err = simulateStopError {
            _isRecording = false
            throw err
        }
        guard _isRecording else {
            throw AudioRecorderError.notRecording
        }
        _isRecording = false

        let handle = try AudioRecordingHandle.createTemporary(fileExtension: VoiceAudioFormat.fileExtension)
        let sampleData = VoiceAudioFormat.createSyntheticWavData(duration: 1.5)
        try sampleData.write(to: handle.fileURL)
        var finalHandle = handle
        finalHandle.duration = 1.5
        return finalHandle
    }

    public func cancel() async {
        _isRecording = false
    }
}

public final class DemoTranscriber: LocalTranscriber, @unchecked Sendable {
    private let lock = NSLock()
    private var _transcript: String
    public var simulateDelay: TimeInterval
    public var simulateError: Error?

    public init(transcript: String = "echo hello from voice", simulateDelay: TimeInterval = 0.05) {
        self._transcript = transcript
        self.simulateDelay = simulateDelay
    }

    public var transcript: String {
        get {
            lock.lock()
            defer { lock.unlock() }
            return _transcript
        }
        set {
            lock.lock()
            _transcript = newValue
            lock.unlock()
        }
    }

    public func setTranscript(_ text: String) {
        self.transcript = text
    }

    public func setSimulateError(_ error: Error?) {
        lock.lock()
        self.simulateError = error
        lock.unlock()
    }

    public func transcribe(
        recording: AudioRecordingHandle,
        progress: (@Sendable (Double) -> Void)? = nil
    ) async throws -> String {
        lock.lock()
        let err = simulateError
        let delay = simulateDelay
        let text = _transcript
        lock.unlock()

        if let err {
            throw err
        }
        if delay > 0 {
            progress?(0.25)
            try await Task.sleep(nanoseconds: UInt64(delay * 0.5 * 1_000_000_000))
            progress?(0.75)
            try await Task.sleep(nanoseconds: UInt64(delay * 0.5 * 1_000_000_000))
            progress?(1.0)
        }
        return text
    }

    public func transcribe(audio: Data) async throws -> String {
        lock.lock()
        let err = simulateError
        let text = _transcript
        lock.unlock()

        if let err {
            throw err
        }
        return text
    }
}

public final class DemoWhisperDownloader: WhisperModelDownloading, @unchecked Sendable {
    public init() {}

    public func download(
        tier: WhisperModelTier,
        downloadBase: URL,
        progress: (@Sendable (Double) -> Void)?
    ) async throws -> URL {
        progress?(0.2)
        try await Task.sleep(nanoseconds: 20_000_000)
        progress?(0.6)
        try await Task.sleep(nanoseconds: 20_000_000)
        progress?(0.9)

        let targetDir = downloadBase.appendingPathComponent(tier.defaultModelID, isDirectory: true)
        try FileManager.default.createDirectory(at: targetDir, withIntermediateDirectories: true)
        let configFile = targetDir.appendingPathComponent("config.json")
        try "{\"tier\":\"\(tier.rawValue)\",\"demo\":true}".data(using: .utf8)?.write(to: configFile)

        progress?(1.0)
        return targetDir
    }
}
