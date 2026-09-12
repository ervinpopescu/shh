import XCTest
@testable import ShhCore

final class ConnectionFailureTests: XCTestCase {
    func testConnectionFailureMappingFromTransportErrorDNS() {
        let error = TransportError.dnsFailure("Cannot resolve server.internal")
        let failure = ConnectionFailure.from(error: error)

        XCTAssertEqual(failure.stage, .dns)
        XCTAssertEqual(failure.reason, "Could not resolve hostname.")
        XCTAssertTrue(failure.technicalDetail.contains("Cannot resolve server.internal"))
        XCTAssertTrue(failure.recoveryAction.contains("Check the host address spelling"))
    }

    func testConnectionFailureMappingFromTransportErrorConnectionRefused() {
        let error = TransportError.connectionRefused
        let failure = ConnectionFailure.from(error: error)

        XCTAssertEqual(failure.stage, .tcp)
        XCTAssertEqual(failure.reason, "Connection refused by remote server.")
        XCTAssertTrue(failure.technicalDetail.contains("ECONNREFUSED"))
        XCTAssertTrue(failure.recoveryAction.contains("Verify that SSH service is running"))
    }

    func testConnectionFailureMappingFromTransportErrorTimeout() {
        let error = TransportError.timeout
        let failure = ConnectionFailure.from(error: error)

        XCTAssertEqual(failure.stage, .tcp)
        XCTAssertEqual(failure.reason, "Connection timed out reaching host.")
        XCTAssertTrue(failure.recoveryAction.contains("reachability"))
    }

    func testConnectionFailureMappingFromTransportErrorNetworkUnavailable() {
        let error = TransportError.networkUnavailable
        let failure = ConnectionFailure.from(error: error)

        XCTAssertEqual(failure.stage, .tcp)
        XCTAssertEqual(failure.reason, "Network is unavailable or unreachable.")
        XCTAssertTrue(failure.recoveryAction.contains("Wi-Fi/cellular"))
    }

    func testConnectionFailureMappingFromTransportErrorMissingCredential() {
        let error = TransportError.missingCredential(reference: "id-secret-reference-12345")
        let failure = ConnectionFailure.from(error: error)

        XCTAssertEqual(failure.stage, .credential)
        XCTAssertEqual(failure.reason, "Saved credential could not be found in Keychain.")
        XCTAssertFalse(failure.technicalDetail.contains("id-secret-reference-12345"))
        XCTAssertTrue(failure.technicalDetail.contains("id-sec..."))
        XCTAssertTrue(failure.recoveryAction.contains("Key Management"))
    }

    func testConnectionFailureMappingFromTransportErrorInvalidPrivateKey() {
        let error = TransportError.invalidPrivateKey(detail: "Corrupted header in key file")
        let failure = ConnectionFailure.from(error: error)

        XCTAssertEqual(failure.stage, .credential)
        XCTAssertEqual(failure.reason, "Private key format invalid or unreadable.")
        XCTAssertEqual(failure.technicalDetail, "Corrupted header in key file")
        XCTAssertTrue(failure.recoveryAction.contains("Ed25519"))
    }

    func testConnectionFailureMappingFromTransportErrorAuthenticationRequired() {
        let error = TransportError.authenticationRequired
        let failure = ConnectionFailure.from(error: error)

        XCTAssertEqual(failure.stage, .authentication)
        XCTAssertEqual(failure.reason, "Authentication rejected by remote server.")
        XCTAssertTrue(failure.recoveryAction.contains("authorized_keys"))
    }

    func testConnectionFailureMappingFromTransportErrorHostKeyChanged() {
        let error = TransportError.hostKeyChanged(old: "SHA256:11112222333344445555", new: "SHA256:99998888777766665555")
        let failure = ConnectionFailure.from(error: error)

        XCTAssertEqual(failure.stage, .hostKey)
        XCTAssertEqual(failure.reason, "Host key has changed.")
        XCTAssertTrue(failure.technicalDetail.contains("Saved: SHA256:111122223..."))
        XCTAssertTrue(failure.recoveryAction.contains("rotated"))
    }

    func testConnectionFailureMappingFromTransportErrorHostKeyApprovalRequired() {
        let challenge = HostKeyChallenge(hostname: "example.com", port: 22, algorithm: "ssh-ed25519", fingerprint: "SHA256:abcd")
        let error = TransportError.hostKeyApprovalRequired(challenge)
        let failure = ConnectionFailure.from(error: error)

        XCTAssertEqual(failure.stage, .hostKey)
        XCTAssertEqual(failure.reason, "Host key verification required.")
        XCTAssertTrue(failure.recoveryAction.contains("Approve"))
    }

    func testConnectionFailureMappingFromTransportErrorPTYAndShell() {
        let error = TransportError.remoteFailure("Remote PTY allocation rejected")
        let failure = ConnectionFailure.from(error: error)

        XCTAssertEqual(failure.stage, .ptyShell)
        XCTAssertEqual(failure.reason, "Remote shell allocation failed.")
    }

    func testConnectionFailureMappingFromTransportErrorProxyJumpAndMosh() {
        let proxyError = TransportError.remoteFailure("ProxyJump bastion hop failed")
        let proxyFailure = ConnectionFailure.from(error: proxyError)
        XCTAssertEqual(proxyFailure.stage, .proxyJump)
        XCTAssertEqual(proxyFailure.reason, "ProxyJump bastion connection failed.")

        let moshError = TransportError.remoteFailure("Mosh bootstrap server died")
        let moshFailure = ConnectionFailure.from(error: moshError)
        XCTAssertEqual(moshFailure.stage, .proxyJump)
        XCTAssertEqual(moshFailure.reason, "Mosh session bootstrap failed.")
    }

    func testConnectionFailureMappingFromGenericErrors() {
        struct MockError: LocalizedError {
            var errorDescription: String? { "nodename nor servname provided, or not known" }
        }
        let failure = ConnectionFailure.from(error: MockError())
        XCTAssertEqual(failure.stage, .dns)
        XCTAssertEqual(failure.reason, "Could not resolve hostname.")
    }

    func testConnectionFailureCopyableDiagnosticsFormattingAndRedaction() {
        let failure = ConnectionFailure(
            stage: .authentication,
            reason: "Authentication rejected by remote server.",
            technicalDetail: "Public key authentication failed.",
            recoveryAction: "Check ~/.ssh/authorized_keys."
        )
        let diagnostics = failure.copyableDiagnostics
        XCTAssertTrue(diagnostics.contains("Stage: Authentication"))
        XCTAssertTrue(diagnostics.contains("Reason: Authentication rejected by remote server."))
        XCTAssertTrue(diagnostics.contains("Detail: Public key authentication failed."))
        XCTAssertTrue(diagnostics.contains("Action: Check ~/.ssh/authorized_keys."))
        XCTAssertTrue(diagnostics.contains("Timestamp:"))
    }

    func testConnectionFailureCodableRoundTrip() throws {
        let original = ConnectionFailure(
            stage: .tcp,
            reason: "Connection refused by remote server.",
            technicalDetail: "ECONNREFUSED",
            recoveryAction: "Verify SSH port."
        )
        let encoder = JSONEncoder()
        let data = try encoder.encode(original)
        let decoded = try JSONDecoder().decode(ConnectionFailure.self, from: data)

        XCTAssertEqual(original, decoded)
    }
}
