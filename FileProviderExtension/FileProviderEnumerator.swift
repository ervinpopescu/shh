#if canImport(FileProvider)
import Foundation
import FileProvider
import ShhCore

/// Thread-safe enumeration observer wrapper guaranteeing callbacks are called at most once.
final class SafeEnumerationObserver: @unchecked Sendable {
    private let lock = NSLock()
    private var didFinish = false
    private let observer: NSFileProviderEnumerationObserver

    init(_ observer: NSFileProviderEnumerationObserver) {
        self.observer = observer
    }

    func didEnumerate(_ items: [NSFileProviderItemProtocol]) {
        lock.lock()
        let canCall = !didFinish
        lock.unlock()
        if canCall {
            observer.didEnumerate(items)
        }
    }

    func finishEnumerating(upTo page: NSFileProviderPage?) {
        lock.lock()
        if didFinish {
            lock.unlock()
            return
        }
        didFinish = true
        lock.unlock()
        observer.finishEnumerating(upTo: page)
    }

    func finishEnumeratingWithError(_ error: Error) {
        lock.lock()
        if didFinish {
            lock.unlock()
            return
        }
        didFinish = true
        lock.unlock()
        observer.finishEnumeratingWithError(error)
    }
}

/// Thread-safe change observer wrapper guaranteeing callbacks are called at most once.
final class SafeChangeObserver: @unchecked Sendable {
    private let lock = NSLock()
    private var didFinish = false
    private let observer: NSFileProviderChangeObserver

    init(_ observer: NSFileProviderChangeObserver) {
        self.observer = observer
    }

    func didUpdate(_ items: [NSFileProviderItemProtocol]) {
        lock.lock()
        let canCall = !didFinish
        lock.unlock()
        if canCall {
            observer.didUpdate(items)
        }
    }

    func didDeleteItems(withIdentifiers identifiers: [NSFileProviderItemIdentifier]) {
        lock.lock()
        let canCall = !didFinish
        lock.unlock()
        if canCall {
            observer.didDeleteItems(withIdentifiers: identifiers)
        }
    }

    func finishEnumeratingChanges(upTo anchor: NSFileProviderSyncAnchor, moreComing: Bool) {
        lock.lock()
        if didFinish {
            lock.unlock()
            return
        }
        didFinish = true
        lock.unlock()
        observer.finishEnumeratingChanges(upTo: anchor, moreComing: moreComing)
    }

    func finishEnumeratingWithError(_ error: Error) {
        lock.lock()
        if didFinish {
            lock.unlock()
            return
        }
        didFinish = true
        lock.unlock()
        observer.finishEnumeratingWithError(error)
    }
}

