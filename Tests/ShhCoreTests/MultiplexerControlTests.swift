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

        XCTAssertEqual(try control.command(for: .tmux(.previousWindow(session))), "tmux previous-window -t '$4'")
        XCTAssertEqual(try control.command(for: .tmux(.nextWindow(session))), "tmux next-window -t '$4'")
        XCTAssertEqual(try control.command(for: .tmux(.focusPane(paneTarget, direction: .left))), "tmux select-pane -t '$4:@7.%9' -L")
        XCTAssertEqual(try control.command(for: .tmux(.focusPane(paneTarget, direction: .right))), "tmux select-pane -t '$4:@7.%9' -R")
        XCTAssertEqual(try control.command(for: .tmux(.focusPane(paneTarget, direction: .up))), "tmux select-pane -t '$4:@7.%9' -U")
        XCTAssertEqual(try control.command(for: .tmux(.focusPane(paneTarget, direction: .down))), "tmux select-pane -t '$4:@7.%9' -D")
        XCTAssertEqual(try control.command(for: .tmux(.focusPane(TmuxPaneTarget(sessionID: session), direction: .left))), "tmux select-pane -t '$4' -L")
        XCTAssertEqual(try control.command(for: .tmux(.split(paneTarget, vertical: true))), "tmux split-window -v -t '$4:@7.%9'")
        XCTAssertEqual(try control.command(for: .tmux(.toggleZoom(paneTarget))), "tmux resize-pane -Z -t '$4:@7.%9'")
        XCTAssertEqual(try control.command(for: .tmux(.renameWindow(windowTarget, name: try TmuxSessionName("dev's")))), "tmux rename-window -t '$4:@7' 'dev'\\''s'")
        XCTAssertEqual(try control.command(for: .tmux(.copyMode(paneTarget))), "tmux copy-mode -t '$4:@7.%9'")
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
        let command = try control.command(for: .herdr(.paneRun(paneID: "pane-7", command: "echo 'safe'; printf x")))
        XCTAssertEqual(command, "herdr pane run 'pane-7' 'echo '\\''safe'\\''; printf x'")
        XCTAssertThrowsError(try control.command(for: .herdr(.paneSplit(paneID: "pane-7", direction: "diagonal")))) { error in
            XCTAssertEqual(error as? MultiplexerControlError, .unsupportedAction)
        }
    }

    func testDetachResolvesExactlyOneActualClientTTY() async throws {
        let recorder = Recorder()
        let executor = Executor(recorder: recorder, result: SSHCommandResult(exitCode: 0, stdout: "/dev/pts/3\t$4\n"))
        let session = try TmuxSessionID("$4")
        let identity = try await TmuxClientResolver.resolve(sessionID: session, using: executor)
        XCTAssertEqual(identity.tty.value, "/dev/pts/3")
        let control = try TmuxControl()
        let command = try control.command(for: .tmux(.detachClient(session: session, expectedTTY: identity.tty)))
        XCTAssertEqual(command, "tmux detach-client -s '$4' -t '/dev/pts/3'")
        XCTAssertThrowsError(try control.command(for: .tmux(.detachClient(session: session, expectedTTY: nil)))) { error in
            XCTAssertEqual(error as? MultiplexerControlError, .missingTarget)
        }
    }

    func testAmbiguousClientResolutionFailsClosed() async throws {
        let executor = Executor(
            recorder: Recorder(),
            result: SSHCommandResult(exitCode: 0, stdout: "/dev/pts/3\t$4\n/dev/pts/4\t$4\n")
        )
        do {
            _ = try await TmuxClientResolver.resolve(sessionID: try TmuxSessionID("$4"), using: executor)
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
}
