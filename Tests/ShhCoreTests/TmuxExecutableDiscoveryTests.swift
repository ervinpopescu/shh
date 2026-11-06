import XCTest

@testable import ShhCore

final class TmuxExecutableDiscoveryTests: XCTestCase {
    func testUsesRemoteLoginShellAndRejectsProfileNoise() {
        XCTAssertTrue(
            TmuxExecutableDiscovery.loginPathCommand.hasPrefix("\"${SHELL:-/bin/sh}\" -lc "))
        XCTAssertFalse(TmuxExecutableDiscovery.loginPathCommand.hasPrefix("sh -lc "))

        let validOutput =
            "\(TmuxExecutableDiscovery.beginSentinel)\n/Users/demo/.local/bin/tmux\n\(TmuxExecutableDiscovery.endSentinel)\n"
        XCTAssertEqual(
            TmuxExecutableDiscovery.parseExecutablePath(
                result: SSHCommandResult(exitCode: 0, stdout: validOutput)
            ),
            "/Users/demo/.local/bin/tmux"
        )
        XCTAssertNil(
            TmuxExecutableDiscovery.parseExecutablePath(
                result: SSHCommandResult(
                    exitCode: 0,
                    stdout: "profile warning\n\(validOutput)",
                    stderr: ""
                )
            )
        )
        XCTAssertNil(
            TmuxExecutableDiscovery.parseExecutablePath(
                result: SSHCommandResult(exitCode: 127, stdout: validOutput)
            )
        )
        XCTAssertNil(
            TmuxExecutableDiscovery.parseExecutablePath(
                result: SSHCommandResult(exitCode: 0, stdout: validOutput, stderr: " \n")
            )
        )
        XCTAssertNil(
            TmuxExecutableDiscovery.parseExecutablePath(
                result: SSHCommandResult(
                    exitCode: 0,
                    stdout:
                        "\(TmuxExecutableDiscovery.beginSentinel)\n /tmp/tmux\n\(TmuxExecutableDiscovery.endSentinel)\n"
                )
            )
        )
        XCTAssertNil(
            TmuxExecutableDiscovery.parseExecutablePath(
                result: SSHCommandResult(
                    exitCode: 0,
                    stdout:
                        "\(TmuxExecutableDiscovery.beginSentinel)\n/tmp/tmux path\n\(TmuxExecutableDiscovery.endSentinel)\n"
                )
            )
        )
        XCTAssertEqual(
            TmuxCommand.probe(executable: "/tmp/tmux;id"),
            "'/tmp/tmux;id' -V"
        )
    }

    func testPathValidationRejectsInvalidAndHerdrPaths() throws {
        XCTAssertTrue(TmuxExecutableDiscovery.isSafeAbsolutePath("/usr/local/bin/tmux"))
        XCTAssertFalse(TmuxExecutableDiscovery.isSafeAbsolutePath(""))
        XCTAssertFalse(TmuxExecutableDiscovery.isSafeAbsolutePath("tmux"))
        XCTAssertFalse(TmuxExecutableDiscovery.isSafeAbsolutePath("/tmp/tmux path"))
        XCTAssertFalse(TmuxExecutableDiscovery.isSafeAbsolutePath("/tmp/tmux\u{001B}"))
        XCTAssertFalse(
            TmuxExecutableDiscovery.isSafeAbsolutePath(String(repeating: "a", count: 513)))
        XCTAssertFalse(TmuxExecutableDiscovery.isSafeTmuxExecutablePath("/opt/bin/herdr"))
        XCTAssertTrue(TmuxExecutableDiscovery.isSafeTmuxExecutablePath("/opt/bin/tmux"))
        XCTAssertThrowsError(try TmuxControl(executable: "herdr"))
        XCTAssertThrowsError(try TmuxControl(executable: "/opt/bin/herdr"))
    }
}
