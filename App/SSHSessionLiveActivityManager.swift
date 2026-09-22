import ActivityKit
import Foundation
import ShhCore

/// Coordinates the ActivityKit Live Activity presentation for active SSH sessions on `@MainActor`.
///
/// Invariants & Safety Constraints:
/// - Single-activity policy: Only one active SSH session Live Activity is displayed at any time.
///   Starting a new session or encountering stale activities from prior runs terminates previous activities.
/// - Background execution: Live Activities serve solely as ambient visual status indicators; they do not
///   extend background socket execution or keep network sockets alive when the app is suspended.
/// - Privacy: Only high-level connection lifecycle status and sanitized labels are displayed; commands,
///   terminal buffers, and credentials are never exposed.
@MainActor
final class SSHSessionLiveActivityManager {
  typealias Attributes = ShhSSHSessionActivityAttributes
  typealias Status = Attributes.ContentState.Status

  private var activity: Activity<Attributes>?
  private var currentSessionID: UUID?
  private var operationTask: Task<Void, Never>?

  deinit {
    operationTask?.cancel()
  }

  func startOrUpdate(session: TerminalSession, host: Host) {
    guard session.state == .connected else { return }
    currentSessionID = session.id
    let state = Attributes.ContentState(status: .connected)
    enqueue { [weak self] in
      guard let self else { return }
      await self.performStartOrUpdate(
        sessionID: session.id,
        displayName: Self.safeDisplayName(host.name),
        hostLabel: Self.safeHostLabel(host.hostname),
        state: state
      )
    }
  }

  func update(sessionID: UUID, status: Status, reconnectAttempt: Int? = nil) {
    if currentSessionID == nil {
      currentSessionID = sessionID
    }
    guard currentSessionID == sessionID else { return }
    let state = Attributes.ContentState(
      status: status,
      reconnectAttempt: reconnectAttempt
    )
    enqueue { [weak self] in
      guard let self else { return }
      await self.performUpdate(sessionID: sessionID, state: state)
    }
  }

  func end(sessionID: UUID) {
    if currentSessionID == sessionID {
      currentSessionID = nil
    }
    enqueue { [weak self] in
      guard let self else { return }
      await self.performEnd(sessionID: sessionID)
    }
  }

  func endAll() {
    currentSessionID = nil
    enqueue { [weak self] in
      guard let self else { return }
      await self.performEnd(sessionID: nil)
    }
  }

  private func enqueue(_ operation: @escaping @MainActor () async -> Void) {
    let previous = operationTask
    operationTask = Task { @MainActor [weak self] in
      _ = await previous?.value
      guard let self, !Task.isCancelled else { return }
      await operation()
    }
  }

  private static func isAlive(_ activity: Activity<Attributes>) -> Bool {
    activity.activityState != .ended && activity.activityState != .dismissed
  }

  private func performStartOrUpdate(
    sessionID: UUID,
    displayName: String,
    hostLabel: String,
    state: Attributes.ContentState
  ) async {
    guard currentSessionID == sessionID,
      ActivityAuthorizationInfo().areActivitiesEnabled
    else { return }

    if let existing = activity,
      existing.attributes.sessionID != sessionID || !Self.isAlive(existing)
    {
      if Self.isAlive(existing) {
        await existing.end(nil, dismissalPolicy: .immediate)
      }
      self.activity = nil
    }

    for existing in Activity<Attributes>.activities where existing.attributes.sessionID != sessionID
    {
      if Self.isAlive(existing) {
        await existing.end(nil, dismissalPolicy: .immediate)
      }
    }

    if activity == nil {
      activity = Activity<Attributes>.activities.first(where: {
        $0.attributes.sessionID == sessionID && Self.isAlive($0)
      })
    }

    if let activity, activity.attributes.sessionID == sessionID, Self.isAlive(activity) {
      await activity.update(ActivityContent(state: state, staleDate: staleDate(for: state)))
      return
    }

    let attributes = Attributes(
      sessionID: sessionID,
      displayName: displayName,
      hostLabel: hostLabel
    )
    do {
      activity = try await Activity.request(
        attributes: attributes,
        content: ActivityContent(state: state, staleDate: staleDate(for: state)),
        pushType: nil
      )
    } catch {
      // Live Activity availability is optional and must never affect SSH.
    }
  }

  private func performUpdate(sessionID: UUID, state: Attributes.ContentState) async {
    guard currentSessionID == sessionID else { return }

    if let existing = activity, !Self.isAlive(existing) {
      self.activity = nil
    }

    if activity == nil || activity?.attributes.sessionID != sessionID {
      activity = Activity<Attributes>.activities.first(where: {
        $0.attributes.sessionID == sessionID && Self.isAlive($0)
      })
    }

    guard let activity, activity.attributes.sessionID == sessionID, Self.isAlive(activity) else {
      return
    }
    await activity.update(ActivityContent(state: state, staleDate: staleDate(for: state)))
  }

  private func performEnd(sessionID: UUID?) async {
    if let sessionID {
      if let activity, activity.attributes.sessionID == sessionID {
        self.activity = nil
        if Self.isAlive(activity) {
          await activity.end(nil, dismissalPolicy: .immediate)
        }
      }
      for existing in Activity<Attributes>.activities
      where existing.attributes.sessionID == sessionID {
        if Self.isAlive(existing) {
          await existing.end(nil, dismissalPolicy: .immediate)
        }
      }
    } else {
      if let activity {
        self.activity = nil
        if Self.isAlive(activity) {
          await activity.end(nil, dismissalPolicy: .immediate)
        }
      }
      for existing in Activity<Attributes>.activities {
        if Self.isAlive(existing) {
          await existing.end(nil, dismissalPolicy: .immediate)
        }
      }
    }
  }

  private func staleDate(for state: Attributes.ContentState) -> Date {
    state.updatedAt.addingTimeInterval(state.status == .connected ? 15 * 60 : 5 * 60)
  }

  nonisolated static func safeDisplayName(_ name: String) -> String {
    let value = name.trimmingCharacters(in: .whitespacesAndNewlines)
    return value.isEmpty ? "SSH session" : String(value.prefix(80))
  }

  nonisolated static func safeHostLabel(_ hostname: String) -> String {
    let value = hostname.trimmingCharacters(in: .whitespacesAndNewlines)
    return value.isEmpty ? "Remote host" : String(value.prefix(253))
  }
}

/// Maps terminal session state and reconnection coordinator state to Live Activity status.
enum SSHLiveActivityStatusMapper {
  typealias Status = ShhSSHSessionActivityAttributes.ContentState.Status

  static func map(
    sessionState: TerminalSessionState,
    reconnectState: ReconnectState
  ) -> (status: Status, reconnectAttempt: Int?) {
    switch reconnectState {
    case .waiting(let attempt, _), .connecting(let attempt):
      return (.reconnecting, attempt)
    case .exhausted:
      return (.failed, nil)
    case .failed:
      return (.failed, nil)
    case .cancelled:
      return (.disconnected, nil)
    case .connected:
      return sessionState == .connected ? (.connected, nil) : (.reconnecting, nil)
    case .idle:
      switch sessionState {
      case .connected: return (.connected, nil)
      case .failed: return (.failed, nil)
      case .disconnected, .connecting: return (.disconnected, nil)
      }
    }
  }
}
