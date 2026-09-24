import XCTest
@testable import Shh
import Crypto
import ShhCore
import ShhSSH
import ShhTerminal
@testable import ShhTerminal
import SwiftUI
#if canImport(UIKit)
import UIKit
#endif

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

    // MARK: - Stage 2 Milestone 3 Tests

    func testDualPathSafety_RawInteractiveBypassesPolicy_ValidatedCommandEnforcesPolicy() async throws {
        let mockConnection = MockSSHConnection()
        let transport = ControllableTransport()
        transport.onConnect = { _ in mockConnection }

        let container = AppContainer(transport: transport)
        let host = try Host(name: "DualPathHost", hostname: "dualpath.invalid", username: "user")

        // 1. Before connection, neither path sends
        let rawBefore = await container.sendRawInteractive(Data("pwd\n".utf8))
        XCTAssertFalse(rawBefore)
        let validatedBefore = await container.sendValidatedCommand("pwd\n", approved: false)
        XCTAssertFalse(validatedBefore)

        // Connect
        await container.connect(to: host)
        XCTAssertEqual(container.activeSession?.state, .connected)

        // 2. sendRawInteractive: raw interactive keystrokes bypass CommandPolicy
        // Destructive command string sent as raw bytes directly to connection
        let dangerousBytes = Data("rm -rf /\n".utf8)
        let rawDangerousResult = await container.sendRawInteractive(dangerousBytes)
        XCTAssertTrue(rawDangerousResult, "sendRawInteractive must transmit without CommandPolicy gating")
        XCTAssertEqual(mockConnection.sentData.last, dangerousBytes)

        // Control characters (e.g. Ctrl-C 0x03) sent as raw bytes
        let ctrlCBytes = Data([0x03])
        let rawCtrlCResult = await container.sendRawInteractive(ctrlCBytes)
        XCTAssertTrue(rawCtrlCResult, "sendRawInteractive must transmit control characters")
        XCTAssertEqual(mockConnection.sentData.last, ctrlCBytes)

        // 3. sendValidatedCommand: must strictly enforce CommandPolicy
        // Safe command: succeeds without explicit approval
        let safeResult = await container.sendValidatedCommand("ls -la\n", approved: false)
        XCTAssertTrue(safeResult, "Safe command passes validated path")
        XCTAssertEqual(mockConnection.sentData.last, Data("ls -la\n".utf8))

        // Review-required command: rejected without approval
        let preCount = mockConnection.sentData.count
        let reviewRejected = await container.sendValidatedCommand("shutdown now\n", approved: false)
        XCTAssertFalse(reviewRejected, "Review-required command rejected without approval")
        XCTAssertEqual(mockConnection.sentData.count, preCount, "Unapproved command must not be sent")

        // Review-required command: permitted with explicit approval
        let reviewApproved = await container.sendValidatedCommand("shutdown now\n", approved: true)
        XCTAssertTrue(reviewApproved, "Review-required command passes when approved")
        XCTAssertEqual(mockConnection.sentData.last, Data("shutdown now\n".utf8))

        // Blocked command: remains unsendable even when approved: true
        let blockedResult = await container.sendValidatedCommand("rm -rf /\n", approved: true)
        XCTAssertFalse(blockedResult, "Blocked command must remain unsendable even after approval")

        // 4. Disconnect closes both paths
        await container.disconnect()
        let rawAfter = await container.sendRawInteractive(Data("ls\n".utf8))
        XCTAssertFalse(rawAfter)
        let validatedAfter = await container.sendValidatedCommand("ls\n", approved: false)
        XCTAssertFalse(validatedAfter)
    }

    func testRawByteFidelityAcrossEncodersAndConnection() async throws {
        let mockConnection = MockSSHConnection()
        let transport = ControllableTransport()
        transport.onConnect = { _ in mockConnection }

        let container = AppContainer(transport: transport)
        let host = try Host(name: "FidelityHost", hostname: "fidelity.invalid", username: "user")
        await container.connect(to: host)

        let testCases: [(TerminalKey, Data)] = [
            (.escape, Data([0x1B])),
            (.tab(shift: false), Data([0x09])),
            (.tab(shift: true), Data([0x1B, 0x5B, 0x5A])),
            (.ctrlC, Data([0x03])),
            (.ctrlD, Data([0x04])),
            (.arrow(.up, modifiers: [], applicationCursor: false), Data([0x1B, 0x5B, 0x41])),
            (.arrow(.down, modifiers: [], applicationCursor: false), Data([0x1B, 0x5B, 0x42])),
            (.arrow(.right, modifiers: [], applicationCursor: false), Data([0x1B, 0x5B, 0x43])),
            (.arrow(.left, modifiers: [], applicationCursor: false), Data([0x1B, 0x5B, 0x44])),
            (.functionKey(1), Data([0x1B, 0x4F, 0x50])),
            (.functionKey(12), Data([0x1B, 0x5B, 0x32, 0x34, 0x7E]))
        ]

        for (key, expectedBytes) in testCases {
            let encoded = TerminalKeyEncoder.encode(key)
            XCTAssertEqual(encoded, expectedBytes, "Key \(key) encoding mismatch")

            let sent = await container.sendRawInteractive(encoded)
            XCTAssertTrue(sent)
            XCTAssertEqual(mockConnection.sentData.last, expectedBytes, "Delivered bytes mismatch for \(key)")
        }

        // Bracketed paste wrapping fidelity
        let pastePayload = "git status\nls -la"
        let bracketedPasteBytes = TerminalKeyEncoder.encodePaste(pastePayload, bracketed: true)
        let expectedPrefix = Data([0x1B, 0x5B, 0x32, 0x30, 0x30, 0x7E])
        let expectedSuffix = Data([0x1B, 0x5B, 0x32, 0x30, 0x31, 0x7E])
        XCTAssertTrue(bracketedPasteBytes.starts(with: expectedPrefix))
        XCTAssertEqual(bracketedPasteBytes.suffix(expectedSuffix.count), expectedSuffix)

        let pasteSent = await container.sendRawInteractive(bracketedPasteBytes)
        XCTAssertTrue(pasteSent)
        XCTAssertEqual(mockConnection.sentData.last, bracketedPasteBytes)
    }

    func testResizeDeliveryThroughAdapterDebounce() async throws {
        let mockConnection = MockSSHConnection()
        let transport = ControllableTransport()
        transport.onConnect = { _ in mockConnection }

        let container = AppContainer(transport: transport)
        let host = try Host(name: "ResizeHost", hostname: "resize.invalid", username: "user")
        await container.connect(to: host)

        // Rapidly report multiple sizes (simulating window resize / split drag)
        container.terminalController.handleResize(columns: 90, rows: 25)
        container.terminalController.handleResize(columns: 100, rows: 30)
        container.terminalController.handleResize(columns: 120, rows: 40)

        // Flush immediately delivers final size
        container.terminalController.flushResize()

        // Wait a small slice for MainActor task
        try await Task.sleep(nanoseconds: 30_000_000)

        // Only the final size should have been delivered
        XCTAssertEqual(mockConnection.resizeCalls.last, TerminalSize(columns: 120, rows: 40))
    }

    func testStaleSessionIsolationAndCallbackDetachment() async throws {
        let mockConnectionA = MockSSHConnection()
        let mockConnectionB = MockSSHConnection()
        let transport = ControllableTransport()

        let hostA = try Host(name: "HostA", hostname: "hosta.invalid", username: "user")
        let hostB = try Host(name: "HostB", hostname: "hostb.invalid", username: "user")

        transport.onConnect = { host in
            host.id == hostA.id ? mockConnectionA : mockConnectionB
        }

        let container = AppContainer(transport: transport)

        // 1. Connect to Host A
        await container.connect(to: hostA)
        XCTAssertEqual(container.activeSession?.hostID, hostA.id)
        XCTAssertNotNil(container.terminalController.onResize, "Callbacks must be attached")
        XCTAssertNotNil(container.terminalController.onOutput, "Callbacks must be attached")

        // 2. Disconnect Host A: callbacks must be detached immediately
        await container.disconnect()
        XCTAssertEqual(container.activeSession?.state, .disconnected)
        XCTAssertNil(container.terminalController.onResize, "Resize callback must be detached on disconnect")
        XCTAssertNil(container.terminalController.onOutput, "Output callback must be detached on disconnect")

        // Triggering controller resize / send after disconnect must NOT deliver to mockConnectionA
        container.terminalController.handleResize(columns: 100, rows: 30)
        container.terminalController.flushResize()
        container.terminalController.send(text: "orphan text")
        try await Task.sleep(nanoseconds: 20_000_000)
        XCTAssertTrue(mockConnectionA.resizeCalls.isEmpty, "Stale connection must not receive resize")
        XCTAssertTrue(mockConnectionA.sentData.isEmpty, "Stale connection must not receive sends")

        // 3. Connect to Host B
        await container.connect(to: hostB)
        XCTAssertEqual(container.activeSession?.hostID, hostB.id)

        // Emit closed / error on old mockConnectionA: must NOT affect Host B's session!
        mockConnectionA.emit(.error(TransportError.remoteFailure("stale error")))
        try await Task.sleep(nanoseconds: 20_000_000)
        XCTAssertEqual(container.activeSession?.state, .connected, "Stale connection error must not mutate active session")
        XCTAssertEqual(container.activeSession?.hostID, hostB.id)
    }

    func testRedactionBeforeFeedInProductionSurface() async throws {
        let credStore = InMemoryCredentialStore()
        let secretValue = "super-secret-ssh-token-42"
        try await credStore.save(Data(secretValue.utf8), reference: "ref-secret-token")
        let identity = try IdentityDescriptor(name: "SecretIdent", kind: .password, keychainReference: "ref-secret-token")

        let mockConnection = MockSSHConnection()
        let transport = ControllableTransport()
        transport.onConnect = { _ in mockConnection }

        let prodContainer = AppContainer(credentialStore: credStore, transport: transport)
        try await prodContainer.catalog.save(identity)
        let host = try Host(name: "ProdHost", hostname: "prod.invalid", username: "user", identityID: identity.id)

        await prodContainer.connect(to: host)
        XCTAssertEqual(prodContainer.activeSession?.state, .connected)

        let secretPayload = "Secret: \(secretValue) in session banner\r\n"
        mockConnection.emit(.bytes(Data(secretPayload.utf8)))
        try await Task.sleep(nanoseconds: 50_000_000)

        let prodTranscript = prodContainer.terminalController.currentTranscript(limit: 10)
        XCTAssertFalse(prodTranscript.contains(secretValue), "Raw secret must never enter terminalController buffer")
        XCTAssertTrue(prodTranscript.contains("[REDACTED]"), "Secret must be replaced with [REDACTED] before feed")
    }

    func testTerminalSurfaceFallbackSelection() async throws {
        // Assert that terminal rendering is unified on SwiftTerm production surface
        let defaultContainer = AppContainer()
        XCTAssertNotNil(defaultContainer.terminalController, "Default container must use production terminal controller")

        let demoContainer = AppContainer.demo()
        XCTAssertNotNil(demoContainer.terminalController, "Demo container must use production terminal controller")

        // Terminal output routes directly to production surface
        defaultContainer.terminalController.feed("Unified Surface Output\r\n")
        let transcript = defaultContainer.accessibilityTerminalText
        XCTAssertTrue(transcript.contains("Unified Surface Output"), "Terminal output must route through production terminal controller")
    }

    func testPastePolicyBracketedVersusUnbracketed() {
        let container = AppContainer()

        // 1. Unbracketed mode (default):
        XCTAssertFalse(container.terminalController.bracketedPasteMode)

        // Single line: not risky
        XCTAssertFalse(container.terminalController.isRiskyUnbracketedPaste("ls -la"))
        XCTAssertFalse(container.terminalController.isRiskyUnbracketedPaste("git status"))
        XCTAssertFalse(container.terminalController.isRiskyUnbracketedPaste(""))

        // Multi-line: risky because unbracketed shells execute newlines as Enter immediately
        XCTAssertTrue(container.terminalController.isRiskyUnbracketedPaste("command1\ncommand2"))
        XCTAssertTrue(container.terminalController.isRiskyUnbracketedPaste("command1\r\ncommand2"))
        XCTAssertTrue(container.terminalController.isRiskyUnbracketedPaste("a\nb\nc"))

        // 2. Bracketed paste mode: ESC [ ? 2004 h
        container.terminalController.feed("\u{1b}[?2004h")
        XCTAssertTrue(container.terminalController.bracketedPasteMode)

        // With bracketed paste enabled, multi-line paste is preserved and safe
        XCTAssertFalse(container.terminalController.isRiskyUnbracketedPaste("command1\ncommand2"))
    }

    func testFirstResponderRecoveryAndControllerState() {
        let container = AppContainer()

        XCTAssertFalse(container.terminalController.isFirstResponder)

        container.terminalController.requestFirstResponder()
        XCTAssertTrue(container.terminalController.hasPendingFirstResponderRequest)

        container.terminalController.recoverFirstResponder()
        XCTAssertTrue(container.terminalController.hasPendingFirstResponderRequest)

        container.terminalController.resignFirstResponder()
        XCTAssertFalse(container.terminalController.hasPendingFirstResponderRequest)
        XCTAssertFalse(container.terminalController.isFirstResponder)

        // Accessibility transcript reflects content or default placeholder
        XCTAssertEqual(container.accessibilityTerminalText, "No terminal output")
        container.terminalController.feed("Accessibility Line 1\r\n")
        XCTAssertTrue(container.accessibilityTerminalText.contains("Accessibility Line 1"))
    }

    func testRedactedPreservesDataWhenSecretsEmpty() {
        let container = AppContainer()
        XCTAssertTrue(container.redactor.secrets.isEmpty)

        // Incomplete multi-byte UTF-8 sequence (e.g. first 2 bytes of 4-byte emoji 0xF0 0x9F 0x90 0x8D)
        let splitUtf8Bytes = Data([0xF0, 0x9F])
        let result = container.redacted(splitUtf8Bytes)
        XCTAssertEqual(result, splitUtf8Bytes, "Split UTF-8 bytes must not be corrupted or replaced with U+FFFD when secrets are empty")

        // Arbitrary binary data with non-UTF-8 bytes
        let arbitraryBinary = Data([0xFF, 0xFE, 0x00, 0x01, 0x80, 0xBF])
        let binaryResult = container.redacted(arbitraryBinary)
        XCTAssertEqual(binaryResult, arbitraryBinary, "Binary data must pass through unchanged when secrets are empty")
    }

    func testMidSessionErrorAndClosedMessageFedToProductionTerminalController() async throws {
        let mockConnection = MockSSHConnection()
        let transport = ControllableTransport()
        transport.onConnect = { _ in mockConnection }

        let reachability = MockReachabilityMonitor(isReachable: false)
        let container = AppContainer(transport: transport, reachabilityMonitor: reachability)
        let host = try Host(name: "Host", hostname: "host.invalid", username: "user")

        // 1. Connect and verify connected
        await container.connect(to: host)
        XCTAssertEqual(container.activeSession?.state, .connected)

        // 2. A transport error followed by close remains failed and keeps the
        // actionable error visible, even while recovery waits for the network.
        mockConnection.emit(.error(TransportError.networkUnavailable))
        mockConnection.emit(.closed)
        try await waitUntil {
            container.activeSession?.state == .failed
        }

        XCTAssertEqual(container.activeSession?.state, .failed)
        XCTAssertTrue(container.terminalText.contains("Network unavailable."))
        let transcript = container.terminalController.currentTranscript(limit: 10)
        XCTAssertTrue(transcript.contains("[Network unavailable.]"), "Error message must be visible in production terminal surface")

        // Repeated callbacks must not downgrade the recorded failure.
        mockConnection.emit(.closed)
        mockConnection.emit(.error(TransportError.networkUnavailable))
        await Task.yield()
        await Task.yield()
        XCTAssertEqual(container.activeSession?.state, .failed)
        XCTAssertTrue(container.terminalText.contains("Network unavailable."))

        // 3. Reconnect and emit a clean close. It remains disconnected.
        let mockConnection2 = MockSSHConnection()
        transport.onConnect = { _ in mockConnection2 }
        await container.connect(to: host)
        XCTAssertEqual(container.activeSession?.state, .connected)

        mockConnection2.emit(.closed)
        mockConnection2.emit(.closed)
        try await waitUntil {
            container.activeSession?.state == .disconnected &&
                container.terminalController.currentTranscript(limit: 10).contains("[Connection closed]")
        }

        XCTAssertEqual(container.activeSession?.state, .disconnected)
        let transcript2 = container.terminalController.currentTranscript(limit: 10)
        XCTAssertTrue(transcript2.contains("[Connection closed]"), "Closure notice must be visible in production terminal surface")

        // Explicit disconnect remains authoritative over callbacks already in flight.
        let mockConnection3 = MockSSHConnection()
        transport.onConnect = { _ in mockConnection3 }
        await container.connect(to: host)
        XCTAssertEqual(container.activeSession?.state, .connected)
        mockConnection3.emit(.error(TransportError.networkUnavailable))
        await container.disconnect()
        mockConnection3.emit(.closed)
        mockConnection3.emit(.error(TransportError.remoteFailure("late callback")))
        XCTAssertEqual(container.activeSession?.state, .disconnected)
    }

    func testSerializedOutboundInteractiveKeystrokeOrdering() async throws {
        let mockConnection = MockSSHConnection()
        let transport = ControllableTransport()
        transport.onConnect = { _ in mockConnection }

        let container = AppContainer(transport: transport)
        let host = try Host(name: "Host", hostname: "host.invalid", username: "user")

        await container.connect(to: host)
        XCTAssertEqual(container.activeSession?.state, .connected)

        // Simulate rapid keystrokes arriving via terminalController.onOutput
        let inputChars = ["a", "b", "c", "d", "e", "\r"]
        for char in inputChars {
            container.terminalController.onOutput?(Data(char.utf8))
        }

        // Allow async serialized task queue to drain
        try await Task.sleep(nanoseconds: 80_000_000)

        let sentStrings = mockConnection.sentData.map { String(decoding: $0, as: UTF8.self) }
        XCTAssertEqual(sentStrings, inputChars, "Rapid interactive keystrokes must be delivered in strict FIFO order")
    }

    func testSessionViewComponentsAndAffordances() {
        let container = AppContainer.demo()

        // SwiftUI hierarchy instantiation sanity
        let sessionView = SessionView().environmentObject(container)
        _ = sessionView

        let compactSessionView = SessionView()
            .environmentObject(container)
            .environment(\.horizontalSizeClass, .compact)
        _ = compactSessionView

        let regularSessionView = SessionView()
            .environmentObject(container)
            .environment(\.horizontalSizeClass, .regular)
        _ = regularSessionView

        let accessoryBar = TerminalAccessoryBar(controller: container.terminalController)
        _ = accessoryBar

        var query = "test"
        let searchBar = TerminalSearchBar(controller: container.terminalController, query: .init(get: { query }, set: { query = $0 }), onClose: {})
        _ = searchBar
    }

    @MainActor
    func testTerminalAccessoryBarModifierReactivityAndRendering() async throws {
        let container = AppContainer.demo()
        let controller = container.terminalController
        var outboundData: [Data] = []
        controller.onOutput = { outboundData.append($0) }

        let barView = TerminalAccessoryBar(controller: controller)
        let hosting = UIHostingController(rootView: barView)
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 393, height: 60))
        window.rootViewController = hosting
        window.makeKeyAndVisible()
        hosting.view.layoutIfNeeded()

        let evidenceDir = ProcessInfo.processInfo.environment["EVIDENCE_DIR"]

        func captureScreenshot(name: String) {
            guard let evidenceDir, !evidenceDir.isEmpty, FileManager.default.fileExists(atPath: evidenceDir) else { return }
            let renderer = UIGraphicsImageRenderer(bounds: hosting.view.bounds)
            let image = renderer.image { _ in
                hosting.view.drawHierarchy(in: hosting.view.bounds, afterScreenUpdates: true)
            }
            if let data = image.pngData() {
                let url = URL(fileURLWithPath: evidenceDir).appendingPathComponent("\(name).png")
                try? data.write(to: url)
            }
        }

        // 1. Initial default state: no modifiers active
        XCTAssertFalse(controller.inputCoordinator.isControlActive)
        XCTAssertFalse(controller.inputCoordinator.isAltActive)
        XCTAssertFalse(controller.inputCoordinator.isShiftActive)
        captureScreenshot(name: "accessory_bar_default")

        // 2. Toggle Ctrl: coordinator becomes active, view hierarchy re-evaluates
        controller.inputCoordinator.toggleControl()
        XCTAssertTrue(controller.inputCoordinator.isControlActive)
        hosting.view.layoutIfNeeded()
        captureScreenshot(name: "accessory_bar_ctrl_active")

        // 3. Emit Space from keyboard: produces NUL byte (0x00) and clears Ctrl
        controller.handleOutput(Data(" ".utf8))
        XCTAssertEqual(outboundData, [Data([0x00])])
        XCTAssertFalse(controller.inputCoordinator.isControlActive)

        // 4. Toggle Shift: coordinator becomes active, Tab updates
        controller.inputCoordinator.toggleShift()
        XCTAssertTrue(controller.inputCoordinator.isShiftActive)
        hosting.view.layoutIfNeeded()
        captureScreenshot(name: "accessory_bar_shift_active")

        // 5. Toggle Alt: coordinator becomes active
        controller.inputCoordinator.toggleAlt()
        XCTAssertTrue(controller.inputCoordinator.isAltActive)
        hosting.view.layoutIfNeeded()
        captureScreenshot(name: "accessory_bar_alt_active")

        // 6. Reset / Clear clears all
        controller.inputCoordinator.clear()
        XCTAssertFalse(controller.inputCoordinator.isControlActive)
        XCTAssertFalse(controller.inputCoordinator.isAltActive)
        XCTAssertFalse(controller.inputCoordinator.isShiftActive)
    }

    func testCreateEd25519IdentityAndRetrievePublicKey() async throws {
        let container = AppContainer.demo()
        let initialCount = (try await container.catalog.identities()).count

        let identity = try await container.createEd25519Identity(name: "Test iPad Key", comment: "user@ipad")
        XCTAssertEqual(identity.name, "Test iPad Key")
        XCTAssertEqual(identity.kind, IdentityKind.privateKey)
        XCTAssertNotNil(identity.publicFingerprint)
        XCTAssertTrue(identity.publicFingerprint?.hasPrefix("SHA256:") == true)

        let allIdentities = try await container.catalog.identities()
        XCTAssertEqual(allIdentities.count, initialCount + 1)
        XCTAssertTrue(allIdentities.contains(where: { $0.id == identity.id }))

        // Verify stored in keychain
        let loadedSecret = try await container.keychain.load(reference: identity.keychainReference)
        XCTAssertFalse(loadedSecret.isEmpty)

        // Retrieve public key (defaults comment to identity.name)
        let pubKey = try await container.openSSHPublicKey(for: identity)
        XCTAssertNotNil(pubKey)
        XCTAssertTrue(pubKey?.hasPrefix("ssh-ed25519 AAAAC3NzaC1lZDI1NTE5") == true)
        XCTAssertTrue(pubKey?.hasSuffix("Test iPad Key") == true)

        // Retrieve with custom comment
        let pubKeyWithComment = try await container.openSSHPublicKey(for: identity, comment: "user@ipad")
        XCTAssertTrue(pubKeyWithComment?.hasSuffix("user@ipad") == true)
    }

    func testImportPrivateKeyIdentity() async throws {
        let container = AppContainer.demo()
        let originalKey = Curve25519.Signing.PrivateKey()
        let openSSHRepresentation = originalKey.makeSSHRepresentation(comment: "imported-key")

        let imported = try await container.importPrivateKeyIdentity(name: "Imported Ed25519", privateKeyText: openSSHRepresentation)
        XCTAssertEqual(imported.name, "Imported Ed25519")
        XCTAssertEqual(imported.kind, IdentityKind.privateKey)

        let expectedFingerprint = Ed25519Parser.fingerprint(from: originalKey.publicKey)
        XCTAssertEqual(imported.publicFingerprint, expectedFingerprint)

        let pubKey = try await container.openSSHPublicKey(for: imported)
        XCTAssertNotNil(pubKey)
        XCTAssertTrue(pubKey?.hasPrefix("ssh-ed25519 AAAAC3NzaC1lZDI1NTE5") == true)
    }

    func testCreatePasswordIdentity() async throws {
        let container = AppContainer.demo()
        let initialCount = (try await container.catalog.identities()).count

        let identity = try await container.createPasswordIdentity(name: "Root Password", password: "secret-password-123")
        XCTAssertEqual(identity.name, "Root Password")
        XCTAssertEqual(identity.kind, IdentityKind.password)
        XCTAssertNil(identity.publicFingerprint)

        let all = try await container.catalog.identities()
        XCTAssertEqual(all.count, initialCount + 1)

        let secretData = try await container.keychain.load(reference: identity.keychainReference)
        XCTAssertEqual(String(data: secretData, encoding: .utf8), "secret-password-123")

        let pubKey = try await container.openSSHPublicKey(for: identity)
        XCTAssertNil(pubKey, "Password identity has no SSH public key")
    }

    func testDeleteIdentityCleansKeychainAndHostReferences() async throws {
        let container = AppContainer.demo()
        let identity = try await container.createEd25519Identity(name: "Disposable Key", comment: "disposable")

        // Create a host referencing this identity
        let host = try Host(name: "Host with Key", hostname: "server.local", username: "admin", identityID: identity.id)
        try await container.saveHost(host)

        let savedHost = try await container.catalog.listHosts().first(where: { $0.id == host.id })
        XCTAssertEqual(savedHost?.identityID, identity.id)

        // Delete the identity
        try await container.deleteIdentity(id: identity.id)

        // Identity must be gone from catalog
        let remainingIdentities = try await container.catalog.identities()
        XCTAssertFalse(remainingIdentities.contains(where: { $0.id == identity.id }))

        // Keychain reference must be deleted
        do {
            _ = try await container.keychain.load(reference: identity.keychainReference)
            XCTFail("Keychain secret should have been deleted")
        } catch {
            // Expected
        }

        // Host's identityID must be cleared to nil
        let updatedHost = try await container.catalog.listHosts().first(where: { $0.id == host.id })
        XCTAssertNil(updatedHost?.identityID)
    }

    func testDeleteIdentityWithSharedKeychainReferencePreservesSecretForSurvivingIdentity() async throws {
        let container = AppContainer.demo()
        let ref = "shared-kc-ref"
        let secret = Data("shared-private-key".utf8)
        try await container.keychain.save(secret, reference: ref)

        let first = try IdentityDescriptor(name: "Key 1", kind: .privateKey, keychainReference: ref)
        let second = try IdentityDescriptor(name: "Key 2", kind: .privateKey, keychainReference: ref)
        try await container.catalog.save(first)
        try await container.catalog.save(second)

        try await container.deleteIdentity(id: first.id)

        let remaining = try await container.catalog.identities()
        XCTAssertFalse(remaining.contains(where: { $0.id == first.id }))
        XCTAssertTrue(remaining.contains(where: { $0.id == second.id }))

        let loaded = try await container.keychain.load(reference: ref)
        XCTAssertEqual(loaded, secret)

        try await container.deleteIdentity(id: second.id)
        do {
            _ = try await container.keychain.load(reference: ref)
            XCTFail("Keychain secret should have been deleted after last reference is removed")
        } catch {
            // Expected
        }
    }

    func testDeleteIdentitySucceedsWhenKeychainItemAlreadyMissing() async throws {
        let container = AppContainer.demo()
        let missingRef = "missing-kc-ref"
        let identity = try IdentityDescriptor(name: "Orphan Key", kind: .privateKey, keychainReference: missingRef)
        try await container.catalog.save(identity)

        let host = try Host(name: "Orphan Host", hostname: "server.local", username: "admin", identityID: identity.id)
        try await container.saveHost(host)

        try await container.deleteIdentity(id: identity.id)

        let remaining = try await container.catalog.identities()
        XCTAssertFalse(remaining.contains(where: { $0.id == identity.id }))

        let updatedHost = try await container.catalog.listHosts().first(where: { $0.id == host.id })
        XCTAssertNil(updatedHost?.identityID)
    }

    func testRedactionIncludesSecretEvenForCollidingIdentities() async throws {
        let container = AppContainer.demo()
        let ref = "colliding-ref"
        let secretText = "super-secret-key-material"
        try await container.keychain.save(Data(secretText.utf8), reference: ref)

        let first = try IdentityDescriptor(name: "Key A", kind: .privateKey, keychainReference: ref)
        let second = try IdentityDescriptor(name: "Key B", kind: .privateKey, keychainReference: ref)
        try await container.catalog.save(first)
        try await container.catalog.save(second)

        let host = try Host(name: "Target", hostname: "server.local", username: "admin", identityID: first.id)
        try await container.saveHost(host)

        await container.loadRedactionSecret(for: host)

        let sampleOutput = Data("output containing super-secret-key-material here".utf8)
        let redactedData = container.redacted(sampleOutput)
        let redactedString = String(decoding: redactedData, as: UTF8.self)
        XCTAssertFalse(redactedString.contains(secretText))
        XCTAssertTrue(redactedString.contains("[REDACTED]"))
    }

    func testBonjourDiscoveryForwarding() async {
        let container = AppContainer.demo()
        XCTAssertNotNil(container.bonjourDiscovery)
        XCTAssertTrue(container.discoveredSSHServices.isEmpty)

        let service = DiscoveredSSHService(name: "test-rpi", hostname: "test-rpi.local", port: 22)
        container.bonjourDiscovery.updateDiscoveredServices([service])

        XCTAssertEqual(container.discoveredSSHServices.count, 1)
        XCTAssertEqual(container.discoveredSSHServices.first?.name, "test-rpi")
        XCTAssertEqual(container.discoveredSSHServices.first?.hostname, "test-rpi.local")
        XCTAssertEqual(container.discoveredSSHServices.first?.port, 22)
    }

    func testKeepScreenAwakePersistenceAndDefaults() {
        let key = AppContainer.keepScreenAwakePreferenceKey
        let originalValue = UserDefaults.standard.object(forKey: key)
        defer {
            if let originalValue {
                UserDefaults.standard.set(originalValue, forKey: key)
            } else {
                UserDefaults.standard.removeObject(forKey: key)
            }
        }

        // Test default value is true when no key is in UserDefaults
        UserDefaults.standard.removeObject(forKey: key)
        let container1 = AppContainer.demo()
        XCTAssertTrue(container1.keepScreenAwake, "keepScreenAwake must default to true")

        // Test setting to false persists to UserDefaults
        container1.setKeepScreenAwake(false)
        XCTAssertFalse(container1.keepScreenAwake)
        XCTAssertEqual(UserDefaults.standard.bool(forKey: key), false)

        // Test initializing new container reads persisted false
        let container2 = AppContainer.demo()
        XCTAssertFalse(container2.keepScreenAwake)

        // Test setting back to true persists
        container2.setKeepScreenAwake(true)
        XCTAssertTrue(container2.keepScreenAwake)
        XCTAssertEqual(UserDefaults.standard.bool(forKey: key), true)
    }

    func testKeepScreenAwakeIdleTimerStateEvaluation() async throws {
        let key = AppContainer.keepScreenAwakePreferenceKey
        let originalValue = UserDefaults.standard.object(forKey: key)
        defer {
            if let originalValue {
                UserDefaults.standard.set(originalValue, forKey: key)
            } else {
                UserDefaults.standard.removeObject(forKey: key)
            }
            #if canImport(UIKit)
            UIApplication.shared.isIdleTimerDisabled = false
            #endif
        }

        let container = AppContainer.demo()
        let host = try Host(name: "Demo Host", hostname: "demo.invalid", username: "dev")
        let challenge = HostKeyChallenge(hostname: "demo.invalid", port: 22, algorithm: "ssh-ed25519", fingerprint: "SHA256:demo-fingerprint")
        await container.trustStore.save(challenge)

        #if canImport(UIKit)
        // 1. Initially disconnected: idle timer is not disabled
        XCTAssertFalse(UIApplication.shared.isIdleTimerDisabled)

        // 2. Connect with keepScreenAwake == true: idle timer disabled
        container.setKeepScreenAwake(true)
        await container.connect(to: host)
        XCTAssertEqual(container.activeSession?.state, .connected)
        XCTAssertTrue(UIApplication.shared.isIdleTimerDisabled, "Idle timer must be disabled during active SSH session when keepScreenAwake is true")

        // 3. Toggle keepScreenAwake to false while connected: idle timer restored to enabled
        container.setKeepScreenAwake(false)
        XCTAssertFalse(UIApplication.shared.isIdleTimerDisabled, "Idle timer must not be disabled when keepScreenAwake is false")

        // 4. Toggle keepScreenAwake back to true while connected: idle timer disabled again
        container.setKeepScreenAwake(true)
        XCTAssertTrue(UIApplication.shared.isIdleTimerDisabled, "Idle timer must be disabled when keepScreenAwake is turned back on")

        // 5. Disconnect: idle timer restored to enabled (isIdleTimerDisabled == false)
        await container.disconnect()
        XCTAssertEqual(container.activeSession?.state, .disconnected)
        XCTAssertFalse(UIApplication.shared.isIdleTimerDisabled, "Idle timer must not be disabled after disconnect")

        // 6. Connect again, then cancel reconnect: idle timer must not be disabled
        await container.connect(to: host)
        XCTAssertEqual(container.activeSession?.state, .connected)
        XCTAssertTrue(UIApplication.shared.isIdleTimerDisabled)
        await container.cancelReconnect()
        XCTAssertFalse(UIApplication.shared.isIdleTimerDisabled, "Idle timer must not be disabled after cancelReconnect")
        #else
        container.setKeepScreenAwake(true)
        XCTAssertTrue(container.keepScreenAwake)
        #endif
    }

    func testRapidDisconnectAndReconnectLifecycleSynchronization() async throws {
        let container = AppContainer.demo()
        let host = try Host(name: "Demo Host", hostname: "demo.invalid", username: "dev")
        let challenge = HostKeyChallenge(hostname: "demo.invalid", port: 22, algorithm: "ssh-ed25519", fingerprint: "SHA256:demo-fingerprint")
        await container.trustStore.save(challenge)

        for _ in 0..<10 {
            await container.connect(to: host)
            XCTAssertEqual(container.activeSession?.state, .connected)
            await container.disconnect()
            XCTAssertEqual(container.activeSession?.state, .disconnected)
        }

        await container.connect(to: host)
        XCTAssertEqual(container.activeSession?.state, .connected)
        await container.cancelReconnect()
        XCTAssertEqual(container.activeSession?.state, .disconnected)
    }

    // MARK: - Secondary Split Pane Tests

    func testSecondaryPaneModeInitialState() {
        let container = AppContainer.demo()
        XCTAssertEqual(container.secondaryPaneMode, .none)
        XCTAssertNotNil(container.secondaryTerminalController)
    }

    func testSecondaryPaneTransitionsAndActions() async throws {
        let container = AppContainer.demo()
        let host1 = try Host(name: "Primary Server", hostname: "server1.example.com", username: "admin")
        let host2 = try Host(name: "Database Server", hostname: "server2.example.com", username: "dbuser")

        // 1. Initial state is none
        XCTAssertEqual(container.secondaryPaneMode, .none)

        // 2. Open secondary SFTP for host1
        container.openSecondarySFTP(for: host1)
        XCTAssertEqual(container.secondaryPaneMode, .sftp(host1))

        if case .sftp(let sftpHost) = container.secondaryPaneMode {
            XCTAssertEqual(sftpHost.id, host1.id)
            XCTAssertEqual(sftpHost.name, "Primary Server")
        } else {
            XCTFail("Expected secondaryPaneMode to be .sftp")
        }

        // 3. Transition from SFTP to secondary terminal for host2
        container.openSecondaryTerminal(for: host2)
        XCTAssertEqual(container.secondaryPaneMode, .terminal(host2))

        if case .terminal(let termHost) = container.secondaryPaneMode {
            XCTAssertEqual(termHost.id, host2.id)
            XCTAssertEqual(termHost.name, "Database Server")
        } else {
            XCTFail("Expected secondaryPaneMode to be .terminal")
        }

        // 4. Close secondary pane
        container.closeSecondaryPane()
        XCTAssertEqual(container.secondaryPaneMode, .none)

        // 5. Open secondary SFTP again and verify close
        container.openSecondarySFTP(for: host2)
        XCTAssertEqual(container.secondaryPaneMode, .sftp(host2))
        container.closeSecondaryPane()
        XCTAssertEqual(container.secondaryPaneMode, .none)
    }

    func testSecondaryTerminalControllerThemeSync() {
        let container = AppContainer.demo()
        container.setTerminalTheme(.dracula)
        XCTAssertEqual(container.terminalTheme, .dracula)
        XCTAssertEqual(container.terminalController.terminalTheme, .dracula)
        XCTAssertEqual(container.secondaryTerminalController.terminalTheme, .dracula)

        container.setTerminalTheme(.catppuccinMocha)
        XCTAssertEqual(container.secondaryTerminalController.terminalTheme, .catppuccinMocha)
    }

    private func waitUntil(
        timeout: TimeInterval = 5,
        condition: () -> Bool
    ) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition() {
            guard Date() < deadline else { return }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
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

final class MockSSHConnection: SSHConnection, SSHCommandExecuting, @unchecked Sendable {
    private let lock = NSLock()
    private(set) var isClosed = false
    var isResponsive: Bool = true
    var onTestResponsiveness: (@Sendable (TimeInterval) async -> Bool)?
    private(set) var sentData: [Data] = []
    private(set) var resizeCalls: [TerminalSize] = []
    private var streamContinuation: AsyncThrowingStream<TerminalEvent, Error>.Continuation?
    var onExecuteCommand: (@Sendable (String) async throws -> SSHCommandResult)?
    var onSend: (@Sendable (Data) async throws -> Void)?

    func testResponsiveness(timeout: TimeInterval = 3.0) async -> Bool {
        if let onTestResponsiveness {
            return await onTestResponsiveness(timeout)
        }
        return !lock.withLock { isClosed } && isResponsive
    }

    func events() async -> AsyncThrowingStream<TerminalEvent, Error> {
        AsyncThrowingStream { continuation in
            self.lock.withLock {
                self.streamContinuation = continuation
            }
        }
    }

    func send(_ data: Data) async throws {
        if let onSend {
            try await onSend(data)
            return
        }
        lock.withLock {
            sentData.append(data)
        }
    }

    func resize(_ size: TerminalSize) async throws {
        lock.withLock {
            resizeCalls.append(size)
        }
    }

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

    func executeCommand(_ command: String) async throws -> SSHCommandResult {
        try await executeCommand(command, timeout: nil, maxOutputBytes: nil)
    }

    func executeCommand(_ command: String, timeout: TimeInterval?, maxOutputBytes: Int?) async throws -> SSHCommandResult {
        if let onExecuteCommand {
            return try await onExecuteCommand(command)
        }
        let trimmed = command.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed == TmuxCommand.probe || trimmed == "tmux -V" {
            return SSHCommandResult(exitCode: 0, stdout: "tmux 3.4\n", stderr: "")
        }
        if trimmed == TmuxCommand.listSessions || trimmed.contains("list-sessions") {
            return SSHCommandResult(exitCode: 0, stdout: "$0\tdefault\t1\t1700000000\t1700000000\t1\n", stderr: "")
        }
        if trimmed.contains("has-session") {
            return SSHCommandResult(exitCode: 0, stdout: "", stderr: "")
        }
        return SSHCommandResult(exitCode: 0, stdout: "", stderr: "")
    }
}

final class ControllableTransport: SSHTransport, @unchecked Sendable {
    var onConnect: (@Sendable (Host) async throws -> any SSHConnection)?

    func connect(host: Host, identity: IdentityDescriptor?, trustEvaluator: any HostTrustEvaluator, initialSize: TerminalSize) async throws -> any SSHConnection {
        if let onConnect {
            return try await onConnect(host)
        }
        return MockSSHConnection()
    }
}

#if canImport(UIKit)
final class MockBackgroundTaskManager: BackgroundTaskManaging, @unchecked Sendable {
    private let lock = NSLock()
    private(set) var beginTaskCallCount = 0
    private(set) var endTaskCallCount = 0
    private(set) var registeredNames: [String?] = []
    private(set) var activeIdentifiers: Set<UIBackgroundTaskIdentifier> = []
    private var expirationHandlers: [UIBackgroundTaskIdentifier: @Sendable () -> Void] = [:]
    private var nextID = 100

    init() {}

    func beginBackgroundTask(withName name: String? = nil, expirationHandler: (@Sendable () -> Void)? = nil) -> UIBackgroundTaskIdentifier {
        lock.withLock {
            beginTaskCallCount += 1
            registeredNames.append(name)
            let id = UIBackgroundTaskIdentifier(rawValue: nextID)
            nextID += 1
            activeIdentifiers.insert(id)
            if let expirationHandler {
                expirationHandlers[id] = expirationHandler
            }
            return id
        }
    }

    func endBackgroundTask(_ identifier: UIBackgroundTaskIdentifier) {
        lock.withLock {
            guard identifier != .invalid else { return }
            endTaskCallCount += 1
            activeIdentifiers.remove(identifier)
            expirationHandlers.removeValue(forKey: identifier)
        }
    }

    func triggerExpiration(for identifier: UIBackgroundTaskIdentifier) {
        let handler = lock.withLock { expirationHandlers[identifier] }
        handler?()
    }

    func triggerAllExpirations() {
        let handlers = lock.withLock { Array(expirationHandlers.values) }
        for handler in handlers {
            handler()
        }
    }
}
#endif
