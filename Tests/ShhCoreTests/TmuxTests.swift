import XCTest
@testable import ShhCore

final class TmuxTests: XCTestCase {

    // MARK: - Parser Outputs

    func testParseValidSingleSession() throws {
        let raw = "$0\tmain\t3\t1712345678\t1712345690\t1\n"
        let sessions = try TmuxListSessionsParser.parse(raw)
        XCTAssertEqual(sessions.count, 1)

        let session = sessions[0]
        XCTAssertEqual(session.id, "$0")
        XCTAssertEqual(session.sessionID, "$0")
        XCTAssertEqual(session.name, "main")
        XCTAssertEqual(session.windowsCount, 3)
        XCTAssertEqual(session.windows, 3)
        XCTAssertEqual(session.createdAt, Date(timeIntervalSince1970: 1712345678))
        XCTAssertEqual(session.created, Date(timeIntervalSince1970: 1712345678))
        XCTAssertEqual(session.lastActivityAt, Date(timeIntervalSince1970: 1712345690))
        XCTAssertEqual(session.activity, Date(timeIntervalSince1970: 1712345690))
        XCTAssertEqual(session.attachedClients, 1)
        XCTAssertEqual(session.attached, 1)
        XCTAssertTrue(session.isAttached)
    }

    func testParseValidMultipleSessionsWithAttachedAndUnattached() throws {
        let raw = """
        $0\twork\t1\t1712345678\t1712345679\t0
        $1\tbackground\t4\t1712345600\t1712345650\t2
        $2\tscratch\t2\t1712345700\t1712345710\t0
        """
        let sessions = try TmuxSessionInfo.parseList(from: raw)
        XCTAssertEqual(sessions.count, 3)

        XCTAssertEqual(sessions[0].sessionID, "$0")
        XCTAssertEqual(sessions[0].name, "work")
        XCTAssertEqual(sessions[0].windowsCount, 1)
        XCTAssertEqual(sessions[0].attachedClients, 0)
        XCTAssertFalse(sessions[0].isAttached)

        XCTAssertEqual(sessions[1].sessionID, "$1")
        XCTAssertEqual(sessions[1].name, "background")
        XCTAssertEqual(sessions[1].windowsCount, 4)
        XCTAssertEqual(sessions[1].attachedClients, 2)
        XCTAssertTrue(sessions[1].isAttached)

        XCTAssertEqual(sessions[2].sessionID, "$2")
        XCTAssertEqual(sessions[2].name, "scratch")
        XCTAssertEqual(sessions[2].windowsCount, 2)
        XCTAssertEqual(sessions[2].attachedClients, 0)
        XCTAssertFalse(sessions[2].isAttached)
    }

    func testParseEmptyAndWhitespaceOutputs() throws {
        XCTAssertTrue(try TmuxListSessionsParser.parse("").isEmpty)
        XCTAssertTrue(try TmuxListSessionsParser.parse("\n").isEmpty)
        XCTAssertTrue(try TmuxListSessionsParser.parse("   \n\t\n  ").isEmpty)
    }

    func testParseWithCarriageReturnsAndTrailingNewlines() throws {
        let raw = "$0\tdev\t2\t1712345678\t1712345690\t0\r\n$1\tprod\t1\t1712345700\t1712345710\t1\r\n\r\n"
        let sessions = try TmuxListSessionsParser.parse(raw)
        XCTAssertEqual(sessions.count, 2)
        XCTAssertEqual(sessions[0].name, "dev")
        XCTAssertEqual(sessions[1].name, "prod")
    }

    // MARK: - Unusual Unicode / Session Names

