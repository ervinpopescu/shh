import XCTest
import NIOCore
import NIOPosix
@testable import ShhSSH
@testable import ShhCore

final class LiveSSHTransportTests: XCTestCase {

    func testConnectToUnreachableHostThrowsTransportErrorWithoutCrashing() async throws {
        let credStore = InMemoryCredentialStore()
        let trustStore = InMemoryTrustStore()
        let transport = LiveSSHTransport(credentialStore: credStore)

        let unreachableHost = try ShhCore.Host(
            name: "Unreachable",
            hostname: "127.0.0.1",
            port: 1,
            username: "testuser",
            connection: .ssh(SSHOptions(connectTimeoutSeconds: 2))
        )

        do {
            _ = try await transport.connect(
                host: unreachableHost,
                identity: nil,
                trustEvaluator: trustStore
            )
            XCTFail("Connecting to unreachable host 127.0.0.1:1 should throw TransportError")
        } catch let error as TransportError {
            switch error {
            case .connectionRefused, .networkUnavailable, .timeout, .remoteFailure:
                break
            default:
                XCTFail("Unexpected TransportError: \(error)")
            }
        } catch {
            XCTFail("Expected TransportError, got: \(error)")
        }
    }

    func testConnectToInvalidHostnameThrowsTransportErrorWithoutCrashing() async throws {
        let credStore = InMemoryCredentialStore()
        let trustStore = InMemoryTrustStore()
        let transport = LiveSSHTransport(credentialStore: credStore)

        let invalidHost = try ShhCore.Host(
            name: "InvalidHost",
            hostname: "invalid.hostname.that.does.not.exist.test",
            port: 22,
            username: "testuser",
            connection: .ssh(SSHOptions(connectTimeoutSeconds: 2))
        )

        do {
            _ = try await transport.connect(
                host: invalidHost,
                identity: nil,
                trustEvaluator: trustStore
            )
            XCTFail("Connecting to invalid host should throw TransportError")
        } catch let error as TransportError {
            switch error {
            case .dnsFailure, .networkUnavailable, .timeout, .remoteFailure:
                break
            default:
                XCTFail("Unexpected TransportError: \(error)")
            }
        } catch {
            XCTFail("Expected TransportError, got: \(error)")
        }
    }

    func testProxyJumpWithUnreachableBastionThrowsTransportErrorWithoutCrashing() async throws {
        let credStore = InMemoryCredentialStore()
        let trustStore = InMemoryTrustStore()
        let transport = LiveSSHTransport(credentialStore: credStore)

        let unreachableBastion = try ShhCore.Host(
            name: "UnreachableBastion",
            hostname: "127.0.0.1",
            port: 1,
            username: "bastionuser",
            connection: .ssh(SSHOptions(connectTimeoutSeconds: 2))
        )

        let targetHost = try ShhCore.Host(
            name: "TargetHost",
            hostname: "10.0.0.2",
            port: 22,
            username: "targetuser",
            connection: .ssh(SSHOptions(connectTimeoutSeconds: 2))
        )

        do {
            _ = try await transport.connectProxyJump(
                hops: [(unreachableBastion, nil)],
                target: targetHost,
                targetIdentity: nil,
                trustEvaluator: trustStore
            )
            XCTFail("Connecting via unreachable bastion should throw TransportError")
        } catch let error as TransportError {
            switch error {
            case .connectionRefused, .networkUnavailable, .timeout, .remoteFailure:
                break
            default:
                XCTFail("Unexpected TransportError: \(error)")
            }
        } catch {
            XCTFail("Expected TransportError, got: \(error)")
        }
    }

    func testLiveSSHHandshakeHandlerDeinitFailsPromiseIfUnfulfilled() async throws {
        let group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
        defer {
            Task {
                try? await group.shutdownGracefully()
            }
        }

        let promise = group.next().makePromise(of: Void.self)

        // Allocate and immediately drop handler without calling succeed or fail
        do {
            _ = LiveSSHHandshakeHandler(promise: promise)
        }

        // The promise should be failed by deinit instead of leaking and asserting
        do {
            try await promise.futureResult.get()
            XCTFail("Unfulfilled promise should have been failed on handler deinit")
        } catch let error as TransportError {
            XCTAssertEqual(error, .cancelled)
        } catch {
            XCTFail("Expected TransportError.cancelled, got \(error)")
        }
    }

    func testLiveSSHExecChannelHandlerDeinitFailsPromiseIfUnfulfilled() async throws {
        let group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
        defer {
            Task {
                try? await group.shutdownGracefully()
            }
        }

        let promise = group.next().makePromise(of: SSHCommandResult.self)

        // Allocate and immediately drop handler without completing
        do {
            _ = LiveSSHExecChannelHandler(
                allocator: ByteBufferAllocator(),
                promise: promise,
                maxOutputBytes: 1024
            )
        }

        // The promise should be failed by deinit instead of leaking and asserting
        do {
            _ = try await promise.futureResult.get()
            XCTFail("Unfulfilled exec promise should have been failed on handler deinit")
        } catch let error as TransportError {
            XCTAssertEqual(error, .cancelled)
        } catch {
            XCTFail("Expected TransportError.cancelled, got \(error)")
        }
    }
}
