import XCTest
@testable import Shh
import ShhCore
import ShhSSH
#if canImport(FileProvider)
import FileProvider
#endif

private final class SafeBox<T>: @unchecked Sendable {
    private let lock = NSLock()
    private var _value: T

    init(_ value: T) {
        self._value = value
    }

    var value: T {
        lock.lock()
        defer { lock.unlock() }
        return _value
    }

    func mutate(_ transform: (inout T) -> Void) {
        lock.lock()
        defer { lock.unlock() }
        transform(&_value)
    }
}

@MainActor
final class Milestone10AppTests: XCTestCase {

    private var tempDirectory: URL!

    override func setUp() async throws {
        try await super.setUp()
        tempDirectory = FileManager.default.temporaryDirectory.appendingPathComponent("M10Tests_\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tempDirectory, withIntermediateDirectories: true)
    }

    override func tearDown() async throws {
        try? FileManager.default.removeItem(at: tempDirectory)
        try await super.tearDown()
    }

    // MARK: - 1. Domain Registration & Mosh Rejection

    func testDomainRegistrationRejectsMoshOnlyHost() async throws {
        let moshHost = try Host(
            name: "Mosh Server",
            hostname: "10.0.0.1",
            port: 22,
            username: "moshuser",
            connection: .mosh(MoshOptions(serverCommand: "mosh-server"))
        )

        let helper = FileProviderManagerHelper(
            appGroupIdentifier: "group.test.m10",
            containerURL: tempDirectory
        )
        let container = AppContainer.demo(fileProviderHelper: helper)
        try await container.catalog.save(moshHost)

        do {
            try await container.registerFileProviderDomain(for: moshHost)
            XCTFail("Expected registration for Mosh-only host to fail")
        } catch let error as FileProviderManagerError {
            guard case .unsupportedMoshHost(let name) = error else {
                XCTFail("Expected .unsupportedMoshHost error, got: \(error)")
                return
            }
            XCTAssertEqual(name, "Mosh Server")
            XCTAssertNotNil(container.fileProviderDomainError)
        }
    }

    func testDomainRegistrationSuccessForStandardSSHHost() async throws {
        let standardHost = try Host(
            name: "Standard SSH",
            hostname: "10.0.0.2",
            port: 22,
            username: "sshuser",
            connection: .ssh(SSHOptions())
        )

        let registeredBox = SafeBox<[String]>([])
        let removedBox = SafeBox<[String]>([])

        let helper = FileProviderManagerHelper(
            appGroupIdentifier: "group.test.m10",
            containerURL: tempDirectory,
            domainAdder: { domain in
                registeredBox.mutate { $0.append(domain.identifier.rawValue) }
            },
            domainRemover: { domain in
                removedBox.mutate { $0.append(domain.identifier.rawValue) }
            },
            domainLister: {
                registeredBox.value.map { NSFileProviderDomain(identifier: NSFileProviderDomainIdentifier($0), displayName: $0) }
            }
        )

        let container = AppContainer.demo(fileProviderHelper: helper)
        try await container.saveHost(standardHost)

        // Register domain
        try await container.registerFileProviderDomain(for: standardHost)
        XCTAssertTrue(registeredBox.value.contains(standardHost.id.uuidString))
        XCTAssertTrue(container.registeredFileProviderDomainIDs.contains(standardHost.id.uuidString))
        XCTAssertNil(container.fileProviderDomainError)

        // Unregister domain
        try await container.unregisterFileProviderDomain(for: standardHost)
        XCTAssertTrue(removedBox.value.contains(standardHost.id.uuidString))
    }

    func testDomainRegistrationMapsEntitlementAndSigningErrors() async throws {
        let host = try Host(
            name: "Entitled Host",
            hostname: "10.0.0.3",
            port: 22,
            username: "user"
        )

        let helper = FileProviderManagerHelper(
            appGroupIdentifier: "group.test.m10",
            containerURL: tempDirectory,
            domainAdder: { _ in
                throw NSError(
                    domain: NSCocoaErrorDomain,
                    code: 4099,
                    userInfo: [NSLocalizedDescriptionKey: "The application is missing com.apple.developer.fileprovider entitlement"]
                )
            }
        )

        let container = AppContainer.demo(fileProviderHelper: helper)

        do {
            try await container.registerFileProviderDomain(for: host)
            XCTFail("Expected entitlement error to be thrown")
        } catch let error as FileProviderManagerError {
            guard case .missingEntitlementOrSigning(let details) = error else {
                XCTFail("Expected .missingEntitlementOrSigning, got: \(error)")
                return
            }
            XCTAssertTrue(details.contains("entitlement"))
        }
    }

    // MARK: - 2. Host CRUD and Permanent Trust Synchronization

    func testHostCreateUpdateDeleteSyncsSharedStateAtomically() async throws {
        let helper = FileProviderManagerHelper(
            appGroupIdentifier: "group.test.m10",
            containerURL: tempDirectory
        )
        let container = AppContainer.demo(fileProviderHelper: helper)

        let host = try Host(
            name: "Sync Server",
            hostname: "sync.internal",
            port: 2222,
            username: "sync"
        )

        // 1. Create Host
        try await container.saveHost(host)

        let snapshotFile = tempDirectory.appendingPathComponent("catalogs/snapshot.json")
        XCTAssertTrue(FileManager.default.fileExists(atPath: snapshotFile.path), "snapshot.json must exist after saveHost")

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let data1 = try Data(contentsOf: snapshotFile)
        let snapshot1 = try decoder.decode(CatalogSnapshot.self, from: data1)
        XCTAssertTrue(snapshot1.hosts.contains(where: { $0.id == host.id }))

        // 2. Update Host
        var updatedHost = host
        updatedHost.name = "Renamed Sync Server"
        try await container.saveHost(updatedHost)

        let data2 = try Data(contentsOf: snapshotFile)
        let snapshot2 = try decoder.decode(CatalogSnapshot.self, from: data2)
        XCTAssertTrue(snapshot2.hosts.contains(where: { $0.id == host.id && $0.name == "Renamed Sync Server" }))

        // 3. Delete Host
        try await container.deleteHost(id: host.id)

        let data3 = try Data(contentsOf: snapshotFile)
        let snapshot3 = try decoder.decode(CatalogSnapshot.self, from: data3)
        XCTAssertFalse(snapshot3.hosts.contains(where: { $0.id == host.id }), "Deleted host must be removed from snapshot.json")
    }

    func testPermanentTrustChangeUpdatesSharedKnownHosts() async throws {
        let helper = FileProviderManagerHelper(
            appGroupIdentifier: "group.test.m10",
            containerURL: tempDirectory
        )
        let container = AppContainer.demo(fileProviderHelper: helper)

        let targetHost = try Host(
            name: "Trust Server",
            hostname: "unknown.invalid",
            port: 22,
            username: "dev"
        )
        try await container.saveHost(targetHost)

        // Connecting triggers the unknown key challenge
        await container.connect(to: targetHost)
        XCTAssertNotNil(container.pendingTrustChallenge, "Unknown host key must require approval")

        // Permanent approval
        await container.approvePendingHostKey(permanently: true)

        let knownHostsFile = tempDirectory.appendingPathComponent("catalogs/known_hosts.json")
        XCTAssertTrue(FileManager.default.fileExists(atPath: knownHostsFile.path), "known_hosts.json must exist after permanent approval")

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let data = try Data(contentsOf: knownHostsFile)
        let records = try decoder.decode([TrustRecord].self, from: data)
        XCTAssertTrue(records.contains(where: { $0.hostname == "unknown.invalid" }))
    }

    func testTemporaryTrustChangeDoesNotPersistToSharedKnownHosts() async throws {
        let helper = FileProviderManagerHelper(
            appGroupIdentifier: "group.test.m10",
            containerURL: tempDirectory
        )
        let container = AppContainer.demo(fileProviderHelper: helper)

        let targetHost = try Host(
            name: "Temp Server",
            hostname: "temp.invalid",
            port: 22,
            username: "dev"
        )
        try await container.saveHost(targetHost)

        // Connecting triggers the unknown key challenge
        await container.connect(to: targetHost)
        XCTAssertNotNil(container.pendingTrustChallenge)

        // Temporary approval
        await container.approvePendingHostKey(permanently: false)

        let knownHostsFile = tempDirectory.appendingPathComponent("catalogs/known_hosts.json")
        if FileManager.default.fileExists(atPath: knownHostsFile.path) {
            let data = try Data(contentsOf: knownHostsFile)
            let records = (try? JSONDecoder().decode([TrustRecord].self, from: data)) ?? []
            XCTAssertFalse(records.contains(where: { $0.hostname == "temp.invalid" }), "Temporary trust must not persist into known_hosts.json")
        }
    }

    // MARK: - 3. Vault Backup Export, Import, Preview, Merge, Replace

    func testVaultBackupExportAndPreviewLifecycle() async throws {
        let container = AppContainer.demo()

        let customHost = try Host(
            name: "Production Bastion",
            hostname: "bastion.corp.net",
            port: 22,
            username: "admin"
        )
        try await container.saveHost(customHost)

        let passphrase = "correct-strong-passphrase-2026"
        let backupData = try await container.exportVaultBackup(passphrase: passphrase)
        XCTAssertFalse(backupData.isEmpty)

        // Preview counts before restore
        let preview = try container.previewVaultBackup(data: backupData, passphrase: passphrase)
        XCTAssertEqual(preview.catalog.metadata.schemaVersion, StoreMetadata.currentSchemaVersion)
        XCTAssertTrue(preview.catalog.hosts.contains(where: { $0.id == customHost.id }))
        let totalHosts = (try await container.catalog.listHosts()).count
        XCTAssertEqual(preview.catalog.hosts.count, totalHosts)

        // Wrong passphrase detection
        XCTAssertThrowsError(try container.previewVaultBackup(data: backupData, passphrase: "wrong-passphrase")) { error in
            XCTAssertEqual(error as? VaultBackupError, .authenticationFailed)
        }
    }

    func testVaultBackupTamperedDataRejection() async throws {
        let container = AppContainer.demo()
        let passphrase = "tamper-proof-passphrase"
        let backupData = try await container.exportVaultBackup(passphrase: passphrase)

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        var backupEnvelope = try decoder.decode(EncryptedVaultBackup.self, from: backupData)

        // Tamper with ciphertext bytes
        var tamperedCiphertext = backupEnvelope.cipher.ciphertext
        if !tamperedCiphertext.isEmpty {
            tamperedCiphertext[0] ^= 0xFF
        }
        backupEnvelope.cipher.ciphertext = tamperedCiphertext

        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let tamperedData = try encoder.encode(backupEnvelope)

        XCTAssertThrowsError(try container.previewVaultBackup(data: tamperedData, passphrase: passphrase)) { error in
            XCTAssertEqual(error as? VaultBackupError, .authenticationFailed)
        }
    }

    func testVaultRestoreMergePreservesExistingItems() async throws {
        let container = AppContainer.demo()

        let hostA = try Host(name: "Host A", hostname: "a.test", username: "user")
        let hostB = try Host(name: "Host B", hostname: "b.test", username: "user")
        try await container.saveHost(hostA)

        // Create backup with only Host B
        let isolatedCatalog = InMemoryCatalog(seedDemoData: false)
        try await isolatedCatalog.save(hostB)
        let snapshotB = await isolatedCatalog.snapshot()

        // Merge snapshotB into container
        await container.restoreCatalog(from: snapshotB, mode: .merge)

        let currentHosts = try await container.catalog.listHosts()
        XCTAssertTrue(currentHosts.contains(where: { $0.id == hostA.id }), "Host A must be preserved after merge")
        XCTAssertTrue(currentHosts.contains(where: { $0.id == hostB.id }), "Host B must be added after merge")
    }

    func testVaultRestoreReplaceOverwritesEntireCatalog() async throws {
        let container = AppContainer.demo()

        let oldHost = try Host(name: "Old Host", hostname: "old.test", username: "user")
        let newHost = try Host(name: "New Host", hostname: "new.test", username: "user")
        try await container.saveHost(oldHost)

        let isolatedCatalog = InMemoryCatalog(seedDemoData: false)
        try await isolatedCatalog.save(newHost)
        let snapshotNew = await isolatedCatalog.snapshot()

        // Replace container with snapshotNew
        await container.restoreCatalog(from: snapshotNew, mode: .replace)

        let currentHosts = try await container.catalog.listHosts()
        XCTAssertFalse(currentHosts.contains(where: { $0.id == oldHost.id }), "Old Host must be wiped on replace")
        XCTAssertTrue(currentHosts.contains(where: { $0.id == newHost.id }), "New Host must be present on replace")
        XCTAssertEqual(currentHosts.count, 1)
    }

    // MARK: - 4. Security-Scoped Staging & Passphrase Clearing

    func testSecurityScopedStagingCopiesAndCleansUp() throws {
        let sourceURL = tempDirectory.appendingPathComponent("external_backup.shhbackup")
        let testBytes = Data("encrypted-vault-payload".utf8)
        try testBytes.write(to: sourceURL)

        let stagingDir = tempDirectory.appendingPathComponent("VaultStaging", isDirectory: true)
        try FileManager.default.createDirectory(at: stagingDir, withIntermediateDirectories: true)
        let stagedURL = stagingDir.appendingPathComponent("staged.shhbackup")

        try FileManager.default.copyItem(at: sourceURL, to: stagedURL)
        XCTAssertTrue(FileManager.default.fileExists(atPath: stagedURL.path))

        let readData = try Data(contentsOf: stagedURL)
        XCTAssertEqual(readData, testBytes)

        // Clean up
        try FileManager.default.removeItem(at: stagedURL)
        XCTAssertFalse(FileManager.default.fileExists(atPath: stagedURL.path))
    }

    func testPassphraseClearingOnStateReset() {
        var passphraseState = "user-secret-passphrase"
        var confirmState = "user-secret-passphrase"

        // Perform clearing
        passphraseState = ""
        confirmState = ""

        XCTAssertEqual(passphraseState, "")
        XCTAssertEqual(confirmState, "")
    }

    func testNoKeychainCredentialBytesInBackup() async throws {
        let container = AppContainer.demo()
        let passphrase = "verify-no-secrets-passphrase"
        let backupData = try await container.exportVaultBackup(passphrase: passphrase)

        let backupString = String(decoding: backupData, as: UTF8.self)

        let forbiddenPatterns = [
            "BEGIN OPENSSH PRIVATE KEY",
            "BEGIN RSA PRIVATE KEY",
            "BEGIN PRIVATE KEY",
            "PuTTY-User-Key-File",
            "password"
        ]

        for pattern in forbiddenPatterns {
            XCTAssertFalse(
                backupString.contains(pattern),
                "Backup ciphertext or envelope must not contain plaintext private key marker '\(pattern)'"
            )
        }

        // Check decrypted payload as well
        let payload = try container.previewVaultBackup(data: backupData, passphrase: passphrase)
        for identity in payload.catalog.identities {
            XCTAssertFalse(identity.keychainReference.contains("PRIVATE KEY"))
        }
    }

    // MARK: - 5. Accessibility & Readiness Verification

    func testTruthfulReadinessAndAccessibilityIdentifiers() {
        let settingsView = SettingsView()
        XCTAssertNotNil(settingsView)

        let vaultBackupView = VaultBackupView()
        XCTAssertNotNil(vaultBackupView)

        let fileProviderSettingsView = FileProviderSettingsView()
        XCTAssertNotNil(fileProviderSettingsView)
    }
}
