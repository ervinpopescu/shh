import XCTest
import SwiftTerm
import ShhCore
@testable import ShhTerminal

private final class TestTerminalDelegate: TerminalDelegate {
    var sentData: [Data] = []
    var titles: [String] = []
    var bellCount = 0

    func showCursor(source: SwiftTerm.Terminal) {}
    func hideCursor(source: SwiftTerm.Terminal) {}

    func setTerminalTitle(source: SwiftTerm.Terminal, title: String) {
        titles.append(title)
    }

    func setTerminalIconTitle(source: SwiftTerm.Terminal, title: String) {}

    func windowCommand(source: SwiftTerm.Terminal, command: SwiftTerm.Terminal.WindowManipulationCommand) -> [UInt8]? {
        nil
    }

    func sizeChanged(source: SwiftTerm.Terminal) {}

    func send(source: SwiftTerm.Terminal, data: ArraySlice<UInt8>) {
        sentData.append(Data(data))
    }

    func scrolled(source: SwiftTerm.Terminal, yDisp: Int) {}
    func linefeed(source: SwiftTerm.Terminal) {}
    func bufferActivated(source: SwiftTerm.Terminal) {}
    func synchronizedOutputChanged(source: SwiftTerm.Terminal, active: Bool) {}

    func bell(source: SwiftTerm.Terminal) {
        bellCount += 1
    }

    func selectionChanged(source: SwiftTerm.Terminal) {}
    func isProcessTrusted(source: SwiftTerm.Terminal) -> Bool { true }
    func cellSizeInPixels(source: SwiftTerm.Terminal) -> (width: Int, height: Int)? { nil }
}

final class HeadlessTerminalTests: XCTestCase {
    private func makeTerminal(cols: Int = 80, rows: Int = 24, scrollback: Int = 5000) -> (SwiftTerm.Terminal, TestTerminalDelegate) {
        let delegate = TestTerminalDelegate()
        let options = TerminalOptions(cols: cols, rows: rows, scrollback: scrollback)
        let terminal = SwiftTerm.Terminal(delegate: delegate, options: options)
        return (terminal, delegate)
    }

    // MARK: - CSI / SGR Tests

    func testSgrTextStylesAndReset() {
        let (terminal, _) = makeTerminal(cols: 80, rows: 24)

        // SGR: 1 = bold, 3 = italic, 4 = underline, followed by text, then 0 = reset
        terminal.feed(text: "\u{1b}[1;3;4mStyled\u{1b}[0mPlain")

        guard let styledCell = terminal.getCharData(col: 0, row: 0) else {
            XCTFail("Expected character at (0, 0)")
            return
        }
        XCTAssertTrue(styledCell.attribute.style.contains(.bold), "Expected bold style")
        XCTAssertTrue(styledCell.attribute.style.contains(.italic), "Expected italic style")
        XCTAssertTrue(styledCell.attribute.style.contains(.underline), "Expected underline style")

        // Cell after SGR 0 reset (col 6 = 'P')
        guard let resetCell = terminal.getCharData(col: 6, row: 0) else {
            XCTFail("Expected character at (6, 0)")
            return
        }
        XCTAssertFalse(resetCell.attribute.style.contains(.bold), "Reset should clear bold")
        XCTAssertFalse(resetCell.attribute.style.contains(.italic), "Reset should clear italic")
        XCTAssertFalse(resetCell.attribute.style.contains(.underline), "Reset should clear underline")
    }

    func testSgrColorAttributes() {
        let (terminal, _) = makeTerminal(cols: 80, rows: 24)

        // 16-color ANSI: 31 = red fg, 42 = green bg
        terminal.feed(text: "\u{1b}[31;42mA\u{1b}[0m")
        guard let cell16 = terminal.getCharData(col: 0, row: 0) else {
            XCTFail("Expected cell at (0, 0)")
            return
        }
        XCTAssertEqual(cell16.attribute.fg, .ansi256(code: 1))
        XCTAssertEqual(cell16.attribute.bg, .ansi256(code: 2))

        // 256-color: 38;5;196 = fg color 196, 48;5;232 = bg color 232
        terminal.feed(text: "\u{1b}[38;5;196;48;5;232mB\u{1b}[0m")
        guard let cell256 = terminal.getCharData(col: 1, row: 0) else {
            XCTFail("Expected cell at (1, 0)")
            return
        }
        XCTAssertEqual(cell256.attribute.fg, .ansi256(code: 196))
        XCTAssertEqual(cell256.attribute.bg, .ansi256(code: 232))

        // 24-bit TrueColor: 38;2;12;34;56 = rgb fg, 48;2;78;90;12 = rgb bg
        terminal.feed(text: "\u{1b}[38;2;12;34;56;48;2;78;90;12mC\u{1b}[0m")
        guard let cellRGB = terminal.getCharData(col: 2, row: 0) else {
            XCTFail("Expected cell at (2, 0)")
            return
        }
        XCTAssertEqual(cellRGB.attribute.fg, .trueColor(red: 12, green: 34, blue: 56))
        XCTAssertEqual(cellRGB.attribute.bg, .trueColor(red: 78, green: 90, blue: 12))
    }

    // MARK: - Alternate Screen Buffer Tests

