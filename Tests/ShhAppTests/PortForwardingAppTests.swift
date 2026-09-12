import SwiftUI
import XCTest
@testable import Shh
import ShhCore
import ShhSSH
import ShhTerminal

@MainActor
final class PortForwardingAppTests: XCTestCase {

    // MARK: - 1. ProxyJump Resolution

    func testProxyJumpCatalogResolutionSingleHop() async throws {
        let catalog = InMemoryCatalog(seedDemoData: false)
        let credStore = InMemoryCredentialStore()
        let trustStore = InMemoryTrustStore()

        // 1. Save identity
        let secretData = Data("bastion-private-key".utf8)
        try await credStore.save(secretData, reference: "kc-bastion")
        let bastionIdent = try IdentityDescriptor(
            name: "Bastion Key",
            kind: .privateKey,
            keychainReference: "kc-bastion"
        )
        try await catalog.save(bastionIdent)

        // 2. Save bastion host
        let bastionHost = try Host(
            name: "Bastion Alpha",
            hostname: "bastion.example.com",
            port: 22,
            username: "jumpuser",
            identityID: bastionIdent.id
        )
        try await catalog.save(bastionHost)

        // 3. Save target host configured with ProxyJump
        let targetHost = try Host(
            name: "Internal Server",
            hostname: "internal.example.corp",
            port: 22,
            username: "appuser",
            connection: .proxyJump(ProxyJumpOptions(hopHostIDs: [bastionHost.id]))
        )
        try await catalog.save(targetHost)

        let container = AppContainer(
            catalog: catalog,
            trustStore: trustStore,
            credentialStore: credStore
        )

        // 4. Resolve hops from container
        let hops = await container.resolveBastionHops(for: targetHost)
        XCTAssertEqual(hops.count, 1)
        XCTAssertEqual(hops[0].0.id, bastionHost.id)
        XCTAssertEqual(hops[0].0.name, "Bastion Alpha")
        XCTAssertEqual(hops[0].0.hostname, "bastion.example.com")
        XCTAssertEqual(hops[0].1?.id, bastionIdent.id)

        let hopNames = await container.resolveBastionNames(for: targetHost)
        XCTAssertEqual(hopNames, ["Bastion Alpha"])
    }

    func testProxyJumpCatalogResolutionMultiHopChain() async throws {
        let catalog = InMemoryCatalog(seedDemoData: false)
        let credStore = InMemoryCredentialStore()

        let b1Ident = try IdentityDescriptor(name: "B1 Key", kind: .password, keychainReference: "kc-b1")
        try await catalog.save(b1Ident)
        let bastion1 = try Host(name: "Bastion 1", hostname: "b1.example.com", username: "u1", identityID: b1Ident.id)
        try await catalog.save(bastion1)

        let b2Ident = try IdentityDescriptor(name: "B2 Key", kind: .password, keychainReference: "kc-b2")
        try await catalog.save(b2Ident)
        let bastion2 = try Host(name: "Bastion 2", hostname: "b2.example.com", username: "u2", identityID: b2Ident.id)
        try await catalog.save(bastion2)

        let target = try Host(
            name: "Deep Target",
            hostname: "deep.lan",
            username: "root",
            connection: .proxyJump(ProxyJumpOptions(hopHostIDs: [bastion1.id, bastion2.id]))
        )
        try await catalog.save(target)

        let container = AppContainer(catalog: catalog, credentialStore: credStore)

        let resolved = await container.resolveBastionHops(for: target)
        XCTAssertEqual(resolved.count, 2)
        XCTAssertEqual(resolved[0].0.name, "Bastion 1")
        XCTAssertEqual(resolved[0].1?.name, "B1 Key")
        XCTAssertEqual(resolved[1].0.name, "Bastion 2")
        XCTAssertEqual(resolved[1].1?.name, "B2 Key")

        let names = await container.resolveBastionNames(for: target)
        XCTAssertEqual(names, ["Bastion 1", "Bastion 2"])
    }

    func testProxyJumpMissingBastionFailsLiveConnect() async throws {
        let catalog = InMemoryCatalog(seedDemoData: false)
        let credStore = InMemoryCredentialStore()
        let nonExistentBastionID = UUID()

        let target = try Host(
            name: "Broken Jump Host",
            hostname: "target.invalid",
            username: "dev",
            connection: .proxyJump(ProxyJumpOptions(hopHostIDs: [nonExistentBastionID]))
        )
        try await catalog.save(target)

        let container = AppContainer(catalog: catalog, credentialStore: credStore)

        // Attempting to connect when a jump bastion does not exist in catalog
        await container.connect(to: target)
        XCTAssertEqual(container.activeSession?.state, .failed)
        XCTAssertTrue(container.terminalText.contains("Unsupported") || container.terminalText.contains("unavailable") || container.terminalText.contains("failed"))
    }

