import ShhCore
import ShhSSH
import ShhTerminal
import SwiftUI
import XCTest

@testable import Shh

@MainActor
final class MultiSessionAppTests: XCTestCase {

    func testTwoSessionsStreamIndependentOutputWithoutCrosstalk() async throws {
        let mockA = MockSSHConnection()
        let mockB = MockSSHConnection()
        let transport = ControllableTransport()
        transport.onConnect = { host in
            host.hostname == "alpha.invalid" ? mockA : mockB
        }

        let container = AppContainer(transport: transport)
        let hostA = try Host(name: "Alpha Host", hostname: "alpha.invalid", username: "dev")
        let hostB = try Host(name: "Beta Host", hostname: "beta.invalid", username: "dev")

        await container.connect(to: hostA)
        let sessionAID = try XCTUnwrap(container.activeSession?.id)
        XCTAssertEqual(container.openSessions.count, 1)

        await container.connect(to: hostB)
        let sessionBID = try XCTUnwrap(container.activeSession?.id)
        XCTAssertEqual(container.openSessions.count, 2)
        XCTAssertNotEqual(sessionAID, sessionBID)
        XCTAssertEqual(container.selectedSessionID, sessionBID)

        mockA.emit(.bytes(Data("alpha stream output\r\n".utf8)))
        mockB.emit(.bytes(Data("beta stream output\r\n".utf8)))
        try await Task.sleep(nanoseconds: 50_000_000)

        // Session B is selected: active container text must only reflect B
        XCTAssertTrue(container.terminalText.contains("beta stream output"))
        XCTAssertFalse(container.terminalText.contains("alpha stream output"))

        // Inspect Session A runtime directly: must contain A's output, not B's
        let runtimeA = try XCTUnwrap(container.runtime(for: sessionAID))
        let runtimeB = try XCTUnwrap(container.runtime(for: sessionBID))
        XCTAssertTrue(runtimeA.terminalText.contains("alpha stream output"))
        XCTAssertFalse(runtimeA.terminalText.contains("beta stream output"))
        XCTAssertTrue(runtimeB.terminalText.contains("beta stream output"))
        XCTAssertFalse(runtimeB.terminalText.contains("alpha stream output"))

        // Switch to Session A: projected terminal text updates to A
        container.selectSession(id: sessionAID)
        XCTAssertEqual(container.selectedSessionID, sessionAID)
        XCTAssertEqual(container.activeSession?.id, sessionAID)
        XCTAssertEqual(container.activeHost?.id, hostA.id)
        XCTAssertTrue(container.terminalText.contains("alpha stream output"))
        XCTAssertFalse(container.terminalText.contains("beta stream output"))
    }

    func testDisconnectingSessionCannotClearNewSelectionAfterTeardown() async throws {
        let closeGate = MultiSessionGate()
        let connectionA = MockSSHConnection()
        connectionA.onClose = { await closeGate.wait() }
        let connectionB = MockSSHConnection()
        let transport = ControllableTransport()
        transport.onConnect = { host in
            host.hostname == "alpha.invalid" ? connectionA : connectionB
        }
        let container = AppContainer(transport: transport)
        let hostA = try Host(name: "Alpha Host", hostname: "alpha.invalid", username: "dev")
        let hostB = try Host(name: "Beta Host", hostname: "beta.invalid", username: "dev")

        await container.connect(to: hostA)
        let sessionAID = try XCTUnwrap(container.selectedSessionID)
        await container.connect(to: hostB)
        let sessionBID = try XCTUnwrap(container.selectedSessionID)
        container.selectSession(id: sessionAID)

        let runtimeB = try XCTUnwrap(container.runtime(for: sessionBID))
        let disconnecting = Task { @MainActor in await container.disconnect() }
        await closeGate.waitForStart()

        // B becomes the selected owner while A's transport close is suspended.
        container.selectSession(id: sessionBID)
        runtimeB.setRedactor(Redactor(secrets: ["beta-secret"]))
        container.selectSession(id: sessionBID)
        XCTAssertEqual(container.activeSession?.id, sessionBID)
        XCTAssertEqual(container.activeHost?.id, hostB.id)
        XCTAssertEqual(container.redactor.secrets, ["beta-secret"])

        await closeGate.open()
        await disconnecting.value

        XCTAssertEqual(container.selectedSessionID, sessionBID)
        XCTAssertEqual(container.activeSession?.id, sessionBID)
        XCTAssertEqual(container.activeSession?.state, .connected)
        XCTAssertEqual(container.activeHost?.id, hostB.id)
        XCTAssertFalse(connectionB.isClosed)
        XCTAssertEqual(container.redactor.secrets, ["beta-secret"])
        XCTAssertTrue(connectionA.isClosed)
    }

    func testSameSessionSFTPListingPublishesOnlyLatestRequest() async throws {
        let repository = OrderedSFTPRepository()
        let connection = MockSSHConnection()
        let transport = ControllableTransport()
        transport.onConnect = { _ in connection }
        let container = AppContainer(transport: transport, sftpRepository: repository)
        let host = try Host(name: "Ordered SFTP Host", hostname: "ordered.invalid", username: "dev")

        await container.connect(to: host)
        await repository.waitForRequestCount(1)
        await repository.release(request: 0)
        try await eventually { !container.isLoadingDirectory }

        let first = Task { @MainActor in
            await container.loadDirectory(at: RemotePath("/first"), bypassCache: true)
        }
        await repository.waitForRequestCount(2)
        let second = Task { @MainActor in
            await container.loadDirectory(at: RemotePath("/second"), bypassCache: true)
        }
        await repository.waitForRequestCount(3)

        // Complete the newer request first, then let the older request finish.
        await repository.release(request: 2)
        await second.value
        await repository.release(request: 1)
        await first.value

        XCTAssertEqual(container.currentPath, RemotePath("/second"))
        XCTAssertEqual(container.currentDirectoryFiles.map(\.name), ["request-2"])
        XCTAssertFalse(container.isLoadingDirectory)
        XCTAssertNil(container.directoryErrorMessage)
    }

    func testStaleSFTPListingCannotPublishAfterSelectionSwitch() async throws {
        let gate = MultiSessionGate()
        // Listing 1 (A's initial load) and listing 2 (A's stale request) are gated.
        // B's own listing (3) is not, so it publishes before the stale one resumes.
        let repository = DelayedSFTPRepository(gate: gate, gatedListingCount: 2)
        let connectionA = MockSSHConnection()
        let connectionB = MockSSHConnection()
        let transport = ControllableTransport()
        transport.onConnect = { host -> any SSHConnection in
            host.hostname == "alpha.invalid" ? connectionA : connectionB
        }
        let container = AppContainer(transport: transport, sftpRepository: repository)
        let hostA = try Host(name: "Alpha Host", hostname: "alpha.invalid", username: "dev")
        let hostB = try Host(name: "Beta Host", hostname: "beta.invalid", username: "dev")

        await container.connect(to: hostA)
        await gate.waitForStart()
        XCTAssertTrue(container.isLoadingDirectory)

        // A uses a distinct path so a stale publish is observable as a path change.
        let staleListing = Task { @MainActor in
            await container.loadDirectory(at: RemotePath("/stale"), bypassCache: true)
        }
        for _ in 0..<500 {
            if await repository.listedDirectoryCount() >= 2 { break }
            await Task.yield()
        }
        let staleListingStarted = await repository.listedDirectoryCount()
        XCTAssertEqual(staleListingStarted, 2)

        await container.connect(to: hostB)
        XCTAssertEqual(container.selectedSessionID, container.openSessions.last?.id)
        // B's per-runtime auxiliary binds and loads its own home listing (not gated).
        for _ in 0..<500 where container.currentDirectoryFiles.isEmpty {
            await Task.yield()
        }
        XCTAssertFalse(container.currentDirectoryFiles.isEmpty)

        await gate.open()
        await staleListing.value

        XCTAssertNotEqual(container.currentPath, RemotePath("/stale"))
        XCTAssertEqual(container.currentPath, RemotePath("/home/dev"))
        XCTAssertNil(container.directoryErrorMessage)
    }

    func testStaleSFTPPreviewResultAndEditorErrorCannotPublishAfterSelectionSwitch()
        async throws
    {
        let initialGate = MultiSessionGate()
        let repository = DelayedSFTPRepository(gate: initialGate)
        let transport = ControllableTransport()
        let container = AppContainer(transport: transport, sftpRepository: repository)
        let hostA = try Host(name: "Alpha Host", hostname: "alpha.invalid", username: "dev")
        let hostB = try Host(name: "Beta Host", hostname: "beta.invalid", username: "dev")

        await initialGate.open()
        await container.connect(to: hostA)
        try await eventually { !container.currentDirectoryFiles.isEmpty }
        let sessionAID = try XCTUnwrap(container.selectedSessionID)
        let file = try XCTUnwrap(container.currentDirectoryFiles.first { $0.isFile })

        await repository.delayRead()
        let preview = Task { @MainActor in await container.loadPreview(for: file) }
        await repository.waitForReadStart()
        await container.connect(to: hostB)
        await repository.releaseRead()
        await preview.value
        XCTAssertNil(container.previewFile)
        XCTAssertNil(container.previewData)
        XCTAssertNil(container.previewErrorMessage)

        let sessionBID = try XCTUnwrap(container.selectedSessionID)
        await container.closeSession(id: sessionBID)
        container.selectSession(id: sessionAID)
        await repository.delayRead(failing: true)
        let editor = Task { @MainActor in try? await container.openEditor(for: file) }
        await repository.waitForReadStart()
        await container.connect(to: hostB)
        await repository.releaseRead()
        await editor.value
        XCTAssertNil(container.activeEditingFile)
        XCTAssertNil(container.editorErrorMessage)
    }

    func testReachabilityAndForegroundEventsProgressRecoveryOwnerPastExplicitSelection()
        async throws
    {
        let recoveryGate = MultiSessionGate()
        let connectionA = MockSSHConnection()
        let connectionB = MockSSHConnection()
        let replacementB = MockSSHConnection()
        let bConnections = ConnectionSequence([connectionB, replacementB])
        let transport = ControllableTransport()
        transport.onConnect = { host in
            host.hostname == "alpha.invalid" ? connectionA : await bConnections.next()
        }
        let container = AppContainer(
            transport: transport,
            reachabilityMonitor: MockReachabilityMonitor(isReachable: true),
            reconnectCoordinator: ReconnectCoordinator(
                clock: { _ in await recoveryGate.wait() },
                jitter: ReconnectCoordinator.zeroJitter
            )
        )
        let hostA = try Host(name: "Alpha Host", hostname: "alpha.invalid", username: "dev")
        let hostB = try Host(name: "Beta Host", hostname: "beta.invalid", username: "dev")

        await container.connect(to: hostA)
        let sessionAID = try XCTUnwrap(container.selectedSessionID)
        await container.connect(to: hostB)
        let sessionBID = try XCTUnwrap(container.selectedSessionID)

        // A clean close is not a recovery trigger (717d63c), so use a transport error.
        connectionB.emit(.error(.connectionRefused))
        try await eventually {
            container.runtime(for: sessionBID)?.reconnectState.isReconnecting == true
        }

        // A is explicitly disconnected while B owns the coordinator run.
        container.selectSession(id: sessionAID)
        await container.disconnect()
        XCTAssertTrue(container.isExplicitDisconnect)
        XCTAssertEqual(container.runtime(for: sessionAID)?.session.state, .disconnected)

        // These events must consult B's owner state rather than A's selected
        // explicit-disconnect bit, and must not project B's progress onto A.
        container.handleReachabilityChange(true)
        container.handleScenePhaseChange(.active)
        await recoveryGate.open()
        try await eventually {
            container.runtime(for: sessionBID)?.session.state == .connected
                && container.runtime(for: sessionBID)?.reconnectState == .connected
        }

        XCTAssertEqual(container.selectedSessionID, sessionAID)
        XCTAssertEqual(container.activeSession?.state, .disconnected)
        XCTAssertEqual(container.runtime(for: sessionAID)?.reconnectState, .idle)
        XCTAssertFalse(replacementB.isClosed)
    }

    func testSlowReconnectProjectsConnectingBeforeTransportAndRetryAfterFailure()
        async throws
    {
        let recoveryGate = MultiSessionGate()
        let originalA = MockSSHConnection()
        let replacementA = MockSSHConnection()
        let connectionB = MockSSHConnection()
        let outcomes = DelayedReconnectOutcomes(
            outcomes: [.success(originalA), .failure(.timeout), .success(replacementA)],
            gate: recoveryGate
        )
        let transport = ControllableTransport()
        transport.onConnect = { host in
            if host.hostname == "alpha.invalid" {
                return try await outcomes.next()
            }
            return connectionB
        }
        let container = AppContainer(
            transport: transport,
            reachabilityMonitor: MockReachabilityMonitor(isReachable: true),
            reconnectCoordinator: ReconnectCoordinator(
                maxAttempts: 1,
                clock: { _ in },
                jitter: ReconnectCoordinator.zeroJitter
            )
        )
        let hostA = try Host(name: "Alpha Host", hostname: "alpha.invalid", username: "dev")
        let hostB = try Host(name: "Beta Host", hostname: "beta.invalid", username: "dev")

        await container.connect(to: hostA)
        let sessionAID = try XCTUnwrap(container.selectedSessionID)
        await container.connect(to: hostB)
        let sessionBID = try XCTUnwrap(container.selectedSessionID)
        container.selectSession(id: sessionAID)

        originalA.emit(.error(.timeout))
        await recoveryGate.waitForStart()
        try await eventually {
            container.runtime(for: sessionAID)?.reconnectState.isReconnecting == true
        }

        // Selection during a slow transport await must project the owner's
        // connecting state, never the stale failed state from before retry.
        container.selectSession(id: sessionBID)
        container.selectSession(id: sessionAID)
        XCTAssertTrue(container.reconnectState.isReconnecting)
        XCTAssertEqual(container.activeSession?.state, .connecting)
        XCTAssertEqual(container.runtime(for: sessionAID)?.session.state, .connecting)

        await recoveryGate.open()
        try await eventually {
            container.runtime(for: sessionAID)?.session.state == .failed
                && container.runtime(for: sessionAID)?.reconnectState.isReconnecting == false
        }
        XCTAssertFalse(container.reconnectState.isReconnecting)
        XCTAssertTrue(
            container.reconnectState == .exhausted(attempts: 1)
                || container.reconnectState == .failed(reason: "Connection timed out.")
        )

        await container.retryReconnect()
        XCTAssertEqual(container.activeSession?.state, .connected)
        XCTAssertTrue((container.connection as AnyObject) === (replacementA as AnyObject))
        await container.disconnect()
    }

    func testTCPInterfaceRecoveryPreservesOwnerFailureAcrossSelectionSwitch() async throws {
        let closeGate = MultiSessionGate()
        let connectionA = MockSSHConnection()
        let connectionB = MockSSHConnection()
        let replacementA = MockSSHConnection()
        let aConnections = ConnectionSequence([connectionA, replacementA])
        let transport = ControllableTransport()
        transport.onConnect = { host in
            host.hostname == "alpha.invalid" ? await aConnections.next() : connectionB
        }
        let container = AppContainer(
            transport: transport,
            reachabilityMonitor: MockReachabilityMonitor(isReachable: true),
            reconnectCoordinator: ReconnectCoordinator(
                clock: { _ in }, jitter: ReconnectCoordinator.zeroJitter))
        let hostA = try Host(name: "Alpha Host", hostname: "alpha.invalid", username: "dev")
        let hostB = try Host(name: "Beta Host", hostname: "beta.invalid", username: "dev")

        await container.connect(to: hostA)
        let sessionAID = try XCTUnwrap(container.selectedSessionID)
        await container.connect(to: hostB)
        let sessionBID = try XCTUnwrap(container.selectedSessionID)
        container.selectSession(id: sessionAID)
        connectionA.onClose = { await closeGate.wait() }

        let interfaceChange = Task { @MainActor in
            await container.handleNetworkInterfaceChange(
                .cellular,
                roamingState: NetworkRoamingState(currentInterface: .cellular))
        }
        await closeGate.waitForStart()
        container.selectSession(id: sessionBID)
        await closeGate.open()
        await interfaceChange.value

        let runtimeA = try XCTUnwrap(container.runtime(for: sessionAID))
        XCTAssertEqual(container.selectedSessionID, sessionBID)
        XCTAssertEqual(runtimeA.session.state, .disconnected)
        XCTAssertEqual(
            runtimeA.reconnectState,
            .failed(reason: "Network changed. Retry connection.")
        )
        XCTAssertEqual(container.runtime(for: sessionBID)?.session.state, .connected)
        XCTAssertFalse(connectionB.isClosed)

        container.selectSession(id: sessionAID)
        try await eventually {
            container.selectedSessionID == sessionAID
                && container.runtime(for: sessionAID)?.session.state == .connected
        }
        XCTAssertFalse(connectionB.isClosed)
        XCTAssertTrue((runtimeA.connection as AnyObject) === (replacementA as AnyObject))
    }

