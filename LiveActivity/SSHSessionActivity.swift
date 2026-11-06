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

    /// A stale ActivityKit snapshot no longer proves that the SSH transport is connected.
    public func displayName(isStale: Bool) -> String {
      isStale ? "Status unverified" : status.displayName
    }

    public var lastConfirmedLabel: String {
      "Last confirmed"
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
  public let isStale: Bool

  public init(
    displayName: String,
    hostLabel: String,
    state: ShhSSHSessionActivityAttributes.ContentState,
    isStale: Bool = false
  ) {
    self.displayName = displayName
    self.hostLabel = hostLabel
    self.state = state
    self.isStale = isStale
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
        Text(state.displayName(isStale: isStale))
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
    .accessibilityLabel("SSH session at \(displayName), \(state.displayName(isStale: isStale))")
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
        timestampView
        Spacer(minLength: 0)
      }
    } else {
      HStack(spacing: 8) {
        timestampView
        Spacer(minLength: 0)
      }
    }
  }

  private var timestampView: some View {
    HStack(spacing: 4) {
      if isStale {
        Text(state.lastConfirmedLabel)
      }
      Text(state.updatedAt, style: .relative)
        .accessibilityLabel("\(isStale ? state.lastConfirmedLabel : "Updated") \(state.updatedAt.formatted())")
    }
    .font(.caption2)
    .foregroundStyle(.white.opacity(0.7))
  }

  private func statusColor(_ status: ShhSSHSessionActivityAttributes.ContentState.Status) -> Color {
    if isStale { return .yellow }
    switch status {
    case .connected: return .green
    case .reconnecting: return .orange
    case .disconnected: return .secondary
    case .failed: return .red
    }
  }
}
