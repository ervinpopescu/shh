import XCTest
@testable import Shh
import ShhCore
import ShhSSH

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

@MainActor
final class AppContainerTests: XCTestCase {

    func testProductionDefaultUsesLiveSSHTransportWithSharedCredentialStore() async {
        let container = AppContainer()
        XCTAssertTrue(container.transport is LiveSSHTransport, "Production default must use LiveSSHTransport")
        XCTAssertFalse(container.isDemo, "Production default is not demo mode")

        let liveTransport = container.transport as? LiveSSHTransport
        XCTAssertNotNil(liveTransport)

        // Verify that LiveSSHTransport received the same CredentialStore instance as AppContainer
        let customStore = InMemoryCredentialStore()
        let containerWithCustomStore = AppContainer(credentialStore: customStore)
        let customLive = containerWithCustomStore.transport as? LiveSSHTransport
        XCTAssertNotNil(customLive)
        XCTAssertTrue((customLive?.credentialStore as? InMemoryCredentialStore) === customStore)
        XCTAssertTrue((containerWithCustomStore.credentialStore as? InMemoryCredentialStore) === customStore)
    }

    func testExplicitDemoConstructionPath() {
        let demoContainer = AppContainer.demo()
        XCTAssertTrue(demoContainer.transport is DemoSSHTransport, "AppContainer.demo() must use DemoSSHTransport")
        XCTAssertTrue(demoContainer.isDemo, "isDemo must be true for demo container")

        let explicitContainer = AppContainer(transport: DemoSSHTransport())
        XCTAssertTrue(explicitContainer.transport is DemoSSHTransport, "Explicit init must preserve DemoSSHTransport")
        XCTAssertTrue(explicitContainer.isDemo)
    }

    func testCommandPolicyGateEnforcedOnSend() async throws {
        let container = AppContainer.demo()
        let host = try Host(name: "Demo Host", hostname: "demo.invalid", username: "dev")

        // Before connection, send must return false
        let sendBeforeConnect = await container.send("echo hi", approved: false)
        XCTAssertFalse(sendBeforeConnect, "Cannot send before connecting")

        // Connect via demo transport (pre-approving the demo fingerprint)
        let demoChallenge = HostKeyChallenge(hostname: "demo.invalid", port: 22, algorithm: "ssh-ed25519", fingerprint: "SHA256:demo-fingerprint")
        await container.trustStore.save(demoChallenge)
        await container.connect(to: host)
        XCTAssertEqual(container.activeSession?.state, .connected)

        // 1. Safe commands: allowed without explicit approval
        let safeResult = await container.send("ls -la\n", approved: false)
        XCTAssertTrue(safeResult, "Safe command must be permitted without approval")

        // 2. Review-required command: blocked without approval, permitted with approval
        let reviewBlocked = await container.send("shutdown now\n", approved: false)
        XCTAssertFalse(reviewBlocked, "Review-required command must be blocked without approval")

        let reviewApproved = await container.send("shutdown now\n", approved: true)
        XCTAssertTrue(reviewApproved, "Review-required command must succeed when approved")

        // 3. Destructive/blocked command: blocked regardless of approval flag
        let destructiveNotApproved = await container.send("rm -rf /\n", approved: false)
        XCTAssertFalse(destructiveNotApproved, "Dangerous command must be blocked without approval")

        let destructiveWithApproval = await container.send("rm -rf /\n", approved: true)
        XCTAssertFalse(destructiveWithApproval, "Dangerous command must remain blocked even with approval")

        // 4. After disconnect, sending must fail
        await container.disconnect()
        let afterDisconnect = await container.send("pwd\n", approved: false)
        XCTAssertFalse(afterDisconnect, "Cannot send after disconnecting")
    }

