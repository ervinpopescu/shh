import XCTest
@testable import ShhCore

final class MoshDomainTests: XCTestCase {

    // MARK: - MoshPortRange Tests

    func testMoshPortRangeInitializationAndDescription() {
        let standard = MoshPortRange.standard
        XCTAssertEqual(standard.start, 60001)
        XCTAssertEqual(standard.end, 60999)
        XCTAssertFalse(standard.isSinglePort)
        XCTAssertEqual(standard.description, "60001:60999")
        XCTAssertEqual(standard.range, 60001...60999)

        let inverted = MoshPortRange(start: 60100, end: 60000)
        XCTAssertEqual(inverted.start, 60000)
        XCTAssertEqual(inverted.end, 60100)

        let single = MoshPortRange(port: 60050)
        XCTAssertEqual(single.start, 60050)
        XCTAssertEqual(single.end, 60050)
        XCTAssertTrue(single.isSinglePort)
        XCTAssertEqual(single.description, "60050")

        let closedRange = MoshPortRange(60010...60020)
        XCTAssertEqual(closedRange.start, 60010)
        XCTAssertEqual(closedRange.end, 60020)
        XCTAssertEqual(closedRange.description, "60010:60020")
    }

    // MARK: - MoshOptions Tests

    func testMoshOptionsDefaultsAndCodableRoundTrip() throws {
        let defaultOptions = MoshOptions()
        XCTAssertEqual(defaultOptions.serverCommand, "mosh-server")
        XCTAssertNil(defaultOptions.portRange)
        XCTAssertEqual(defaultOptions.predictionMode, .adaptive)
        XCTAssertEqual(defaultOptions.sshOptions.connectTimeoutSeconds, 15)

        let customOptions = MoshOptions(
            serverCommand: "/usr/local/bin/mosh-server",
            portRange: MoshPortRange(start: 60000, end: 60500),
            predictionMode: .always,
            sshOptions: SSHOptions(connectTimeoutSeconds: 30, keepAliveSeconds: 120, compression: true)
        )

        let encoder = JSONEncoder()
        let data = try encoder.encode(customOptions)
        let decoder = JSONDecoder()
        let decoded = try decoder.decode(MoshOptions.self, from: data)

        XCTAssertEqual(decoded.serverCommand, "/usr/local/bin/mosh-server")
        XCTAssertEqual(decoded.portRange?.start, 60000)
        XCTAssertEqual(decoded.portRange?.end, 60500)
        XCTAssertEqual(decoded.predictionMode, .always)
        XCTAssertEqual(decoded.sshOptions.connectTimeoutSeconds, 30)
        XCTAssertEqual(decoded.sshOptions.keepAliveSeconds, 120)
        XCTAssertTrue(decoded.sshOptions.compression)
    }

    func testMoshOptionsBackwardDecodingFromEmptyJSON() throws {
        let emptyJSON = "{}".data(using: .utf8)!
        let decoder = JSONDecoder()
        let decoded = try decoder.decode(MoshOptions.self, from: emptyJSON)

        XCTAssertEqual(decoded.serverCommand, "mosh-server")
        XCTAssertNil(decoded.portRange)
        XCTAssertEqual(decoded.predictionMode, .adaptive)
        XCTAssertEqual(decoded.sshOptions.connectTimeoutSeconds, 15)
    }

    // MARK: - MoshSessionKey Redaction and Zeroing Tests

