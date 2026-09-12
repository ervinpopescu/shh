import XCTest
import ShhCore

final class PortForwardingModelTests: XCTestCase {

    func testPortForwardingRuleCreationAndValidation() throws {
        // Valid local rule
        let localRule = try PortForwardingRule(
            type: .local,
            localHost: "127.0.0.1",
            localPort: 8080,
            remoteHost: "internal.example.com",
            remotePort: 80
        )
        XCTAssertEqual(localRule.type, .local)
        XCTAssertEqual(localRule.localHost, "127.0.0.1")
        XCTAssertEqual(localRule.localPort, 8080)
        XCTAssertEqual(localRule.remoteHost, "internal.example.com")
        XCTAssertEqual(localRule.remotePort, 80)
        XCTAssertFalse(localRule.requiresNonLoopbackApproval)

        // Valid dynamic SOCKS5 rule (does not require destination)
        let dynamicRule = try PortForwardingRule(
            type: .dynamic,
            localHost: "127.0.0.1",
            localPort: 1080
        )
        XCTAssertEqual(dynamicRule.type, .dynamic)
        XCTAssertNil(dynamicRule.remoteHost)
        XCTAssertNil(dynamicRule.remotePort)
        XCTAssertFalse(dynamicRule.requiresNonLoopbackApproval)

        // Non-loopback binding requires approval
        let nonLoopbackRule = try PortForwardingRule(
            type: .local,
            localHost: "0.0.0.0",
            localPort: 8080,
            remoteHost: "db.internal",
            remotePort: 5432
        )
        XCTAssertTrue(nonLoopbackRule.requiresNonLoopbackApproval)

        // Invalid empty bind address
        XCTAssertThrowsError(try PortForwardingRule(
            type: .local,
            localHost: "",
            localPort: 8080,
            remoteHost: "target",
            remotePort: 80
        ))

        // Invalid missing destination on local rule
        XCTAssertThrowsError(try PortForwardingRule(
            type: .local,
            localHost: "127.0.0.1",
            localPort: 8080,
            remoteHost: nil,
            remotePort: 80
        ))

        XCTAssertThrowsError(try PortForwardingRule(
            type: .local,
            localHost: "127.0.0.1",
            localPort: 8080,
            remoteHost: "target",
            remotePort: 0
        ))

        // Remote rule with port 0 (ephemeral request) is allowed
        let remoteEphemeralRule = try PortForwardingRule(
            type: .remote,
            localHost: "127.0.0.1",
            localPort: 3000,
            remoteHost: "0.0.0.0",
            remotePort: 0
        )
        XCTAssertEqual(remoteEphemeralRule.remotePort, 0)
    }

    func testPortForwardingRuleCodableRoundTrip() throws {
        let rule = try PortForwardingRule(
            id: UUID(),
            name: "Postgres Forward",
            type: .local,
            localHost: "127.0.0.1",
            localPort: 5432,
            remoteHost: "prod-db.internal",
            remotePort: 5432,
            enabled: true
        )

        let encoder = JSONEncoder()
        let data = try encoder.encode(rule)
        let decoded = try JSONDecoder().decode(PortForwardingRule.self, from: data)

        XCTAssertEqual(decoded.id, rule.id)
        XCTAssertEqual(decoded.name, "Postgres Forward")
        XCTAssertEqual(decoded.type, .local)
        XCTAssertEqual(decoded.localHost, "127.0.0.1")
        XCTAssertEqual(decoded.localPort, 5432)
        XCTAssertEqual(decoded.remoteHost, "prod-db.internal")
        XCTAssertEqual(decoded.remotePort, 5432)
        XCTAssertEqual(decoded.enabled, true)
    }

