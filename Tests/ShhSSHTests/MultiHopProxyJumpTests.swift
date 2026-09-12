import XCTest
import NIOCore
import NIOPosix
import ShhCore
@testable import ShhSSH

final class MultiHopProxyJumpTests: XCTestCase {

    func testTwoHopProxyJumpConnectionAndExec() async throws {
        let bastionServer = SSHTestServer()
        bastionServer.authDelegate.expectedUsername = "bastionuser"
        bastionServer.authDelegate.expectedPassword = "bastionpassword"
        let b1Port = try await bastionServer.start()

        let targetServer = SSHTestServer()
        targetServer.authDelegate.expectedUsername = "targetuser"
        targetServer.authDelegate.expectedPassword = "targetpassword"
        let targetPort = try await targetServer.start()

        let credStore = InMemoryCredentialStore()
        let b1Ref = "cred-bastion"
        let targetRef = "cred-target"
        try await credStore.save(Data("bastionpassword".utf8), reference: b1Ref)
        try await credStore.save(Data("targetpassword".utf8), reference: targetRef)

        let b1Identity = try IdentityDescriptor(
            id: UUID(),
            name: "Bastion Credential",
            kind: .password,
            publicFingerprint: "fp1",
            keychainReference: b1Ref
        )
        let targetIdentity = try IdentityDescriptor(
            id: UUID(),
            name: "Target Credential",
            kind: .password,
            publicFingerprint: "fp2",
            keychainReference: targetRef
        )

        let trustStore = InMemoryTrustStore()
        await trustStore.save(HostKeyChallenge(
            hostname: "127.0.0.1",
            port: b1Port,
            algorithm: "ssh-ed25519",
            fingerprint: bastionServer.fingerprint
        ))
        await trustStore.save(HostKeyChallenge(
            hostname: "127.0.0.1",
            port: targetPort,
            algorithm: "ssh-ed25519",
            fingerprint: targetServer.fingerprint
        ))

        let b1Host = try ShhCore.Host(
            name: "Bastion 1",
            hostname: "127.0.0.1",
            port: b1Port,
            username: "bastionuser",
            identityID: b1Identity.id,
            connection: .ssh(SSHOptions(strictHostKeyChecking: .trustedOnly))
        )

        let targetHost = try ShhCore.Host(
            name: "Target",
            hostname: "127.0.0.1",
            port: targetPort,
            username: "targetuser",
            identityID: targetIdentity.id,
            connection: .proxyJump(ProxyJumpOptions(
                hopHostIDs: [b1Host.id],
                sshOptions: SSHOptions(strictHostKeyChecking: .trustedOnly)
            ))
        )

        let transport = LiveSSHTransport(
            credentialStore: credStore,
            hostResolver: { id in
                if id == b1Host.id {
                    return (b1Host, b1Identity)
                }
                throw TransportError.remoteFailure("Host not found")
            }
        )

        let connection = try await transport.connect(
            host: targetHost,
            identity: targetIdentity,
            trustEvaluator: trustStore
        )

        guard let live = connection as? LiveSSHConnection else {
            XCTFail("Expected LiveSSHConnection")
            return
        }

        let cmdResult = try await live.executeCommand("echo hello-from-jump")
        XCTAssertEqual(cmdResult.exitCode, 0)
        XCTAssertTrue(cmdResult.stdout.contains("hello-from-jump"))

        XCTAssertEqual(bastionServer.authDelegate.authAttemptsCount, 1)
        XCTAssertEqual(targetServer.authDelegate.authAttemptsCount, 1)

        await connection.close()
        try await bastionServer.stop()
        try await targetServer.stop()
    }