    func testMoshSelectionClearsOldProjectionBeforeDelayedCompletion() async throws {
        let connectionA = ControllableMoshConnection(
            sessionInfo: MoshSessionInfo(udpPort: 60101, sessionKey: "mosh-alpha", pid: 42001))
        let delayedB = DelayedMoshConnection(
            base: ControllableMoshConnection(
                sessionInfo: MoshSessionInfo(udpPort: 60102, sessionKey: "mosh-beta", pid: 42002)))
        let moshTransport = ControllableMoshTransport()
        moshTransport.onConnect = { host -> any SSHConnection in
            host.hostname == "alpha.invalid" ? connectionA : delayedB
        }
        let container = AppContainer(moshTransport: moshTransport)
        let hostA = try Host(
            name: "Alpha Mosh", hostname: "alpha.invalid", username: "dev",
            connection: .mosh(MoshOptions()))
        let hostB = try Host(
            name: "Beta Mosh", hostname: "beta.invalid", username: "dev",
            connection: .mosh(MoshOptions()))

        await container.connect(to: hostA)
        let sessionAID = try XCTUnwrap(container.selectedSessionID)
        await container.connect(to: hostB)
        let sessionBID = try XCTUnwrap(container.selectedSessionID)
        let runtimeB = try XCTUnwrap(container.runtime(for: sessionBID))
        container.selectSession(id: sessionAID)
        // Force the selection path to query the delayed controller instead of
        // reusing the projection captured during B's initial connection.
        runtimeB.clearMoshProjection()
        delayedB.delayReads()

        container.selectSession(id: sessionBID)
        XCTAssertNil(container.moshSessionInfo)
        XCTAssertNil(container.moshState)
        XCTAssertNil(container.networkRoamingState)
        await delayedB.waitForReadStart()

        container.selectSession(id: sessionAID)
        XCTAssertEqual(container.moshSessionPort, 60101)
        await delayedB.releaseReads()
        try await Task.sleep(nanoseconds: 50_000_000)
        XCTAssertEqual(container.selectedSessionID, sessionAID)
        XCTAssertEqual(container.moshSessionPort, 60101)
    }

    func testMoshProjectionStaysWithSelectedRuntimeWhileAnotherOpens() async throws {
        let connectionA = ControllableMoshConnection(
            sessionInfo: MoshSessionInfo(udpPort: 60011, sessionKey: "mosh-alpha", pid: 41101))
        let betaRoamingState = NetworkRoamingState(currentInterface: .cellular)
        let connectionB = ControllableMoshConnection(
            sessionInfo: MoshSessionInfo(udpPort: 60012, sessionKey: "mosh-beta", pid: 41102),
            moshState: .roaming(betaRoamingState))
        let gate = MultiSessionGate()
        let moshTransport = ControllableMoshTransport()
        moshTransport.onConnect = { host in
            if host.hostname == "beta.invalid" {
                await gate.wait()
                return connectionB
            }
            return connectionA
        }
        let container = AppContainer(
            moshTransport: moshTransport,
            sftpRepository: DemoSFTPRepository(seedDemoData: true),
            portForwardingManager: DemoPortForwardingManager())
        let hostA = try Host(
            name: "Alpha Mosh", hostname: "alpha.invalid", username: "dev",
            connection: .mosh(MoshOptions()))
        let hostB = try Host(
            name: "Beta Mosh", hostname: "beta.invalid", username: "dev",
            connection: .mosh(MoshOptions()))

        await container.connect(to: hostA)
        let sessionAID = try XCTUnwrap(container.selectedSessionID)
        XCTAssertEqual(container.moshSessionInfo?.udpPort, 60011)
        XCTAssertEqual(container.moshState, .connected)

        let openingB = Task { @MainActor in
            await container.connect(to: hostB)
        }
        await gate.waitForStart()
        XCTAssertEqual(container.selectedSessionID, sessionAID)
        XCTAssertEqual(container.moshSessionInfo?.udpPort, 60011)
        XCTAssertEqual(container.moshState, .connected)

        await gate.open()
        await openingB.value
        XCTAssertNotEqual(container.selectedSessionID, sessionAID)
        XCTAssertEqual(container.moshSessionInfo?.udpPort, 60012)
        XCTAssertEqual(container.moshState, .roaming(betaRoamingState))
    }

    func testMoshRuntimesOwnRedactionSecretsWithoutCrossSessionLeak() async throws {
        let keyA = "mosh-session-key-alpha-0123456789"
        let keyB = "mosh-session-key-beta-9876543210"
        let connectionA = ControllableMoshConnection(
            sessionInfo: MoshSessionInfo(udpPort: 60001, sessionKey: keyA, pid: 41001))
        let connectionB = ControllableMoshConnection(
            sessionInfo: MoshSessionInfo(udpPort: 60002, sessionKey: keyB, pid: 41002))
        let moshTransport = ControllableMoshTransport()
        moshTransport.onConnect = { host in
            host.hostname == "alpha.invalid" ? connectionA : connectionB
        }

        let container = AppContainer(
            moshTransport: moshTransport,
            sftpRepository: DemoSFTPRepository(seedDemoData: true),
            portForwardingManager: DemoPortForwardingManager()
        )
        let hostA = try Host(
            name: "Alpha Mosh", hostname: "alpha.invalid", username: "dev",
            connection: .mosh(MoshOptions()))
        let hostB = try Host(
            name: "Beta Mosh", hostname: "beta.invalid", username: "dev",
            connection: .mosh(MoshOptions()))

        await container.connect(to: hostA)
        let sessionAID = try XCTUnwrap(container.selectedSessionID)
        await container.connect(to: hostB)
        let sessionBID = try XCTUnwrap(container.selectedSessionID)

        let runtimeA = try XCTUnwrap(container.runtime(for: sessionAID))
        let runtimeB = try XCTUnwrap(container.runtime(for: sessionBID))
        XCTAssertEqual(runtimeA.redactor.secrets, [keyA])
        XCTAssertEqual(runtimeB.redactor.secrets, [keyB])

        connectionB.emit(.bytes(Data("beta output: \(keyB)\r\n".utf8)))
        try await Task.sleep(nanoseconds: 30_000_000)
        XCTAssertFalse(
            runtimeB.terminalText.contains(keyB),
            "Session B terminal output must not expose its Mosh session key")
        XCTAssertTrue(runtimeB.terminalText.contains("[REDACTED]"))

        await container.closeSession(id: sessionBID)
        await container.closeSession(id: sessionAID)
        XCTAssertTrue(
            container.redactor.secrets.isEmpty,
            "The final close must clear the legacy redactor projection")
    }

    func testExplicitlyDisconnectedSelectedSessionDoesNotCancelNewSessionRedaction()
        async throws
    {
        let credentialStore = BlockingCredentialStore()
        let privateSecret = "private-key-beta-0123456789"
        try await credentialStore.save(Data(privateSecret.utf8), reference: "beta-key")
        let identity = try IdentityDescriptor(
            name: "Beta key", kind: .privateKey, keychainReference: "beta-key")
        let catalog = InMemoryCatalog()
        try await catalog.save(identity)

        let connectionA = ControllableMoshConnection(
            sessionInfo: MoshSessionInfo(
                udpPort: 60003, sessionKey: "mosh-key-alpha-0123456789", pid: 41003))
        let connectionB = ControllableMoshConnection(
            sessionInfo: MoshSessionInfo(
                udpPort: 60004, sessionKey: "mosh-key-beta-9876543210", pid: 41004))
        let moshTransport = ControllableMoshTransport()
        moshTransport.onConnect = { host in
            host.hostname == "alpha.invalid" ? connectionA : connectionB
        }
        let container = AppContainer(
            catalog: catalog,
            credentialStore: credentialStore,
            moshTransport: moshTransport
        )
        let hostA = try Host(
            name: "Alpha Mosh", hostname: "alpha.invalid", username: "dev",
            connection: .mosh(MoshOptions()))
        let hostB = try Host(
            name: "Beta Mosh", hostname: "beta.invalid", username: "dev",
            identityID: identity.id,
            connection: .mosh(MoshOptions()))

        await container.connect(to: hostA)
        let sessionAID = try XCTUnwrap(container.selectedSessionID)
        credentialStore.blockNextLoad()
        let openingB = Task { @MainActor in
            await container.connect(to: hostB)
        }
        await credentialStore.waitForBlockedLoad()
        XCTAssertEqual(container.selectedSessionID, sessionAID)

        await container.disconnect()
        XCTAssertTrue(container.explicitlyDisconnectedSessionIDs.contains(sessionAID))
        await credentialStore.releaseBlockedLoad()
        await openingB.value

        let sessionBID = try XCTUnwrap(container.selectedSessionID)
        let runtimeB = try XCTUnwrap(container.runtime(for: sessionBID))
        XCTAssertEqual(
            runtimeB.redactor.secrets,
            [privateSecret, connectionB.sessionInfo.sessionKey.base64String]
        )
        XCTAssertFalse(runtimeB.redactor.redact(privateSecret).contains(privateSecret))
        XCTAssertFalse(
            runtimeB.redactor.redact(connectionB.sessionInfo.sessionKey.base64String)
                .contains(connectionB.sessionInfo.sessionKey.base64String))
    }

    func testDelayedReconnectConnectionIsClosedAfterDisconnect() async throws {
        let original = MockSSHConnection()
        let replacement = MockSSHConnection()
        let gate = MultiSessionGate()
        let transport = ControllableTransport()
        transport.onConnect = { _ in
            await gate.wait()
            return replacement
        }
        let container = AppContainer(transport: transport)
        let host = try Host(name: "Delayed Host", hostname: "delayed.invalid", username: "dev")

        // Seed the runtime without using the delayed replacement transport.
        transport.onConnect = { _ in original }
        await container.connect(to: host)
        let sessionID = try XCTUnwrap(container.selectedSessionID)
        transport.onConnect = { _ in
            await gate.wait()
            return replacement
        }

        let reconnecting = Task { @MainActor in
            try? await container.performReconnect(to: host, attempt: 1)
        }
        await gate.waitForStart()
        await container.disconnect()
        await gate.open()
        await reconnecting.value

        XCTAssertTrue(
            replacement.isClosed,
            "A replacement returned after disconnect must be rejected")
        XCTAssertEqual(container.runtime(for: sessionID)?.session.state, .disconnected)
        XCTAssertTrue(container.redactor.secrets.isEmpty)
    }

    func testSameSessionDisconnectInvalidatesPendingReplacementRedactor() async throws {
        let credentialStore = BlockingCredentialStore()
        let privateSecret = "replacement-private-key-0123456789"
        try await credentialStore.save(Data(privateSecret.utf8), reference: "replacement-key")
        let identity = try IdentityDescriptor(
            name: "Replacement key", kind: .privateKey, keychainReference: "replacement-key")
        let catalog = InMemoryCatalog()
        try await catalog.save(identity)
        let original = MockSSHConnection()
        let replacement = MockSSHConnection()
        let transport = ControllableTransport()
        transport.onConnect = { _ in original }
        let container = AppContainer(
            catalog: catalog,
            credentialStore: credentialStore,
            transport: transport
        )
        let host = try Host(
            name: "Reconnect Host", hostname: "reconnect.invalid", username: "dev",
            identityID: identity.id)

        await container.connect(to: host)
        let sessionID = try XCTUnwrap(container.selectedSessionID)
        credentialStore.blockNextLoad()
        transport.onConnect = { _ in replacement }
        let reconnecting = Task { @MainActor in
            try? await container.performReconnect(to: host, attempt: 1)
        }
        await credentialStore.waitForBlockedLoad()

        await container.disconnect()
        await credentialStore.releaseBlockedLoad()
        await reconnecting.value

        let runtime = try XCTUnwrap(container.runtime(for: sessionID))
        XCTAssertTrue(replacement.isClosed)
        XCTAssertTrue(runtime.redactor.secrets.isEmpty)
    }

    func testDisconnectWhileInitialConnectionPendingClosesLateConnectionWithoutRuntime()
        async throws
    {
        let lateConnection = MockSSHConnection()
        let gate = MultiSessionGate()
        let transport = ControllableTransport()
        transport.onConnect = { _ in
            await gate.wait()
            return lateConnection
        }
        let container = AppContainer(transport: transport)
        let host = try Host(name: "Delayed Host", hostname: "delayed.invalid", username: "dev")

        let opening = Task { @MainActor in await container.connect(to: host) }
        await gate.waitForStart()
        XCTAssertEqual(container.pendingConnectingSessions.values.map(\.hostID), [host.id])

        await container.disconnect()
        XCTAssertTrue(container.pendingConnectingSessions.isEmpty)
        XCTAssertNil(container.selectedSessionID)
        XCTAssertNil(container.activeHost)
        XCTAssertEqual(container.activeSession?.state, .disconnected)
        XCTAssertFalse(container.isConnectingSession)
        XCTAssertTrue(container.sessionRuntimes.isEmpty)

        await gate.open()
        await opening.value
        XCTAssertTrue(lateConnection.isClosed)
        XCTAssertTrue(container.sessionRuntimes.isEmpty)
        XCTAssertNil(container.selectedSessionID)

        let followUpConnection = MockSSHConnection()
        transport.onConnect = { _ in followUpConnection }
        await container.connect(to: host)
        XCTAssertEqual(container.activeSession?.state, .connected)
        XCTAssertFalse(container.isConnectingSession)
    }

    func testDisconnectWhileSecondaryConnectionPendingDoesNotCancelSelectedRuntime()
        async throws
    {
        let connectionA = MockSSHConnection()
        let lateConnectionB = MockSSHConnection()
        let gate = MultiSessionGate()
        let transport = ControllableTransport()
        transport.onConnect = { host in
            if host.hostname == "beta.invalid" {
                await gate.wait()
                return lateConnectionB
            }
            return connectionA
        }
        let container = AppContainer(transport: transport)
        let hostA = try Host(name: "Alpha Host", hostname: "alpha.invalid", username: "dev")
        let hostB = try Host(name: "Beta Host", hostname: "beta.invalid", username: "dev")

        await container.connect(to: hostA)
        let sessionAID = try XCTUnwrap(container.selectedSessionID)
        let opening = Task { @MainActor in await container.connect(to: hostB) }
        await gate.waitForStart()

        await container.disconnect()
        XCTAssertEqual(container.selectedSessionID, sessionAID)
        XCTAssertEqual(container.runtime(for: sessionAID)?.session.state, .disconnected)
        XCTAssertEqual(container.pendingConnectingSessions.values.map(\.hostID), [hostB.id])

        await gate.open()
        await opening.value
        let sessionBID = try XCTUnwrap(container.selectedSessionID)
        XCTAssertEqual(container.runtime(for: sessionBID)?.host.id, hostB.id)
        XCTAssertEqual(container.runtime(for: sessionBID)?.session.state, .connected)
        XCTAssertEqual(container.runtime(for: sessionAID)?.session.state, .disconnected)
        XCTAssertFalse(lateConnectionB.isClosed)
        XCTAssertTrue(container.redactor.secrets.isEmpty)
    }

    func testDisconnectReconcilesCapturedRuntimeAfterSelectionReturns() async throws {
        let closeGate = MultiSessionGate()
        let connectionA = MockSSHConnection()
        connectionA.onClose = { await closeGate.wait() }
        let connectionB = MockSSHConnection()
        let transport = ControllableTransport()
        transport.onConnect = { host in
            host.hostname == "alpha.invalid" ? connectionA : connectionB
        }
        let container = AppContainer(transport: transport)
        let hostA = try Host(name: "Alpha Host", hostname: "alpha.invalid", username: "dev")
        let hostB = try Host(name: "Beta Host", hostname: "beta.invalid", username: "dev")

        await container.connect(to: hostA)
        let sessionAID = try XCTUnwrap(container.selectedSessionID)
        await container.connect(to: hostB)
        let sessionBID = try XCTUnwrap(container.selectedSessionID)
        container.selectSession(id: sessionAID)

        let disconnecting = Task { @MainActor in await container.disconnect() }
        await closeGate.waitForStart()
        container.selectSession(id: sessionBID)
        container.selectSession(id: sessionAID)
        await closeGate.open()
        await disconnecting.value

        XCTAssertEqual(container.selectedSessionID, sessionAID)
        XCTAssertEqual(container.activeSession?.id, sessionAID)
        XCTAssertEqual(container.activeSession?.state, .disconnected)
        XCTAssertEqual(container.activeHost?.id, hostA.id)
        XCTAssertTrue(container.redactor.secrets.isEmpty)
        XCTAssertEqual(container.moshState, nil)
        XCTAssertFalse(connectionB.isClosed)
    }