    func testParserUnusualUnicodeAndSpecialNames() throws {
        let raw = """
        $0\tmy dev session\t1\t1712345678\t1712345679\t0
        $1\t🚀 prod ⚡️\t2\t1712345678\t1712345679\t1
        $2\t開発セッション\t1\t1712345678\t1712345679\t0
        $3\tсессия-номер-один\t1\t1712345678\t1712345679\t0
        $4\tüñîçødé-tëst\t1\t1712345678\t1712345679\t0
        $5\twork's-project_2026\t1\t1712345678\t1712345679\t0
        $6\tc##project\t1\t1712345678\t1712345679\t0
        $7\twork; rm -rf /\t1\t1712345678\t1712345679\t0
        """
        let sessions = try TmuxListSessionsParser.parse(raw)
        XCTAssertEqual(sessions.count, 8)
        XCTAssertEqual(sessions[0].name, "my dev session")
        XCTAssertEqual(sessions[1].name, "🚀 prod ⚡️")
        XCTAssertEqual(sessions[2].name, "開発セッション")
        XCTAssertEqual(sessions[3].name, "сессия-номер-один")
        XCTAssertEqual(sessions[4].name, "üñîçødé-tëst")
        XCTAssertEqual(sessions[5].name, "work's-project_2026")
        XCTAssertEqual(sessions[6].name, "c##project")
        XCTAssertEqual(sessions[7].name, "work; rm -rf /")
    }

    func testSessionNameValidationAcceptsUnusualUnicode() throws {
        let validNames = [
            "🚀 prod ⚡️",
            "開発セッション",
            "сессия",
            "üñîçødé-tëst",
            "my dev session",
            "work's-project",
            "project#1",
            "work; rm -rf /"
        ]
        for name in validNames {
            let sessionName = try TmuxSessionName(name)
            XCTAssertEqual(sessionName.value, name)
            XCTAssertEqual(sessionName.description, name)
            XCTAssertFalse(sessionName.shellArgument.isEmpty)
        }
    }

    // MARK: - Malformed Rows

    func testParserThrowsOnMalformedTooFewFields() {
        // Output from tmux when server is not running
        XCTAssertThrowsError(try TmuxListSessionsParser.parse("no server running on /private/tmp/tmux-501/default")) { error in
            guard case TmuxParseError.invalidFieldCount(let expected, let actual, _) = error else {
                XCTFail("Unexpected error: \(error)")
                return
            }
            XCTAssertEqual(expected, 6)
            XCTAssertEqual(actual, 1)
        }

        // 3 fields
        XCTAssertThrowsError(try TmuxListSessionsParser.parseLine("$0\tmain\t1")) { error in
            guard case TmuxParseError.invalidFieldCount(let expected, let actual, _) = error else {
                XCTFail("Unexpected error: \(error)")
                return
            }
            XCTAssertEqual(expected, 6)
            XCTAssertEqual(actual, 3)
        }

        // 5 fields
        XCTAssertThrowsError(try TmuxListSessionsParser.parseLine("$0\tmain\t1\t1712345678\t1712345679")) { error in
            guard case TmuxParseError.invalidFieldCount(let expected, let actual, _) = error else {
                XCTFail("Unexpected error: \(error)")
                return
            }
            XCTAssertEqual(expected, 6)
            XCTAssertEqual(actual, 5)
        }
    }

    func testParserThrowsOnMalformedTooManyFields() {
        let line = "$0\tmain\t1\t1712345678\t1712345679\t0\textra"
        XCTAssertThrowsError(try TmuxListSessionsParser.parseLine(line)) { error in
            guard case TmuxParseError.invalidFieldCount(let expected, let actual, _) = error else {
                XCTFail("Unexpected error: \(error)")
                return
            }
            XCTAssertEqual(expected, 6)
            XCTAssertEqual(actual, 7)
        }
    }

    func testParserThrowsOnMalformedWindowsCount() {
        let badCounts = ["NaN", "two", "-1", ""]
        for bad in badCounts {
            let line = "$0\tmain\t\(bad)\t1712345678\t1712345679\t0"
            XCTAssertThrowsError(try TmuxListSessionsParser.parseLine(line), "Should fail on: \(bad)") { error in
                guard case TmuxParseError.invalidWindowsCount = error else {
                    XCTFail("Unexpected error: \(error)")
                    return
                }
            }
        }
    }

