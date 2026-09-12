import Foundation

/// Strongly typed, stable item identifier for File Provider items.
public struct FileProviderItemIdentifier: RawRepresentable, Hashable, Codable, Sendable, CustomStringConvertible {
    public let rawValue: String

    public init(rawValue: String) {
        self.rawValue = rawValue
    }

    public var description: String { rawValue }

    // MARK: - Well-known Identifiers

    /// Root container identifier matching Apple's NSFileProviderItemIdentifier.rootContainer.rawValue
    public static let root = FileProviderItemIdentifier(rawValue: "NSFileProviderRootContainerItemIdentifier")

    /// Working set container identifier matching Apple's NSFileProviderItemIdentifier.workingSet.rawValue
    public static let workingSet = FileProviderItemIdentifier(rawValue: "NSFileProviderWorkingSetContainerItemIdentifier")

    /// Trash container identifier matching Apple's NSFileProviderItemIdentifier.trashContainer.rawValue
    public static let trash = FileProviderItemIdentifier(rawValue: "NSFileProviderTrashContainerItemIdentifier")

    // MARK: - Host-based Hierarchical Identifiers

    private static let hostPrefix = "shh-fp:"

    /// Construct a stable identifier for a remote path on a specific host.
    public init(hostID: UUID, remotePath: RemotePath) {
        let normalized = remotePath.description
        self.rawValue = "\(Self.hostPrefix)\(hostID.uuidString):\(normalized)"
    }

    /// Extract the host ID if this is a host-scoped path identifier.
    public var hostID: UUID? {
        guard rawValue.hasPrefix(Self.hostPrefix) else { return nil }
        let trimmed = String(rawValue.dropFirst(Self.hostPrefix.count))
        let parts = trimmed.split(separator: ":", maxSplits: 1, omittingEmptySubsequences: false)
        guard parts.count >= 1 else { return nil }
        return UUID(uuidString: String(parts[0]))
    }

    /// Extract the remote path if this is a host-scoped path identifier.
    public var remotePath: RemotePath? {
        guard rawValue.hasPrefix(Self.hostPrefix) else { return nil }
        let trimmed = String(rawValue.dropFirst(Self.hostPrefix.count))
        let parts = trimmed.split(separator: ":", maxSplits: 1, omittingEmptySubsequences: false)
        guard parts.count == 2 else { return nil }
        return RemotePath(String(parts[1]))
    }

    /// Determine the parent identifier in the hierarchy.
    public var parentIdentifier: FileProviderItemIdentifier {
        if self == .root || self == .workingSet || self == .trash {
            return self
        }

        guard let hostID = self.hostID, let path = self.remotePath else {
            return .root
        }

        if path.isRoot {
            // Host root folder sits directly under the domain root container
            return .root
        }

        let parentPath = path.parent
        if parentPath.isRoot {
            return .root
        }
        return FileProviderItemIdentifier(hostID: hostID, remotePath: parentPath)
    }

    public var isRoot: Bool {
        self == .root
    }
}

/// Capabilities bitmask representing supported file system actions.
public struct FileProviderItemCapabilities: OptionSet, Codable, Hashable, Sendable {
    public let rawValue: UInt32

    public init(rawValue: UInt32) {
        self.rawValue = rawValue
    }

    public static let allowsReading = FileProviderItemCapabilities(rawValue: 1 << 0)
    public static let allowsWriting = FileProviderItemCapabilities(rawValue: 1 << 1)
    public static let allowsRenaming = FileProviderItemCapabilities(rawValue: 1 << 2)
    public static let allowsDeleting = FileProviderItemCapabilities(rawValue: 1 << 3)
    public static let allowsReparenting = FileProviderItemCapabilities(rawValue: 1 << 4)
    public static let allowsEvicting = FileProviderItemCapabilities(rawValue: 1 << 5)

    public static let all: FileProviderItemCapabilities = [
        .allowsReading,
        .allowsWriting,
        .allowsRenaming,
        .allowsDeleting,
        .allowsReparenting,
        .allowsEvicting
    ]

