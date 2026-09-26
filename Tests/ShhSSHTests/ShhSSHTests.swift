import XCTest
import Crypto
import NIOCore
@preconcurrency import NIOSSH
@testable import ShhSSH
@testable import ShhCore

final class AtomicBox<T>: @unchecked Sendable {
    private let lock = NSLock()
    private var value: T
    init(_ value: T) { self.value = value }
    func get() -> T { lock.withLock { value } }
    func set(_ value: T) { lock.withLock { self.value = value } }
}

final class CountingCredentialStore: CredentialStore, @unchecked Sendable {
    private let inner = InMemoryCredentialStore()
    private let lock = NSLock()
    private(set) var loadCallCount = 0

    func save(_ secret: Data, reference: String) async throws {
        try await inner.save(secret, reference: reference)
    }

    func load(reference: String) async throws -> Data {
        lock.withLock { loadCallCount += 1 }
        return try await inner.load(reference: reference)
    }

    func delete(reference: String) async throws {
        try await inner.delete(reference: reference)
    }
}

final class ShhSSHTests: XCTestCase {

    func testTOFUChallengeReceivedBeforeCredentialsTransmitted() async throws {
        let server = SSHTestServer()
        let port = try await server.start()
        addTeardownBlock { try await server.stop() }

        let credStore = InMemoryCredentialStore()
        try await credStore.save(Data("testpassword".utf8), reference: "ref-pass")
        let identity = try IdentityDescriptor(name: "Test Pass", kind: .password, keychainReference: "ref-pass")

        let trustStore = InMemoryTrustStore()
        let transport = LiveSSHTransport(credentialStore: credStore)

        let host = try ShhCore.Host(
            name: "Localhost",
            hostname: "127.0.0.1",
            port: port,
            username: "testuser",
            identityID: identity.id,
            connection: .ssh(SSHOptions(connectTimeoutSeconds: 5, strictHostKeyChecking: .prompt))
        )

        // Attempt 1: Unknown host key, unapproved evaluator
        do {
            _ = try await transport.connect(host: host, identity: identity, trustEvaluator: trustStore)
            XCTFail("Should have thrown hostKeyApprovalRequired")
        } catch let TransportError.hostKeyApprovalRequired(challenge) {
            XCTAssertEqual(challenge.port, port)
            XCTAssertEqual(challenge.fingerprint, server.fingerprint)
            // Crucial verification: server received 0 authentication requests before host key validation failed!
            XCTAssertEqual(server.authDelegate.authAttemptsCount, 0, "No credentials should have been sent!")
        }

        // Now approve the host key and verify connection succeeds and auth happens
        let challenge = HostKeyChallenge(hostname: "127.0.0.1", port: port, algorithm: "ssh-ed25519", fingerprint: server.fingerprint)
        await trustStore.save(challenge)

        let connection = try await transport.connect(host: host, identity: identity, trustEvaluator: trustStore)
        XCTAssertGreaterThan(server.authDelegate.authAttemptsCount, 0, "Credentials sent only after host key approved")
        await connection.close()
    }

    func testChangedHostKeyRejectsConnection() async throws {
        let server = SSHTestServer()
        let port = try await server.start()
        addTeardownBlock { try await server.stop() }

        let credStore = InMemoryCredentialStore()
        try await credStore.save(Data("testpassword".utf8), reference: "ref-pass")
        let identity = try IdentityDescriptor(name: "Test Pass", kind: .password, keychainReference: "ref-pass")

        let trustStore = InMemoryTrustStore()
        // Save an old, mismatched fingerprint
        let fakeOldChallenge = HostKeyChallenge(hostname: "127.0.0.1", port: port, algorithm: "ssh-ed25519", fingerprint: "SHA256:mismatchedOldFingerprint1234567890abc")
        await trustStore.save(fakeOldChallenge)

        let transport = LiveSSHTransport(credentialStore: credStore)
        let host = try ShhCore.Host(
            name: "Localhost",
            hostname: "127.0.0.1",
            port: port,
            username: "testuser",
            identityID: identity.id,
            connection: .ssh(SSHOptions(connectTimeoutSeconds: 5, strictHostKeyChecking: .prompt))
        )

        do {
            _ = try await transport.connect(host: host, identity: identity, trustEvaluator: trustStore)
            XCTFail("Should have thrown hostKeyChanged")
        } catch let TransportError.hostKeyChanged(old, new) {
            XCTAssertEqual(old, fakeOldChallenge.fingerprint)
            XCTAssertEqual(new, server.fingerprint)
            XCTAssertEqual(server.authDelegate.authAttemptsCount, 0, "No credentials transmitted when host key changed!")
        }
    }