    func testMoshSessionKeyRedactionAndMemoryZeroing() {
        let rawKey = "42a12B4C1234567890ABCD"
        let key = MoshSessionKey(base64: rawKey)

        // Key should be accessible prior to zeroing
        XCTAssertEqual(key.base64String, rawKey)
        XCTAssertEqual(key.rawBytes, Array(rawKey.utf8))
        XCTAssertFalse(key.isZeroized)

        // Redaction: description and debugDescription must NEVER contain the secret
        let description = key.description
        let debugDescription = key.debugDescription
        XCTAssertEqual(description, "[REDACTED]")
        XCTAssertEqual(debugDescription, "[REDACTED]")
        XCTAssertFalse(description.contains(rawKey))
        XCTAssertFalse(debugDescription.contains(rawKey))

        // String interpolation must also be redacted
        let interpolated = "Key is: \(key)"
        XCTAssertFalse(interpolated.contains(rawKey))
        XCTAssertTrue(interpolated.contains("[REDACTED]"))

        // Zeroize: wipes memory buffer
        key.zeroize()
        XCTAssertTrue(key.isZeroized)
        XCTAssertEqual(key.base64String, "")
        XCTAssertEqual(key.rawBytes, [])

        // Second zeroize call should be idempotent and safe
        key.zeroize()
        XCTAssertTrue(key.isZeroized)
    }

    func testMoshSessionInfoRedactionAndZeroing() {
        let rawKey = "secret-session-key-xyz"
        var info = MoshSessionInfo(udpPort: 60005, sessionKey: rawKey, pid: 12345)

        XCTAssertEqual(info.udpPort, 60005)
        XCTAssertEqual(info.pid, 12345)
        XCTAssertEqual(info.sessionKey.base64String, rawKey)

        // Redaction verification
        let desc = info.description
        let debugDesc = info.debugDescription
        XCTAssertFalse(desc.contains(rawKey))
        XCTAssertFalse(debugDesc.contains(rawKey))
        XCTAssertTrue(desc.contains("[REDACTED]"))
        XCTAssertTrue(desc.contains("60005"))
        XCTAssertTrue(desc.contains("12345"))

        // Zeroize wipes key
        info.zeroize()
        XCTAssertTrue(info.sessionKey.isZeroized)
        XCTAssertEqual(info.sessionKey.base64String, "")
    }

    // MARK: - NetworkRoamingState Tests

    func testNetworkRoamingStateInterfaceChanges() {
        let initial = NetworkRoamingState(
            currentInterface: .wifi,
            isExpensive: false,
            isConstrained: false,
            remoteAddress: "198.51.100.10",
            remotePort: 60001
        )

        XCTAssertNil(initial.previousInterface)
        XCTAssertEqual(initial.currentInterface, .wifi)
        XCTAssertFalse(initial.hasInterfaceChanged)
        XCTAssertFalse(initial.isExpensive)

        // Roam to Cellular
        let roamed = initial.transitioning(
            to: .cellular,
            isExpensive: true,
            isConstrained: false
        )

        XCTAssertEqual(roamed.previousInterface, .wifi)
        XCTAssertEqual(roamed.currentInterface, .cellular)
        XCTAssertTrue(roamed.hasInterfaceChanged)
        XCTAssertTrue(roamed.isExpensive)
        XCTAssertEqual(roamed.remoteAddress, "198.51.100.10")
        XCTAssertEqual(roamed.remotePort, 60001)

        // Roam back to Wi-Fi
        let backToWifi = roamed.transitioning(to: .wifi, isExpensive: false)
        XCTAssertEqual(backToWifi.previousInterface, .cellular)
        XCTAssertEqual(backToWifi.currentInterface, .wifi)
        XCTAssertTrue(backToWifi.hasInterfaceChanged)
        XCTAssertFalse(backToWifi.isExpensive)

        // No change transition
        let same = backToWifi.transitioning(to: .wifi)
        XCTAssertEqual(same.previousInterface, .wifi)
        XCTAssertEqual(same.currentInterface, .wifi)
        XCTAssertFalse(same.hasInterfaceChanged)
    }

    // MARK: - MoshState Tests