    func testParserThrowsOnMalformedTimestamps() {
        let badCreated = "$0\tmain\t1\tyesterday\t1712345679\t0"
        XCTAssertThrowsError(try TmuxListSessionsParser.parseLine(badCreated)) { error in
            guard case TmuxParseError.invalidTimestamp(let field, _) = error else {
                XCTFail("Unexpected error: \(error)")
                return
            }
            XCTAssertEqual(field, "created")
        }

        let badActivity = "$0\tmain\t1\t1712345678\tnow\t0"
        XCTAssertThrowsError(try TmuxListSessionsParser.parseLine(badActivity)) { error in
            guard case TmuxParseError.invalidTimestamp(let field, _) = error else {
                XCTFail("Unexpected error: \(error)")
                return
            }
            XCTAssertEqual(field, "activity")
        }
    }

    func testParserThrowsOnMalformedAttachedCount() {
        let badAttached = ["yes", "true", "-1", ""]
        for bad in badAttached {
            let line = "$0\tmain\t1\t1712345678\t1712345679\t\(bad)"
            XCTAssertThrowsError(try TmuxListSessionsParser.parseLine(line), "Should fail on: \(bad)") { error in
                guard case TmuxParseError.invalidAttachedCount = error else {
                    XCTFail("Unexpected error: \(error)")
                    return
                }
            }
        }
    }

    func testParserThrowsOnMalformedSessionID() {
        let badIDs = ["main", "0", "$", "$abc", ""]
        for bad in badIDs {
            let line = "\(bad)\tmain\t1\t1712345678\t1712345679\t0"
            XCTAssertThrowsError(try TmuxListSessionsParser.parseLine(line), "Should fail on: \(bad)") { error in
                guard case TmuxParseError.invalidSessionID = error else {
                    XCTFail("Unexpected error: \(error)")
                    return
                }
            }
        }
    }

    func testParserThrowsOnEmptySessionName() {
        let line = "$0\t\t1\t1712345678\t1712345679\t0"
        XCTAssertThrowsError(try TmuxListSessionsParser.parseLine(line)) { error in
            guard case TmuxParseError.invalidSessionName = error else {
                XCTFail("Unexpected error: \(error)")
                return
            }
        }
    }

    func testParserParseLineThrowsOnEmptyLine() {
        XCTAssertThrowsError(try TmuxListSessionsParser.parseLine("")) { error in
            XCTAssertEqual(error as? TmuxParseError, .emptyLine)
        }
    }

    // MARK: - Tmux 3.7c & Collision-Resistant Delimiters Fixtures

    func testParserSupportsTmux37cUnderscoreSanitizedOutput() throws {
        // Exact fixture matching tmux 3.7c where tabs are sanitized to underscores
        let raw = """
        $1_1-home_2_1789215519_1789303845_0
        $2_my_work_session_3_1789215519_1789303845_1
        $10_日本語_作業_1_1789215519_1789303845_0
        """
        let sessions = try TmuxListSessionsParser.parse(raw)
        XCTAssertEqual(sessions.count, 3)

        XCTAssertEqual(sessions[0].sessionID, "$1")
        XCTAssertEqual(sessions[0].name, "1-home")
        XCTAssertEqual(sessions[0].windowsCount, 2)
        XCTAssertEqual(sessions[0].createdAt, Date(timeIntervalSince1970: 1789215519))
        XCTAssertEqual(sessions[0].lastActivityAt, Date(timeIntervalSince1970: 1789303845))
        XCTAssertEqual(sessions[0].attachedClients, 0)

        XCTAssertEqual(sessions[1].sessionID, "$2")
        XCTAssertEqual(sessions[1].name, "my_work_session")
        XCTAssertEqual(sessions[1].windowsCount, 3)
        XCTAssertEqual(sessions[1].attachedClients, 1)

        XCTAssertEqual(sessions[2].sessionID, "$10")
        XCTAssertEqual(sessions[2].name, "日本語_作業")
        XCTAssertEqual(sessions[2].windowsCount, 1)
        XCTAssertEqual(sessions[2].attachedClients, 0)
    }