    func testThreeHopProxyJumpConnectionAndCascadeTeardown() async throws {
        let bastion1 = SSHTestServer()
        bastion1.authDelegate.expectedUsername = "b1user"
        bastion1.authDelegate.expectedPassword = "b1password"
        let b1Port = try await bastion1.start()

        let bastion2 = SSHTestServer()
        bastion2.authDelegate.expectedUsername = "b2user"
        bastion2.authDelegate.expectedPassword = "b2password"
        let b2Port = try await bastion2.start()

        let target = SSHTestServer()
        target.authDelegate.expectedUsername = "targetuser"
        target.authDelegate.expectedPassword = "targetpassword"
        let targetPort = try await target.start()

        let credStore = InMemoryCredentialStore()
        try await credStore.save(Data("b1password".utf8), reference: "ref-b1")
        try await credStore.save(Data("b2password".utf8), reference: "ref-b2")
        try await credStore.save(Data("targetpassword".utf8), reference: "ref-target")

        let b1Identity = try IdentityDescriptor(name: "B1", kind: .password, publicFingerprint: "fp1", keychainReference: "ref-b1")
        let b2Identity = try IdentityDescriptor(name: "B2", kind: .password, publicFingerprint: "fp2", keychainReference: "ref-b2")
        let targetIdentity = try IdentityDescriptor(name: "Target", kind: .password, publicFingerprint: "fp3", keychainReference: "ref-target")

        let trustStore = InMemoryTrustStore()
        await trustStore.save(HostKeyChallenge(hostname: "127.0.0.1", port: b1Port, algorithm: "ssh-ed25519", fingerprint: bastion1.fingerprint))
        await trustStore.save(HostKeyChallenge(hostname: "127.0.0.1", port: b2Port, algorithm: "ssh-ed25519", fingerprint: bastion2.fingerprint))
        await trustStore.save(HostKeyChallenge(hostname: "127.0.0.1", port: targetPort, algorithm: "ssh-ed25519", fingerprint: target.fingerprint))

        let b1Host = try ShhCore.Host(name: "B1", hostname: "127.0.0.1", port: b1Port, username: "b1user", identityID: b1Identity.id)
        let b2Host = try ShhCore.Host(name: "B2", hostname: "127.0.0.1", port: b2Port, username: "b2user", identityID: b2Identity.id)
        let targetHost = try ShhCore.Host(
            name: "Target",
            hostname: "127.0.0.1",
            port: targetPort,
            username: "targetuser",
            identityID: targetIdentity.id,
            connection: .proxyJump(ProxyJumpOptions(
                hopHostIDs: [b1Host.id, b2Host.id],
                sshOptions: SSHOptions(strictHostKeyChecking: .trustedOnly)
            ))
        )

        let transport = LiveSSHTransport(
            credentialStore: credStore,
            hostResolver: { id in
                if id == b1Host.id { return (b1Host, b1Identity) }
                if id == b2Host.id { return (b2Host, b2Identity) }
                throw TransportError.remoteFailure("Host not found")
            }
        )

        let connection = try await transport.connect(
            host: targetHost,
            identity: targetIdentity,
            trustEvaluator: trustStore
        )

        guard let live = connection as? LiveSSHConnection else {
            XCTFail("Expected LiveSSHConnection")
            return
        }

        let cmd = try await live.executeCommand("echo multi-hop-works")
        XCTAssertTrue(cmd.stdout.contains("multi-hop-works"))

        XCTAssertEqual(bastion1.authDelegate.authAttemptsCount, 1)
        XCTAssertEqual(bastion2.authDelegate.authAttemptsCount, 1)
        XCTAssertEqual(target.authDelegate.authAttemptsCount, 1)

        await connection.close()
        try await bastion1.stop()
        try await bastion2.stop()
        try await target.stop()
    }

    func testProxyJumpHostKeyChangedRejectionOnBastion() async throws {
        let bastionServer = SSHTestServer()
        let b1Port = try await bastionServer.start()

        let targetServer = SSHTestServer()
        let targetPort = try await targetServer.start()

        let credStore = InMemoryCredentialStore()
        let trustStore = InMemoryTrustStore()
        // Save changed fingerprint for bastion
        await trustStore.save(HostKeyChallenge(
            hostname: "127.0.0.1",
            port: b1Port,
            algorithm: "ssh-ed25519",
            fingerprint: "SHA256:differentwrongfingerprint"
        ))

        let b1Host = try ShhCore.Host(name: "Bastion", hostname: "127.0.0.1", port: b1Port, username: "testuser")
        let targetHost = try ShhCore.Host(
            name: "Target",
            hostname: "127.0.0.1",
            port: targetPort,
            username: "testuser",
            connection: .proxyJump(ProxyJumpOptions(hopHostIDs: [b1Host.id], sshOptions: SSHOptions(strictHostKeyChecking: .trustedOnly)))
        )

        let transport = LiveSSHTransport(
            credentialStore: credStore,
            hostResolver: { _ in (b1Host, nil) }
        )

        do {
            _ = try await transport.connect(host: targetHost, identity: nil, trustEvaluator: trustStore)
            XCTFail("Should have thrown host key changed error")
        } catch let error as TransportError {
            switch error {
            case .hostKeyChanged:
                // Success - expected security error
                break
            default:
                XCTFail("Unexpected error: \(error)")
            }
        }

        // Target server should never have been contacted
        XCTAssertEqual(targetServer.authDelegate.authAttemptsCount, 0)

        try await bastionServer.stop()
        try await targetServer.stop()
    }

