import XCTest
@testable import Shh
import ShhCore
import ShhSSH

@MainActor
final class HetznerConnectionIntegrationTests: XCTestCase {
    func testSavedHetznerHostLoadsAndConnectsSuccessfully() async throws {
        // 1. Verify shared snapshot exists and contains Hetzner
        let helper = FileProviderManagerHelper.shared
        guard let snapshot = helper.loadSharedSnapshot(),
              let hetznerHost = snapshot.hosts.first(where: { $0.name == "Hetzner" }),
              let idID = hetznerHost.identityID,
              let hetznerIdentity = snapshot.identities.first(where: { $0.id == idID }) else {
            throw XCTSkip("No saved Hetzner host found in simulator shared container")
        }

        // 2. Initialize AppContainer with production transport and real keychain
        let ag = KeychainCredentialStore.defaultSharedAccessGroup
        let credentialStore = KeychainCredentialStore(accessGroup: ag)
        let trustStore = InMemoryTrustStore(records: helper.loadSharedTrustRecords() ?? [])

        let testCatalog = InMemoryCatalog(seedDemoData: false)
        try await testCatalog.save(hetznerIdentity)
        try await testCatalog.save(hetznerHost)

        let container = AppContainer(
            catalog: testCatalog,
            trustStore: trustStore,
            credentialStore: credentialStore,
            transport: LiveSSHTransport(credentialStore: credentialStore)
        )

        // 3. First connection attempt: should encounter TOFU host key challenge if untrusted
        await container.connect(to: hetznerHost)

        if let challenge = container.pendingTrustChallenge {
            XCTAssertEqual(challenge.algorithm, "ssh-ed25519")
            XCTAssertFalse(challenge.fingerprint.isEmpty)

            // Approve host key permanently
            await container.approvePendingHostKey(permanently: true)
        }

        // 4. Verify terminal/session connected state
        guard let session = container.activeSession else {
            return XCTFail("Expected active session for host")
        }

        XCTAssertEqual(session.hostID, hetznerHost.id)
        XCTAssertEqual(session.state, .connected)
        XCTAssertNil(container.lastConnectionFailure)

        // Wait for SFTP setup to complete
        for _ in 0..<50 {
            if container.sftpRepository != nil || container.sftpErrorMessage != nil {
                break
            }
            try await Task.sleep(nanoseconds: 100_000_000)
        }
        XNilOrEmpty: do {
            XCTAssertNil(container.sftpErrorMessage)
            XCTAssertNotNil(container.sftpRepository)
        }

        // Clean up connection
        await container.disconnect()
    }

    func testSavedHetznerHostSFTPConnectAndListDirectory() async throws {
        let helper = FileProviderManagerHelper.shared
        guard let snapshot = helper.loadSharedSnapshot(),
              let hetznerHost = snapshot.hosts.first(where: { $0.name == "Hetzner" }),
              let idID = hetznerHost.identityID,
              let hetznerIdentity = snapshot.identities.first(where: { $0.id == idID }) else {
            throw XCTSkip("No saved Hetzner host found in simulator shared container")
        }

        let ag = KeychainCredentialStore.defaultSharedAccessGroup
        let credentialStore = KeychainCredentialStore(accessGroup: ag)
        let trustStore = InMemoryTrustStore(records: helper.loadSharedTrustRecords() ?? [])

        let sftp = try await LiveSFTPRepository.connect(
            host: hetznerHost,
            identity: hetznerIdentity,
            trustEvaluator: trustStore,
            credentialStore: credentialStore
        )
        defer {
            Task { await sftp.close() }
        }

        let contents = try await sftp.listDirectory(at: RemotePath("/"))
        XCTAssertFalse(contents.isEmpty, "SFTP initial directory listing should contain root entries")
        XCTAssertTrue(contents.contains(where: { $0.name == "etc" || $0.name == "var" || $0.name == "home" || $0.name == "usr" || $0.name == "bin" }))
    }

    func testSavedHetznerHostTmuxProbeAndParseSessions() async throws {
        let helper = FileProviderManagerHelper.shared
        guard let snapshot = helper.loadSharedSnapshot(),
              let hetznerHost = snapshot.hosts.first(where: { $0.name == "Hetzner" }),
              let idID = hetznerHost.identityID,
              let hetznerIdentity = snapshot.identities.first(where: { $0.id == idID }) else {
            throw XCTSkip("No saved Hetzner host found in simulator shared container")
        }

        let ag = KeychainCredentialStore.defaultSharedAccessGroup
        let credentialStore = KeychainCredentialStore(accessGroup: ag)
        let trustStore = InMemoryTrustStore(records: helper.loadSharedTrustRecords() ?? [])

        let transport = LiveSSHTransport(credentialStore: credentialStore)
        let connection = try await transport.connect(
            host: hetznerHost,
            identity: hetznerIdentity,
            trustEvaluator: trustStore
        )
        defer {
            Task { await connection.close() }
        }

        guard let executor = connection as? (any SSHCommandExecuting) else {
            XCTFail("Connection does not conform to SSHCommandExecuting")
            return
        }

        let versionRes = try await executor.executeCommand(TmuxCommand.probe)
        XCTAssertEqual(versionRes.exitCode, 0)
        let availability = TmuxAvailability.parse(result: versionRes)
        XCTAssertTrue(availability.isAvailable)

        let listRes = try await executor.executeCommand(TmuxCommand.listSessions)
        XCTAssertEqual(listRes.exitCode, 0)

        let parsedSessions = try TmuxListSessionsParser.parse(listRes.stdout)
        XCTAssertFalse(parsedSessions.isEmpty, "Expected at least one tmux session on remote host")
        for session in parsedSessions {
            XCTAssertTrue(session.sessionID.hasPrefix("$"))
            XCTAssertFalse(session.name.isEmpty)
            XCTAssertGreaterThanOrEqual(session.windowsCount, 1)
        }
    }
}
