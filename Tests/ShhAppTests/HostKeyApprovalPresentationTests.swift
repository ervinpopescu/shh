import SwiftUI
import XCTest
@testable import Shh
import ShhCore

@MainActor
final class HostKeyApprovalPresentationTests: XCTestCase {
    func testPresentationBindingReflectsPendingChallengePresence() {
        let container = AppContainer.demo()
        let binding = HostKeyApprovalAlertModifier.presentationBinding(for: container)

        XCTAssertNil(container.pendingTrustChallenge)
        XCTAssertFalse(binding.wrappedValue, "Presentation binding must be false when no challenge is pending")

        let challenge = HostKeyChallenge(
            hostname: "bastion.internal",
            port: 2222,
            algorithm: "ssh-ed25519",
            fingerprint: "SHA256:4yV3R4nd0mF1ng3rpr1ntF0rT3st1ng0nly"
        )
        container.pendingTrustChallenge = challenge

        XCTAssertTrue(binding.wrappedValue, "Presentation binding must be true when a challenge is pending")
    }

    func testPresentationBindingSetterDoesNotRejectOrMutatePendingChallenge() async throws {
        let container = AppContainer.demo()
        let host = try Host(name: "Pending Target", hostname: "pending.invalid", username: "dev")

        await container.connect(to: host)
        XCTAssertNotNil(container.pendingTrustChallenge)
        let challenge = container.pendingTrustChallenge
        let previousState = container.activeSession?.state

        let binding = HostKeyApprovalAlertModifier.presentationBinding(for: container)
        XCTAssertTrue(binding.wrappedValue)

        // Simulate SwiftUI attempting to set presentation false due to view transition or backdrop tap
        binding.wrappedValue = false

        // Crucial requirement: setting presentation false MUST NOT reject or clear the challenge!
        XCTAssertNotNil(container.pendingTrustChallenge, "Challenge must remain intact when SwiftUI resets isPresented")
        XCTAssertEqual(container.pendingTrustChallenge, challenge)
        XCTAssertEqual(
            container.activeSession?.state,
            previousState,
            "Setting presentation false must not prematurely disconnect or alter session state"
        )
        XCTAssertTrue(binding.wrappedValue, "Getter must continue returning true while challenge is pending")
    }

    func testExplicitRejectClearsChallengeAndDisconnects() async throws {
        let container = AppContainer.demo()
        let host = try Host(name: "Reject Target", hostname: "reject.invalid", username: "dev")

        await container.connect(to: host)
        XCTAssertNotNil(container.pendingTrustChallenge, "Unknown host key must produce approval challenge")
        XCTAssertEqual(container.activeSession?.state, .disconnected)

        // Explicit user tap on Reject
        container.rejectPendingHostKey()

        XCTAssertNil(container.pendingTrustChallenge, "Explicit reject must clear pending challenge")
        XCTAssertEqual(container.activeSession?.state, .disconnected, "Explicit reject sets session disconnected")

        let binding = HostKeyApprovalAlertModifier.presentationBinding(for: container)
        XCTAssertFalse(binding.wrappedValue)
    }

    func testExplicitTrustOnceApprovesChallengeAndConnects() async throws {
        let container = AppContainer.demo()
        let host = try Host(name: "Trust Once Target", hostname: "once.invalid", username: "dev")

        await container.connect(to: host)
        XCTAssertNotNil(container.pendingTrustChallenge)

        // Explicit user tap on Trust Once
        await container.approvePendingHostKey(permanently: false)

        XCTAssertNil(container.pendingTrustChallenge, "Trust once must clear pending challenge")
        XCTAssertEqual(container.activeSession?.state, .connected, "Session should connect after temporary approval")

        // Permanent trust store should NOT have it
        let records = await container.trustStore.allRecords()
        XCTAssertFalse(records.contains { $0.hostname == "once.invalid" }, "Trust once must not persist permanently")
    }

