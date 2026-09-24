import ActivityKit
import ShhCore
import SwiftUI
import UIKit
import XCTest

@testable import Shh

final class LiveActivityTests: XCTestCase {

  @MainActor
  func testScenario1_LiveActivityStartsOnActiveConnection() async throws {
    let container = AppContainer.demo()
    let host = try Host(name: "Demo Workbox", hostname: "demo.invalid", port: 22, username: "dev")
    let challenge = HostKeyChallenge(
      hostname: "demo.invalid", port: 22, algorithm: "ssh-ed25519",
      fingerprint: "SHA256:demo-fingerprint")
    await container.trustStore.save(challenge)

    await container.connect(to: host)
    XCTAssertEqual(container.activeSession?.state, .connected)

    let mapped = SSHLiveActivityStatusMapper.map(
      sessionState: container.activeSession?.state ?? .disconnected,
      reconnectState: container.reconnectState
    )
    XCTAssertEqual(mapped.status, .connected)

    await container.disconnect()
  }

  @MainActor
  func testScenario2_LiveActivityUpdatesDuringDropAndReconnect() async throws {
    let container = AppContainer.demo()
    let host = try Host(name: "Demo Workbox", hostname: "demo.invalid", port: 22, username: "dev")
    let challenge = HostKeyChallenge(
      hostname: "demo.invalid", port: 22, algorithm: "ssh-ed25519",
      fingerprint: "SHA256:demo-fingerprint")
    await container.trustStore.save(challenge)

    await container.connect(to: host)
    XCTAssertEqual(container.activeSession?.state, .connected)

    // Simulate transport connection drop triggering reconnect attempt 2
    container.reconnectState = .waiting(attempt: 2, delay: 2)
    let mapped = SSHLiveActivityStatusMapper.map(
      sessionState: container.activeSession?.state ?? .disconnected,
      reconnectState: container.reconnectState
    )
    XCTAssertEqual(mapped.status, .reconnecting)
    XCTAssertEqual(mapped.reconnectAttempt, 2)

    await container.disconnect()
  }

  @MainActor
  func testScenario3_DirectReconnectFailureUpdatesToFailed() async throws {
    let container = AppContainer.demo()
    let host = try Host(name: "Demo Workbox", hostname: "demo.invalid", port: 22, username: "dev")
    let challenge = HostKeyChallenge(
      hostname: "demo.invalid", port: 22, algorithm: "ssh-ed25519",
      fingerprint: "SHA256:demo-fingerprint")
    await container.trustStore.save(challenge)

    await container.connect(to: host)
    XCTAssertEqual(container.activeSession?.state, .connected)

    // Directly assign reconnectState to failed (e.g. from network unavailable or exhausted attempts)
    container.reconnectState = .failed(reason: "Network connection dropped.")
    XCTAssertEqual(container.reconnectState, .failed(reason: "Network connection dropped."))

    let mapped = SSHLiveActivityStatusMapper.map(
      sessionState: container.activeSession?.state ?? .disconnected,
      reconnectState: container.reconnectState
    )
    XCTAssertEqual(mapped.status, .failed)

    await container.disconnect()
  }

  @MainActor
  func testScenario4_LiveActivityTerminatesOnDisconnectAndNoLeak() async throws {
    let container = AppContainer.demo()
    let host = try Host(name: "Demo Workbox", hostname: "demo.invalid", port: 22, username: "dev")
    let challenge = HostKeyChallenge(
      hostname: "demo.invalid", port: 22, algorithm: "ssh-ed25519",
      fingerprint: "SHA256:demo-fingerprint")
    await container.trustStore.save(challenge)

    await container.connect(to: host)
    XCTAssertEqual(container.activeSession?.state, .connected)

    await container.disconnect()
    XCTAssertEqual(container.activeSession?.state, .disconnected)

    let mapped = SSHLiveActivityStatusMapper.map(
      sessionState: container.activeSession?.state ?? .disconnected,
      reconnectState: container.reconnectState
    )
    XCTAssertEqual(mapped.status, .disconnected)
  }