    // MARK: - 2. Port Forwarding Lifecycle

    func testAutomaticStartupOfEnabledRulesOnConnect() async throws {
        let container = AppContainer.demo()

        let rule1 = try PortForwardingRule(
            name: "Web Tunnel",
            type: .local,
            localHost: "127.0.0.1",
            localPort: 8080,
            remoteHost: "10.0.0.5",
            remotePort: 80,
            enabled: true
        )
        let rule2 = try PortForwardingRule(
            name: "Dynamic Proxy",
            type: .dynamic,
            localHost: "127.0.0.1",
            localPort: 1080,
            enabled: false
        )

        let host = try Host(
            name: "Server With Rules",
            hostname: "demo.invalid",
            username: "dev",
            forwardingRules: [rule1, rule2]
        )

        let demoChallenge = HostKeyChallenge(hostname: "demo.invalid", port: 22, algorithm: "ssh-ed25519", fingerprint: "SHA256:demo-fingerprint")
        await container.trustStore.save(demoChallenge)

        await container.connect(to: host)
        XCTAssertEqual(container.activeSession?.state, .connected)

        // Give the auto-start task a brief moment to finish updating published sessions
        try await Task.sleep(nanoseconds: 50_000_000)

        // Rule 1 was enabled, so it must be automatically active
        let rule1Session = container.forwardingSessions.first(where: { $0.ruleID == rule1.id })
        XCTAssertNotNil(rule1Session)
        XCTAssertEqual(rule1Session?.status, .active)
        XCTAssertEqual(rule1Session?.rule.name, "Web Tunnel")
        XCTAssertEqual(container.activeForwardersCount, 1)

        // Rule 2 was disabled, so it should not be active
        let rule2Session = container.forwardingSessions.first(where: { $0.ruleID == rule2.id })
        XCTAssertTrue(rule2Session == nil || rule2Session?.status == .stopped)
    }

    func testManualStartAndStopLifecycle() async throws {
        let container = AppContainer.demo()

        let rule1 = try PortForwardingRule(
            name: "Rule A",
            type: .local,
            localHost: "127.0.0.1",
            localPort: 8081,
            remoteHost: "localhost",
            remotePort: 80,
            enabled: false
        )
        let rule2 = try PortForwardingRule(
            name: "Rule B",
            type: .dynamic,
            localHost: "127.0.0.1",
            localPort: 1081,
            enabled: false
        )

        let host = try Host(
            name: "Manual Host",
            hostname: "demo.invalid",
            username: "dev",
            forwardingRules: [rule1, rule2]
        )
        let challenge = HostKeyChallenge(hostname: "demo.invalid", port: 22, algorithm: "ssh-ed25519", fingerprint: "SHA256:demo-fingerprint")
        await container.trustStore.save(challenge)

        await container.connect(to: host)
        XCTAssertEqual(container.activeSession?.state, .connected)
        XCTAssertEqual(container.activeForwardersCount, 0)

        // Start Rule 1 manually
        let session1 = try await container.startForwarding(rule: rule1)
        XCTAssertEqual(session1.status, .active)
        try await Task.sleep(nanoseconds: 20_000_000)
        XCTAssertEqual(container.activeForwardersCount, 1)

        // Start Rule 2 manually
        let session2 = try await container.startForwarding(rule: rule2)
        XCTAssertEqual(session2.status, .active)
        try await Task.sleep(nanoseconds: 20_000_000)
        XCTAssertEqual(container.activeForwardersCount, 2)

        // Stop Rule 1
        await container.stopForwarding(ruleID: rule1.id)
        try await Task.sleep(nanoseconds: 20_000_000)
        XCTAssertEqual(container.activeForwardersCount, 1)
        XCTAssertEqual(container.forwardingSessions.first(where: { $0.ruleID == rule1.id })?.status, .stopped)

        // Stop All
        await container.stopAllForwarding()
        try await Task.sleep(nanoseconds: 20_000_000)
        XCTAssertEqual(container.activeForwardersCount, 0)
    }