@objc(FileProviderEnumerator)
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
        let safeObserver = SafeEnumerationObserver(observer)
        guard !isInvalidated else {
            safeObserver.finishEnumerating(upTo: nil)
            return
        }

        if containerItemIdentifier == .workingSet {
            Task {
                guard !self.isInvalidated else {
                    safeObserver.finishEnumerating(upTo: nil)
                    return
                }
                let materialized = await cache.allMetadata().filter(\.isMaterialized).map { FileProviderItem(contract: $0.item) }
                safeObserver.didEnumerate(materialized)
                safeObserver.finishEnumerating(upTo: nil)
            }
            return
        }

        if containerItemIdentifier == .trashContainer {
            safeObserver.didEnumerate([])
            safeObserver.finishEnumerating(upTo: nil)
            return
        }

        let isRoot = containerItemIdentifier == .rootContainer ||
            containerItemIdentifier.rawValue == NSFileProviderItemIdentifier.rootContainer.rawValue ||
            containerItemIdentifier.rawValue == FileProviderItemIdentifier.root.rawValue ||
            containerItemIdentifier.rawValue == "NSFileProviderRootContainerItemIdentifier"

        let targetPath: RemotePath
        let parentContractID: FileProviderItemIdentifier

        if isRoot {
            targetPath = RemotePath("/")
            parentContractID = .root
        } else {
            let contractID = FileProviderItemIdentifier(rawValue: containerItemIdentifier.rawValue)
            guard let path = contractID.remotePath else {
                safeObserver.finishEnumeratingWithError(NSFileProviderError(.noSuchItem))
                return
            }
            targetPath = path
            parentContractID = contractID
        }

        Task {
            guard !self.isInvalidated else {
                safeObserver.finishEnumerating(upTo: nil)
                return
            }

            do {
                // Short-lived scoped repository access with 15s timeout
                let remoteFiles = try await repositoryProvider.withRepository(hostID: hostID, timeoutSeconds: 15.0) { repo in
                    try await repo.listDirectory(at: targetPath)
                }

                guard !self.isInvalidated else {
                    safeObserver.finishEnumerating(upTo: nil)
                    return
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

                safeObserver.didEnumerate(items)
                safeObserver.finishEnumerating(upTo: nil)
            } catch {
                guard !self.isInvalidated else {
                    safeObserver.finishEnumerating(upTo: nil)
                    return
                }

                // Fallback to bounded local cache
                let cachedChildren = await cache.listChildren(parentIdentifier: parentContractID)
                if !cachedChildren.isEmpty {
                    let items = cachedChildren.map { FileProviderItem(contract: $0) }
                    safeObserver.didEnumerate(items)
                    safeObserver.finishEnumerating(upTo: nil)
                } else {
                    safeObserver.finishEnumeratingWithError(Self.translateError(error))
                }
            }
        }
    }

    public func enumerateChanges(
        for observer: NSFileProviderChangeObserver,
        from anchor: NSFileProviderSyncAnchor
    ) {
        let safeObserver = SafeChangeObserver(observer)
        guard !isInvalidated else {
            safeObserver.finishEnumeratingChanges(upTo: anchor, moreComing: false)
            return
        }

        Task {
            guard !self.isInvalidated else {
                safeObserver.finishEnumeratingChanges(upTo: anchor, moreComing: false)
                return
            }

            let changeAnchor = FileProviderChangeAnchor.decode(from: anchor.rawValue) ?? FileProviderChangeAnchor(generation: 0)
            let currentAnchor = await cache.currentAnchor()

            // If anchor generation is in the future, signal expired sync anchor
            if changeAnchor.generation > currentAnchor.generation {
                safeObserver.finishEnumeratingWithError(NSFileProviderError(.syncAnchorExpired))
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

            guard !self.isInvalidated else {
                safeObserver.finishEnumeratingChanges(upTo: anchor, moreComing: false)
                return
            }

            if !updatedItems.isEmpty {
                safeObserver.didUpdate(updatedItems)
            }
            if !deletedIDs.isEmpty {
                safeObserver.didDeleteItems(withIdentifiers: deletedIDs)
            }

            let newSyncAnchor = NSFileProviderSyncAnchor(currentAnchor.encodedData())
            safeObserver.finishEnumeratingChanges(upTo: newSyncAnchor, moreComing: false)
        }
    }

    public func currentSyncAnchor(completionHandler: @escaping (NSFileProviderSyncAnchor?) -> Void) {
        let safeCompletion = SafeOnceCompletion(completionHandler)
        Task {
            let anchor = await cache.currentAnchor()
            safeCompletion(NSFileProviderSyncAnchor(anchor.encodedData()))
        }
    }

    private static func translateError(_ error: any Error) -> Error {
        if let fpError = error as? NSFileProviderError {
            return fpError
        }
        if error is CancellationError {
            return NSError(domain: NSCocoaErrorDomain, code: NSUserCancelledError, userInfo: nil)
        }
        let nsError = error as NSError
        if nsError.domain == NSFileProviderErrorDomain || nsError.domain == NSCocoaErrorDomain {
            return error
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
            case .networkUnavailable, .timeout, .dnsFailure, .connectionRefused:
                return NSFileProviderError(.serverUnreachable)
            case .authenticationRequired, .hostKeyChanged, .hostKeyApprovalRequired, .missingCredential, .invalidPrivateKey:
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