    func testExplicitAlwaysTrustApprovesChallengeAndPersistsInTrustStore() async throws {
        let container = AppContainer.demo()
        let host = try Host(name: "Always Trust Target", hostname: "always.invalid", username: "dev")

        await container.connect(to: host)
        XCTAssertNotNil(container.pendingTrustChallenge)

        // Explicit user tap on Always Trust
        await container.approvePendingHostKey(permanently: true)

        XCTAssertNil(container.pendingTrustChallenge, "Always trust must clear pending challenge")
        XCTAssertEqual(container.activeSession?.state, .connected, "Session should connect after permanent approval")

        // Permanent trust store MUST have it
        let records = await container.trustStore.allRecords()
        XCTAssertTrue(records.contains { $0.hostname == "always.invalid" }, "Permanent trust must be saved in trust store")
    }

    func testChangedHostKeyRemainsBlockedWithoutPresentingApproval() async throws {
        let trustStore = InMemoryTrustStore()
        let oldChallenge = HostKeyChallenge(
            hostname: "changed.security.test",
            port: 22,
            algorithm: "ssh-ed25519",
            fingerprint: "SHA256:knownOriginalFingerprint"
        )
        await trustStore.save(oldChallenge)

        let container = AppContainer.demo(trustStore: trustStore)
        let host = try Host(name: "Changed Host", hostname: "changed.security.test", username: "dev")

        await container.connect(to: host)

        // Strict TOFU: changed keys must fail immediately without offering approval
        XCTAssertEqual(container.activeSession?.state, .failed, "Changed host key must fail immediately")
        XCTAssertNil(container.pendingTrustChallenge, "Changed host key must never produce an approval challenge")
        let binding = HostKeyApprovalAlertModifier.presentationBinding(for: container)
        XCTAssertFalse(binding.wrappedValue, "Alert must not be presented for changed host key")
    }

    func testChallengeMessageFormattingPreservesAlgorithmAndFingerprintSafely() {
        let challenge = HostKeyChallenge(
            hostname: "server.corp.example.com",
            port: 2222,
            algorithm: "ssh-ed25519",
            fingerprint: "SHA256:uW38fjK91+vN291/0abcdef1234567890ABCDEF="
        )

        let message = HostKeyApprovalAlertModifier.challengeMessage(for: challenge)

        XCTAssertTrue(message.contains("server.corp.example.com:2222"), "Message must contain full hostname and port")
        XCTAssertTrue(message.contains("Algorithm: ssh-ed25519"), "Message must preserve complete algorithm name")
        XCTAssertTrue(
            message.contains("Fingerprint: SHA256:uW38fjK91+vN291/0abcdef1234567890ABCDEF="),
            "Message must preserve complete fingerprint without truncation"
        )
        XCTAssertFalse(message.contains("password"), "Message must never contain secret terms")
    }

    func testSinglePresentationOwnerInHierarchy() throws {
        let container = AppContainer.demo()

        // RootView must host the approval alert
        let rootView = RootView().environmentObject(container)
        let rootHosting = UIHostingController(rootView: rootView)
        rootHosting.loadViewIfNeeded()
        XCTAssertNotNil(rootHosting.view)

        // HostDetailView must NOT have competing approval alert
        let sampleHost = try Host(name: "Detail Host", hostname: "detail.example.com", username: "dev")
        let detailView = HostDetailView(host: sampleHost).environmentObject(container)
        let detailHosting = UIHostingController(rootView: detailView)
        detailHosting.loadViewIfNeeded()
        XCTAssertNotNil(detailHosting.view)

        // Verify that setting a challenge with both views loaded behaves deterministically
        let challenge = HostKeyChallenge(
            hostname: "detail.example.com",
            port: 22,
            algorithm: "ssh-ed25519",
            fingerprint: "SHA256:uniqueHostFingerprint12345"
        )
        container.pendingTrustChallenge = challenge

        let binding = HostKeyApprovalAlertModifier.presentationBinding(for: container)
        XCTAssertTrue(binding.wrappedValue)

        // Simulating SwiftUI alert dismissal notification on any subview does not clear challenge
        binding.wrappedValue = false
        XCTAssertEqual(container.pendingTrustChallenge, challenge, "Challenge must not be dismissed by subview events")
    }
}