    func testParserSupportsPipeDelimitedWithExplicitEscaping() throws {
        let raw = """
        $1|session\\|with\\|pipes|2|1789215519|1789303845|0
        $2|session\\ with\\ spaces|1|1789215519|1789303845|1
        $3|escaped\\\\backslash|3|1789215519|1789303845|0
        $4|simple_name|1|1789215519|1789303845|0
        """
        let sessions = try TmuxListSessionsParser.parse(raw)
        XCTAssertEqual(sessions.count, 4)

        XCTAssertEqual(sessions[0].sessionID, "$1")
        XCTAssertEqual(sessions[0].name, "session|with|pipes")
        XCTAssertEqual(sessions[0].windowsCount, 2)

        XCTAssertEqual(sessions[1].sessionID, "$2")
        XCTAssertEqual(sessions[1].name, "session with spaces")
        XCTAssertEqual(sessions[1].attachedClients, 1)

        XCTAssertEqual(sessions[2].sessionID, "$3")
        XCTAssertEqual(sessions[2].name, "escaped\\backslash")

        XCTAssertEqual(sessions[3].sessionID, "$4")
        XCTAssertEqual(sessions[3].name, "simple_name")
    }

    func testParserUnderscoreSanitizedSessionNamesWithMultipleUnderscores() throws {
        let line = "$0_feature_login_auth_redesign_v2_4_1700000000_1700000010_2"
        let session = try TmuxListSessionsParser.parseLine(line)
        XCTAssertEqual(session.sessionID, "$0")
        XCTAssertEqual(session.name, "feature_login_auth_redesign_v2")
        XCTAssertEqual(session.windowsCount, 4)
        XCTAssertEqual(session.createdAt, Date(timeIntervalSince1970: 1700000000))
        XCTAssertEqual(session.lastActivityAt, Date(timeIntervalSince1970: 1700000010))
        XCTAssertEqual(session.attachedClients, 2)
    }

    func testParserRejectsMalformedUnderscoreLines() {
        // Missing fields (fewer than 5 underscores)
        XCTAssertThrowsError(try TmuxListSessionsParser.parseLine("$1_name_2_1700000000_0")) { error in
            guard case TmuxParseError.invalidFieldCount(let expected, let actual, _) = error else {
                XCTFail("Expected invalidFieldCount, got \(error)")
                return
            }
            XCTAssertEqual(expected, 6)
            XCTAssertEqual(actual, 5)
        }

        // Missing session ID prefix '$'
        XCTAssertThrowsError(try TmuxListSessionsParser.parseLine("1_name_2_1700000000_1700000000_0")) { error in
            guard case TmuxParseError.invalidSessionID = error else {
                XCTFail("Expected invalidSessionID, got \(error)")
                return
            }
        }

        // Non-numeric windows in underscore format
        XCTAssertThrowsError(try TmuxListSessionsParser.parseLine("$1_name_abc_1700000000_1700000000_0")) { error in
            guard case TmuxParseError.invalidWindowsCount = error else {
                XCTFail("Expected invalidWindowsCount, got \(error)")
                return
            }
        }

        // Non-numeric timestamp in underscore format
        XCTAssertThrowsError(try TmuxListSessionsParser.parseLine("$1_name_2_notatime_1700000000_0")) { error in
            guard case TmuxParseError.invalidTimestamp = error else {
                XCTFail("Expected invalidTimestamp, got \(error)")
                return
            }
        }

        // Non-numeric attached count in underscore format
        XCTAssertThrowsError(try TmuxListSessionsParser.parseLine("$1_name_2_1700000000_1700000000_notanumber")) { error in
            guard case TmuxParseError.invalidAttachedCount = error else {
                XCTFail("Expected invalidAttachedCount, got \(error)")
                return
            }
        }

        // Empty session name in underscore format
        XCTAssertThrowsError(try TmuxListSessionsParser.parseLine("$1__2_1700000000_1700000000_0")) { error in
            guard case TmuxParseError.invalidSessionName = error else {
                XCTFail("Expected invalidSessionName, got \(error)")
                return
            }
        }
    }