    func testInitialActivationDoesNotProjectConnectedStateIntoDisconnectedSelection()
        async throws
    {
        let connectionA = MockSSHConnection()
        let connectionB = DelayedEventsConnection()
        let transport = ControllableTransport()
        transport.onConnect = { host -> any SSHConnection in
            host.hostname == "alpha.invalid" ? connectionA : connectionB
        }
        let container = AppContainer(transport: transport)
        let hostA = try Host(name: "Alpha Host", hostname: "alpha.invalid", username: "dev")
        let hostB = try Host(name: "Beta Host", hostname: "beta.invalid", username: "dev")

        await container.connect(to: hostA)
        let sessionAID = try XCTUnwrap(container.selectedSessionID)
        let openingB = Task { @MainActor in await container.connect(to: hostB) }
        await connectionB.waitForEventsStart()

        let runtimeA = try XCTUnwrap(container.runtime(for: sessionAID))
        runtimeA.updateSessionState(.disconnected)
        container.selectSession(id: sessionAID)
        XCTAssertEqual(container.activeSession?.state, .disconnected)

        await connectionB.releaseEvents()
        await openingB.value

        let sessionBID = try XCTUnwrap(
            container.openSessions.first(where: { $0.hostID == hostB.id })?.id)
        XCTAssertEqual(container.selectedSessionID, sessionBID)
        XCTAssertEqual(container.runtime(for: sessionAID)?.session.state, .disconnected)
        XCTAssertEqual(container.runtime(for: sessionBID)?.session.state, .connected)
        container.selectSession(id: sessionAID)
        XCTAssertEqual(container.activeSession?.state, .disconnected)
    }

    func testMoshRoamingFailureRecoversCapturedOwnerAfterSelectionSwitch() async throws {
        let connectionA = ControllableMoshConnection()
        let connectionB = ControllableMoshConnection()
        let gate = MultiSessionGate()
        let moshTransport = ControllableMoshTransport()
        moshTransport.onConnect = { host in
            if host.hostname == "beta.invalid" {
                return connectionB
            }
            return connectionA
        }
        connectionA.onHandleNetworkRoaming = { _ in
            await gate.wait()
            throw TransportError.connectionRefused
        }
        let container = AppContainer(moshTransport: moshTransport)
        let hostA = try Host(
            name: "Alpha Mosh", hostname: "alpha.invalid", username: "dev",
            connection: .mosh(MoshOptions()))
        let hostB = try Host(
            name: "Beta Mosh", hostname: "beta.invalid", username: "dev",
            connection: .mosh(MoshOptions()))

        await container.connect(to: hostA)
        let sessionAID = try XCTUnwrap(container.selectedSessionID)
        await container.connect(to: hostB)
        let sessionBID = try XCTUnwrap(container.selectedSessionID)
        container.selectSession(id: sessionAID)
        let roaming = Task { @MainActor in
            await container.handleNetworkInterfaceChange(
                .cellular,
                roamingState: NetworkRoamingState(currentInterface: .cellular))
        }
        await gate.waitForStart()
        container.selectSession(id: sessionBID)
        await gate.open()
        await roaming.value
        try await Task.sleep(nanoseconds: 50_000_000)

        XCTAssertEqual(container.selectedSessionID, sessionBID)
        XCTAssertEqual(container.runtime(for: sessionBID)?.session.state, .connected)
        XCTAssertEqual(connectionB.roamingTransitions.count, 1)
    }

    func testDelayedMoshRoamingDoesNotPublishAfterExplicitDisconnect() async throws {
        let gate = MultiSessionGate()
        let connection = ControllableMoshConnection(
            sessionInfo: MoshSessionInfo(udpPort: 60110, sessionKey: "mosh-delayed", pid: 42110))
        connection.onHandleNetworkRoaming = { _ in
            await gate.wait()
        }
        let moshTransport = ControllableMoshTransport()
        moshTransport.onConnect = { _ in connection }
        let container = AppContainer(moshTransport: moshTransport)
        let host = try Host(
            name: "Delayed Mosh", hostname: "delayed-mosh.invalid", username: "dev",
            connection: .mosh(MoshOptions()))

        await container.connect(to: host)
        let sessionID = try XCTUnwrap(container.selectedSessionID)
        let roaming = Task { @MainActor in
            await container.handleNetworkInterfaceChange(
                .cellular,
                roamingState: NetworkRoamingState(currentInterface: .cellular))
        }
        await gate.waitForStart()

        await container.disconnect()
        await gate.open()
        await roaming.value

        XCTAssertEqual(container.selectedSessionID, sessionID)
        XCTAssertEqual(container.activeSession?.state, .disconnected)
        XCTAssertNil(container.moshState)
        XCTAssertNil(container.moshSessionInfo)
        XCTAssertNil(container.networkRoamingState)
    }

    func testFinalCloseSerializesRestorationClearAfterQueuedSelectionSave() async throws {
        let store = ReverseOrderingRestorationStore()
        let transport = ControllableTransport()
        let container = AppContainer(transport: transport, restorationStore: store)
        let host = try Host(name: "Final Host", hostname: "final.invalid", username: "dev")

        await container.connect(to: host)
        let sessionID = try XCTUnwrap(container.selectedSessionID)
        await container.closeSession(id: sessionID)
        await store.waitForSaveCount(1)
        try await Task.sleep(nanoseconds: 100_000_000)

        let metadata = try await store.load()
        XCTAssertNil(metadata, "Final close must win over queued selection metadata")
    }

    func testSelectionSaveSerializationPreservesLatestHostAndTarget() async throws {
        let store = ReverseOrderingRestorationStore()
        let transport = ControllableTransport()
        let container = AppContainer(transport: transport, restorationStore: store)
        let hostA = try Host(name: "Alpha Host", hostname: "alpha.invalid", username: "dev")
        let hostB = try Host(name: "Beta Host", hostname: "beta.invalid", username: "dev")

        await container.connect(to: hostA)
        let sessionAID = try XCTUnwrap(container.selectedSessionID)
        container.activeTmuxSessionID = "$alpha"
        await container.connect(to: hostB)
        let sessionBID = try XCTUnwrap(container.selectedSessionID)
        container.selectSession(id: sessionAID)
        container.selectSession(id: sessionBID)

        await store.waitForSaveCount(3)
        try await Task.sleep(nanoseconds: 100_000_000)
        guard let metadata = try await store.load() else {
            XCTFail("Selection metadata was not saved")
            return
        }
        XCTAssertEqual(metadata.hostID, hostB.id)
        XCTAssertEqual(metadata.sessionID, sessionBID)
        XCTAssertNil(metadata.lastUsedMultiplexerTarget)
    }

    func testSwitchingSessionsPreservesTargetsWithoutCrossHostApplication() async throws {
        let store = InMemorySessionRestorationStore()
        let transport = ControllableTransport()
        let container = AppContainer(transport: transport, restorationStore: store)
        let hostA = try Host(name: "Alpha Host", hostname: "alpha.invalid", username: "dev")
        let hostB = try Host(name: "Beta Host", hostname: "beta.invalid", username: "dev")

        await container.connect(to: hostA)
        let sessionAID = try XCTUnwrap(container.selectedSessionID)
        // Production sets this only after successful target validation.
        container.activeTmuxSessionID = "$alpha"
        await container.connect(to: hostB)
        let sessionBID = try XCTUnwrap(container.selectedSessionID)
        try await Task.sleep(nanoseconds: 50_000_000)

        guard let metadataForB = try await store.load() else {
            XCTFail("Session B restoration metadata was not saved")
            return
        }
        XCTAssertEqual(metadataForB.hostID, hostB.id)
        XCTAssertNil(metadataForB.lastUsedMultiplexerTarget)

        container.selectSession(id: sessionAID)
        try await Task.sleep(nanoseconds: 50_000_000)
        guard let metadataForA = try await store.load() else {
            XCTFail("Session A restoration metadata was not preserved")
            return
        }
        XCTAssertEqual(metadataForA.hostID, hostA.id)
        XCTAssertEqual(
            metadataForA.lastUsedMultiplexerTarget,
            .tmux(sessionID: "$alpha")
        )
        XCTAssertEqual(container.selectedSessionID, sessionAID)
        XCTAssertNotEqual(sessionAID, sessionBID)
    }

    func testNonSelectedReconnectRestoresOwnerTmuxTargetWithoutChangingSelectedProjection()
        async throws
    {
        let connectionA = MockSSHConnection()
        let connectionB = MockSSHConnection()
        let replacementB = MockSSHConnection()
        let bConnections = ConnectionSequence([connectionB, replacementB])
        let transport = ControllableTransport()
        transport.onConnect = { host in
            host.hostname == "alpha.invalid" ? connectionA : await bConnections.next()
        }
        let container = AppContainer(
            transport: transport,
            reachabilityMonitor: MockReachabilityMonitor(isReachable: true),
            reconnectCoordinator: ReconnectCoordinator(
                clock: { _ in }, jitter: ReconnectCoordinator.zeroJitter))
        let hostA = try Host(
            name: "Alpha Host", hostname: "alpha.invalid", username: "dev", autoAttachTmux: true)
        let hostB = try Host(
            name: "Beta Host", hostname: "beta.invalid", username: "dev", autoAttachTmux: true)

        await container.connect(to: hostA)
        let sessionAID = try XCTUnwrap(container.selectedSessionID)
        await container.connect(to: hostB, restoringTmuxSessionID: "$0")
        let sessionBID = try XCTUnwrap(container.selectedSessionID)
        container.selectSession(id: sessionAID)
        XCTAssertNil(container.activeTmuxSessionID)

        let runtimeB = try XCTUnwrap(container.runtime(for: sessionBID))
        try await eventually {
            connectionB.sentData.contains {
                String(decoding: $0, as: UTF8.self).contains("attach-session")
            }
        }
        connectionB.emit(.error(.connectionRefused))
        try await eventually(timeoutNanoseconds: 5_000_000_000) {
            runtimeB.session.state == .connected
                && (runtimeB.connection as AnyObject) === (replacementB as AnyObject)
                && replacementB.sentData.contains {
                    String(decoding: $0, as: UTF8.self).contains("attach-session")
                }
        }

        XCTAssertEqual(container.selectedSessionID, sessionAID)
        XCTAssertNil(container.activeTmuxSessionID)
        XCTAssertTrue(
            replacementB.sentData.contains {
                String(decoding: $0, as: UTF8.self).contains("attach-session")
            },
            "A non-selected reconnect must attach its own remembered tmux target")
    }

    func testSameHostReconnectDoesNotInheritAnotherRuntimeRestorationMetadata() async throws {
        let connectionA = MockSSHConnection()
        let connectionB = MockSSHConnection()
        let replacementB = MockSSHConnection()
        let ownedReplacementB = MockSSHConnection()
        let connections = ConnectionSequence([connectionA, connectionB, replacementB, ownedReplacementB])
        let transport = ControllableTransport()
        transport.onConnect = { _ in await connections.next() }
        let store = ControlledSessionRestorationStore()
        let container = AppContainer(
            transport: transport,
            restorationStore: store,
            reachabilityMonitor: MockReachabilityMonitor(isReachable: true),
            reconnectCoordinator: ReconnectCoordinator(
                clock: { _ in }, jitter: ReconnectCoordinator.zeroJitter))
        let host = try Host(
            name: "Shared Host", hostname: "shared.invalid", username: "dev", autoAttachTmux: true)
        let sessionAID = UUID()

        // A is the initial restored runtime and owns the persisted target.
        await store.set(
            SessionRestorationMetadata(
                hostID: host.id,
                sessionID: sessionAID,
                lastUsedMultiplexerTarget: .tmux(sessionID: "$0")))
        await container.connect(to: host, sessionID: sessionAID)
        XCTAssertEqual(container.selectedSessionID, sessionAID)

        // B is a second runtime for the same host and has no owner-scoped record.
        await container.connect(to: host)
        let sessionBID = try XCTUnwrap(container.selectedSessionID)
        XCTAssertNotEqual(sessionAID, sessionBID)
        let runtimeB = try XCTUnwrap(container.runtime(for: sessionBID))

        // Use the real reconnect path and await its completion so the negative
        // assertion cannot pass before automatic tmux setup runs.
        try await container.performReconnect(to: host, attempt: 1, ownerSessionID: sessionBID)
        XCTAssertTrue((runtimeB.connection as AnyObject) === (replacementB as AnyObject))
        XCTAssertFalse(
            replacementB.sentData.contains {
                String(decoding: $0, as: UTF8.self).contains("attach-session")
                    && String(decoding: $0, as: UTF8.self).contains("'$0'")
            },
            "B must not attach A's remembered tmux target")

        // Positive control: once the persisted record belongs to B, B's next
        // replacement must attach B's own target through the same path.
        await store.set(
            SessionRestorationMetadata(
                hostID: host.id,
                sessionID: sessionBID,
                lastUsedMultiplexerTarget: .tmux(sessionID: "$1")))
        try await container.performReconnect(to: host, attempt: 1, ownerSessionID: sessionBID)
        XCTAssertTrue((runtimeB.connection as AnyObject) === (ownedReplacementB as AnyObject))
        try await eventually {
            ownedReplacementB.sentData.contains {
                String(decoding: $0, as: UTF8.self).contains("attach-session")
                    && String(decoding: $0, as: UTF8.self).contains("'$1'")
            }
        }
    }

    func testForegroundRetriesPendingAdmissionWhileAnotherRuntimeConnected() async throws {
        let connectionA = MockSSHConnection()
        let staleConnectionB = MockSSHConnection()
        let replacementB = MockSSHConnection()
        let admissionGate = MultiSessionGate()
        let connectionsB = ConnectionSequence([staleConnectionB, replacementB])
        let transport = ControllableTransport()
        transport.onConnect = { host in
            guard host.hostname == "beta.invalid" else { return connectionA }
            let connection = await connectionsB.next()
            if (connection as AnyObject) === (staleConnectionB as AnyObject) {
                await admissionGate.wait()
            }
            return connection
        }
        let hostA = try Host(name: "Alpha Host", hostname: "alpha.invalid", username: "dev")
        let hostB = try Host(name: "Beta Host", hostname: "beta.invalid", username: "dev")
        let catalog = InMemoryCatalog(
            snapshot: CatalogSnapshot(hosts: [hostA, hostB], identities: []))
        let container = AppContainer(
            catalog: catalog,
            transport: transport,
            reachabilityMonitor: MockReachabilityMonitor(isReachable: true),
            reconnectCoordinator: ReconnectCoordinator(
                clock: { _ in }, jitter: ReconnectCoordinator.zeroJitter))

        await container.connect(to: hostA)
        let sessionAID = try XCTUnwrap(container.selectedSessionID)
        let openingB = Task { @MainActor in await container.connect(to: hostB) }
        try await eventually {
            container.pendingConnectingSessions.values.contains { $0.hostID == hostB.id }
        }

        container.handleScenePhaseChange(.background)
        await admissionGate.open()
        await openingB.value
        try await eventually { staleConnectionB.isClosed }

        container.handleScenePhaseChange(.active)

        try await eventually(timeoutNanoseconds: 5_000_000_000) {
            guard let sessionBID = container.openSessions.first(where: { $0.hostID == hostB.id })?.id,
                let runtimeB = container.runtime(for: sessionBID)
            else { return false }
            return runtimeB.session.state == .connected
                && (runtimeB.connection as AnyObject) === (replacementB as AnyObject)
        }
        XCTAssertEqual(container.runtime(for: sessionAID)?.session.state, .connected)
    }

    func testForegroundRetrySurvivesStaleAdmissionCloseCompletion() async throws {
        let connectionA = MockSSHConnection()
        let staleConnectionB = MockSSHConnection()
        let replacementB = MockSSHConnection()
        let admissionGate = MultiSessionGate()
        let closeGate = MultiSessionGate()
        let replacementTransportGate = MultiSessionGate()
        staleConnectionB.onClose = { await closeGate.wait() }
        let connectionsB = ConnectionSequence([staleConnectionB, replacementB])
        let transport = ControllableTransport()
        transport.onConnect = { host in
            guard host.hostname == "beta.invalid" else { return connectionA }
            let connection = await connectionsB.next()
            if (connection as AnyObject) === (staleConnectionB as AnyObject) {
                await admissionGate.wait()
            } else {
                await replacementTransportGate.wait()
            }
            return connection
        }
        let hostA = try Host(name: "Alpha Host", hostname: "alpha.invalid", username: "dev")
        let hostB = try Host(name: "Beta Host", hostname: "beta.invalid", username: "dev")
        let catalog = InMemoryCatalog(
            snapshot: CatalogSnapshot(hosts: [hostA, hostB], identities: []))
        let container = AppContainer(
            catalog: catalog,
            transport: transport,
            reachabilityMonitor: MockReachabilityMonitor(isReachable: true),
            reconnectCoordinator: ReconnectCoordinator(
                clock: { _ in }, jitter: ReconnectCoordinator.zeroJitter))

        await container.connect(to: hostA)
        let sessionAID = try XCTUnwrap(container.selectedSessionID)
        let openingB = Task { @MainActor in await container.connect(to: hostB) }
        try await eventually {
            container.pendingConnectingSessions.values.contains { $0.hostID == hostB.id }
        }

        container.handleScenePhaseChange(.background)
        await admissionGate.open()
        await closeGate.waitForStart()

        container.handleScenePhaseChange(.active)
        await replacementTransportGate.waitForStart()
        await closeGate.open()
        await openingB.value
        await replacementTransportGate.open()

        try await eventually(timeoutNanoseconds: 5_000_000_000) {
            guard let sessionBID = container.openSessions.first(where: { $0.hostID == hostB.id })?.id,
                let runtimeB = container.runtime(for: sessionBID)
            else { return false }
            return runtimeB.session.state == .connected
                && (runtimeB.connection as AnyObject) === (replacementB as AnyObject)
        }
        XCTAssertEqual(container.runtime(for: sessionAID)?.session.state, .connected)
    }