    public static let readOnly: FileProviderItemCapabilities = [
        .allowsReading,
        .allowsEvicting
    ]

    public static let defaultCapabilities: FileProviderItemCapabilities = .all
}

/// Foundation-only metadata contract for a File Provider item.
public struct FileProviderItemContract: Codable, Hashable, Sendable, Identifiable {
    public var id: FileProviderItemIdentifier { identifier }

    public var identifier: FileProviderItemIdentifier
    public var parentIdentifier: FileProviderItemIdentifier
    public var filename: String
    public var isDirectory: Bool
    public var size: Int64
    public var creationDate: Date?
    public var contentModificationDate: Date?
    public var posixPermissions: PosixPermissions?
    public var symlinkTarget: String?
    public var contentTypeIdentifier: String
    public var capabilities: FileProviderItemCapabilities

    public init(
        identifier: FileProviderItemIdentifier,
        parentIdentifier: FileProviderItemIdentifier,
        filename: String,
        isDirectory: Bool,
        size: Int64,
        creationDate: Date? = nil,
        contentModificationDate: Date? = nil,
        posixPermissions: PosixPermissions? = nil,
        symlinkTarget: String? = nil,
        contentTypeIdentifier: String,
        capabilities: FileProviderItemCapabilities = .defaultCapabilities
    ) {
        self.identifier = identifier
        self.parentIdentifier = parentIdentifier
        self.filename = filename
        self.isDirectory = isDirectory
        self.size = size
        self.creationDate = creationDate
        self.contentModificationDate = contentModificationDate
        self.posixPermissions = posixPermissions
        self.symlinkTarget = symlinkTarget
        self.contentTypeIdentifier = contentTypeIdentifier
        self.capabilities = capabilities
    }

    /// Construct a contract item from a domain `RemoteFile`.
    public init(
        remoteFile: RemoteFile,
        hostID: UUID,
        capabilities: FileProviderItemCapabilities = .defaultCapabilities
    ) {
        let id = FileProviderItemIdentifier(hostID: hostID, remotePath: remoteFile.path)
        let parentID = id.parentIdentifier
        let isDir = remoteFile.isDirectory
        let filename = remoteFile.path.isRoot ? "Root" : remoteFile.name

        let uti: String
        if isDir {
            uti = "public.folder"
        } else {
            uti = Self.inferContentType(filename: remoteFile.name)
        }

        self.init(
            identifier: id,
            parentIdentifier: parentID,
            filename: filename,
            isDirectory: isDir,
            size: remoteFile.size,
            creationDate: remoteFile.accessDate,
            contentModificationDate: remoteFile.modificationDate,
            posixPermissions: remoteFile.permissions,
            symlinkTarget: remoteFile.symlinkTarget,
            contentTypeIdentifier: uti,
            capabilities: capabilities
        )
    }

    /// Root container virtual item for a given host domain.
    public static func rootItem(hostID: UUID, hostName: String) -> FileProviderItemContract {
        FileProviderItemContract(
            identifier: .root,
            parentIdentifier: .root,
            filename: hostName,
            isDirectory: true,
            size: 0,
            creationDate: nil,
            contentModificationDate: nil,
            posixPermissions: nil,
            symlinkTarget: nil,
            contentTypeIdentifier: "public.folder",
            capabilities: [.allowsReading, .allowsWriting]
        )
    }

    private static func inferContentType(filename: String) -> String {
        let ext = (filename as NSString).pathExtension.lowercased()
        switch ext {
        case "txt", "md", "markdown", "log", "conf", "cfg", "ini", "env":
            return "public.plain-text"
        case "json":
            return "public.json"
        case "yaml", "yml":
            return "public.yaml"
        case "xml", "plist":
            return "public.xml"
        case "sh", "bash", "zsh":
            return "public.shell-script"
        case "py":
            return "public.python-script"
        case "swift":
            return "public.swift-source"
        case "c", "h", "cpp", "hpp":
            return "public.c-source"
        case "html", "htm":
            return "public.html"
        case "css":
            return "public.css"
        case "js":
            return "com.netscape.javascript-source"
        case "png":
            return "public.png"
        case "jpg", "jpeg":
            return "public.jpeg"
        case "pdf":
            return "com.adobe.pdf"
        case "zip":
            return "public.zip-archive"
        case "tar", "gz", "tgz":
            return "org.gnu.gnu-tar-archive"
        default:
            return "public.data"
        }
    }
}

