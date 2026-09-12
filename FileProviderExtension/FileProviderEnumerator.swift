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

        if containerItemIdentifier == .workingSet {
            Task {
                let materialized = await cache.allMetadata().filter(\.isMaterialized).map { FileProviderItem(contract: $0.item) }
                observer.didEnumerate(materialized)
                observer.finishEnumerating(upTo: nil)
            }
            return
        }

        if containerItemIdentifier == .trashContainer {
            observer.didEnumerate([])
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
                    observer.finishEnumeratingWithError(Self.translateError(error))
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
            let currentAnchor = await cache.currentAnchor()

            // If anchor generation is in the future, signal expired sync anchor
            if changeAnchor.generation > currentAnchor.generation {
                observer.finishEnumeratingWithError(NSFileProviderError(.syncAnchorExpired))
                return
            }

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

            let newSyncAnchor = NSFileProviderSyncAnchor(currentAnchor.encodedData())
            observer.finishEnumeratingChanges(upTo: newSyncAnchor, moreComing: false)
        }
    }

    public func currentSyncAnchor(completionHandler: @escaping (NSFileProviderSyncAnchor?) -> Void) {
        Task {
            let anchor = await cache.currentAnchor()
            completionHandler(NSFileProviderSyncAnchor(anchor.encodedData()))
        }
    }

    private static func translateError(_ error: any Error) -> Error {
        if let fpError = error as? NSFileProviderError {
            return fpError
        }
        if let sftpError = error as? SFTPRepositoryError {
            switch sftpError {
            case .notFound:
                return NSFileProviderError(.noSuchItem)
            case .permissionDenied:
                return NSFileProviderError(.notAuthenticated)
            case .alreadyExists:
                return NSFileProviderError(.filenameCollision)
            case .connectionClosed:
                return NSFileProviderError(.serverUnreachable)
            case .invalidPath:
                return NSError(domain: NSCocoaErrorDomain, code: NSFileWriteInvalidFileNameError, userInfo: nil)
            case .cancelled:
                return NSError(domain: NSCocoaErrorDomain, code: NSUserCancelledError, userInfo: nil)
            case .isDirectory, .notADirectory, .directoryNotEmpty, .remoteFailure:
                return NSFileProviderError(.serverUnreachable)
            }
        }
        if let transportError = error as? TransportError {
            switch transportError {
            case .networkUnavailable, .timeout:
                return NSFileProviderError(.serverUnreachable)
            case .authenticationRequired, .hostKeyChanged, .hostKeyApprovalRequired:
                return NSFileProviderError(.notAuthenticated)
            case .cancelled:
                return NSError(domain: NSCocoaErrorDomain, code: NSUserCancelledError, userInfo: nil)
            case .invalidConfiguration, .unsupported:
                return NSError(domain: NSCocoaErrorDomain, code: NSFeatureUnsupportedError, userInfo: nil)
            case .remoteFailure:
                return NSFileProviderError(.serverUnreachable)
            }
        }
        return error
    }
}
#endif
