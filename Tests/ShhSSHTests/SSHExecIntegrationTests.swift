import XCTest
import Crypto
import NIOCore
@preconcurrency import NIOSSH
@testable import ShhSSH
@testable import ShhCore

final class SSHExecIntegrationTests: XCTestCase {

    private func makeConnectedClient(
        server: SSHTestServer,
        redactor: Redactor = Redactor(),
        keepaliveInterval: TimeInterval = 30.0,
        keepaliveTimeout: TimeInterval = 8.0
    ) async throws -> (LiveSSHTransport, LiveSSHConnection) {
        let credStore = InMemoryCredentialStore()
        try await credStore.save(Data("testpassword".utf8), reference: "ref-pass")
        let identity = try IdentityDescriptor(name: "Test Pass", kind: .password, keychainReference: "ref-pass")

        let trustStore = InMemoryTrustStore()
        let challenge = HostKeyChallenge(
            hostname: "127.0.0.1",
            port: server.port,
            algorithm: "ssh-ed25519",
            fingerprint: server.fingerprint
        )
        await trustStore.save(challenge)

        let transport = LiveSSHTransport(
            credentialStore: credStore,
            keepaliveInterval: keepaliveInterval,
            keepaliveTimeout: keepaliveTimeout
        )
        let host = try ShhCore.Host(
            name: "Localhost",
            hostname: "127.0.0.1",
            port: server.port,
            username: "testuser",
            identityID: identity.id,
            connection: .ssh(SSHOptions(connectTimeoutSeconds: 5, strictHostKeyChecking: .trustedOnly))
        )

        let rawConnection = try await transport.connect(host: host, identity: identity, trustEvaluator: trustStore)
        guard let connection = rawConnection as? LiveSSHConnection else {
            XCTFail("Expected LiveSSHConnection")
            throw TransportError.remoteFailure("Cast failed")
        }
        connection.setRedactor(redactor)
        return (transport, connection)
    }

    // MARK: - 1. Success

    func testIdleKeepaliveDoesNotPolluteTerminalOutput() async throws {
        let server = SSHTestServer()
        _ = try await server.start()
        addTeardownBlock { try await server.stop() }

        let (_, connection) = try await makeConnectedClient(
            server: server,
            keepaliveInterval: 0.01,
            keepaliveTimeout: 0.2
        )
        addTeardownBlock { await connection.close() }
        let events = await connection.events()
        let output = AtomicBox<Data>(Data())
        let task = Task {
            for try await event in events {
                if case .bytes(let bytes) = event {
                    var current = output.get()
                    current.append(bytes)
                    output.set(current)
                }
            }
        }
        // Drain the normal shell banner before checking probe traffic.
        try await Task.sleep(nanoseconds: 50_000_000)
        output.set(Data())
        try await Task.sleep(nanoseconds: 400_000_000)
        task.cancel()

        XCTAssertGreaterThan(server.globalRequestCount, 0, "Idle SSH must send a protocol liveness probe")
        XCTAssertTrue(output.get().isEmpty, "Keepalive packets must never enter PTY output")
        let result = try await connection.executeCommand("tmux -V")
        XCTAssertTrue(result.isSuccess, "An idle session must remain usable after keepalive probes")
    }

    func testExecSuccess() async throws {
        let server = SSHTestServer()
        _ = try await server.start()
        addTeardownBlock { try await server.stop() }

        let (_, connection) = try await makeConnectedClient(server: server)
        addTeardownBlock { await connection.close() }

        let result = try await connection.executeCommand("tmux -V")
        XCTAssertTrue(result.isSuccess)
        XCTAssertEqual(result.exitCode, 0)
        XCTAssertEqual(result.stdout, "tmux 3.4\n")
        XCTAssertTrue(result.stderr.isEmpty)

        let availability = TmuxAvailability.parse(result: result)
        XCTAssertTrue(availability.isAvailable)
        XCTAssertEqual(availability.version, "tmux 3.4")
    }

    // MARK: - 2. Nonzero Exit

    func testExecNonzeroExit() async throws {
        let server = SSHTestServer()
        _ = try await server.start()
        addTeardownBlock { try await server.stop() }

        let (_, connection) = try await makeConnectedClient(server: server)
        addTeardownBlock { await connection.close() }

        let result = try await connection.executeCommand("exit 42")
        XCTAssertFalse(result.isSuccess)
        XCTAssertEqual(result.exitCode, 42)
        XCTAssertTrue(result.stderr.contains("code 42"))
    }

    // MARK: - 3. No Sessions

