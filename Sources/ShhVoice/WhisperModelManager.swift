import Foundation
import WhisperKit
import ShhCore

// MARK: - Supported Model Tiers

public enum WhisperModelTier: String, CaseIterable, Codable, Sendable {
    case tiny
    case base
    case small

    public var defaultModelID: String {
        switch self {
        case .tiny: return "openai_whisper-tiny"
        case .base: return "openai_whisper-base"
        case .small: return "openai_whisper-small"
        }
    }

    public var displayName: String {
        switch self {
        case .tiny: return "Whisper Tiny"
        case .base: return "Whisper Base"
        case .small: return "Whisper Small"
        }
    }

    public var estimatedSizeBytes: Int64 {
        switch self {
        case .tiny: return 75_000_000     // ~75 MB
        case .base: return 145_000_000    // ~145 MB
        case .small: return 480_000_000   // ~480 MB
        }
    }

    public var requiredDiskSpaceBytes: Int64 {
        // Model asset size + 100MB safety margin for extraction/working room
        estimatedSizeBytes + 100_000_000
    }

    public var minimumRAMBytes: UInt64 {
        switch self {
        case .tiny: return 1_000_000_000   // 1 GB
        case .base: return 1_500_000_000   // 1.5 GB
        case .small: return 3_000_000_000  // 3 GB
        }
    }

    public static func match(identifier: String) -> WhisperModelTier? {
        let cleaned = identifier.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if cleaned == "tiny" || cleaned == "openai_whisper-tiny" || cleaned.hasSuffix("whisper-tiny") {
            return .tiny
        }
        if cleaned == "base" || cleaned == "openai_whisper-base" || cleaned.hasSuffix("whisper-base") {
            return .base
        }
        if cleaned == "small" || cleaned == "openai_whisper-small" || cleaned.hasSuffix("whisper-small") {
            return .small
        }
        return nil
    }
}

// MARK: - Resource and Validation Protocols

public protocol DeviceResourceChecking: Sendable {
    func availableDiskSpace(at url: URL) throws -> Int64
    var physicalMemoryBytes: UInt64 { get }
}

public struct SystemDeviceResourceChecker: DeviceResourceChecking {
    public init() {}

    public func availableDiskSpace(at url: URL) throws -> Int64 {
        let keys: Set<URLResourceKey> = [.volumeAvailableCapacityForImportantUsageKey, .volumeAvailableCapacityKey]
        let values = try url.resourceValues(forKeys: keys)
        if let important = values.volumeAvailableCapacityForImportantUsage {
            return important
        }
        if let capacity = values.volumeAvailableCapacity {
            return Int64(capacity)
        }
        return Int64.max
    }

    public var physicalMemoryBytes: UInt64 {
        ProcessInfo.processInfo.physicalMemory
    }
}

public protocol WhisperModelValidating: Sendable {
    func validateModel(at folderURL: URL, tier: WhisperModelTier) throws -> Bool
}

public struct StandardWhisperModelValidator: WhisperModelValidating {
    public init() {}

    public func validateModel(at folderURL: URL, tier: WhisperModelTier) throws -> Bool {
        let candidates: [URL] = [
            folderURL,
            folderURL.deletingLastPathComponent()
                .appendingPathComponent("models", isDirectory: true)
                .appendingPathComponent("argmaxinc", isDirectory: true)
                .appendingPathComponent("whisperkit-coreml", isDirectory: true)
                .appendingPathComponent(tier.defaultModelID, isDirectory: true),
            folderURL.deletingLastPathComponent()
                .deletingLastPathComponent()
                .deletingLastPathComponent()
                .appendingPathComponent(tier.defaultModelID, isDirectory: true)
        ]

        guard let validDir = candidates.first(where: { candidate in
            var isDir: ObjCBool = false
            return FileManager.default.fileExists(atPath: candidate.path, isDirectory: &isDir) && isDir.boolValue
        }) else {
            return false
        }

        let contents = try FileManager.default.contentsOfDirectory(atPath: validDir.path)
        guard !contents.isEmpty else {
            return false
        }

        // Must contain valid, non-empty files (e.g. config.json or mlmodelc or tokenizer)
        for item in contents {
            let itemURL = validDir.appendingPathComponent(item)
            var itemIsDir: ObjCBool = false
            if FileManager.default.fileExists(atPath: itemURL.path, isDirectory: &itemIsDir) {
                if !itemIsDir.boolValue {
                    let attrs = try FileManager.default.attributesOfItem(atPath: itemURL.path)
                    let size = (attrs[.size] as? NSNumber)?.int64Value ?? 0
                    if size <= 0 {
                        return false
                    }
                }
            }
        }
        return true
    }
}

public protocol WhisperModelDownloading: Sendable {
    func download(
        tier: WhisperModelTier,
        downloadBase: URL,
        progress: (@Sendable (Double) -> Void)?
    ) async throws -> URL
}

public struct LiveWhisperModelDownloader: WhisperModelDownloading {
    public init() {}

