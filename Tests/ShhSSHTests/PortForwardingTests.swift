import XCTest
import NIOCore
import NIOPosix
import ShhCore
@testable import ShhSSH

final class PortForwardingTests: XCTestCase {

    func testLocalPortForwardingDataTransmission() async throws {
        let echoServer = TestEchoServer()
        let echoPort = try await echoServer.start()

        let sshServer = SSHTestServer()
        let sshPort = try await sshServer.start()

        let credStore = InMemoryCredentialStore()
        try await credStore.save(Data("testpassword".utf8), reference: "ref-pass")
        let identity = try IdentityDescriptor(name: "Test", kind: .password, keychainReference: "ref-pass")

        let trustStore = InMemoryTrustStore()
        await trustStore.save(HostKeyChallenge(
            hostname: "127.0.0.1",
            port: sshPort,
            algorithm: "ssh-ed25519",
            fingerprint: sshServer.fingerprint
        ))

        let host = try ShhCore.Host(
            name: "TestHost",
            hostname: "127.0.0.1",
            port: sshPort,
            username: "testuser",
            identityID: identity.id
        )

        let transport = LiveSSHTransport(credentialStore: credStore)
        let connection = try await transport.connect(host: host, identity: identity, trustEvaluator: trustStore)
        guard let liveConn = connection as? LiveSSHConnection else {
            XCTFail("Expected LiveSSHConnection")
            return
        }

        let forwardingManager = PortForwardingManager(connection: liveConn)

        let rule = try PortForwardingRule(
            type: .local,
            localHost: "127.0.0.1",
            localPort: 0,
            remoteHost: "127.0.0.1",
            remotePort: echoPort
        )

        let sessionState = try await forwardingManager.startForwarding(rule: rule)
        XCTAssertEqual(sessionState.status, .active)
        guard let localBoundPort = sessionState.boundPort, localBoundPort > 0 else {
            XCTFail("Expected bound port")
            return
        }

        // Connect TCP client to the local listening port
        let client = TestTCPClient()
        try await client.connect(host: "127.0.0.1", port: Int(localBoundPort))

        let testPayload = Data("Hello from local port forward!\n".utf8)
        try await client.send(testPayload)

        let received = try await client.receiveNext()
        XCTAssertEqual(received, testPayload)

        // Verify active sessions and counters
        let active = await forwardingManager.activeSessions()
        XCTAssertEqual(active.count, 1)
        XCTAssertGreaterThan(active[0].bytesSent, 0)
        XCTAssertGreaterThan(active[0].bytesReceived, 0)

        await client.close()
        try await forwardingManager.stopForwarding(ruleID: rule.id)

        let remaining = await forwardingManager.activeSessions()
        XCTAssertEqual(remaining.count, 0)

        await connection.close()
        try await sshServer.stop()
        try await echoServer.stop()
    }