/// Versioned change synchronization anchor.
public struct FileProviderChangeAnchor: Hashable, Codable, Sendable, Comparable {
    public var generation: UInt64
    public var timestamp: Date

    public init(generation: UInt64 = 0, timestamp: Date = Date()) {
        self.generation = generation
        self.timestamp = timestamp
    }

    public static func < (lhs: FileProviderChangeAnchor, rhs: FileProviderChangeAnchor) -> Bool {
        if lhs.generation != rhs.generation {
            return lhs.generation < rhs.generation
        }
        return lhs.timestamp < rhs.timestamp
    }

    public func advanced() -> FileProviderChangeAnchor {
        FileProviderChangeAnchor(generation: generation + 1, timestamp: Date())
    }

    public func encodedData() -> Data {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        return (try? encoder.encode(self)) ?? Data()
    }

    public static func decode(from data: Data) -> FileProviderChangeAnchor? {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try? decoder.decode(FileProviderChangeAnchor.self, from: data)
    }
}

/// Change event types for File Provider incremental sync.
public enum FileProviderChangeType: String, Codable, Sendable, Hashable {
    case added
    case updated
    case deleted
}

/// Change record tracked during enumeration.
public struct FileProviderChange: Codable, Sendable, Hashable {
    public var itemIdentifier: FileProviderItemIdentifier
    public var type: FileProviderChangeType
    public var item: FileProviderItemContract?
    public var anchor: FileProviderChangeAnchor
    public var timestamp: Date

    public init(
        itemIdentifier: FileProviderItemIdentifier,
        type: FileProviderChangeType,
        item: FileProviderItemContract? = nil,
        anchor: FileProviderChangeAnchor,
        timestamp: Date = Date()
    ) {
        self.itemIdentifier = itemIdentifier
        self.type = type
        self.item = item
        self.anchor = anchor
        self.timestamp = timestamp
    }
}

/// Metadata record cached locally for offline support.
public struct FileProviderCacheMetadata: Codable, Hashable, Sendable, Identifiable {
    public var id: FileProviderItemIdentifier { item.identifier }

    public var hostID: UUID
    public var remotePath: RemotePath
    public var item: FileProviderItemContract
    public var cachedAt: Date
    public var lastAccessDate: Date
    public var fileSizeBytes: Int64
    public var isMaterialized: Bool
    public var localRelativePath: String?
    public var eTag: String?

    public init(
        hostID: UUID,
        remotePath: RemotePath,
        item: FileProviderItemContract,
        cachedAt: Date = Date(),
        lastAccessDate: Date = Date(),
        fileSizeBytes: Int64,
        isMaterialized: Bool = false,
        localRelativePath: String? = nil,
        eTag: String? = nil
    ) {
        self.hostID = hostID
        self.remotePath = remotePath
        self.item = item
        self.cachedAt = cachedAt
        self.lastAccessDate = lastAccessDate
        self.fileSizeBytes = fileSizeBytes
        self.isMaterialized = isMaterialized
        self.localRelativePath = localRelativePath
        self.eTag = eTag
    }
}

/// Eviction policy governing local cache limits.
public struct FileProviderEvictionPolicy: Sendable, Equatable {
    public var maxItemCount: Int
    public var maxCacheSizeBytes: Int64
    public var maxAgeSeconds: TimeInterval
    public var evictMaterializedOnly: Bool

    public init(
        maxItemCount: Int = 500,
        maxCacheSizeBytes: Int64 = 100 * 1024 * 1024, // 100 MB
        maxAgeSeconds: TimeInterval = 7 * 24 * 3600, // 7 days
        evictMaterializedOnly: Bool = false
    ) {
        self.maxItemCount = max(maxItemCount, 1)
        self.maxCacheSizeBytes = max(maxCacheSizeBytes, 1024)
        self.maxAgeSeconds = max(maxAgeSeconds, 1)
        self.evictMaterializedOnly = evictMaterializedOnly
    }
}

