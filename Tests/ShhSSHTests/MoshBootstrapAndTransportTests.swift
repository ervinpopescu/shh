import XCTest
@testable import ShhCore
@testable import ShhSSH

final class MoshBootstrapAndTransportTests: XCTestCase {

    private final class LockedBox<T>: @unchecked Sendable {
        private let lock = NSLock()
        private var value: T?

        func set(_ value: T) {
            lock.withLock { self.value = value }
        }

        func get() -> T? {
            lock.withLock { self.value }
        }
    }

    // MARK: - MoshBootstrapper Command Generation Tests

    func testBuildCommandDefaultOptions() throws {
        let options = MoshOptions()
        let cmd = try MoshBootstrapper.buildCommand(options: options)
        XCTAssertEqual(cmd, "mosh-server new -s -c 256")
    }

    func testBuildCommandWithPortRangeAndRows() throws {
        let options = MoshOptions(
            serverCommand: "mosh-server",
            portRange: MoshPortRange(start: 60000, end: 60050)
        )
        let size = TerminalSize(columns: 120, rows: 40)
        let cmd = try MoshBootstrapper.buildCommand(options: options, initialSize: size)
        XCTAssertEqual(cmd, "mosh-server new -s -c 256 -p 60000:60050 -l rows=40")
    }

    func testBuildCommandWithQuotedPathAndRemoteCommand() throws {
        let options = MoshOptions(
            serverCommand: "/opt/custom bin/mosh-server",
            portRange: MoshPortRange(port: 60020)
        )
        let cmd = try MoshBootstrapper.buildCommand(
            options: options,
            remoteCommand: "tmux new-session -A -s dev"
        )
        XCTAssertEqual(cmd, "'/opt/custom bin/mosh-server' new -s -c 256 -p 60020 -- tmux new-session -A -s dev")
    }

    func testBuildCommandRejectsShellMetacharacters() {
        let maliciousCommands = [
            "mosh-server;reboot",
            "mosh-server$(malicious)",
            "mosh-server`whoami`",
            "mosh-server|cat",
            "mosh-server&disown",
            "mosh-server>file"
        ]
        for badCmd in maliciousCommands {
            let options = MoshOptions(serverCommand: badCmd)
            XCTAssertThrowsError(try MoshBootstrapper.buildCommand(options: options)) { error in
                guard case MoshBootstrapError.invalidServerCommand(let cmd) = error else {
                    XCTFail("Expected invalidServerCommand for '\(badCmd)', got \(error)")
                    return
                }
                XCTAssertEqual(cmd, badCmd)
            }
        }
    }

    func testBuildCommandRejectsBlockedRemoteCommand() {
        let blockedCommands = [
            "rm -rf /",
            "tmux kill-server",
            "dd if=/dev/zero of=/dev/sda"
        ]
        for blocked in blockedCommands {
            let options = MoshOptions()
            XCTAssertThrowsError(try MoshBootstrapper.buildCommand(options: options, remoteCommand: blocked)) { error in
                guard case MoshBootstrapError.blockedRemoteCommand(let cmd) = error else {
                    XCTFail("Expected blockedRemoteCommand for '\(blocked)', got \(error)")
                    return
                }
                XCTAssertEqual(cmd, blocked)
            }
        }
    }

    // MARK: - MoshBootstrapper Output Parsing Tests

    func testParseOutputStandard() throws {
        let output = "\r\nMOSH CONNECT 60001 42a12B4C1234567890ABCD\r\n"
        let info = try MoshBootstrapper.parseOutput(output)
        XCTAssertEqual(info.udpPort, 60001)
        XCTAssertEqual(info.sessionKey.base64String, "42a12B4C1234567890ABCD")
        XCTAssertNil(info.pid)
    }

    func testParseOutputWithMotdAndPid() throws {
        let output = """
        Welcome to Ubuntu 22.04 LTS
        System load: 0.12

        MOSH CONNECT 60015 Key99ABCDef1234567890
        MOSH PID 31415
        """
        let info = try MoshBootstrapper.parseOutput(output)
        XCTAssertEqual(info.udpPort, 60015)
        XCTAssertEqual(info.sessionKey.base64String, "Key99ABCDef1234567890")
        XCTAssertEqual(info.pid, 31415)
    }