    func testPortForwardingRuleAndForwardingRuleConversion() throws {
        let original = try ForwardingRule(
            mode: .local,
            bindAddress: "127.0.0.1",
            bindPort: 8080,
            destinationHost: "internal",
            destinationPort: 80
        )

        let converted = PortForwardingRule(from: original)
        XCTAssertEqual(converted.type, .local)
        XCTAssertEqual(converted.localHost, "127.0.0.1")
        XCTAssertEqual(converted.localPort, 8080)
        XCTAssertEqual(converted.remoteHost, "internal")
        XCTAssertEqual(converted.remotePort, 80)

        let backToForwarding = try converted.toForwardingRule()
        XCTAssertEqual(backToForwarding.mode, .local)
        XCTAssertEqual(backToForwarding.bindAddress, "127.0.0.1")
        XCTAssertEqual(backToForwarding.bindPort, 8080)
        XCTAssertEqual(backToForwarding.destinationHost, "internal")
        XCTAssertEqual(backToForwarding.destinationPort, 80)
    }

    func testPortForwardingProfileModel() throws {
        let rule1 = try PortForwardingRule(type: .local, localHost: "127.0.0.1", localPort: 8080, remoteHost: "web", remotePort: 80)
        let rule2 = try PortForwardingRule(type: .dynamic, localHost: "127.0.0.1", localPort: 1080)
        let hostID = UUID()

        let profile = PortForwardingProfile(
            name: "Production Tunnel Profile",
            hostID: hostID,
            rules: [rule1, rule2]
        )

        let data = try JSONEncoder().encode(profile)
        let decoded = try JSONDecoder().decode(PortForwardingProfile.self, from: data)

        XCTAssertEqual(decoded.name, "Production Tunnel Profile")
        XCTAssertEqual(decoded.hostID, hostID)
        XCTAssertEqual(decoded.rules.count, 2)
        XCTAssertEqual(decoded.rules[0].type, .local)
        XCTAssertEqual(decoded.rules[1].type, .dynamic)
    }

    func testProxyJumpConfigAndLegacyOptionsDecoding() throws {
        let b1ID = UUID()
        let b2ID = UUID()

        // New config with mixed hops (hostID + endpoint)
        let endpoint = ProxyJumpEndpoint(hostname: "bastion-ext.corp.com", port: 2222, username: "admin")
        let config = ProxyJumpConfig(hops: [
            .hostID(b1ID),
            .endpoint(endpoint),
            .hostID(b2ID)
        ])

        XCTAssertEqual(config.hostIDs, [b1ID, b2ID])

        let options = ProxyJumpOptions(
            config: config,
            sshOptions: SSHOptions(connectTimeoutSeconds: 30, strictHostKeyChecking: .trustedOnly)
        )

        let encoded = try JSONEncoder().encode(options)
        let decoded = try JSONDecoder().decode(ProxyJumpOptions.self, from: encoded)

        XCTAssertEqual(decoded.config.hops.count, 3)
        XCTAssertEqual(decoded.hopHostIDs, [b1ID, b2ID])
        XCTAssertEqual(decoded.sshOptions.connectTimeoutSeconds, 30)
        XCTAssertEqual(decoded.sshOptions.strictHostKeyChecking, .trustedOnly)

        // Legacy JSON format with only hopHostIDs
        let legacyJSON = """
        {
            "hopHostIDs": ["\(b1ID.uuidString)", "\(b2ID.uuidString)"]
        }
        """.data(using: .utf8)!

        let legacyDecoded = try JSONDecoder().decode(ProxyJumpOptions.self, from: legacyJSON)
        XCTAssertEqual(legacyDecoded.hopHostIDs, [b1ID, b2ID])
        XCTAssertEqual(legacyDecoded.sshOptions.connectTimeoutSeconds, 15) // default
    }