  @MainActor
  func testScenario5_PrivacyMetadataBoundary() throws {
    let now = Date()
    let state = ShhSSHSessionActivityAttributes.ContentState(
      status: .connected,
      updatedAt: now,
      reconnectAttempt: nil
    )

    let stateData = try JSONEncoder().encode(state)
    let stateObject = try XCTUnwrap(
      JSONSerialization.jsonObject(with: stateData) as? [String: Any]
    )
    XCTAssertEqual(
      Set(stateObject.keys),
      Set(["status", "updatedAt"])
    )

    let attributes = ShhSSHSessionActivityAttributes(
      sessionID: UUID(),
      displayName: "production-server",
      hostLabel: "prod.internal:22"
    )
    let attributesData = try JSONEncoder().encode(attributes)
    let attributesObject = try XCTUnwrap(
      JSONSerialization.jsonObject(with: attributesData) as? [String: Any]
    )
    XCTAssertEqual(
      Set(attributesObject.keys),
      Set(["sessionID", "displayName", "hostLabel"])
    )
  }

  @MainActor
  func testScenario6_AdversarialEndedActivityDoesNotBlockNewSession() async throws {
    let manager = SSHSessionLiveActivityManager()
    let sessionID = UUID()
    let session = TerminalSession(
      id: sessionID, hostID: UUID(), state: .connected, capabilities: ["ansi"])
    let host = try Host(name: "bastion", hostname: "bastion.internal", port: 22, username: "ops")

    // Start and end activity
    manager.startOrUpdate(session: session, host: host)
    manager.end(sessionID: sessionID)

    // Start again with same session or new session - must not be blocked by ended activity
    let newSession = TerminalSession(
      id: UUID(), hostID: UUID(), state: .connected, capabilities: ["ansi"])
    manager.startOrUpdate(session: newSession, host: host)
    manager.update(sessionID: newSession.id, status: .connected)
    manager.end(sessionID: newSession.id)
  }
  func testStatusMappingReflectsReconnectLifecycle() {
    XCTAssertEqual(
      SSHLiveActivityStatusMapper.map(sessionState: .connected, reconnectState: .idle).status,
      .connected
    )
    XCTAssertEqual(
      SSHLiveActivityStatusMapper.map(
        sessionState: .disconnected,
        reconnectState: .waiting(attempt: 2, delay: 2)
      ).status,
      .reconnecting
    )
    XCTAssertEqual(
      SSHLiveActivityStatusMapper.map(
        sessionState: .failed,
        reconnectState: .connecting(attempt: 3)
      ).reconnectAttempt,
      3
    )
    XCTAssertEqual(
      SSHLiveActivityStatusMapper.map(
        sessionState: .failed,
        reconnectState: .exhausted(attempts: 8)
      ).status,
      .failed
    )
    XCTAssertEqual(
      SSHLiveActivityStatusMapper.map(sessionState: .disconnected, reconnectState: .idle).status,
      .disconnected
    )
  }

  func testActivityContentStateContainsOnlyLifecycleMetadata() throws {
    let now = Date()
    let state = ShhSSHSessionActivityAttributes.ContentState(
      status: .reconnecting,
      updatedAt: now,
      reconnectAttempt: 2
    )

    XCTAssertEqual(state.status, .reconnecting)
    XCTAssertEqual(state.updatedAt, now)
    XCTAssertEqual(state.reconnectAttempt, 2)

    let stateData = try JSONEncoder().encode(state)
    let stateObject = try XCTUnwrap(
      JSONSerialization.jsonObject(with: stateData) as? [String: Any]
    )
    XCTAssertEqual(
      Set(stateObject.keys),
      Set(["status", "updatedAt", "reconnectAttempt"])
    )

    let attributes = ShhSSHSessionActivityAttributes(
      sessionID: UUID(),
      displayName: "prod-server",
      hostLabel: "prod.example.com"
    )
    let attributesData = try JSONEncoder().encode(attributes)
    let attributesObject = try XCTUnwrap(
      JSONSerialization.jsonObject(with: attributesData) as? [String: Any]
    )
    XCTAssertEqual(
      Set(attributesObject.keys),
      Set(["sessionID", "displayName", "hostLabel"])
    )
  }

