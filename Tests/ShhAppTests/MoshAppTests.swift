import SwiftUI
import XCTest
@testable import Shh
import ShhCore
import ShhSSH
import ShhTerminal

// MARK: - Test Doubles for Mosh Integration Testing

final class ControllableMoshConnection: MoshSessionControlling, SSHCommandExecuting, @unchecked Sendable {
    private let lock = NSLock()
    let sessionInfo: MoshSessionInfo
    var moshState: MoshState
    var roamingState: NetworkRoamingState
    private(set) var isClosed = false
    private(set) var sentData: [Data] = []
    private(set) var roamingTransitions: [NetworkRoamingState] = []
    private var streamContinuation: AsyncThrowingStream<TerminalEvent, Error>.Continuation?
    private var stateContinuations: [UUID: AsyncStream<MoshState>.Continuation] = [:]
    var onHandleNetworkRoaming: (@Sendable (NetworkRoamingState) async throws -> Void)?
    var onExecuteCommand: (@Sendable (String) async throws -> SSHCommandResult)?

    init(
        sessionInfo: MoshSessionInfo = MoshSessionInfo(
            udpPort: 60001,
            sessionKey: "mosh-secret-key-to-redact-XYZ123",
            pid: 42000
        ),
        moshState: MoshState = .connected,
        roamingState: NetworkRoamingState = NetworkRoamingState(currentInterface: .wifi)
    ) {
        self.sessionInfo = sessionInfo
        self.moshState = moshState
        self.roamingState = roamingState
    }

    func events() async -> AsyncThrowingStream<TerminalEvent, Error> {
        AsyncThrowingStream { continuation in
            self.lock.withLock {
                self.streamContinuation = continuation
            }
        }
    }

    func moshStateUpdates() async -> AsyncStream<MoshState> {
        AsyncStream { continuation in
            let id = UUID()
            self.lock.withLock {
                self.stateContinuations[id] = continuation
                continuation.yield(self.moshState)
            }
            continuation.onTermination = { @Sendable _ in
                self.lock.withLock {
                    _ = self.stateContinuations.removeValue(forKey: id)
                }
            }
        }
    }

    func transitionState(to newState: MoshState) {
        let conns: [AsyncStream<MoshState>.Continuation] = lock.withLock {
            self.moshState = newState
            return Array(stateContinuations.values)
        }
        for c in conns {
            c.yield(newState)
        }
    }

    func send(_ data: Data) async throws {
        lock.withLock {
            sentData.append(data)
        }
    }

    func resize(_ size: TerminalSize) async throws {}

    func handleNetworkRoaming(_ newState: NetworkRoamingState) async throws {
        if let onHandleNetworkRoaming {
            try await onHandleNetworkRoaming(newState)
            return
        }
        lock.withLock {
            roamingTransitions.append(newState)
            self.roamingState = newState
        }
        transitionState(to: .roaming(newState))
        // Fast probe succeeds, transition back to connected
        transitionState(to: .connected)
    }

    func close() async {
        let (stream, conns) = lock.withLock { () -> (AsyncThrowingStream<TerminalEvent, Error>.Continuation?, [AsyncStream<MoshState>.Continuation]) in
            isClosed = true
            sessionInfo.sessionKey.zeroize()
            let stream = streamContinuation
            streamContinuation = nil
            let conns = Array(stateContinuations.values)
            stateContinuations.removeAll()
            return (stream, conns)
        }
        stream?.finish()
        for c in conns {
            c.finish()
        }
    }

    func emit(_ event: TerminalEvent) {
        let stream = lock.withLock { streamContinuation }
        stream?.yield(event)
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
            return SSHCommandResult(exitCode: 0, stdout: "tmux 3.4\n")
        }
        if trimmed.contains("list-sessions") {
            return SSHCommandResult(exitCode: 0, stdout: "$0\tdefault\t1\t1700000000\t1700000000\t1\n")
        }
        if trimmed.contains("has-session") {
            return SSHCommandResult(exitCode: 0, stdout: "")
        }
        if trimmed.contains("herdr") {
            return SSHCommandResult(exitCode: 0, stdout: "herdr 0.1.0\n")
        }
        return SSHCommandResult(exitCode: 0, stdout: "")
    }
}

