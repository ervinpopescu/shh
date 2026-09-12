import Foundation
import WhisperKit
import ShhCore

// MARK: - WhisperKit Engine Protocol for Dependency Injection

public protocol WhisperKitEngine: Sendable {
    func transcribe(
        audioURL: URL,
        modelFolder: URL,
        progress: (@Sendable (Double) -> Void)?
    ) async throws -> String
}

public final class LiveWhisperKitEngine: WhisperKitEngine, @unchecked Sendable {
    public init() {}

    public func transcribe(
        audioURL: URL,
        modelFolder: URL,
        progress: (@Sendable (Double) -> Void)?
    ) async throws -> String {
        let config = WhisperKitConfig(
            modelFolder: modelFolder.path,
            verbose: false,
            download: false
        )
        let whisper = try await WhisperKit(config)
        let results: [TranscriptionResult] = try await whisper.transcribe(
            audioPath: audioURL.path,
            callback: { progressInfo in
                progress?(0.5)
                return !Task.isCancelled
            }
        )
        return results.map { $0.text }.joined(separator: " ").trimmingCharacters(in: CharacterSet.whitespacesAndNewlines)
    }
}

// MARK: - WhisperKitTranscriber

/// The default local voice transcriber for Shh, powered by on-device WhisperKit models.
/// Reads models strictly from local directories managed by WhisperModelManager.
/// Operates with zero network/cloud configuration and rejects external hub downloads during transcription.
/// Enforces cancellation, timeouts, and forwards progress.
public final class WhisperKitTranscriber: LocalTranscriber, @unchecked Sendable {
    public let modelManager: WhisperModelManager
    public let modelID: String
    public let timeout: TimeInterval
    private let engine: any WhisperKitEngine

    public init(
        modelManager: WhisperModelManager,
        modelID: String = WhisperModelTier.tiny.defaultModelID,
        timeout: TimeInterval = 60.0,
        engine: any WhisperKitEngine = LiveWhisperKitEngine()
    ) {
        self.modelManager = modelManager
        self.modelID = modelID
        self.timeout = timeout
        self.engine = engine
    }

    public func transcribe(
        recording: AudioRecordingHandle,
        progress: (@Sendable (Double) -> Void)? = nil
    ) async throws -> String {
        try Task.checkCancellation()

        guard recording.exists else {
            throw TranscriptionError.audioFileUnreadable(reason: "Audio recording file does not exist at \(recording.url.path)")
        }

        // Verify model is installed locally
        let modelFolder: URL
        do {
            modelFolder = try await modelManager.localModelURL(for: modelID)
        } catch TranscriptionError.modelNotInstalled {
            // Fall back to checking installed models via modelManager.listModels()
            // and use the URL of the first ready model tier before throwing
            let models = await modelManager.listModels()
            if let installed = models.first(where: { $0.state.isReady }) {
                modelFolder = try await modelManager.localModelURL(for: installed.id)
            } else {
                throw TranscriptionError.modelNotInstalled(modelID: modelID)
            }
        } catch let err as TranscriptionError {
            throw err
        } catch {
            throw TranscriptionError.transcriptionFailed(reason: "Failed to locate local model assets: \(error.localizedDescription)")
        }

        try Task.checkCancellation()

        progress?(0.05)

        let targetAudioURL = recording.url
        let targetModelFolder = modelFolder
        let currentEngine = self.engine
        let currentTimeout = self.timeout

        let transcriptionTask = Task<String, Error> {
            try Task.checkCancellation()
            let result = try await currentEngine.transcribe(
                audioURL: targetAudioURL,
                modelFolder: targetModelFolder,
                progress: { fraction in
                    progress?(0.05 + (fraction * 0.90))
                }
            )
            try Task.checkCancellation()
            return result
        }

        let timeoutTask = Task {
            try? await Task.sleep(nanoseconds: UInt64(currentTimeout * 1_000_000_000))
            if !Task.isCancelled {
                transcriptionTask.cancel()
            }
        }

        do {
            let result = try await transcriptionTask.value
            timeoutTask.cancel()
            progress?(1.0)
            return result
        } catch is CancellationError {
            timeoutTask.cancel()
            throw TranscriptionError.cancelled
        } catch let err as TranscriptionError {
            timeoutTask.cancel()
            throw err
        } catch {
            timeoutTask.cancel()
            if Task.isCancelled {
                throw TranscriptionError.cancelled
            }
            let desc = error.localizedDescription
            if desc.lowercased().contains("cancel") {
                throw TranscriptionError.cancelled
            }
            if desc.lowercased().contains("timeout") {
                throw TranscriptionError.timeout
            }
            throw TranscriptionError.transcriptionFailed(reason: error.localizedDescription)
        }
    }
}
