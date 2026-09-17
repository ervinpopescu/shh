import XCTest
#if canImport(Security)
import Security
#endif
@testable import ShhCore

final class KeychainCredentialStoreTests: XCTestCase {
    func testKeychainErrorLocalizedDescriptions() {
        let unavailable = KeychainError.unavailable
        XCTAssertEqual(unavailable.localizedDescription, "Keychain storage is unavailable on this device.")

        #if canImport(Security)
        let notFound = KeychainError.status(errSecItemNotFound)
        XCTAssertEqual(notFound.localizedDescription, "The credential was not found in the Keychain.")
        #else
        let notFound = KeychainError.status(-25300)
        XCTAssertEqual(notFound.localizedDescription, "The credential was not found in the Keychain.")
        #endif

        let entitlement = KeychainError.status(-34018)
        XCTAssertEqual(entitlement.localizedDescription, "Keychain access group entitlement is missing.")

        let genericStatus = KeychainError.status(-25244)
        XCTAssertTrue(genericStatus.localizedDescription.contains("-25244"))
    }

    func testKeychainCredentialStoreFallbackWhenAccessGroupIsInvalid() async throws {
        #if canImport(Security)
        let invalidAccessGroup = "INVALID_GROUP_123.group.com.ervinpopescu.shh"
        let store = KeychainCredentialStore(
            service: "com.ervinpopescu.shh.test.fallback",
            accessGroup: invalidAccessGroup
        )
        let reference = "test-ref-\(UUID().uuidString)"
        let secretData = Data("sample-secret-payload".utf8)

        // Saving should not throw even if the access group is invalid, because it falls back to local Keychain
        do {
            try await store.save(secretData, reference: reference)
            let loaded = try await store.load(reference: reference)
            XCTAssertEqual(loaded, secretData)
            try await store.delete(reference: reference)
        } catch {
            XCTFail("Keychain fallback operation failed: \(error)")
        }
        #endif
    }

    func testCatalogReconciliationPreservesMissingHostReferenceAndFindsDuplicateLabels() throws {
        let first = try IdentityDescriptor(name: "Build Key", kind: .privateKey, publicFingerprint: "SHA256:first", keychainReference: "synthetic-first")
        let second = try IdentityDescriptor(name: "build key", kind: .privateKey, publicFingerprint: "SHA256:second", keychainReference: "synthetic-second")
        let missingID = UUID()
        let savedHost = try Host(name: "Synthetic SSH", hostname: "127.0.0.1", username: "test", identityID: missingID)
        let reconciliation = IdentityCatalogReconciliation(hosts: [savedHost], identities: [first, second])

        XCTAssertEqual(reconciliation.missingHostIdentityIDs, [missingID])
        XCTAssertEqual(reconciliation.duplicateNames, ["build key"])
        XCTAssertEqual(savedHost.identityID, missingID, "Reconciliation must not repair a host by choosing another key")
    }

    func testMissingIdentityDiagnosticIsActionableAndContainsOnlyMetadata() {
        let identityID = UUID()
        let error = TransportError.missingIdentity(id: identityID)
        XCTAssertTrue(error.localizedDescription.contains(identityID.uuidString))
        XCTAssertTrue(error.recoverySuggestion?.contains("select an available identity") == true)
    }

    func testReconciliationDetectsDuplicateIDsAndKeychainReferences() throws {
        let sharedID = UUID()
        let first = try IdentityDescriptor(id: sharedID, name: "First", kind: .privateKey, keychainReference: "shared-ref")
        let duplicateID = try IdentityDescriptor(id: sharedID, name: "Second", kind: .privateKey, keychainReference: "other-ref")
        let duplicateReference = try IdentityDescriptor(name: "Third", kind: .privateKey, keychainReference: "shared-ref")
        let reconciliation = IdentityCatalogReconciliation(hosts: [], identities: [first, duplicateID, duplicateReference])

        XCTAssertEqual(reconciliation.duplicateIdentityIDs, [sharedID, duplicateReference.id])
        XCTAssertEqual(reconciliation.duplicateKeychainReferences, ["shared-ref"])
    }

    func testIdentityCollisionDiagnosticIsActionable() {
        let identityID = UUID()
        let failure = ConnectionFailure.from(error: TransportError.identityCollision(id: identityID))
        XCTAssertEqual(failure.stage, .credential)
        XCTAssertTrue(failure.technicalDetail.contains(identityID.uuidString))
        XCTAssertTrue(failure.recoveryAction.contains("duplicate"))
    }

}
