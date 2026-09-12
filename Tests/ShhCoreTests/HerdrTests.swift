import XCTest
import Foundation
@testable import ShhCore

final class HerdrTests: XCTestCase {

    // MARK: - 1. HerdrAgentState Domain Model Tests

    func testAgentStatePropertiesAndPredicates() {
        let idle = HerdrAgentState.idle
        XCTAssertTrue(idle.isIdle)
        XCTAssertFalse(idle.isWorking)
        XCTAssertFalse(idle.isBlocked)
        XCTAssertFalse(idle.isCompleted)
        XCTAssertEqual(idle.statusName, "idle")
        XCTAssertNil(idle.blockedReason)
        XCTAssertNil(idle.completedSummary)

        let working = HerdrAgentState.working
        XCTAssertFalse(working.isIdle)
        XCTAssertTrue(working.isWorking)
        XCTAssertFalse(working.isBlocked)
        XCTAssertFalse(working.isCompleted)
        XCTAssertEqual(working.statusName, "working")
        XCTAssertNil(working.blockedReason)
        XCTAssertNil(working.completedSummary)

        let blocked = HerdrAgentState.blocked(reason: "Waiting for human approval")
        XCTAssertFalse(blocked.isIdle)
        XCTAssertFalse(blocked.isWorking)
        XCTAssertTrue(blocked.isBlocked)
        XCTAssertFalse(blocked.isCompleted)
        XCTAssertEqual(blocked.statusName, "blocked")
        XCTAssertEqual(blocked.blockedReason, "Waiting for human approval")
        XCTAssertNil(blocked.completedSummary)

        let completed = HerdrAgentState.completed(summary: "All 42 tests passed")
        XCTAssertFalse(completed.isIdle)
        XCTAssertFalse(completed.isWorking)
        XCTAssertFalse(completed.isBlocked)
        XCTAssertTrue(completed.isCompleted)
        XCTAssertEqual(completed.statusName, "completed")
        XCTAssertNil(completed.blockedReason)
        XCTAssertEqual(completed.completedSummary, "All 42 tests passed")
    }

    func testAgentStateCodableRoundTrip() throws {
        let states: [HerdrAgentState] = [
            .idle,
            .working,
            .blocked(reason: "Needs token"),
            .completed(summary: "Build green")
        ]

        let encoder = JSONEncoder()
        let decoder = JSONDecoder()

        for state in states {
            let data = try encoder.encode(state)
            let decoded = try decoder.decode(HerdrAgentState.self, from: data)
            XCTAssertEqual(decoded, state)
        }
    }

    func testAgentStateFlexibleDecoding() throws {
        let decoder = JSONDecoder()

        // Single string decoding
        let idleFromString = try decoder.decode(HerdrAgentState.self, from: Data("\"idle\"".utf8))
        XCTAssertEqual(idleFromString, .idle)

        let workingFromString = try decoder.decode(HerdrAgentState.self, from: Data("\"working\"".utf8))
        XCTAssertEqual(workingFromString, .working)

        let blockedFromString = try decoder.decode(HerdrAgentState.self, from: Data("\"blocked: DB locked\"".utf8))
        XCTAssertEqual(blockedFromString, .blocked(reason: "DB locked"))

        let completedFromString = try decoder.decode(HerdrAgentState.self, from: Data("\"completed: done\"".utf8))
        XCTAssertEqual(completedFromString, .completed(summary: "done"))

        // Alternative key decoding (e.g. "state" and "message")
        let altBlockedJSON = "{\"state\": \"blocked\", \"message\": \"Waiting on network\"}"
        let altBlocked = try decoder.decode(HerdrAgentState.self, from: Data(altBlockedJSON.utf8))
        XCTAssertEqual(altBlocked, .blocked(reason: "Waiting on network"))

        let altCompletedJSON = "{\"state\": \"completed\", \"message\": \"Finished in 2s\"}"
        let altCompleted = try decoder.decode(HerdrAgentState.self, from: Data(altCompletedJSON.utf8))
        XCTAssertEqual(altCompleted, .completed(summary: "Finished in 2s"))
    }

    // MARK: - 2. HerdrPane and HerdrWorkspace Models

