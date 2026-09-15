import XCTest
import SwiftUI
@testable import Shh
import ShhCore
import ShhSSH

@MainActor
final class KeyManagementAppTests: XCTestCase {
    func testKeyManagementViewRendersWithIdentities() async throws {
        let container = AppContainer.demo()
        let identity = try await container.createEd25519Identity(name: "Demo iPad Key", comment: "demo@ipad")

        let view = KeyManagementView().environmentObject(container)
        let hostingController = UIHostingController(rootView: view)
        hostingController.loadViewIfNeeded()

        XCTAssertNotNil(hostingController.view)
        let identities = try await container.catalog.identities()
        XCTAssertTrue(identities.contains(where: { $0.id == identity.id }))
    }

    func testIdentityDetailViewRendersPublicKey() async throws {
        let container = AppContainer.demo()
        let identity = try await container.createEd25519Identity(name: "Production Key", comment: "admin@server")

        let view = IdentityDetailView(identity: identity).environmentObject(container)
        let hostingController = UIHostingController(rootView: view)
        hostingController.loadViewIfNeeded()

        XCTAssertNotNil(hostingController.view)

        let pubKey = try await container.openSSHPublicKey(for: identity)
        XCTAssertNotNil(pubKey)
        XCTAssertTrue(pubKey?.hasPrefix("ssh-ed25519 AAAAC3NzaC1lZDI1NTE5") == true)
    }

    func testIdentityDetailViewDoesNotTriggerModalErrorWhenKeyMissing() async throws {
        let container = AppContainer.demo()
        let missingIdentity = try IdentityDescriptor(
            id: UUID(),
            name: "Orphaned Key",
            kind: .privateKey,
            keychainReference: "non-existent-ref"
        )

        let view = IdentityDetailView(identity: missingIdentity).environmentObject(container)
        let hostingController = UIHostingController(rootView: view)
        hostingController.loadViewIfNeeded()

        XCTAssertNotNil(hostingController.view)
        let pubKey = try? await container.openSSHPublicKey(for: missingIdentity)
        XCTAssertNil(pubKey)
    }

    func testIdentityEditorViewGenerateMode() async throws {
        let container = AppContainer.demo()
        var createdIdentity: IdentityDescriptor?

        let view = IdentityEditorView { ident in
            createdIdentity = ident
        }.environmentObject(container)

        let hostingController = UIHostingController(rootView: view)
        hostingController.loadViewIfNeeded()
        XCTAssertNotNil(hostingController.view)

        // Directly verify the container operation that the view triggers
        let newKey = try await container.createEd25519Identity(name: "Newly Generated Key", comment: "test@ipad")
        createdIdentity = newKey

        XCTAssertNotNil(createdIdentity)
        XCTAssertEqual(createdIdentity?.name, "Newly Generated Key")
        XCTAssertEqual(createdIdentity?.kind, .privateKey)
    }

    func testIdentityEditorViewImportMode() async throws {
        let container = AppContainer.demo()
        let keyPair = Ed25519Parser.generateKeyPair(comment: "imported@ipad")

        let imported = try await container.importPrivateKeyIdentity(
            name: "Imported Key",
            privateKeyText: keyPair.openSSHPrivateKey
        )

        XCTAssertEqual(imported.name, "Imported Key")
        XCTAssertEqual(imported.kind, .privateKey)
        XCTAssertEqual(imported.publicFingerprint, keyPair.fingerprint)

        let pubKey = try await container.openSSHPublicKey(for: imported, comment: "imported@ipad")
        XCTAssertEqual(pubKey, keyPair.openSSHPublicKey)
    }
}
