import XCTest

@testable import ShhCore

final class MultiplexerControlTests: XCTestCase {
    private actor Recorder {
        var commands: [String] = []
        func record(_ command: String) { commands.append(command) }
        func all() -> [String] { commands }
    }

    private struct Executor: SSHCommandExecuting {
        let recorder: Recorder
        let result: SSHCommandResult
        func executeCommand(_ command: String) async throws -> SSHCommandResult {
            await recorder.record(command)
            return result
        }
    }

    func testTmuxControlsRenderExactSafeCommands() throws {
        let session = try TmuxSessionID("$4")
        let window = try TmuxWindowID("@7")
        let pane = try TmuxPaneID("%9")
        let paneTarget = TmuxPaneTarget(sessionID: session, windowID: window, paneID: pane)
        let windowTarget = TmuxWindowTarget(sessionID: session, windowID: window)
        let control = try TmuxControl()

        XCTAssertEqual(
            try control.command(for: .tmux(.previousWindow(session))),
            "tmux previous-window -t '$4'")
        XCTAssertEqual(
            try control.command(for: .tmux(.nextWindow(session))), "tmux next-window -t '$4'")
        XCTAssertEqual(
            try control.command(for: .tmux(.focusPane(paneTarget, direction: .left))),
            "tmux select-pane -t '$4:@7.%9' -L")
        XCTAssertEqual(
            try control.command(for: .tmux(.focusPane(paneTarget, direction: .right))),
            "tmux select-pane -t '$4:@7.%9' -R")
        XCTAssertEqual(
            try control.command(for: .tmux(.focusPane(paneTarget, direction: .up))),
            "tmux select-pane -t '$4:@7.%9' -U")
        XCTAssertEqual(
            try control.command(for: .tmux(.focusPane(paneTarget, direction: .down))),
            "tmux select-pane -t '$4:@7.%9' -D")
        XCTAssertEqual(
            try control.command(
                for: .tmux(.focusPane(TmuxPaneTarget(sessionID: session), direction: .left))),
            "tmux select-pane -t '$4' -L")
        XCTAssertEqual(
            try control.command(for: .tmux(.split(paneTarget, vertical: true))),
            "tmux split-window -v -t '$4:@7.%9'")
        XCTAssertEqual(
            try control.command(for: .tmux(.toggleZoom(paneTarget))),
            "tmux resize-pane -Z -t '$4:@7.%9'")
        XCTAssertEqual(
            try control.command(
                for: .tmux(.renameWindow(windowTarget, name: try TmuxSessionName("dev's")))),
            "tmux rename-window -t '$4:@7' 'dev'\\''s'")
        XCTAssertEqual(
            try control.command(for: .tmux(.copyMode(paneTarget))), "tmux copy-mode -t '$4:@7.%9'")
    }

    func testIdentifiersRejectInjection() {
        XCTAssertThrowsError(try TmuxWindowID("@1; touch /tmp/pwned"))
        XCTAssertThrowsError(try TmuxPaneID("%1$(id)"))
        XCTAssertThrowsError(try TmuxSessionID("$1; rm -rf /"))
        XCTAssertThrowsError(try TmuxClientTTY("/dev/pts/1;touch"))
        XCTAssertThrowsError(try TmuxControl(executable: "tmux; touch /tmp/pwned"))
    }

    func testHerdrCapabilitiesHideTmuxOnlyActionsAndUseObjectIDs() throws {
        XCTAssertFalse(MultiplexerCapabilities.herdr.contains(.directionalFocus))
        XCTAssertFalse(MultiplexerCapabilities.herdr.contains(.detachClient))
        let control = try HerdrControl()
        let command = try control.command(
            for: .herdr(.paneRun(paneID: "pane-7", command: "echo 'safe'; printf x")))
        XCTAssertEqual(command, "herdr pane run 'pane-7' 'echo '\\''safe'\\''; printf x'")
        XCTAssertThrowsError(
            try control.command(for: .herdr(.paneSplit(paneID: "pane-7", direction: "diagonal")))
        ) { error in
            XCTAssertEqual(error as? MultiplexerControlError, .unsupportedAction)
        }
    }

    func testDetachResolvesExactlyOneActualClientTTY() async throws {
        let recorder = Recorder()
        let executor = Executor(
            recorder: recorder, result: SSHCommandResult(exitCode: 0, stdout: "/dev/pts/3\t$4\n"))
        let session = try TmuxSessionID("$4")
        let identity = try await TmuxClientResolver.resolve(sessionID: session, using: executor)
        XCTAssertEqual(identity.tty.value, "/dev/pts/3")
        let recorded = await recorder.all()
        XCTAssertEqual(recorded, [TmuxClientResolver.listCommand])
        let control = try TmuxControl()
        let command = try control.command(
            for: .tmux(.detachClient(session: session, expectedTTY: identity.tty)))
        XCTAssertEqual(command, "tmux detach-client -s '$4' -t '/dev/pts/3'")
        XCTAssertThrowsError(
            try control.command(for: .tmux(.detachClient(session: session, expectedTTY: nil)))
        ) { error in
            XCTAssertEqual(error as? MultiplexerControlError, .missingTarget)
        }
    }