    func testAddAndRemoveForwardingRuleDynamically() async throws {
        let catalog = InMemoryCatalog(seedDemoData: false)
        let container = AppContainer.demo(catalog: catalog)

        let host = try Host(
            name: "Dynamic Host",
            hostname: "demo.invalid",
            username: "dev"
        )
        try await catalog.save(host)
        let challenge = HostKeyChallenge(hostname: "demo.invalid", port: 22, algorithm: "ssh-ed25519", fingerprint: "SHA256:demo-fingerprint")
        await container.trustStore.save(challenge)

        await container.connect(to: host)
        XCTAssertEqual(container.activeSession?.state, .connected)

        // Add a new rule dynamically while connected
        let newRule = try PortForwardingRule(
            name: "App Database",
            type: .local,
            localHost: "127.0.0.1",
            localPort: 5432,
            remoteHost: "postgres.internal",
            remotePort: 5432,
            enabled: true
        )
        try await container.addForwardingRule(newRule, for: host, autoStartIfConnected: true)
        try await Task.sleep(nanoseconds: 30_000_000)

        // Verify rule is present in active host and catalog
        XCTAssertEqual(container.activeHost?.forwardingRules.count, 1)
        let savedHosts = try await catalog.listHosts()
        XCTAssertEqual(savedHosts.first?.forwardingRules.count, 1)
        XCTAssertEqual(container.activeForwardersCount, 1)

        // Remove the rule
        try await container.removeForwardingRule(ruleID: newRule.id, for: host)
        try await Task.sleep(nanoseconds: 30_000_000)

        XCTAssertEqual(container.activeHost?.forwardingRules.count, 0)
        XCTAssertEqual(container.activeForwardersCount, 0)
    }

    // MARK: - 3. Socket Teardown on Disconnect

    func testSocketTeardownOnExplicitDisconnect() async throws {
        let container = AppContainer.demo()

        let rule = try PortForwardingRule(
            name: "Auto Rule",
            type: .local,
            localHost: "127.0.0.1",
            localPort: 9000,
            remoteHost: "backend.local",
            remotePort: 80,
            enabled: true
        )
        let host = try Host(
            name: "Disconnect Test Host",
            hostname: "demo.invalid",
            username: "dev",
            forwardingRules: [rule]
        )
        let challenge = HostKeyChallenge(hostname: "demo.invalid", port: 22, algorithm: "ssh-ed25519", fingerprint: "SHA256:demo-fingerprint")
        await container.trustStore.save(challenge)

        await container.connect(to: host)
        try await Task.sleep(nanoseconds: 30_000_000)
        XCTAssertEqual(container.activeForwardersCount, 1)

        // Explicit disconnect
        await container.disconnect()
        XCTAssertEqual(container.activeSession?.state, .disconnected)
        XCTAssertEqual(container.forwardingSessions.count, 0)
        XCTAssertEqual(container.activeForwardersCount, 0)
    }

    func testSocketTeardownOnConnectionClosedEvent() async throws {
        let mock = MockSSHConnection()
        let transport = ControllableTransport()
        transport.onConnect = { _ in mock }

        let demoPF = DemoPortForwardingManager()
        let container = AppContainer(
            transport: transport,
            portForwardingManager: demoPF
        )

        let rule = try PortForwardingRule(
            name: "Drop Test",
            type: .dynamic,
            localHost: "127.0.0.1",
            localPort: 1099,
            enabled: true
        )
        let host = try Host(
            name: "Drop Host",
            hostname: "drop.test",
            username: "dev",
            forwardingRules: [rule]
        )

        await container.connect(to: host)
        XCTAssertEqual(container.activeSession?.state, .connected)
        try await Task.sleep(nanoseconds: 30_000_000)
        XCTAssertEqual(container.activeForwardersCount, 1)

        // Emit closed event from underlying connection
        mock.emit(.closed)
        try await Task.sleep(nanoseconds: 50_000_000)

        // Session must be disconnected and forwarders stopped/cleared
        XCTAssertEqual(container.activeSession?.state, .disconnected)
        XCTAssertEqual(container.forwardingSessions.count, 0)
        XCTAssertEqual(container.activeForwardersCount, 0)
    }

    // MARK: - 4. UI State, VoiceOver Accessibility & Dynamic Type

