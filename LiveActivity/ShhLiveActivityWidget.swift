import ActivityKit
import SwiftUI
import WidgetKit

struct ShhLiveActivityWidget: Widget {
  var body: some WidgetConfiguration {
    ActivityConfiguration(for: ShhSSHSessionActivityAttributes.self) { context in
      ShhLiveActivityLockScreenView(context: context)
        .activityBackgroundTint(Color.black.opacity(0.92))
        .activitySystemActionForegroundColor(.white)
    } dynamicIsland: { context in
      DynamicIsland {
        DynamicIslandExpandedRegion(.leading) {
          Image(systemName: "terminal")
            .accessibilityLabel("SSH session")
        }
        DynamicIslandExpandedRegion(.center) {
          VStack(alignment: .leading, spacing: 2) {
            Text(context.attributes.displayName)
              .font(.headline)
              .lineLimit(1)
            Text(context.state.status.displayName)
              .font(.caption)
              .foregroundStyle(statusColor(context.state.status))
          }
          .accessibilityElement(children: .combine)
          .accessibilityLabel(
            "SSH session at \(context.attributes.displayName), \(context.state.status.displayName)"
          )
          .accessibilityHint(
            "Displays connection status only. Does not extend background socket execution and never exposes commands or credentials."
          )
        }
        DynamicIslandExpandedRegion(.trailing) {
          Text(context.state.updatedAt, style: .relative)
            .font(.caption2)
            .foregroundStyle(.secondary)
            .accessibilityLabel("Updated \(context.state.updatedAt.formatted())")
        }
        DynamicIslandExpandedRegion(.bottom) {
          VStack(alignment: .leading, spacing: 4) {
            ShhLiveActivityStatusView(context: context, showsTimestamp: false)
            Text(
              "Connection status only. Does not extend background socket execution or expose commands."
            )
            .font(.caption2)
            .foregroundStyle(.secondary)
          }
          .accessibilityElement(children: .combine)
          .accessibilityHint(
            "Displays connection status only. Does not extend background socket execution and never exposes commands or credentials."
          )
        }
      } compactLeading: {
        Image(systemName: "terminal")
          .foregroundStyle(statusColor(context.state.status))
          .accessibilityLabel("SSH session")
      } compactTrailing: {
        Image(systemName: statusSymbol(context.state.status))
          .foregroundStyle(statusColor(context.state.status))
          .accessibilityLabel(context.state.status.displayName)
      } minimal: {
        Image(systemName: statusSymbol(context.state.status))
          .foregroundStyle(statusColor(context.state.status))
          .accessibilityLabel("SSH session: \(context.state.status.displayName)")
      }
    }
  }
}

private struct ShhLiveActivityLockScreenView: View {
  let context: ActivityViewContext<ShhSSHSessionActivityAttributes>

  var body: some View {
    ShhLiveActivityCardView(
      displayName: context.attributes.displayName,
      hostLabel: context.attributes.hostLabel,
      state: context.state
    )
    .padding(.vertical, 4)
  }
}

private struct ShhLiveActivityStatusView: View {
  let context: ActivityViewContext<ShhSSHSessionActivityAttributes>
  var showsTimestamp: Bool = true

  var body: some View {
    if showsTimestamp
      || (context.state.status == .reconnecting && context.state.reconnectAttempt != nil)
    {
      HStack(spacing: 8) {
        if context.state.status == .reconnecting,
          let attempt = context.state.reconnectAttempt
        {
          ProgressView(value: Double(attempt), total: 8)
            .tint(statusColor(context.state.status))
            .accessibilityLabel("Reconnect attempt \(attempt) of 8")
        }
        if showsTimestamp {
          Text(context.state.updatedAt, style: .relative)
            .font(.caption2)
            .foregroundStyle(.secondary)
            .accessibilityLabel("Updated \(context.state.updatedAt.formatted())")
        }
        Spacer(minLength: 0)
      }
    }
  }
}

private func statusSymbol(_ status: ShhSSHSessionActivityAttributes.ContentState.Status) -> String {
  switch status {
  case .connected: return "checkmark.circle.fill"
  case .reconnecting: return "arrow.clockwise.circle.fill"
  case .disconnected: return "pause.circle.fill"
  case .failed: return "exclamationmark.triangle.fill"
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
