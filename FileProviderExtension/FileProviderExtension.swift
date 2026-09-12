#if canImport(FileProvider)
import Foundation
import FileProvider
import UniformTypeIdentifiers
import ShhCore
import ShhSSH

public class FileProviderExtension: NSObject, NSFileProviderReplicatedExtension {
    public let domain: NSFileProviderDomain
    public let hostID: UUID
    private let repositoryProvider: FileProviderRepositoryProvider
    private let cache: FileProviderMetadataCache
    private let storage: FileProviderStorageManager
    private var isInvalidated = false

    public required init(domain: NSFileProviderDomain) {
        self.domain = domain
        self.hostID = UUID(uuidString: domain.identifier.rawValue) ?? UUID()
        self.repositoryProvider = LiveFileProviderRepositoryProvider()
        self.cache = FileProviderMetadataCache()
        self.storage = FileProviderStorageManager.shared
        super.init()
    }

    /// Internal initializer for injection in tests.
    public init(
        domain: NSFileProviderDomain,
        repositoryProvider: FileProviderRepositoryProvider,
        cache: FileProviderMetadataCache = FileProviderMetadataCache(),
        storage: FileProviderStorageManager = FileProviderStorageManager.shared
    ) {
        self.domain = domain
        self.hostID = UUID(uuidString: domain.identifier.rawValue) ?? UUID()
        self.repositoryProvider = repositoryProvider
        self.cache = cache
        self.storage = storage
        super.init()
    }

    public func invalidate() {
        isInvalidated = true
    }

    // MARK: - Item Metadata Lookup

    public func item(
        for identifier: NSFileProviderItemIdentifier,
        request: NSFileProviderRequest,
        completionHandler: @escaping (NSFileProviderItem?, (any Error)?) -> Void
    ) -> Progress {
        let progress = Progress(totalUnitCount: 1)

        if identifier == .rootContainer {
            let root = FileProviderItemContract.rootItem(hostID: hostID, hostName: domain.displayName)
            completionHandler(FileProviderItem(contract: root), nil)
            progress.completedUnitCount = 1
            return progress
        }

        let contractID = FileProviderItemIdentifier(rawValue: identifier.rawValue)
        guard let remotePath = contractID.remotePath else {
            completionHandler(nil, NSFileProviderError(.noSuchItem))
            return progress
        }

        let task = Task {
            // Check cache first
            if let cached = await cache.getMetadata(for: contractID) {
                await cache.recordAccess(for: contractID)
                completionHandler(FileProviderItem(contract: cached.item), nil)
                progress.completedUnitCount = 1
                return
            }

            // Scoped fetch with short timeout
            do {
                let remoteFile = try await repositoryProvider.withRepository(hostID: hostID, timeoutSeconds: 10.0) { repo in
                    try await repo.fetchAttributes(at: remotePath)
                }
                let contract = FileProviderItemContract(remoteFile: remoteFile, hostID: hostID)
                await cache.storeMetadata(FileProviderCacheMetadata(
                    hostID: hostID,
                    remotePath: remotePath,
                    item: contract,
                    fileSizeBytes: remoteFile.size,
                    isMaterialized: false
                ))
                completionHandler(FileProviderItem(contract: contract), nil)
            } catch {
                completionHandler(nil, NSFileProviderError(.noSuchItem))
            }
            progress.completedUnitCount = 1
        }

        progress.cancellationHandler = {
            task.cancel()
        }

        return progress
    }

    // MARK: - Content Materialization (Download)