/// Pure rule engine evaluating cache items against eviction constraints.
public struct FileProviderEvictionRule: Sendable {
    /// Evaluates which items in `items` should be evicted according to `policy`.
    /// Returns the items that need eviction, ordered from oldest LRU access.
    public static func evaluateEviction(
        items: [FileProviderCacheMetadata],
        policy: FileProviderEvictionPolicy,
        now: Date = Date()
    ) -> [FileProviderCacheMetadata] {
        var itemsToEvict: [FileProviderCacheMetadata] = []
        var remainingItems: [FileProviderCacheMetadata] = []

        // 1. Evict items exceeding maxAge
        for item in items {
            let age = now.timeIntervalSince(item.lastAccessDate)
            if age > policy.maxAgeSeconds {
                if !policy.evictMaterializedOnly || item.isMaterialized {
                    itemsToEvict.append(item)
                    continue
                }
            }
            remainingItems.append(item)
        }

        // Sort remaining candidates by LRU (oldest access date first)
        let sortedCandidates = remainingItems.sorted { $0.lastAccessDate < $1.lastAccessDate }

        var currentCount = sortedCandidates.count
        var currentSize = sortedCandidates.reduce(Int64(0)) { $0 + ($1.isMaterialized ? $1.fileSizeBytes : 0) }

        for item in sortedCandidates {
            let shouldEvictCount = currentCount > policy.maxItemCount
            let shouldEvictSize = currentSize > policy.maxCacheSizeBytes

            if shouldEvictCount || shouldEvictSize {
                if !policy.evictMaterializedOnly || item.isMaterialized {
                    itemsToEvict.append(item)
                    currentCount -= 1
                    if item.isMaterialized {
                        currentSize -= item.fileSizeBytes
                    }
                }
            }
        }

        return itemsToEvict
    }
}

/// Offline mutation operation type.
public enum FileProviderOfflineOperationType: String, Codable, Sendable, Hashable {
    case createDirectory
    case uploadFile
    case modifyFile
    case rename
    case delete
}

/// Execution status of an offline queued operation.
public enum FileProviderOfflineOperationStatus: Codable, Sendable, Hashable {
    case pending
    case inFlight
    case completed
    case failed(reason: String)
}

/// Record of an operation queued when offline or disconnected.
public struct FileProviderOfflineOperation: Codable, Sendable, Identifiable, Hashable {
    public var id: UUID
    public var sequenceNumber: UInt64
    public var hostID: UUID
    public var type: FileProviderOfflineOperationType
    public var sourcePath: RemotePath
    public var targetPath: RemotePath?
    public var localTempRelativePath: String?
    public var createdAt: Date
    public var status: FileProviderOfflineOperationStatus

    public init(
        id: UUID = UUID(),
        sequenceNumber: UInt64,
        hostID: UUID,
        type: FileProviderOfflineOperationType,
        sourcePath: RemotePath,
        targetPath: RemotePath? = nil,
        localTempRelativePath: String? = nil,
        createdAt: Date = Date(),
        status: FileProviderOfflineOperationStatus = .pending
    ) {
        self.id = id
        self.sequenceNumber = sequenceNumber
        self.hostID = hostID
        self.type = type
        self.sourcePath = sourcePath
        self.targetPath = targetPath
        self.localTempRelativePath = localTempRelativePath
        self.createdAt = createdAt
        self.status = status
    }
}