    func testPasswordAuthentication() async throws {
        let server = SSHTestServer()
        server.authDelegate.expectedUsername = "testuser"
        server.authDelegate.expectedPassword = "correctpassword"
        let port = try await server.start()
        addTeardownBlock { try await server.stop() }

        let credStore = InMemoryCredentialStore()
        try await credStore.save(Data("correctpassword".utf8), reference: "ref-good-pass")
        try await credStore.save(Data("wrongpassword".utf8), reference: "ref-bad-pass")

        let goodIdentity = try IdentityDescriptor(name: "Good", kind: .password, keychainReference: "ref-good-pass")
        let badIdentity = try IdentityDescriptor(name: "Bad", kind: .password, keychainReference: "ref-bad-pass")

        let trustStore = InMemoryTrustStore()
        await trustStore.save(HostKeyChallenge(hostname: "127.0.0.1", port: port, algorithm: "ssh-ed25519", fingerprint: server.fingerprint))

        let transport = LiveSSHTransport(credentialStore: credStore)

        // Bad password
        let badHost = try ShhCore.Host(
            name: "Bad",
            hostname: "127.0.0.1",
            port: port,
            username: "testuser",
            identityID: badIdentity.id,
            connection: .ssh(SSHOptions(connectTimeoutSeconds: 5))
        )
        do {
            _ = try await transport.connect(host: badHost, identity: badIdentity, trustEvaluator: trustStore)
            XCTFail("Bad password should fail")
        } catch TransportError.authenticationRequired {
            // Expected
        }

        // Good password
        let goodHost = try ShhCore.Host(
            name: "Good",
            hostname: "127.0.0.1",
            port: port,
            username: "testuser",
            identityID: goodIdentity.id,
            connection: .ssh(SSHOptions(connectTimeoutSeconds: 5))
        )
        let connection = try await transport.connect(host: goodHost, identity: goodIdentity, trustEvaluator: trustStore)
        await connection.close()
    }

    func testPrivateKeyAuthentication() async throws {
        let clientKey = Curve25519.Signing.PrivateKey()
        let clientPublicKey = try NIOSSHPublicKey.ed25519(clientKey.publicKey)

        let server = SSHTestServer()
        server.authDelegate.expectedUsername = "testuser"
        server.authDelegate.expectedClientPublicKey = clientPublicKey
        let port = try await server.start()
        addTeardownBlock { try await server.stop() }

        let credStore = InMemoryCredentialStore()
        // Save OpenSSH format representation
        let openSSHRepresentation = clientKey.makeSSHRepresentation()
        try await credStore.save(Data(openSSHRepresentation.utf8), reference: "ref-ed25519-openssh")

        // Also test raw 32 bytes representation
        let rawRepresentation = clientKey.rawRepresentation
        try await credStore.save(rawRepresentation, reference: "ref-ed25519-raw")

        let openSSHIdentity = try IdentityDescriptor(name: "Key PEM", kind: .privateKey, keychainReference: "ref-ed25519-openssh")
        let rawIdentity = try IdentityDescriptor(name: "Key Raw", kind: .privateKey, keychainReference: "ref-ed25519-raw")

        let trustStore = InMemoryTrustStore()
        await trustStore.save(HostKeyChallenge(hostname: "127.0.0.1", port: port, algorithm: "ssh-ed25519", fingerprint: server.fingerprint))

        let transport = LiveSSHTransport(credentialStore: credStore)

        // 1. Connect with OpenSSH PEM format
        let host1 = try ShhCore.Host(name: "H1", hostname: "127.0.0.1", port: port, username: "testuser", identityID: openSSHIdentity.id)
        let conn1 = try await transport.connect(host: host1, identity: openSSHIdentity, trustEvaluator: trustStore)
        await conn1.close()

        // 2. Connect with raw 32-byte representation
        let host2 = try ShhCore.Host(name: "H2", hostname: "127.0.0.1", port: port, username: "testuser", identityID: rawIdentity.id)
        let conn2 = try await transport.connect(host: host2, identity: rawIdentity, trustEvaluator: trustStore)
        await conn2.close()
    }