    func testParseOutputWithDetachedPidPattern() throws {
        let output = """
        MOSH CONNECT 60025 Key1234567890ABCDEF12
        [mosh-server detached: pid 42100]
        """
        let info = try MoshBootstrapper.parseOutput(output)
        XCTAssertEqual(info.udpPort, 60025)
        XCTAssertEqual(info.sessionKey.base64String, "Key1234567890ABCDEF12")
        XCTAssertEqual(info.pid, 42100)
    }

    func testParseOutputInvalidHandshakeThrows() {
        let invalid = "bash: mosh-server: port in use"
        XCTAssertThrowsError(try MoshBootstrapper.parseOutput(invalid)) { error in
            guard case MoshBootstrapError.invalidHandshake(let str) = error else {
                XCTFail("Expected invalidHandshake error, got \(error)")
                return
            }
            XCTAssertEqual(str, invalid)
        }
    }

    func testParseOutputErrorRedactsSecretKey() {
        // Output with MOSH CONNECT pattern but invalid/incomplete tokens that triggers invalidHandshake
        let outputWithSecret = "MOSH CONNECT notaport SUPER_SECRET_MOSH_KEY_12345"
        XCTAssertThrowsError(try MoshBootstrapper.parseOutput(outputWithSecret)) { error in
            guard case MoshBootstrapError.invalidHandshake(let str) = error else {
                XCTFail("Expected invalidHandshake error, got \(error)")
                return
            }
            XCTAssertFalse(str.contains("SUPER_SECRET_MOSH_KEY_12345"))
            XCTAssertFalse(error.localizedDescription.contains("SUPER_SECRET_MOSH_KEY_12345"))
        }
    }

    func testParseOutputEmptyThrows() {
        XCTAssertThrowsError(try MoshBootstrapper.parseOutput("")) { error in
            guard case MoshBootstrapError.invalidHandshake = error else {
                XCTFail("Expected invalidHandshake error, got \(error)")
                return
            }
        }
    }

    // MARK: - MoshBootstrapper Execution Tests

    private struct MockCommandExecutor: SSHCommandExecuting {
        let handler: @Sendable (String) throws -> SSHCommandResult

        func executeCommand(_ command: String) async throws -> SSHCommandResult {
            try handler(command)
        }

        func executeCommand(_ command: String, timeout: TimeInterval?, maxOutputBytes: Int?) async throws -> SSHCommandResult {
            try handler(command)
        }
    }

    func testBootstrapHappyPath() async throws {
        let executor = MockCommandExecutor { cmd in
            XCTAssertTrue(cmd.contains("mosh-server new"))
            return SSHCommandResult(
                exitCode: 0,
                stdout: "MOSH CONNECT 60003 KeySuccess1234567890\nMOSH PID 100",
                stderr: ""
            )
        }

        let bootstrapper = MoshBootstrapper()
        let info = try await bootstrapper.bootstrap(
            executor: executor,
            options: MoshOptions(portRange: MoshPortRange(port: 60003))
        )

        XCTAssertEqual(info.udpPort, 60003)
        XCTAssertEqual(info.sessionKey.base64String, "KeySuccess1234567890")
        XCTAssertEqual(info.pid, 100)
    }

    func testBootstrapServerCommandNotFound() async {
        let executor = MockCommandExecutor { _ in
            SSHCommandResult(
                exitCode: 127,
                stdout: "",
                stderr: "bash: mosh-server: command not found\n"
            )
        }

        let bootstrapper = MoshBootstrapper()
        do {
            _ = try await bootstrapper.bootstrap(executor: executor, options: MoshOptions())
            XCTFail("Expected serverCommandNotFound")
        } catch {
            guard case MoshBootstrapError.serverCommandNotFound(let cmd) = error else {
                XCTFail("Expected serverCommandNotFound, got \(error)")
                return
            }
            XCTAssertEqual(cmd, "mosh-server")
        }
    }

    func testBootstrapExecutionFailed() async {
        let executor = MockCommandExecutor { _ in
            SSHCommandResult(
                exitCode: 1,
                stdout: "",
                stderr: "Could not bind UDP port"
            )
        }

        let bootstrapper = MoshBootstrapper()
        do {
            _ = try await bootstrapper.bootstrap(executor: executor, options: MoshOptions())
            XCTFail("Expected executionFailed")
        } catch {
            guard case MoshBootstrapError.executionFailed(let code, let stderr) = error else {
                XCTFail("Expected executionFailed, got \(error)")
                return
            }
            XCTAssertEqual(code, 1)
            XCTAssertTrue(stderr.contains("Could not bind UDP port"))
        }
    }