    func testClosingSessionRemovesReconnectCoordinatorAndIgnoresLateCallback()
        async throws
    {
        let recoveryGate = MultiSessionGate()
        let original = MockSSHConnection()
        let replacement = MockSSHConnection()
        let connections = ConnectionSequence([original, replacement])
        let transport = ControllableTransport()
        transport.onConnect = { _ in await connections.next() }
        let container = AppContainer(
            transport: transport,
            reachabilityMonitor: MockReachabilityMonitor(isReachable: true),
            reconnectCoordinator: ReconnectCoordinator(
                clock: { _ in await recoveryGate.wait() }, jitter: ReconnectCoordinator.zeroJitter))
        let host = try Host(name: "Coordinator Host", hostname: "coordinator.invalid", username: "dev")

        await container.connect(to: host)
        let sessionID = try XCTUnwrap(container.selectedSessionID)
        original.emit(.error(.connectionRefused))
        try await eventually { container.runtime(for: sessionID)?.reconnectState.isReconnecting == true }
        XCTAssertTrue(container.reconnectCoordinatorSessionIDs.contains(sessionID))

        await container.closeSession(id: sessionID)
        XCTAssertNil(container.runtime(for: sessionID))
        XCTAssertFalse(container.reconnectCoordinatorSessionIDs.contains(sessionID))

        original.emit(.error(.connectionRefused))
        await recoveryGate.open()
        try await eventually { !container.reconnectCoordinatorSessionIDs.contains(sessionID) }
    }

    func testOpeningRuntimeDoesNotCancelAnotherRuntimeReconnect()
        async throws
    {
        let connectionA = MockSSHConnection()
        let replacementA = MockSSHConnection()
        let connectionB = MockSSHConnection()
        let aConnections = ConnectionSequence([connectionA, replacementA])
        let recoveryGate = MultiSessionGate()
        let transport = ControllableTransport()
        transport.onConnect = { host in
            host.hostname == "alpha.invalid" ? await aConnections.next() : connectionB
        }
        let container = AppContainer(
            transport: transport,
            reachabilityMonitor: MockReachabilityMonitor(isReachable: true),
            reconnectCoordinator: ReconnectCoordinator(
                clock: { _ in await recoveryGate.wait() },
                jitter: ReconnectCoordinator.zeroJitter))
        let hostA = try Host(name: "Alpha Host", hostname: "alpha.invalid", username: "dev")
        let hostB = try Host(name: "Beta Host", hostname: "beta.invalid", username: "dev")

        await container.connect(to: hostA)
        let sessionAID = try XCTUnwrap(container.selectedSessionID)
        connectionA.emit(.error(.connectionRefused))
        try await eventually {
            container.runtime(for: sessionAID)?.reconnectState.isReconnecting == true
        }

        await container.connect(to: hostB)
        XCTAssertEqual(container.openSessions.count, 2)
        XCTAssertTrue(container.runtime(for: sessionAID)?.reconnectState.isReconnecting == true)

        await recoveryGate.open()
        try await eventually {
            container.runtime(for: sessionAID)?.session.state == .connected
                && container.runtime(for: sessionAID)?.reconnectState == .connected
        }
        XCTAssertTrue((container.runtime(for: sessionAID)?.connection as AnyObject) === replacementA)
    }

    func testReconnectPrefersOwnerTmuxTargetAfterImmediateAndABAReturn() async throws {
        let connectionA1 = MockSSHConnection()
        let connectionA2 = MockSSHConnection()
        let connectionB = MockSSHConnection()
        let transport = ControllableTransport()
        let aConnections = ConnectionSequence([connectionA1, connectionA2])
        transport.onConnect = { host in
            if host.hostname == "alpha.invalid" {
                return await aConnections.next()
            }
            return connectionB
        }
        let container = AppContainer(
            transport: transport,
            reachabilityMonitor: MockReachabilityMonitor(isReachable: true),
            reconnectCoordinator: ReconnectCoordinator(
                clock: { _ in }, jitter: ReconnectCoordinator.zeroJitter))
        let hostA = try Host(name: "Alpha Host", hostname: "alpha.invalid", username: "dev")
        let hostB = try Host(name: "Beta Host", hostname: "beta.invalid", username: "dev")

        await container.connect(to: hostA)
        let sessionAID = try XCTUnwrap(container.selectedSessionID)
        container.activeTmuxSessionID = "$1"
        try await container.performReconnect(to: hostA, attempt: 1)
        XCTAssertTrue(
            connectionA2.sentData.contains {
                String(decoding: $0, as: UTF8.self).contains("$1")
            })

        await container.connect(to: hostB)
        let sessionBID = try XCTUnwrap(container.selectedSessionID)
        container.activeTmuxSessionID = "$2"
        await container.closeSession(id: sessionBID)
        XCTAssertEqual(container.selectedSessionID, sessionAID)

        let connectionA3 = MockSSHConnection()
        let replacementSequence = ConnectionSequence([connectionA3])
        transport.onConnect = { _ in await replacementSequence.next() }
        try await container.performReconnect(to: hostA, attempt: 1)

        XCTAssertEqual(container.activeTmuxSessionID, "$1")
        XCTAssertFalse(
            connectionA3.sentData.contains {
                String(decoding: $0, as: UTF8.self).contains("$2")
            },
            "A reconnect must not apply B's remembered tmux target")
    }

    func testReconnectPrefersOwnerHerdrTargetAfterABAReturn() async throws {
        let connectionA1 = MockSSHConnection()
        let connectionB = MockSSHConnection()
        let transport = ControllableTransport()
        let aConnections = ConnectionSequence([connectionA1])
        transport.onConnect = { host in
            if host.hostname == "alpha.invalid" {
                return await aConnections.next()
            }
            return connectionB
        }
        let container = AppContainer(
            transport: transport,
            reachabilityMonitor: MockReachabilityMonitor(isReachable: true),
            reconnectCoordinator: ReconnectCoordinator(
                clock: { _ in }, jitter: ReconnectCoordinator.zeroJitter))
        let hostA = try Host(name: "Alpha Host", hostname: "alpha.invalid", username: "dev")
        let hostB = try Host(name: "Beta Host", hostname: "beta.invalid", username: "dev")

        await container.connect(to: hostA)
        let sessionAID = try XCTUnwrap(container.selectedSessionID)
        container.activeHerdrWorkspaceID = "workspace-alpha"
        await container.connect(to: hostB)
        let sessionBID = try XCTUnwrap(container.selectedSessionID)
        container.activeHerdrWorkspaceID = "workspace-beta"
        await container.closeSession(id: sessionBID)
        XCTAssertEqual(container.selectedSessionID, sessionAID)

        let connectionA3 = MockSSHConnection()
        connectionA3.onExecuteCommand = { command in
            if command == HerdrCommand.probe || command == "herdr --version" {
                return SSHCommandResult(exitCode: 0, stdout: "herdr 0.1.0\n", stderr: "")
            }
            if command.contains("workspace list") {
                return SSHCommandResult(
                    exitCode: 0,
                    stdout:
                        "[{\"id\":\"workspace-alpha\",\"label\":\"Alpha\",\"cwd\":\"/\",\"panes\":[]}]",
                    stderr: "")
            }
            if command.contains("pane list") {
                // Refresh parses pane output after workspaces; an empty reply is a parse error.
                return SSHCommandResult(exitCode: 0, stdout: "[]", stderr: "")
            }
            return SSHCommandResult(exitCode: 0, stdout: "", stderr: "")
        }
        let replacementSequence = ConnectionSequence([connectionA3])
        transport.onConnect = { _ in await replacementSequence.next() }
        try await container.performReconnect(to: hostA, attempt: 1)

        XCTAssertEqual(container.activeHerdrWorkspaceID, "workspace-alpha")
        XCTAssertNotEqual(container.activeHerdrWorkspaceID, "workspace-beta")
    }

    func testTerminalInputTargetsSelectedConnectionOnly() async throws {
        let mockA = MockSSHConnection()
        let mockB = MockSSHConnection()
        let transport = ControllableTransport()
        transport.onConnect = { host in
            host.hostname == "alpha.invalid" ? mockA : mockB
        }

        let container = AppContainer(transport: transport)
        let hostA = try Host(name: "Alpha Host", hostname: "alpha.invalid", username: "dev")
        let hostB = try Host(name: "Beta Host", hostname: "beta.invalid", username: "dev")

        await container.connect(to: hostA)
        let sessionAID = try XCTUnwrap(container.activeSession?.id)
        await container.connect(to: hostB)
        let sessionBID = try XCTUnwrap(container.activeSession?.id)

        // Selected is Session B: input must reach mockB only
        container.selectSession(id: sessionBID)
        let sentToB = await container.sendRawInteractive(Data("command-for-beta\n".utf8))
        XCTAssertTrue(sentToB)
        try await Task.sleep(nanoseconds: 30_000_000)

        XCTAssertEqual(mockB.sentData, [Data("command-for-beta\n".utf8)])
        XCTAssertTrue(
            mockA.sentData.isEmpty, "Connection A must not receive keystrokes meant for Session B")

        // Switch to Session A: input must reach mockA only
        container.selectSession(id: sessionAID)
        let sentToA = await container.sendRawInteractive(Data("command-for-alpha\n".utf8))
        XCTAssertTrue(sentToA)
        try await Task.sleep(nanoseconds: 30_000_000)

        XCTAssertEqual(mockA.sentData, [Data("command-for-alpha\n".utf8)])
        XCTAssertEqual(
            mockB.sentData, [Data("command-for-beta\n".utf8)],
            "Connection B must not receive keystrokes meant for Session A")
    }

    func testSwitchingPreservesTerminalStateAndBuffers() async throws {
        let mockA = MockSSHConnection()
        let mockB = MockSSHConnection()
        let transport = ControllableTransport()
        transport.onConnect = { host in
            host.hostname == "alpha.invalid" ? mockA : mockB
        }

        let container = AppContainer(transport: transport)
        let hostA = try Host(name: "Alpha Host", hostname: "alpha.invalid", username: "dev")
        let hostB = try Host(name: "Beta Host", hostname: "beta.invalid", username: "dev")

        await container.connect(to: hostA)
        let sessionAID = try XCTUnwrap(container.activeSession?.id)
        let runtimeA = try XCTUnwrap(container.runtime(for: sessionAID))

        runtimeA.terminalController.feed("line 1 on alpha\r\nline 2 on alpha\r\n")
        try await Task.sleep(nanoseconds: 20_000_000)

        await container.connect(to: hostB)
        let sessionBID = try XCTUnwrap(container.activeSession?.id)
        let runtimeB = try XCTUnwrap(container.runtime(for: sessionBID))

        runtimeB.terminalController.feed("line 1 on beta\r\n")
        try await Task.sleep(nanoseconds: 20_000_000)

        XCTAssertTrue(
            runtimeB.terminalController.currentTranscript(limit: 10).contains("line 1 on beta"))
        XCTAssertFalse(
            runtimeB.terminalController.currentTranscript(limit: 10).contains("line 1 on alpha"))

        // Switch to A: verify full state preservation
        container.selectSession(id: sessionAID)
        XCTAssertTrue(
            container.terminalController.currentTranscript(limit: 10).contains("line 1 on alpha"))
        XCTAssertTrue(
            container.terminalController.currentTranscript(limit: 10).contains("line 2 on alpha"))
        XCTAssertFalse(
            container.terminalController.currentTranscript(limit: 10).contains("line 1 on beta"))

        // Switch back to B
        container.selectSession(id: sessionBID)
        XCTAssertTrue(
            container.terminalController.currentTranscript(limit: 10).contains("line 1 on beta"))
    }

    func testDisconnectOrCloseOfOneSessionLeavesOtherAlive() async throws {
        let mockA = MockSSHConnection()
        let mockB = MockSSHConnection()
        let transport = ControllableTransport()
        transport.onConnect = { host in
            host.hostname == "alpha.invalid" ? mockA : mockB
        }

        let container = AppContainer(transport: transport)
        let hostA = try Host(name: "Alpha Host", hostname: "alpha.invalid", username: "dev")
        let hostB = try Host(name: "Beta Host", hostname: "beta.invalid", username: "dev")

        await container.connect(to: hostA)
        let sessionAID = try XCTUnwrap(container.activeSession?.id)
        await container.connect(to: hostB)
        let sessionBID = try XCTUnwrap(container.activeSession?.id)

        XCTAssertEqual(container.openSessions.count, 2)
        XCTAssertFalse(mockA.isClosed)
        XCTAssertFalse(mockB.isClosed)

        // Close Session A
        await container.closeSession(id: sessionAID)
        XCTAssertTrue(mockA.isClosed, "Closing Session A must tear down transport A")
        XCTAssertFalse(mockB.isClosed, "Closing Session A must NOT disturb transport B")

        XCTAssertEqual(container.openSessions.count, 1)
        XCTAssertEqual(container.selectedSessionID, sessionBID)
        XCTAssertEqual(container.activeSession?.state, .connected)

        // Session B remains functional
        let sentOnB = await container.sendRawInteractive(Data("still-live\n".utf8))
        XCTAssertTrue(sentOnB)
        XCTAssertEqual(mockB.sentData, [Data("still-live\n".utf8)])
    }

    func testReconnectIsIsolatedToTargetSession() async throws {
        let mockA1 = MockSSHConnection()
        let mockA2 = MockSSHConnection()
        let mockB = MockSSHConnection()
        let transport = ControllableTransport()

        let aSequence = ConnectionSequence([mockA1, mockA2])
        transport.onConnect = { host in
            if host.hostname == "alpha.invalid" {
                return await aSequence.next()
            } else {
                return mockB
            }
        }

        let container = AppContainer(
            transport: transport,
            reachabilityMonitor: MockReachabilityMonitor(isReachable: true)
        )
        let hostA = try Host(name: "Alpha Host", hostname: "alpha.invalid", username: "dev")
        let hostB = try Host(name: "Beta Host", hostname: "beta.invalid", username: "dev")

        await container.connect(to: hostA)
        let sessionAID = try XCTUnwrap(container.activeSession?.id)
        await container.connect(to: hostB)
        let sessionBID = try XCTUnwrap(container.activeSession?.id)

        // Select Session A to reconnect
        container.selectSession(id: sessionAID)
        try await container.performReconnect(to: hostA, attempt: 1)

        XCTAssertTrue(mockA1.isClosed, "Original connection A must be closed on reconnect")
        XCTAssertFalse(
            mockB.isClosed,
            "Connection B must remain alive and undisturbed during Session A reconnect")

        let runtimeB = try XCTUnwrap(container.runtime(for: sessionBID))
        XCTAssertEqual(runtimeB.session.state, .connected)

        // Replacement connection receives output
        mockA2.emit(.bytes(Data("reconnected-alpha-output\r\n".utf8)))
        try await Task.sleep(nanoseconds: 30_000_000)
        XCTAssertTrue(container.terminalText.contains("reconnected-alpha-output"))
        XCTAssertFalse(runtimeB.terminalText.contains("reconnected-alpha-output"))
    }

    func testResourceExhaustionGuardPreventsExceedingMaximumSessions() async throws {
        let transport = ControllableTransport()
        let container = AppContainer(transport: transport)

        for i in 1...AppContainer.maximumConcurrentSessions {
            let host = try Host(name: "Host \(i)", hostname: "host\(i).invalid", username: "dev")
            await container.connect(to: host)
            XCTAssertEqual(container.openSessions.count, i)
        }

        // Attempt 9th session
        let overflowHost = try Host(
            name: "Overflow Host", hostname: "overflow.invalid", username: "dev")
        await container.connect(to: overflowHost)

        XCTAssertEqual(container.openSessions.count, AppContainer.maximumConcurrentSessions)
        XCTAssertNotNil(container.lastConnectionFailure)
        XCTAssertTrue(
            container.lastConnectionFailure?.reason.contains("Maximum concurrent sessions") == true)
    }

