import Foundation
import Speech
import ShhCore

// MARK: - CLI Contextual Strings

public enum CLIContextualStrings {
    public static let standard: [String] = [
        "ssh", "tmux", "ls", "cd", "pwd", "mkdir", "rm", "cp", "mv",
        "touch", "cat", "grep", "chmod", "chown", "curl", "wget", "tar",
        "git", "status", "commit", "push", "pull", "checkout", "branch",
        "docker", "ps", "kill", "systemctl", "journalctl", "top", "htop",
        "df", "du", "free", "uname", "vim", "nano", "sudo", "apt", "brew",
        "zsh", "bash", "echo", "tail", "head", "sed", "awk", "find",
        "python", "node", "swift", "cargo", "--help", "-la", "-rf", "-p",
        "-a", "-v", "stdin", "stdout", "stderr"
    ]
}

// MARK: - Apple Speech Engine Protocol for Dependency Injection

public protocol AppleSpeechEngine: Sendable {
    var supportsOnDeviceRecognition: Bool { get }
    func recognize(
        audioURL: URL,
        requiresOnDevice: Bool,
        contextualStrings: [String],
        progress: (@Sendable (Double) -> Void)?
    ) async throws -> String
}

public final class LiveAppleSpeechEngine: AppleSpeechEngine, @unchecked Sendable {
    private let locale: Locale

    public init(locale: Locale = Locale(identifier: "en_US")) {
        self.locale = locale
    }

    public var supportsOnDeviceRecognition: Bool {
        guard let recognizer = SFSpeechRecognizer(locale: locale) else {
            return false
        }
        return recognizer.supportsOnDeviceRecognition
    }

    public func recognize(
        audioURL: URL,
        requiresOnDevice: Bool,
        contextualStrings: [String],
        progress: (@Sendable (Double) -> Void)?
    ) async throws -> String {
        // Enforce on-device-only invariant: Never permit cloud recognition.
        guard requiresOnDevice else {
            throw TranscriptionError.transcriptionFailed(
                reason: "AppleSpeechTranscriber strictly forbids cloud recognition: requiresOnDevice must be true"
            )
        }

        guard let recognizer = SFSpeechRecognizer(locale: locale), recognizer.isAvailable else {
            throw TranscriptionError.modelUnavailable
        }

        guard recognizer.supportsOnDeviceRecognition else {
            throw TranscriptionError.transcriptionFailed(
                reason: "On-device speech recognition is not supported on this device or for locale '\(locale.identifier)'. Cloud recognition is forbidden."
            )
        }

        let request = SFSpeechURLRecognitionRequest(url: audioURL)
        request.requiresOnDeviceRecognition = true
        request.contextualStrings = contextualStrings
        request.shouldReportPartialResults = true

        final class TaskHolder: @unchecked Sendable {
            var task: SFSpeechRecognitionTask?
        }
        let holder = TaskHolder()

        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                var hasResumed = false
                holder.task = recognizer.recognitionTask(with: request) { result, error in
                    if let error = error {
                        guard !hasResumed else { return }
                        hasResumed = true
                        let nsError = error as NSError
                        if nsError.domain == "kAFAssistantErrorDomain" && nsError.code == 216 {
                            // Cancelled
                            continuation.resume(throwing: TranscriptionError.cancelled)
                        } else {
                            continuation.resume(throwing: TranscriptionError.transcriptionFailed(reason: error.localizedDescription))
                        }
                        return
                    }

                    if let result = result {
                        progress?(0.5)
                        if result.isFinal {
                            guard !hasResumed else { return }
                            hasResumed = true
                            progress?(1.0)
                            continuation.resume(returning: result.bestTranscription.formattedString)
                        }
                    }
                }
            }
        } onCancel: {
            holder.task?.cancel()
        }
    }
}

// MARK: - AppleSpeechTranscriber

/// An explicitly selected, on-device-only fallback transcriber using Apple's Speech framework.
/// Requires on-device recognition (`requiresOnDeviceRecognition = true`), uses CLI contextual strings
/// to maximize terminal command transcription accuracy, and strictly forbids cloud recognition.
/// Never activates silently as an automatic fallback.
public final class AppleSpeechTranscriber: LocalTranscriber, @unchecked Sendable {
    public let timeout: TimeInterval
    public let contextualStrings: [String]
    private let engine: any AppleSpeechEngine

    public init(
        timeout: TimeInterval = 30.0,
        contextualStrings: [String] = CLIContextualStrings.standard,
        engine: any AppleSpeechEngine = LiveAppleSpeechEngine()
    ) {
        self.timeout = timeout
        self.contextualStrings = contextualStrings
        self.engine = engine
    }

    public var supportsOnDeviceRecognition: Bool {
        engine.supportsOnDeviceRecognition
    }

    public func transcribe(
        recording: AudioRecordingHandle,
        progress: (@Sendable (Double) -> Void)? = nil
    ) async throws -> String {
        try Task.checkCancellation()

        guard recording.exists else {
            throw TranscriptionError.audioFileUnreadable(reason: "Audio recording file does not exist at \(recording.url.path)")
        }

        guard engine.supportsOnDeviceRecognition else {
            throw TranscriptionError.transcriptionFailed(
                reason: "On-device speech recognition is not supported on this device. Cloud recognition is strictly forbidden."
            )
        }

        try Task.checkCancellation()

        progress?(0.05)

        let targetAudioURL = recording.url
        let targetEngine = self.engine
        let targetStrings = self.contextualStrings
        let currentTimeout = self.timeout

        let recognitionTask = Task<String, Error> {
            try Task.checkCancellation()
            let result = try await targetEngine.recognize(
                audioURL: targetAudioURL,
                requiresOnDevice: true,
                contextualStrings: targetStrings,
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
                recognitionTask.cancel()
            }
        }

        do {
            let result = try await recognitionTask.value
            timeoutTask.cancel()
            progress?(1.0)
            return result.trimmingCharacters(in: .whitespacesAndNewlines)
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