    func testDynamicSOCKS5HandshakeAndRoutingIPv4() async throws {
        let echoServer = TestEchoServer()
        let echoPort = try await echoServer.start()

        let sshServer = SSHTestServer()
        let sshPort = try await sshServer.start()

        let credStore = InMemoryCredentialStore()
        try await credStore.save(Data("testpassword".utf8), reference: "ref-pass")
        let identity = try IdentityDescriptor(name: "Test", kind: .password, keychainReference: "ref-pass")

        let trustStore = InMemoryTrustStore()
        await trustStore.save(HostKeyChallenge(
            hostname: "127.0.0.1",
            port: sshPort,
            algorithm: "ssh-ed25519",
            fingerprint: sshServer.fingerprint
        ))

        let host = try ShhCore.Host(
            name: "TestHost",
            hostname: "127.0.0.1",
            port: sshPort,
            username: "testuser",
            identityID: identity.id
        )

        let transport = LiveSSHTransport(credentialStore: credStore)
        let connection = try await transport.connect(host: host, identity: identity, trustEvaluator: trustStore)
        guard let liveConn = connection as? LiveSSHConnection else {
            XCTFail("Expected LiveSSHConnection")
            return
        }

        let forwardingManager = PortForwardingManager(connection: liveConn)
        let rule = try PortForwardingRule(
            type: .dynamic,
            localHost: "127.0.0.1",
            localPort: 0
        )

        let sessionState = try await forwardingManager.startForwarding(rule: rule)
        guard let socksPort = sessionState.boundPort else {
            XCTFail("Expected SOCKS port")
            return
        }

        let client = TestTCPClient()
        try await client.connect(host: "127.0.0.1", port: Int(socksPort))

        // Step 1: Greeting [VER=0x05, NMETHODS=1, METHOD=0x00 (No Auth)]
        try await client.send(Data([0x05, 0x01, 0x00]))
        let greetingReply = try await client.receiveNext()
        XCTAssertEqual(greetingReply, Data([0x05, 0x00]))

        // Step 2: CONNECT [VER=5, CMD=1, RSV=0, ATYP=1, 127, 0, 0, 1, Port]
        var connectPacket = Data([0x05, 0x01, 0x00, 0x01, 127, 0, 0, 1])
        let portBytes = withUnsafeBytes(of: echoPort.bigEndian) { Data($0) }
        connectPacket.append(portBytes)
        let pendingPayload = Data("socks5-pending-data\n".utf8)
        connectPacket.append(pendingPayload)
        try await client.send(connectPacket)

        let connectReply = try await client.receiveNext()
        XCTAssertGreaterThanOrEqual(connectReply.count, 2)
        XCTAssertEqual(connectReply[0], 0x05) // VER
        XCTAssertEqual(connectReply[1], 0x00) // SUCCESS

        // Data that arrived with CONNECT must be forwarded after the success reply.
        let receivedPendingPayload = try await client.receiveNext()
        XCTAssertEqual(receivedPendingPayload, pendingPayload)

        // Step 3: Application Data duplex forwarding
        let payload = Data("socks5-tunnelled-data-stream\n".utf8)
        try await client.send(payload)

        let receivedPayload = try await client.receiveNext()
        XCTAssertEqual(receivedPayload, payload)

        // Verify active connections counter is 1 during active SOCKS5 session (Security Finding P2)
        let active = await forwardingManager.activeSessions()
        XCTAssertEqual(active.first?.activeConnectionsCount, 1)

        await client.close()
        try await Task.sleep(nanoseconds: 50_000_000)
        let activeAfterClose = await forwardingManager.activeSessions()
        XCTAssertEqual(activeAfterClose.first?.activeConnectionsCount, 0)

        try await forwardingManager.stopForwarding(ruleID: rule.id)
        await connection.close()
        try await sshServer.stop()
        try await echoServer.stop()
    }

    func testDynamicSOCKS5HandshakeAndRoutingIPv6() async throws {
        let echoServer = TestEchoServer()
        let echoPort = try await echoServer.start(host: "::1")

        let sshServer = SSHTestServer()
        let sshPort = try await sshServer.start()

        let credStore = InMemoryCredentialStore()
        try await credStore.save(Data("testpassword".utf8), reference: "ref-pass")
        let identity = try IdentityDescriptor(name: "Test", kind: .password, keychainReference: "ref-pass")

        let trustStore = InMemoryTrustStore()
        await trustStore.save(HostKeyChallenge(
            hostname: "127.0.0.1",
            port: sshPort,
            algorithm: "ssh-ed25519",
            fingerprint: sshServer.fingerprint
        ))

        let host = try ShhCore.Host(
            name: "TestHost",
            hostname: "127.0.0.1",
            port: sshPort,
            username: "testuser",
            identityID: identity.id
        )
        let transport = LiveSSHTransport(credentialStore: credStore)
        let connection = try await transport.connect(host: host, identity: identity, trustEvaluator: trustStore)
        guard let liveConn = connection as? LiveSSHConnection else { return }

        let forwardingManager = PortForwardingManager(connection: liveConn)
        let rule = try PortForwardingRule(type: .dynamic, localHost: "127.0.0.1", localPort: 0)
        let sessionState = try await forwardingManager.startForwarding(rule: rule)
        let socksPort = sessionState.boundPort!

        let client = TestTCPClient()
        try await client.connect(host: "127.0.0.1", port: Int(socksPort))

        // Step 1: Greeting
        try await client.send(Data([0x05, 0x01, 0x00]))
        let greetingReply = try await client.receiveNext()
        XCTAssertEqual(greetingReply, Data([0x05, 0x00]))

        // Step 2: CONNECT with ATYP=0x04 (IPv6 ::1)
        var connectPacket = Data([0x05, 0x01, 0x00, 0x04])
        let ipv6Bytes: [UInt8] = [0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 1]
        connectPacket.append(contentsOf: ipv6Bytes)
        let portBytes = withUnsafeBytes(of: echoPort.bigEndian) { Data($0) }
        connectPacket.append(portBytes)
        try await client.send(connectPacket)

        let connectReply = try await client.receiveNext()
        XCTAssertGreaterThanOrEqual(connectReply.count, 2)
        XCTAssertEqual(connectReply[0], 0x05) // VER
        XCTAssertEqual(connectReply[1], 0x00) // SUCCESS

        // Step 3: Application Data duplex forwarding over IPv6
        let payload = Data("socks5-ipv6-tunnelled-data\n".utf8)
        try await client.send(payload)

        let receivedPayload = try await client.receiveNext()
        XCTAssertEqual(receivedPayload, payload)

        await client.close()
        try await forwardingManager.stopForwarding(ruleID: rule.id)
        await connection.close()
        try await sshServer.stop()
        try await echoServer.stop()
    }