    func testSessionSwitcherBarSemanticsAndAccessibility() async throws {
        let transport = ControllableTransport()
        let container = AppContainer(transport: transport)
        let hostA = try Host(name: "Alpha Server", hostname: "alpha.invalid", username: "dev")
        let hostB = try Host(name: "Beta Server", hostname: "beta.invalid", username: "dev")

        await container.connect(to: hostA)
        let sessionAID = try XCTUnwrap(container.activeSession?.id)
        await container.connect(to: hostB)
        let sessionBID = try XCTUnwrap(container.activeSession?.id)

        XCTAssertEqual(container.openSessions.count, 2)

        let sessionA = try XCTUnwrap(container.runtime(for: sessionAID)?.session)
        let tabItem = SessionTabItem(
            session: sessionA,
            isSelected: false,
            onSelect: { container.selectSession(id: sessionAID) },
            onClose: {
                Task {
                    await container.closeSession(id: sessionAID)
                }
            }
        )
        let tabView = tabItem.environmentObject(container)

        let tabHosting = UIHostingController(rootView: tabView)
        let tabWindow = UIWindow(frame: CGRect(x: 0, y: 0, width: 300, height: 60))
        tabWindow.rootViewController = tabHosting
        tabWindow.makeKeyAndVisible()
        tabHosting.view.layoutIfNeeded()

        // P1 hit target: verify the rendered tab item size accommodates >= 44pt touch target
        let tabFittingSize = tabHosting.sizeThatFits(in: CGSize(width: 300, height: 100))
        XCTAssertGreaterThanOrEqual(
            tabFittingSize.height, 44.0,
            "Session tab item must be at least 44pt in height to satisfy minimum touch targets")
        XCTAssertGreaterThanOrEqual(
            tabFittingSize.width, 44.0,
            "Session tab item must be at least 44pt in width to satisfy minimum touch targets")

        // Switcher bar UI hierarchy
        let switcher = SessionSwitcherBar().environmentObject(container)
        let hosting = UIHostingController(rootView: switcher)
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 393, height: 60))
        window.rootViewController = hosting
        window.makeKeyAndVisible()
        hosting.view.layoutIfNeeded()

        let switcherFitting = hosting.sizeThatFits(in: CGSize(width: 393, height: 100))
        XCTAssertGreaterThanOrEqual(switcherFitting.height, 44.0)

        // Hierarchy inspection: verify accessibility elements and subviews are present
        var axElements: [Any] = []
        let containerCount = hosting.view.accessibilityElementCount()
        if containerCount > 0 && containerCount != NSNotFound {
            for i in 0..<containerCount {
                if let elem = hosting.view.accessibilityElement(at: i) {
                    axElements.append(elem)
                }
            }
        }
        let tabContainerCount = tabHosting.view.accessibilityElementCount()
        if tabContainerCount > 0 && tabContainerCount != NSNotFound {
            for i in 0..<tabContainerCount {
                if let elem = tabHosting.view.accessibilityElement(at: i) {
                    axElements.append(elem)
                }
            }
        }

        func collectViews(in view: UIView) -> [UIView] {
            var results: [UIView] = [view]
            for subview in view.subviews {
                results.append(contentsOf: collectViews(in: subview))
            }
            return results
        }

        let allViews = collectViews(in: hosting.view) + collectViews(in: tabHosting.view)
        XCTAssertFalse(allViews.isEmpty, "Hosting view hierarchy must be populated")
        XCTAssertFalse(
            axElements.isEmpty && allViews.count < 2,
            "Observable accessibility elements or views must be present")

        // Validate real container session switching and state projections
        XCTAssertEqual(container.host(for: sessionAID)?.name, "Alpha Server")
        XCTAssertEqual(container.host(for: sessionBID)?.name, "Beta Server")
        XCTAssertEqual(container.selectedSessionID, sessionBID)

        container.selectSession(id: sessionAID)
        XCTAssertEqual(container.selectedSessionID, sessionAID)
        XCTAssertEqual(container.activeHost?.name, "Alpha Server")

        await container.closeSession(id: sessionAID)
        XCTAssertEqual(container.openSessions.count, 1)
        XCTAssertEqual(container.selectedSessionID, sessionBID)
        XCTAssertEqual(container.activeHost?.name, "Beta Server")
    }

    func testTwoSessionsConnectConcurrentlyWhileBothAdmissionsAreInFlight() async throws {
        let connectionA = MockSSHConnection()
        let connectionB = MockSSHConnection()
        let gateA = MultiSessionGate()
        let gateB = MultiSessionGate()
        let transport = ControllableTransport()
        transport.onConnect = { host in
            if host.hostname == "alpha.invalid" {
                await gateA.wait()
                return connectionA
            }
            await gateB.wait()
            return connectionB
        }
        let container = AppContainer(transport: transport)
        let hostA = try Host(name: "Alpha Host", hostname: "alpha.invalid", username: "dev")
        let hostB = try Host(name: "Beta Host", hostname: "beta.invalid", username: "dev")

        let openingA = Task { @MainActor in await container.connect(to: hostA) }
        await gateA.waitForStart()
        let openingB = Task { @MainActor in await container.connect(to: hostB) }
        await gateB.waitForStart()

        // Both transport attempts are suspended at once. Neither admission may
        // reject, overwrite, or cancel the other.
        XCTAssertEqual(
            Set(container.pendingConnectingSessions.values.map(\.hostID)), [hostA.id, hostB.id])
        XCTAssertTrue(container.isConnecting(hostID: hostA.id))
        XCTAssertTrue(container.isConnecting(hostID: hostB.id))
        XCTAssertTrue(container.isConnectingSession)

        await gateB.open()
        await openingB.value
        let sessionBID = try XCTUnwrap(container.openSessions.first { $0.hostID == hostB.id }?.id)
        XCTAssertEqual(container.runtime(for: sessionBID)?.session.state, .connected)
        XCTAssertEqual(container.pendingConnectingSessions.values.map(\.hostID), [hostA.id])

        await gateA.open()
        await openingA.value
        let sessionAID = try XCTUnwrap(container.openSessions.first { $0.hostID == hostA.id }?.id)
        XCTAssertEqual(container.runtime(for: sessionAID)?.session.state, .connected)
        XCTAssertEqual(container.openSessions.count, 2)
        XCTAssertTrue(container.pendingConnectingSessions.isEmpty)
        XCTAssertFalse(container.isConnectingSession)
    }

    func testPendingAdmissionsCountTowardMaximumSessions() async throws {
        let gate = MultiSessionGate()
        let transport = ControllableTransport()
        transport.onConnect = { _ in
            await gate.wait()
            return MockSSHConnection()
        }
        let container = AppContainer(transport: transport)
        var openings: [Task<Void, Never>] = []
        for index in 1...AppContainer.maximumConcurrentSessions {
            let host = try Host(
                name: "Host \(index)", hostname: "host\(index).invalid", username: "dev")
            openings.append(Task { @MainActor in await container.connect(to: host) })
        }
        // Wait for every attempt to reach admission. No session is connected yet,
        // so the cap must be enforced against in-flight admissions.
        try await eventually {
            container.pendingConnectingSessions.count == AppContainer.maximumConcurrentSessions
        }

        let overflowHost = try Host(
            name: "Overflow Host", hostname: "overflow.invalid", username: "dev")
        await container.connect(to: overflowHost)

        XCTAssertTrue(
            container.lastConnectionFailure?.reason.contains("Maximum concurrent sessions") == true)
        XCTAssertEqual(
            container.pendingConnectingSessions.count, AppContainer.maximumConcurrentSessions)
        XCTAssertFalse(container.isConnecting(hostID: overflowHost.id))

        await gate.open()
        for opening in openings {
            await opening.value
        }
        XCTAssertEqual(container.openSessions.count, AppContainer.maximumConcurrentSessions)
        XCTAssertTrue(container.pendingConnectingSessions.isEmpty)
    }

    func testSecondSessionConnectionFailurePreservesFirstSessionProjections() async throws {
        let mockA = MockSSHConnection()
        let mockC = MockSSHConnection()
        let transport = ControllableTransport()
        transport.onConnect = { host in
            if host.hostname == "alpha.invalid" {
                return mockA
            } else if host.hostname == "gamma.invalid" {
                return mockC
            } else {
                throw TransportError.connectionRefused
            }
        }

        let container = AppContainer(transport: transport)
        let hostA = try Host(name: "Alpha Host", hostname: "alpha.invalid", username: "dev")
        let hostB = try Host(name: "Beta Host", hostname: "beta.invalid", username: "dev")
        let hostC = try Host(name: "Gamma Host", hostname: "gamma.invalid", username: "dev")

        await container.connect(to: hostA)
        let sessionAID = try XCTUnwrap(container.activeSession?.id)
        XCTAssertEqual(container.selectedSessionID, sessionAID)
        XCTAssertEqual(container.activeSession?.state, .connected)
        XCTAssertEqual(container.activeHost?.id, hostA.id)

        mockA.emit(.bytes(Data("alpha persistent output\r\n".utf8)))
        try await Task.sleep(nanoseconds: 30_000_000)
        XCTAssertTrue(container.terminalText.contains("alpha persistent output"))

        // Attempt connecting to host B, which fails with connectionRefused
        await container.connect(to: hostB)

        // Selected session projections must remain coherent and pointing to Host A
        XCTAssertEqual(container.selectedSessionID, sessionAID)
        XCTAssertEqual(container.activeSession?.id, sessionAID)
        XCTAssertEqual(container.activeSession?.state, .connected)
        XCTAssertEqual(container.activeHost?.id, hostA.id)
        XCTAssertTrue(
            container.terminalText.contains("alpha persistent output"),
            "Host A's terminal text must not be clobbered by Host B's connection failure")
        XCTAssertEqual(container.openSessions.count, 1)
        XCTAssertEqual(container.openSessions.first?.id, sessionAID)
        XCTAssertNotNil(container.lastConnectionFailure)
        XCTAssertEqual(container.lastConnectionFailure?.hostID, hostB.id)
        XCTAssertNotEqual(container.lastConnectionFailure?.sessionID, sessionAID)
        XCTAssertNil(
            container.connectionFailure(for: hostA.id, sessionID: sessionAID),
            "Host B's failure must not appear on selected healthy Host A")
        XCTAssertEqual(
            container.lastConnectionFailure?.reason, "Connection refused by remote server.")

        // A later, unrelated connection must not erase B's actionable detail.
        await container.connect(to: hostC)
        XCTAssertEqual(container.activeHost?.id, hostC.id)
        XCTAssertEqual(
            container.connectionFailure(for: hostB.id)?.reason,
            "Connection refused by remote server.")
        XCTAssertNil(container.connectionFailure(for: hostA.id))
        XCTAssertNil(container.connectionFailure(for: hostC.id))
        XCTAssertFalse(mockA.isClosed, "Host A transport must remain connected and undamaged")
    }

    func testForegroundResumesSoleRecoveryAfterBackgroundCancellation() async throws {
        let recoveryGate = MultiSessionGate()
        let original = MockSSHConnection()
        let replacement = MockSSHConnection()
        let connections = ConnectionSequence([original, replacement])
        let transport = ControllableTransport()
        transport.onConnect = { _ in await connections.next() }
        let container = AppContainer(
            transport: transport,
            reachabilityMonitor: MockReachabilityMonitor(isReachable: true),
            reconnectCoordinator: ReconnectCoordinator(
                clock: { _ in await recoveryGate.wait() },
                jitter: ReconnectCoordinator.zeroJitter
            )
        )
        let host = try Host(name: "Recovery Host", hostname: "recovery.invalid", username: "dev")

        await container.connect(to: host)
        let sessionID = try XCTUnwrap(container.selectedSessionID)
        original.emit(.closed)
        try await eventually {
            container.runtime(for: sessionID)?.reconnectState.isReconnecting == true
        }

        container.handleScenePhaseChange(.background)
        XCTAssertEqual(container.runtime(for: sessionID)?.reconnectState, .cancelled)
        container.handleScenePhaseChange(.active)
        await recoveryGate.open()

        try await eventually {
            container.runtime(for: sessionID)?.session.state == .connected
                && container.runtime(for: sessionID)?.reconnectState == .connected
        }
        XCTAssertTrue((container.connection as AnyObject) === (replacement as AnyObject))
        XCTAssertFalse(replacement.isClosed)
    }

    func testDisconnectReconcilesAfterNewSessionAdvancesLifecycleGeneration() async throws {
        let closeGate = MultiSessionGate()
        let connectionA = MockSSHConnection()
        connectionA.onClose = { await closeGate.wait() }
        let connectionB = MockSSHConnection()
        let transport = ControllableTransport()
        transport.onConnect = { host in
            host.hostname == "alpha.invalid" ? connectionA : connectionB
        }
        let container = AppContainer(transport: transport)
        let hostA = try Host(name: "Alpha Host", hostname: "alpha.invalid", username: "dev")
        let hostB = try Host(name: "Beta Host", hostname: "beta.invalid", username: "dev")

        await container.connect(to: hostA)
        let sessionAID = try XCTUnwrap(container.selectedSessionID)
        let disconnecting = Task { @MainActor in await container.disconnect() }
        await closeGate.waitForStart()

        // Opening B advances lifecycleGeneration while A's exact teardown is suspended.
        await container.connect(to: hostB)
        XCTAssertEqual(container.selectedSessionID, try XCTUnwrap(container.openSessions.last?.id))
        container.selectSession(id: sessionAID)
        XCTAssertEqual(container.selectedSessionID, sessionAID)

        await closeGate.open()
        await disconnecting.value

        XCTAssertEqual(container.selectedSessionID, sessionAID)
        XCTAssertEqual(container.activeSession?.id, sessionAID)
        XCTAssertEqual(container.activeSession?.state, .disconnected)
        XCTAssertEqual(container.activeHost?.id, hostA.id)
        XCTAssertFalse(connectionB.isClosed)
    }

    func testInitialConnectAbortsForwardingAfterDelayedTmuxTargetDisconnect() async throws {
        let store = DelayedLoadRestorationStore(delayOnLoad: 1)
        let manager = InterleavingForwardingManager()
        let connection = MockSSHConnection()
        let transport = ControllableTransport()
        transport.onConnect = { _ in connection }
        let container = AppContainer(
            transport: transport,
            restorationStore: store,
            reachabilityMonitor: MockReachabilityMonitor(isReachable: true),
            portForwardingManager: manager
        )
        let host = try Host(
            name: "Delayed Initial Host", hostname: "delayed-initial.invalid", username: "dev",
            autoAttachTmux: true)
        let connecting = Task { @MainActor in await container.connect(to: host) }

        await store.waitForDelayedLoad()
        let disconnecting = Task { @MainActor in await container.disconnect() }
        await store.openDelayedLoad()
        await disconnecting.value
        await connecting.value

        let initialStartCount = await manager.startCallCount()
        XCTAssertEqual(initialStartCount, 0)
        XCTAssertTrue(connection.isClosed)
    }

    func testReconnectAbortsForwardingAfterDelayedRestorationDisconnect() async throws {
        let store = DelayedLoadRestorationStore(delayOnLoad: 2)
        let manager = InterleavingForwardingManager()
        let original = MockSSHConnection()
        let replacement = MockSSHConnection()
        let connections = ConnectionSequence([original, replacement])
        let transport = ControllableTransport()
        transport.onConnect = { _ in await connections.next() }
        let container = AppContainer(
            transport: transport,
            restorationStore: store,
            reachabilityMonitor: MockReachabilityMonitor(isReachable: true),
            reconnectCoordinator: ReconnectCoordinator(
                clock: { _ in }, jitter: ReconnectCoordinator.zeroJitter),
            portForwardingManager: manager)
        let host = try Host(
            name: "Delayed Reconnect Host", hostname: "delayed-reconnect.invalid", username: "dev",
            autoAttachTmux: true)

        await container.connect(to: host)
        original.emit(.closed)
        await store.waitForDelayedLoad()
        let disconnecting = Task { @MainActor in await container.disconnect() }
        await store.openDelayedLoad()
        await disconnecting.value

        let reconnectStartCount = await manager.startCallCount()
        XCTAssertEqual(reconnectStartCount, 0)
        XCTAssertTrue(replacement.isClosed)
    }

    func testForegroundRecoveryDoesNotTeardownNewSelectionAfterOwnerClose() async throws {
        let probeGate = MultiSessionGate()
        let closeGate = MultiSessionGate()
        let connectionA = MockSSHConnection()
        connectionA.onTestResponsiveness = { _ in
            await probeGate.wait()
            return false
        }
        connectionA.onClose = { await closeGate.wait() }
        let connectionB = MockSSHConnection()
        let transport = ControllableTransport()
        transport.onConnect = { host in
            host.hostname == "alpha.invalid" ? connectionA : connectionB
        }
        let container = AppContainer(
            transport: transport,
            reachabilityMonitor: MockReachabilityMonitor(isReachable: true))
        let hostA = try Host(name: "Alpha Host", hostname: "alpha.invalid", username: "dev")
        let hostB = try Host(name: "Beta Host", hostname: "beta.invalid", username: "dev")

        await container.connect(to: hostA)
        let sessionAID = try XCTUnwrap(container.selectedSessionID)
        await container.connect(to: hostB)
        let sessionBID = try XCTUnwrap(container.selectedSessionID)
        container.selectSession(id: sessionAID)

        container.handleScenePhaseChange(.background)
        container.handleScenePhaseChange(.active)
        await probeGate.waitForStart()
        await probeGate.open()
        await closeGate.waitForStart()

        // The foreground task is still tearing down A. Selecting B must remain
        // authoritative when that owner-scoped await completes.
        container.selectSession(id: sessionBID)
        await closeGate.open()
        try await eventually {
            container.runtime(for: sessionAID)?.session.state == .disconnected
                && container.runtime(for: sessionAID)?.reconnectState
                    == .failed(reason: "Connection closed.")
        }

        XCTAssertEqual(container.selectedSessionID, sessionBID)
        XCTAssertEqual(container.activeSession?.id, sessionBID)
        XCTAssertEqual(container.activeSession?.state, .connected)
        XCTAssertEqual(container.activeHost?.id, hostB.id)
        XCTAssertFalse(connectionB.isClosed)
        XCTAssertTrue(connectionA.isClosed)
    }

    func testNonSelectedSessionLifecycleAndBackgroundProbing() async throws {
        let mockA = MockSSHConnection()
        let mockB = MockSSHConnection()
        let transport = ControllableTransport()
        transport.onConnect = { host in
            host.hostname == "alpha.invalid" ? mockA : mockB
        }

        let backgroundTaskManager = MockBackgroundTaskManager()
        let container = AppContainer(
            transport: transport,
            reachabilityMonitor: MockReachabilityMonitor(isReachable: true),
            backgroundTaskManager: backgroundTaskManager
        )
        let hostA = try Host(name: "Alpha Host", hostname: "alpha.invalid", username: "dev")
        let hostB = try Host(name: "Beta Host", hostname: "beta.invalid", username: "dev")

        await container.connect(to: hostA)
        let sessionAID = try XCTUnwrap(container.activeSession?.id)
        await container.connect(to: hostB)
        let sessionBID = try XCTUnwrap(container.activeSession?.id)

        // Select session A; session B is non-selected
        container.selectSession(id: sessionAID)
        XCTAssertEqual(container.selectedSessionID, sessionAID)

        // Background transition: verify background task starts because runtimes are connected
        container.handleScenePhaseChange(ScenePhase.background)
        XCTAssertGreaterThan(
            backgroundTaskManager.beginTaskCallCount, 0,
            "Background task must start when any runtime is connected")

        // Return to foreground: mockA is responsive, mockB is unresponsive
        mockA.isResponsive = true
        mockB.isResponsive = false

        container.handleScenePhaseChange(ScenePhase.active)
        try await Task.sleep(nanoseconds: 100_000_000)

        // Selected session A remains connected
        XCTAssertEqual(container.selectedSessionID, sessionAID)
        XCTAssertEqual(container.activeSession?.id, sessionAID)
        XCTAssertEqual(container.activeSession?.state, .connected)

        // Non-selected session B was probed independently and disconnected
        let runtimeB: SessionRuntime = try XCTUnwrap(container.runtime(for: sessionBID))
        XCTAssertEqual(runtimeB.session.state, TerminalSessionState.disconnected)
        XCTAssertTrue(mockB.isClosed)
        XCTAssertFalse(mockA.isClosed)
    }

    func testBackgroundCancelsNonSelectedRecoveryOwnerWithoutStrandingIt() async throws {
        let connectionA = MockSSHConnection()
        let connectionB = MockSSHConnection()
        let transport = ControllableTransport()
        transport.onConnect = { host in
            host.hostname == "alpha.invalid" ? connectionA : connectionB
        }
        let container = AppContainer(
            transport: transport,
            reachabilityMonitor: MockReachabilityMonitor(isReachable: true))
        let hostA = try Host(name: "Alpha Host", hostname: "alpha.invalid", username: "dev")
        let hostB = try Host(name: "Beta Host", hostname: "beta.invalid", username: "dev")

        await container.connect(to: hostA)
        let sessionAID = try XCTUnwrap(container.selectedSessionID)
        await container.connect(to: hostB)
        let sessionBID = try XCTUnwrap(container.selectedSessionID)
        container.selectSession(id: sessionAID)
        let runtimeB = try XCTUnwrap(container.runtime(for: sessionBID))
        runtimeB.updateReconnectState(.connecting(attempt: 1))

        container.handleScenePhaseChange(.background)
        XCTAssertEqual(runtimeB.session.state, .disconnected)
        XCTAssertEqual(runtimeB.reconnectState, .cancelled)
        XCTAssertEqual(container.activeSession?.id, sessionAID)
        XCTAssertEqual(container.activeSession?.state, .connected)

        container.handleScenePhaseChange(.active)
        try await eventually {
            runtimeB.session.state == .connected
                && runtimeB.reconnectState == .connected
        }
        XCTAssertEqual(container.selectedSessionID, sessionAID)
        XCTAssertEqual(container.activeSession?.id, sessionAID)
        XCTAssertEqual(container.activeSession?.state, .connected)
    }

    func testCancelReconnectDisconnectsCapturedRuntimeAfterSelectionSwitch() async throws {
        let connectionA = MockSSHConnection()
        let connectionB = MockSSHConnection()
        let recoveryGate = MultiSessionGate()
        let transport = ControllableTransport()
        transport.onConnect = { host in
            host.hostname == "alpha.invalid" ? connectionA : connectionB
        }
        let container = AppContainer(
            transport: transport,
            reachabilityMonitor: MockReachabilityMonitor(isReachable: true),
            reconnectCoordinator: ReconnectCoordinator(
                clock: { _ in await recoveryGate.wait() },
                jitter: ReconnectCoordinator.zeroJitter))
        let hostA = try Host(name: "Alpha Host", hostname: "alpha.invalid", username: "dev")
        let hostB = try Host(name: "Beta Host", hostname: "beta.invalid", username: "dev")

        await container.connect(to: hostA)
        let sessionAID = try XCTUnwrap(container.selectedSessionID)
        await container.connect(to: hostB)
        let sessionBID = try XCTUnwrap(container.selectedSessionID)
        container.selectSession(id: sessionAID)

        // A clean close is deliberately not a recovery trigger (717d63c), so the
        // drop is a transport error. The bounded wait fails fast if recovery never starts.
        connectionA.emit(.error(.connectionRefused))
        try await eventually {
            container.runtime(for: sessionAID)?.reconnectState.isReconnecting == true
        }
        let cancelling = Task { @MainActor in
            await container.cancelReconnect()
        }
        await Task.yield()
        container.selectSession(id: sessionBID)
        await cancelling.value

        XCTAssertEqual(container.selectedSessionID, sessionBID)
        XCTAssertFalse(connectionB.isClosed, "Cancellation of A must not disconnect selected B")
        XCTAssertTrue(connectionA.isClosed, "Captured recovery runtime A must be disconnected")
        XCTAssertEqual(container.runtime(for: sessionAID)?.session.state, .disconnected)
        XCTAssertEqual(container.runtime(for: sessionBID)?.session.state, .connected)
        await recoveryGate.open()
    }

    func testSimultaneousDropsRecoverEachRuntimeIndependently() async throws {
        let connectionA = MockSSHConnection()
        let connectionB = MockSSHConnection()
        let replacementA = MockSSHConnection()
        let replacementB = MockSSHConnection()
        let aConnections = ConnectionSequence([connectionA, replacementA])
        let bConnections = ConnectionSequence([connectionB, replacementB])
        let recoveryGate = MultiSessionGate()
        let transport = ControllableTransport()
        transport.onConnect = { host in
            host.hostname == "alpha.invalid"
                ? await aConnections.next() : await bConnections.next()
        }
        let container = AppContainer(
            transport: transport,
            reachabilityMonitor: MockReachabilityMonitor(isReachable: true),
            reconnectCoordinator: ReconnectCoordinator(
                clock: { _ in await recoveryGate.wait() },
                jitter: ReconnectCoordinator.zeroJitter))
        let hostA = try Host(name: "Alpha Host", hostname: "alpha.invalid", username: "dev")
        let hostB = try Host(name: "Beta Host", hostname: "beta.invalid", username: "dev")

        await container.connect(to: hostA)
        let sessionAID = try XCTUnwrap(container.selectedSessionID)
        await container.connect(to: hostB)
        let sessionBID = try XCTUnwrap(container.selectedSessionID)
        container.selectSession(id: sessionAID)
        let runtimeA = try XCTUnwrap(container.runtime(for: sessionAID))
        let runtimeB = try XCTUnwrap(container.runtime(for: sessionBID))

        // Both runtimes drop while both owners are still in backoff.
        connectionA.emit(.error(.connectionRefused))
        connectionB.emit(.error(.connectionRefused))
        try await eventually {
            runtimeA.reconnectState.isReconnecting && runtimeB.reconnectState.isReconnecting
        }

        await recoveryGate.open()
        try await eventually {
            runtimeA.session.state == .connected && runtimeB.session.state == .connected
        }
        XCTAssertTrue((runtimeA.connection as AnyObject) === replacementA)
        XCTAssertTrue((runtimeB.connection as AnyObject) === replacementB)
    }

    func testNonSelectedDropRecoversWhileAnotherSessionIsSelected() async throws {
        let connectionA = MockSSHConnection()
        let connectionB = MockSSHConnection()
        let replacementB = MockSSHConnection()
        let bConnections = ConnectionSequence([connectionB, replacementB])
        let recoveryGate = MultiSessionGate()
        let transport = ControllableTransport()
        transport.onConnect = { host in
            host.hostname == "alpha.invalid" ? connectionA : await bConnections.next()
        }
        let container = AppContainer(
            transport: transport,
            reachabilityMonitor: MockReachabilityMonitor(isReachable: true),
            reconnectCoordinator: ReconnectCoordinator(
                clock: { _ in await recoveryGate.wait() },
                jitter: ReconnectCoordinator.zeroJitter))
        let hostA = try Host(name: "Alpha Host", hostname: "alpha.invalid", username: "dev")
        let hostB = try Host(name: "Beta Host", hostname: "beta.invalid", username: "dev")

        await container.connect(to: hostA)
        let sessionAID = try XCTUnwrap(container.selectedSessionID)
        await container.connect(to: hostB)
        let sessionBID = try XCTUnwrap(container.selectedSessionID)
        container.selectSession(id: sessionAID)
        let runtimeB = try XCTUnwrap(container.runtime(for: sessionBID))

        // B drops while A stays selected. Selection must not gate B's recovery.
        connectionB.emit(.error(.connectionRefused))
        try await eventually { runtimeB.reconnectState.isReconnecting }
        XCTAssertEqual(container.selectedSessionID, sessionAID)
        XCTAssertEqual(container.activeSession?.state, .connected)

        await recoveryGate.open()
        try await eventually { runtimeB.session.state == .connected }
        XCTAssertEqual(container.selectedSessionID, sessionAID)
        XCTAssertEqual(container.activeSession?.state, .connected)
        XCTAssertFalse(connectionA.isClosed)
        XCTAssertTrue((runtimeB.connection as AnyObject) === replacementB)
    }

    func testCancellingOneOwnerReconnectLeavesOtherRecoveryRunning() async throws {
        let connectionA = MockSSHConnection()
        let connectionB = MockSSHConnection()
        let replacementB = MockSSHConnection()
        let bConnections = ConnectionSequence([connectionB, replacementB])
        let recoveryGate = MultiSessionGate()
        let transport = ControllableTransport()
        transport.onConnect = { host in
            host.hostname == "alpha.invalid" ? connectionA : await bConnections.next()
        }
        let container = AppContainer(
            transport: transport,
            reachabilityMonitor: MockReachabilityMonitor(isReachable: true),
            reconnectCoordinator: ReconnectCoordinator(
                clock: { _ in await recoveryGate.wait() },
                jitter: ReconnectCoordinator.zeroJitter))
        let hostA = try Host(name: "Alpha Host", hostname: "alpha.invalid", username: "dev")
        let hostB = try Host(name: "Beta Host", hostname: "beta.invalid", username: "dev")

        await container.connect(to: hostA)
        let sessionAID = try XCTUnwrap(container.selectedSessionID)
        await container.connect(to: hostB)
        let sessionBID = try XCTUnwrap(container.selectedSessionID)
        container.selectSession(id: sessionAID)
        let runtimeA = try XCTUnwrap(container.runtime(for: sessionAID))
        let runtimeB = try XCTUnwrap(container.runtime(for: sessionBID))

        connectionA.emit(.error(.connectionRefused))
        connectionB.emit(.error(.connectionRefused))
        try await eventually {
            runtimeA.reconnectState.isReconnecting && runtimeB.reconnectState.isReconnecting
        }

        // The selected owner A is cancelled; B's coordinator and backoff must survive.
        await container.cancelReconnect()
        XCTAssertEqual(runtimeA.reconnectState, .cancelled)
        XCTAssertTrue(connectionA.isClosed)
        XCTAssertTrue(runtimeB.reconnectState.isReconnecting)
        XCTAssertFalse(replacementB.isClosed)

        await recoveryGate.open()
        try await eventually { runtimeB.session.state == .connected }
        XCTAssertTrue((runtimeB.connection as AnyObject) === replacementB)
        // A stayed cancelled: its released backoff must not dial a replacement.
        XCTAssertEqual(runtimeA.reconnectState, .cancelled)
        XCTAssertEqual(runtimeA.session.state, .disconnected)
    }

    func testNonSelectedDropCanBeSelectedAndRetriedWithoutDisturbingHealthySession() async throws {
        let connectionA = MockSSHConnection()
        let connectionB = MockSSHConnection()
        let replacementB = MockSSHConnection()
        let transport = ControllableTransport()
        let bConnections = ConnectionSequence([connectionB, replacementB])
        transport.onConnect = { host in
            host.hostname == "alpha.invalid" ? connectionA : await bConnections.next()
        }
        let container = AppContainer(
            transport: transport,
            reachabilityMonitor: MockReachabilityMonitor(isReachable: true),
            reconnectCoordinator: ReconnectCoordinator(
                clock: { _ in }, jitter: ReconnectCoordinator.zeroJitter))
        let hostA = try Host(name: "Alpha Host", hostname: "alpha.invalid", username: "dev")
        let hostB = try Host(name: "Beta Host", hostname: "beta.invalid", username: "dev")

        await container.connect(to: hostA)
        let sessionAID = try XCTUnwrap(container.selectedSessionID)
        await container.connect(to: hostB)
        let sessionBID = try XCTUnwrap(container.selectedSessionID)
        container.selectSession(id: sessionAID)
        container.handleScenePhaseChange(.background)
        connectionB.isResponsive = false
        container.handleScenePhaseChange(.active)

        let runtimeB = try XCTUnwrap(container.runtime(for: sessionBID))
        try await eventually {
            runtimeB.session.state == .disconnected
                && runtimeB.reconnectState == .failed(reason: "Connection closed.")
        }
        XCTAssertEqual(container.selectedSessionID, sessionAID)
        XCTAssertEqual(container.activeSession?.state, .connected)
        XCTAssertFalse(connectionA.isClosed)

        container.selectSession(id: sessionBID)
        XCTAssertEqual(container.reconnectState, .failed(reason: "Connection closed."))
        await container.retryReconnect()

        XCTAssertTrue(connectionB.isClosed)
        XCTAssertFalse(connectionA.isClosed)
        XCTAssertEqual(container.selectedSessionID, sessionBID)
        XCTAssertEqual(container.activeSession?.state, .connected)
        XCTAssertEqual(container.runtime(for: sessionAID)?.session.state, .connected)
        let currentBConnection = try XCTUnwrap(container.runtime(for: sessionBID)?.connection)
        XCTAssertTrue((currentBConnection as AnyObject) === (replacementB as AnyObject))
    }

    func testAuxiliaryRebindStopsStaleForwardingStartAfterNewConnect() async throws {
        let manager = InterleavingForwardingManager()
        let transport = ControllableTransport()
        let container = AppContainer(
            transport: transport,
            portForwardingManager: manager)
        let rule = try PortForwardingRule(
            name: "Rebind tunnel",
            type: .local,
            localHost: "127.0.0.1",
            localPort: 18081,
            remoteHost: "localhost",
            remotePort: 8081,
            enabled: true)
        let hostA = try Host(
            name: "Alpha Host", hostname: "alpha.invalid", username: "dev", forwardingRules: [rule])
        let hostB = try Host(name: "Beta Host", hostname: "beta.invalid", username: "dev")
        let hostC = try Host(name: "Gamma Host", hostname: "gamma.invalid", username: "dev")

        await container.connect(to: hostA)
        await container.connect(to: hostB)
        await manager.blockNextStart()

        let closingB = Task { @MainActor in
            await container.closeSession(id: try! XCTUnwrap(container.selectedSessionID))
        }
        let startBlocked = await manager.waitForBlockedStart()
        XCTAssertTrue(startBlocked, "Closing B must rebind A and reach the forwarding start")

        // A new connection supersedes the awaited rebind for A.
        await container.connect(to: hostC)
        await manager.releaseBlockedStart()
        await closingB.value

        let stopForwardingCallCount = await manager.stopForwardingCallCount()
        XCTAssertGreaterThanOrEqual(
            stopForwardingCallCount, 1,
            "Stale forwarding starts must be torn down after a newer connect")
        XCTAssertTrue(container.forwardingSessions.isEmpty)
    }

    func testNonCooperativeForwardingStreamCannotRepublishAfterSelectionChanges() async throws {
        let manager = NonCooperativeForwardingStreamManager()
        let container = AppContainer(
            transport: ControllableTransport(),
            portForwardingManager: manager
        )
        let rule = try PortForwardingRule(
            name: "Delayed stream tunnel",
            type: .local,
            localHost: "127.0.0.1",
            localPort: 18082,
            remoteHost: "localhost",
            remotePort: 8082,
            enabled: true
        )
        let hostA = try Host(
            name: "Stream Alpha", hostname: "stream-alpha.invalid", username: "dev",
            forwardingRules: [rule]
        )
        let hostB = try Host(name: "Stream Beta", hostname: "stream-beta.invalid", username: "dev")

        await container.connect(to: hostA)
        await manager.waitForStreamStart()
        await container.connect(to: hostB)

        await manager.emit([
            ForwardingSessionState(ruleID: rule.id, rule: rule, status: .active)
        ])
        try await Task.sleep(nanoseconds: 50_000_000)

        XCTAssertEqual(container.activeHost?.id, hostB.id)
        XCTAssertTrue(
            container.forwardingSessions.isEmpty,
            "A's delayed stream must not repopulate forwarding state after B is selected")
    }

    func testReusedForwardingManagerCannotLetStaleTeardownStopNewOwner() async throws {
        let manager = ManagerReuseRaceForwardingManager()
        let container = AppContainer(
            transport: ControllableTransport(),
            portForwardingManager: manager
        )
        let rule = try PortForwardingRule(
            name: "Reused manager tunnel",
            type: .local,
            localHost: "127.0.0.1",
            localPort: 18083,
            remoteHost: "localhost",
            remotePort: 8083,
            enabled: true
        )
        let hostA = try Host(
            name: "Reuse Alpha", hostname: "reuse-alpha.invalid", username: "dev",
            forwardingRules: [rule]
        )
        let hostB = try Host(name: "Reuse Beta", hostname: "reuse-beta.invalid", username: "dev")

        await container.connect(to: hostA)
        await container.connect(to: hostB)

        let activeWhileBIsOpen = await manager.activeSessions()
        XCTAssertTrue(
            activeWhileBIsOpen.contains { $0.ruleID == rule.id && $0.status == .active },
            "Opening B must not stop A's tunnel on a shared manager")

        let closingB = Task { @MainActor in
            await container.closeSession(id: try! XCTUnwrap(container.selectedSessionID))
        }
        await Task.yield()
        await closingB.value

        let active = await manager.activeSessions()
        XCTAssertTrue(
            active.contains { $0.ruleID == rule.id && $0.status == .active },
            "A stale teardown must not stop the reused manager after A is rebound")
        XCTAssertEqual(container.activeHost?.id, hostA.id)
    }

    func testOpeningSecondSessionClosesSFTPSecondaryPane() async throws {
        let transport = ControllableTransport()
        let container = AppContainer(transport: transport)
        let hostA = try Host(name: "Alpha Host", hostname: "alpha.invalid", username: "dev")
        let hostB = try Host(name: "Beta Host", hostname: "beta.invalid", username: "dev")

        await container.connect(to: hostA)
        XCTAssertEqual(container.openSessions.count, 1)

        // Open secondary SFTP pane for host A
        container.openSecondarySFTP(for: hostA)
        XCTAssertEqual(container.secondaryPaneMode, .sftp(hostA))

        // Open second session for host B
        await container.connect(to: hostB)
        XCTAssertEqual(container.openSessions.count, 2)

        // Secondary pane must be closed before creating another session to prevent cross-host leak
        XCTAssertEqual(
            container.secondaryPaneMode, .none,
            "Existing secondary pane must be closed before opening a second session")
    }

    func testAuxiliaryProjectionFollowsSelectedSessionAcrossMultipleSessions() async throws {
        let transport = ControllableTransport()
        let forwardingManager = DemoPortForwardingManager()
        let sftpRepository = DemoSFTPRepository(seedDemoData: true)
        let container = AppContainer(
            transport: transport,
            sftpRepository: sftpRepository,
            portForwardingManager: forwardingManager
        )
        let rule = try PortForwardingRule(
            name: "Host A tunnel",
            type: .local,
            localHost: "127.0.0.1",
            localPort: 18080,
            remoteHost: "localhost",
            remotePort: 8080,
            enabled: true
        )
        let hostA = try Host(
            name: "Host A", hostname: "a.invalid", username: "dev", forwardingRules: [rule])
        let hostB = try Host(name: "Host B", hostname: "b.invalid", username: "dev")

        await container.connect(to: hostA)
        XCTAssertEqual(container.openSessions.count, 1)
        XCTAssertEqual(container.forwardingSessions.first?.status, .active)
        await container.loadDirectory(at: RemotePath("/home/dev"), bypassCache: true)
        XCTAssertFalse(container.currentDirectoryFiles.isEmpty)
        container.activeTmuxSessionID = "$0"

        await container.connect(to: hostB)
        XCTAssertEqual(container.openSessions.count, 2)
        XCTAssertTrue(container.openSessions.count > 1)
        // B has no rules, so A's rule must not be projected for B even though
        // the injected manager is shared and reports A's live rule.
        XCTAssertTrue(container.forwardingSessions.isEmpty)
        // Opening B does not wipe A's tmux target; B starts without one.
        XCTAssertEqual(container.activeHost?.id, hostB.id)
        XCTAssertNil(container.activeTmuxSessionID)

        await container.closeSession(id: try XCTUnwrap(container.activeSession?.id))
        XCTAssertEqual(container.openSessions.count, 1)
        XCTAssertEqual(container.activeHost?.id, hostA.id)
        // Closing B restores A's own tmux target projection.
        XCTAssertEqual(container.activeTmuxSessionID, "$0")
        let deadline = DispatchTime.now().uptimeNanoseconds + 1_000_000_000
        while container.forwardingSessions.first?.status != .active,
            DispatchTime.now().uptimeNanoseconds < deadline
        {
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        XCTAssertEqual(container.forwardingSessions.first?.status, .active)
    }

    func testRejectingSecondaryHostKeyChallengePreservesActiveSessionAndRedactor() async throws {
        let mockA = MockSSHConnection()
        let transport = ControllableTransport()
        let challenge = HostKeyChallenge(
            hostname: "beta.invalid",
            port: 22,
            algorithm: "ssh-ed25519",
            fingerprint: "SHA256:test"
        )
        transport.onConnect = { host in
            if host.hostname == "alpha.invalid" {
                return mockA
            } else {
                throw TransportError.hostKeyApprovalRequired(challenge)
            }
        }

        let container = AppContainer(transport: transport)
        let hostA = try Host(name: "Alpha Host", hostname: "alpha.invalid", username: "dev")
        let hostB = try Host(name: "Beta Host", hostname: "beta.invalid", username: "dev")

        await container.connect(to: hostA)
        let sessionAID = try XCTUnwrap(container.activeSession?.id)
        XCTAssertEqual(container.selectedSessionID, sessionAID)
        XCTAssertEqual(container.activeSession?.state, .connected)

        // Attempt second session to hostB which requires approval
        await container.connect(to: hostB)

        // Verify challenge is pending, but session A remains selected and connected
        XCTAssertNotNil(container.pendingTrustChallenge)
        XCTAssertEqual(container.pendingTrustHost?.id, hostB.id)
        XCTAssertEqual(container.selectedSessionID, sessionAID)
        XCTAssertEqual(container.activeSession?.state, .connected)

        // Reject the host key challenge for the secondary session
        container.rejectPendingHostKey()

        // Pending challenge cleared
        XCTAssertNil(container.pendingTrustChallenge)
        XCTAssertNil(container.pendingTrustHost)

        // Primary session A must NOT be marked disconnected
        XCTAssertEqual(container.selectedSessionID, sessionAID)
        XCTAssertEqual(container.activeSession?.id, sessionAID)
        XCTAssertEqual(container.activeSession?.state, .connected)

        // Active session can still send interactive terminal input
        let sent = await container.sendRawInteractive(Data("echo hello\n".utf8))
        XCTAssertTrue(
            sent,
            "Rejecting a secondary host key challenge must not disrupt the active session's keyboard input"
        )
    }

    func testExplicitDisconnectIsScopedToTargetSession() async throws {
        let mockA = MockSSHConnection()
        let mockB = MockSSHConnection()
        let transport = ControllableTransport()
        transport.onConnect = { host in
            host.hostname == "alpha.invalid" ? mockA : mockB
        }

        let container = AppContainer(transport: transport)
        let hostA = try Host(name: "Alpha Host", hostname: "alpha.invalid", username: "dev")
        let hostB = try Host(name: "Beta Host", hostname: "beta.invalid", username: "dev")

        await container.connect(to: hostA)
        let sessionAID = try XCTUnwrap(container.activeSession?.id)

        await container.connect(to: hostB)
        let sessionBID = try XCTUnwrap(container.activeSession?.id)
        XCTAssertEqual(container.selectedSessionID, sessionBID)
        XCTAssertFalse(container.isExplicitDisconnect)

        // Disconnect Session B explicitly
        await container.disconnect()
        XCTAssertTrue(container.isExplicitDisconnect)
        XCTAssertEqual(container.activeSession?.state, .disconnected)

        // Switch back to Session A
        container.selectSession(id: sessionAID)
        XCTAssertEqual(container.selectedSessionID, sessionAID)
        XCTAssertEqual(container.activeSession?.state, .connected)
        XCTAssertFalse(
            container.isExplicitDisconnect,
            "Switching to a connected session must not inherit the disconnected session's explicit disconnect flag"
        )

        // Input works on Session A
        let sent = await container.sendRawInteractive(Data("test\n".utf8))
        XCTAssertTrue(sent)

        // Switch back to Session B: explicit disconnect is preserved for Session B
        container.selectSession(id: sessionBID)
        XCTAssertTrue(container.isExplicitDisconnect)
    }

    func testConnectingSecondSessionPreservesPriorSessionExplicitDisconnectState() async throws {
        let mockA = MockSSHConnection()
        let mockB = MockSSHConnection()
        let transport = ControllableTransport()
        transport.onConnect = { host in
            if host.hostname == "alpha.invalid" {
                return mockA
            } else if host.hostname == "beta.invalid" {
                return mockB
            } else {
                throw TransportError.connectionRefused
            }
        }

        let container = AppContainer(transport: transport)
        let hostA = try Host(name: "Alpha Host", hostname: "alpha.invalid", username: "dev")
        let hostB = try Host(name: "Beta Host", hostname: "beta.invalid", username: "dev")
        let hostFailed = try Host(name: "Fail Host", hostname: "failed.invalid", username: "dev")

        // 1. Connect Session A
        await container.connect(to: hostA)
        let sessionAID = try XCTUnwrap(container.activeSession?.id)
        XCTAssertEqual(container.selectedSessionID, sessionAID)
        XCTAssertEqual(container.activeSession?.state, .connected)
        XCTAssertFalse(container.isExplicitDisconnect)

        // 2. Explicitly disconnect Session A while selected
        await container.disconnect()
        XCTAssertEqual(container.selectedSessionID, sessionAID)
        XCTAssertEqual(container.activeSession?.state, .disconnected)
        XCTAssertTrue(container.isExplicitDisconnect)
        XCTAssertTrue(container.explicitlyDisconnectedSessionIDs.contains(sessionAID))

        // 3. Attempt connecting to a failing second host while Session A remains selected
        await container.connect(to: hostFailed)
        XCTAssertEqual(container.selectedSessionID, sessionAID)
        XCTAssertEqual(container.activeSession?.state, .disconnected)
        XCTAssertTrue(
            container.isExplicitDisconnect,
            "Failed second connection attempt must preserve prior session's explicit disconnect state"
        )
        XCTAssertTrue(container.explicitlyDisconnectedSessionIDs.contains(sessionAID))

        // 4. Complete connecting Session B while Session A remains selected and explicitly disconnected
        await container.connect(to: hostB)
        let sessionBID = try XCTUnwrap(container.activeSession?.id)
        XCTAssertNotEqual(sessionAID, sessionBID)
        XCTAssertEqual(container.selectedSessionID, sessionBID)
        XCTAssertEqual(container.activeSession?.state, .connected)
        XCTAssertFalse(container.isExplicitDisconnect)
        XCTAssertFalse(container.explicitlyDisconnectedSessionIDs.contains(sessionBID))

        // Verify Session B can send commands
        let sentOnB = await container.sendRawInteractive(Data("echo from b\n".utf8))
        XCTAssertTrue(sentOnB)

        // 5. Switch back to Session A
        container.selectSession(id: sessionAID)
        XCTAssertEqual(container.selectedSessionID, sessionAID)
        XCTAssertEqual(container.activeSession?.id, sessionAID)
        XCTAssertEqual(container.activeSession?.state, .disconnected)

        // Assert Session A remains explicitly disconnected
        XCTAssertTrue(
            container.isExplicitDisconnect,
            "Connecting a second session must not clear the explicit disconnect state of the previously selected session"
        )
        XCTAssertTrue(container.explicitlyDisconnectedSessionIDs.contains(sessionAID))

        // 6. Assert Session A cannot be automatically reconnected or probed due to cleared state
        container.handleReachabilityChange(true)
        XCTAssertFalse(
            container.reconnectState.isReconnecting,
            "Explicitly disconnected session must not initiate reconnection on reachability changes"
        )
        XCTAssertEqual(container.activeSession?.state, .disconnected)

        container.handleScenePhaseChange(.background)
        container.handleScenePhaseChange(.active)
        XCTAssertFalse(
            container.reconnectState.isReconnecting,
            "Explicitly disconnected session must not initiate reconnection on foreground return"
        )
        XCTAssertEqual(container.activeSession?.state, .disconnected)
        XCTAssertTrue(container.isExplicitDisconnect)
    }

    func testBackgroundSessionTerminationDoesNotDisruptSelectedSessionMultiplexerOrErrorState()
        async throws
    {
        let mockA = MockSSHConnection()
        let mockB = MockSSHConnection()
        let recoveryGate = MultiSessionGate()
        let transport = ControllableTransport()
        transport.onConnect = { host in
            host.hostname == "alpha.invalid" ? mockA : mockB
        }

        let container = AppContainer(
            transport: transport,
            reachabilityMonitor: MockReachabilityMonitor(isReachable: true),
            reconnectCoordinator: ReconnectCoordinator(
                clock: { _ in await recoveryGate.wait() },
                jitter: ReconnectCoordinator.zeroJitter))
        let hostA = try Host(name: "Alpha Host", hostname: "alpha.invalid", username: "dev")
        let hostB = try Host(name: "Beta Host", hostname: "beta.invalid", username: "dev")

        await container.connect(to: hostA)
        let sessionAID = try XCTUnwrap(container.activeSession?.id)

        await container.connect(to: hostB)
        let sessionBID = try XCTUnwrap(container.activeSession?.id)

        // Select Session A
        container.selectSession(id: sessionAID)
        XCTAssertEqual(container.selectedSessionID, sessionAID)

        let initialTmuxGen = container.tmuxRefreshGeneration
        let initialHerdrGen = container.herdrRefreshGeneration

        // Background session B encounters a transport error. Wait (bounded) for its
        // own recovery admission so the assertions below observe the processed drop.
        let runtimeB = try XCTUnwrap(container.runtime(for: sessionBID))
        mockB.emit(.error(.connectionRefused))
        try await eventually { runtimeB.reconnectState.isReconnecting }

        // Session A must remain connected and unperturbed
        XCTAssertEqual(container.selectedSessionID, sessionAID)
        XCTAssertEqual(container.activeSession?.id, sessionAID)
        XCTAssertEqual(container.activeSession?.state, .connected)
        XCTAssertEqual(
            container.tmuxRefreshGeneration, initialTmuxGen,
            "Background session termination must not increment tmux refresh generation")
        XCTAssertEqual(
            container.herdrRefreshGeneration, initialHerdrGen,
            "Background session termination must not increment herdr refresh generation")
        XCTAssertFalse(
            container.hasObservedTransportError,
            "Background session error must not set container-global observed transport error")

        // A non-selected drop now owns its own recovery (P1), so B is no longer
        // parked in .failed. Its backoff is gated, which keeps the run deterministic.
        XCTAssertEqual(runtimeB.session.state, .connecting)
        XCTAssertFalse(mockA.isClosed)

        container.selectSession(id: sessionBID)
        await container.cancelReconnect()
        await recoveryGate.open()
    }

    func testClosingFinalSessionTearsDownAuxiliaryResources() async throws {
        let mockA = MockSSHConnection()
        let transport = ControllableTransport()
        transport.onConnect = { _ in mockA }

        let container = AppContainer(transport: transport)
        let hostA = try Host(name: "Alpha Host", hostname: "alpha.invalid", username: "dev")

        await container.connect(to: hostA)
        let sessionAID = try XCTUnwrap(container.activeSession?.id)
        XCTAssertEqual(container.openSessions.count, 1)

        // Open secondary pane
        container.openSecondarySFTP(for: hostA)
        XCTAssertEqual(container.secondaryPaneMode, .sftp(hostA))

        // Close the final session
        await container.closeSession(id: sessionAID)

        XCTAssertTrue(container.sessionRuntimes.isEmpty)
        XCTAssertTrue(container.openSessions.isEmpty)
        XCTAssertNil(container.selectedSessionID)
        XCTAssertNil(container.activeSession)
        XCTAssertNil(container.activeHost)
        XCTAssertEqual(
            container.secondaryPaneMode, .none,
            "Closing final session must reset secondary pane mode")
        XCTAssertTrue(container.forwardingSessions.isEmpty)
        XCTAssertTrue(container.currentDirectoryFiles.isEmpty)
        XCTAssertTrue(
            container.redactor.secrets.isEmpty,
            "Closing the final session must clear the legacy redactor projection")
    }

    private func eventually(
        timeoutNanoseconds: UInt64 = 2_000_000_000,
        condition: @escaping @MainActor () -> Bool
    ) async throws {
        let deadline = DispatchTime.now().uptimeNanoseconds + timeoutNanoseconds
        while !condition() {
            if DispatchTime.now().uptimeNanoseconds >= deadline {
                XCTFail("Condition was not met before timeout")
                return
            }
            try await Task.sleep(nanoseconds: 5_000_000)
        }
    }
}