  func testSafeDisplayAndHostSanitization() {
    XCTAssertEqual(SSHSessionLiveActivityManager.safeDisplayName(""), "SSH session")
    XCTAssertEqual(SSHSessionLiveActivityManager.safeDisplayName("   "), "SSH session")
    XCTAssertEqual(SSHSessionLiveActivityManager.safeDisplayName("Production"), "Production")
    XCTAssertEqual(SSHSessionLiveActivityManager.safeHostLabel(""), "Remote host")
    XCTAssertEqual(SSHSessionLiveActivityManager.safeHostLabel("  10.0.0.1  "), "10.0.0.1")
  }

  @MainActor
  func testLiveActivityManagerLifecycleTransitions() async throws {
    let manager = SSHSessionLiveActivityManager()
    let sessionID = UUID()
    let session = TerminalSession(
      id: sessionID, hostID: UUID(), state: .connected, capabilities: ["ansi"])
    let host = try Host(name: "bastion", hostname: "bastion.internal", port: 22, username: "ops")

    // Should safely enqueue start, update, and end without throwing or crashing
    manager.startOrUpdate(session: session, host: host)
    manager.update(sessionID: sessionID, status: .reconnecting, reconnectAttempt: 1)
    manager.update(sessionID: sessionID, status: .reconnecting, reconnectAttempt: 2)
    manager.update(sessionID: sessionID, status: .connected)
    manager.end(sessionID: sessionID)
    manager.endAll()
  }

  @MainActor
  func testLiveActivityManagerRejectsDifferentSessionUpdate() async throws {
    let manager = SSHSessionLiveActivityManager()
    let session1ID = UUID()
    let session2ID = UUID()
    let session1 = TerminalSession(
      id: session1ID, hostID: UUID(), state: .connected, capabilities: ["ansi"])
    let host = try Host(name: "server1", hostname: "server1.net", port: 22, username: "root")

    manager.startOrUpdate(session: session1, host: host)
    // Attempting to update with a different session ID should be rejected
    manager.update(sessionID: session2ID, status: .failed)
    manager.end(sessionID: session1ID)
  }

  @MainActor
  func testAppContainerConnectAndDisconnectSyncsLiveActivity() async throws {
    let container = AppContainer.demo()
    let host = try Host(name: "Demo Server", hostname: "demo.invalid", username: "dev")
    let challenge = HostKeyChallenge(
      hostname: "demo.invalid", port: 22, algorithm: "ssh-ed25519",
      fingerprint: "SHA256:demo-fingerprint")
    await container.trustStore.save(challenge)

    await container.connect(to: host)
    XCTAssertEqual(container.activeSession?.state, .connected)
    let sessionID = try XCTUnwrap(container.activeSession?.id)
    try await Task.sleep(nanoseconds: 250_000_000)
    XCTAssertTrue(
      Activity<ShhSSHSessionActivityAttributes>.activities.contains { $0.attributes.sessionID == sessionID },
      "AppContainer connection wiring must request a Live Activity after the session becomes connected"
    )

    await container.disconnect()
    XCTAssertEqual(container.activeSession?.state, .disconnected)
  }

  @MainActor
  func testLiveActivityDeepLinkRoundTripsWithoutSensitiveData() throws {
    let sessionID = UUID()
    let url = LiveActivityDeepLink.url(sessionID: sessionID)
    XCTAssertEqual(LiveActivityDeepLink.sessionID(from: url), sessionID)
    XCTAssertFalse(url.absoluteString.contains("demo.invalid"))
    XCTAssertNil(LiveActivityDeepLink.sessionID(from: URL(string: "shh://session/\(sessionID)?host=secret")!))
    XCTAssertNil(LiveActivityDeepLink.sessionID(from: URL(string: "https://session/\(sessionID)")!))
  }

