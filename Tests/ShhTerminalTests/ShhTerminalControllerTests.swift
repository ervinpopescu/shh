import XCTest
import ShhCore
@testable import ShhTerminal

@MainActor
final class ShhTerminalControllerTests: XCTestCase {
    func testDefaultConfigurationAndRenderingEngine() {
        let controller = ShhTerminalController()

        XCTAssertEqual(controller.configuration.scrollbackLimit, 5000)
        XCTAssertEqual(controller.configuration.resizeDebounceInterval, 0.150, accuracy: 0.001)
        XCTAssertEqual(controller.configuration.initialSize, TerminalSize(columns: 80, rows: 24))
        XCTAssertEqual(controller.size, TerminalSize(columns: 80, rows: 24))
        XCTAssertFalse(controller.isMetalEnabled, "CoreGraphics/CoreText rendering should be used by default (Metal disabled)")
        XCTAssertFalse(controller.bracketedPasteMode)
    }

    func testInboundFeedingAndHeadlessEcho() {
        let controller = ShhTerminalController()

        let inbound = Data("Welcome to Shh Terminal\r\n".utf8)
        controller.feed(inbound)

        guard let headless = controller.internalHeadlessTerminal else {
            XCTFail("Headless terminal should be initialized")
            return
        }

        XCTAssertEqual(headless.getCharacter(col: 0, row: 0), "W")
        XCTAssertEqual(headless.getCharacter(col: 1, row: 0), "e")
    }

    func testOutboundCallbacksOnSend() {
        let controller = ShhTerminalController()

        var received: [Data] = []
        controller.onOutput = { data in
            received.append(data)
        }

        controller.send(key: .escape)
        controller.send(key: .ctrlC)
        controller.send(text: "ls\n")

        XCTAssertEqual(received.count, 3)
        XCTAssertEqual(received[0], Data([0x1B]))
        XCTAssertEqual(received[1], Data([0x03]))
        XCTAssertEqual(received[2], Data("ls\n".utf8))
    }

    func testDebouncedResizeCallback() {
        let config = ShhTerminalConfiguration(
            resizeDebounceInterval: 0.040,
            initialSize: TerminalSize(columns: 80, rows: 24)
        )
        let controller = ShhTerminalController(configuration: config)

        let exp = expectation(description: "Debounced resize called")
        var deliveredSizes: [TerminalSize] = []
        controller.onResize = { size in
            deliveredSizes.append(size)
            exp.fulfill()
        }

        // Rapid resizes
        controller.handleResize(columns: 90, rows: 25)
        controller.handleResize(columns: 100, rows: 30)
        controller.handleResize(columns: 110, rows: 35)

        waitForExpectations(timeout: 1.0)
        XCTAssertEqual(deliveredSizes.count, 1)
        XCTAssertEqual(deliveredSizes.first, TerminalSize(columns: 110, rows: 35))
        XCTAssertEqual(controller.size, TerminalSize(columns: 110, rows: 35))
    }

    func testFlushResizeImmediatelyInvokesCallback() {
        let config = ShhTerminalConfiguration(
            resizeDebounceInterval: 1.0,
            initialSize: TerminalSize(columns: 80, rows: 24)
        )
        let controller = ShhTerminalController(configuration: config)

        var deliveredSizes: [TerminalSize] = []
        controller.onResize = { size in
            deliveredSizes.append(size)
        }

        controller.handleResize(columns: 120, rows: 40)
        XCTAssertTrue(deliveredSizes.isEmpty)

        controller.flushResize()
        // Allow MainActor task to complete
        let exp = expectation(description: "Flush delivered")
        DispatchQueue.main.async {
            exp.fulfill()
        }
        waitForExpectations(timeout: 1.0)

        XCTAssertEqual(deliveredSizes.count, 1)
        XCTAssertEqual(deliveredSizes.first, TerminalSize(columns: 120, rows: 40))
    }