    func testAmbiguousClientResolutionFailsClosed() async throws {
        let executor = Executor(
            recorder: Recorder(),
            result: SSHCommandResult(exitCode: 0, stdout: "/dev/pts/3\t$4\n/dev/pts/4\t$4\n")
        )
        do {
            _ = try await TmuxClientResolver.resolve(
                sessionID: try TmuxSessionID("$4"), using: executor)
            XCTFail("Expected ambiguous client resolution to fail")
        } catch {
            XCTAssertEqual(error as? MultiplexerControlError, .ambiguousClient)
        }
    }

    func testDialMenuOmitsHerdrQueryControls() throws {
        let nodes = CommandDialMultiplexerMenu.nodes(
            tmuxSessionID: nil,
            herdrWorkspaceID: nil,
            capabilities: .herdr
        )
        XCTAssertTrue(nodes.isEmpty)
    }

    func testDialMenuResolvesTmuxPaneControlsWithoutExplicitPaneTarget() throws {
        let session = try TmuxSessionID("$4")
        let nodes = CommandDialMultiplexerMenu.nodes(
            tmuxSessionID: session,
            capabilities: .tmux
        )
        XCTAssertTrue(nodes.contains { $0.id == "mux.tmux.focus.left" })
        XCTAssertTrue(nodes.contains { $0.id == "mux.tmux.split.vertical" })
        XCTAssertTrue(nodes.contains { $0.id == "mux.tmux.zoom" })
    }

    func testTargetFormattingAndDescriptions() throws {
        let session = try TmuxSessionID("$4")
        let windowWithoutAt = try TmuxWindowID("7")
        let paneWithoutPercent = try TmuxPaneID("9")
        let tty = try TmuxClientTTY("/dev/pts/5")

        XCTAssertEqual(windowWithoutAt.value, "@7")
        XCTAssertEqual(windowWithoutAt.description, "@7")
        XCTAssertEqual(windowWithoutAt.shellArgument, "'@7'")
        XCTAssertEqual(paneWithoutPercent.value, "%9")
        XCTAssertEqual(paneWithoutPercent.description, "%9")
        XCTAssertEqual(paneWithoutPercent.shellArgument, "'%9'")
        XCTAssertEqual(tty.description, "/dev/pts/5")
        XCTAssertEqual(tty.shellArgument, "'/dev/pts/5'")

        let windowTarget = TmuxWindowTarget(sessionID: session, windowID: windowWithoutAt)
        XCTAssertEqual(windowTarget.value, "$4:@7")
        XCTAssertEqual(windowTarget.shellArgument, "'$4:@7'")

        let paneOnlyWindow = TmuxPaneTarget(sessionID: session, windowID: windowWithoutAt)
        XCTAssertEqual(paneOnlyWindow.value, "$4:@7")
        let paneOnlySession = TmuxPaneTarget(sessionID: session)
        XCTAssertEqual(paneOnlySession.value, "$4")

        let target = TmuxControlTarget(
            sessionID: session,
            window: windowTarget,
            pane: paneOnlyWindow,
            clientTTY: tty
        )
        XCTAssertEqual(target.sessionID, session)
        XCTAssertEqual(target.window, windowTarget)
        XCTAssertEqual(target.pane, paneOnlyWindow)
        XCTAssertEqual(target.clientTTY, tty)
    }