    func testHerdrPanePropertiesAndCodable() throws {
        let timestamp = Date(timeIntervalSince1970: 1700000000)
        let pane = HerdrPane(
            id: "pane-1",
            label: "editor",
            agentState: .blocked(reason: "Needs write permission"),
            currentCommand: "vim /etc/hosts",
            lastActivity: timestamp
        )

        XCTAssertEqual(pane.id, "pane-1")
        XCTAssertEqual(pane.label, "editor")
        XCTAssertEqual(pane.agentState, .blocked(reason: "Needs write permission"))
        XCTAssertEqual(pane.currentCommand, "vim /etc/hosts")
        XCTAssertEqual(pane.lastActivity, timestamp)

        let encoder = JSONEncoder()
        let decoder = JSONDecoder()
        let data = try encoder.encode(pane)
        let decoded = try decoder.decode(HerdrPane.self, from: data)

        XCTAssertEqual(decoded.id, pane.id)
        XCTAssertEqual(decoded.label, pane.label)
        XCTAssertEqual(decoded.agentState, pane.agentState)
        XCTAssertEqual(decoded.currentCommand, pane.currentCommand)
    }

    func testHerdrWorkspaceWithFourStates() throws {
        let now = Date(timeIntervalSince1970: 1700000000)
        let p1 = HerdrPane(id: "p1", label: "idle-pane", agentState: .idle, currentCommand: nil, lastActivity: now)
        let p2 = HerdrPane(id: "p2", label: "work-pane", agentState: .working, currentCommand: "cargo build", lastActivity: now)
        let p3 = HerdrPane(id: "p3", label: "block-pane", agentState: .blocked(reason: "OAuth prompt"), currentCommand: "gh auth login", lastActivity: now)
        let p4 = HerdrPane(id: "p4", label: "done-pane", agentState: .completed(summary: "0 failures"), currentCommand: "cargo test", lastActivity: now)

        let workspace = HerdrWorkspace(
            id: "ws-1",
            label: "core-dev",
            cwd: "/home/user/project",
            panes: [p1, p2, p3, p4]
        )

        XCTAssertEqual(workspace.id, "ws-1")
        XCTAssertEqual(workspace.label, "core-dev")
        XCTAssertEqual(workspace.cwd, "/home/user/project")
        XCTAssertEqual(workspace.panes.count, 4)

        let encoder = JSONEncoder()
        let decoder = JSONDecoder()
        let data = try encoder.encode(workspace)
        let decoded = try decoder.decode(HerdrWorkspace.self, from: data)

        XCTAssertEqual(decoded.id, workspace.id)
        XCTAssertEqual(decoded.label, workspace.label)
        XCTAssertEqual(decoded.cwd, workspace.cwd)
        XCTAssertEqual(decoded.panes.count, 4)
        XCTAssertEqual(decoded.panes[0].agentState, .idle)
        XCTAssertEqual(decoded.panes[1].agentState, .working)
        XCTAssertEqual(decoded.panes[2].agentState, .blocked(reason: "OAuth prompt"))
        XCTAssertEqual(decoded.panes[3].agentState, .completed(summary: "0 failures"))
    }

    // MARK: - 3. HerdrAvailability Model Tests

    func testHerdrAvailability() {
        let avail = HerdrAvailability.available(version: "herdr 0.1.0")
        XCTAssertTrue(avail.isAvailable)
        XCTAssertEqual(avail.version, "herdr 0.1.0")
        XCTAssertNil(avail.unavailableReason)
        XCTAssertEqual(avail.capability, .available)

        let unavail = HerdrAvailability.unavailable(reason: "herdr: command not found")
        XCTAssertFalse(unavail.isAvailable)
        XCTAssertNil(unavail.version)
        XCTAssertEqual(unavail.unavailableReason, "herdr: command not found")
        XCTAssertEqual(unavail.capability, .unavailable(reason: "herdr: command not found"))

        // Parsing from command output and exit code
        let parsedAvail = HerdrAvailability.parse(output: "herdr 0.2.1\n", exitCode: 0)
        XCTAssertEqual(parsedAvail, .available(version: "herdr 0.2.1"))

        let parsedEmpty = HerdrAvailability.parse(output: "   \n", exitCode: 0)
        XCTAssertEqual(parsedEmpty, .unavailable(reason: "Empty probe output"))

        let parsedError = HerdrAvailability.parse(output: "not found\n", exitCode: 127)
        XCTAssertEqual(parsedError, .unavailable(reason: "not found"))

        // Parsing from SSHCommandResult
        let successResult = SSHCommandResult(exitCode: 0, stdout: "herdr 0.3.0\n")
        XCTAssertEqual(HerdrAvailability.parse(result: successResult), .available(version: "herdr 0.3.0"))

        let failResult = SSHCommandResult(exitCode: 1, stdout: "", stderr: "permission denied")
        XCTAssertEqual(HerdrAvailability.parse(result: failResult), .unavailable(reason: "permission denied"))
    }