    func testProxyJumpSeparateCredentialFailureOnBastion() async throws {
        let bastionServer = SSHTestServer()
        bastionServer.authDelegate.expectedUsername = "buser"
        bastionServer.authDelegate.expectedPassword = "correctpassword"
        let b1Port = try await bastionServer.start()

        let targetServer = SSHTestServer()
        let targetPort = try await targetServer.start()

        let credStore = InMemoryCredentialStore()
        // Save WRONG password for bastion
        try await credStore.save(Data("wrongpassword".utf8), reference: "bad-b-ref")
        let badBIdentity = try IdentityDescriptor(name: "Bad", kind: .password, publicFingerprint: "fp", keychainReference: "bad-b-ref")

        let trustStore = InMemoryTrustStore()
        await trustStore.save(HostKeyChallenge(hostname: "127.0.0.1", port: b1Port, algorithm: "ssh-ed25519", fingerprint: bastionServer.fingerprint))
        await trustStore.save(HostKeyChallenge(hostname: "127.0.0.1", port: targetPort, algorithm: "ssh-ed25519", fingerprint: targetServer.fingerprint))

        let b1Host = try ShhCore.Host(name: "B1", hostname: "127.0.0.1", port: b1Port, username: "buser", identityID: badBIdentity.id)
        let targetHost = try ShhCore.Host(
            name: "Target",
            hostname: "127.0.0.1",
            port: targetPort,
            username: "targetuser",
            connection: .proxyJump(ProxyJumpOptions(hopHostIDs: [b1Host.id]))
        )

        let transport = LiveSSHTransport(
            credentialStore: credStore,
            hostResolver: { _ in (b1Host, badBIdentity) }
        )

        do {
            _ = try await transport.connect(host: targetHost, identity: nil, trustEvaluator: trustStore)
            XCTFail("Should have thrown authenticationRequired")
        } catch let error as TransportError {
            XCTAssertEqual(error, .authenticationRequired)
        }

        XCTAssertEqual(targetServer.authDelegate.authAttemptsCount, 0)

        try await bastionServer.stop()
        try await targetServer.stop()
    }

    func testProxyJumpInteractivePTYEcho() async throws {
        let bastionServer = SSHTestServer()
        let b1Port = try await bastionServer.start()

        let targetServer = SSHTestServer()
        let targetPort = try await targetServer.start()

        let credStore = InMemoryCredentialStore()
        try await credStore.save(Data("testpassword".utf8), reference: "pass")
        let ident = try IdentityDescriptor(name: "ID", kind: .password, publicFingerprint: "fp", keychainReference: "pass")

        let trustStore = InMemoryTrustStore()
        await trustStore.save(HostKeyChallenge(hostname: "127.0.0.1", port: b1Port, algorithm: "ssh-ed25519", fingerprint: bastionServer.fingerprint))
        await trustStore.save(HostKeyChallenge(hostname: "127.0.0.1", port: targetPort, algorithm: "ssh-ed25519", fingerprint: targetServer.fingerprint))

        let b1Host = try ShhCore.Host(name: "B1", hostname: "127.0.0.1", port: b1Port, username: "testuser", identityID: ident.id)
        let targetHost = try ShhCore.Host(name: "Target", hostname: "127.0.0.1", port: targetPort, username: "testuser", identityID: ident.id)

        let transport = LiveSSHTransport(credentialStore: credStore)
        let connection = try await transport.connectProxyJump(
            hops: [(b1Host, ident)],
            target: targetHost,
            targetIdentity: ident,
            trustEvaluator: trustStore
        )

        let stream = await connection.events()
        let readTask = Task { () -> String in
            var text = ""
            for try await event in stream {
                if case .bytes(let bytes) = event {
                    text += String(decoding: bytes, as: UTF8.self)
                    if text.contains("echo-test") {
                        break
                    }
                }
            }
            return text
        }

        try await connection.send(Data("echo-test\n".utf8))
        let received = try await readTask.value
        XCTAssertTrue(received.contains("echo-test"))

        await connection.close()
        try await bastionServer.stop()
        try await targetServer.stop()
    }
}