    func testDynamicSOCKS5RoutingDomainName() async throws {
        let echoServer = TestEchoServer()
        let echoPort = try await echoServer.start()

        let sshServer = SSHTestServer()
        let sshPort = try await sshServer.start()

        let credStore = InMemoryCredentialStore()
        try await credStore.save(Data("testpassword".utf8), reference: "ref-pass")
        let identity = try IdentityDescriptor(name: "Test", kind: .password, keychainReference: "ref-pass")

        let trustStore = InMemoryTrustStore()
        await trustStore.save(HostKeyChallenge(
            hostname: "127.0.0.1",
            port: sshPort,
            algorithm: "ssh-ed25519",
            fingerprint: sshServer.fingerprint
        ))

        let host = try ShhCore.Host(
            name: "TestHost",
            hostname: "127.0.0.1",
            port: sshPort,
            username: "testuser",
            identityID: identity.id
        )

        let transport = LiveSSHTransport(credentialStore: credStore)
        let connection = try await transport.connect(host: host, identity: identity, trustEvaluator: trustStore)
        guard let liveConn = connection as? LiveSSHConnection else {
            XCTFail("Expected LiveSSHConnection")
            return
        }

        let forwardingManager = PortForwardingManager(connection: liveConn)
        let rule = try PortForwardingRule(
            type: .dynamic,
            localHost: "127.0.0.1",
            localPort: 0
        )

        let sessionState = try await forwardingManager.startForwarding(rule: rule)
        guard let socksPort = sessionState.boundPort else {
            XCTFail("Expected SOCKS port")
            return
        }

        let client = TestTCPClient()
        try await client.connect(host: "127.0.0.1", port: Int(socksPort))

        // Step 1: Greeting
        try await client.send(Data([0x05, 0x01, 0x00]))
        let greetingReply = try await client.receiveNext()
        XCTAssertEqual(greetingReply, Data([0x05, 0x00]))

        // Step 2: CONNECT with Domain Name "127.0.0.1" (ATYP = 0x03)
        let domain = "127.0.0.1"
        var connectPacket = Data([0x05, 0x01, 0x00, 0x03, UInt8(domain.utf8.count)])
        connectPacket.append(Data(domain.utf8))
        let portBytes = withUnsafeBytes(of: echoPort.bigEndian) { Data($0) }
        connectPacket.append(portBytes)
        try await client.send(connectPacket)

        let connectReply = try await client.receiveNext()
        XCTAssertEqual(connectReply[0], 0x05)
        XCTAssertEqual(connectReply[1], 0x00)

        // Step 3: Application Data
        let payload = Data("domain-routed-data\n".utf8)
        try await client.send(payload)
        let received = try await client.receiveNext()
        XCTAssertEqual(received, payload)

        await client.close()
        try await forwardingManager.stopForwarding(ruleID: rule.id)
        await connection.close()
        try await sshServer.stop()
        try await echoServer.stop()
    }