/// Actor maintaining bounded in-memory and serialized metadata cache, change stream, and offline queue.
public actor FileProviderMetadataCache {
    private var metadataStore: [FileProviderItemIdentifier: FileProviderCacheMetadata] = [:]
    private var changeLog: [FileProviderChange] = []
    private var offlineOperations: [UUID: FileProviderOfflineOperation] = [:]
    private var currentGeneration: UInt64 = 1
    private var sequenceCounter: UInt64 = 1

    public init() {}

    public func getMetadata(for identifier: FileProviderItemIdentifier) -> FileProviderCacheMetadata? {
        metadataStore[identifier]
    }

    public func storeMetadata(_ metadata: FileProviderCacheMetadata) {
        metadataStore[metadata.id] = metadata
    }

    public func recordAccess(for identifier: FileProviderItemIdentifier, at date: Date = Date()) {
        guard var item = metadataStore[identifier] else { return }
        item.lastAccessDate = date
        metadataStore[identifier] = item
    }

    public func removeMetadata(for identifier: FileProviderItemIdentifier) {
        metadataStore.removeValue(forKey: identifier)
    }

    public func listChildren(parentIdentifier: FileProviderItemIdentifier) -> [FileProviderItemContract] {
        metadataStore.values
            .filter { $0.item.parentIdentifier == parentIdentifier }
            .map(\.item)
            .sorted { $0.filename.localizedCaseInsensitiveCompare($1.filename) == .orderedAscending }
    }

    public func allMetadata() -> [FileProviderCacheMetadata] {
        Array(metadataStore.values)
    }

    // MARK: - Eviction

    public func evaluateAndApplyEviction(
        policy: FileProviderEvictionPolicy,
        now: Date = Date(),
        baseStorageURL: URL? = nil
    ) -> [FileProviderCacheMetadata] {
        let items = Array(metadataStore.values)
        let toEvict = FileProviderEvictionRule.evaluateEviction(items: items, policy: policy, now: now)
        for item in toEvict {
            if let path = item.localRelativePath, let base = baseStorageURL {
                let fileURL = base.appendingPathComponent(path)
                try? FileManager.default.removeItem(at: fileURL)
            }
            if policy.evictMaterializedOnly {
                if var current = metadataStore[item.id] {
                    current.isMaterialized = false
                    current.localRelativePath = nil
                    metadataStore[item.id] = current
                }
            } else {
                metadataStore.removeValue(forKey: item.id)
            }
        }
        return toEvict
    }

    // MARK: - Changes & Anchors

    public func currentAnchor() -> FileProviderChangeAnchor {
        FileProviderChangeAnchor(generation: currentGeneration, timestamp: Date())
    }

    public func recordChange(
        itemIdentifier: FileProviderItemIdentifier,
        type: FileProviderChangeType,
        item: FileProviderItemContract?
    ) -> FileProviderChange {
        currentGeneration += 1
        let anchor = FileProviderChangeAnchor(generation: currentGeneration, timestamp: Date())
        let change = FileProviderChange(
            itemIdentifier: itemIdentifier,
            type: type,
            item: item,
            anchor: anchor
        )
        changeLog.append(change)
        // Keep changeLog bounded
        if changeLog.count > 1000 {
            changeLog.removeFirst(changeLog.count - 1000)
        }
        return change
    }

    public func changesSince(anchor: FileProviderChangeAnchor) -> [FileProviderChange] {
        changeLog.filter { $0.anchor > anchor }
    }

    // MARK: - Offline Operations

    public func queueOfflineOperation(
        hostID: UUID,
        type: FileProviderOfflineOperationType,
        sourcePath: RemotePath,
        targetPath: RemotePath? = nil,
        localTempRelativePath: String? = nil
    ) -> FileProviderOfflineOperation {
        let op = FileProviderOfflineOperation(
            sequenceNumber: sequenceCounter,
            hostID: hostID,
            type: type,
            sourcePath: sourcePath,
            targetPath: targetPath,
            localTempRelativePath: localTempRelativePath
        )
        sequenceCounter += 1
        offlineOperations[op.id] = op
        return op
    }

    public func pendingOfflineOperations(hostID: UUID) -> [FileProviderOfflineOperation] {
        offlineOperations.values
            .filter { $0.hostID == hostID && $0.status == .pending }
            .sorted { $0.sequenceNumber < $1.sequenceNumber }
    }

    public func updateOfflineOperationStatus(id: UUID, status: FileProviderOfflineOperationStatus) {
        guard var op = offlineOperations[id] else { return }
        op.status = status
        offlineOperations[id] = op
    }
}
