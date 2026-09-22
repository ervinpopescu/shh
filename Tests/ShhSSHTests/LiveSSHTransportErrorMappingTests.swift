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
        XCTAssertEqual(
            LiveSSHTransport.mapError(IOError(errnoCode: POSIXErrorCode.EHOSTUNREACH.rawValue, reason: "host unreachable")),
            .networkUnavailable
        )
        XCTAssertEqual(
            LiveSSHTransport.mapError(IOError(errnoCode: POSIXErrorCode.ENETDOWN.rawValue, reason: "network down")),
            .networkUnavailable
        )
    }

    func testDirectTransportErrorsAndCancellationMapDirectly() {
        XCTAssertEqual(
            LiveSSHTransport.mapError(TransportError.authenticationRequired),
            .authenticationRequired
        )
        XCTAssertEqual(
            LiveSSHTransport.mapError(TransportError.connectionRefused),
            .connectionRefused
        )
        XCTAssertEqual(
            LiveSSHTransport.mapError(TransportError.timeout),
            .timeout
        )
        XCTAssertEqual(
            LiveSSHTransport.mapError(TransportError.networkUnavailable),
            .networkUnavailable
        )
        XCTAssertEqual(
            LiveSSHTransport.mapError(TransportError.dnsFailure("unresolvable")),
            .dnsFailure("unresolvable")
        )
        XCTAssertEqual(
            LiveSSHTransport.mapError(CancellationError()),
            .cancelled
        )
    }

    func testChannelErrorMapping() {
        XCTAssertEqual(
            LiveSSHTransport.mapError(ChannelError.connectTimeout(.seconds(5))),
            .timeout
        )
        XCTAssertEqual(
            LiveSSHTransport.mapError(ChannelError.alreadyClosed),
            .remoteFailure("SSH connection failed.")
        )
    }

    func testPOSIXSocketErrorsMapToTransportErrors() {
        XCTAssertEqual(
            LiveSSHTransport.mapError(POSIXError(.ECONNREFUSED)),
            .connectionRefused
        )
        XCTAssertEqual(
            LiveSSHTransport.mapError(POSIXError(.ETIMEDOUT)),
            .timeout
        )
        XCTAssertEqual(
            LiveSSHTransport.mapError(POSIXError(.ENETUNREACH)),
            .networkUnavailable
        )
        XCTAssertEqual(
            LiveSSHTransport.mapError(POSIXError(.EHOSTUNREACH)),
            .networkUnavailable
        )
        XCTAssertEqual(
            LiveSSHTransport.mapError(POSIXError(.ENETDOWN)),
            .networkUnavailable
        )
        XCTAssertEqual(
            LiveSSHTransport.mapError(POSIXError(.EINVAL)),
            .remoteFailure("SSH connection failed.")
        )
    }

    func testFallbackErrorDescriptionMatching() {
        struct MockDescribedError: LocalizedError, CustomStringConvertible {
            let errorDescription: String?
            var description: String { errorDescription ?? "" }
        }

        XCTAssertEqual(
            LiveSSHTransport.mapError(MockDescribedError(errorDescription: "operation timed out")),
            .timeout
        )
        XCTAssertEqual(
            LiveSSHTransport.mapError(MockDescribedError(errorDescription: "request timeout occurred")),
            .timeout
        )
        XCTAssertEqual(
            LiveSSHTransport.mapError(MockDescribedError(errorDescription: "connection refused by target")),
            .connectionRefused
        )
        XCTAssertEqual(
            LiveSSHTransport.mapError(MockDescribedError(errorDescription: "nodename nor servname provided, or not known")),
            .dnsFailure("DNS resolution failed for hostname")
        )
        XCTAssertEqual(
            LiveSSHTransport.mapError(MockDescribedError(errorDescription: "unknownhost error")),
            .dnsFailure("DNS resolution failed for hostname")
        )
        XCTAssertEqual(
            LiveSSHTransport.mapError(MockDescribedError(errorDescription: "hostname could not be resolved")),
            .dnsFailure("DNS resolution failed for hostname")
        )
        XCTAssertEqual(
            LiveSSHTransport.mapError(MockDescribedError(errorDescription: "name resolution failed")),
            .dnsFailure("DNS resolution failed for hostname")
        )
        XCTAssertEqual(
            LiveSSHTransport.mapError(MockDescribedError(errorDescription: "eai_again")),
            .dnsFailure("DNS resolution failed for hostname")
        )
        XCTAssertEqual(
            LiveSSHTransport.mapError(MockDescribedError(errorDescription: "no address associated with nodename")),
            .dnsFailure("DNS resolution failed for hostname")
        )
        XCTAssertEqual(
            LiveSSHTransport.mapError(MockDescribedError(errorDescription: "network is down")),
            .networkUnavailable
        )
        XCTAssertEqual(
            LiveSSHTransport.mapError(MockDescribedError(errorDescription: "network unreachable")),
            .networkUnavailable
        )
        XCTAssertEqual(
            LiveSSHTransport.mapError(MockDescribedError(errorDescription: "host unreachable")),
            .networkUnavailable
        )
        XCTAssertEqual(
            LiveSSHTransport.mapError(MockDescribedError(errorDescription: "permission denied (publickey)")),
            .authenticationRequired
        )
        XCTAssertEqual(
            LiveSSHTransport.mapError(MockDescribedError(errorDescription: "auth failed")),
            .authenticationRequired
        )
        XCTAssertEqual(
            LiveSSHTransport.mapError(MockDescribedError(errorDescription: "authentication rejected")),
            .authenticationRequired
        )
        XCTAssertEqual(
            LiveSSHTransport.mapError(MockDescribedError(errorDescription: "something completely generic")),
            .remoteFailure("SSH connection failed.")
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