    func testDynamicSOCKS5ErrorHandling() async throws {
        let sshServer = SSHTestServer()
        let sshPort = try await sshServer.start()

        let credStore = InMemoryCredentialStore()
        try await credStore.save(Data("testpassword".utf8), reference: "ref-pass")
        let identity = try IdentityDescriptor(name: "Test", kind: .password, keychainReference: "ref-pass")

        let trustStore = InMemoryTrustStore()
        await trustStore.save(HostKeyChallenge(hostname: "127.0.0.1", port: sshPort, algorithm: "ssh-ed25519", fingerprint: sshServer.fingerprint))

        let host = try ShhCore.Host(name: "TestHost", hostname: "127.0.0.1", port: sshPort, username: "testuser", identityID: identity.id)
        let transport = LiveSSHTransport(credentialStore: credStore)
        let connection = try await transport.connect(host: host, identity: identity, trustEvaluator: trustStore)
        guard let liveConn = connection as? LiveSSHConnection else { return }

        let forwardingManager = PortForwardingManager(connection: liveConn)
        let rule = try PortForwardingRule(type: .dynamic, localHost: "127.0.0.1", localPort: 0)
        let sessionState = try await forwardingManager.startForwarding(rule: rule)
        let socksPort = sessionState.boundPort!

        // Subtest 1: Unsupported command (CMD=2 BIND)
        let client1 = TestTCPClient()
        try await client1.connect(host: "127.0.0.1", port: Int(socksPort))
        try await client1.send(Data([0x05, 0x01, 0x00]))
        _ = try await client1.receiveNext()

        // Send BIND command (0x02)
        try await client1.send(Data([0x05, 0x02, 0x00, 0x01, 127, 0, 0, 1, 0, 80]))
        let reply1 = try await client1.receiveNext()
        XCTAssertEqual(reply1[1], 0x07) // Command not supported

        await client1.close()

        // Subtest 2: Connection failure to unreachable port
        let client2 = TestTCPClient()
        try await client2.connect(host: "127.0.0.1", port: Int(socksPort))
        try await client2.send(Data([0x05, 0x01, 0x00]))
        _ = try await client2.receiveNext()

        // Connect to a closed port
        let unreachablePort: UInt16 = 59999
        var packet = Data([0x05, 0x01, 0x00, 0x01, 127, 0, 0, 1])
        packet.append(withUnsafeBytes(of: unreachablePort.bigEndian) { Data($0) })
        try await client2.send(packet)

        let reply2 = try await client2.receiveNext()
        XCTAssertEqual(reply2[0], 0x05)
        XCTAssertEqual(reply2[1], 0x05) // Connection refused

        await client2.close()

        // Subtest 3: Unsupported authentication method
        let client3 = TestTCPClient()
        try await client3.connect(host: "127.0.0.1", port: Int(socksPort))
        try await client3.send(Data([0x05, 0x01, 0x02]))
        let reply3 = try await client3.receiveNext()
        XCTAssertEqual(reply3, Data([0x05, 0xFF]))
        await client3.close()

        // Subtest 4: Invalid greeting version
        let client4 = TestTCPClient()
        try await client4.connect(host: "127.0.0.1", port: Int(socksPort))
        try await client4.send(Data([0x04, 0x01, 0x00]))
        do {
            _ = try await client4.receiveNext()
            XCTFail("Expected disconnect on invalid SOCKS version")
        } catch {
            // Expected connection reset / disconnect
        }
        await client4.close()

        // Subtest 5: Invalid request version
        let client5 = TestTCPClient()
        try await client5.connect(host: "127.0.0.1", port: Int(socksPort))
        try await client5.send(Data([0x05, 0x01, 0x00]))
        _ = try await client5.receiveNext()
        try await client5.send(Data([0x04, 0x01, 0x00, 0x01, 127, 0, 0, 1, 0, 80]))
        do {
            _ = try await client5.receiveNext()
            XCTFail("Expected disconnect on invalid request version")
        } catch {
            // Expected connection reset / disconnect
        }
        await client5.close()

        // Subtest 6: Unsupported address type (ATYP = 0x08)
        let client6 = TestTCPClient()
        try await client6.connect(host: "127.0.0.1", port: Int(socksPort))
        try await client6.send(Data([0x05, 0x01, 0x00]))
        _ = try await client6.receiveNext()
        try await client6.send(Data([0x05, 0x01, 0x00, 0x08, 0, 0, 0, 0, 0, 80]))
        let reply6 = try await client6.receiveNext()
        XCTAssertEqual(reply6[0], 0x05)
        XCTAssertEqual(reply6[1], 0x08) // Address type not supported
        await client6.close()

        try await forwardingManager.stopForwarding(ruleID: rule.id)
        await connection.close()
        try await sshServer.stop()
    }