    // MARK: - MoshDatagram Framing Tests

    func testMoshDatagramEncodeDecode() {
        let payload = Data("terminal test bytes".utf8)
        let original = MoshDatagram(
            kind: .data,
            sequenceNumber: 42,
            timestamp: 1700000000000,
            payload: payload
        )

        let encoded = original.encode()
        XCTAssertEqual(encoded.count, 17 + payload.count)

        let decoded = MoshDatagram.decode(from: encoded)
        XCTAssertNotNil(decoded)
        XCTAssertEqual(decoded?.kind, .data)
        XCTAssertEqual(decoded?.sequenceNumber, 42)
        XCTAssertEqual(decoded?.timestamp, 1700000000000)
        XCTAssertEqual(decoded?.payload, payload)
    }

    func testMoshDatagramDecodeUnalignedMemory() {
        let original = MoshDatagram(kind: .data, sequenceNumber: 123456789, timestamp: 987654321, payload: Data("unaligned test".utf8))
        let encoded = original.encode()

        // Prepend an odd number of bytes to force unaligned buffer slice
        var unalignedBuffer = Data([0xAA])
        unalignedBuffer.append(encoded)

        let slice = unalignedBuffer.subdata(in: 1..<unalignedBuffer.count)
        let decoded = MoshDatagram.decode(from: slice)
        XCTAssertNotNil(decoded)
        XCTAssertEqual(decoded?.sequenceNumber, 123456789)
        XCTAssertEqual(decoded?.timestamp, 987654321)
        XCTAssertEqual(decoded?.payload, Data("unaligned test".utf8))
    }

    func testMoshDatagramDecodeTooShortReturnsNil() {
        let shortData = Data(repeating: 0, count: 16)
        XCTAssertNil(MoshDatagram.decode(from: shortData))
    }

    // MARK: - MoshConnection Lifecycle and State Machine Tests

    func testMoshConnectionSendAndReceiveLifecycle() async throws {
        let channel = MockMoshDatagramChannel(remoteHost: "192.168.1.50", remotePort: 60001)
        let info = MoshSessionInfo(udpPort: 60001, sessionKey: "secretKey1234567890", pid: 2000)
        let connection = MoshConnection(
            sessionInfo: info,
            remoteHostname: "192.168.1.50",
            channel: channel
        )

        try await connection.start()
        XCTAssertTrue(channel.isStarted)

        let state = await connection.moshState
        XCTAssertEqual(state, .connected)

        let stream = await connection.events()
        var iterator = stream.makeAsyncIterator()

        // Send terminal bytes
        try await connection.send(Data("ls -la\n".utf8))
        XCTAssertEqual(channel.sentDatagrams.count, 1)
        let sentPacket = MoshDatagram.decode(from: channel.sentDatagrams[0])
        XCTAssertEqual(sentPacket?.kind, .data)
        XCTAssertEqual(sentPacket?.sequenceNumber, 1)
        XCTAssertEqual(sentPacket?.payload, Data("ls -la\n".utf8))

        // Receive simulated incoming UDP packet
        let incoming = MoshDatagram(kind: .data, sequenceNumber: 10, payload: Data("file.txt\n".utf8))
        channel.simulateInboundDatagram(incoming.encode())

        let event = try await iterator.next()
        guard case .bytes(let bytes) = event else {
            XCTFail("Expected .bytes event")
            return
        }
        XCTAssertEqual(String(decoding: bytes, as: UTF8.self), "file.txt\n")

        // Resize window
        try await connection.resize(TerminalSize(columns: 100, rows: 30))
        XCTAssertEqual(channel.sentDatagrams.count, 2)
        let resizePacket = MoshDatagram.decode(from: channel.sentDatagrams[1])
        XCTAssertEqual(resizePacket?.kind, .resize)
        XCTAssertEqual(resizePacket?.sequenceNumber, 2)

        // Close connection and verify teardown zeroing
        await connection.close()
        XCTAssertTrue(channel.isClosed)

        let closedState = await connection.moshState
        XCTAssertTrue(closedState.isDisconnected)

        // Verify session key is zeroized from memory
        let key = await connection.sessionInfo.sessionKey
        XCTAssertTrue(key.isZeroized)
        XCTAssertEqual(key.base64String, "")
    }

