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
}