    func testParserRejectsOversizedSessionName() {
        let longName = String(repeating: "a", count: 129)
        let line = "$0|\(longName)|1|1700000000|1700000000|0"
        XCTAssertThrowsError(try TmuxListSessionsParser.parseLine(line)) { error in
            guard case TmuxParseError.invalidSessionName = error else {
                XCTFail("Expected invalidSessionName, got \(error)")
                return
            }
        }
    }

    // MARK: - Validated Create Names

    func testSessionNameRejectsEmptyAndWhitespace() {
        XCTAssertThrowsError(try TmuxSessionName("")) { error in
            XCTAssertEqual(error as? TmuxSessionNameError, .empty)
        }
        XCTAssertThrowsError(try TmuxSessionName("   ")) { error in
            XCTAssertEqual(error as? TmuxSessionNameError, .empty)
        }
    }

    func testSessionNameRejectsColon() {
        let namesWithColon = ["session:1", ":main", "main:", "a:b:c"]
        for name in namesWithColon {
            XCTAssertThrowsError(try TmuxSessionName(name), "Should reject colon in \(name)") { error in
                XCTAssertEqual(error as? TmuxSessionNameError, .containsColon)
            }
        }
    }

    func testSessionNameRejectsPeriod() {
        let namesWithPeriod = ["session.1", ".main", "main.", "a.b.c"]
        for name in namesWithPeriod {
            XCTAssertThrowsError(try TmuxSessionName(name), "Should reject period in \(name)") { error in
                XCTAssertEqual(error as? TmuxSessionNameError, .containsPeriod)
            }
        }
    }

    func testSessionNameRejectsControls() {
        let controlStrings = [
            "line\nbreak",
            "carriage\rreturn",
            "tab\tcharacter",
            "null\u{0000}byte",
            "escape\u{001B}code",
            "del\u{007F}char",
            "c1\u{009F}control"
        ]
        for name in controlStrings {
            XCTAssertThrowsError(try TmuxSessionName(name), "Should reject control character in \(name)") { error in
                XCTAssertEqual(error as? TmuxSessionNameError, .containsControlCharacters)
            }
        }
    }

    func testSessionNameRejectsOversized() {
        let exactMax = String(repeating: "a", count: 128)
        XCTAssertNoThrow(try TmuxSessionName(exactMax))

        let oversized = String(repeating: "a", count: 129)
        XCTAssertThrowsError(try TmuxSessionName(oversized)) { error in
            guard case TmuxSessionNameError.oversized(let length, let max) = error else {
                XCTFail("Unexpected error: \(error)")
                return
            }
            XCTAssertEqual(length, 129)
            XCTAssertEqual(max, 128)
        }
    }

    // MARK: - Quoting and Format Injection

    func testSessionNameFormatEscapesHashCharacters() throws {
        let nameWithHash = try TmuxSessionName("c#")
        XCTAssertEqual(nameWithHash.tmuxFormatEscaped, "c##")
        XCTAssertEqual(nameWithHash.shellArgument, "'c##'")

        let nameWithCommandInjection = try TmuxSessionName("project#(rm -rf /)")
        XCTAssertEqual(nameWithCommandInjection.tmuxFormatEscaped, "project##(rm -rf /)")
        XCTAssertEqual(nameWithCommandInjection.shellArgument, "'project##(rm -rf /)'")

        let nameWithFormatVar = try TmuxSessionName("#{session_name}")
        XCTAssertEqual(nameWithFormatVar.tmuxFormatEscaped, "##{session_name}")
        XCTAssertEqual(nameWithFormatVar.shellArgument, "'##{session_name}'")
    }