    func testHostKeyApprovalAndReconnectFlow() async throws {
        let container = AppContainer.demo()
        let host = try Host(name: "Unknown Host", hostname: "unknown.invalid", username: "dev")

        // Attempt 1: Unknown key triggers approval required
        await container.connect(to: host)
        XCTAssertNotNil(container.pendingTrustChallenge, "Unknown host key must require approval")
        XCTAssertEqual(container.activeSession?.state, .disconnected)
        let challenge = container.pendingTrustChallenge
        XCTAssertEqual(challenge?.hostname, "unknown.invalid")

        // Approve permanently: must save and auto-reconnect
        await container.approvePendingHostKey(permanently: true)
        XCTAssertNil(container.pendingTrustChallenge, "Pending challenge should clear after approval")
        XCTAssertEqual(container.activeSession?.state, .connected, "Should reconnect to host after approval")

        // Verify permanent record in trust store
        let records = await container.trustStore.allRecords()
        XCTAssertTrue(records.contains { $0.hostname == "unknown.invalid" })
    }

    func testHostKeyApprovalOnceAndRejectFlow() async throws {
        // Test rejection flow
        let container = AppContainer.demo()
        let host = try Host(name: "Reject Host", hostname: "reject.invalid", username: "dev")

        await container.connect(to: host)
        XCTAssertNotNil(container.pendingTrustChallenge)

        container.rejectPendingHostKey()
        XCTAssertNil(container.pendingTrustChallenge)
        XCTAssertEqual(container.activeSession?.state, .disconnected)

        // Test trustOnce flow
        let containerOnce = AppContainer.demo()
        let onceHost = try Host(name: "Once Host", hostname: "once.invalid", username: "dev")

        await containerOnce.connect(to: onceHost)
        XCTAssertNotNil(containerOnce.pendingTrustChallenge)

        await containerOnce.approvePendingHostKey(permanently: false)
        XCTAssertNil(containerOnce.pendingTrustChallenge)
        XCTAssertEqual(containerOnce.activeSession?.state, .connected)
    }

    func testChangedHostKeyRemainsBlocked() async throws {
        let trustStore = InMemoryTrustStore()
        let mismatchedChallenge = HostKeyChallenge(
            hostname: "changed.invalid",
            port: 22,
            algorithm: "ssh-ed25519",
            fingerprint: "SHA256:differentOldFingerprint"
        )
        await trustStore.save(mismatchedChallenge)

        let container = AppContainer.demo(trustStore: trustStore)
        let host = try Host(name: "Changed Host", hostname: "changed.invalid", username: "dev")

        await container.connect(to: host)

        XCTAssertEqual(container.activeSession?.state, .failed, "Changed host key must fail")
        XCTAssertNil(container.pendingTrustChallenge, "Changed host key must NOT offer approval challenge")
        XCTAssertEqual(container.terminalText, "Connection refused: host key has changed.")
    }

    func testCredentialsNotLoadedBeforeHostKeyAcceptance() async throws {
        let credStore = CountingCredentialStore()
        try await credStore.save(Data("topsecretpassword".utf8), reference: "ref-secret")
        let identity = try IdentityDescriptor(name: "Secret Pass", kind: .password, keychainReference: "ref-secret")

        let container = AppContainer.demo(credentialStore: credStore)
        try await container.catalog.save(identity)
        let host = try Host(name: "Secure Host", hostname: "secure.invalid", username: "dev", identityID: identity.id)

        // Connect to unknown host - host key is NOT yet approved
        await container.connect(to: host)
        XCTAssertNotNil(container.pendingTrustChallenge)
        XCTAssertEqual(credStore.loadCallCount, 0, "CredentialStore must NOT be queried before host key is accepted")

        // Now approve the host key
        await container.approvePendingHostKey(permanently: true)
        XCTAssertEqual(container.activeSession?.state, .connected)
        XCTAssertGreaterThan(credStore.loadCallCount, 0, "CredentialStore loaded only after host key approved")
    }

