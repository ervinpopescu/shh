import XCTest
@testable import Shh
import ShhCore
import ShhSSH
#if canImport(FileProvider)
import FileProvider
#endif

@MainActor
final class FileProviderAppTests: XCTestCase {

    private func isolatedPersistenceHelper() throws -> (FileProviderManagerHelper, URL) {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("ShhPersistenceTest_\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let helper = FileProviderManagerHelper(
            localContainerURL: root,
            containerURLResolver: { _ in nil }
        )
        return (helper, root)
    }

    func testAppGroupUnavailableLoadsLocalFallback() async throws {
        let (helper, root) = try isolatedPersistenceHelper()
        defer { try? FileManager.default.removeItem(at: root) }
        let host = try Host(name: "Recovered Host", hostname: "recovered.invalid", username: "user")
        try helper.syncLocalState(snapshot: CatalogSnapshot(hosts: [host]))

        XCTAssertFalse(helper.isSharedContainerAvailable)
        let result = helper.loadCatalogSnapshot()
        XCTAssertEqual(result.state, .valid)
        XCTAssertEqual(result.snapshot?.hosts.map(\.id), [host.id])
    }

    func testInvalidPersistedCatalogIsNotOverwrittenByStartup() async throws {
        let (helper, root) = try isolatedPersistenceHelper()
        defer { try? FileManager.default.removeItem(at: root) }
        let snapshotURL = root.appendingPathComponent("catalogs/snapshot.json")
        try FileManager.default.createDirectory(at: snapshotURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        let original = Data("not a catalog".utf8)
        try original.write(to: snapshotURL)

        _ = AppContainer(transport: LiveSSHTransport(), fileProviderHelper: helper)
        try await Task.sleep(nanoseconds: 100_000_000)
        XCTAssertEqual(try Data(contentsOf: snapshotURL), original)
    }

    func testProductionConstructionDoesNotSeedDemoCatalog() async throws {
        let (helper, root) = try isolatedPersistenceHelper()
        defer { try? FileManager.default.removeItem(at: root) }
        let container = AppContainer(transport: DemoSSHTransport(), fileProviderHelper: helper)
        let hosts = try await container.catalog.listHosts()
        XCTAssertTrue(hosts.isEmpty, "Only AppContainer.demo may seed Demo Workbox")
    }

    func testCandidateSnapshotRoundTripsWithoutCredentialMaterial() async throws {
        let identity = try IdentityDescriptor(name: "Recovered identity", kind: .privateKey, keychainReference: "opaque-reference")
        let host = try Host(name: "Hetzner", hostname: "recovered.invalid", username: "user", identityID: identity.id)
        let record = TrustRecord(hostname: host.hostname, port: host.port, keyAlgorithm: "ssh-ed25519", sha256Fingerprint: "SHA256:redacted-test")
        let snapshot = CatalogSnapshot(hosts: [host], identities: [identity])
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let decoded = try decoder.decode(CatalogSnapshot.self, from: encoder.encode(snapshot))
        XCTAssertEqual(decoded.hosts.first?.name.lowercased(), "hetzner")
        XCTAssertEqual(decoded.identities.first?.keychainReference, "opaque-reference")
        XCTAssertEqual(record.lookupKey, "recovered.invalid:22:ssh-ed25519")

        let mergedCatalog = InMemoryCatalog(snapshot: CatalogSnapshot())
        await mergedCatalog.merge(with: decoded)
        let mergedHostIDs = try await mergedCatalog.listHosts().map(\.id)
        let mergedIdentityIDs = try await mergedCatalog.identities().map(\.id)
        XCTAssertEqual(mergedHostIDs, [host.id])
        XCTAssertEqual(mergedIdentityIDs, [identity.id])
        let mergedTrust = InMemoryTrustStore(records: [record])
        let mergedTrustRecords = await mergedTrust.allRecords()
        XCTAssertEqual(mergedTrustRecords.count, 1)
    }

    func testHostRemainsWhenReferencedCredentialIsMissing() async throws {
        let identity = try IdentityDescriptor(name: "Missing identity", kind: .privateKey, keychainReference: "missing-reference")
        let host = try Host(name: "Preserved Host", hostname: "preserved.invalid", username: "user", identityID: identity.id)
        let catalog = InMemoryCatalog(snapshot: CatalogSnapshot(hosts: [host], identities: [identity]))
        let container = AppContainer(catalog: catalog, credentialStore: InMemoryCredentialStore(), transport: DemoSSHTransport())
        let hosts = try await container.catalog.listHosts()
        XCTAssertEqual(hosts.map(\.id), [host.id])
        let identityIDs = try await container.catalog.identities().map(\.id)
        XCTAssertEqual(identityIDs, [identity.id])
    }

    func testVaultBackupAndRestoreFromAppContainerCatalog() async throws {
        let repo = DemoSFTPRepository(seedDemoData: true)
        let container = AppContainer.demo(sftpRepository: repo)

        let snapshot = await container.catalog.snapshot()
        XCTAssertFalse(snapshot.hosts.isEmpty, "Demo catalog should have hosts")

        let vaultService = EncryptedVaultService()
        var preferences = VaultPreferences()
        preferences.voiceProvider = container.selectedProviderDisplayName

        let passphrase = "app-container-vault-test-passphrase"
        let backupData = try vaultService.exportBackupData(
            catalog: snapshot,
            preferences: preferences,
            passphrase: passphrase,
            options: VaultExportOptions(iterations: 10_000)
        )

        XCTAssertFalse(backupData.isEmpty)

        // Restore
        let restored = try vaultService.restoreBackup(data: backupData, passphrase: passphrase)
        XCTAssertEqual(restored.catalog.hosts.count, snapshot.hosts.count)
        XCTAssertEqual(restored.preferences.voiceProvider, container.selectedProviderDisplayName)

        // Verify wrong passphrase rejection
        XCTAssertThrowsError(try vaultService.restoreBackup(data: backupData, passphrase: "wrong")) { error in
            XCTAssertEqual(error as? VaultBackupError, .authenticationFailed)
        }
    }

    func testFileProviderManagerHelperSharedCatalogExport() async throws {
        #if canImport(FileProvider)
        let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent("FPTest_\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }
        let helper = FileProviderManagerHelper(
            appGroupIdentifier: "group.com.ervinpopescu.shh",
            containerURL: tempDir
        )
        let catalog = InMemoryCatalog(seedDemoData: true)
        let snapshot = await catalog.snapshot()

        // Should not throw even if App Group directory is sandboxed/unavailable in host test
        XCTAssertNoThrow(try helper.exportCatalogToSharedContainer(snapshot: snapshot))
        #endif
    }

    func testFileProviderItemContractMapping() async throws {
        let hostID = UUID()
        let path = RemotePath("/var/log/system.log")
        let remoteFile = RemoteFile(
            id: path.description,
            name: path.lastComponent,
            path: path,
            entryType: .file,
            size: 2048,
            permissions: PosixPermissions(octal: 0o644),
            modificationDate: Date()
        )

        let contract = FileProviderItemContract(remoteFile: remoteFile, hostID: hostID)
        XCTAssertEqual(contract.filename, "system.log")
        XCTAssertEqual(contract.size, 2048)
        XCTAssertEqual(contract.contentTypeIdentifier, "public.plain-text")
        XCTAssertFalse(contract.isDirectory)
        XCTAssertEqual(contract.parentIdentifier.remotePath?.description, "/var/log")

        #if canImport(FileProvider)
        let item = FileProviderItem(contract: contract)
        XCTAssertEqual(item.filename, "system.log")
        XCTAssertEqual(item.documentSize?.int64Value, 2048)
        XCTAssertEqual(item.capabilities.contains(.allowsReading), true)
        XCTAssertEqual(item.capabilities.contains(.allowsWriting), true)
        #endif
    }

    func testDemoRepositoryProviderShortLivedExecution() async throws {
        #if canImport(FileProvider)
        let demoRepo = DemoSFTPRepository(seedDemoData: true)
        let provider = DemoFileProviderRepositoryProvider(repository: demoRepo)
        let hostID = UUID()

        // Verify operation-scoped repository access completes and returns value
        let files = try await provider.withRepository(hostID: hostID, timeoutSeconds: 5.0) { repo in
            try await repo.listDirectory(at: RemotePath("/home/dev"))
        }

        XCTAssertFalse(files.isEmpty)
        XCTAssertTrue(files.contains { $0.name == "projects" })
        #endif
    }

    func testFileProviderItemParentIdentifierRootMapping() async throws {
        #if canImport(FileProvider)
        let hostID = UUID()

        // Root folder
        let rootFile = RemoteFile(
            id: "/",
            name: "/",
            path: RemotePath("/"),
            entryType: .directory,
            size: 4096,
            modificationDate: Date()
        )
        let rootContract = FileProviderItemContract(remoteFile: rootFile, hostID: hostID)
        let rootItem = FileProviderItem(contract: rootContract)
        XCTAssertEqual(rootItem.itemIdentifier, .rootContainer)
        XCTAssertEqual(rootItem.parentItemIdentifier, .rootContainer)

        // Top-level item (/etc)
        let etcFile = RemoteFile(
            id: "/etc",
            name: "etc",
            path: RemotePath("/etc"),
            entryType: .directory,
            size: 4096,
            modificationDate: Date()
        )
        let etcContract = FileProviderItemContract(remoteFile: etcFile, hostID: hostID)
        XCTAssertTrue(etcContract.parentIdentifier.isRoot)
        let etcItem = FileProviderItem(contract: etcContract)
        XCTAssertEqual(etcItem.parentItemIdentifier, .rootContainer)

        // Nested item (/etc/hosts)
        let hostsFile = RemoteFile(
            id: "/etc/hosts",
            name: "hosts",
            path: RemotePath("/etc/hosts"),
            entryType: .file,
            size: 256,
            modificationDate: Date()
        )
        let hostsContract = FileProviderItemContract(remoteFile: hostsFile, hostID: hostID)
        XCTAssertFalse(hostsContract.parentIdentifier.isRoot)
        let hostsItem = FileProviderItem(contract: hostsContract)
        XCTAssertNotEqual(hostsItem.parentItemIdentifier, .rootContainer)
        let expectedParentID = FileProviderItemIdentifier(hostID: hostID, remotePath: RemotePath("/etc"))
        XCTAssertEqual(hostsItem.parentItemIdentifier, NSFileProviderItemIdentifier(expectedParentID.rawValue))
        #endif
    }

    func testFileProviderEnumeratorWorkingSetAndTrash() async throws {
        #if canImport(FileProvider)
        let demoRepo = DemoSFTPRepository(seedDemoData: true)
        let provider = DemoFileProviderRepositoryProvider(repository: demoRepo)
        let cache = FileProviderMetadataCache()
        let hostID = UUID()
        let domain = NSFileProviderDomain(identifier: NSFileProviderDomainIdentifier(hostID.uuidString), displayName: "Test Domain")

        // Seed 1 materialized item and 1 non-materialized item in cache
        let matPath = RemotePath("/materialized.txt")
        let matFile = RemoteFile(id: matPath.description, name: "materialized.txt", path: matPath, entryType: .file, size: 100, modificationDate: Date())
        let matContract = FileProviderItemContract(remoteFile: matFile, hostID: hostID)
        await cache.storeMetadata(FileProviderCacheMetadata(
            hostID: hostID,
            remotePath: matPath,
            item: matContract,
            fileSizeBytes: 100,
            isMaterialized: true
        ))

        let nonMatPath = RemotePath("/cloud.txt")
        let nonMatFile = RemoteFile(id: nonMatPath.description, name: "cloud.txt", path: nonMatPath, entryType: .file, size: 200, modificationDate: Date())
        let nonMatContract = FileProviderItemContract(remoteFile: nonMatFile, hostID: hostID)
        await cache.storeMetadata(FileProviderCacheMetadata(
            hostID: hostID,
            remotePath: nonMatPath,
            item: nonMatContract,
            fileSizeBytes: 200,
            isMaterialized: false
        ))

        // Working set enumeration test
        final class TestObserver: NSObject, NSFileProviderEnumerationObserver, @unchecked Sendable {
            var items: [NSFileProviderItem] = []
            var finished = false
            var error: Error?

            func didEnumerate(_ updatedItems: [NSFileProviderItemProtocol]) {
                items.append(contentsOf: updatedItems.compactMap { $0 as? NSFileProviderItem })
            }
            func finishEnumerating(upTo page: NSFileProviderPage?) {
                finished = true
            }
            func finishEnumeratingWithError(_ error: Error) {
                self.error = error
                finished = true
            }
        }

        let workingSetEnumerator = FileProviderEnumerator(
            containerItemIdentifier: .workingSet,
            domain: domain,
            repositoryProvider: provider,
            cache: cache
        )
        let wsObserver = TestObserver()
        workingSetEnumerator.enumerateItems(for: wsObserver, startingAt: NSFileProviderPage(Data()))

        // Allow background Task to execute
        try await Task.sleep(nanoseconds: 50_000_000)
        XCTAssertTrue(wsObserver.finished)
        XCTAssertEqual(wsObserver.items.count, 1)
        XCTAssertEqual(wsObserver.items.first?.filename, "materialized.txt")

        // Trash container enumeration test
        let trashEnumerator = FileProviderEnumerator(
            containerItemIdentifier: .trashContainer,
            domain: domain,
            repositoryProvider: provider,
            cache: cache
        )
        let trashObserver = TestObserver()
        trashEnumerator.enumerateItems(for: trashObserver, startingAt: NSFileProviderPage(Data()))
        XCTAssertTrue(trashObserver.finished)
        XCTAssertTrue(trashObserver.items.isEmpty)
        #endif
    }

    func testFileProviderCreateItemTraversalRejection() async throws {
        #if canImport(FileProvider)
        let demoRepo = DemoSFTPRepository(seedDemoData: true)
        let provider = DemoFileProviderRepositoryProvider(repository: demoRepo)
        let hostID = UUID()
        let domain = NSFileProviderDomain(identifier: NSFileProviderDomainIdentifier(hostID.uuidString), displayName: "Test Domain")
        let extensionInstance = FileProviderExtension(domain: domain, repositoryProvider: provider)

        // Attempt creation with path traversal in filename
        let maliciousItem = FileProviderItem(contract: FileProviderItemContract(
            identifier: FileProviderItemIdentifier.root,
            parentIdentifier: .root,
            filename: "../../etc/shadow",
            isDirectory: false,
            size: 0,
            contentTypeIdentifier: "public.data"
        ))

        let expectation = expectation(description: "Create item traversal rejected")
        _ = extensionInstance.createItem(
            basedOn: maliciousItem,
            fields: [],
            contents: nil,
            request: NSFileProviderRequest()
        ) { createdItem, fields, shouldFetch, error in
            XCTAssertNil(createdItem)
            XCTAssertNotNil(error)
            expectation.fulfill()
        }

        await fulfillment(of: [expectation], timeout: 5.0)
        #endif
    }

    func testFileProviderCreateItemEmptyFileCreation() async throws {
        #if canImport(FileProvider)
        let demoRepo = DemoSFTPRepository(seedDemoData: true)
        let provider = DemoFileProviderRepositoryProvider(repository: demoRepo)
        let hostID = UUID()
        let domain = NSFileProviderDomain(identifier: NSFileProviderDomainIdentifier(hostID.uuidString), displayName: "Test Domain")
        let extensionInstance = FileProviderExtension(domain: domain, repositoryProvider: provider)

        let newEmptyItem = FileProviderItem(contract: FileProviderItemContract(
            identifier: FileProviderItemIdentifier.root,
            parentIdentifier: .root,
            filename: "empty_new.txt",
            isDirectory: false,
            size: 0,
            contentTypeIdentifier: "public.plain-text"
        ))

        let expectation = expectation(description: "Create empty file")
        _ = extensionInstance.createItem(
            basedOn: newEmptyItem,
            fields: [],
            contents: nil,
            request: NSFileProviderRequest()
        ) { createdItem, fields, shouldFetch, error in
            XCTAssertNil(error)
            XCTAssertNotNil(createdItem)
            XCTAssertEqual(createdItem?.filename, "empty_new.txt")
            expectation.fulfill()
        }

        await fulfillment(of: [expectation], timeout: 5.0)

        // Verify remote file was written
        let file = try? await demoRepo.fetchAttributes(at: RemotePath("/empty_new.txt"))
        XCTAssertNotNil(file)
        #endif
    }

    func testFileProviderModifyItemRename() async throws {
        #if canImport(FileProvider)
        let demoRepo = DemoSFTPRepository(seedDemoData: true)
        let provider = DemoFileProviderRepositoryProvider(repository: demoRepo)
        let hostID = UUID()
        let domain = NSFileProviderDomain(identifier: NSFileProviderDomainIdentifier(hostID.uuidString), displayName: "Test Domain")
        let extensionInstance = FileProviderExtension(domain: domain, repositoryProvider: provider)

        // First write an initial file
        let initialPath = RemotePath("/home/dev/projects/original.txt")
        try await demoRepo.writeFile(data: Data("original content".utf8), at: initialPath, progress: nil)

        let itemID = FileProviderItemIdentifier(hostID: hostID, remotePath: initialPath)
        let renamedItem = FileProviderItem(contract: FileProviderItemContract(
            identifier: itemID,
            parentIdentifier: itemID.parentIdentifier,
            filename: "renamed.txt",
            isDirectory: false,
            size: 16,
            contentTypeIdentifier: "public.plain-text"
        ))

        let expectation = expectation(description: "Modify rename item")
        var completionCount = 0
        _ = extensionInstance.modifyItem(
            renamedItem,
            baseVersion: renamedItem.itemVersion,
            changedFields: [.filename],
            contents: nil,
            request: NSFileProviderRequest()
        ) { modifiedItem, fields, shouldFetch, error in
            completionCount += 1
            XCTAssertNil(error)
            XCTAssertEqual(modifiedItem?.filename, "renamed.txt")
            expectation.fulfill()
        }

        await fulfillment(of: [expectation], timeout: 5.0)
        XCTAssertEqual(completionCount, 1, "Modify completion must be delivered exactly once")

        // Verify remote file was renamed
        let oldFile = try? await demoRepo.fetchAttributes(at: initialPath)
        let newFile = try? await demoRepo.fetchAttributes(at: RemotePath("/home/dev/projects/renamed.txt"))
        XCTAssertNil(oldFile)
        XCTAssertNotNil(newFile)
        #endif
    }

    func testFileProviderModifyItemTraversalRejection() async throws {
        #if canImport(FileProvider)
        let demoRepo = DemoSFTPRepository(seedDemoData: true)
        let provider = DemoFileProviderRepositoryProvider(repository: demoRepo)
        let hostID = UUID()
        let domain = NSFileProviderDomain(identifier: NSFileProviderDomainIdentifier(hostID.uuidString), displayName: "Test Domain")
        let extensionInstance = FileProviderExtension(domain: domain, repositoryProvider: provider)

        let initialPath = RemotePath("/home/dev/projects/stay_safe.txt")
        try await demoRepo.writeFile(data: Data("safe content".utf8), at: initialPath, progress: nil)

        let itemID = FileProviderItemIdentifier(hostID: hostID, remotePath: initialPath)
        let maliciousRenamedItem = FileProviderItem(contract: FileProviderItemContract(
            identifier: itemID,
            parentIdentifier: itemID.parentIdentifier,
            filename: "../traversal_escape.txt",
            isDirectory: false,
            size: 12,
            contentTypeIdentifier: "public.plain-text"
        ))

        let expectation = expectation(description: "Modify rename traversal rejected")
        var completionCount = 0
        _ = extensionInstance.modifyItem(
            maliciousRenamedItem,
            baseVersion: maliciousRenamedItem.itemVersion,
            changedFields: [.filename],
            contents: nil,
            request: NSFileProviderRequest()
        ) { modifiedItem, fields, shouldFetch, error in
            completionCount += 1
            XCTAssertNil(modifiedItem)
            let nsError = error as? NSError
            XCTAssertEqual(nsError?.domain, NSCocoaErrorDomain)
            XCTAssertEqual(nsError?.code, NSFileWriteInvalidFileNameError)
            expectation.fulfill()
        }

        await fulfillment(of: [expectation], timeout: 5.0)
        XCTAssertEqual(completionCount, 1, "Modify completion must be delivered exactly once")

        // Original file must remain intact
        let originalFile = try? await demoRepo.fetchAttributes(at: initialPath)
        XCTAssertNotNil(originalFile)
        #endif
    }

    func testFileProviderSyncAnchorExpiration() async throws {
        #if canImport(FileProvider)
        let demoRepo = DemoSFTPRepository(seedDemoData: true)
        let provider = DemoFileProviderRepositoryProvider(repository: demoRepo)
        let cache = FileProviderMetadataCache()
        let hostID = UUID()
        let domain = NSFileProviderDomain(identifier: NSFileProviderDomainIdentifier(hostID.uuidString), displayName: "Test Domain")

        let enumerator = FileProviderEnumerator(
            containerItemIdentifier: .rootContainer,
            domain: domain,
            repositoryProvider: provider,
            cache: cache
        )

        final class ChangeObserver: NSObject, NSFileProviderChangeObserver, @unchecked Sendable {
            var finished = false
            var error: Error?
            func didUpdate(_ updatedItems: [NSFileProviderItemProtocol]) {}
            func didDeleteItems(withIdentifiers deletedItemIdentifiers: [NSFileProviderItemIdentifier]) {}
            func finishEnumeratingChanges(upTo anchor: NSFileProviderSyncAnchor, moreComing: Bool) { finished = true }
            func finishEnumeratingWithError(_ error: Error) { self.error = error; finished = true }
        }

        // Anchor with future generation (e.g. generation 999 while current is 0)
        let futureAnchor = FileProviderChangeAnchor(generation: 999)
        let syncAnchor = NSFileProviderSyncAnchor(futureAnchor.encodedData())

        let observer = ChangeObserver()
        enumerator.enumerateChanges(for: observer, from: syncAnchor)

        try await Task.sleep(nanoseconds: 50_000_000)
        XCTAssertTrue(observer.finished)
        XCTAssertNotNil(observer.error)
        let nsError = observer.error as? NSError
        XCTAssertEqual(nsError?.code, NSFileProviderError.syncAnchorExpired.rawValue)
        #endif
    }

    func testFileProviderItemLookupRootContainer() async throws {
        #if canImport(FileProvider)
        let demoRepo = DemoSFTPRepository(seedDemoData: true)
        let provider = DemoFileProviderRepositoryProvider(repository: demoRepo)
        let hostID = UUID()
        let domain = NSFileProviderDomain(identifier: NSFileProviderDomainIdentifier(hostID.uuidString), displayName: "My Remote Server")
        let extensionInstance = FileProviderExtension(domain: domain, repositoryProvider: provider)

        // 1. Test .rootContainer
        let exp1 = expectation(description: "Fetch .rootContainer item")
        _ = extensionInstance.item(for: .rootContainer, request: NSFileProviderRequest()) { item, error in
            XCTAssertNil(error)
            XCTAssertNotNil(item)
            XCTAssertEqual(item?.itemIdentifier, .rootContainer)
            XCTAssertEqual(item?.parentItemIdentifier, .rootContainer)
            XCTAssertEqual(item?.filename, "My Remote Server")
            XCTAssertEqual(item?.contentType, .folder)
            exp1.fulfill()
        }

        // 2. Test raw string matching root identifier
        let exp2 = expectation(description: "Fetch raw root identifier")
        let rawRootID = NSFileProviderItemIdentifier(FileProviderItemIdentifier.root.rawValue)
        _ = extensionInstance.item(for: rawRootID, request: NSFileProviderRequest()) { item, error in
            XCTAssertNil(error)
            XCTAssertNotNil(item)
            XCTAssertEqual(item?.itemIdentifier, .rootContainer)
            XCTAssertEqual(item?.parentItemIdentifier, .rootContainer)
            XCTAssertEqual(item?.filename, "My Remote Server")
            exp2.fulfill()
        }

        await fulfillment(of: [exp1, exp2], timeout: 5.0)
        #endif
    }

    func testFileProviderEnumeratorRootContainer() async throws {
        #if canImport(FileProvider)
        let demoRepo = DemoSFTPRepository(seedDemoData: true)
        let provider = DemoFileProviderRepositoryProvider(repository: demoRepo)
        let cache = FileProviderMetadataCache()
        let hostID = UUID()
        let domain = NSFileProviderDomain(identifier: NSFileProviderDomainIdentifier(hostID.uuidString), displayName: "Test Domain")

        let enumerator = FileProviderEnumerator(
            containerItemIdentifier: .rootContainer,
            domain: domain,
            repositoryProvider: provider,
            cache: cache
        )

        final class EnumerationObserver: NSObject, NSFileProviderEnumerationObserver, @unchecked Sendable {
            var items: [NSFileProviderItemProtocol] = []
            var finished = false
            var error: Error?
            func didEnumerate(_ updatedItems: [NSFileProviderItemProtocol]) {
                items.append(contentsOf: updatedItems)
            }
            func finishEnumerating(upTo page: NSFileProviderPage?) {
                finished = true
            }
            func finishEnumeratingWithError(_ error: Error) {
                self.error = error
                finished = true
            }
        }

        let observer = EnumerationObserver()
        enumerator.enumerateItems(for: observer, startingAt: NSFileProviderPage(Data()))

        try await Task.sleep(nanoseconds: 100_000_000)
        XCTAssertTrue(observer.finished)
        XCTAssertNil(observer.error)
        XCTAssertFalse(observer.items.isEmpty)
        for item in observer.items {
            XCTAssertEqual(item.parentItemIdentifier, .rootContainer)
        }
        #endif
    }
}
