import XCTest
import Foundation
@testable import ShhCore
@testable import ShhVoice

final class TranscriberAndRegistryTests: XCTestCase {

    var tempModelsDir: URL!

    override func setUpWithError() throws {
        try super.setUpWithError()
        tempModelsDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("ShhTranscriberTests_\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempModelsDir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        if FileManager.default.fileExists(atPath: tempModelsDir.path) {
            try? FileManager.default.removeItem(at: tempModelsDir)
        }
        try super.tearDownWithError()
    }

    // MARK: - Mocks

    final class Box<T>: @unchecked Sendable {
        var value: T
        init(_ value: T) { self.value = value }
    }

    final class MockWhisperKitEngine: WhisperKitEngine, @unchecked Sendable {
        var transcriptToReturn: String = "git status"
        var errorToThrow: Error?
        var delayNanos: UInt64 = 0
        var transcribeCallCount: Int = 0

        func transcribe(
            audioURL: URL,
            modelFolder: URL,
            progress: (@Sendable (Double) -> Void)?
        ) async throws -> String {
            transcribeCallCount += 1
            if delayNanos > 0 {
                try await Task.sleep(nanoseconds: delayNanos)
            }
            if let errorToThrow {
                throw errorToThrow
            }
            progress?(0.5)
            progress?(1.0)
            return transcriptToReturn
        }
    }

    final class MockAppleSpeechEngine: AppleSpeechEngine, @unchecked Sendable {
        var supportsOnDeviceRecognition: Bool = true
        var transcriptToReturn: String = "ssh production"
        var errorToThrow: Error?
        var delayNanos: UInt64 = 0
        var lastRequiresOnDevice: Bool?
        var lastContextualStrings: [String]?
        var recognizeCallCount: Int = 0

        func recognize(
            audioURL: URL,
            requiresOnDevice: Bool,
            contextualStrings: [String],
            progress: (@Sendable (Double) -> Void)?
        ) async throws -> String {
            recognizeCallCount += 1
            lastRequiresOnDevice = requiresOnDevice
            lastContextualStrings = contextualStrings

            guard requiresOnDevice else {
                throw TranscriptionError.transcriptionFailed(reason: "requiresOnDevice must be true")
            }

            guard supportsOnDeviceRecognition else {
                throw TranscriptionError.transcriptionFailed(reason: "Device does not support on-device recognition")
            }

            if delayNanos > 0 {
                try await Task.sleep(nanoseconds: delayNanos)
            }

            if let errorToThrow {
                throw errorToThrow
            }

            progress?(0.5)
            progress?(1.0)
            return transcriptToReturn
        }
    }

    final class SimpleDownloader: WhisperModelDownloading, @unchecked Sendable {
        func download(tier: WhisperModelTier, downloadBase: URL, progress: (@Sendable (Double) -> Void)?) async throws -> URL {
            let modelDir = downloadBase.appendingPathComponent(tier.defaultModelID, isDirectory: true)
            try FileManager.default.createDirectory(at: modelDir, withIntermediateDirectories: true)
            let configData = "{\"model\": true}".data(using: .utf8)!
            FileManager.default.createFile(atPath: modelDir.appendingPathComponent("config.json").path, contents: configData)
            return modelDir
        }
    }

    // MARK: - WhisperKitTranscriber Tests

    func testWhisperKitTranscriberHappyPath() async throws {
        let downloader = SimpleDownloader()
        let manager = WhisperModelManager(modelsDirectory: tempModelsDir, downloader: downloader)
        _ = try await manager.downloadModel(.tiny)

        let engine = MockWhisperKitEngine()
        engine.transcriptToReturn = "tmux attach -t 0"

        let transcriber = WhisperKitTranscriber(
            modelManager: manager,
            modelID: "openai_whisper-tiny",
            engine: engine
        )

        let handle = try AudioRecordingHandle.createTemporary(fileExtension: "wav")
        defer { handle.cleanup() }
        let wavData = VoiceAudioFormat.createSyntheticWavData(duration: 0.5)
        try wavData.write(to: handle.url)

        let progressValuesBox = Box<[Double]>([])
        let result = try await transcriber.transcribe(recording: handle, progress: { p in
            progressValuesBox.value.append(p)
        })

        XCTAssertEqual(result, "tmux attach -t 0")
        XCTAssertEqual(engine.transcribeCallCount, 1)
        XCTAssertFalse(progressValuesBox.value.isEmpty)
        XCTAssertEqual(progressValuesBox.value.last, 1.0)
    }