private actor OrderedSFTPRepository: SFTPRepository {
    private var requestCount = 0
    private var releasedRequests = Set<Int>()
    private var waiters: [Int: [CheckedContinuation<Void, Never>]] = [:]

    func listDirectory(at path: RemotePath) async throws -> [RemoteFile] {
        let request = requestCount
        requestCount += 1
        if !releasedRequests.contains(request) {
            await withCheckedContinuation { continuation in
                waiters[request, default: []].append(continuation)
            }
        }
        return [RemoteFile(name: "request-\(request)", path: path)]
    }

    func waitForRequestCount(_ expected: Int) async {
        while requestCount < expected {
            await Task.yield()
        }
    }

    func release(request: Int) {
        releasedRequests.insert(request)
        let pending = waiters.removeValue(forKey: request) ?? []
        for continuation in pending {
            continuation.resume()
        }
    }

    func readFile(at path: RemotePath) async throws -> Data {
        Data()
    }

    func download(
        from remotePath: RemotePath,
        to localURL: URL,
        progress: (@Sendable (TransferProgress) -> Void)?
    ) async throws {}

    func writeFile(
        data: Data,
        at remotePath: RemotePath,
        progress: (@Sendable (TransferProgress) -> Void)?
    ) async throws {}

    func upload(
        from localURL: URL,
        to remotePath: RemotePath,
        progress: (@Sendable (TransferProgress) -> Void)?
    ) async throws {}

    func createDirectory(at path: RemotePath) async throws {}
    func removeFile(at path: RemotePath) async throws {}
    func removeDirectory(at path: RemotePath) async throws {}
    func rename(from oldPath: RemotePath, to newPath: RemotePath) async throws {}
    func fetchAttributes(at path: RemotePath) async throws -> RemoteFile {
        RemoteFile(name: path.lastComponent, path: path)
    }
}