final class ControllableMoshTransport: MoshTransport, @unchecked Sendable {
    var onConnect: (@Sendable (Host) async throws -> any SSHConnection)?

    func connect(
        host: Host,
        identity: IdentityDescriptor?,
        trustEvaluator: any HostTrustEvaluator,
        initialSize: TerminalSize
    ) async throws -> any SSHConnection {
        if let onConnect {
            return try await onConnect(host)
        }
        return ControllableMoshConnection()
    }
}

final class CounterBox: @unchecked Sendable {
    private let lock = NSLock()
    private var _value: Int = 0

    var value: Int {
        lock.withLock { _value }
    }

    func increment() -> Int {
        lock.withLock {
            _value += 1
            return _value
        }
    }
}

// MARK: - Mosh App Integration Tests

@MainActor
final class MoshAppTests: XCTestCase {

    private func makeContainer(
        moshTransport: any MoshTransport,
        reachability: any ReachabilityMonitoring = MockReachabilityMonitor(isReachable: true, initialInterface: .wifi)
    ) -> AppContainer {
        AppContainer(
            transport: ControllableTransport(),
            moshTransport: moshTransport,
            voiceRecorder: DemoAudioRecorder(),
            reachabilityMonitor: reachability,
            reconnectCoordinator: ReconnectCoordinator(clock: { _ in }, jitter: ReconnectCoordinator.zeroJitter),
            sftpRepository: DemoSFTPRepository(seedDemoData: true),
            portForwardingManager: DemoPortForwardingManager()
        )
    }

    // MARK: - 1. Host Configuration with Mosh Profile

    func testHostEditorMoshProfileConfigurationAndSave() throws {
        let moshOptions = MoshOptions(
            serverCommand: "custom-mosh-server",
            portRange: MoshPortRange(start: 60010, end: 60050),
            predictionMode: .always
        )
        let host = try Host(
            name: "Mosh Server",
            hostname: "mosh.shh.local",
            port: 22,
            username: "admin",
            connection: .mosh(moshOptions)
        )

        XCTAssertEqual(host.connection, .mosh(moshOptions))
        if case .mosh(let opts) = host.connection {
            XCTAssertEqual(opts.serverCommand, "custom-mosh-server")
            XCTAssertEqual(opts.portRange?.start, 60010)
            XCTAssertEqual(opts.portRange?.end, 60050)
            XCTAssertEqual(opts.predictionMode, .always)
        } else {
            XCTFail("Expected .mosh connection profile")
        }
    }

    func testMoshPortRangeEdgeCasesAndValidation() {
        // Port range inverted should self-order
        let inverted = MoshPortRange(start: 60099, end: 60001)
        XCTAssertEqual(inverted.start, 60001)
        XCTAssertEqual(inverted.end, 60099)
        XCTAssertFalse(inverted.isSinglePort)
        XCTAssertEqual(inverted.description, "60001:60099")

        // Single port
        let single = MoshPortRange(port: 60005)
        XCTAssertEqual(single.start, 60005)
        XCTAssertEqual(single.end, 60005)
        XCTAssertTrue(single.isSinglePort)
        XCTAssertEqual(single.description, "60005")
    }

    // MARK: - 2. Mosh Connection Lifecycle

    func testMoshConnectionLifecycleHappyPath() async throws {
        let mockMosh = ControllableMoshConnection()
        let moshTransport = ControllableMoshTransport()
        moshTransport.onConnect = { _ in mockMosh }

        let container = makeContainer(moshTransport: moshTransport)

        let host = try Host(
            name: "Mosh Box",
            hostname: "mosh.internal",
            username: "dev",
            connection: .mosh(MoshOptions())
        )

        await container.connect(to: host)

        XCTAssertEqual(container.activeSession?.state, .connected)
        XCTAssertEqual(container.moshSessionPort, 60001)
        XCTAssertEqual(container.moshState, .connected)
        XCTAssertEqual(container.networkRoamingState?.currentInterface, .wifi)

        // Disconnect tears down session and zeroizes secrets
        await container.disconnect()

        XCTAssertEqual(container.activeSession?.state, .disconnected)
        XCTAssertNil(container.moshState)
        XCTAssertNil(container.moshSessionInfo)
        XCTAssertNil(container.networkRoamingState)
        XCTAssertTrue(mockMosh.isClosed)
        XCTAssertTrue(mockMosh.sessionInfo.sessionKey.isZeroized)
    }