    func testInteractivePTYEchoAndResize() async throws {
        let server = SSHTestServer()
        let ptyBox = AtomicBox<(Int, Int)>((0, 0))
        let resizeBox = AtomicBox<(Int, Int)>((0, 0))

        server.sessionHandler.onPTY = { cols, rows in
            ptyBox.set((cols, rows))
        }
        server.sessionHandler.onResize = { cols, rows in
            resizeBox.set((cols, rows))
        }

        let port = try await server.start()
        addTeardownBlock { try await server.stop() }

        let credStore = InMemoryCredentialStore()
        try await credStore.save(Data("testpassword".utf8), reference: "ref-pass")
        let identity = try IdentityDescriptor(name: "Pass", kind: .password, keychainReference: "ref-pass")

        let trustStore = InMemoryTrustStore()
        await trustStore.save(HostKeyChallenge(hostname: "127.0.0.1", port: port, algorithm: "ssh-ed25519", fingerprint: server.fingerprint))

        let transport = LiveSSHTransport(credentialStore: credStore)
        let host = try ShhCore.Host(name: "Host", hostname: "127.0.0.1", port: port, username: "testuser", identityID: identity.id)

        let initialSize = TerminalSize(columns: 100, rows: 35)
        let connection = try await transport.connect(
            host: host,
            identity: identity,
            trustEvaluator: trustStore,
            initialSize: initialSize
        )

        let pty = ptyBox.get()
        XCTAssertEqual(pty.0, 100)
        XCTAssertEqual(pty.1, 35)

        let events = await connection.events()

        let iteratorTask = Task { () -> String in
            var text = ""
            for try await event in events {
                if case .bytes(let data) = event {
                    text += String(decoding: data, as: UTF8.self)
                    if text.contains("test-echo-data") && text.contains("[resize:130x45]") {
                        break
                    }
                }
            }
            return text
        }

        // Send interactive data
        try await connection.send(Data("test-echo-data\n".utf8))

        // Trigger dynamic resize
        let newSize = TerminalSize(columns: 130, rows: 45)
        try await connection.resize(newSize)

        let output = try await iteratorTask.value
        XCTAssertTrue(output.contains("Welcome to test shell"))
        XCTAssertTrue(output.contains("test-echo-data"))
        XCTAssertTrue(output.contains("[resize:130x45]"))

        let resize = resizeBox.get()
        XCTAssertEqual(resize.0, 130)
        XCTAssertEqual(resize.1, 45)

        await connection.close()
    }

    func testDisconnectAndResourceTeardown() async throws {
        let server = SSHTestServer()
        let port = try await server.start()
        addTeardownBlock { try await server.stop() }

        let credStore = InMemoryCredentialStore()
        try await credStore.save(Data("testpassword".utf8), reference: "ref-pass")
        let identity = try IdentityDescriptor(name: "Pass", kind: .password, keychainReference: "ref-pass")

        let trustStore = InMemoryTrustStore()
        await trustStore.save(HostKeyChallenge(hostname: "127.0.0.1", port: port, algorithm: "ssh-ed25519", fingerprint: server.fingerprint))

        let transport = LiveSSHTransport(credentialStore: credStore)
        let host = try ShhCore.Host(name: "Host", hostname: "127.0.0.1", port: port, username: "testuser", identityID: identity.id)

        let connection = try await transport.connect(host: host, identity: identity, trustEvaluator: trustStore)
        let events = await connection.events()

        let closedExpectation = expectation(description: "Stream received closed")
        Task {
            for try await event in events {
                if case .closed = event {
                    closedExpectation.fulfill()
                    break
                }
            }
        }

        await connection.close()
        await fulfillment(of: [closedExpectation], timeout: 2.0)

        // Sending after close must throw
        do {
            try await connection.send(Data("after-close".utf8))
            XCTFail("Send after close should throw")
        } catch {
            // Expected
        }

        do {
            try await connection.resize(TerminalSize(columns: 80, rows: 24))
            XCTFail("Resize after close should throw")
        } catch {
            // Expected
        }

        if let liveConn = connection as? LiveSSHConnection {
            XCTAssertNotNil(liveConn.eventLoop)
            do {
                _ = try await liveConn.executeCommand("echo test")
                XCTFail("Execute after close should throw")
            } catch {
                // Expected
            }
        }

        let postCloseEvents = await connection.events()
        var postCloseIterator = postCloseEvents.makeAsyncIterator()
        let postCloseEvent = try await postCloseIterator.next()
        XCTAssertEqual(postCloseEvent, .closed)
        let postCloseNext = try await postCloseIterator.next()
        XCTAssertNil(postCloseNext)

        // Multiple close calls are idempotent and must not crash
        await connection.close()
        await connection.close()
    }