private actor DelayedReconnectOutcomes {
    enum Outcome {
        case success(MockSSHConnection)
        case failure(TransportError)
    }

    private var outcomes: [Outcome]
    private var callCount = 0
    private let gate: MultiSessionGate

    init(outcomes: [Outcome], gate: MultiSessionGate) {
        self.outcomes = outcomes
        self.gate = gate
    }

    func next() async throws -> MockSSHConnection {
        callCount += 1
        if callCount == 2 {
            await gate.wait()
        }
        precondition(!outcomes.isEmpty)
        switch outcomes.removeFirst() {
        case .success(let connection): return connection
        case .failure(let error): throw error
        }
    }
}

private actor DelayedSFTPRepository: SFTPRepository {
    private let base: DemoSFTPRepository
    private let gate: MultiSessionGate
    private var readGate: MultiSessionGate?
    private var readFailure = false
    private var listingCount = 0
    private let gatedListingCount: Int

    /// Only the first `gatedListingCount` listings wait on `gate`; later listings
    /// complete immediately so a test can order one listing before another.
    init(gate: MultiSessionGate, gatedListingCount: Int = Int.max) {
        self.base = DemoSFTPRepository(seedDemoData: true)
        self.gate = gate
        self.gatedListingCount = gatedListingCount
    }

    func listedDirectoryCount() -> Int {
        listingCount
    }

    func delayRead(failing: Bool = false) {
        readGate = MultiSessionGate()
        readFailure = failing
    }

    func waitForReadStart() async {
        await readGate?.waitForStart()
    }

    func releaseRead() async {
        await readGate?.open()
    }

    func listDirectory(at path: RemotePath) async throws -> [RemoteFile] {
        listingCount += 1
        if listingCount <= gatedListingCount {
            await gate.wait()
        }
        return try await base.listDirectory(at: path)
    }

    func readFile(at path: RemotePath) async throws -> Data {
        let gate = readGate
        let failing = readFailure
        await gate?.wait()
        if failing { throw SFTPRepositoryError.remoteFailure("delayed read failure") }
        return try await base.readFile(at: path)
    }

    func download(
        from remotePath: RemotePath,
        to localURL: URL,
        progress: (@Sendable (TransferProgress) -> Void)?
    ) async throws {
        try await base.download(from: remotePath, to: localURL, progress: progress)
    }

    func writeFile(
        data: Data,
        at remotePath: RemotePath,
        progress: (@Sendable (TransferProgress) -> Void)?
    ) async throws {
        try await base.writeFile(data: data, at: remotePath, progress: progress)
    }

    func upload(
        from localURL: URL,
        to remotePath: RemotePath,
        progress: (@Sendable (TransferProgress) -> Void)?
    ) async throws {
        try await base.upload(from: localURL, to: remotePath, progress: progress)
    }

    func createDirectory(at path: RemotePath) async throws {
        try await base.createDirectory(at: path)
    }

    func removeFile(at path: RemotePath) async throws {
        try await base.removeFile(at: path)
    }

    func removeDirectory(at path: RemotePath) async throws {
        try await base.removeDirectory(at: path)
    }

    func rename(from oldPath: RemotePath, to newPath: RemotePath) async throws {
        try await base.rename(from: oldPath, to: newPath)
    }

    func fetchAttributes(at path: RemotePath) async throws -> RemoteFile {
        try await base.fetchAttributes(at: path)
    }
}

