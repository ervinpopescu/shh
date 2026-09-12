import Foundation
import ShhCore

// MARK: - Voice Provider Registry

/// Manages registration and explicit selection of local voice transcription providers.
/// Enforces the invariant that providers never silently fall back to another provider.
/// WhisperKit is the default local provider; AppleSpeech is an on-device-only fallback
/// that must be explicitly selected by the user.
public final class VoiceProviderRegistry: @unchecked Sendable {
    public static let whisperProviderID = "localWhisper"
    public static let appleSpeechProviderID = "appleSpeech"

    private let lock = NSLock()
    private var selectedID: String
    private let whisperTranscriber: any LocalTranscriber
    private let appleSpeechTranscriber: any LocalTranscriber

    public init(
        whisperTranscriber: any LocalTranscriber,
        appleSpeechTranscriber: any LocalTranscriber,
        initialSelectedID: String = VoiceProviderRegistry.whisperProviderID
    ) {
        self.whisperTranscriber = whisperTranscriber
        self.appleSpeechTranscriber = appleSpeechTranscriber
        self.selectedID = initialSelectedID
    }

    public var selectedProviderID: String {
        lock.lock()
        defer { lock.unlock() }
        return selectedID
    }

    public func selectProvider(id: String) throws {
        lock.lock()
        defer { lock.unlock() }

        guard id == Self.whisperProviderID || id == Self.appleSpeechProviderID else {
            throw TranscriptionError.transcriptionFailed(reason: "Unknown provider ID '\(id)'")
        }
        self.selectedID = id
    }

    public func activeTranscriber() -> any LocalTranscriber {
        lock.lock()
        let currentID = selectedID
        lock.unlock()

        switch currentID {
        case Self.appleSpeechProviderID:
            return appleSpeechTranscriber
        default:
            return whisperTranscriber
        }
    }

    public var providerDescriptors: [VoiceProviderDescriptor] {
        [
            VoiceProviderDescriptor(
                id: Self.whisperProviderID,
                name: "Local Whisper",
                kind: .localWhisper,
                supportedModes: Set(VoiceInputMode.allCases),
                isAvailable: true,
                isLocalOnly: true,
                providerDescription: "On-device Whisper CoreML model running entirely offline"
            ),
            VoiceProviderDescriptor(
                id: Self.appleSpeechProviderID,
                name: "Apple Speech (On-Device)",
                kind: .systemSpeech,
                supportedModes: Set(VoiceInputMode.allCases),
                isAvailable: true,
                isLocalOnly: true,
                providerDescription: "On-device Apple Speech recognition requiring on-device processing and CLI context"
            )
        ]
    }
}