    func testExecNoSessions() async throws {
        let server = SSHTestServer()
        _ = try await server.start()
        addTeardownBlock { try await server.stop() }

        let (_, connection) = try await makeConnectedClient(server: server)
        addTeardownBlock { await connection.close() }

        let result = try await connection.executeCommand("tmux list-sessions no-sessions")
        XCTAssertFalse(result.isSuccess)
        XCTAssertEqual(result.exitCode, 1)
        XCTAssertTrue(result.stderr.contains("no server running"))

        let availability = TmuxAvailability.parse(result: result)
        XCTAssertFalse(availability.isAvailable)
        if case .unavailable(let reason) = availability {
            XCTAssertTrue(reason.contains("no server running"))
        } else {
            XCTFail("Expected unavailable")
        }
    }

    // MARK: - 4. Timeout

    func testExecTimeout() async throws {
        let server = SSHTestServer()
        _ = try await server.start()
        addTeardownBlock { try await server.stop() }

        let (_, connection) = try await makeConnectedClient(server: server)
        addTeardownBlock { await connection.close() }

        do {
            _ = try await connection.executeCommand("timeout-delay", timeout: 0.05)
            XCTFail("Expected timeout error")
        } catch let error as TransportError {
            XCTAssertEqual(error, TransportError.timeout)
        }

        // Connection should remain usable after command timeout
        let followUp = try await connection.executeCommand("tmux -V")
        XCTAssertTrue(followUp.isSuccess)
    }

    // MARK: - 5. Cancellation

    func testExecCancellation() async throws {
        let server = SSHTestServer()
        _ = try await server.start()
        addTeardownBlock { try await server.stop() }

        let (_, connection) = try await makeConnectedClient(server: server)
        addTeardownBlock { await connection.close() }

        let task = Task {
            try await connection.executeCommand("delayed", timeout: 10.0)
        }

        // Allow child channel creation and outbound exec request to dispatch
        try await Task.sleep(nanoseconds: 50_000_000)
        task.cancel()

        do {
            _ = try await task.value
            XCTFail("Expected cancellation error")
        } catch let error as TransportError {
            XCTAssertEqual(error, TransportError.cancelled)
        } catch is CancellationError {
            // Also acceptable Swift cancellation representation
        }
    }

    // MARK: - 6. Missing Exit Status

    func testExecMissingExitStatus() async throws {
        let server = SSHTestServer()
        _ = try await server.start()
        addTeardownBlock { try await server.stop() }

        let (_, connection) = try await makeConnectedClient(server: server)
        addTeardownBlock { await connection.close() }

        do {
            _ = try await connection.executeCommand("missing-exit-status")
            XCTFail("Expected missing exit status error")
        } catch let TransportError.remoteFailure(message) {
            XCTAssertTrue(message.contains("without exit status"), "Error message should identify missing exit status: \(message)")
        }
    }

    // MARK: - 7. Output Bound

    func testExecOutputBound() async throws {
        let server = SSHTestServer()
        _ = try await server.start()
        addTeardownBlock { try await server.stop() }

        let (_, connection) = try await makeConnectedClient(server: server)
        addTeardownBlock { await connection.close() }

        do {
            _ = try await connection.executeCommand("large-output", timeout: 5.0, maxOutputBytes: 1024)
            XCTFail("Expected output bound exceeded error")
        } catch let TransportError.remoteFailure(message) {
            XCTAssertTrue(message.contains("exceeded"), "Message should mention exceeded limit: \(message)")
        }
    }

    // MARK: - 8. Concurrent PTY + Exec