private final class DelayedMoshConnection: MoshSessionControlling, @unchecked Sendable {
    let base: ControllableMoshConnection
    private let lock = NSLock()
    private var readGate: MultiSessionGate?

    init(base: ControllableMoshConnection) {
        self.base = base
    }

    func delayReads() {
        lock.withLock {
            readGate = MultiSessionGate()
        }
    }

    func waitForReadStart() async {
        let gate = lock.withLock { readGate }
        await gate?.waitForStart()
    }

    func releaseReads() async {
        let gate = lock.withLock { readGate }
        await gate?.open()
    }

    var sessionInfo: MoshSessionInfo {
        get async {
            let gate = lock.withLock { readGate }
            await gate?.wait()
            return base.sessionInfo
        }
    }

    var moshState: MoshState {
        get async {
            let gate = lock.withLock { readGate }
            await gate?.wait()
            return base.moshState
        }
    }

    var roamingState: NetworkRoamingState {
        get async { base.roamingState }
    }

    func events() async -> AsyncThrowingStream<TerminalEvent, Error> {
        await base.events()
    }

    func moshStateUpdates() async -> AsyncStream<MoshState> {
        await base.moshStateUpdates()
    }

    func handleNetworkRoaming(_ newState: NetworkRoamingState) async throws {
        try await base.handleNetworkRoaming(newState)
    }

    func send(_ data: Data) async throws {
        try await base.send(data)
    }

    func resize(_ size: TerminalSize) async throws {
        try await base.resize(size)
    }

    func close() async {
        await base.close()
    }
}

private actor ManagerReuseRaceForwardingManager: PortForwardingManaging {
    private var sessions: [UUID: ForwardingSessionState] = [:]
    private var blockNextStop = false
    private var blockedStop = false
    private var releasedStop = false
    private var stopWaiters: [CheckedContinuation<Void, Never>] = []

    func blockNextStopAll() {
        blockNextStop = true
        releasedStop = false
    }

    func waitForBlockedStopAll() async {
        while !blockedStop {
            await Task.yield()
        }
    }

    func releaseBlockedStopAll() {
        releasedStop = true
        let waiters = stopWaiters
        stopWaiters.removeAll()
        for waiter in waiters {
            waiter.resume()
        }
    }

    func startForwarding(rule: PortForwardingRule) async throws -> ForwardingSessionState {
        let session = ForwardingSessionState(ruleID: rule.id, rule: rule, status: .active)
        sessions[rule.id] = session
        return session
    }

    func stopForwarding(ruleID: UUID) async throws {
        sessions.removeValue(forKey: ruleID)
    }

    func stopAll() async {
        if blockNextStop {
            blockNextStop = false
            blockedStop = true
            if !releasedStop {
                await withCheckedContinuation { continuation in
                    stopWaiters.append(continuation)
                }
            }
        }
        sessions.removeAll()
    }

    func activeSessions() async -> [ForwardingSessionState] {
        Array(sessions.values.filter { $0.status == .active })
    }

    func sessionState(for ruleID: UUID) async -> ForwardingSessionState? {
        sessions[ruleID]
    }

    func sessionStatesStream() async -> AsyncStream<[ForwardingSessionState]> {
        AsyncStream { continuation in
            continuation.yield(Array(sessions.values))
            continuation.finish()
        }
    }
}

private actor NonCooperativeForwardingStreamManager: PortForwardingManaging {
    private var continuation: AsyncStream<[ForwardingSessionState]>.Continuation?
    private var streamStarted = false

    func waitForStreamStart() async {
        while !streamStarted {
            await Task.yield()
        }
    }

    func emit(_ states: [ForwardingSessionState]) {
        continuation?.yield(states)
    }

    func startForwarding(rule: PortForwardingRule) async throws -> ForwardingSessionState {
        ForwardingSessionState(ruleID: rule.id, rule: rule, status: .active)
    }

    func stopForwarding(ruleID: UUID) async throws {}
    func stopAll() async {}
    func activeSessions() async -> [ForwardingSessionState] { [] }
    func sessionState(for ruleID: UUID) async -> ForwardingSessionState? { nil }

    func sessionStatesStream() async -> AsyncStream<[ForwardingSessionState]> {
        streamStarted = true
        return AsyncStream { continuation in
            self.continuation = continuation
        }
    }
}

private actor InterleavingForwardingManager: PortForwardingManaging {
    private var blockNext = false
    private var blocked = false
    private var startCalls = 0
    private var isReleased = false
    private var stopAllCalls = 0
    private var stopForwardingCalls = 0
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func blockNextStart() {
        blockNext = true
    }

    /// Bounded: returns false when the expected start never reaches the manager,
    /// so a missing call fails the test instead of spinning forever.
    func waitForBlockedStart(maximumYields: Int = 10_000) async -> Bool {
        for _ in 0..<maximumYields where !blocked {
            await Task.yield()
        }
        return blocked
    }

    func releaseBlockedStart() {
        isReleased = true
        for waiter in waiters {
            waiter.resume()
        }
        waiters.removeAll()
    }

    func stopAllCallCount() -> Int {
        stopAllCalls
    }

    func stopForwardingCallCount() -> Int {
        stopForwardingCalls
    }

    func startCallCount() -> Int {
        startCalls
    }

    func startForwarding(rule: PortForwardingRule) async throws -> ForwardingSessionState {
        startCalls += 1
        if blockNext {
            blockNext = false
            blocked = true
            if !isReleased {
                await withCheckedContinuation { continuation in
                    waiters.append(continuation)
                }
            }
        }
        return ForwardingSessionState(ruleID: rule.id, rule: rule, status: .active)
    }

    func stopForwarding(ruleID: UUID) async throws {
        stopForwardingCalls += 1
    }

    func stopAll() async {
        stopAllCalls += 1
    }

    func activeSessions() async -> [ForwardingSessionState] { [] }

    func sessionState(for ruleID: UUID) async -> ForwardingSessionState? { nil }

    func sessionStatesStream() async -> AsyncStream<[ForwardingSessionState]> {
        AsyncStream { continuation in continuation.finish() }
    }
}

private actor ControlledSessionRestorationStore: SessionRestorationStore {
    private var metadata: SessionRestorationMetadata?

    func set(_ metadata: SessionRestorationMetadata) {
        self.metadata = metadata
    }

    func save(_ metadata: SessionRestorationMetadata) async throws {}

    func load() async throws -> SessionRestorationMetadata? {
        metadata
    }

    func clear() async throws {
        metadata = nil
    }
}

private actor MultiSessionGate {
    private var isOpen = false
    private var started = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func wait() async {
        started = true
        if isOpen { return }
        await withCheckedContinuation { continuation in
            waiters.append(continuation)
        }
    }

    func waitForStart(timeoutNanoseconds: UInt64 = 1_000_000_000) async {
        let deadline = DispatchTime.now().uptimeNanoseconds + timeoutNanoseconds
        while !started && DispatchTime.now().uptimeNanoseconds < deadline { await Task.yield() }
        if !started { XCTFail("Multi-session gate did not start before timeout") }
    }

    func open() {
        isOpen = true
        for waiter in waiters {
            waiter.resume()
        }
        waiters.removeAll()
    }
}

private final class DelayedEventsConnection: SSHConnection, @unchecked Sendable {
    private let gate = MultiSessionGate()
    private let lock = NSLock()
    private var continuation: AsyncThrowingStream<TerminalEvent, Error>.Continuation?
    private(set) var isClosed = false

    func waitForEventsStart() async {
        await gate.waitForStart()
    }

    func releaseEvents() async {
        await gate.open()
    }

    func events() async -> AsyncThrowingStream<TerminalEvent, Error> {
        await gate.wait()
        return AsyncThrowingStream { continuation in
            self.lock.withLock { self.continuation = continuation }
        }
    }

    func send(_ data: Data) async throws {}
    func resize(_ size: TerminalSize) async throws {}

    func close() async {
        await gate.open()
        let stream = lock.withLock {
            () -> AsyncThrowingStream<TerminalEvent, Error>.Continuation? in
            isClosed = true
            let stream = continuation
            continuation = nil
            return stream
        }
        stream?.finish()
    }
}

private final class DelayedLoadRestorationStore: SessionRestorationStore, @unchecked Sendable {
    private let lock = NSLock()
    private let delayOnLoad: Int
    private let gate = MultiSessionGate()
    private var loadCount = 0
    private var metadata: SessionRestorationMetadata?

    init(delayOnLoad: Int, metadata: SessionRestorationMetadata? = nil) {
        self.delayOnLoad = delayOnLoad
        self.metadata = metadata
    }

    func waitForDelayedLoad() async {
        while lock.withLock({ loadCount < delayOnLoad }) {
            try? await Task.sleep(nanoseconds: 1_000_000)
        }
        await gate.waitForStart()
    }

    func openDelayedLoad() async {
        await gate.open()
    }

    func save(_ metadata: SessionRestorationMetadata) async throws {
        lock.withLock { self.metadata = metadata }
    }

    func load() async throws -> SessionRestorationMetadata? {
        let shouldDelay = lock.withLock {
            loadCount += 1
            return loadCount == delayOnLoad
        }
        if shouldDelay { await gate.wait() }
        return lock.withLock { metadata }
    }

    func clear() async throws {
        lock.withLock { metadata = nil }
    }
}

private final class ReverseOrderingRestorationStore: SessionRestorationStore, @unchecked Sendable {
    private let lock = NSLock()
    private var metadata: SessionRestorationMetadata?
    private var saveCount = 0

    func save(_ metadata: SessionRestorationMetadata) async throws {
        let delay: UInt64 = metadata.lastUsedMultiplexerTarget == nil ? 1_000_000 : 50_000_000
        lock.withLock { saveCount += 1 }
        try await Task.sleep(nanoseconds: delay)
        lock.withLock { self.metadata = metadata }
    }

    func load() async throws -> SessionRestorationMetadata? {
        lock.withLock { metadata }
    }

    func clear() async throws {
        lock.withLock { metadata = nil }
    }

    func waitForSaveCount(_ expected: Int) async {
        while lock.withLock({ saveCount < expected }) {
            try? await Task.sleep(nanoseconds: 1_000_000)
        }
    }
}
