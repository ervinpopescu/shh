import XCTest
import Foundation
@testable import ShhCore
@testable import ShhVoice

final class WhisperModelManagerTests: XCTestCase {

    var tempModelsDir: URL!

    override func setUpWithError() throws {
        try super.setUpWithError()
        tempModelsDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("ShhTestModels_\(UUID().uuidString)", isDirectory: true)
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

    struct MockDeviceChecker: DeviceResourceChecking {
        var freeDiskBytes: Int64 = 10_000_000_000 // 10 GB
        var memoryBytes: UInt64 = 8_000_000_000    // 8 GB

        func availableDiskSpace(at url: URL) throws -> Int64 {
            freeDiskBytes
        }

        var physicalMemoryBytes: UInt64 {
            memoryBytes
        }
    }

    final class MockModelDownloader: WhisperModelDownloading, @unchecked Sendable {
        var shouldThrow: Error?
        var delayNanos: UInt64 = 0
        var simulateCorruptDownload: Bool = false

        func download(
            tier: WhisperModelTier,
            downloadBase: URL,
            progress: (@Sendable (Double) -> Void)?
        ) async throws -> URL {
            if let shouldThrow {
                throw shouldThrow
            }

            if delayNanos > 0 {
                try await Task.sleep(nanoseconds: delayNanos)
            }

            progress?(0.25)
            progress?(0.50)
            progress?(0.75)
            progress?(1.0)

            let modelDir = downloadBase.appendingPathComponent(tier.defaultModelID, isDirectory: true)
            try FileManager.default.createDirectory(at: modelDir, withIntermediateDirectories: true)

            if simulateCorruptDownload {
                // Create an empty corrupt file (0 bytes)
                FileManager.default.createFile(atPath: modelDir.appendingPathComponent("config.json").path, contents: Data())
            } else {
                // Create valid non-empty files
                let configData = "{\"model_type\": \"whisper\"}".data(using: .utf8)!
                FileManager.default.createFile(atPath: modelDir.appendingPathComponent("config.json").path, contents: configData)
                let weightsData = Data(repeating: 0x42, count: 1024)
                FileManager.default.createFile(atPath: modelDir.appendingPathComponent("model.mil").path, contents: weightsData)
            }

            return modelDir
        }
    }

    // MARK: - Storage & Backup Exclusion Tests

    func testStorageDirectoryCreatedWithBackupExclusion() async throws {
        _ = WhisperModelManager(
            modelsDirectory: tempModelsDir,
            deviceChecker: MockDeviceChecker(),
            downloader: MockModelDownloader()
        )

        XCTAssertTrue(FileManager.default.fileExists(atPath: tempModelsDir.path))

        let values = try tempModelsDir.resourceValues(forKeys: [.isExcludedFromBackupKey])
        XCTAssertEqual(values.isExcludedFromBackup, true, "Models directory must be excluded from iCloud backups")
    }

    func testSupportedTiersAndIdentityMatching() {
        XCTAssertEqual(WhisperModelTier.match(identifier: "tiny"), .tiny)
        XCTAssertEqual(WhisperModelTier.match(identifier: "openai_whisper-tiny"), .tiny)
        XCTAssertEqual(WhisperModelTier.match(identifier: "base"), .base)
        XCTAssertEqual(WhisperModelTier.match(identifier: "openai_whisper-base"), .base)
        XCTAssertEqual(WhisperModelTier.match(identifier: "small"), .small)
        XCTAssertEqual(WhisperModelTier.match(identifier: "openai_whisper-small"), .small)

        // Reject invalid / unapproved models
        XCTAssertNil(WhisperModelTier.match(identifier: "large"))
        XCTAssertNil(WhisperModelTier.match(identifier: "medium"))
        XCTAssertNil(WhisperModelTier.match(identifier: "huggingface/external-model"))
        XCTAssertNil(WhisperModelTier.match(identifier: ""))
    }

    // MARK: - Download, Progress, and Installation Tests

    func testModelDownloadHappyPathProgressAndStateTransition() async throws {
        let downloader = MockModelDownloader()
        let manager = WhisperModelManager(
            modelsDirectory: tempModelsDir,
            deviceChecker: MockDeviceChecker(),
            downloader: downloader
        )

        let initial = await manager.state(for: .tiny)
        XCTAssertEqual(initial, .notInstalled)

        let reportedProgressBox = Box<[Double]>([])
        let modelURL = try await manager.downloadModel(.tiny, progress: { fraction in
            reportedProgressBox.value.append(fraction)
        })

        XCTAssertTrue(FileManager.default.fileExists(atPath: modelURL.path))
        XCTAssertFalse(reportedProgressBox.value.isEmpty)
        XCTAssertEqual(reportedProgressBox.value.last, 1.0)

        let postState = await manager.state(for: .tiny)
        guard case .installed = postState else {
            XCTFail("Expected .installed state, got \(postState)")
            return
        }

        let resolvedURL = try await manager.localModelURL(for: "openai_whisper-tiny")
        XCTAssertEqual(resolvedURL.path, modelURL.path)
    }

    func testDownloadCancellationCleansUpPartialFiles() async throws {
        let downloader = MockModelDownloader()
        downloader.delayNanos = 200_000_000 // 200ms delay

        let manager = WhisperModelManager(
            modelsDirectory: tempModelsDir,
            deviceChecker: MockDeviceChecker(),
            downloader: downloader
        )

        let downloadTask = Task {
            try await manager.downloadModel(.tiny)
        }

        // Wait slightly then cancel
        try await Task.sleep(nanoseconds: 30_000_000)
        await manager.cancelDownload(.tiny)

        do {
            _ = try await downloadTask.value
            XCTFail("Expected download task to fail or cancel")
        } catch {
            // Expected cancellation or error
        }

        let state = await manager.state(for: .tiny)
        XCTAssertEqual(state, .notInstalled)

        let expectedPath = tempModelsDir.appendingPathComponent(WhisperModelTier.tiny.defaultModelID).path
        XCTAssertFalse(FileManager.default.fileExists(atPath: expectedPath), "Partial files must be cleaned up on cancellation")
    }

    func testModelDeletionRemovesAssetsAndResetsState() async throws {
        let downloader = MockModelDownloader()
        let manager = WhisperModelManager(
            modelsDirectory: tempModelsDir,
            deviceChecker: MockDeviceChecker(),
            downloader: downloader
        )

        _ = try await manager.downloadModel(.base)
        let installedState = await manager.state(for: .base)
        guard case .installed = installedState else {
            XCTFail("Expected model to be installed")
            return
        }

        try await manager.deleteModel(.base)
        let stateAfter = await manager.state(for: .base)
        XCTAssertEqual(stateAfter, .notInstalled)

        let expectedPath = tempModelsDir.appendingPathComponent(WhisperModelTier.base.defaultModelID).path
        XCTAssertFalse(FileManager.default.fileExists(atPath: expectedPath), "Assets must be deleted from disk")
    }

    // MARK: - Resource Guards Tests

    func testLowDiskSpaceGuardRejectsDownloadWithoutWriting() async throws {
        var checker = MockDeviceChecker()
        checker.freeDiskBytes = 10_000_000 // 10MB free space (insufficient for tiny ~175MB)

        let downloader = MockModelDownloader()
        let manager = WhisperModelManager(
            modelsDirectory: tempModelsDir,
            deviceChecker: checker,
            downloader: downloader
        )

        do {
            _ = try await manager.downloadModel(.tiny)
            XCTFail("Expected download to fail due to low disk space")
        } catch let err as TranscriptionError {
            if case .transcriptionFailed(let reason) = err {
                XCTAssertTrue(reason.contains("Insufficient disk space"), "Reason: \(reason)")
            } else {
                XCTFail("Expected transcriptionFailed with disk space message, got \(err)")
            }
        } catch {
            XCTFail("Unexpected error: \(error)")
        }

        let state = await manager.state(for: .tiny)
        XCTAssertEqual(state, .notInstalled)
    }

    func testLowRAMGuardRejectsSmallModelDownload() async throws {
        var checker = MockDeviceChecker()
        checker.memoryBytes = 1_500_000_000 // 1.5GB RAM (small model requires 3GB)

        let downloader = MockModelDownloader()
        let manager = WhisperModelManager(
            modelsDirectory: tempModelsDir,
            deviceChecker: checker,
            downloader: downloader
        )

        do {
            _ = try await manager.downloadModel(.small)
            XCTFail("Expected download to fail due to insufficient RAM")
        } catch let err as TranscriptionError {
            if case .transcriptionFailed(let reason) = err {
                XCTAssertTrue(reason.contains("Insufficient RAM"), "Reason: \(reason)")
            } else {
                XCTFail("Expected transcriptionFailed with RAM message, got \(err)")
            }
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
    }

    // MARK: - Integrity & Corruption Tests

    func testCorruptedDownloadedModelRejectedAndRemoved() async throws {
        let downloader = MockModelDownloader()
        downloader.simulateCorruptDownload = true // Generates 0-byte file

        let manager = WhisperModelManager(
            modelsDirectory: tempModelsDir,
            deviceChecker: MockDeviceChecker(),
            downloader: downloader
        )

        do {
            _ = try await manager.downloadModel(.tiny)
            XCTFail("Expected download to fail integrity check")
        } catch let err as TranscriptionError {
            if case .transcriptionFailed(let reason) = err {
                XCTAssertTrue(reason.contains("integrity"), "Reason: \(reason)")
            } else {
                XCTFail("Expected transcriptionFailed with integrity message, got \(err)")
            }
        } catch {
            XCTFail("Unexpected error: \(error)")
        }

        let state = await manager.state(for: .tiny)
        XCTAssertEqual(state, .notInstalled)

        let expectedPath = tempModelsDir.appendingPathComponent(WhisperModelTier.tiny.defaultModelID).path
        XCTAssertFalse(FileManager.default.fileExists(atPath: expectedPath), "Corrupt model must be removed from disk")
    }

    func testUninstalledModelAccessThrowsModelNotInstalled() async throws {
        let manager = WhisperModelManager(
            modelsDirectory: tempModelsDir,
            deviceChecker: MockDeviceChecker(),
            downloader: MockModelDownloader()
        )

        do {
            _ = try await manager.localModelURL(for: .tiny)
            XCTFail("Expected modelNotInstalled error")
        } catch let err as TranscriptionError {
            if case .modelNotInstalled(let id) = err {
                XCTAssertEqual(id, WhisperModelTier.tiny.defaultModelID)
            } else {
                XCTFail("Expected modelNotInstalled, got \(err)")
            }
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
    }

    func testListModelsReportsAllTiersWithDescriptors() async {
        let manager = WhisperModelManager(
            modelsDirectory: tempModelsDir,
            deviceChecker: MockDeviceChecker(),
            downloader: MockModelDownloader()
        )

        let models = await manager.listModels()
        XCTAssertEqual(models.count, 3)
        XCTAssertTrue(models.contains { $0.id == "openai_whisper-tiny" })
        XCTAssertTrue(models.contains { $0.id == "openai_whisper-base" })
        XCTAssertTrue(models.contains { $0.id == "openai_whisper-small" })
        for m in models {
            XCTAssertEqual(m.providerID, "localWhisper")
            XCTAssertEqual(m.state, .notInstalled)
        }
    }
}