    func testTimeoutHandling() async throws {
        let hangingServer = HangingTCPServer()
        let port = try await hangingServer.start()
        addTeardownBlock { try await hangingServer.stop() }

        let credStore = InMemoryCredentialStore()
        try await credStore.save(Data("testpassword".utf8), reference: "ref-pass")
        let identity = try IdentityDescriptor(name: "Pass", kind: .password, keychainReference: "ref-pass")
        let trustStore = InMemoryTrustStore()

        let transport = LiveSSHTransport(credentialStore: credStore)
        let host = try ShhCore.Host(
            name: "Hanging",
            hostname: "127.0.0.1",
            port: port,
            username: "testuser",
            identityID: identity.id,
            connection: .ssh(SSHOptions(connectTimeoutSeconds: 0.5))
        )

        let start = Date()
        do {
            _ = try await transport.connect(host: host, identity: identity, trustEvaluator: trustStore)
            XCTFail("Connection to hanging server should time out")
        } catch TransportError.timeout {
            let elapsed = Date().timeIntervalSince(start)
            XCTAssertLessThan(elapsed, 3.0, "Timeout should happen quickly (around 0.5s)")
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
    }

    func testCredentialsNotLoadedBeforeHostKeyValidationAccepted() async throws {
        let server = SSHTestServer()
        let port = try await server.start()
        addTeardownBlock { try await server.stop() }

        let credStore = CountingCredentialStore()
        try await credStore.save(Data("testpassword".utf8), reference: "ref-pass")
        let identity = try IdentityDescriptor(name: "Test Pass", kind: .password, keychainReference: "ref-pass")

        let trustStore = InMemoryTrustStore()
        let transport = LiveSSHTransport(credentialStore: credStore)

        let host = try ShhCore.Host(
            name: "Localhost",
            hostname: "127.0.0.1",
            port: port,
            username: "testuser",
            identityID: identity.id,
            connection: .ssh(SSHOptions(connectTimeoutSeconds: 5, strictHostKeyChecking: .prompt))
        )

        // 1. Unknown host key: must NOT load credential from store
        do {
            _ = try await transport.connect(host: host, identity: identity, trustEvaluator: trustStore)
            XCTFail("Should have thrown hostKeyApprovalRequired")
        } catch TransportError.hostKeyApprovalRequired {
            XCTAssertEqual(credStore.loadCallCount, 0, "Credentials must not be loaded when host key is unknown")
        }

        // 2. Changed host key: must NOT load credential from store
        let changedTrustStore = InMemoryTrustStore()
        let mismatchedChallenge = HostKeyChallenge(hostname: "127.0.0.1", port: port, algorithm: "ssh-ed25519", fingerprint: "SHA256:differentOldFingerprint")
        await changedTrustStore.save(mismatchedChallenge)

        do {
            _ = try await transport.connect(host: host, identity: identity, trustEvaluator: changedTrustStore)
            XCTFail("Should have thrown hostKeyChanged")
        } catch TransportError.hostKeyChanged {
            XCTAssertEqual(credStore.loadCallCount, 0, "Credentials must not be loaded when host key has changed")
        }

        // 3. Accepted host key: credential IS loaded from store
        let challenge = HostKeyChallenge(hostname: "127.0.0.1", port: port, algorithm: "ssh-ed25519", fingerprint: server.fingerprint)
        await trustStore.save(challenge)

        let connection = try await transport.connect(host: host, identity: identity, trustEvaluator: trustStore)
        XCTAssertGreaterThan(credStore.loadCallCount, 0, "Credentials should be loaded after host key accepted")
        await connection.close()
    }

    func testNoIdentityDoesNotTransmitPasswordOffer() async throws {
        let server = SSHTestServer()
        server.authDelegate.expectedUsername = "testuser"
        let port = try await server.start()
        addTeardownBlock { try await server.stop() }

        let trustStore = InMemoryTrustStore()
        await trustStore.save(HostKeyChallenge(hostname: "127.0.0.1", port: port, algorithm: "ssh-ed25519", fingerprint: server.fingerprint))

        let transport = LiveSSHTransport(credentialStore: InMemoryCredentialStore())
        let host = try ShhCore.Host(
            name: "No Identity Host",
            hostname: "127.0.0.1",
            port: port,
            username: "testuser",
            identityID: nil,
            connection: .ssh(SSHOptions(connectTimeoutSeconds: 5))
        )

        do {
            _ = try await transport.connect(host: host, identity: nil, trustEvaluator: trustStore)
            XCTFail("Connect without identity should fail")
        } catch TransportError.authenticationRequired {
            // Expected
        }

        XCTAssertEqual(server.authDelegate.authAttemptsCount, 0, "No password offer must be transmitted when identity is nil")
    }

    func testPTYCancellationClosesChannel() async throws {
        let server = SSHTestServer()
        server.sessionHandler.suppressPTYReply = true
        let port = try await server.start()
        addTeardownBlock { try await server.stop() }

        let credStore = InMemoryCredentialStore()
        try await credStore.save(Data("testpassword".utf8), reference: "ref-pass")
        let identity = try IdentityDescriptor(name: "Pass", kind: .password, keychainReference: "ref-pass")

        let trustStore = InMemoryTrustStore()
        await trustStore.save(HostKeyChallenge(hostname: "127.0.0.1", port: port, algorithm: "ssh-ed25519", fingerprint: server.fingerprint))

        let transport = LiveSSHTransport(credentialStore: credStore)
        let host = try ShhCore.Host(
            name: "PTY Suppressed Host",
            hostname: "127.0.0.1",
            port: port,
            username: "testuser",
            identityID: identity.id,
            connection: .ssh(SSHOptions(connectTimeoutSeconds: 5))
        )

        let connectTask = Task {
            try await transport.connect(host: host, identity: identity, trustEvaluator: trustStore)
        }

        try await Task.sleep(nanoseconds: 100_000_000)
        connectTask.cancel()

        do {
            _ = try await connectTask.value
            XCTFail("Cancelled connect should throw")
        } catch TransportError.cancelled {
            // Expected
        }
    }

    func testShellCancellationClosesChannel() async throws {
        let server = SSHTestServer()
        server.sessionHandler.suppressShellReply = true
        let port = try await server.start()
        addTeardownBlock { try await server.stop() }

        let credStore = InMemoryCredentialStore()
        try await credStore.save(Data("testpassword".utf8), reference: "ref-pass")
        let identity = try IdentityDescriptor(name: "Pass", kind: .password, keychainReference: "ref-pass")

        let trustStore = InMemoryTrustStore()
        await trustStore.save(HostKeyChallenge(hostname: "127.0.0.1", port: port, algorithm: "ssh-ed25519", fingerprint: server.fingerprint))

        let transport = LiveSSHTransport(credentialStore: credStore)
        let host = try ShhCore.Host(
            name: "Shell Suppressed Host",
            hostname: "127.0.0.1",
            port: port,
            username: "testuser",
            identityID: identity.id,
            connection: .ssh(SSHOptions(connectTimeoutSeconds: 5))
        )

        let connectTask = Task {
            try await transport.connect(host: host, identity: identity, trustEvaluator: trustStore)
        }

        try await Task.sleep(nanoseconds: 100_000_000)
        connectTask.cancel()

        do {
            _ = try await connectTask.value
            XCTFail("Cancelled connect should throw")
        } catch TransportError.cancelled {
            // Expected
        }
    }
}