    func testControlActionConfirmationAndDisplayNames() throws {
        let session = try TmuxSessionID("$4")
        let window = try TmuxWindowID("@7")
        let pane = try TmuxPaneID("%9")
        let paneTarget = TmuxPaneTarget(sessionID: session, windowID: window, paneID: pane)
        let windowTarget = TmuxWindowTarget(sessionID: session, windowID: window)
        let name = try TmuxSessionName("main")
        let tty = try TmuxClientTTY("/dev/pts/1")

        let tmuxActions: [(MultiplexerControlAction, String)] = [
            (.tmux(.previousWindow(session)), "Previous Window"),
            (.tmux(.nextWindow(session)), "Next Window"),
            (.tmux(.focusPane(paneTarget, direction: .up)), "Focus Up"),
            (.tmux(.split(paneTarget, vertical: true)), "Split Vertical"),
            (.tmux(.split(paneTarget, vertical: false)), "Split Horizontal"),
            (.tmux(.toggleZoom(paneTarget)), "Toggle Zoom"),
            (.tmux(.sessionPicker(session)), "Choose Session"),
            (.tmux(.windowPicker(paneTarget)), "Choose Window"),
            (.tmux(.copyMode(paneTarget)), "Copy Mode"),
            (.tmux(.closePane(paneTarget)), "Close Pane"),
            (.tmux(.attachSession(session)), "Attach Session"),
            (.tmux(.createSession(name)), "Create Session"),
            (.tmux(.renameWindow(windowTarget, name: name)), "Rename Window"),
            (.tmux(.detachClient(session: session, expectedTTY: tty)), "Detach Client"),
        ]

        for (action, expectedName) in tmuxActions {
            XCTAssertTrue(action.requiresConfirmation)
            XCTAssertEqual(action.displayName, expectedName)
        }

        let herdrActions: [(MultiplexerControlAction, String, Bool)] = [
            (.herdr(.workspaceList), "List Workspaces", false),
            (.herdr(.workspaceCreate(cwd: "/tmp", label: "w")), "Create Workspace", false),
            (.herdr(.tabCreate(label: "t")), "Create Tab", false),
            (.herdr(.paneList(workspaceID: "w1")), "List Panes", false),
            (.herdr(.paneSplit(paneID: "p1", direction: "left")), "Split Pane", false),
            (.herdr(.paneRun(paneID: "p1", command: "ls")), "Run Pane Command", true),
            (.herdr(.paneRead(paneID: "p1", source: "s1")), "Read Pane", false),
            (.herdr(.waitAgentStatus(paneID: "p1", status: "ready")), "Wait for Agent", false),
            (.herdr(.status), "Agent Status", false),
        ]

        for (action, expectedName, confirmation) in herdrActions {
            XCTAssertEqual(action.requiresConfirmation, confirmation)
            XCTAssertEqual(action.displayName, expectedName)
        }
    }

    func testMultiplexerControlErrorDescriptions() {
        let errors: [(MultiplexerControlError, String)] = [
            (.invalidIdentifier("bad"), "The multiplexer identifier is invalid."),
            (.unsupportedAction, "This multiplexer does not support that control."),
            (.missingTarget, "The focused multiplexer object could not be resolved."),
            (.ambiguousClient, "The Shh tmux client could not be identified unambiguously."),
            (.clientNotFound, "The Shh tmux client is no longer connected."),
            (.unavailable("custom"), "custom"),
        ]
        for (error, description) in errors {
            XCTAssertEqual(error.errorDescription, description)
        }
    }

    func testExecutablePrefixAndCustomPaths() throws {
        let control = try TmuxControl(executable: "/usr/local/bin/tmux")
        XCTAssertEqual(control.executable, "'/usr/local/bin/tmux'")

        let herdrControl = try HerdrControl(executable: "/opt/bin/herdr")
        XCTAssertEqual(herdrControl.executable, "'/opt/bin/herdr'")

        XCTAssertThrowsError(try TmuxControl(executable: "custom-mux"))
        XCTAssertThrowsError(try TmuxControl(executable: "/bin/tmux\n"))
    }

    func testTmuxControlCommandsAndExecution() async throws {
        let session = try TmuxSessionID("$4")
        let name = try TmuxSessionName("demo")
        let window = try TmuxWindowID("@1")
        let pane = try TmuxPaneID("%2")
        let paneTarget = TmuxPaneTarget(sessionID: session, windowID: window, paneID: pane)
        let control = try TmuxControl()

        XCTAssertEqual(
            try control.command(for: .tmux(.attachSession(session))),
            "env -u TMUX tmux attach-session -d -t '$4'")
        XCTAssertEqual(
            try control.command(for: .tmux(.createSession(name))),
            "tmux new-session -A -D -s 'demo'")
        XCTAssertEqual(
            try control.command(for: .tmux(.sessionPicker(session))),
            "tmux choose-tree -s -w -t '$4'")
        XCTAssertEqual(
            try control.command(for: .tmux(.windowPicker(paneTarget))),
            "tmux choose-tree -w -t '$4:@1.%2'")
        XCTAssertEqual(
            try control.command(for: .tmux(.closePane(paneTarget))),
            "tmux kill-pane -t '$4:@1.%2'")

        XCTAssertThrowsError(try control.command(for: .herdr(.status))) { error in
            XCTAssertEqual(error as? MultiplexerControlError, .unsupportedAction)
        }

        let recorder = Recorder()
        let executor = Executor(
            recorder: recorder,
            result: SSHCommandResult(exitCode: 0, stdout: "/dev/pts/2\t$4\n")
        )

        _ = try await control.execute(.tmux(.toggleZoom(paneTarget)), using: executor)
        _ = try await control.execute(
            .tmux(.detachClient(session: session, expectedTTY: nil)),
            using: executor
        )
        let commands = await recorder.all()
        XCTAssertEqual(commands.count, 3)
        XCTAssertEqual(commands[0], "tmux resize-pane -Z -t '$4:@1.%2'")
        XCTAssertEqual(commands[1], TmuxClientResolver.listCommand)
        XCTAssertEqual(commands[2], "tmux detach-client -s '$4' -t '/dev/pts/2'")
    }