    public func fetchContents(
        for itemIdentifier: NSFileProviderItemIdentifier,
        version requestedVersion: NSFileProviderItemVersion?,
        request: NSFileProviderRequest,
        completionHandler: @escaping (URL?, (any NSFileProviderItem)?, (any Error)?) -> Void
    ) -> Progress {
        let progress = Progress(totalUnitCount: 100)
        let contractID = FileProviderItemIdentifier(rawValue: itemIdentifier.rawValue)
        guard let remotePath = contractID.remotePath else {
            completionHandler(nil, nil, NSFileProviderError(.noSuchItem))
            return progress
        }

        let targetLocalURL = storage.temporaryFileURL(prefix: "materialize")

        let task = Task {
            do {
                try await repositoryProvider.withRepository(hostID: hostID, timeoutSeconds: 60.0) { repo in
                    try await repo.download(from: remotePath, to: targetLocalURL) { transferProgress in
                        progress.completedUnitCount = Int64(transferProgress.fractionCompleted * 100.0)
                    }
                }

                // Update cache record
                if var metadata = await cache.getMetadata(for: contractID) {
                    metadata.isMaterialized = true
                    metadata.localRelativePath = targetLocalURL.lastPathComponent
                    metadata.lastAccessDate = Date()
                    await cache.storeMetadata(metadata)
                    completionHandler(targetLocalURL, FileProviderItem(contract: metadata.item), nil)
                } else {
                    let remoteFile = try await repositoryProvider.withRepository(hostID: hostID, timeoutSeconds: 10.0) { repo in
                        try await repo.fetchAttributes(at: remotePath)
                    }
                    let contract = FileProviderItemContract(remoteFile: remoteFile, hostID: hostID)
                    completionHandler(targetLocalURL, FileProviderItem(contract: contract), nil)
                }
            } catch {
                completionHandler(nil, nil, error)
            }
        }

        progress.cancellationHandler = {
            task.cancel()
            try? FileManager.default.removeItem(at: targetLocalURL)
        }

        return progress
    }

    // MARK: - Create Item

    public func createItem(
        basedOn itemTemplate: NSFileProviderItem,
        fields: NSFileProviderItemFields,
        contents url: URL?,
        options: NSFileProviderCreateItemOptions = [],
        request: NSFileProviderRequest,
        completionHandler: @escaping ((any NSFileProviderItem)?, NSFileProviderItemFields, Bool, (any Error)?) -> Void
    ) -> Progress {
        let progress = Progress(totalUnitCount: 100)
        let parentID = FileProviderItemIdentifier(rawValue: itemTemplate.parentItemIdentifier.rawValue)
        let parentPath = parentID.remotePath ?? RemotePath("/")
        let itemPath = parentPath.appending(itemTemplate.filename)
        let isDirectory = itemTemplate.contentType == .folder

        let task = Task {
            do {
                if isDirectory {
                    try await repositoryProvider.withRepository(hostID: hostID, timeoutSeconds: 15.0) { repo in
                        try await repo.createDirectory(at: itemPath)
                    }
                } else if let url {
                    try await repositoryProvider.withRepository(hostID: hostID, timeoutSeconds: 60.0) { repo in
                        try await repo.upload(from: url, to: itemPath) { transferProgress in
                            progress.completedUnitCount = Int64(transferProgress.fractionCompleted * 100.0)
                        }
                    }
                }

                let contractID = FileProviderItemIdentifier(hostID: hostID, remotePath: itemPath)
                let itemContract = FileProviderItemContract(
                    identifier: contractID,
                    parentIdentifier: parentID,
                    filename: itemTemplate.filename,
                    isDirectory: isDirectory,
                    size: (try? url?.resourceValues(forKeys: [.fileSizeKey]).fileSize).map(Int64.init) ?? 0,
                    creationDate: Date(),
                    contentModificationDate: Date(),
                    contentTypeIdentifier: itemTemplate.contentType?.identifier ?? (isDirectory ? "public.folder" : "public.data")
                )

                await cache.storeMetadata(FileProviderCacheMetadata(
                    hostID: hostID,
                    remotePath: itemPath,
                    item: itemContract,
                    fileSizeBytes: itemContract.size,
                    isMaterialized: url != nil
                ))

                _ = await cache.recordChange(itemIdentifier: contractID, type: .added, item: itemContract)

                let item = FileProviderItem(contract: itemContract)
                completionHandler(item, [], false, nil)
            } catch {
                completionHandler(nil, [], false, error)
            }
        }

        progress.cancellationHandler = {
            task.cancel()
        }

        return progress
    }

    // MARK: - Modify Item