    public func download(
        tier: WhisperModelTier,
        downloadBase: URL,
        progress: (@Sendable (Double) -> Void)?
    ) async throws -> URL {
        try await WhisperKit.download(
            variant: tier.defaultModelID,
            downloadBase: downloadBase,
            useBackgroundSession: false,
            progressCallback: { prog in
                progress?(prog.fractionCompleted)
            }
        )
    }
}

// MARK: - WhisperModelManager Actor

/// Manages local Whisper model assets stored strictly under Application Support/Shh/Models.
/// Excludes storage from iCloud backups, rejects default Hub caches or Documents leakage,
/// enforces disk, RAM, and model identity invariants, supports cooperative cancellation,
/// and rejects incomplete or corrupted state.
public actor WhisperModelManager {
    public let modelsDirectory: URL
    private let deviceChecker: any DeviceResourceChecking
    private let validator: any WhisperModelValidating
    private let downloader: any WhisperModelDownloading
    private let fileManager: FileManager

    private var states: [WhisperModelTier: VoiceModelState] = [:]
    private var activeDownloadTasks: [WhisperModelTier: Task<URL, Error>] = [:]

    public static func defaultModelsDirectory() -> URL {
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        return appSupport.appendingPathComponent("Shh/Models", isDirectory: true)
    }

    public init(
        modelsDirectory: URL = WhisperModelManager.defaultModelsDirectory(),
        deviceChecker: any DeviceResourceChecking = SystemDeviceResourceChecker(),
        validator: any WhisperModelValidating = StandardWhisperModelValidator(),
        downloader: any WhisperModelDownloading = LiveWhisperModelDownloader(),
        fileManager: FileManager = .default
    ) {
        self.modelsDirectory = modelsDirectory
        self.deviceChecker = deviceChecker
        self.validator = validator
        self.downloader = downloader
        self.fileManager = fileManager

        if !fileManager.fileExists(atPath: modelsDirectory.path) {
            try? fileManager.createDirectory(at: modelsDirectory, withIntermediateDirectories: true)
        }
        var targetURL = modelsDirectory
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        try? targetURL.setResourceValues(values)

        var initialStates: [WhisperModelTier: VoiceModelState] = [:]
        for tier in WhisperModelTier.allCases {
            let modelDir = Self.resolvedModelDirectory(in: modelsDirectory, fileManager: fileManager, for: tier)
            if fileManager.fileExists(atPath: modelDir.path) {
                if (try? validator.validateModel(at: modelDir, tier: tier)) == true {
                    let attrs = try? fileManager.attributesOfItem(atPath: modelDir.path)
                    let date = (attrs?[.creationDate] as? Date) ?? Date()
                    initialStates[tier] = .installed(installedAt: date)
                } else {
                    try? fileManager.removeItem(at: modelDir)
                    initialStates[tier] = .notInstalled
                }
            } else {
                initialStates[tier] = .notInstalled
            }
        }
        self.states = initialStates
    }

    public func state(for tier: WhisperModelTier) -> VoiceModelState {
        states[tier] ?? .notInstalled
    }

    public func state(for identifier: String) -> VoiceModelState {
        guard let tier = WhisperModelTier.match(identifier: identifier) else {
            return .unavailable(reason: "Unknown or unsupported model identifier '\(identifier)'")
        }
        return state(for: tier)
    }

    public func listModels() -> [VoiceModelDescriptor] {
        WhisperModelTier.allCases.map { tier in
            VoiceModelDescriptor(
                id: tier.defaultModelID,
                providerID: "localWhisper",
                name: tier.displayName,
                sizeBytes: tier.estimatedSizeBytes,
                state: state(for: tier),
                supportedLanguages: ["en", "multilingual"]
            )
        }
    }

    public func localModelURL(for tier: WhisperModelTier) throws -> URL {
        guard case .installed = state(for: tier) else {
            throw TranscriptionError.modelNotInstalled(modelID: tier.defaultModelID)
        }
        let modelDir = resolvedModelDirectory(for: tier)
        guard try validator.validateModel(at: modelDir, tier: tier) else {
            try? fileManager.removeItem(at: modelDir)
            states[tier] = .notInstalled
            throw TranscriptionError.transcriptionFailed(reason: "Model '\(tier.defaultModelID)' is incomplete or corrupt on disk")
        }
        return modelDir
    }

    public func localModelURL(for identifier: String) throws -> URL {
        guard let tier = WhisperModelTier.match(identifier: identifier) else {
            throw TranscriptionError.modelUnavailable
        }
        return try localModelURL(for: tier)
    }

    public func downloadModel(
        _ tier: WhisperModelTier,
        progress: (@Sendable (Double) -> Void)? = nil
    ) async throws -> URL {
        // 1. In-flight task reuse or conflict guard
        if let existingTask = activeDownloadTasks[tier] {
            return try await existingTask.value
        }

        // 2. RAM guard
        let memory = deviceChecker.physicalMemoryBytes
        if memory < tier.minimumRAMBytes {
            let reqMB = tier.minimumRAMBytes / (1024 * 1024)
            let actMB = memory / (1024 * 1024)
            let err = TranscriptionError.transcriptionFailed(
                reason: "Insufficient RAM for \(tier.displayName): requires at least \(reqMB)MB, but device has \(actMB)MB"
            )
            states[tier] = .unavailable(reason: "Device memory insufficient")
            throw err
        }

        // 3. Disk space guard
        do {
            let freeSpace = try deviceChecker.availableDiskSpace(at: modelsDirectory)
            if freeSpace < tier.requiredDiskSpaceBytes {
                let reqMB = tier.requiredDiskSpaceBytes / (1024 * 1024)
                let actMB = freeSpace / (1024 * 1024)
                let err = TranscriptionError.transcriptionFailed(
                    reason: "Insufficient disk space for \(tier.displayName): requires \(reqMB)MB free, but only \(actMB)MB available"
                )
                throw err
            }
        } catch let err as TranscriptionError {
            throw err
        } catch {
            throw TranscriptionError.transcriptionFailed(reason: "Failed to query available disk space: \(error.localizedDescription)")
        }

        states[tier] = .downloading(fractionCompleted: 0.0)

        let task = Task<URL, Error> { [modelsDirectory, downloader, validator] in
            let targetURL = try await downloader.download(
                tier: tier,
                downloadBase: modelsDirectory,
                progress: { frac in
                    progress?(frac)
                }
            )

            // Validate integrity upon download completion
            guard try validator.validateModel(at: targetURL, tier: tier) else {
                try? FileManager.default.removeItem(at: targetURL)
                throw TranscriptionError.transcriptionFailed(
                    reason: "Model '\(tier.defaultModelID)' downloaded but failed integrity check (corrupt or incomplete)"
                )
            }

            // Exclude from backup
            var backupURL = targetURL
            var values = URLResourceValues()
            values.isExcludedFromBackup = true
            try? backupURL.setResourceValues(values)

            return targetURL
        }

        activeDownloadTasks[tier] = task

        do {
            let resultURL = try await task.value
            activeDownloadTasks[tier] = nil
            states[tier] = .installed(installedAt: Date())
            return resultURL
        } catch is CancellationError {
            activeDownloadTasks[tier] = nil
            cleanupPartialDownload(tier: tier)
            states[tier] = .notInstalled
            throw TranscriptionError.cancelled
        } catch {
            activeDownloadTasks[tier] = nil
            cleanupPartialDownload(tier: tier)
            states[tier] = .notInstalled
            throw error
        }
    }

    public func downloadModel(
        identifier: String,
        progress: (@Sendable (Double) -> Void)? = nil
    ) async throws -> URL {
        guard let tier = WhisperModelTier.match(identifier: identifier) else {
            throw TranscriptionError.modelUnavailable
        }
        return try await downloadModel(tier, progress: progress)
    }

    public func cancelDownload(_ tier: WhisperModelTier) {
        if let task = activeDownloadTasks[tier] {
            task.cancel()
            activeDownloadTasks[tier] = nil
        }
        cleanupPartialDownload(tier: tier)
        states[tier] = .notInstalled
    }

    public func cancelDownload(identifier: String) {
        guard let tier = WhisperModelTier.match(identifier: identifier) else { return }
        cancelDownload(tier)
    }

    public func deleteModel(_ tier: WhisperModelTier) throws {
        cancelDownload(tier)
        let modelDir = resolvedModelDirectory(for: tier)
        if fileManager.fileExists(atPath: modelDir.path) {
            try fileManager.removeItem(at: modelDir)
        }
        states[tier] = .notInstalled
    }

    public func deleteModel(identifier: String) throws {
        guard let tier = WhisperModelTier.match(identifier: identifier) else {
            throw TranscriptionError.modelUnavailable
        }
        try deleteModel(tier)
    }

    public static func resolvedModelDirectory(in modelsDirectory: URL, fileManager: FileManager = .default, for tier: WhisperModelTier) -> URL {
        let direct = modelsDirectory.appendingPathComponent(tier.defaultModelID, isDirectory: true)
        if fileManager.fileExists(atPath: direct.path) {
            return direct
        }
        let hfPath = modelsDirectory
            .appendingPathComponent("models", isDirectory: true)
            .appendingPathComponent("argmaxinc", isDirectory: true)
            .appendingPathComponent("whisperkit-coreml", isDirectory: true)
            .appendingPathComponent(tier.defaultModelID, isDirectory: true)
        if fileManager.fileExists(atPath: hfPath.path) {
            return hfPath
        }
        return direct
    }

    func resolvedModelDirectory(for tier: WhisperModelTier) -> URL {
        Self.resolvedModelDirectory(in: modelsDirectory, fileManager: fileManager, for: tier)
    }

    private func cleanupPartialDownload(tier: WhisperModelTier) {
        let modelDir = resolvedModelDirectory(for: tier)
        if fileManager.fileExists(atPath: modelDir.path) {
            try? fileManager.removeItem(at: modelDir)
        }
    }
}