    func testWhisperKitTranscriberThrowsWhenModelNotInstalled() async throws {
        let manager = WhisperModelManager(modelsDirectory: tempModelsDir)
        let engine = MockWhisperKitEngine()

        let transcriber = WhisperKitTranscriber(
            modelManager: manager,
            modelID: "openai_whisper-tiny",
            engine: engine
        )

        let handle = try AudioRecordingHandle.createTemporary(fileExtension: "wav")
        defer { handle.cleanup() }
        let wavData = VoiceAudioFormat.createSyntheticWavData(duration: 0.5)
        try wavData.write(to: handle.url)

        do {
            _ = try await transcriber.transcribe(recording: handle)
            XCTFail("Expected modelNotInstalled error")
        } catch let err as TranscriptionError {
            if case .modelNotInstalled(let id) = err {
                XCTAssertEqual(id, "openai_whisper-tiny")
            } else {
                XCTFail("Expected modelNotInstalled, got \(err)")
            }
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
    }

    func testWhisperKitTranscriberFallsBackToInstalledTierWhenRequestedTierMissing() async throws {
        let downloader = SimpleDownloader()
        let manager = WhisperModelManager(modelsDirectory: tempModelsDir, downloader: downloader)
        // Only download base model, leave tiny not installed
        _ = try await manager.downloadModel(.base)

        let engine = MockWhisperKitEngine()
        engine.transcriptToReturn = "fallback base transcript"

        // Default transcriber requests openai_whisper-tiny
        let transcriber = WhisperKitTranscriber(
            modelManager: manager,
            modelID: "openai_whisper-tiny",
            engine: engine
        )

        let handle = try AudioRecordingHandle.createTemporary(fileExtension: "wav")
        defer { handle.cleanup() }
        let wavData = VoiceAudioFormat.createSyntheticWavData(duration: 0.5)
        try wavData.write(to: handle.url)

        let result = try await transcriber.transcribe(recording: handle)
        XCTAssertEqual(result, "fallback base transcript")
        XCTAssertEqual(engine.transcribeCallCount, 1)
    }

    func testWhisperKitTranscriberTimeoutThrows() async throws {
        let downloader = SimpleDownloader()
        let manager = WhisperModelManager(modelsDirectory: tempModelsDir, downloader: downloader)
        _ = try await manager.downloadModel(.tiny)

        let engine = MockWhisperKitEngine()
        engine.delayNanos = 200_000_000 // 200ms delay

        let transcriber = WhisperKitTranscriber(
            modelManager: manager,
            modelID: "openai_whisper-tiny",
            timeout: 0.05, // 50ms timeout
            engine: engine
        )

        let handle = try AudioRecordingHandle.createTemporary(fileExtension: "wav")
        defer { handle.cleanup() }
        let wavData = VoiceAudioFormat.createSyntheticWavData(duration: 0.5)
        try wavData.write(to: handle.url)

        do {
            _ = try await transcriber.transcribe(recording: handle)
            XCTFail("Expected timeout or cancelled error")
        } catch let err as TranscriptionError {
            XCTAssertTrue(err == .timeout || err == .cancelled, "Expected timeout or cancelled, got \(err)")
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
    }

    // MARK: - AppleSpeechTranscriber Tests

    func testAppleSpeechTranscriberHappyPathAndContextualStrings() async throws {
        let engine = MockAppleSpeechEngine()
        engine.transcriptToReturn = "curl -I https://example.com"

        let transcriber = AppleSpeechTranscriber(
            timeout: 10.0,
            engine: engine
        )

        let handle = try AudioRecordingHandle.createTemporary(fileExtension: "wav")
        defer { handle.cleanup() }
        let wavData = VoiceAudioFormat.createSyntheticWavData(duration: 0.5)
        try wavData.write(to: handle.url)

        let result = try await transcriber.transcribe(recording: handle)
        XCTAssertEqual(result, "curl -I https://example.com")
        XCTAssertEqual(engine.recognizeCallCount, 1)
        XCTAssertEqual(engine.lastRequiresOnDevice, true, "Must require on-device recognition")
        XCTAssertNotNil(engine.lastContextualStrings)
        XCTAssertTrue(engine.lastContextualStrings!.contains("curl"))
        XCTAssertTrue(engine.lastContextualStrings!.contains("ssh"))
        XCTAssertTrue(engine.lastContextualStrings!.contains("tmux"))
    }

    func testAppleSpeechTranscriberRejectsWhenOnDeviceUnsupported() async throws {
        let engine = MockAppleSpeechEngine()
        engine.supportsOnDeviceRecognition = false // Device does not support on-device

        let transcriber = AppleSpeechTranscriber(engine: engine)

        let handle = try AudioRecordingHandle.createTemporary(fileExtension: "wav")
        defer { handle.cleanup() }
        let wavData = VoiceAudioFormat.createSyntheticWavData(duration: 0.5)
        try wavData.write(to: handle.url)

        do {
            _ = try await transcriber.transcribe(recording: handle)
            XCTFail("Expected transcriptionFailed error when on-device unsupported")
        } catch let err as TranscriptionError {
            if case .transcriptionFailed(let reason) = err {
                XCTAssertTrue(reason.contains("On-device speech recognition is not supported"), "Reason: \(reason)")
            } else {
                XCTFail("Expected transcriptionFailed, got \(err)")
            }
            XCTAssertEqual(engine.recognizeCallCount, 0, "Engine must not be called when on-device recognition is unsupported")
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
    }

    func testAppleSpeechTranscriberTimeoutThrows() async throws {
        let engine = MockAppleSpeechEngine()
        engine.delayNanos = 200_000_000 // 200ms delay

        let transcriber = AppleSpeechTranscriber(
            timeout: 0.05, // 50ms timeout
            engine: engine
        )

        let handle = try AudioRecordingHandle.createTemporary(fileExtension: "wav")
        defer { handle.cleanup() }
        let wavData = VoiceAudioFormat.createSyntheticWavData(duration: 0.5)
        try wavData.write(to: handle.url)

        do {
            _ = try await transcriber.transcribe(recording: handle)
            XCTFail("Expected timeout or cancelled error")
        } catch let err as TranscriptionError {
            XCTAssertTrue(err == .timeout || err == .cancelled, "Expected timeout or cancelled, got \(err)")
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
    }

    // MARK: - Registry & Selection Tests

    func testProviderRegistrySelectionAndNoSilentFallback() async throws {
        let downloader = SimpleDownloader()
        let manager = WhisperModelManager(modelsDirectory: tempModelsDir, downloader: downloader)
        // Notice: Model is NOT downloaded, so whisper transcriber will fail!

        let whisperEngine = MockWhisperKitEngine()
        let whisperTranscriber = WhisperKitTranscriber(modelManager: manager, engine: whisperEngine)

        let appleEngine = MockAppleSpeechEngine()
        appleEngine.transcriptToReturn = "apple fallback speech"
        let appleTranscriber = AppleSpeechTranscriber(engine: appleEngine)

        let registry = VoiceProviderRegistry(
            whisperTranscriber: whisperTranscriber,
            appleSpeechTranscriber: appleTranscriber
        )

        // 1. Default provider is localWhisper
        XCTAssertEqual(registry.selectedProviderID, VoiceProviderRegistry.whisperProviderID)
        let activeTranscriber = registry.activeTranscriber()

        let handle = try AudioRecordingHandle.createTemporary(fileExtension: "wav")
        defer { handle.cleanup() }
        let wavData = VoiceAudioFormat.createSyntheticWavData(duration: 0.5)
        try wavData.write(to: handle.url)

        // Invariant: When localWhisper fails, it MUST NOT silently fall back to Apple Speech!
        do {
            _ = try await activeTranscriber.transcribe(recording: handle)
            XCTFail("Expected whisper to fail because model is not downloaded")
        } catch let err as TranscriptionError {
            if case .modelNotInstalled = err {
                // Expected failure from WhisperKit
            } else {
                XCTFail("Expected modelNotInstalled, got \(err)")
            }
            // Verify Apple Speech engine was NEVER called!
            XCTAssertEqual(appleEngine.recognizeCallCount, 0, "Must NEVER silently invoke fallback provider")
        }

        // 2. Explicit selection of Apple Speech fallback
        try registry.selectProvider(id: VoiceProviderRegistry.appleSpeechProviderID)
        XCTAssertEqual(registry.selectedProviderID, VoiceProviderRegistry.appleSpeechProviderID)

        let newActiveTranscriber = registry.activeTranscriber()
        let appleResult = try await newActiveTranscriber.transcribe(recording: handle)
        XCTAssertEqual(appleResult, "apple fallback speech")
        XCTAssertEqual(appleEngine.recognizeCallCount, 1)

        // 3. Reject invalid provider
        XCTAssertThrowsError(try registry.selectProvider(id: "cloudGoogleSpeech"))

        // 4. Verify all descriptors are local-only
        let descriptors = registry.providerDescriptors
        XCTAssertEqual(descriptors.count, 2)
        for desc in descriptors {
            XCTAssertTrue(desc.isLocalOnly, "All providers must be strictly local-only")
        }
    }
}