    public func modifyItem(
        _ item: NSFileProviderItem,
        baseVersion version: NSFileProviderItemVersion,
        changedFields: NSFileProviderItemFields,
        contents newContents: URL?,
        options: NSFileProviderModifyItemOptions = [],
        request: NSFileProviderRequest,
        completionHandler: @escaping ((any NSFileProviderItem)?, NSFileProviderItemFields, Bool, (any Error)?) -> Void
    ) -> Progress {
        let progress = Progress(totalUnitCount: 100)
        let contractID = FileProviderItemIdentifier(rawValue: item.itemIdentifier.rawValue)
        guard let remotePath = contractID.remotePath else {
            completionHandler(nil, [], false, NSFileProviderError(.noSuchItem))
            return progress
        }

        let task = Task {
            do {
                if let newContents {
                    try await repositoryProvider.withRepository(hostID: hostID, timeoutSeconds: 60.0) { repo in
                        try await repo.upload(from: newContents, to: remotePath) { transferProgress in
                            progress.completedUnitCount = Int64(transferProgress.fractionCompleted * 100.0)
                        }
                    }
                }

                if var metadata = await cache.getMetadata(for: contractID) {
                    metadata.item.contentModificationDate = Date()
                    if let newContents, let size = try? newContents.resourceValues(forKeys: [.fileSizeKey]).fileSize {
                        metadata.item.size = Int64(size)
                        metadata.fileSizeBytes = Int64(size)
                    }
                    await cache.storeMetadata(metadata)
                    _ = await cache.recordChange(itemIdentifier: contractID, type: .updated, item: metadata.item)
                    completionHandler(FileProviderItem(contract: metadata.item), [], false, nil)
                } else {
                    let remoteFile = try await repositoryProvider.withRepository(hostID: hostID, timeoutSeconds: 10.0) { repo in
                        try await repo.fetchAttributes(at: remotePath)
                    }
                    let contract = FileProviderItemContract(remoteFile: remoteFile, hostID: hostID)
                    completionHandler(FileProviderItem(contract: contract), [], false, nil)
                }
            } catch {
                completionHandler(nil, [], false, error)
            }
        }

        progress.cancellationHandler = {
            task.cancel()
        }

        return progress
    }

    // MARK: - Delete Item

    public func deleteItem(
        identifier: NSFileProviderItemIdentifier,
        baseVersion version: NSFileProviderItemVersion,
        options: NSFileProviderDeleteItemOptions = [],
        request: NSFileProviderRequest,
        completionHandler: @escaping ((any Error)?) -> Void
    ) -> Progress {
        let progress = Progress(totalUnitCount: 1)
        let contractID = FileProviderItemIdentifier(rawValue: identifier.rawValue)
        guard let remotePath = contractID.remotePath else {
            completionHandler(NSFileProviderError(.noSuchItem))
            return progress
        }

        let task = Task {
            do {
                let metadata = await cache.getMetadata(for: contractID)
                let isDir = metadata?.item.isDirectory ?? false

                try await repositoryProvider.withRepository(hostID: hostID, timeoutSeconds: 15.0) { repo in
                    if isDir {
                        try await repo.removeDirectory(at: remotePath)
                    } else {
                        try await repo.removeFile(at: remotePath)
                    }
                }

                await cache.removeMetadata(for: contractID)
                _ = await cache.recordChange(itemIdentifier: contractID, type: .deleted, item: nil)
                completionHandler(nil)
            } catch {
                completionHandler(error)
            }
            progress.completedUnitCount = 1
        }

        progress.cancellationHandler = {
            task.cancel()
        }

        return progress
    }

    // MARK: - Enumerator Factory

    public func enumerator(
        for containerItemIdentifier: NSFileProviderItemIdentifier,
        request: NSFileProviderRequest
    ) throws -> NSFileProviderEnumerator {
        FileProviderEnumerator(
            containerItemIdentifier: containerItemIdentifier,
            domain: domain,
            repositoryProvider: repositoryProvider,
            cache: cache
        )
    }
}
#endif