    func testRedactedConnectionStates() async throws {
        // Test statusMessage mapping for all error kinds
        XCTAssertEqual(AppContainer.statusMessage(for: TransportError.authenticationRequired), "Authentication required.")
        XCTAssertEqual(AppContainer.statusMessage(for: TransportError.timeout), "Connection timed out.")
        XCTAssertEqual(AppContainer.statusMessage(for: TransportError.networkUnavailable), "Network unavailable.")
        XCTAssertEqual(AppContainer.statusMessage(for: TransportError.unsupported), "Unsupported configuration.")
        XCTAssertEqual(AppContainer.statusMessage(for: TransportError.invalidConfiguration), "Unsupported configuration.")
        XCTAssertEqual(AppContainer.statusMessage(for: TransportError.cancelled), "Connection cancelled.")
        XCTAssertEqual(AppContainer.statusMessage(for: TransportError.hostKeyChanged(old: "x", new: "y")), "Connection refused: host key has changed.")
        XCTAssertEqual(
            AppContainer.statusMessage(for: TransportError.remoteFailure("internal libssh error: failed to decrypt token")),
            "Connection failed.",
            "Raw third-party errors must never be surfaced"
        )
        XCTAssertEqual(AppContainer.statusMessage(for: NSError(domain: "test", code: -1)), "Connection unavailable.")

        // Test mock transport yielding each failure to verify activeSession state and terminalText
        struct FailingTransport: SSHTransport {
            let error: TransportError
            func connect(host: Host, identity: IdentityDescriptor?, trustEvaluator: any HostTrustEvaluator, initialSize: TerminalSize) async throws -> any SSHConnection {
                throw error
            }
        }

        let testCases: [(TransportError, TerminalSessionState, String)] = [
            (.authenticationRequired, .failed, "Authentication required."),
            (.timeout, .failed, "Connection timed out."),
            (.networkUnavailable, .failed, "Network unavailable."),
            (.unsupported, .failed, "Unsupported configuration."),
            (.cancelled, .disconnected, "Connection cancelled."),
            (.hostKeyChanged(old: "1", new: "2"), .failed, "Connection refused: host key has changed."),
            (.remoteFailure("raw libssh internal error with credentials password123"), .failed, "Connection failed.")
        ]

        let host = try Host(name: "Test", hostname: "test.invalid", username: "user")
        for (error, expectedState, expectedText) in testCases {
            let container = AppContainer(transport: FailingTransport(error: error))
            await container.connect(to: host)
            XCTAssertEqual(container.activeSession?.state, expectedState, "State for \(error)")
            XCTAssertEqual(container.terminalText, expectedText, "Text for \(error)")
            XCTAssertFalse(container.terminalText.contains("password123"), "Credentials must never leak into terminalText")
        }
    }

    func testNoSilentFallbackFromLiveFailureToDemo() async throws {
        struct FailingLiveTransport: SSHTransport {
            func connect(host: Host, identity: IdentityDescriptor?, trustEvaluator: any HostTrustEvaluator, initialSize: TerminalSize) async throws -> any SSHConnection {
                throw TransportError.networkUnavailable
            }
        }

        let container = AppContainer(transport: FailingLiveTransport())
        let host = try Host(name: "Live Host", hostname: "live.invalid", username: "user")

        await container.connect(to: host)

        XCTAssertEqual(container.activeSession?.state, .failed)
        XCTAssertEqual(container.terminalText, "Network unavailable.")
        // Must NOT have silently fallen back to DemoSSHTransport
        XCTAssertFalse(container.isDemo, "Failed live connection must not fall back to demo mode")
    }