    func testPasteRespectsBracketedPasteMode() {
        let controller = ShhTerminalController()

        var sentData: [Data] = []
        controller.onOutput = { sentData.append($0) }

        // Paste while bracketed paste is disabled
        controller.paste("echo unbracketed")
        XCTAssertEqual(sentData.last, Data("echo unbracketed".utf8))

        // Enable bracketed paste via inbound feed
        controller.feed("\u{1b}[?2004h")
        XCTAssertTrue(controller.bracketedPasteMode)

        // Paste while bracketed paste is enabled
        controller.paste("echo bracketed")
        let expectedStart = Data([0x1B, 0x5B, 0x32, 0x30, 0x30, 0x7E])
        let expectedEnd = Data([0x1B, 0x5B, 0x32, 0x30, 0x31, 0x7E])
        let expectedPayload = expectedStart + Data("echo bracketed".utf8) + expectedEnd
        XCTAssertEqual(sentData.last, expectedPayload)
    }

    func testTitleAndBellCallbacks() {
        let controller = ShhTerminalController()

        var reportedTitle: String?
        controller.onTitleChanged = { reportedTitle = $0 }

        var bellRang = false
        controller.onBell = { bellRang = true }

        // OSC 0/2 to set title: ESC ] 0 ; NewTitle BEL
        controller.feed("\u{1b}]0;RemoteServer\u{07}")
        controller.feed("\u{07}") // BEL

        let exp = expectation(description: "Title and bell delivered")
        DispatchQueue.main.async {
            exp.fulfill()
        }
        waitForExpectations(timeout: 1.0)

        XCTAssertEqual(controller.title, "RemoteServer")
        XCTAssertEqual(reportedTitle, "RemoteServer")
        XCTAssertTrue(bellRang)
    }

    func testAlternateScreenBufferThroughController() {
        let controller = ShhTerminalController()

        XCTAssertFalse(controller.isAlternateScreenActive)

        controller.feed("\u{1b}[?1049h")
        XCTAssertTrue(controller.isAlternateScreenActive)

        controller.feed("\u{1b}[?1049l")
        XCTAssertFalse(controller.isAlternateScreenActive)
    }

    func testFirstResponderHooks() {
        let controller = ShhTerminalController()

        final class MockResponder: TerminalFirstResponderBridge {
            var active = false
            var isFirstResponder: Bool { active }
            func requestFirstResponder() -> Bool {
                active = true
                return true
            }
            func resignFirstResponder() -> Bool {
                active = false
                return true
            }
        }

        final class MockEngine: TerminalEngineBridge {
            var bracketedPasteMode: Bool = false
            var isAlternateScreenActive: Bool = false
            var currentSize: TerminalSize = TerminalSize(columns: 80, rows: 24)
            func feed(data: Data) {}
            func feed(text: String) {}
            func resize(size: TerminalSize) {}
            func changeScrollback(_ limit: Int) {}
            func findNext(_ term: String) -> Bool { true }
            func findPrevious(_ term: String) -> Bool { true }
            func searchMatchSummary(_ term: String) -> (index: Int, total: Int) { (1, 1) }
            func clearSearch() {}
            func selectAll() {}
            func selectNone() {}
            func getSelection() -> String? { "mock selection" }
            func currentTranscript(limit: Int) -> String { "mock transcript" }
        }

        var responderChanges: [Bool] = []
        controller.onFirstResponderChange = { responderChanges.append($0) }

        // Request before view attached queues request
        controller.requestFirstResponder()
        XCTAssertTrue(controller.hasPendingFirstResponderRequest)
        XCTAssertFalse(controller.isFirstResponder)

        // Attach view
        let mockEngine = MockEngine()
        let mockResponder = MockResponder()
        controller.attachEngine(mockEngine, firstResponder: mockResponder)

        // Pending request should have been consumed
        XCTAssertFalse(controller.hasPendingFirstResponderRequest)
        XCTAssertTrue(controller.isFirstResponder)
        XCTAssertEqual(responderChanges, [true])

        // Resign
        controller.resignFirstResponder()
        XCTAssertFalse(controller.isFirstResponder)
        XCTAssertEqual(responderChanges, [true, false])

        // Recover
        controller.recoverFirstResponder()
        XCTAssertTrue(controller.isFirstResponder)
        XCTAssertEqual(responderChanges, [true, false, true])
    }

