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

        // Clean up connection
        await container.disconnect()
    }
}
