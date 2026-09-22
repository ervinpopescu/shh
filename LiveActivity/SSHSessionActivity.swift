import ActivityKit
import Foundation
import SwiftUI

/// Shared, privacy-safe attributes used by the application and the WidgetKit extension.
///
/// Invariant: This structure and its `ContentState` intentionally store only high-level
/// connection lifecycle metadata. Terminal streams, commands, keystrokes, passwords, and
/// private keys must never be added to these attributes or transmitted to ActivityKit.
public struct ShhSSHSessionActivityAttributes: ActivityAttributes {
  public struct ContentState: Codable, Hashable {
    public enum Status: String, Codable, Hashable {
      case connected
      case reconnecting
      case disconnected
      case failed

      public var displayName: String {
        switch self {
        case .connected: return "Connected"
        case .reconnecting: return "Reconnecting"
        case .disconnected: return "Disconnected"
        case .failed: return "Connection failed"
        }
      }
    }

    public var status: Status
    public var updatedAt: Date
    public var reconnectAttempt: Int?

    public init(status: Status, updatedAt: Date = Date(), reconnectAttempt: Int? = nil) {
      self.status = status
      self.updatedAt = updatedAt
      self.reconnectAttempt = reconnectAttempt
    }
  }

  public let sessionID: UUID
  public let displayName: String
  public let hostLabel: String

  public init(sessionID: UUID, displayName: String, hostLabel: String) {
    self.sessionID = sessionID
    self.displayName = displayName
    self.hostLabel = hostLabel
  }
}

/// Standalone presentation view for SSH session Live Activity cards.
public struct ShhLiveActivityCardView: View {
  public let displayName: String
  public let hostLabel: String
  public let state: ShhSSHSessionActivityAttributes.ContentState

  public init(
    displayName: String,
    hostLabel: String,
    state: ShhSSHSessionActivityAttributes.ContentState
  ) {
    self.displayName = displayName
    self.hostLabel = hostLabel
    self.state = state
  }

  public var body: some View {
    VStack(alignment: .leading, spacing: 6) {
      HStack(spacing: 8) {
        Image(systemName: "terminal")
          .foregroundStyle(statusColor(state.status))
        VStack(alignment: .leading, spacing: 1) {
          Text(displayName)
            .font(.headline)
            .foregroundStyle(.white)
            .lineLimit(1)
          Text(hostLabel)
            .font(.caption)
            .foregroundStyle(.white.opacity(0.7))
            .lineLimit(1)
        }
        Spacer(minLength: 8)
        Text(state.status.displayName)
          .font(.subheadline.weight(.semibold))
          .foregroundStyle(statusColor(state.status))
      }
      statusRow
      Text(
        "Connection status only. Does not extend background socket execution and never exposes commands or credentials."
      )
      .font(.caption2)
      .foregroundStyle(.white.opacity(0.6))
      .fixedSize(horizontal: false, vertical: true)
    }
    .accessibilityElement(children: .combine)
    .accessibilityLabel("SSH session at \(displayName), \(state.status.displayName)")
    .accessibilityHint(
      "Displays connection status only. Does not extend background socket execution and never exposes commands or credentials."
    )
    .padding(14)
    .background(Color.black.opacity(0.92))
    .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
    .environment(\.colorScheme, .dark)
  }

  @ViewBuilder
  private var statusRow: some View {
    if state.status == .reconnecting, let attempt = state.reconnectAttempt {
      HStack(spacing: 8) {
        ProgressView(value: Double(attempt), total: 8)
          .tint(statusColor(state.status))
          .accessibilityLabel("Reconnect attempt \(attempt) of 8")
        Text(state.updatedAt, style: .relative)
          .font(.caption2)
          .foregroundStyle(.white.opacity(0.7))
          .accessibilityLabel("Updated \(state.updatedAt.formatted())")
        Spacer(minLength: 0)
      }
    } else {
      HStack(spacing: 8) {
        Text(state.updatedAt, style: .relative)
          .font(.caption2)
          .foregroundStyle(.white.opacity(0.7))
          .accessibilityLabel("Updated \(state.updatedAt.formatted())")
        Spacer(minLength: 0)
      }
    }
  }

  private func statusColor(_ status: ShhSSHSessionActivityAttributes.ContentState.Status) -> Color {
    switch status {
    case .connected: return .green
    case .reconnecting: return .orange
    case .disconnected: return .secondary
    case .failed: return .red
    }
  }
}