    func testRiskyUnbracketedPasteDetection() {
        let controller = ShhTerminalController()

        // 1. Unbracketed mode (default)
        XCTAssertFalse(controller.bracketedPasteMode)

        // Single line commands: not risky
        XCTAssertFalse(controller.isRiskyUnbracketedPaste("echo hello"))
        XCTAssertFalse(controller.isRiskyUnbracketedPaste("ls -la"))
        XCTAssertFalse(controller.isRiskyUnbracketedPaste(""))
        XCTAssertFalse(controller.isRiskyUnbracketedPaste("   "))

        // Multi-line commands: risky because newlines execute commands without user review
        XCTAssertTrue(controller.isRiskyUnbracketedPaste("echo hello\necho world"))
        XCTAssertTrue(controller.isRiskyUnbracketedPaste("git pull\r\nrm -rf /"))
        XCTAssertTrue(controller.isRiskyUnbracketedPaste("first line\nsecond line\nthird line"))

        // 2. Bracketed paste mode enabled: ESC [ ? 2004 h
        controller.feed("\u{1b}[?2004h")
        XCTAssertTrue(controller.bracketedPasteMode)

        // Multi-line commands in bracketed paste mode are safe because shell frames with escape sequences
        XCTAssertFalse(controller.isRiskyUnbracketedPaste("echo hello\necho world"))
        XCTAssertFalse(controller.isRiskyUnbracketedPaste("git pull\r\nrm -rf /"))
    }

    func testHeadlessTranscriptAndSearchAffordances() {
        let controller = ShhTerminalController()

        controller.feed("first line match\r\nsecond line other\r\nthird line match\r\n")

        let transcript = controller.currentTranscript(limit: 10)
        XCTAssertTrue(transcript.contains("first line match"))
        XCTAssertTrue(transcript.contains("second line other"))
        XCTAssertTrue(transcript.contains("third line match"))

        // Search: match query
        let foundFirst = controller.findNext("match")
        XCTAssertTrue(foundFirst)

        let summary = controller.searchMatchSummary("match")
        XCTAssertEqual(summary.total, 2)
        XCTAssertEqual(summary.index, 1)

        let foundNext = controller.findNext("match")
        XCTAssertTrue(foundNext)
        let summary2 = controller.searchMatchSummary("match")
        XCTAssertEqual(summary2.index, 2)

        let foundPrev = controller.findPrevious("match")
        XCTAssertTrue(foundPrev)

        // Non-existent search
        let notFound = controller.findNext("nonexistent_term")
        XCTAssertFalse(notFound)
        let emptySummary = controller.searchMatchSummary("nonexistent_term")
        XCTAssertEqual(emptySummary.total, 0)

        // Clear search
        controller.clearSearch()
        let clearedSummary = controller.searchMatchSummary("match")
        XCTAssertEqual(clearedSummary.index, 0)
    }

    func testHeadlessSelectionAndResetAffordances() {
        let controller = ShhTerminalController()

        controller.feed("sample buffer line\r\n")

        XCTAssertNil(controller.getSelection())
        controller.selectAll()
        XCTAssertNotNil(controller.getSelection())
        XCTAssertTrue(controller.getSelection()?.contains("sample buffer line") == true)

        controller.selectNone()
        XCTAssertNil(controller.getSelection())

        // Reset
        controller.selectAll()
        controller.reset()
        XCTAssertNil(controller.getSelection())
        XCTAssertEqual(controller.title, "")
    }
}
