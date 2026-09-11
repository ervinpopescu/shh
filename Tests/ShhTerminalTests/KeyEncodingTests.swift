import XCTest
@testable import ShhTerminal

final class KeyEncodingTests: XCTestCase {
    func testEscapeEncoding() {
        let expected = Data([0x1B])
        XCTAssertEqual(TerminalKeyEncoder.escape(), expected)
        XCTAssertEqual(TerminalKeyEncoder.encode(.escape), expected)
    }

    func testTabEncoding() {
        let normalTab = Data([0x09])
        XCTAssertEqual(TerminalKeyEncoder.tab(shift: false), normalTab)
        XCTAssertEqual(TerminalKeyEncoder.encode(.tab(shift: false)), normalTab)

        let shiftTab = Data([0x1B, 0x5B, 0x5A]) // ESC [ Z
        XCTAssertEqual(TerminalKeyEncoder.tab(shift: true), shiftTab)
        XCTAssertEqual(TerminalKeyEncoder.encode(.tab(shift: true)), shiftTab)
    }

    func testArrowKeysNormalMode() {
        XCTAssertEqual(
            TerminalKeyEncoder.arrow(.up, modifiers: [], applicationCursor: false),
            Data([0x1B, 0x5B, 0x41]) // ESC [ A
        )
        XCTAssertEqual(
            TerminalKeyEncoder.arrow(.down, modifiers: [], applicationCursor: false),
            Data([0x1B, 0x5B, 0x42]) // ESC [ B
        )
        XCTAssertEqual(
            TerminalKeyEncoder.arrow(.right, modifiers: [], applicationCursor: false),
            Data([0x1B, 0x5B, 0x43]) // ESC [ C
        )
        XCTAssertEqual(
            TerminalKeyEncoder.arrow(.left, modifiers: [], applicationCursor: false),
            Data([0x1B, 0x5B, 0x44]) // ESC [ D
        )
    }

    func testArrowKeysApplicationCursorMode() {
        XCTAssertEqual(
            TerminalKeyEncoder.arrow(.up, modifiers: [], applicationCursor: true),
            Data([0x1B, 0x4F, 0x41]) // ESC O A
        )
        XCTAssertEqual(
            TerminalKeyEncoder.arrow(.down, modifiers: [], applicationCursor: true),
            Data([0x1B, 0x4F, 0x42]) // ESC O B
        )
        XCTAssertEqual(
            TerminalKeyEncoder.arrow(.right, modifiers: [], applicationCursor: true),
            Data([0x1B, 0x4F, 0x43]) // ESC O C
        )
        XCTAssertEqual(
            TerminalKeyEncoder.arrow(.left, modifiers: [], applicationCursor: true),
            Data([0x1B, 0x4F, 0x44]) // ESC O D
        )
    }

    func testArrowKeysWithModifiers() {
        // Shift -> modifier code 2 (1 + 1)
        XCTAssertEqual(
            TerminalKeyEncoder.arrow(.up, modifiers: [.shift]),
            Data([0x1B, 0x5B, 0x31, 0x3B, 0x32, 0x41]) // ESC [ 1 ; 2 A
        )

        // Option/Alt -> modifier code 3 (1 + 2)
        XCTAssertEqual(
            TerminalKeyEncoder.arrow(.down, modifiers: [.option]),
            Data([0x1B, 0x5B, 0x31, 0x3B, 0x33, 0x42]) // ESC [ 1 ; 3 B
        )

        // Control -> modifier code 5 (1 + 4)
        XCTAssertEqual(
            TerminalKeyEncoder.arrow(.left, modifiers: [.control]),
            Data([0x1B, 0x5B, 0x31, 0x3B, 0x35, 0x44]) // ESC [ 1 ; 5 D
        )
        XCTAssertEqual(
            TerminalKeyEncoder.arrow(.right, modifiers: [.control]),
            Data([0x1B, 0x5B, 0x31, 0x3B, 0x35, 0x43]) // ESC [ 1 ; 5 C
        )

        // Shift + Control -> modifier code 6 (1 + 1 + 4)
        XCTAssertEqual(
            TerminalKeyEncoder.arrow(.up, modifiers: [.shift, .control]),
            Data([0x1B, 0x5B, 0x31, 0x3B, 0x36, 0x41]) // ESC [ 1 ; 6 A
        )

        // Emacs word navigation helpers
        XCTAssertEqual(TerminalKeyEncoder.emacsWordBack(), Data([0x1B, 0x62]))    // ESC b
        XCTAssertEqual(TerminalKeyEncoder.emacsWordForward(), Data([0x1B, 0x66])) // ESC f
    }

    func testCtrlCAndCtrlD() {
        XCTAssertEqual(TerminalKeyEncoder.ctrlC(), Data([0x03]))
        XCTAssertEqual(TerminalKeyEncoder.encode(.ctrlC), Data([0x03]))

        XCTAssertEqual(TerminalKeyEncoder.ctrlD(), Data([0x04]))
        XCTAssertEqual(TerminalKeyEncoder.encode(.ctrlD), Data([0x04]))
    }