    func testMoshConnectionNetworkRoamingRejectsThirdPartyAddress() async throws {
        let channel = MockMoshDatagramChannel(remoteHost: "198.51.100.1", remotePort: 60010)
        let info = MoshSessionInfo(udpPort: 60010, sessionKey: "secretRoamingKey123", pid: 3000)
        let connection = MoshConnection(
            sessionInfo: info,
            remoteHostname: "198.51.100.1",
            channel: channel
        )
        try await connection.start()

        let unauthorizedRoaming = NetworkRoamingState(
            currentInterface: .cellular,
            remoteAddress: "203.0.113.99",
            remotePort: 60010
        )
        do {
            try await connection.handleNetworkRoaming(unauthorizedRoaming)
            XCTFail("Expected TransportError.invalidConfiguration")
        } catch let error as TransportError {
            XCTAssertEqual(error, .invalidConfiguration)
        }
        await connection.close()
    }

    func testMoshConnectionDiscardsRawUnauthenticatedDatagrams() async throws {
        let channel = MockMoshDatagramChannel(remoteHost: "192.168.1.50", remotePort: 60001)
        let info = MoshSessionInfo(udpPort: 60001, sessionKey: "secretKey1234567890", pid: 2000)
        let connection = MoshConnection(
            sessionInfo: info,
            remoteHostname: "192.168.1.50",
            channel: channel
        )
        try await connection.start()
        let stream = await connection.events()
        var iterator = stream.makeAsyncIterator()

        // Allow the receive loop task to start and subscribe
        await Task.yield()

        // Inject raw unauthenticated bytes that do not decode as MoshDatagram
        channel.simulateInboundDatagram(Data("rm -rf /\n".utf8))

        // Inject valid datagram
        let valid = MoshDatagram(kind: .data, sequenceNumber: 1, payload: Data("legit\n".utf8))
        channel.simulateInboundDatagram(valid.encode())

        // The first yielded event should be the valid datagram, NOT the raw unauthenticated bytes
        let event = try await iterator.next()
        guard case .bytes(let bytes) = event else {
            XCTFail("Expected .bytes event")
            return
        }
        XCTAssertEqual(String(decoding: bytes, as: UTF8.self), "legit\n")
        await connection.close()
    }

    // MARK: - Network Roaming Recovery Tests

    func testMoshConnectionNetworkRoamingRecovery() async throws {
        let channel = MockMoshDatagramChannel(remoteHost: "198.51.100.1", remotePort: 60010)
        let info = MoshSessionInfo(udpPort: 60010, sessionKey: "secretRoamingKey123", pid: 3000)
        let connection = MoshConnection(
            sessionInfo: info,
            remoteHostname: "198.51.100.1",
            channel: channel,
            initialRoamingState: NetworkRoamingState(currentInterface: .wifi)
        )

        try await connection.start()

        // Observe state updates stream
        let stateStream = await connection.moshStateUpdates()
        var stateIterator = stateStream.makeAsyncIterator()
        let initial = await stateIterator.next()
        XCTAssertEqual(initial, .connected)

        // Simulate device roaming from Wi-Fi to Cellular
        let cellularRoaming = NetworkRoamingState(
            previousInterface: .wifi,
            currentInterface: .cellular,
            isExpensive: true,
            remoteAddress: "198.51.100.1",
            remotePort: 60010
        )
        try await connection.handleNetworkRoaming(cellularRoaming)

        // Channel endpoint should be updated
        XCTAssertEqual(channel.currentHost, "198.51.100.1")
        XCTAssertEqual(channel.currentPort, 60010)

        // Roaming probe datagram should have been sent
        guard let probePacketData = channel.sentDatagrams.last,
              let probePacket = MoshDatagram.decode(from: probePacketData) else {
            XCTFail("Expected roaming probe packet")
            return
        }
        XCTAssertEqual(probePacket.kind, .roamingProbe)
        XCTAssertEqual(probePacket.payload, Data("ROAM".utf8))

        // State should have transitioned through roaming back to connected
        let roamingObserved = await stateIterator.next()
        guard case .roaming(let roamedState) = roamingObserved else {
            XCTFail("Expected roaming state")
            return
        }
        XCTAssertEqual(roamedState.previousInterface, .wifi)
        XCTAssertEqual(roamedState.currentInterface, .cellular)
        XCTAssertTrue(roamedState.hasInterfaceChanged)

        let reconnected = await stateIterator.next()
        XCTAssertEqual(reconnected, .connected)

        await connection.close()
    }