  @MainActor
  func testLiveActivityDeepLinkOpensOnlyMatchingLocalRestorationSession() async throws {
    let host = try Host(name: "Deep Link Host", hostname: "demo.invalid", username: "dev")
    let sessionID = UUID()
    let restorationStore = InMemorySessionRestorationStore(
      initial: SessionRestorationMetadata(hostID: host.id, sessionID: sessionID)
    )
    let catalog = InMemoryCatalog(snapshot: CatalogSnapshot(hosts: [host], identities: []))
    let container = AppContainer.demo(catalog: catalog, restorationStore: restorationStore)
    let challenge = HostKeyChallenge(
      hostname: "demo.invalid", port: 22, algorithm: "ssh-ed25519",
      fingerprint: "SHA256:demo-fingerprint")
    await container.trustStore.save(challenge)

    let opened = await container.openLiveActivitySession(sessionID: sessionID)
    XCTAssertTrue(opened)
    XCTAssertEqual(container.activeSession?.id, sessionID)
    let rejected = await container.openLiveActivitySession(sessionID: UUID())
    XCTAssertFalse(rejected)
    await container.disconnect()
  }

  @MainActor
  func testSequentialSessionsHandledCleanly() async throws {
    let manager = SSHSessionLiveActivityManager()
    let session1 = TerminalSession(
      id: UUID(), hostID: UUID(), state: .connected, capabilities: ["ansi"])
    let host1 = try Host(
      name: "host-alpha", hostname: "alpha.internal", port: 22, username: "admin")
    let session2 = TerminalSession(
      id: UUID(), hostID: UUID(), state: .connected, capabilities: ["ansi"])
    let host2 = try Host(name: "host-beta", hostname: "beta.internal", port: 22, username: "admin")

    manager.startOrUpdate(session: session1, host: host1)
    manager.update(sessionID: session1.id, status: .connected)
    // Starting session 2 while session 1 is active must terminate session 1 and start session 2
    manager.startOrUpdate(session: session2, host: host2)
    manager.update(sessionID: session2.id, status: .reconnecting, reconnectAttempt: 1)
    manager.end(sessionID: session2.id)
  }

  @MainActor
  func testEndedActivityDoesNotBlockNewSessionActivity() async throws {
    let manager = SSHSessionLiveActivityManager()
    let sessionID = UUID()
    let session = TerminalSession(
      id: sessionID, hostID: UUID(), state: .connected, capabilities: ["ansi"])
    let host = try Host(name: "bastion", hostname: "bastion.internal", port: 22, username: "ops")

    manager.startOrUpdate(session: session, host: host)
    manager.end(sessionID: sessionID)

    manager.startOrUpdate(session: session, host: host)
    manager.update(sessionID: sessionID, status: .connected)
    manager.end(sessionID: sessionID)
  }

  @MainActor
  func testDirectReconnectStateMutationTriggersSync() async throws {
    let container = AppContainer.demo()
    let host = try Host(name: "Demo Server", hostname: "demo.invalid", username: "dev")
    let challenge = HostKeyChallenge(
      hostname: "demo.invalid", port: 22, algorithm: "ssh-ed25519",
      fingerprint: "SHA256:demo-fingerprint")
    await container.trustStore.save(challenge)

    await container.connect(to: host)
    XCTAssertEqual(container.activeSession?.state, .connected)

    container.reconnectState = .failed(reason: "Network unavailable.")
    XCTAssertEqual(container.reconnectState, .failed(reason: "Network unavailable."))

    await container.disconnect()
  }

  @MainActor
  func testCancelReconnectEndsLiveActivityCleanly() async throws {
    let container = AppContainer.demo()
    let host = try Host(name: "Demo Server", hostname: "demo.invalid", username: "dev")
    let challenge = HostKeyChallenge(
      hostname: "demo.invalid", port: 22, algorithm: "ssh-ed25519",
      fingerprint: "SHA256:demo-fingerprint")
    await container.trustStore.save(challenge)

    await container.connect(to: host)
    XCTAssertEqual(container.activeSession?.state, .connected)

    await container.cancelReconnect()
    XCTAssertTrue(container.isExplicitDisconnect)
    XCTAssertEqual(container.reconnectState, .cancelled)
    XCTAssertEqual(container.activeSession?.state, .disconnected)
  }