    // MARK: - 4. HerdrCommand Templates

    func testHerdrCommandTemplates() {
        XCTAssertEqual(HerdrCommand.base.renderedCommand, "herdr")
        XCTAssertEqual(HerdrCommand.probe, "herdr --version")
        XCTAssertEqual(HerdrCommand.remote(host: "server1").renderedCommand, "herdr --remote 'server1'")
        XCTAssertEqual(HerdrCommand.remoteLaunch(workbox: "box").renderedCommand, "herdr --remote 'box'")

        XCTAssertEqual(
            HerdrCommand.workspaceCreate(cwd: "/var/www", label: "staging").renderedCommand,
            "herdr workspace create --cwd '/var/www' --label 'staging'"
        )
        XCTAssertEqual(
            HerdrCommand.tabCreate(label: "logs").renderedCommand,
            "herdr tab create --label 'logs'"
        )
        XCTAssertEqual(
            HerdrCommand.paneSplit(pane: "p1", direction: "right").renderedCommand,
            "herdr pane split 'p1' --direction 'right'"
        )
        XCTAssertEqual(
            HerdrCommand.paneRun(pane: "p1", command: "npm start").renderedCommand,
            "herdr pane run 'p1' 'npm start'"
        )
        XCTAssertEqual(
            HerdrCommand.paneRead(pane: "p1", source: "recent-unwrapped").renderedCommand,
            "herdr pane read 'p1' --source 'recent-unwrapped'"
        )
        XCTAssertEqual(
            HerdrCommand.waitAgentStatus(pane: "p1", status: "done").renderedCommand,
            "herdr wait agent-status 'p1' --status 'done'"
        )
        XCTAssertEqual(
            HerdrCommand.waitAgentStatus.renderedCommand,
            "herdr wait agent-status"
        )
        XCTAssertEqual(
            HerdrCommand.workspaceList().renderedCommand,
            "herdr workspace list --format 'json'"
        )
        XCTAssertEqual(
            HerdrCommand.paneList().renderedCommand,
            "herdr pane list --format 'json'"
        )
        XCTAssertEqual(
            HerdrCommand.paneList(workspace: "ws1").renderedCommand,
            "herdr pane list 'ws1' --format 'json'"
        )
        XCTAssertEqual(
            HerdrCommand.status().renderedCommand,
            "herdr status --format 'json'"
        )
        XCTAssertEqual(
            HerdrCommand.version.renderedCommand,
            "herdr --version"
        )
    }

    func testHerdrCommandQuotingSafety() {
        let maliciousLabel = "test'; rm -rf /; echo '"
        let command = HerdrCommand.workspaceCreate(cwd: "/home", label: maliciousLabel)
        XCTAssertTrue(command.renderedCommand.contains(ShellQuoting.quote(maliciousLabel)))
    }

    // MARK: - 5. HerdrOutputParser Tests

    func testParseWorkspacesJSON() throws {
        let json = """
        [
          {
            "id": "ws-1",
            "label": "primary",
            "cwd": "/src/shh",
            "panes": [
              {
                "id": "p-idle",
                "label": "shell",
                "agentState": { "status": "idle" },
                "currentCommand": null,
                "lastActivity": "2026-09-12T19:00:00Z"
              },
              {
                "id": "p-work",
                "label": "compiler",
                "agentState": { "status": "working" },
                "currentCommand": "swift build",
                "lastActivity": "2026-09-12T19:01:00Z"
              },
              {
                "id": "p-block",
                "label": "migration",
                "agentState": { "status": "blocked", "reason": "confirmation required" },
                "currentCommand": "migrate-db",
                "lastActivity": "2026-09-12T19:02:00Z"
              },
              {
                "id": "p-done",
                "label": "test",
                "agentState": { "status": "completed", "summary": "tests green" },
                "currentCommand": "swift test",
                "lastActivity": "2026-09-12T19:03:00Z"
              }
            ]
          }
        ]
        """

        let workspaces = try HerdrOutputParser.parseWorkspaces(from: json)
        XCTAssertEqual(workspaces.count, 1)
        XCTAssertEqual(workspaces[0].id, "ws-1")
        XCTAssertEqual(workspaces[0].label, "primary")
        XCTAssertEqual(workspaces[0].cwd, "/src/shh")
        XCTAssertEqual(workspaces[0].panes.count, 4)

        XCTAssertEqual(workspaces[0].panes[0].agentState, .idle)
        XCTAssertEqual(workspaces[0].panes[1].agentState, .working)
        XCTAssertEqual(workspaces[0].panes[2].agentState, .blocked(reason: "confirmation required"))
        XCTAssertEqual(workspaces[0].panes[3].agentState, .completed(summary: "tests green"))
    }

