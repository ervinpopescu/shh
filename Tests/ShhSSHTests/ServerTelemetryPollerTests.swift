import XCTest
import ShhCore
@testable import ShhSSH

final class ServerTelemetryPollerTests: XCTestCase {

    private final class CommandBox: @unchecked Sendable {
        var command: String?
    }

    private struct MockCommandExecutor: SSHCommandExecuting {
        let handler: @Sendable (String) throws -> SSHCommandResult

        func executeCommand(_ command: String) async throws -> SSHCommandResult {
            try handler(command)
        }

        func executeCommand(_ command: String, timeout: TimeInterval?, maxOutputBytes: Int?) async throws -> SSHCommandResult {
            try handler(command)
        }
    }

    func testFetchTelemetryHappyPath() async throws {
        let output = """
        0.15 0.20 0.10 1/120 4321
        MemTotal:        8388608 kB
        MemFree:         1048576 kB
        MemAvailable:    4194304 kB
         10:00:00 up 2 days, 1:30, 1 user, load average: 0.15, 0.20, 0.10
        """

        let box = CommandBox()
        let executor = MockCommandExecutor { cmd in
            box.command = cmd
            return SSHCommandResult(
                exitCode: 0,
                stdout: output,
                stderr: ""
            )
        }

        let poller = ServerTelemetryPoller(executor: executor)
        let telemetry = try await poller.fetchTelemetry()

        XCTAssertEqual(box.command, ServerTelemetryPoller.defaultCommand)
        XCTAssertEqual(telemetry.loadAverage?.0 ?? 0, 0.15, accuracy: 0.001)
        XCTAssertEqual(telemetry.loadAverage?.1 ?? 0, 0.20, accuracy: 0.001)
        XCTAssertEqual(telemetry.loadAverage?.2 ?? 0, 0.10, accuracy: 0.001)
        XCTAssertEqual(telemetry.memoryTotalBytes, 8388608 * 1024)
        XCTAssertEqual(telemetry.memoryUsedBytes, (8388608 - 4194304) * 1024)
        let expectedUptime: TimeInterval = 178_200.0 // 2d 1h 30m
        XCTAssertEqual(telemetry.uptimeSeconds, expectedUptime)
        XCTAssertEqual(telemetry.formattedUptime, "2d 1h")
    }

    func testFetchTelemetryRejectsUnsafeCommand() async {
        let executor = MockCommandExecutor { _ in
            return SSHCommandResult(exitCode: 0, stdout: "", stderr: "")
        }

        let poller = ServerTelemetryPoller(executor: executor, command: "rm -rf /")
        do {
            _ = try await poller.fetchTelemetry()
            XCTFail("Expected command policy rejection error")
        } catch let error as ServerTelemetryError {
            XCTAssertEqual(error, .commandPolicyRejected("rm -rf /"))
        } catch {
            XCTFail("Unexpected error type: \(error)")
        }
    }

    func testPollingLifecycle() async throws {
        let expectation = expectation(description: "Telemetry poller update received")

        let executor = MockCommandExecutor { _ in
            return SSHCommandResult(
                exitCode: 0,
                stdout: "0.10 0.10 0.10 1/100 1234\nMemTotal: 1024 kB\nMemFree: 512 kB\n",
                stderr: ""
            )
        }

        let poller = ServerTelemetryPoller(executor: executor, interval: 0.05)
        XCTAssertFalse(poller.isPolling)

        poller.startPolling(interval: 0.05) { telemetry in
            if telemetry.loadAverage != nil {
                expectation.fulfill()
            }
        }

        XCTAssertTrue(poller.isPolling)
        await fulfillment(of: [expectation], timeout: 2.0)

        poller.stopPolling()
        XCTAssertFalse(poller.isPolling)
    }
}