    func testSessionNameShellArgumentQuotingPreventsShellInjection() throws {
        let quotes = try TmuxSessionName("work's session")
        XCTAssertEqual(quotes.shellArgument, "'work'\\''s session'")

        let combined = try TmuxSessionName("foo'#(date)'bar")
        XCTAssertEqual(combined.shellArgument, "'foo'\\''##(date)'\\''bar'")

        let shellOps = try TmuxSessionName("work; rm -rf /")
        XCTAssertEqual(shellOps.shellArgument, "'work; rm -rf /'")

        let subshell = try TmuxSessionName("$(reboot)")
        XCTAssertEqual(subshell.shellArgument, "'$(reboot)'")

        let backticks = try TmuxSessionName("`reboot`")
        XCTAssertEqual(backticks.shellArgument, "'`reboot`'")
    }

    // MARK: - Session ID Validation & Attachment

    func testSessionIDValidation() throws {
        let validIDs = ["$0", "$1", "$42", "$999"]
        for id in validIDs {
            let sessionID = try TmuxSessionID(id)
            XCTAssertEqual(sessionID.value, id)
            XCTAssertEqual(sessionID.shellArgument, "'\(id)'")
        }

        let invalidIDs = [
            "work",
            "main",
            "0",
            "1",
            "$",
            "$abc",
            "",
            "   ",
            "$0; rm -rf /",
            "$0\n"
        ]
        for id in invalidIDs {
            XCTAssertThrowsError(try TmuxSessionID(id), "Should reject invalid session ID: \(id)") { error in
                guard case TmuxSessionIDError.invalidSessionID(let rejected) = error else {
                    XCTFail("Unexpected error: \(error)")
                    return
                }
                XCTAssertEqual(rejected, id)
            }
        }
    }

    func testAttachSessionRequiresSessionIDNeverName() throws {
        // Must succeed with session ID
        let attachCommand = try TmuxCommand.attachSession(id: "$0")
        XCTAssertEqual(attachCommand, "env -u TMUX tmux attach-session -d -t '$0'")

        // Must reject session names
        XCTAssertThrowsError(try TmuxCommand.attachSession(id: "work")) { error in
            guard case TmuxSessionIDError.invalidSessionID = error else {
                XCTFail("Unexpected error: \(error)")
                return
            }
        }
        XCTAssertThrowsError(try TmuxCommand.attachSession(id: "main"))
    }

    // MARK: - Fixed Command Templates

    func testVerifiedCommandTemplates() throws {
        // 1. Probe template: tmux -V
        XCTAssertEqual(TmuxCommand.probe, "tmux -V")

        // 2. Delimited list-sessions fields
        XCTAssertEqual(
            TmuxCommand.listSessionsFormat,
            "#{session_id}|#{q:session_name}|#{session_windows}|#{session_created}|#{session_activity}|#{session_attached}"
        )
        XCTAssertEqual(
            TmuxCommand.listSessions,
            "tmux list-sessions -F '#{session_id}|#{q:session_name}|#{session_windows}|#{session_created}|#{session_activity}|#{session_attached}'"
        )

        // 3. Has-session template
        XCTAssertEqual(TmuxCommand.hasSession(id: "$0"), "tmux has-session -t '$0'")

        // 4. env -u TMUX attach-session takeover by quoted session ID
        let sessionID = try TmuxSessionID("$1")
        XCTAssertEqual(
            TmuxCommand.attachSession(id: sessionID),
            "env -u TMUX tmux attach-session -d -t '$1'"
        )

        // 5. new-session -A -D using validated quoted name
        let sessionName = try TmuxSessionName("my-dev")
        XCTAssertEqual(
            TmuxCommand.newSession(name: sessionName),
            "tmux new-session -A -D -s 'my-dev'"
        )

        let escapedName = try TmuxSessionName("c#")
        XCTAssertEqual(
            TmuxCommand.newSession(name: escapedName),
            "tmux new-session -A -D -s 'c##'"
        )

        // TmuxAdapter integration
        let adapter = TmuxAdapter()
        XCTAssertEqual(adapter.command(for: .list), TmuxCommand.listSessions)
        XCTAssertEqual(adapter.command(for: .attach(name: "$0")), "env -u TMUX tmux attach-session -d -t '$0'")
        XCTAssertEqual(adapter.command(for: .create(name: "work")), "tmux new-session -A -D -s 'work'")
    }