    func testParseWorkspacesWrappedObject() throws {
        let json = """
        {
          "workspaces": [
            {
              "id": "ws-2",
              "label": "backend",
              "cwd": "/tmp",
              "panes": []
            }
          ]
        }
        """

        let workspaces = try HerdrOutputParser.parseWorkspaces(from: json)
        XCTAssertEqual(workspaces.count, 1)
        XCTAssertEqual(workspaces[0].id, "ws-2")
    }

    func testParsePanesDirectAndWrapped() throws {
        let json = """
        [
          {
            "id": "p1",
            "label": "dev",
            "agentState": "working",
            "currentCommand": "go run main.go"
          }
        ]
        """
        let panes = try HerdrOutputParser.parsePanes(from: json)
        XCTAssertEqual(panes.count, 1)
        XCTAssertEqual(panes[0].id, "p1")
        XCTAssertEqual(panes[0].agentState, .working)
    }

    func testParseAgentStateNeverScrapesColors() throws {
        // Semantic structured string
        let state1 = try HerdrOutputParser.parseAgentState(from: "idle")
        XCTAssertEqual(state1, .idle)

        let state2 = try HerdrOutputParser.parseAgentState(from: "working")
        XCTAssertEqual(state2, .working)

        let state3 = try HerdrOutputParser.parseAgentState(from: "blocked: Need OAuth authorization")
        XCTAssertEqual(state3, .blocked(reason: "Need OAuth authorization"))

        let state4 = try HerdrOutputParser.parseAgentState(from: "completed: 100% build pass")
        XCTAssertEqual(state4, .completed(summary: "100% build pass"))

        // Even with ANSI color codes present, colors are stripped and semantic text is used
        let ansiState = try HerdrOutputParser.parseAgentState(from: "\u{001B}[32mcompleted: all passed\u{001B}[0m")
        XCTAssertEqual(ansiState, .completed(summary: "all passed"))

        // If arbitrary text with green color is passed, it fails to parse as state; NEVER guesses completed from color
        XCTAssertThrowsError(try HerdrOutputParser.parseAgentState(from: "\u{001B}[32munknown_message\u{001B}[0m")) { error in
            guard let parseErr = error as? HerdrParseError else {
                XCTFail("Expected HerdrParseError")
                return
            }
            XCTAssertEqual(parseErr, .invalidState("unknown_message"))
        }
    }

    func testParseRecentUnwrapped() {
        let raw = "Line 1\r\nLine 2\r\nLine 3\r\n"
        let parsed = HerdrOutputParser.parseRecentUnwrapped(from: raw)
        XCTAssertEqual(parsed, "Line 1\nLine 2\nLine 3\n")

        let jsonWrapper = "{\"output\": \"Unwrapped pane content\\r\\nSecond line\\r\\n\"}"
        let parsedJSON = HerdrOutputParser.parseRecentUnwrapped(from: jsonWrapper)
        XCTAssertEqual(parsedJSON, "Unwrapped pane content\nSecond line\n")

        let textWrapper = "{\"text\": \"Line A\\r\\nLine B\\r\\n\"}"
        let parsedText = HerdrOutputParser.parseRecentUnwrapped(from: textWrapper)
        XCTAssertEqual(parsedText, "Line A\nLine B\n")

        let contentWrapper = "{\"content\": \"Alpha\\r\\nBeta\\r\\n\"}"
        let parsedContent = HerdrOutputParser.parseRecentUnwrapped(from: contentWrapper)
        XCTAssertEqual(parsedContent, "Alpha\nBeta\n")

        let linesWrapper = "{\"lines\": [\"First\\r\\nsubline\", \"Second\"]}"
        let parsedLines = HerdrOutputParser.parseRecentUnwrapped(from: linesWrapper)
        XCTAssertEqual(parsedLines, "First\nsubline\nSecond")
    }

