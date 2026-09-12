#if canImport(FileProvider)
import Foundation
import FileProvider
import ShhCore

public final class FileProviderEnumerator: NSObject, NSFileProviderEnumerator {
    private let containerItemIdentifier: NSFileProviderItemIdentifier
    private let domain: NSFileProviderDomain
    private let repositoryProvider: FileProviderRepositoryProvider
    private let cache: FileProviderMetadataCache
    private let hostID: UUID
    private var isInvalidated = false

    public init(
        containerItemIdentifier: NSFileProviderItemIdentifier,
        domain: NSFileProviderDomain,
        repositoryProvider: FileProviderRepositoryProvider,
        cache: FileProviderMetadataCache
    ) {
        self.containerItemIdentifier = containerItemIdentifier
        self.domain = domain
        self.repositoryProvider = repositoryProvider
        self.cache = cache
        self.hostID = UUID(uuidString: domain.identifier.rawValue) ?? UUID()
        super.init()
    }

    public func invalidate() {
        isInvalidated = true
    }

    public func enumerateItems(
        for observer: NSFileProviderEnumerationObserver,
        startingAt page: NSFileProviderPage
    ) {
        guard !isInvalidated else {
            observer.finishEnumerating(upTo: nil)
            return
        }

        let targetPath: RemotePath
        let parentContractID: FileProviderItemIdentifier

        if containerItemIdentifier == .rootContainer {
            targetPath = RemotePath("/")
            parentContractID = .root
        } else {
            let contractID = FileProviderItemIdentifier(rawValue: containerItemIdentifier.rawValue)
            targetPath = contractID.remotePath ?? RemotePath("/")
            parentContractID = contractID
        }

        Task {
            do {
                // Short-lived scoped repository access with 15s timeout
                let remoteFiles = try await repositoryProvider.withRepository(hostID: hostID, timeoutSeconds: 15.0) { repo in
                    try await repo.listDirectory(at: targetPath)
                }

                var items: [FileProviderItem] = []
                for remoteFile in remoteFiles {
                    let contract = FileProviderItemContract(remoteFile: remoteFile, hostID: hostID)
                    await cache.storeMetadata(FileProviderCacheMetadata(
                        hostID: hostID,
                        remotePath: remoteFile.path,
                        item: contract,
                        fileSizeBytes: remoteFile.size,
                        isMaterialized: false
                    ))
                    items.append(FileProviderItem(contract: contract))
                }

                observer.didEnumerate(items)
                observer.finishEnumerating(upTo: nil)
            } catch {
                // Fallback to bounded local cache
                let cachedChildren = await cache.listChildren(parentIdentifier: parentContractID)
                if !cachedChildren.isEmpty {
                    let items = cachedChildren.map { FileProviderItem(contract: $0) }
                    observer.didEnumerate(items)
                    observer.finishEnumerating(upTo: nil)
                } else {
                    observer.finishEnumeratingWithError(error)
                }
            }
        }
    }

    public func enumerateChanges(
        for observer: NSFileProviderChangeObserver,
        from anchor: NSFileProviderSyncAnchor
    ) {
        guard !isInvalidated else {
            observer.finishEnumeratingChanges(upTo: anchor, moreComing: false)
            return
        }

        Task {
            let changeAnchor = FileProviderChangeAnchor.decode(from: anchor.rawValue) ?? FileProviderChangeAnchor(generation: 0)
            let changes = await cache.changesSince(anchor: changeAnchor)

            var updatedItems: [FileProviderItem] = []
            var deletedIDs: [NSFileProviderItemIdentifier] = []

            for change in changes {
                switch change.type {
                case .added, .updated:
                    if let itemContract = change.item {
                        updatedItems.append(FileProviderItem(contract: itemContract))
                    }
                case .deleted:
                    deletedIDs.append(NSFileProviderItemIdentifier(change.itemIdentifier.rawValue))
                }
            }

            if !updatedItems.isEmpty {
                observer.didUpdate(updatedItems)
            }
            if !deletedIDs.isEmpty {
                observer.didDeleteItems(withIdentifiers: deletedIDs)
            }

            let newAnchor = await cache.currentAnchor()
            let newSyncAnchor = NSFileProviderSyncAnchor(newAnchor.encodedData())
            observer.finishEnumeratingChanges(upTo: newSyncAnchor, moreComing: false)
        }
    }

    public func currentSyncAnchor(completionHandler: @escaping (NSFileProviderSyncAnchor?) -> Void) {
        Task {
            let anchor = await cache.currentAnchor()
            completionHandler(NSFileProviderSyncAnchor(anchor.encodedData()))
        }
    }
}
#endif