    func testConcurrentPTYAndExec() async throws {
        let server = SSHTestServer()
        _ = try await server.start()
        addTeardownBlock { try await server.stop() }

        let (_, connection) = try await makeConnectedClient(server: server)
        addTeardownBlock { await connection.close() }

        // Start listening to interactive terminal stream
        let events = await connection.events()
        let receivedBytes = AtomicBox<[Data]>([])
        let streamTask = Task {
            do {
                for try await event in events {
                    if case .bytes(let data) = event {
                        var list = receivedBytes.get()
                        list.append(data)
                        receivedBytes.set(list)
                    }
                }
            } catch {}
        }
        addTeardownBlock { streamTask.cancel() }

        // Send interactive keystrokes
        try await connection.send(Data("hello-pty\n".utf8))

        // Concurrently execute multiple exec commands
        async let r1 = connection.executeCommand("tmux -V")
        async let r2 = connection.executeCommand("tmux list-sessions")
        async let r3 = connection.executeCommand("echo concurrent-command")

        let (res1, res2, res3) = try await (r1, r2, r3)

        XCTAssertTrue(res1.isSuccess)
        XCTAssertEqual(res1.stdout, "tmux 3.4\n")

        XCTAssertTrue(res2.isSuccess)
        let sessions = try TmuxListSessionsParser.parse(res2.stdout)
        XCTAssertEqual(sessions.count, 2)
        XCTAssertEqual(sessions[0].sessionID, "$0")
        XCTAssertEqual(sessions[0].name, "main")
        XCTAssertEqual(sessions[1].sessionID, "$1")
        XCTAssertEqual(sessions[1].name, "dev")

        XCTAssertTrue(res3.isSuccess)
        XCTAssertTrue(res3.stdout.contains("concurrent-command"))

        // Send additional interactive keystrokes to verify PTY remains alive
        try await connection.send(Data("more-pty\n".utf8))
        try await Task.sleep(nanoseconds: 50_000_000)

        let combinedData = receivedBytes.get().reduce(Data(), +)
        let interactiveText = String(decoding: combinedData, as: UTF8.self)
        XCTAssertTrue(interactiveText.contains("hello-pty"))
        XCTAssertTrue(interactiveText.contains("more-pty"))
    }

    // MARK: - 9. Zero Terminal Pollution

    func testZeroTerminalPollution() async throws {
        let server = SSHTestServer()
        _ = try await server.start()
        addTeardownBlock { try await server.stop() }

        let (_, connection) = try await makeConnectedClient(server: server)
        addTeardownBlock { await connection.close() }

        let events = await connection.events()
        let receivedChunks = AtomicBox<[Data]>([])
        let streamTask = Task {
            do {
                for try await event in events {
                    if case .bytes(let data) = event {
                        var current = receivedChunks.get()
                        current.append(data)
                        receivedChunks.set(current)
                    }
                }
            } catch {}
        }
        addTeardownBlock { streamTask.cancel() }

        // Execute distinct exec commands
        let execUniqueMarker = "EXEC_CHANNEL_EXCLUSIVE_SECRET_DATA_12345"
        let r1 = try await connection.executeCommand("echo \(execUniqueMarker)")
        XCTAssertTrue(r1.isSuccess)
        XCTAssertTrue(r1.stdout.contains(execUniqueMarker))

        let r2 = try await connection.executeCommand("tmux -V")
        XCTAssertTrue(r2.isSuccess)
        XCTAssertTrue(r2.stdout.contains("tmux 3.4"))

        // Send interactive data
        let ptyMarker = "INTERACTIVE_TERMINAL_ECHO_TOKEN_67890"
        try await connection.send(Data("\(ptyMarker)\n".utf8))

        // Wait for interactive data echo to be collected
        var attempts = 0
        while attempts < 20 {
            let text = String(decoding: receivedChunks.get().reduce(Data(), +), as: UTF8.self)
            if text.contains(ptyMarker) { break }
            try await Task.sleep(nanoseconds: 25_000_000)
            attempts += 1
        }

        let allInteractiveBytes = receivedChunks.get().reduce(Data(), +)
        let interactiveStreamText = String(decoding: allInteractiveBytes, as: UTF8.self)

        // Verify interactive data arrived
        XCTAssertTrue(interactiveStreamText.contains(ptyMarker), "Interactive stream must contain interactive echoed data")

        // CRITICAL: Guarantee zero bytes leaked from exec into interactive terminal stream
        XCTAssertFalse(
            interactiveStreamText.contains(execUniqueMarker),
            "ZERO BYTES LEAK GUARANTEE: interactive stream must not contain exec command output"
        )
        XCTAssertFalse(
            interactiveStreamText.contains("tmux 3.4"),
            "ZERO BYTES LEAK GUARANTEE: interactive stream must not contain tmux probe output"
        )
    }

    // MARK: - 10. Redacted Errors

    func testRedactedErrors() async throws {
        let server = SSHTestServer()
        _ = try await server.start()
        addTeardownBlock { try await server.stop() }

        let secretToken = "super-secret-password-xyz"
        let redactor = Redactor(secrets: [secretToken])
        let (_, connection) = try await makeConnectedClient(server: server, redactor: redactor)
        addTeardownBlock { await connection.close() }

        // Configure server to emit an error mentioning the secret
        server.execHandler = { cmd in
            SSHCommandTestResponse(
                exitCode: 1,
                stdout: "",
                stderr: "fatal: authentication failure for token \(secretToken) on remote host\n"
            )
        }

        let result = try await connection.executeCommand("failing-cmd")
        XCTAssertFalse(result.isSuccess)
        XCTAssertFalse(result.stderr.contains(secretToken), "Secret must be redacted from stderr")
        XCTAssertTrue(result.stderr.contains("[REDACTED]"), "Redacted placeholder must appear in stderr")

        // Also test thrown remote failure redaction
        server.execHandler = { cmd in
            SSHCommandTestResponse(
                rejectExec: true
            )
        }

        // Test thrown remoteFailure when exec is rejected
        do {
            _ = try await connection.executeCommand("rejected-cmd")
            XCTFail("Expected exec rejection error")
        } catch let TransportError.remoteFailure(message) {
            XCTAssertFalse(message.contains(secretToken))
        }
    }

