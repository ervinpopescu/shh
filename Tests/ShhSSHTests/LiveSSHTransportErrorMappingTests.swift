#if canImport(XCTest)
import XCTest
@testable import ShhSSH
import ShhCore
import Crypto
import NIOCore
import NIOPosix

final class LiveSSHTransportErrorMappingTests: XCTestCase {
    func testTypedNIOSocketErrorsMapToTransportErrors() {
        XCTAssertEqual(
            LiveSSHTransport.mapError(IOError(errnoCode: POSIXErrorCode.ECONNREFUSED.rawValue, reason: "connect failed")),
            .connectionRefused
        )
        XCTAssertEqual(
            LiveSSHTransport.mapError(IOError(errnoCode: POSIXErrorCode.ETIMEDOUT.rawValue, reason: "connect timed out")),
            .timeout
        )
        XCTAssertEqual(
            LiveSSHTransport.mapError(IOError(errnoCode: POSIXErrorCode.ENETUNREACH.rawValue, reason: "network unavailable")),
            .networkUnavailable
        )
    }

    func testConnectionFailureMappingDoesNotExposeRawErrorDetails() {
        let mapped = LiveSSHTransport.mapError(
            IOError(errnoCode: POSIXErrorCode.EIO.rawValue, reason: "secret-password should not be surfaced")
        )

        XCTAssertEqual(mapped, .remoteFailure("SSH connection failed."))
    }

    func testNIOConnectionErrorSingleStackIPv4DoesNotMaskConnectionRefusedAsDNSFailure() {
        let group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
        defer { try? group.syncShutdownGracefully() }

        let bootstrap = ClientBootstrap(group: group)

        do {
            _ = try bootstrap.connect(host: "127.0.0.1", port: 1).wait()
            XCTFail("Expected connection to fail")
        } catch {
            XCTAssertTrue(error is NIOConnectionError)
            XCTAssertEqual(LiveSSHTransport.mapError(error), .connectionRefused)
        }
    }

    func testNIOConnectionErrorPureDNSFailureMapsToDNSFailure() {
        let group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
        defer { try? group.syncShutdownGracefully() }

        let bootstrap = ClientBootstrap(group: group)

        do {
            _ = try bootstrap.connect(host: "nonexistent.test.invalid", port: 22).wait()
            XCTFail("Expected connection to fail")
        } catch {
            XCTAssertTrue(error is NIOConnectionError)
            XCTAssertEqual(
                LiveSSHTransport.mapError(error),
                .dnsFailure("DNS resolution failed for hostname")
            )
        }
    }

    func testMissingCredentialThrowsMissingCredentialError() async throws {
        let emptyStore = InMemoryCredentialStore()
        let identity = try IdentityDescriptor(
            name: "Missing Key",
            kind: .privateKey,
            keychainReference: "non-existent-ref"
        )

        do {
            _ = try await LiveSSHTransport.resolveAuthenticationCredential(
                identity: identity,
                credentialStore: emptyStore
            )
            XCTFail("Expected missingCredential error")
        } catch let error as TransportError {
            guard case .missingCredential(let ref) = error else {
                return XCTFail("Expected .missingCredential, got: \(error)")
            }
            XCTAssertEqual(ref, "non-existent-ref")
        }
    }

    func testInvalidPrivateKeyDataThrowsInvalidPrivateKeyError() async throws {
        let store = InMemoryCredentialStore()
        try await store.save(Data("invalid-corrupt-key-bytes".utf8), reference: "bad-key-ref")
        let identity = try IdentityDescriptor(
            name: "Bad Key",
            kind: .privateKey,
            keychainReference: "bad-key-ref"
        )

        do {
            _ = try await LiveSSHTransport.resolveAuthenticationCredential(
                identity: identity,
                credentialStore: store
            )
            XCTFail("Expected invalidPrivateKey error")
        } catch let error as TransportError {
            guard case .invalidPrivateKey = error else {
                return XCTFail("Expected .invalidPrivateKey, got: \(error)")
            }
        }
    }

    func testValidEd25519KeyRoundTripsSuccessfully() async throws {
        let store = InMemoryCredentialStore()
        let generated = Ed25519Parser.generateKeyPair(comment: "test@device")
        try await store.save(Data(generated.openSSHPrivateKey.utf8), reference: "good-key-ref")
        let identity = try IdentityDescriptor(
            name: "Good Key",
            kind: .privateKey,
            keychainReference: "good-key-ref"
        )

        let cred = try await LiveSSHTransport.resolveAuthenticationCredential(
            identity: identity,
            credentialStore: store
        )
        guard case .privateKey = cred else {
            return XCTFail("Expected .privateKey credential")
        }
    }

    func testValidPasswordRoundTripsSuccessfully() async throws {
        let store = InMemoryCredentialStore()
        try await store.save(Data("secret-pass".utf8), reference: "good-pass-ref")
        let identity = try IdentityDescriptor(
            name: "Password ID",
            kind: .password,
            keychainReference: "good-pass-ref"
        )

        let cred = try await LiveSSHTransport.resolveAuthenticationCredential(
            identity: identity,
            credentialStore: store
        )
        guard case .password(let pass) = cred else {
            return XCTFail("Expected .password credential")
        }
        XCTAssertEqual(pass, "secret-pass")
    }
}
#endif