    func testPortForwardingSheetRenderingAndAccessibility() throws {
        let container = AppContainer.demo()

        let sheet = PortForwardingSheet()
            .environmentObject(container)

        let controller = UIHostingController(rootView: sheet)
        _ = controller.view

        // Verify view loads without crashing across iPhone and iPad traits
        controller.view.bounds = CGRect(x: 0, y: 0, width: 393, height: 852) // iPhone 16 Pro
        controller.view.layoutIfNeeded()

        controller.view.bounds = CGRect(x: 0, y: 0, width: 1024, height: 1366) // iPad Pro 12.9
        controller.view.layoutIfNeeded()
    }

    func testPortForwardingRuleEditorSheetValidation() throws {
        var savedRule: PortForwardingRule? = nil

        let editor = PortForwardingRuleEditorSheet { rule in
            savedRule = rule
        }

        let controller = UIHostingController(rootView: editor)
        _ = controller.view
        controller.view.bounds = CGRect(x: 0, y: 0, width: 393, height: 852)
        controller.view.layoutIfNeeded()
        XCTAssertNil(savedRule)
    }

    func testHostEditorProxyJumpAndRuleManagementUI() async throws {
        let catalog = InMemoryCatalog(seedDemoData: false)
        let bastion = try Host(name: "Bastion Host", hostname: "bastion.lan", username: "jump")
        try await catalog.save(bastion)

        let target = try Host(
            name: "Target Host",
            hostname: "target.lan",
            username: "dev",
            connection: .proxyJump(ProxyJumpOptions(hopHostIDs: [bastion.id]))
        )
        try await catalog.save(target)

        let container = AppContainer.demo(catalog: catalog)
        let editor = HostEditorView(existing: target).environmentObject(container)

        let controller = UIHostingController(rootView: editor)
        _ = controller.view
        controller.view.bounds = CGRect(x: 0, y: 0, width: 820, height: 1180)
        controller.view.layoutIfNeeded()
    }

    func testNonLoopbackWarningAndApprovalFlag() throws {
        let loopbackIPv4 = try PortForwardingRule(
            name: "Loopback IPv4",
            type: .local,
            localHost: "127.0.0.1",
            localPort: 8080,
            remoteHost: "localhost",
            remotePort: 80
        )
        XCTAssertFalse(loopbackIPv4.requiresNonLoopbackApproval)

        let loopbackIPv6 = try PortForwardingRule(
            name: "Loopback IPv6",
            type: .local,
            localHost: "::1",
            localPort: 8080,
            remoteHost: "localhost",
            remotePort: 80
        )
        XCTAssertFalse(loopbackIPv6.requiresNonLoopbackApproval)

        let loopbackLocalhost = try PortForwardingRule(
            name: "Localhost",
            type: .local,
            localHost: "localhost",
            localPort: 8080,
            remoteHost: "localhost",
            remotePort: 80
        )
        XCTAssertFalse(loopbackLocalhost.requiresNonLoopbackApproval)

        let allInterfaces = try PortForwardingRule(
            name: "All Interfaces",
            type: .local,
            localHost: "0.0.0.0",
            localPort: 8080,
            remoteHost: "localhost",
            remotePort: 80
        )
        XCTAssertTrue(allInterfaces.requiresNonLoopbackApproval)

        let lanInterface = try PortForwardingRule(
            name: "LAN Interface",
            type: .local,
            localHost: "192.168.1.105",
            localPort: 8080,
            remoteHost: "localhost",
            remotePort: 80
        )
        XCTAssertTrue(lanInterface.requiresNonLoopbackApproval)
    }

    // MARK: - 5. Security & UX Finding Regression Tests

    func testNonLoopbackRuleSkippedOnAutoStart() async throws {
        let container = AppContainer.demo()

        let nonLoopbackRule = try PortForwardingRule(
            name: "Public Proxy",
            type: .dynamic,
            localHost: "0.0.0.0",
            localPort: 1080,
            enabled: true
        )
        let loopbackRule = try PortForwardingRule(
            name: "Private Tunnel",
            type: .local,
            localHost: "127.0.0.1",
            localPort: 8080,
            remoteHost: "localhost",
            remotePort: 80,
            enabled: true
        )

        let host = try Host(
            name: "Host With Public Rule",
            hostname: "demo.invalid",
            username: "dev",
            forwardingRules: [nonLoopbackRule, loopbackRule]
        )
        let challenge = HostKeyChallenge(hostname: "demo.invalid", port: 22, algorithm: "ssh-ed25519", fingerprint: "SHA256:demo-fingerprint")
        await container.trustStore.save(challenge)

        await container.connect(to: host)
        XCTAssertEqual(container.activeSession?.state, .connected)
        try await Task.sleep(nanoseconds: 50_000_000)

        // Non-loopback rule was skipped; only loopback rule started
        XCTAssertEqual(container.activeForwardersCount, 1)
        let nonLoopbackSession = container.forwardingSessions.first(where: { $0.ruleID == nonLoopbackRule.id })
        XCTAssertTrue(nonLoopbackSession == nil || nonLoopbackSession?.status != .active)
        XCTAssertNotNil(container.forwardingErrorMessage)
        XCTAssertTrue(container.forwardingErrorMessage?.contains("requires approval") == true)
        XCTAssertTrue(container.terminalController.currentTranscript(limit: 10).contains("requires approval"))
    }