    func testRedactorMaterialClearedOnDisconnectAndStreamTermination() async throws {
        let credStore = InMemoryCredentialStore()
        try await credStore.save(Data("my-secret-password".utf8), reference: "ref-secret-pwd")
        let identity = try IdentityDescriptor(name: "Secret", kind: .password, keychainReference: "ref-secret-pwd")

        let mockConnection = MockSSHConnection()
        let transport = ControllableTransport()
        transport.onConnect = { _ in mockConnection }

        let container = AppContainer(credentialStore: credStore, transport: transport)
        try await container.catalog.save(identity)
        let host = try Host(name: "Host", hostname: "host.invalid", username: "user", identityID: identity.id)

        // 1. Successful connection populates redactor
        await container.connect(to: host)
        XCTAssertEqual(container.activeSession?.state, .connected)
        XCTAssertEqual(container.redactor.secrets, ["my-secret-password"])

        // 2. Disconnect clears redactor
        await container.disconnect()
        XCTAssertEqual(container.activeSession?.state, .disconnected)
        XCTAssertTrue(container.redactor.secrets.isEmpty, "Redactor secrets must be cleared on disconnect")

        // 3. Reconnect populates redactor again
        let mockConnection2 = MockSSHConnection()
        transport.onConnect = { _ in mockConnection2 }
        await container.connect(to: host)
        XCTAssertEqual(container.redactor.secrets, ["my-secret-password"])

        // 4. Stream closed clears redactor
        mockConnection2.emit(.closed)
        try await Task.sleep(nanoseconds: 50_000_000)
        XCTAssertEqual(container.activeSession?.state, .disconnected)
        XCTAssertTrue(container.redactor.secrets.isEmpty, "Redactor secrets must be cleared on stream closed")

        // 5. Reconnect and stream error clears redactor
        let mockConnection3 = MockSSHConnection()
        transport.onConnect = { _ in mockConnection3 }
        await container.connect(to: host)
        XCTAssertEqual(container.redactor.secrets, ["my-secret-password"])

        mockConnection3.emit(.error(TransportError.remoteFailure("peer reset")))
        try await Task.sleep(nanoseconds: 50_000_000)
        XCTAssertEqual(container.activeSession?.state, .failed)
        XCTAssertTrue(container.redactor.secrets.isEmpty, "Redactor secrets must be cleared on stream error")
    }

    func testInFlightConnectionAttemptDoesNotOverrideExplicitDisconnect() async throws {
        let mockConnection = MockSSHConnection()
        let transport = ControllableTransport()
        let resumeGate = Gate()

        transport.onConnect = { _ in
            await resumeGate.wait()
            return mockConnection
        }

        let container = AppContainer(transport: transport)
        let host = try Host(name: "Host", hostname: "host.invalid", username: "user")

        let connectTask = Task {
            await container.connect(to: host)
        }

        // Give task a moment to enter connecting state
        try await Task.sleep(nanoseconds: 30_000_000)
        XCTAssertEqual(container.activeSession?.state, .connecting)

        // User explicitly disconnects while connection is in-flight
        await container.disconnect()
        XCTAssertEqual(container.activeSession?.state, .disconnected)

        // Let transport connect finish
        await resumeGate.open()
        await connectTask.value

        // Session must remain disconnected and connection must be closed
        XCTAssertEqual(container.activeSession?.state, .disconnected, "In-flight connect must not resurrect disconnected session")
        XCTAssertNil(container.connection)
        XCTAssertTrue(mockConnection.isClosed, "Resurrected connection must be closed immediately")
    }

    func testStaleConnectionFailureDoesNotOverwriteCurrentSessionOrState() async throws {
        let transport = ControllableTransport()
        let resumeGate = Gate()
        let mockB = MockSSHConnection()

        let hostA = try Host(name: "HostA", hostname: "hosta.invalid", username: "user")
        let hostB = try Host(name: "HostB", hostname: "hostb.invalid", username: "user")

        transport.onConnect = { host in
            if host.id == hostA.id {
                await resumeGate.wait()
                throw TransportError.timeout
            } else {
                return mockB
            }
        }

        let container = AppContainer(transport: transport)

        let connectTask = Task {
            await container.connect(to: hostA)
        }

        try await Task.sleep(nanoseconds: 30_000_000)
        XCTAssertEqual(container.activeSession?.state, .connecting)
        XCTAssertEqual(container.activeSession?.hostID, hostA.id)

        // User disconnects hostA
        await container.disconnect()
        XCTAssertEqual(container.activeSession?.state, .disconnected)

        // Now connect to hostB with an immediate successful connection
        await container.connect(to: hostB)
        XCTAssertEqual(container.activeSession?.state, .connected)
        XCTAssertEqual(container.activeSession?.hostID, hostB.id)

        // Now let hostA's failing connection finish throwing
        await resumeGate.open()
        await connectTask.value

        // Stale failure must not have affected hostB
        XCTAssertEqual(container.activeSession?.state, .connected)
        XCTAssertEqual(container.activeSession?.hostID, hostB.id)
        XCTAssertNotEqual(container.terminalText, "Connection timed out.")
    }