    func testAlternateScreenBufferSwitchingAndPreservation() {
        let (terminal, _) = makeTerminal(cols: 40, rows: 10)

        // Starts on normal buffer
        XCTAssertFalse(terminal.isCurrentBufferAlternate)

        // Write to normal buffer
        terminal.feed(text: "NormalScreenData")
        XCTAssertEqual(terminal.getCharacter(col: 0, row: 0), "N")

        // Switch to alternate buffer: ESC [ ? 1049 h
        terminal.feed(text: "\u{1b}[?1049h")
        XCTAssertTrue(terminal.isCurrentBufferAlternate)

        // Move cursor to home (1,1) on alternate buffer and write content
        terminal.feed(text: "\u{1b}[HAltScreenData")
        XCTAssertEqual(terminal.getCharacter(col: 0, row: 0), "A")

        // Switch back to normal buffer: ESC [ ? 1049 l
        terminal.feed(text: "\u{1b}[?1049l")
        XCTAssertFalse(terminal.isCurrentBufferAlternate)

        // Original content on normal buffer is preserved
        XCTAssertEqual(terminal.getCharacter(col: 0, row: 0), "N")
    }

    // MARK: - Unicode Width Tests

    func testUnicodeWidthHandling() {
        let (terminal, _) = makeTerminal(cols: 40, rows: 10)

        // Single-width ASCII
        terminal.feed(text: "A")
        guard let asciiCell = terminal.getCharData(col: 0, row: 0) else {
            XCTFail("Expected cell at (0, 0)")
            return
        }
        XCTAssertEqual(asciiCell.width, 1)
        XCTAssertEqual(terminal.buffer.x, 1)

        // Double-width CJK character (中 U+4E2D)
        terminal.feed(text: "\r\n中")
        guard let cjkCell = terminal.getCharData(col: 0, row: 1) else {
            XCTFail("Expected cell at (0, 1)")
            return
        }
        XCTAssertEqual(cjkCell.width, 2)
        XCTAssertEqual(terminal.buffer.x, 2, "Double-width character advances cursor by 2 columns")

        // Emoji width
        terminal.feed(text: "\r\n😀")
        guard let emojiCell = terminal.getCharData(col: 0, row: 2) else {
            XCTFail("Expected cell at (0, 2)")
            return
        }
        XCTAssertEqual(emojiCell.width, 2)

        // Combining mark (e + COMBINING GRAVE ACCENT U+0300)
        terminal.feed(text: "\r\ne\u{0300}")
        XCTAssertEqual(terminal.getCharacter(col: 0, row: 3), "e\u{0300}")
        guard let combinedCell = terminal.getCharData(col: 0, row: 3) else {
            XCTFail("Expected cell at (0, 3)")
            return
        }
        XCTAssertEqual(combinedCell.width, 1)
        XCTAssertEqual(terminal.buffer.x, 1)
    }

    // MARK: - Bracketed-Paste State and Encoding Tests

    func testBracketedPasteModeToggleAndEncoding() {
        let (terminal, _) = makeTerminal(cols: 80, rows: 24)

        // Default: bracketed paste mode is disabled
        XCTAssertFalse(terminal.bracketedPasteMode)

        // Enable bracketed paste: ESC [ ? 2004 h
        terminal.feed(text: "\u{1b}[?2004h")
        XCTAssertTrue(terminal.bracketedPasteMode)

        // Encoding with bracketed paste enabled
        let textToPaste = "git commit -m 'feat: test'"
        let encodedBracketed = TerminalKeyEncoder.encodePaste(textToPaste, bracketed: terminal.bracketedPasteMode)
        let expectedStart = Data([0x1B, 0x5B, 0x32, 0x30, 0x30, 0x7E]) // ESC [ 200 ~
        let expectedEnd = Data([0x1B, 0x5B, 0x32, 0x30, 0x31, 0x7E])   // ESC [ 201 ~
        XCTAssertTrue(encodedBracketed.starts(with: expectedStart))
        XCTAssertEqual(encodedBracketed.suffix(expectedEnd.count), expectedEnd)
        XCTAssertEqual(encodedBracketed, expectedStart + Data(textToPaste.utf8) + expectedEnd)

        // Disable bracketed paste: ESC [ ? 2004 l
        terminal.feed(text: "\u{1b}[?2004l")
        XCTAssertFalse(terminal.bracketedPasteMode)

        // Encoding with bracketed paste disabled
        let encodedUnbracketed = TerminalKeyEncoder.encodePaste(textToPaste, bracketed: terminal.bracketedPasteMode)
        XCTAssertEqual(encodedUnbracketed, Data(textToPaste.utf8))
    }

    // MARK: - Scrollback Bounds Tests

    func testScrollbackBoundsConfigurationAndTrimming() {
        let rows = 10
        let scrollbackLimit = 5000
        let (terminal, _) = makeTerminal(cols: 40, rows: rows, scrollback: scrollbackLimit)

        XCTAssertEqual(terminal.options.scrollback, scrollbackLimit)

        // Feed more than 5,000 lines (5,050 lines)
        let linesToFeed = 5050
        for i in 0..<linesToFeed {
            terminal.feed(text: "Line \(i)\r\n")
        }

        // Lines pushed beyond the 5,000 limit must be trimmed off the top
        XCTAssertGreaterThan(
            terminal.buffer.totalLinesTrimmed,
            0,
            "Lines beyond the scrollback limit must increment totalLinesTrimmed"
        )
        // 5050 lines followed by trailing newline produces 5051 line starts.
        // With a 10-row viewport and 5000 scrollback (5010 capacity), 41 lines are trimmed.
        XCTAssertEqual(
            terminal.buffer.totalLinesTrimmed,
            41,
            "Trimmed line count should match excess lines beyond scrollback capacity"
        )

        // Verify runtime scrollback change
        terminal.changeScrollback(scrollbackLimit)
        XCTAssertEqual(terminal.options.scrollback, scrollbackLimit)
    }
}