    func testHerdrControlCommandsAndExecution() async throws {
        let control = try HerdrControl()

        XCTAssertEqual(
            try control.command(for: .herdr(.workspaceList)),
            "herdr workspace list --format 'json'")
        XCTAssertEqual(
            try control.command(for: .herdr(.workspaceCreate(cwd: "/root/dir", label: "main"))),
            "herdr workspace create --cwd '/root/dir' --label 'main'")
        XCTAssertEqual(
            try control.command(for: .herdr(.tabCreate(label: "tab-1"))),
            "herdr tab create --label 'tab-1'")
        XCTAssertEqual(
            try control.command(for: .herdr(.paneList(workspaceID: nil))),
            "herdr pane list --format 'json'")
        XCTAssertEqual(
            try control.command(for: .herdr(.paneList(workspaceID: "ws-1"))),
            "herdr pane list 'ws-1' --format 'json'")
        XCTAssertEqual(
            try control.command(for: .herdr(.paneSplit(paneID: "p1", direction: "right"))),
            "herdr pane split 'p1' --direction 'right'")
        XCTAssertEqual(
            try control.command(for: .herdr(.paneRead(paneID: "p1", source: "s1"))),
            "herdr pane read 'p1' --source 's1'")
        XCTAssertEqual(
            try control.command(for: .herdr(.waitAgentStatus(paneID: "p1", status: "ready"))),
            "herdr wait agent-status 'p1' --status 'ready'")
        XCTAssertEqual(
            try control.command(for: .herdr(.waitAgentStatus(paneID: nil, status: nil))),
            "herdr wait agent-status")
        XCTAssertEqual(
            try control.command(for: .herdr(.status)),
            "herdr status --format 'json'")

        XCTAssertThrowsError(
            try control.command(for: .tmux(.previousWindow(try TmuxSessionID("$1"))))
        ) { error in
            XCTAssertEqual(error as? MultiplexerControlError, .unsupportedAction)
        }
        XCTAssertThrowsError(
            try control.command(for: .herdr(.paneList(workspaceID: "invalid id with spaces")))
        )

        let recorder = Recorder()
        let executor = Executor(
            recorder: recorder,
            result: SSHCommandResult(exitCode: 0, stdout: "{}\n")
        )
        _ = try await control.execute(.herdr(.status), using: executor)
        let commands = await recorder.all()
        XCTAssertEqual(commands, ["herdr status --format 'json'"])
    }

    func testTmuxClientResolverEdgeCases() async throws {
        XCTAssertThrowsError(try TmuxClientResolver.parse("malformed")) { error in
            XCTAssertEqual(
                error as? MultiplexerControlError,
                .invalidIdentifier("malformed")
            )
        }

        let recorder = Recorder()
        let session = try TmuxSessionID("$4")
        let targetTTY = try TmuxClientTTY("/dev/pts/3")
        let anotherTTY = try TmuxClientTTY("/dev/pts/4")

        let matchExecutor = Executor(
            recorder: recorder,
            result: SSHCommandResult(exitCode: 0, stdout: "/dev/pts/3\t$4\n/dev/pts/4\t$4\n")
        )
        let matched = try await TmuxClientResolver.resolve(
            sessionID: session,
            expectedTTY: targetTTY,
            using: matchExecutor
        )
        XCTAssertEqual(matched.tty, targetTTY)

        do {
            _ = try await TmuxClientResolver.resolve(
                sessionID: session,
                expectedTTY: try TmuxClientTTY("/dev/pts/99"),
                using: matchExecutor
            )
            XCTFail("Expected clientNotFound when target tty is missing")
        } catch {
            XCTAssertEqual(error as? MultiplexerControlError, .clientNotFound)
        }

        let failedExecutor = Executor(
            recorder: recorder,
            result: SSHCommandResult(exitCode: 1, stdout: "")
        )
        do {
            _ = try await TmuxClientResolver.resolve(sessionID: session, using: failedExecutor)
            XCTFail("Expected clientNotFound when command fails")
        } catch {
            XCTAssertEqual(error as? MultiplexerControlError, .clientNotFound)
        }

        let emptyExecutor = Executor(
            recorder: recorder,
            result: SSHCommandResult(exitCode: 0, stdout: "")
        )
        do {
            _ = try await TmuxClientResolver.resolve(sessionID: session, using: emptyExecutor)
            XCTFail("Expected clientNotFound on empty client output")
        } catch {
            XCTAssertEqual(error as? MultiplexerControlError, .clientNotFound)
        }
    }
}