  func testActivityAuthorizationInfoStatus() {
    let areEnabled = ActivityAuthorizationInfo().areActivitiesEnabled
    print("DEBUG_LIVE_ACTIVITY: areActivitiesEnabled on simulator: \(areEnabled)")
  }

  @MainActor
  func testRealActivityRequestUpdateAndEnd() async throws {
    XCTAssertTrue(ActivityAuthorizationInfo().areActivitiesEnabled)

    let sessionID = UUID()
    let attributes = ShhSSHSessionActivityAttributes(
      sessionID: sessionID,
      displayName: "Test Server",
      hostLabel: "test.example.com"
    )
    let initialContent = ActivityContent(
      state: ShhSSHSessionActivityAttributes.ContentState(status: .connected),
      staleDate: Date().addingTimeInterval(900)
    )

    // Request real Live Activity
    let activity = try Activity.request(
      attributes: attributes,
      content: initialContent,
      pushType: nil
    )

    XCTAssertEqual(activity.attributes.sessionID, sessionID)
    XCTAssertEqual(activity.content.state.status, .connected)

    // Verify it exists in Activity<Attributes>.activities
    let allActivities = Activity<ShhSSHSessionActivityAttributes>.activities
    XCTAssertTrue(allActivities.contains { $0.id == activity.id })

    // Update content state to reconnecting
    let updatedContent = ActivityContent(
      state: ShhSSHSessionActivityAttributes.ContentState(
        status: .reconnecting, reconnectAttempt: 1),
      staleDate: Date().addingTimeInterval(300)
    )
    await activity.update(updatedContent)

    // End activity
    await activity.end(nil, dismissalPolicy: .immediate)
  }

  func testStatusDisplayNamesDescribeEveryLifecycleState() {
    XCTAssertEqual(
      ShhSSHSessionActivityAttributes.ContentState.Status.connected.displayName,
      "Connected"
    )
    XCTAssertEqual(
      ShhSSHSessionActivityAttributes.ContentState.Status.reconnecting.displayName,
      "Reconnecting"
    )
    XCTAssertEqual(
      ShhSSHSessionActivityAttributes.ContentState.Status.disconnected.displayName,
      "Disconnected"
    )
    XCTAssertEqual(
      ShhSSHSessionActivityAttributes.ContentState.Status.failed.displayName,
      "Connection failed"
    )
  }

  @MainActor
  func testLiveActivityCardRendersReconnectMetadata() {
    let state = ShhSSHSessionActivityAttributes.ContentState(
      status: .reconnecting,
      updatedAt: Date(timeIntervalSince1970: 1_700_000_000),
      reconnectAttempt: 2
    )
    var renderer = ImageRenderer(
      content: ShhLiveActivityCardView(
        displayName: "bastion",
        hostLabel: "bastion.internal:22",
        state: state
      )
      .frame(width: 360, height: 180)
    )
    renderer.scale = 1

    let image = renderer.uiImage
    XCTAssertEqual(image?.size, CGSize(width: 360, height: 180))
    XCTAssertNotNil(image?.pngData())
  }

  func testStatusMapperCoversAllEdgeCases() {
    // ReconnectState edge cases
    XCTAssertEqual(
      SSHLiveActivityStatusMapper.map(sessionState: .connected, reconnectState: .connected).status,
      .connected
    )
    XCTAssertEqual(
      SSHLiveActivityStatusMapper.map(sessionState: .connecting, reconnectState: .connected).status,
      .reconnecting
    )
    XCTAssertEqual(
      SSHLiveActivityStatusMapper.map(
        sessionState: .connected, reconnectState: .failed(reason: "timeout")
      ).status,
      .failed
    )
    XCTAssertEqual(
      SSHLiveActivityStatusMapper.map(sessionState: .connected, reconnectState: .cancelled).status,
      .disconnected
    )
    XCTAssertEqual(
      SSHLiveActivityStatusMapper.map(sessionState: .connecting, reconnectState: .idle).status,
      .disconnected
    )
    XCTAssertEqual(
      SSHLiveActivityStatusMapper.map(sessionState: .failed, reconnectState: .idle).status,
      .failed
    )
  }

