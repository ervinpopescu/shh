import ShhCore
import SwiftUI

/// Centralized, durable presentation modifier for SSH host-key approval alerts.
///
/// Ensures exactly one alert owner across the app hierarchy (attached to `RootView`),
/// preventing duplicate alert races where competing views (like `HostDetailView`)
/// cause SwiftUI to auto-dismiss and prematurely reject pending trust challenges.
///
/// The alert's presentation binding ignores programmatic dismissal attempts from SwiftUI
/// (e.g. iPad split-view column transitions or backdrop taps) so the challenge remains visible
/// until the user explicitly taps "Trust Once", "Always Trust", or "Reject".
struct HostKeyApprovalAlertModifier: ViewModifier {
    @ObservedObject var container: AppContainer

    /// Creates a durable presentation binding that is true when a pending challenge exists.
    /// Setting this binding to `false` is intentionally a no-op to ensure that host-key
    /// decisions are made exclusively via explicit user action (Trust Once, Always Trust, Reject).
    static func presentationBinding(for container: AppContainer) -> Binding<Bool> {
        Binding(
            get: { container.pendingTrustChallenge != nil },
            set: { isPresented in
                // Setting to false must NOT reject or clear pending trust.
                // Accidental outside-tap, split view column changes, or competing dismissals
                // must leave the pending challenge intact until the user acts explicitly.
                _ = isPresented
            }
        )
    }

    /// Formats the approval message preserving complete algorithm and fingerprint details
    /// without truncating or leaking credentials.
    static func challengeMessage(for challenge: HostKeyChallenge) -> String {
        "The host key for \(challenge.hostname):\(challenge.port) is not yet verified.\n\nAlgorithm: \(challenge.algorithm)\nFingerprint: \(challenge.fingerprint)"
    }

    func body(content: Content) -> some View {
        content.alert(
            "Approve Host Key?",
            isPresented: Self.presentationBinding(for: container),
            presenting: container.pendingTrustChallenge
        ) { _ in
            Button("Trust Once") {
                Task { await container.approvePendingHostKey(permanently: false) }
            }
            Button("Always Trust") {
                Task { await container.approvePendingHostKey(permanently: true) }
            }
            Button("Reject", role: .cancel) {
                container.rejectPendingHostKey()
            }
        } message: { challenge in
            Text(Self.challengeMessage(for: challenge))
        }
    }
}

extension View {
    /// Attaches the centralized host-key approval alert to this view hierarchy.
    /// Exactly one root view in the app must host this modifier.
    func hostKeyApprovalAlert(container: AppContainer) -> some View {
        modifier(HostKeyApprovalAlertModifier(container: container))
    }
}