    // MARK: - LiveMoshTransport Tests

    private final class MockSSHConnectionWithExecutor: SSHConnection, SSHCommandExecuting, @unchecked Sendable {
        private let continuation: AsyncThrowingStream<TerminalEvent, Error>.Continuation?
        let commandHandler: @Sendable (String) throws -> SSHCommandResult
        private(set) var isClosed: Bool = false

        init(commandHandler: @escaping @Sendable (String) throws -> SSHCommandResult) {
            self.continuation = nil
            self.commandHandler = commandHandler
        }

        func events() async -> AsyncThrowingStream<TerminalEvent, Error> {
            AsyncThrowingStream { $0.finish() }
        }

        func send(_ data: Data) async throws {}
        func resize(_ size: TerminalSize) async throws {}
        func close() async {
            isClosed = true
        }

        func executeCommand(_ command: String) async throws -> SSHCommandResult {
            try commandHandler(command)
        }

        func executeCommand(_ command: String, timeout: TimeInterval?, maxOutputBytes: Int?) async throws -> SSHCommandResult {
            try commandHandler(command)
        }
    }

    private struct MockSSHTransport: SSHTransport {
        let connection: MockSSHConnectionWithExecutor

        func connect(
            host: ShhCore.Host,
            identity: IdentityDescriptor?,
            trustEvaluator: any HostTrustEvaluator,
            initialSize: TerminalSize
        ) async throws -> any SSHConnection {
            connection
        }
    }

    func testLiveMoshTransportConnectsAndTearsDownBootstrapSSH() async throws {
        let mockSSHConnection = MockSSHConnectionWithExecutor { cmd in
            XCTAssertTrue(cmd.contains("mosh-server new"))
            return SSHCommandResult(
                exitCode: 0,
                stdout: "MOSH CONNECT 60030 KeyMockLive1234567890\nMOSH PID 777",
                stderr: ""
            )
        }

        let mockSSHTransport = MockSSHTransport(connection: mockSSHConnection)
        let channelBox = LockedBox<MockMoshDatagramChannel>()

        let moshTransport = LiveMoshTransport(
            sshTransport: mockSSHTransport,
            bootstrapper: MoshBootstrapper(),
            channelFactory: { host, port in
                let ch = MockMoshDatagramChannel(remoteHost: host, remotePort: port)
                channelBox.set(ch)
                return ch
            }
        )

        let host = try ShhCore.Host(
            name: "Live Mosh Server",
            hostname: "10.0.0.1",
            port: 22,
            username: "user",
            connection: .mosh(MoshOptions(portRange: MoshPortRange(port: 60030)))
        )

        struct AlwaysTrust: HostTrustEvaluator {
            func status(for challenge: HostKeyChallenge) async -> TrustStatus { .trusted }
            func evaluate(_ challenge: HostKeyChallenge) async -> TrustDecision { .trustPermanently }
        }

        let connection = try await moshTransport.connect(
            host: host,
            identity: nil,
            trustEvaluator: AlwaysTrust()
        )

        // Bootstrap SSH connection must be closed once UDP credentials are acquired!
        XCTAssertTrue(mockSSHConnection.isClosed)

        // Live Mosh connection is ready
        guard let moshConn = connection as? MoshConnection else {
            XCTFail("Expected MoshConnection")
            return
        }

        let state = await moshConn.moshState
        XCTAssertEqual(state, .connected)
        let info = await moshConn.sessionInfo
        XCTAssertEqual(info.udpPort, 60030)
        XCTAssertEqual(info.pid, 777)
        XCTAssertEqual(info.sessionKey.base64String, "KeyMockLive1234567890")

        await connection.close()
        XCTAssertTrue(info.sessionKey.isZeroized)
        XCTAssertEqual(channelBox.get()?.currentPort, 60030)
    }
}