    func testStaleConnectionFailureAfterDisconnectDoesNotMutateStateToFailed() async throws {
        let transport = ControllableTransport()
        let resumeGate = Gate()

        transport.onConnect = { _ in
            await resumeGate.wait()
            throw TransportError.timeout
        }

        let container = AppContainer(transport: transport)
        let host = try Host(name: "Host", hostname: "host.invalid", username: "user")

        let connectTask = Task {
            await container.connect(to: host)
        }

        try await Task.sleep(nanoseconds: 30_000_000)
        XCTAssertEqual(container.activeSession?.state, .connecting)

        // User disconnects while in-flight
        await container.disconnect()
        XCTAssertEqual(container.activeSession?.state, .disconnected)

        // Transport throws timeout
        await resumeGate.open()
        await connectTask.value

        // State must remain disconnected, NOT overwritten with failed or timeout message
        XCTAssertEqual(container.activeSession?.state, .disconnected)
        XCTAssertNotEqual(container.terminalText, "Connection timed out.")
    }

    func testHostDetailViewAndSessionScoping() async throws {
        let container = AppContainer.demo()
        let hostA = try Host(name: "Host A", hostname: "a.invalid", username: "user")
        let hostB = try Host(name: "Host B", hostname: "b.invalid", username: "user")

        // Pre-approve host A's key
        let challengeA = HostKeyChallenge(hostname: "a.invalid", port: 22, algorithm: "ssh-ed25519", fingerprint: "SHA256:demo-fingerprint")
        await container.trustStore.save(challengeA)

        // Connect to host A
        await container.connect(to: hostA)
        XCTAssertEqual(container.activeSession?.state, .connected)
        XCTAssertEqual(container.activeSession?.hostID, hostA.id)

        // Verify active session matches host A but NOT host B
        XCTAssertEqual(container.activeSession?.hostID, hostA.id)
        XCTAssertNotEqual(container.activeSession?.hostID, hostB.id)

        // Verify SwiftUI view instantiation
        let rootView = RootView().environmentObject(container)
        let detailViewA = HostDetailView(host: hostA).environmentObject(container)
        let detailViewB = HostDetailView(host: hostB).environmentObject(container)

        _ = rootView
        _ = detailViewA
        _ = detailViewB
    }
}

private actor Gate {
    private var isOpen = false
    private var continuations: [CheckedContinuation<Void, Never>] = []

    func wait() async {
        if isOpen { return }
        await withCheckedContinuation { cont in
            continuations.append(cont)
        }
    }

    func open() {
        isOpen = true
        for cont in continuations {
            cont.resume()
        }
        continuations.removeAll()
    }
}

private final class MockSSHConnection: SSHConnection, @unchecked Sendable {
    private let lock = NSLock()
    private(set) var isClosed = false
    private var streamContinuation: AsyncThrowingStream<TerminalEvent, Error>.Continuation?

    func events() async -> AsyncThrowingStream<TerminalEvent, Error> {
        AsyncThrowingStream { continuation in
            self.lock.withLock {
                self.streamContinuation = continuation
            }
        }
    }

    func send(_ data: Data) async throws {}
    func resize(_ size: TerminalSize) async throws {}
    func close() async {
        lock.withLock {
            isClosed = true
            streamContinuation?.finish()
        }
    }

    func emit(_ event: TerminalEvent) {
        _ = lock.withLock {
            streamContinuation?.yield(event)
        }
    }
}

private final class ControllableTransport: SSHTransport, @unchecked Sendable {
    var onConnect: (@Sendable (Host) async throws -> any SSHConnection)?

    func connect(host: Host, identity: IdentityDescriptor?, trustEvaluator: any HostTrustEvaluator, initialSize: TerminalSize) async throws -> any SSHConnection {
        if let onConnect {
            return try await onConnect(host)
        }
        return MockSSHConnection()
    }
}