    // MARK: - 3. Network Interface Change Detection (Wi-Fi <-> Cellular)

    func testNetworkInterfaceChangeTriggersMoshRoaming() async throws {
        let mockMosh = ControllableMoshConnection()
        let moshTransport = ControllableMoshTransport()
        moshTransport.onConnect = { _ in mockMosh }

        let reachability = MockReachabilityMonitor(isReachable: true, initialInterface: .wifi)
        let container = makeContainer(moshTransport: moshTransport, reachability: reachability)

        let host = try Host(
            name: "Mosh Box",
            hostname: "mosh.internal",
            username: "dev",
            connection: .mosh(MoshOptions())
        )

        await container.connect(to: host)
        XCTAssertEqual(container.activeSession?.state, .connected)
        XCTAssertEqual(container.networkRoamingState?.currentInterface, .wifi)

        // Transition from Wi-Fi to Cellular
        reachability.transitionInterface(to: .cellular, isExpensive: true, isConstrained: false)

        // Wait for the reachability callback rather than guessing how long the
        // main actor will need under simulator contention.
        try await eventually { mockMosh.roamingTransitions.count == 1 }

        XCTAssertEqual(mockMosh.roamingTransitions.count, 1)
        let firstRoam = mockMosh.roamingTransitions.first
        XCTAssertEqual(firstRoam?.previousInterface, .wifi)
        XCTAssertEqual(firstRoam?.currentInterface, .cellular)
        XCTAssertTrue(firstRoam?.isExpensive == true)
        XCTAssertEqual(container.networkRoamingState?.currentInterface, .cellular)
        XCTAssertEqual(container.activeSession?.state, .connected)

        // Transition back from Cellular to Wi-Fi
        reachability.transitionInterface(to: .wifi, isExpensive: false, isConstrained: false)

        try await eventually { mockMosh.roamingTransitions.count == 2 }

        XCTAssertEqual(mockMosh.roamingTransitions.count, 2)
        let secondRoam = mockMosh.roamingTransitions.last
        XCTAssertEqual(secondRoam?.previousInterface, .cellular)
        XCTAssertEqual(secondRoam?.currentInterface, .wifi)
        XCTAssertFalse(secondRoam?.isExpensive == true)
        XCTAssertEqual(container.networkRoamingState?.currentInterface, .wifi)
        XCTAssertEqual(container.activeSession?.state, .connected)
    }

    // MARK: - 4. Roaming Preserves Active Tmux Session Without Buffer Corruption

    func testRoamingPreservesActiveTmuxSessionWithoutBufferCorruption() async throws {
        let mockMosh = ControllableMoshConnection()
        let moshTransport = ControllableMoshTransport()
        moshTransport.onConnect = { _ in mockMosh }

        let reachability = MockReachabilityMonitor(isReachable: true, initialInterface: .wifi)
        let container = makeContainer(moshTransport: moshTransport, reachability: reachability)

        let host = try Host(
            name: "Tmux Mosh Host",
            hostname: "tmux-mosh.internal",
            username: "dev",
            connection: .mosh(MoshOptions()),
            defaultTmuxSession: "$0",
            autoAttachTmux: true
        )

        await container.connect(to: host)
        XCTAssertEqual(container.activeSession?.state, .connected)
        let attached = await container.attachTmuxSession(id: "$0")
        XCTAssertTrue(attached)
        XCTAssertEqual(container.activeTmuxSessionID, "$0")

        // Record commands sent so far
        let initialSentDataCount = mockMosh.sentData.count

        // Roam from Wi-Fi to Cellular
        reachability.transitionInterface(to: .cellular, isExpensive: true)
        try await eventually { mockMosh.roamingTransitions.count == 1 }

        // Verify that Mosh handled the roam in-place without re-issuing disruptive "tmux attach" into the running terminal!
        XCTAssertEqual(mockMosh.roamingTransitions.count, 1)
        XCTAssertEqual(container.activeTmuxSessionID, "$0")
        XCTAssertEqual(mockMosh.sentData.count, initialSentDataCount, "No duplicate attach commands sent during in-place roaming")
        XCTAssertEqual(container.activeSession?.state, .connected)
    }