    func testMoshStateTransitionsAndPredicates() {
        let bootstrapping = MoshState.bootstrapping
        XCTAssertTrue(bootstrapping.isBootstrapping)
        XCTAssertFalse(bootstrapping.isConnected)
        XCTAssertFalse(bootstrapping.isRoaming)
        XCTAssertFalse(bootstrapping.isDisconnected)

        let connected = MoshState.connected
        XCTAssertTrue(connected.isConnected)
        XCTAssertFalse(connected.isBootstrapping)

        let roamingState = NetworkRoamingState(previousInterface: .wifi, currentInterface: .cellular)
        let roaming = MoshState.roaming(roamingState)
        XCTAssertTrue(roaming.isRoaming)
        XCTAssertEqual(roaming.roamingState?.previousInterface, .wifi)
        XCTAssertEqual(roaming.roamingState?.currentInterface, .cellular)

        let disconnected = MoshState.disconnected(reason: "Network timeout")
        XCTAssertTrue(disconnected.isDisconnected)
        XCTAssertEqual(disconnected.disconnectReason, "Network timeout")

        // Static parameterless forms
        XCTAssertTrue(MoshState.roaming.isRoaming)
        XCTAssertTrue(MoshState.disconnected.isDisconnected)
    }

    // MARK: - DemoMoshConnection Tests

    func testDemoMoshConnectionWorkflow() async throws {
        let sessionInfo = MoshSessionInfo(
            udpPort: 60002,
            sessionKey: "demo-secret-key-12345",
            pid: 9999
        )
        let connection = DemoMoshConnection(
            sessionInfo: sessionInfo,
            options: MoshOptions(portRange: MoshPortRange(port: 60002)),
            remoteHostname: "demo.mosh.internal"
        )

        await connection.start()
        let initialState = await connection.moshState
        XCTAssertEqual(initialState, .connected)

        let stream = await connection.events()
        var iterator = stream.makeAsyncIterator()

        // First event is the initial banner
        let firstEvent = try await iterator.next()
        guard case .bytes(let bannerData) = firstEvent else {
            XCTFail("Expected .bytes banner")
            return
        }
        let bannerStr = String(decoding: bannerData, as: UTF8.self)
        XCTAssertTrue(bannerStr.contains("60002"))

        // Send input (echo)
        try await connection.send(Data("hello".utf8))
        let echoEvent = try await iterator.next()
        guard case .bytes(let echoData) = echoEvent else {
            XCTFail("Expected echo bytes")
            return
        }
        XCTAssertEqual(String(decoding: echoData, as: UTF8.self), "hello")

        // Roaming transition
        let roamingUpdate = NetworkRoamingState(
            previousInterface: .wifi,
            currentInterface: .cellular,
            isExpensive: true
        )
        try await connection.handleNetworkRoaming(roamingUpdate)

        let roamingNoticeEvent = try await iterator.next()
        guard case .bytes(let noticeData) = roamingNoticeEvent else {
            XCTFail("Expected roaming notice")
            return
        }
        let noticeStr = String(decoding: noticeData, as: UTF8.self)
        XCTAssertTrue(noticeStr.contains("Cellular"))

        let postRoamState = await connection.moshState
        XCTAssertEqual(postRoamState, .connected)

        // Close and verify teardown zeroing
        await connection.close()
        let finalState = await connection.moshState
        XCTAssertTrue(finalState.isDisconnected)

        let keyAfterClose = await connection.sessionInfo.sessionKey
        XCTAssertTrue(keyAfterClose.isZeroized)
    }

    // MARK: - DemoMoshTransport Tests

    func testDemoMoshTransportConnectsWithTrustEvaluator() async throws {
        struct AlwaysTrustEvaluator: HostTrustEvaluator {
            func status(for challenge: HostKeyChallenge) async -> TrustStatus { .trusted }
            func evaluate(_ challenge: HostKeyChallenge) async -> TrustDecision { .trustPermanently }
        }

        let transport = DemoMoshTransport()
        let host = try Host(
            name: "Demo Mosh Host",
            hostname: "mosh.demo.local",
            port: 22,
            username: "demo",
            connection: .mosh(MoshOptions(portRange: MoshPortRange(port: 60010)))
        )

        let evaluator = AlwaysTrustEvaluator()

        // Unknown host key: evaluator prompts trustOnce or rejects
        // DefaultHostTrustEvaluator returns .trustOnce or .reject
        let connection = try await transport.connect(
            host: host,
            identity: nil,
            trustEvaluator: evaluator
        )

        let events = await connection.events()
        var iterator = events.makeAsyncIterator()
        let event = try await iterator.next()
        guard case .bytes(let data) = event else {
            XCTFail("Expected banner event")
            return
        }
        let output = String(decoding: data, as: UTF8.self)
        XCTAssertTrue(output.contains("60010"))

        await connection.close()
    }