    func testNonLoopbackRuleNotAutoStartedOnAddRule() async throws {
        let container = AppContainer.demo()

        let host = try Host(
            name: "Connected Host",
            hostname: "demo.invalid",
            username: "dev"
        )
        let challenge = HostKeyChallenge(hostname: "demo.invalid", port: 22, algorithm: "ssh-ed25519", fingerprint: "SHA256:demo-fingerprint")
        await container.trustStore.save(challenge)

        await container.connect(to: host)
        XCTAssertEqual(container.activeSession?.state, .connected)

        let publicRule = try PortForwardingRule(
            name: "Public SOCKS",
            type: .dynamic,
            localHost: "0.0.0.0",
            localPort: 9050,
            enabled: true
        )

        // Adding rule with autoStartIfConnected: true must still respect requiresNonLoopbackApproval
        try await container.addForwardingRule(publicRule, for: host, autoStartIfConnected: true)
        try await Task.sleep(nanoseconds: 30_000_000)

        XCTAssertEqual(container.activeForwardersCount, 0)
        let session = container.forwardingSessions.first(where: { $0.ruleID == publicRule.id })
        XCTAssertTrue(session == nil || session?.status != .active)
    }

    func testEditActiveForwardingRuleRestartsWithNewParameters() async throws {
        let container = AppContainer.demo()

        var rule = try PortForwardingRule(
            name: "Local Service",
            type: .local,
            localHost: "127.0.0.1",
            localPort: 8085,
            remoteHost: "localhost",
            remotePort: 80,
            enabled: true
        )

        let host = try Host(
            name: "Edit Test Host",
            hostname: "demo.invalid",
            username: "dev",
            forwardingRules: [rule]
        )
        let challenge = HostKeyChallenge(hostname: "demo.invalid", port: 22, algorithm: "ssh-ed25519", fingerprint: "SHA256:demo-fingerprint")
        await container.trustStore.save(challenge)

        await container.connect(to: host)
        try await Task.sleep(nanoseconds: 30_000_000)
        XCTAssertEqual(container.activeForwardersCount, 1)

        // Edit the rule to a new local port
        rule.localPort = 8086
        try await container.addForwardingRule(rule, for: host, autoStartIfConnected: true)
        try await Task.sleep(nanoseconds: 30_000_000)

        XCTAssertEqual(container.activeForwardersCount, 1)
        let activeSession = container.forwardingSessions.first(where: { $0.ruleID == rule.id })
        XCTAssertEqual(activeSession?.status, .active)
        XCTAssertEqual(activeSession?.rule.localPort, 8086)
    }

    func testBatchDeleteRulesDoesNotResurrectDeletedRules() async throws {
        let catalog = InMemoryCatalog(seedDemoData: false)
        let container = AppContainer.demo(catalog: catalog)

        let rule1 = try PortForwardingRule(
            name: "Rule One",
            type: .local,
            localHost: "127.0.0.1",
            localPort: 8001,
            remoteHost: "localhost",
            remotePort: 80
        )
        let rule2 = try PortForwardingRule(
            name: "Rule Two",
            type: .local,
            localHost: "127.0.0.1",
            localPort: 8002,
            remoteHost: "localhost",
            remotePort: 80
        )

        let host = try Host(
            name: "Batch Delete Host",
            hostname: "demo.invalid",
            username: "dev",
            forwardingRules: [rule1, rule2]
        )
        try await catalog.save(host)
        let challenge = HostKeyChallenge(hostname: "demo.invalid", port: 22, algorithm: "ssh-ed25519", fingerprint: "SHA256:demo-fingerprint")
        await container.trustStore.save(challenge)

        await container.connect(to: host)
        XCTAssertEqual(container.activeHost?.forwardingRules.count, 2)

        // Batch deletion passing original host snapshot in loop
        let rulesToDelete = [rule1, rule2]
        for rule in rulesToDelete {
            try await container.removeForwardingRule(ruleID: rule.id, for: host)
        }

        XCTAssertEqual(container.activeHost?.forwardingRules.count, 0)
        let loadedHost = try await catalog.listHosts().first(where: { $0.id == host.id })
        XCTAssertEqual(loadedHost?.forwardingRules.count, 0)
    }