    func testRemotePortForwardingProtocolContractAndChannelHandling() async throws {
        let echoServer = TestEchoServer()
        let localEchoPort = try await echoServer.start()

        let sshServer = SSHTestServer()
        let sshPort = try await sshServer.start()

        let credStore = InMemoryCredentialStore()
        try await credStore.save(Data("testpassword".utf8), reference: "ref-pass")
        let identity = try IdentityDescriptor(name: "Test", kind: .password, keychainReference: "ref-pass")

        let trustStore = InMemoryTrustStore()
        await trustStore.save(HostKeyChallenge(
            hostname: "127.0.0.1",
            port: sshPort,
            algorithm: "ssh-ed25519",
            fingerprint: sshServer.fingerprint
        ))

        let host = try ShhCore.Host(
            name: "TestHost",
            hostname: "127.0.0.1",
            port: sshPort,
            username: "testuser",
            identityID: identity.id
        )

        let transport = LiveSSHTransport(credentialStore: credStore)
        let connection = try await transport.connect(host: host, identity: identity, trustEvaluator: trustStore)
        guard let liveConn = connection as? LiveSSHConnection else {
            XCTFail("Expected LiveSSHConnection")
            return
        }

        let forwardingManager = PortForwardingManager(connection: liveConn)

        // Remote rule: remote server listens on ephemeral port (0), forwards to local echo server
        let rule = try PortForwardingRule(
            type: .remote,
            localHost: "127.0.0.1",
            localPort: localEchoPort,
            remoteHost: "127.0.0.1",
            remotePort: 0
        )

        let sessionState = try await forwardingManager.startForwarding(rule: rule)
        XCTAssertEqual(sessionState.status, .active)
        guard let remoteListeningPort = sessionState.boundPort, remoteListeningPort > 0 else {
            XCTFail("Expected remote bound port")
            return
        }

        // External client connects to the remote listening port
        let externalClient = TestTCPClient()
        try await externalClient.connect(host: "127.0.0.1", port: Int(remoteListeningPort))

        let payload = Data("forwarded-through-remote-tunnel!\n".utf8)
        try await externalClient.send(payload)

        let echoed = try await externalClient.receiveNext()
        XCTAssertEqual(echoed, payload)

        await externalClient.close()
        try await forwardingManager.stopForwarding(ruleID: rule.id)

        let active = await forwardingManager.activeSessions()
        XCTAssertEqual(active.count, 0)

        await connection.close()
        try await sshServer.stop()
        try await echoServer.stop()
    }

    func testCleanCancellationAndTeardown() async throws {
        let echoServer = TestEchoServer()
        let echoPort = try await echoServer.start()

        let sshServer = SSHTestServer()
        let sshPort = try await sshServer.start()

        let credStore = InMemoryCredentialStore()
        try await credStore.save(Data("testpassword".utf8), reference: "ref-pass")
        let identity = try IdentityDescriptor(name: "Test", kind: .password, keychainReference: "ref-pass")

        let trustStore = InMemoryTrustStore()
        await trustStore.save(HostKeyChallenge(hostname: "127.0.0.1", port: sshPort, algorithm: "ssh-ed25519", fingerprint: sshServer.fingerprint))

        let host = try ShhCore.Host(name: "TestHost", hostname: "127.0.0.1", port: sshPort, username: "testuser", identityID: identity.id)
        let transport = LiveSSHTransport(credentialStore: credStore)
        let connection = try await transport.connect(host: host, identity: identity, trustEvaluator: trustStore)
        guard let liveConn = connection as? LiveSSHConnection else { return }

        let forwardingManager = PortForwardingManager(connection: liveConn)

        let localRule = try PortForwardingRule(type: .local, localHost: "127.0.0.1", localPort: 0, remoteHost: "127.0.0.1", remotePort: echoPort)
        let dynamicRule = try PortForwardingRule(type: .dynamic, localHost: "127.0.0.1", localPort: 0)
        let remoteRule = try PortForwardingRule(type: .remote, localHost: "127.0.0.1", localPort: echoPort, remoteHost: "127.0.0.1", remotePort: 0)

        _ = try await forwardingManager.startForwarding(rule: localRule)
        _ = try await forwardingManager.startForwarding(rule: dynamicRule)
        _ = try await forwardingManager.startForwarding(rule: remoteRule)

        let activeBefore = await forwardingManager.activeSessions()
        XCTAssertEqual(activeBefore.count, 3)

        await forwardingManager.stopAll()

        let activeAfter = await forwardingManager.activeSessions()
        XCTAssertEqual(activeAfter.count, 0)

        await connection.close()
        try await sshServer.stop()
        try await echoServer.stop()
    }
}