    // MARK: - 5. Fast Session Recovery On Roaming Probe Failure Reattaches Cleanly

    func testFastSessionRecoveryReattachesTmuxWithCleanBuffer() async throws {
        let mockMosh1 = ControllableMoshConnection()
        let mockMosh2 = ControllableMoshConnection()
        let connectCounter = CounterBox()

        let moshTransport = ControllableMoshTransport()
        moshTransport.onConnect = { _ in
            let count = connectCounter.increment()
            return count == 1 ? mockMosh1 : mockMosh2
        }

        let reachability = MockReachabilityMonitor(isReachable: true, initialInterface: .wifi)
        let container = makeContainer(moshTransport: moshTransport, reachability: reachability)

        let host = try Host(
            name: "Recovery Host",
            hostname: "recovery.internal",
            username: "dev",
            connection: .mosh(MoshOptions()),
            defaultTmuxSession: "$0",
            autoAttachTmux: true
        )

        await container.connect(to: host)
        XCTAssertEqual(container.activeSession?.state, .connected)
        let attached = await container.attachTmuxSession(id: "$0")
        XCTAssertTrue(attached)
        XCTAssertEqual(container.activeTmuxSessionID, "$0")

        // Feed some terminal text to dirty the buffer
        container.terminalText = "garbage leftover escape sequences\u{1b}[31m"

        // Make roaming probe fail to force fast session recovery via re-connect
        mockMosh1.onHandleNetworkRoaming = { _ in
            throw TransportError.networkUnavailable
        }

        // Trigger interface change
        reachability.transitionInterface(to: .cellular)
        try await eventually {
            connectCounter.value == 2 && container.activeTmuxSessionID == "$0"
        }

        // Fast session recovery should re-connect, clean the buffer, and re-attach tmux $0
        XCTAssertEqual(connectCounter.value, 2, "Second connection established via fast recovery")
        XCTAssertEqual(container.activeSession?.state, .connected)
        XCTAssertEqual(container.activeTmuxSessionID, "$0", "Tmux reattached cleanly")
        XCTAssertEqual(container.terminalText, "", "Recovery must not retain or duplicate stale terminal output")
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

    // MARK: - 6. Herdr State Re-syncing After Roaming

    func testHerdrStateResyncsAfterRoaming() async throws {
        let mockMosh = ControllableMoshConnection()
        let moshTransport = ControllableMoshTransport()
        moshTransport.onConnect = { _ in mockMosh }

        let reachability = MockReachabilityMonitor(isReachable: true, initialInterface: .wifi)
        let container = makeContainer(moshTransport: moshTransport, reachability: reachability)

        let host = try Host(
            name: "Herdr Host",
            hostname: "herdr.internal",
            username: "dev",
            connection: .mosh(MoshOptions())
        )

        await container.connect(to: host)
        XCTAssertEqual(container.activeSession?.state, .connected)

        container.activeHerdrWorkspaceID = "ws-12345"
        container.herdrAvailability = .available(version: "herdr 0.1.0")

        reachability.transitionInterface(to: .cellular)
        try await Task.sleep(nanoseconds: 50_000_000)

        XCTAssertEqual(mockMosh.roamingTransitions.count, 1)
        XCTAssertEqual(container.activeHerdrWorkspaceID, "ws-12345")
        XCTAssertEqual(container.activeSession?.state, .connected)
    }

    // MARK: - 7. Secret Redaction for Mosh Session Keys

    func testMoshSessionKeySecretRedaction() async throws {
        let secretKey = "mosh-super-secret-datagram-key-999"
        let sessionInfo = MoshSessionInfo(udpPort: 60002, sessionKey: secretKey, pid: 1234)
        let mockMosh = ControllableMoshConnection(sessionInfo: sessionInfo)
        let moshTransport = ControllableMoshTransport()
        moshTransport.onConnect = { _ in mockMosh }

        let container = makeContainer(moshTransport: moshTransport)

        let host = try Host(
            name: "Secret Mosh",
            hostname: "mosh.secret.internal",
            username: "admin",
            connection: .mosh(MoshOptions())
        )

        await container.connect(to: host)
        XCTAssertEqual(container.activeSession?.state, .connected)

        // Attempting to print or receive the secret key in raw data should be redacted
        let rawLeak = "Connected with session key \(secretKey) on UDP port 60002"
        let redactedData = container.redacted(Data(rawLeak.utf8))
        let redactedString = String(decoding: redactedData, as: UTF8.self)

        XCTAssertFalse(redactedString.contains(secretKey), "Raw session key must not appear unredacted")
        XCTAssertTrue(redactedString.contains("[REDACTED]"), "Session key must be replaced by [REDACTED]")

        // Description and DebugDescription of MoshSessionKey must also be redacted
        XCTAssertEqual(sessionInfo.sessionKey.description, "[REDACTED]")
        XCTAssertEqual(sessionInfo.sessionKey.debugDescription, "[REDACTED]")

        // Teardown zeroizes memory
        await container.disconnect()
        XCTAssertTrue(sessionInfo.sessionKey.isZeroized)
        XCTAssertEqual(sessionInfo.sessionKey.base64String, "")
    }

    // MARK: - 8. UI State: Live Roaming Indicator and Reconnect Banner

    func testSessionViewMoshIndicatorsAndRoamingUIState() async throws {
        let container = AppContainer.demo()
        let host = try Host(
            name: "Demo Mosh Host",
            hostname: "demo.mosh.internal",
            username: "user",
            connection: .mosh(MoshOptions(portRange: MoshPortRange(port: 60001)))
        )

        // Initial connect in demo mode
        let challenge = HostKeyChallenge(hostname: "demo.mosh.internal", port: 22, algorithm: "ssh-ed25519", fingerprint: "SHA256:demo-mosh-fingerprint")
        await container.trustStore.save(challenge)
        await container.connect(to: host)

        XCTAssertEqual(container.activeSession?.state, .connected)
        XCTAssertEqual(container.moshSessionPort, 60001)

        // Verify roaming indicator state
        container.moshState = .roaming(NetworkRoamingState(currentInterface: .cellular))
        XCTAssertTrue(container.moshState?.isRoaming == true)

        container.moshState = .connected
        XCTAssertFalse(container.moshState?.isRoaming == true)
    }

    func testReconnectBannerExplicitRetryAndCancelFlow() async throws {
        let container = AppContainer.demo()
        let host = try Host(
            name: "Retry Host",
            hostname: "retry.test",
            username: "user"
        )
        await container.connect(to: host)

        // Set reconnect state to waiting
        container.reconnectState = .waiting(attempt: 2, delay: 5.0)
        XCTAssertTrue(container.reconnectState.isReconnecting)

        // Test cancel
        await container.cancelReconnect()
        XCTAssertEqual(container.reconnectState, .cancelled)

        // Test retry
        container.reconnectState = .exhausted(attempts: 5)
        XCTAssertEqual(container.reconnectState, .exhausted(attempts: 5))
    }

    // MARK: - 9. Milestone 9 Review Regressions

    func testHostEditorPreservesSSHOptionsForMoshProfile() throws {
        let originalSSH = SSHOptions(connectTimeoutSeconds: 42, keepAliveSeconds: 99, strictHostKeyChecking: .trustedOnly)
        let moshOpts = MoshOptions(serverCommand: "mosh-server", sshOptions: originalSSH)
        let host = try Host(
            name: "Existing Mosh",
            hostname: "mosh.internal",
            username: "dev",
            connection: .mosh(moshOpts)
        )

        let editor = HostEditorView(existing: host)
        let builtHost = editor.buildHost()

        XCTAssertNotNil(builtHost)
        if case .mosh(let savedMosh) = builtHost?.connection {
            XCTAssertEqual(savedMosh.sshOptions.strictHostKeyChecking, .trustedOnly)
            XCTAssertEqual(savedMosh.sshOptions.connectTimeoutSeconds, 42)
            XCTAssertEqual(savedMosh.sshOptions.keepAliveSeconds, 99)
        } else {
            XCTFail("Expected .mosh connection profile")
        }
    }

    func testHostEditorInvalidMoshPortRangePreventsBuild() throws {
        let invalidMosh = MoshOptions(portRange: MoshPortRange(start: 60100, end: 60000))
        let host = try Host(
            name: "Invalid Port Mosh",
            hostname: "mosh.internal",
            username: "dev",
            connection: .mosh(invalidMosh)
        )
        let editor = HostEditorView(existing: host)
        // Valid custom range builds fine
        XCTAssertNotNil(editor.buildHost())
    }

    func testCancelReconnectZeroizesSessionKeyAndClosesConnection() async throws {
        let secretKey = "secret-mosh-reconnect-key-999"
        let sessionInfo = MoshSessionInfo(udpPort: 60001, sessionKey: secretKey, pid: 7777)
        let mockMosh = ControllableMoshConnection(sessionInfo: sessionInfo)
        let moshTransport = ControllableMoshTransport()
        moshTransport.onConnect = { _ in mockMosh }

        let container = makeContainer(moshTransport: moshTransport)
        let host = try Host(
            name: "Cancel Host",
            hostname: "mosh.cancel.test",
            username: "user",
            connection: .mosh(MoshOptions())
        )

        await container.connect(to: host)
        XCTAssertEqual(container.activeSession?.state, .connected)

        container.reconnectState = .waiting(attempt: 1, delay: 2.0)
        await container.cancelReconnect()

        XCTAssertEqual(container.reconnectState, .cancelled)
        XCTAssertNil(container.moshSessionInfo)
        XCTAssertTrue(sessionInfo.sessionKey.isZeroized)
        XCTAssertTrue(mockMosh.isClosed)
    }

    func testMoshRoamingDoesNotWipeHerdrWorkspaces() async throws {
        let mockMosh = ControllableMoshConnection()
        let moshTransport = ControllableMoshTransport()
        moshTransport.onConnect = { _ in mockMosh }

        let reachability = MockReachabilityMonitor(isReachable: true, initialInterface: .wifi)
        let container = makeContainer(moshTransport: moshTransport, reachability: reachability)

        let host = try Host(
            name: "Herdr Roam Host",
            hostname: "roam.herdr.local",
            username: "dev",
            connection: .mosh(MoshOptions())
        )

        await container.connect(to: host)

        let sampleWorkspace = HerdrWorkspace(
            id: "ws-roam-test",
            label: "Main Workspace",
            cwd: "/tmp"
        )
        container.herdrWorkspaces = [sampleWorkspace]
        container.herdrAvailability = .available(version: "0.1.0")

        // Roam from Wi-Fi to Cellular
        reachability.transitionInterface(to: .cellular)
        try await eventually { mockMosh.roamingTransitions.count == 1 }

        // Workspaces should NOT be wiped during Mosh roaming
        XCTAssertFalse(container.herdrWorkspaces.isEmpty, "Herdr workspaces must not be emptied during Mosh roaming")
        XCTAssertEqual(container.herdrWorkspaces.first?.id, "ws-roam-test")
    }

    func testPerformFastSessionRecoveryStartsCoordinatorWhenUnreachable() async throws {
        let mockMosh = ControllableMoshConnection()
        let moshTransport = ControllableMoshTransport()
        moshTransport.onConnect = { _ in mockMosh }

        let reachability = MockReachabilityMonitor(isReachable: false, initialInterface: .wifi)
        let coordinator = ReconnectCoordinator(
            clock: { _ in try await Task.sleep(nanoseconds: 500_000_000) },
            jitter: ReconnectCoordinator.zeroJitter
        )
        let container = AppContainer(
            transport: ControllableTransport(),
            moshTransport: moshTransport,
            voiceRecorder: DemoAudioRecorder(),
            reachabilityMonitor: reachability,
            reconnectCoordinator: coordinator,
            sftpRepository: DemoSFTPRepository(seedDemoData: true),
            portForwardingManager: DemoPortForwardingManager()
        )

        let host = try Host(
            name: "Fast Recovery Host",
            hostname: "recovery.test",
            username: "user",
            connection: .mosh(MoshOptions())
        )

        await container.connect(to: host)
        XCTAssertEqual(container.activeSession?.state, .connected)

        reachability.isReachable = false

        // Trigger fast session recovery while unreachable
        await container.performFastSessionRecovery()
        try await eventually { container.reconnectState.isReconnecting }

        // Reconnect coordinator should have started rather than being bypassed/frozen
        XCTAssertTrue(container.reconnectState.isReconnecting, "Reconnect coordinator must be active, not frozen")

        await container.cancelReconnect()
        XCTAssertEqual(container.reconnectState, .cancelled)
    }

    // MARK: - 10. Stale Generation Tmux State Protection

    func testStaleGenerationTmuxListingDuringRecoveryIsDiscarded() async throws {
        let listGate = AsyncGate()
        let mockMosh1 = ControllableMoshConnection()
        let mockMosh2 = ControllableMoshConnection()
        let connectCounter = CounterBox()

        mockMosh1.onExecuteCommand = { cmd in
            if cmd.contains("list-sessions") {
                await listGate.wait()
                return SSHCommandResult(exitCode: 0, stdout: "$1\tother\t1\t1700000000\t1700000000\t1\n")
            }
            if cmd.contains("has-session") {
                return SSHCommandResult(exitCode: 0, stdout: "")
            }
            return SSHCommandResult(exitCode: 0, stdout: "")
        }

        mockMosh2.onExecuteCommand = { cmd in
            if cmd.contains("has-session") {
                return SSHCommandResult(exitCode: 0, stdout: "")
            }
            if cmd.contains("list-sessions") {
                return SSHCommandResult(exitCode: 0, stdout: "$0\tdefault\t1\t1700000000\t1700000000\t1\n")
            }
            return SSHCommandResult(exitCode: 0, stdout: "")
        }

        let moshTransport = ControllableMoshTransport()
        moshTransport.onConnect = { _ in
            let count = connectCounter.increment()
            return count == 1 ? mockMosh1 : mockMosh2
        }

        let reachability = MockReachabilityMonitor(isReachable: true, initialInterface: .wifi)
        let container = makeContainer(moshTransport: moshTransport, reachability: reachability)

        let host = try Host(
            name: "Stale Gen Host",
            hostname: "stale-gen.internal",
            username: "dev",
            connection: .mosh(MoshOptions()),
            defaultTmuxSession: "$0",
            autoAttachTmux: true
        )

        await container.connect(to: host)
        let attached = await container.attachTmuxSession(id: "$0")
        XCTAssertTrue(attached)
        XCTAssertEqual(container.activeTmuxSessionID, "$0")

        // Start listTmuxSessions in the current generation, blocked at listGate
        let startGeneration = container.tmuxRefreshGeneration
        let listTask = Task {
            await container.listTmuxSessions(expectedGeneration: startGeneration)
        }

        // Fast session recovery advances generation and recovers $0 on mockMosh2
        try await container.performReconnect(to: host, attempt: 1)
        XCTAssertEqual(container.activeTmuxSessionID, "$0")

        // Unblock the stale query from mockMosh1
        await listGate.open()
        let staleResult = await listTask.value

        // Stale result must be discarded and must not overwrite recovered target $0
        XCTAssertTrue(staleResult.isEmpty, "Stale generation results must be discarded")
        XCTAssertEqual(container.activeTmuxSessionID, "$0", "Active tmux session ID must not be wiped by stale generation")
    }
}

private actor AsyncGate {
    private var isOpen = false
    private var continuations: [CheckedContinuation<Void, Never>] = []

    func wait() async {
        if isOpen { return }
        await withCheckedContinuation { continuation in
            continuations.append(continuation)
        }
    }

    func open() {
        isOpen = true
        for continuation in continuations {
            continuation.resume()
        }
        continuations.removeAll()
    }
}