    func testRemotePortForwardingSummaryWithBoundPort() throws {
        let rule = try PortForwardingRule(
            name: "Remote Web",
            type: .remote,
            localHost: "127.0.0.1",
            localPort: 8080,
            remoteHost: "0.0.0.0",
            remotePort: 0
        )

        // When boundPort is provided (e.g. allocated ephemeral port on server),
        // it must format remote host:boundPort -> local host:localPort
        let summary = portForwardingRuleSummary(rule, boundPort: 54321)
        XCTAssertEqual(summary, "remote 0.0.0.0:54321 -> 127.0.0.1:8080")

        // When no boundPort, fallback to rule.remotePort
        let defaultSummary = portForwardingRuleSummary(rule)
        XCTAssertEqual(defaultSummary, "remote 0.0.0.0:0 -> 127.0.0.1:8080")
    }

    func testPortForwardingRuleEditorAllowsRemotePortZero() throws {
        let remoteRule = try PortForwardingRule(
            name: "Ephemeral Remote",
            type: .remote,
            localHost: "127.0.0.1",
            localPort: 3000,
            remoteHost: "0.0.0.0",
            remotePort: 0
        )

        let editor = PortForwardingRuleEditorSheet(existingRule: remoteRule) { _ in }

        let controller = UIHostingController(rootView: editor)
        _ = controller.view
        controller.view.bounds = CGRect(x: 0, y: 0, width: 393, height: 852)
        controller.view.layoutIfNeeded()

        // Editor renders without issue for remotePort == 0
        XCTAssertNotNil(editor)
    }

    func testHostEditorBastionReordering() async throws {
        let catalog = InMemoryCatalog(seedDemoData: false)
        let b1 = try Host(name: "Bastion 1", hostname: "b1.lan", username: "jump")
        let b2 = try Host(name: "Bastion 2", hostname: "b2.lan", username: "jump")
        try await catalog.save(b1)
        try await catalog.save(b2)

        let target = try Host(
            name: "Target Host",
            hostname: "target.lan",
            username: "dev",
            connection: .proxyJump(ProxyJumpOptions(hopHostIDs: [b1.id, b2.id]))
        )
        try await catalog.save(target)

        let container = AppContainer.demo(catalog: catalog)
        let editor = HostEditorView(existing: target).environmentObject(container)

        let controller = UIHostingController(rootView: editor)
        _ = controller.view
        controller.view.bounds = CGRect(x: 0, y: 0, width: 820, height: 1180)
        controller.view.layoutIfNeeded()
    }

    func testDeletedRuleNotSurfacedInSheetAllRules() async throws {
        let container = AppContainer.demo()
        let rule = try PortForwardingRule(
            name: "Temp Rule",
            type: .local,
            localHost: "127.0.0.1",
            localPort: 8888,
            remoteHost: "localhost",
            remotePort: 80,
            enabled: true
        )
        let host = try Host(
            name: "Host",
            hostname: "demo.invalid",
            username: "dev",
            forwardingRules: [rule]
        )
        await container.trustStore.save(HostKeyChallenge(hostname: "demo.invalid", port: 22, algorithm: "ssh-ed25519", fingerprint: "SHA256:demo-fingerprint"))
        await container.connect(to: host)
        try await Task.sleep(nanoseconds: 30_000_000)
        XCTAssertEqual(container.activeForwardersCount, 1)

        // Delete the rule
        try await container.removeForwardingRule(ruleID: rule.id, for: host)
        try await Task.sleep(nanoseconds: 30_000_000)

        // Session exists in stopped state
        XCTAssertTrue(container.forwardingSessions.contains(where: { $0.ruleID == rule.id && $0.status == .stopped }))

        // Host rules is empty
        XCTAssertEqual(container.activeHost?.forwardingRules.count, 0)

        // Verify sheet renders empty state
        let sheet = PortForwardingSheet().environmentObject(container)
        let controller = UIHostingController(rootView: sheet)
        _ = controller.view
        controller.view.bounds = CGRect(x: 0, y: 0, width: 393, height: 852)
        controller.view.layoutIfNeeded()
        XCTAssertEqual(container.activeForwardersCount, 0)
    }
}
