import XCTest
@testable import Shh
import ShhCore
import ShhSSH
#if canImport(FileProvider)
import FileProvider
#endif

@MainActor
final class FileProviderAppTests: XCTestCase {

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
        let helper = FileProviderManagerHelper(appGroupIdentifier: "group.com.ervinpopescu.shh")
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
}