    func testHerdrParseErrorCases() {
        let empty = HerdrParseError.emptyOutput
        XCTAssertEqual(empty.errorDescription, "Herdr command output was empty.")

        let invalidJSON = HerdrParseError.invalidJSON("corrupt")
        XCTAssertEqual(invalidJSON.errorDescription, "Failed to parse Herdr JSON: corrupt")

        let missing = HerdrParseError.missingRequiredField("id")
        XCTAssertEqual(missing.errorDescription, "Missing required field 'id' in Herdr output.")

        let invalidState = HerdrParseError.invalidState("mysterious")
        XCTAssertEqual(invalidState.errorDescription, "Unknown or invalid Herdr agent state: 'mysterious'")

        let failed = HerdrParseError.executionFailed("pane exited with code 1")
        XCTAssertEqual(failed.errorDescription, "Herdr command failed: pane exited with code 1")
        XCTAssertEqual(failed, HerdrParseError.executionFailed("pane exited with code 1"))
    }

    // MARK: - 6. CommandPolicy Hardening Tests for Herdr

    func testCommandPolicyAllowsSafeHerdrQueries() {
        let policy = CommandPolicy()

        XCTAssertEqual(policy.classify("herdr --version"), .safe)
        XCTAssertEqual(policy.classify("herdr -v"), .safe)
        XCTAssertEqual(policy.classify("herdr workspace list --format json"), .safe)
        XCTAssertEqual(policy.classify("herdr workspace list"), .safe)
        XCTAssertEqual(policy.classify("herdr tab list"), .safe)
        XCTAssertEqual(policy.classify("herdr pane list"), .safe)
        XCTAssertEqual(policy.classify("herdr pane read p1 --source recent-unwrapped"), .safe)
        XCTAssertEqual(policy.classify("herdr wait agent-status p1 --status done"), .safe)
        XCTAssertEqual(policy.classify("herdr wait agent-status"), .safe)
        XCTAssertEqual(policy.classify("herdr agent list"), .safe)
        XCTAssertEqual(policy.classify("herdr agent status"), .safe)
        XCTAssertEqual(policy.classify("herdr status"), .safe)

        XCTAssertTrue(policy.canSend("herdr --version", approved: false))
        XCTAssertTrue(policy.canSend("herdr workspace list --format json", approved: false))
        XCTAssertTrue(policy.canSend("herdr pane read p1 --source recent-unwrapped", approved: false))
    }

    func testCommandPolicyRequiresReviewForHerdrStateMutations() {
        let policy = CommandPolicy()

        XCTAssertEqual(policy.classify("herdr"), .reviewRequired)
        XCTAssertEqual(policy.classify("herdr --remote mybox"), .reviewRequired)
        XCTAssertEqual(policy.classify("herdr workspace create --cwd /app --label myapp"), .reviewRequired)
        XCTAssertEqual(policy.classify("herdr tab create --label logs"), .reviewRequired)
        XCTAssertEqual(policy.classify("herdr pane split p1 --direction right"), .reviewRequired)
        XCTAssertEqual(policy.classify("herdr pane run p1 'echo hello'"), .reviewRequired)
        XCTAssertEqual(policy.classify("herdr pane run p1 'git status'"), .reviewRequired)

        // Without approval, reviewRequired commands cannot be sent
        XCTAssertFalse(policy.canSend("herdr workspace create --cwd /app --label myapp", approved: false))
        // With approval, reviewRequired commands can be sent
        XCTAssertTrue(policy.canSend("herdr workspace create --cwd /app --label myapp", approved: true))
        XCTAssertTrue(policy.canSend("herdr pane run p1 'echo hello'", approved: true))
    }