    // MARK: - Tmux Availability

    func testTmuxAvailabilityParsing() {
        let availableProbe = TmuxAvailability.parse(output: "tmux 3.3a\n", exitCode: 0)
        XCTAssertTrue(availableProbe.isAvailable)
        XCTAssertEqual(availableProbe.version, "tmux 3.3a")
        XCTAssertEqual(availableProbe.capability, .available)

        let nextProbe = TmuxAvailability.parse(output: "tmux next-3.4\n", exitCode: 0)
        XCTAssertTrue(nextProbe.isAvailable)
        XCTAssertEqual(nextProbe.version, "tmux next-3.4")

        let notFoundProbe = TmuxAvailability.parse(output: "bash: tmux: command not found", exitCode: 127)
        XCTAssertFalse(notFoundProbe.isAvailable)
        XCTAssertNil(notFoundProbe.version)
        if case .unavailable(let reason) = notFoundProbe {
            XCTAssertTrue(reason.contains("command not found"))
        } else {
            XCTFail("Expected .unavailable")
        }

        let emptyProbe = TmuxAvailability.parse(output: "", exitCode: 0)
        XCTAssertFalse(emptyProbe.isAvailable)

        let resultSuccess = SSHCommandResult(exitCode: 0, stdout: "tmux 3.2\n")
        let fromResultSuccess = TmuxAvailability.parse(result: resultSuccess)
        XCTAssertTrue(fromResultSuccess.isAvailable)
        XCTAssertEqual(fromResultSuccess.version, "tmux 3.2")

        let resultFail = SSHCommandResult(exitCode: 127, stdout: "", stderr: "tmux: not found\n")
        let fromResultFail = TmuxAvailability.parse(result: resultFail)
        XCTAssertFalse(fromResultFail.isAvailable)
        if case .unavailable(let reason) = fromResultFail {
            XCTAssertEqual(reason, "tmux: not found")
        } else {
            XCTFail("Expected .unavailable")
        }
    }

    // MARK: - SSHCommandExecuting & RemoteCommandResult

    func testSSHCommandExecutingAndResult() async throws {
        struct MockExecutor: SSHCommandExecuting {
            func executeCommand(_ command: String) async throws -> SSHCommandResult {
                if command == "tmux -V" {
                    return SSHCommandResult(exitCode: 0, stdout: "tmux 3.3a\n")
                }
                return SSHCommandResult(exitCode: 1, stdout: "", stderr: "unknown command")
            }
        }

        let executor = MockExecutor()
        let result = try await executor.execute("tmux -V")
        XCTAssertTrue(result.isSuccess)
        XCTAssertEqual(result.stdout, "tmux 3.3a\n")

        let failResult = try await executor.executeCommand("bad-command")
        XCTAssertFalse(failResult.isSuccess)
        XCTAssertEqual(failResult.exitCode, 1)

        // Check typealias
        let remoteResult: RemoteCommandResult = result
        XCTAssertEqual(remoteResult.exitCode, 0)
    }

    // MARK: - CommandPolicy Hardening: Blocked Policy Bypasses