    func testControlKeyEncoding() {
        // Lowercase letters
        XCTAssertEqual(TerminalKeyEncoder.control("a"), Data([0x01]))
        XCTAssertEqual(TerminalKeyEncoder.control("c"), Data([0x03]))
        XCTAssertEqual(TerminalKeyEncoder.control("d"), Data([0x04]))
        XCTAssertEqual(TerminalKeyEncoder.control("z"), Data([0x1A]))

        // Uppercase letters
        XCTAssertEqual(TerminalKeyEncoder.control("A"), Data([0x01]))
        XCTAssertEqual(TerminalKeyEncoder.control("C"), Data([0x03]))
        XCTAssertEqual(TerminalKeyEncoder.control("D"), Data([0x04]))
        XCTAssertEqual(TerminalKeyEncoder.control("Z"), Data([0x1A]))

        // Special control keys
        XCTAssertEqual(TerminalKeyEncoder.control("@"), Data([0x00]))
        XCTAssertEqual(TerminalKeyEncoder.control(" "), Data([0x00]))
        XCTAssertEqual(TerminalKeyEncoder.control("["), Data([0x1B]))
        XCTAssertEqual(TerminalKeyEncoder.control("\\"), Data([0x1C]))
        XCTAssertEqual(TerminalKeyEncoder.control("]"), Data([0x1D]))
        XCTAssertEqual(TerminalKeyEncoder.control("^"), Data([0x1E]))
        XCTAssertEqual(TerminalKeyEncoder.control("_"), Data([0x1F]))
        XCTAssertEqual(TerminalKeyEncoder.control("?"), Data([0x7F]))

        // Non-ASCII
        XCTAssertNil(TerminalKeyEncoder.control("🚀"))
    }

    func testOptionMetaCombinations() {
        XCTAssertEqual(TerminalKeyEncoder.meta("a"), Data([0x1B, 0x61]))
        XCTAssertEqual(TerminalKeyEncoder.meta("x"), Data([0x1B, 0x78]))
        XCTAssertEqual(TerminalKeyEncoder.meta("1"), Data([0x1B, 0x31]))

        XCTAssertEqual(TerminalKeyEncoder.meta("git status"), Data([0x1B]) + Data("git status".utf8))
    }

    func testFunctionKeys() {
        XCTAssertEqual(TerminalKeyEncoder.functionKey(1), Data([0x1B, 0x4F, 0x50]))
        XCTAssertEqual(TerminalKeyEncoder.functionKey(2), Data([0x1B, 0x4F, 0x51]))
        XCTAssertEqual(TerminalKeyEncoder.functionKey(3), Data([0x1B, 0x4F, 0x52]))
        XCTAssertEqual(TerminalKeyEncoder.functionKey(4), Data([0x1B, 0x4F, 0x53]))
        XCTAssertEqual(TerminalKeyEncoder.functionKey(5), Data([0x1B, 0x5B, 0x31, 0x35, 0x7E]))
        XCTAssertEqual(TerminalKeyEncoder.functionKey(6), Data([0x1B, 0x5B, 0x31, 0x37, 0x7E]))
        XCTAssertEqual(TerminalKeyEncoder.functionKey(7), Data([0x1B, 0x5B, 0x31, 0x38, 0x7E]))
        XCTAssertEqual(TerminalKeyEncoder.functionKey(8), Data([0x1B, 0x5B, 0x31, 0x39, 0x7E]))
        XCTAssertEqual(TerminalKeyEncoder.functionKey(9), Data([0x1B, 0x5B, 0x32, 0x30, 0x7E]))
        XCTAssertEqual(TerminalKeyEncoder.functionKey(10), Data([0x1B, 0x5B, 0x32, 0x31, 0x7E]))
        XCTAssertEqual(TerminalKeyEncoder.functionKey(11), Data([0x1B, 0x5B, 0x32, 0x33, 0x7E]))
        XCTAssertEqual(TerminalKeyEncoder.functionKey(12), Data([0x1B, 0x5B, 0x32, 0x34, 0x7E]))

        // Invalid function keys
        XCTAssertNil(TerminalKeyEncoder.functionKey(0))
        XCTAssertNil(TerminalKeyEncoder.functionKey(13))
    }

    func testBracketedPasteEncoding() {
        let text = "echo 'hello world'"

        // With bracketed paste enabled
        let bracketed = TerminalKeyEncoder.encodePaste(text, bracketed: true)
        let expectedStart = Data([0x1B, 0x5B, 0x32, 0x30, 0x30, 0x7E]) // ESC [ 200 ~
        let expectedEnd = Data([0x1B, 0x5B, 0x32, 0x30, 0x31, 0x7E])   // ESC [ 201 ~
        XCTAssertTrue(bracketed.starts(with: expectedStart))
        XCTAssertEqual(bracketed.suffix(expectedEnd.count), expectedEnd)
        XCTAssertEqual(bracketed, expectedStart + Data(text.utf8) + expectedEnd)

        // With bracketed paste disabled
        let unbracketed = TerminalKeyEncoder.encodePaste(text, bracketed: false)
        XCTAssertEqual(unbracketed, Data(text.utf8))
    }
}