    func testCommandPolicyBlocksDestructiveHerdrPaneRun() {
        let policy = CommandPolicy()

        // rm -rf / inside pane run
        let rmBlock = "herdr pane run p1 'rm -rf /'"
        XCTAssertEqual(policy.classify(rmBlock), .blocked)
        XCTAssertFalse(policy.canSend(rmBlock, approved: false))
        XCTAssertFalse(policy.canSend(rmBlock, approved: true), "Approval must never override blocked commands")

        // Critical system path deletion
        let rmSystem = "herdr pane run p1 'rm -rf /etc'"
        XCTAssertEqual(policy.classify(rmSystem), .blocked)
        XCTAssertFalse(policy.canSend(rmSystem, approved: true))

        // Disk wiping with dd
        let ddBlock = "herdr pane run p1 'dd if=/dev/zero of=/dev/sda'"
        XCTAssertEqual(policy.classify(ddBlock), .blocked)
        XCTAssertFalse(policy.canSend(ddBlock, approved: true))

        // Disk formatting
        let mkfsBlock = "herdr pane run p1 'mkfs.ext4 /dev/nvme0n1'"
        XCTAssertEqual(policy.classify(mkfsBlock), .blocked)
        XCTAssertFalse(policy.canSend(mkfsBlock, approved: true))

        // Fork bomb
        let forkBomb = "herdr pane run p1 ':(){ :|:& };:'"
        XCTAssertEqual(policy.classify(forkBomb), .blocked)
        XCTAssertFalse(policy.canSend(forkBomb, approved: true))

        // Compound command with destructive part
        let compound = "herdr pane run p1 'echo safe; rm -rf /'"
        XCTAssertEqual(policy.classify(compound), .blocked)
        XCTAssertFalse(policy.canSend(compound, approved: true))

        // Unquoted arguments inside pane run
        let unquoted = "herdr pane run p1 rm -rf /"
        XCTAssertEqual(policy.classify(unquoted), .blocked)
        XCTAssertFalse(policy.canSend(unquoted, approved: true))

        // Pane run with no pane id
        let noPane = "herdr pane run 'rm -rf /'"
        XCTAssertEqual(policy.classify(noPane), .blocked)
        XCTAssertFalse(policy.canSend(noPane, approved: true))

        // Global destruction commands
        XCTAssertEqual(policy.classify("herdr kill-server"), .blocked)
        XCTAssertEqual(policy.classify("herdr destroy-all"), .blocked)
    }

    // MARK: - 7. DemoSSHConnection Simulation Tests

    func testDemoSSHConnectionHerdrWorkflow() async throws {
        let conn = DemoSSHConnection()

        // Probe
        let probeResult = try await conn.executeCommand("herdr --version")
        XCTAssertEqual(probeResult.exitCode, 0)
        let avail = HerdrAvailability.parse(result: probeResult)
        XCTAssertEqual(avail, .available(version: "herdr 0.1.0"))

        // Workspaces list
        let listResult = try await conn.executeCommand("herdr workspace list --format json")
        XCTAssertEqual(listResult.exitCode, 0)
        let workspaces = try HerdrOutputParser.parseWorkspaces(from: listResult.stdout)
        XCTAssertFalse(workspaces.isEmpty)

        // Verify all 4 states are present
        let allPanes = workspaces.flatMap(\.panes)
        let states = Set(allPanes.map { $0.agentState.statusName })
        XCTAssertTrue(states.contains("idle"), "Must contain idle state")
        XCTAssertTrue(states.contains("working"), "Must contain working state")
        XCTAssertTrue(states.contains("blocked"), "Must contain blocked state")
        XCTAssertTrue(states.contains("completed"), "Must contain completed state")

        // Output reading
        let readResult = try await conn.executeCommand("herdr pane read pane-working --source recent-unwrapped")
        XCTAssertEqual(readResult.exitCode, 0)
        let unwrapped = HerdrOutputParser.parseRecentUnwrapped(from: readResult.stdout)
        XCTAssertTrue(unwrapped.contains("Compiling"), "Output reading should return pane output")

        // State transition: pane run transitions idle to working
        let runResult = try await conn.executeCommand("herdr pane run pane-idle 'build-task'")
        XCTAssertEqual(runResult.exitCode, 0)

        let workspacesAfterRun = try await conn.executeCommand("herdr workspace list --format json")
        let updatedWorkspaces = try HerdrOutputParser.parseWorkspaces(from: workspacesAfterRun.stdout)
        let transitionedPane = updatedWorkspaces.flatMap(\.panes).first(where: { $0.id == "pane-idle" })
        XCTAssertEqual(transitionedPane?.agentState, .working)

        // State transition: wait agent-status transitions working to completed
        let waitResult = try await conn.executeCommand("herdr wait agent-status pane-idle --status done")
        XCTAssertEqual(waitResult.exitCode, 0)
        let waitState = try HerdrOutputParser.parseAgentState(from: waitResult.stdout)
        XCTAssertTrue(waitState.isCompleted)

        let workspacesAfterWait = try await conn.executeCommand("herdr workspace list --format json")
        let finalWorkspaces = try HerdrOutputParser.parseWorkspaces(from: workspacesAfterWait.stdout)
        let finalPane = finalWorkspaces.flatMap(\.panes).first(where: { $0.id == "pane-idle" })
        XCTAssertEqual(finalPane?.agentState.statusName, "completed")
    }
}