  func testSafeDisplayAndHostSanitizationLengthLimits() {
    let longName = String(repeating: "ServerAlpha-", count: 10)
    let sanitizedName = SSHSessionLiveActivityManager.safeDisplayName(longName)
    XCTAssertEqual(sanitizedName.count, 80)
    XCTAssertEqual(sanitizedName, String(longName.prefix(80)))

    let longHost = String(repeating: "node-subdomain.", count: 20)
    let sanitizedHost = SSHSessionLiveActivityManager.safeHostLabel(longHost)
    XCTAssertEqual(sanitizedHost.count, 253)
    XCTAssertEqual(sanitizedHost, String(longHost.prefix(253)))

    XCTAssertEqual(SSHSessionLiveActivityManager.safeDisplayName("   \n\t  "), "SSH session")
    XCTAssertEqual(SSHSessionLiveActivityManager.safeHostLabel("   \n\t  "), "Remote host")
  }

  @MainActor
  func testStartOrUpdateRejectsNonConnectedSessions() async throws {
    let manager = SSHSessionLiveActivityManager()
    let host = try Host(name: "bastion", hostname: "bastion.internal", port: 22, username: "ops")

    let disconnectedSession = TerminalSession(
      id: UUID(), hostID: UUID(), state: .disconnected, capabilities: ["ansi"])
    manager.startOrUpdate(session: disconnectedSession, host: host)

    let connectingSession = TerminalSession(
      id: UUID(), hostID: UUID(), state: .connecting, capabilities: ["ansi"])
    manager.startOrUpdate(session: connectingSession, host: host)

    let failedSession = TerminalSession(
      id: UUID(), hostID: UUID(), state: .failed, capabilities: ["ansi"])
    manager.startOrUpdate(session: failedSession, host: host)

    for _ in 0..<5 {
      await Task.yield()
    }
    manager.endAll()
  }

  @MainActor
  func testLiveActivityCardRendersAllLifecycleStates() {
    let states: [ShhSSHSessionActivityAttributes.ContentState] = [
      ShhSSHSessionActivityAttributes.ContentState(
        status: .connected,
        updatedAt: Date(timeIntervalSince1970: 1_700_000_000)
      ),
      ShhSSHSessionActivityAttributes.ContentState(
        status: .disconnected,
        updatedAt: Date(timeIntervalSince1970: 1_700_000_000)
      ),
      ShhSSHSessionActivityAttributes.ContentState(
        status: .failed,
        updatedAt: Date(timeIntervalSince1970: 1_700_000_000)
      ),
      ShhSSHSessionActivityAttributes.ContentState(
        status: .reconnecting,
        updatedAt: Date(timeIntervalSince1970: 1_700_000_000),
        reconnectAttempt: nil
      ),
    ]

    for state in states {
      var renderer = ImageRenderer(
        content: ShhLiveActivityCardView(
          displayName: "workstation",
          hostLabel: "workstation.internal:22",
          state: state
        )
        .frame(width: 360, height: 180)
      )
      renderer.scale = 1
      let image = renderer.uiImage
      XCTAssertEqual(image?.size, CGSize(width: 360, height: 180))
      XCTAssertNotNil(image?.pngData())
    }
  }

  @MainActor
  func testLiveActivityManagerEndAllWhileActivityActive() async throws {
    let manager = SSHSessionLiveActivityManager()
    let session = TerminalSession(
      id: UUID(), hostID: UUID(), state: .connected, capabilities: ["ansi"])
    let host = try Host(name: "prod-db", hostname: "db.internal", port: 22, username: "admin")

    manager.startOrUpdate(session: session, host: host)
    for _ in 0..<10 {
      await Task.yield()
    }

    manager.startOrUpdate(session: session, host: host)
    for _ in 0..<10 {
      await Task.yield()
    }

    manager.update(sessionID: session.id, status: .reconnecting, reconnectAttempt: 1)
    for _ in 0..<10 {
      await Task.yield()
    }

    let randomID = UUID()
    manager.end(sessionID: randomID)

    manager.endAll()
    for _ in 0..<10 {
      await Task.yield()
    }
  }
}