    func testMoshSessionKeyEqualityAndHashingComparesRawBytes() {
        let key1 = MoshSessionKey(base64: "token-abc-123")
        let key2 = MoshSessionKey(base64: "token-abc-123")
        let key3 = MoshSessionKey(base64: "different-token")

        XCTAssertEqual(key1, key2)
        XCTAssertNotEqual(key1, key3)
        XCTAssertEqual(key1.hashValue, key2.hashValue)

        key1.zeroize()
        XCTAssertNotEqual(key1, key2)

        key2.zeroize()
        XCTAssertEqual(key1, key2)
    }

    func testDemoMoshTransportUnknownKeyRequiresApproval() async throws {
        struct RejectEvaluator: HostTrustEvaluator {
            func status(for challenge: HostKeyChallenge) async -> TrustStatus { .unknown }
            func evaluate(_ challenge: HostKeyChallenge) async -> TrustDecision { .reject }
        }

        let transport = DemoMoshTransport()
        let host = try Host(
            name: "Demo Mosh Host",
            hostname: "mosh.demo.local",
            port: 22,
            username: "demo",
            connection: .mosh(MoshOptions())
        )

        do {
            _ = try await transport.connect(host: host, identity: nil, trustEvaluator: RejectEvaluator())
            XCTFail("Expected hostKeyApprovalRequired")
        } catch let error as TransportError {
            guard case .hostKeyApprovalRequired(let challenge) = error else {
                XCTFail("Expected .hostKeyApprovalRequired, got \(error)")
                return
            }
            XCTAssertEqual(challenge.hostname, "mosh.demo.local")
        }
    }

    func testDemoMoshTransportStrictHostKeyCheckingRejectsUnknownKey() async throws {
        struct RejectEvaluator: HostTrustEvaluator {
            func status(for challenge: HostKeyChallenge) async -> TrustStatus { .unknown }
            func evaluate(_ challenge: HostKeyChallenge) async -> TrustDecision { .reject }
        }

        let transport = DemoMoshTransport()
        let host = try Host(
            name: "Demo Mosh Host",
            hostname: "mosh.demo.local",
            port: 22,
            username: "demo",
            connection: .mosh(MoshOptions(sshOptions: SSHOptions(strictHostKeyChecking: .trustedOnly)))
        )

        do {
            _ = try await transport.connect(host: host, identity: nil, trustEvaluator: RejectEvaluator())
            XCTFail("Expected remoteFailure")
        } catch let error as TransportError {
            guard case .remoteFailure(let reason) = error else {
                XCTFail("Expected .remoteFailure, got \(error)")
                return
            }
            XCTAssertEqual(reason, "Host key is not trusted")
        }
    }

    func testDemoMoshTransportChangedKeyThrowsHostKeyChanged() async throws {
        struct ChangedEvaluator: HostTrustEvaluator {
            func status(for challenge: HostKeyChallenge) async -> TrustStatus {
                .changed(oldFingerprint: "SHA256:old-fingerprint-999")
            }
            func evaluate(_ challenge: HostKeyChallenge) async -> TrustDecision { .reject }
        }

        let transport = DemoMoshTransport()
        let host = try Host(
            name: "Demo Mosh Host",
            hostname: "mosh.demo.local",
            port: 22,
            username: "demo",
            connection: .mosh(MoshOptions())
        )

        do {
            _ = try await transport.connect(host: host, identity: nil, trustEvaluator: ChangedEvaluator())
            XCTFail("Expected hostKeyChanged")
        } catch let error as TransportError {
            guard case .hostKeyChanged(let old, let new) = error else {
                XCTFail("Expected .hostKeyChanged, got \(error)")
                return
            }
            XCTAssertEqual(old, "SHA256:old-fingerprint-999")
            XCTAssertEqual(new, "SHA256:demo-mosh-fingerprint")
        }
    }
}