    func testHostModelWithForwardingRulesAndProxyJumpProfile() throws {
        let rule = try PortForwardingRule(type: .local, localHost: "127.0.0.1", localPort: 3000, remoteHost: "api", remotePort: 3000)
        let bastionID = UUID()

        let host = try ShhCore.Host(
            name: "Jumped Host",
            hostname: "internal.target",
            port: 22,
            username: "deploy",
            connection: .proxyJump(ProxyJumpOptions(hopHostIDs: [bastionID])),
            forwardingRules: [rule]
        )

        let encoded = try JSONEncoder().encode(host)
        let decoded = try JSONDecoder().decode(ShhCore.Host.self, from: encoded)

        XCTAssertEqual(decoded.name, "Jumped Host")
        XCTAssertEqual(decoded.forwardingRules.count, 1)
        XCTAssertEqual(decoded.forwardingRules[0].localPort, 3000)
        if case .proxyJump(let jumpOpts) = decoded.connection {
            XCTAssertEqual(jumpOpts.hopHostIDs, [bastionID])
        } else {
            XCTFail("Expected proxyJump connection profile")
        }
    }

    func testForwardingSessionStateLifecycle() throws {
        let rule = try PortForwardingRule(type: .dynamic, localHost: "127.0.0.1", localPort: 1080)
        var state = ForwardingSessionState(ruleID: rule.id, rule: rule, status: .starting)

        XCTAssertEqual(state.status, .starting)
        XCTAssertEqual(state.bytesSent, 0)
        XCTAssertEqual(state.bytesReceived, 0)

        state.status = .active
        state.boundPort = 1080
        state.activeConnectionsCount = 2
        state.bytesSent = 1024
        state.bytesReceived = 2048
        state.lastActivityAt = Date()

        let data = try JSONEncoder().encode(state)
        let decoded = try JSONDecoder().decode(ForwardingSessionState.self, from: data)

        XCTAssertEqual(decoded.status, .active)
        XCTAssertEqual(decoded.boundPort, 1080)
        XCTAssertEqual(decoded.activeConnectionsCount, 2)
        XCTAssertEqual(decoded.bytesSent, 1024)
        XCTAssertEqual(decoded.bytesReceived, 2048)
    }

    func testDemoPortForwardingManagerWorkflow() async throws {
        let demoManager = DemoPortForwardingManager()

        let rule1 = try PortForwardingRule(type: .local, localHost: "127.0.0.1", localPort: 8080, remoteHost: "web", remotePort: 80)
        let rule2 = try PortForwardingRule(type: .dynamic, localHost: "127.0.0.1", localPort: 1080)

        let state1 = try await demoManager.startForwarding(rule: rule1)
        XCTAssertEqual(state1.status, .active)
        XCTAssertEqual(state1.boundPort, 8080)

        let state2 = try await demoManager.startForwarding(rule: rule2)
        XCTAssertEqual(state2.status, .active)
        XCTAssertEqual(state2.boundPort, 1080)

        let active = await demoManager.activeSessions()
        XCTAssertEqual(active.count, 2)

        let lookupState = await demoManager.sessionState(for: rule1.id)
        XCTAssertNotNil(lookupState)
        XCTAssertEqual(lookupState?.ruleID, rule1.id)

        try await demoManager.stopForwarding(ruleID: rule1.id)
        let activeAfterStop1 = await demoManager.activeSessions()
        XCTAssertEqual(activeAfterStop1.count, 1)
        XCTAssertEqual(activeAfterStop1[0].ruleID, rule2.id)

        await demoManager.stopAll()
        let activeAfterStopAll = await demoManager.activeSessions()
        XCTAssertEqual(activeAfterStopAll.count, 0)
    }

    func testDemoPortForwardingManagerStream() async throws {
        let demoManager = DemoPortForwardingManager()
        let rule = try PortForwardingRule(type: .dynamic, localHost: "127.0.0.1", localPort: 1080)

        let stream = await demoManager.sessionStatesStream()
        var iterator = stream.makeAsyncIterator()

        // Initial yield
        let initial = await iterator.next()
        XCTAssertEqual(initial?.count, 0)

        _ = try await demoManager.startForwarding(rule: rule)
        let updated = await iterator.next()
        XCTAssertEqual(updated?.count, 1)
        XCTAssertEqual(updated?.first?.rule.id, rule.id)

        await demoManager.stopAll()
        let stopped = await iterator.next()
        XCTAssertEqual(stopped?.first?.status, .stopped)
    }
}