    func testCommandPolicyBlocksTmuxGlobalDestruction() {
        let policy = CommandPolicy()
        let blockedCommands = [
            // Exact kill-server forms
            "tmux kill-server",
            "tmux -u kill-server",
            "tmux -S /tmp/tmux.sock kill-server",
            "tmux -L mysocket kill-server",
            // kill-session global flags: -a (all other sessions), -g (group), --all
            "tmux kill-session -a",
            "tmux kill-session -a -t $0",
            "tmux kill-session -t $0 -a",
            "tmux kill-session -at $0",
            "tmux kill-session -ta $0",
            "tmux kill-session -aC",
            "tmux kill-session -Ca",
            "tmux kill-session -g",
            "tmux kill-session -g -t $0",
            "tmux kill-session --all",
            "tmux kill-sess -a",
            // Wrapper bypass attempts
            "sudo tmux kill-server",
            "sudo tmux kill-session -a",
            "env tmux kill-server",
            "env -u TMUX tmux kill-server",
            "env TMUX=1 tmux kill-session -a",
            "exec tmux kill-server",
            // Shell interpreter bypass attempts
            "bash -c 'tmux kill-server'",
            "sh -c 'tmux kill-session -a'",
            "zsh -c 'tmux kill-server'",
            // Command substitution bypass attempts
            "echo \"$(tmux kill-server)\"",
            "echo \"`tmux kill-server`\"",
            "echo \"$(tmux kill-session -a)\"",
            // Tmux format injection bypass attempts
            "tmux display-message -p '#(tmux kill-server)'",
            "tmux display-message -p '#(tmux kill-session -a)'",
            "tmux list-sessions -F '#(tmux kill-server)'",
            "tmux list-sessions -F '#(tmux kill-session -a)'",
            "tmux list-sessions -F '#(rm -rf /)'",
            // Run-shell bypass attempts
            "tmux run-shell 'rm -rf /'",
            "tmux run-shell 'tmux kill-server'"
        ]

        for command in blockedCommands {
            XCTAssertEqual(policy.classify(command), .blocked, "Command must be blocked: \(command)")
            XCTAssertFalse(policy.canSend(command, approved: true), "Approved cannot override blocked: \(command)")
            XCTAssertFalse(policy.canSend(command, approved: false), "Unapproved cannot send blocked: \(command)")
        }
    }

    // MARK: - CommandPolicy: Safe Commands

    func testCommandPolicyAllowsSafeTmuxForms() {
        let policy = CommandPolicy()
        let safeCommands = [
            // Exact probe form
            "tmux -V",
            "tmux -u -V",
            // Exact list forms
            "tmux list-sessions",
            "tmux ls",
            "tmux list-sessions -F '#{session_id}\t#{session_name}\t#{session_windows}\t#{session_created}\t#{session_activity}\t#{session_attached}'",
            "tmux ls -F '#{session_id}\t#{session_name}'",
            "tmux list-windows",
            "tmux lsw",
            // Exact has-session forms
            "tmux has-session -t '$0'",
            "tmux has-session -t mysession",
            "tmux has -t '$0'",
            "tmux has-session"
        ]

        for command in safeCommands {
            XCTAssertEqual(policy.classify(command), .safe, "Command must be safe: \(command)")
            XCTAssertTrue(policy.canSend(command, approved: false), "Safe command can send without approval: \(command)")
        }
    }

    // MARK: - CommandPolicy: Review-Required Commands

    func testCommandPolicyRequiresReviewForArbitraryTmuxActions() {
        let policy = CommandPolicy()
        let reviewCommands = [
            // Attach actions
            "env -u TMUX tmux attach-session -d -t '$0'",
            "tmux attach-session -t '$0'",
            "tmux attach -t '$0'",
            // Create actions
            "tmux new-session -A -D -s 'work'",
            "tmux new-session -s 'work'",
            "tmux new -s 'work'",
            // Targeted single-session termination (not global -a)
            "tmux kill-session -t '$0'",
            "tmux kill-session -t work",
            // Send keys
            "tmux send-keys -t '$0' 'ls' Enter",
            // Display message
            "tmux display-message 'hello'",
            "tmux display-message -p '#(date)'",
            // Configuration
            "tmux source-file ~/.tmux.conf",
            "tmux set-option -g prefix C-a",
            // Window / pane manipulation
            "tmux split-window -h",
            "tmux new-window"
        ]

        for command in reviewCommands {
            XCTAssertEqual(policy.classify(command), .reviewRequired, "Command must require review: \(command)")
            XCTAssertFalse(policy.canSend(command, approved: false), "Review-required cannot send unapproved: \(command)")
            XCTAssertTrue(policy.canSend(command, approved: true), "Review-required can send when approved: \(command)")
        }
    }
}
