import XCTest
import SwiftUI
@testable import Shh
import ShhCore
import ShhSSH

@MainActor
final class ConnectionFailureAppTests: XCTestCase {
    func testStatusMessageForDnsFailure() {
        let error = TransportError.dnsFailure("Cannot resolve hostname")
        let msg = AppContainer.statusMessage(for: error)
        XCTAssertEqual(msg, "Cannot resolve hostname")
    }

    func testStatusMessageForConnectionRefused() {
        let error = TransportError.connectionRefused
        let msg = AppContainer.statusMessage(for: error)
        XCTAssertEqual(msg, "Connection refused by remote server.")
    }

    func testStatusMessageForMissingCredential() {
        let error = TransportError.missingCredential(reference: "id-1234")
        let msg = AppContainer.statusMessage(for: error)
        XCTAssertEqual(msg, "Saved credential could not be found in Keychain.")
    }

    func testStatusMessageForInvalidPrivateKey() {
        let error = TransportError.invalidPrivateKey(detail: "Corrupted")
        let msg = AppContainer.statusMessage(for: error)
        XCTAssertEqual(msg, "Private key format invalid or unreadable.")
    }

    func testConnectionFailureCardRendersProperly() {
        let failure = ConnectionFailure(
            stage: .dns,
            reason: "Could not resolve hostname.",
            technicalDetail: "DNS resolution failed for remote host.",
            recoveryAction: "Check the host address spelling."
        )
        var retried = false
        var edited = false
        let card = ConnectionFailureCard(
            failure: failure,
            onRetry: { retried = true },
            onEdit: { edited = true }
        )

        let controller = UIHostingController(rootView: card)
        controller.loadViewIfNeeded()

        XCTAssertNotNil(controller.view)
        XCTAssertFalse(retried)
        XCTAssertFalse(edited)
    }

    func testAppContainerSetsLastConnectionFailureOnTransportError() async throws {
        struct FailingTransport: SSHTransport {
            func connect(host: Host, identity: IdentityDescriptor?, trustEvaluator: any HostTrustEvaluator, initialSize: TerminalSize) async throws -> any SSHConnection {
                throw TransportError.dnsFailure("Failed DNS lookup")
            }
        }

        let container = AppContainer.demo(transport: FailingTransport())
        let host = try Host(name: "TestHost", hostname: "bad.internal", username: "user")

        await container.connect(to: host)

        XCTAssertNotNil(container.lastConnectionFailure)
        XCTAssertEqual(container.lastConnectionFailure?.stage, .dns)
        XCTAssertEqual(container.lastConnectionFailure?.reason, "Could not resolve hostname.")
        XCTAssertEqual(container.activeSession?.state, .failed)
    }
}