    // MARK: - 11. Deterministic Server Behaviors

    func testDeterministicServerTmuxBehaviors() async throws {
        let server = SSHTestServer()
        _ = try await server.start()
        addTeardownBlock { try await server.stop() }

        let (_, connection) = try await makeConnectedClient(server: server)
        addTeardownBlock { await connection.close() }

        // has-session existing
        let hasZero = try await connection.executeCommand(TmuxCommand.hasSession(id: "$0"))
        XCTAssertTrue(hasZero.isSuccess)
        XCTAssertEqual(hasZero.exitCode, 0)

        // has-session missing
        let has99 = try await connection.executeCommand(TmuxCommand.hasSession(id: "$99"))
        XCTAssertFalse(has99.isSuccess)
        XCTAssertEqual(has99.exitCode, 1)
        XCTAssertTrue(has99.stderr.contains("can't find session"))

        // not-installed mode
        server.execMode = .notInstalled
        let notInstalledResult = try await connection.executeCommand("tmux -V")
        XCTAssertFalse(notInstalledResult.isSuccess)
        XCTAssertEqual(notInstalledResult.exitCode, 127)
        let unavailable = TmuxAvailability.parse(result: notInstalledResult)
        XCTAssertFalse(unavailable.isAvailable)
        if case .unavailable(let reason) = unavailable {
            XCTAssertTrue(reason.contains("not found"))
        } else {
            XCTFail("Expected unavailable")
        }

        // malformed output mode
        server.execMode = .malformed
        let malformedResult = try await connection.executeCommand(TmuxCommand.listSessions)
        XCTAssertTrue(malformedResult.isSuccess)
        XCTAssertThrowsError(try TmuxListSessionsParser.parse(malformedResult.stdout)) { error in
            XCTAssertTrue(error is TmuxParseError)
        }

        // no-server mode
        server.execMode = .noServer
        let noServerResult = try await connection.executeCommand(TmuxCommand.listSessions)
        XCTAssertFalse(noServerResult.isSuccess)
        XCTAssertEqual(noServerResult.exitCode, 1)
        XCTAssertTrue(noServerResult.stderr.contains("no server running"))
    }

    // MARK: - 12. Demo SSH Connection

    func testDemoSSHConnectionExecution() async throws {
        let demo = DemoSSHConnection()

        // Probe
        let probeResult = try await demo.executeCommand(TmuxCommand.probe)
        XCTAssertTrue(probeResult.isSuccess)
        XCTAssertEqual(probeResult.stdout, "tmux 3.4\n")

        // List
        let listResult = try await demo.executeCommand(TmuxCommand.listSessions)
        XCTAssertTrue(listResult.isSuccess)
        let sessions = try TmuxListSessionsParser.parse(listResult.stdout)
        XCTAssertEqual(sessions.count, 1)
        XCTAssertEqual(sessions[0].sessionID, "$0")

        // Has session existing
        let has0 = try await demo.executeCommand(TmuxCommand.hasSession(id: "$0"))
        XCTAssertTrue(has0.isSuccess)

        // Has session missing
        let has99 = try await demo.executeCommand(TmuxCommand.hasSession(id: "$99"))
        XCTAssertFalse(has99.isSuccess)
        XCTAssertEqual(has99.exitCode, 1)

        // Output bound limit
        do {
            _ = try await demo.executeCommand("echo test", timeout: nil, maxOutputBytes: 3)
            XCTFail("Expected output bound error")
        } catch let TransportError.remoteFailure(msg) {
            XCTAssertTrue(msg.contains("exceeded"))
        }

        // Custom handler
        await demo.setCommandHandler { cmd in
            SSHCommandResult(exitCode: 7, stdout: "custom", stderr: "custom-err")
        }
        let customRes = try await demo.executeCommand("anything")
        XCTAssertEqual(customRes.exitCode, 7)
        XCTAssertEqual(customRes.stdout, "custom")
        XCTAssertEqual(customRes.stderr, "custom-err")

        await demo.close()
    }
}
