import XCTest
import ShhCore
@testable import ShhTerminal
#if canImport(UIKit) && canImport(SwiftUI)
import UIKit
import SwiftUI
#endif

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

    func testHandlePasteRequest_SafeVersusRisky() {
        let controller = ShhTerminalController()

        var outbound: [Data] = []
        controller.onOutput = { outbound.append($0) }

        var requestedRisky: [String] = []
        controller.onRiskyPasteRequested = { requestedRisky.append($0) }

        // 1. Single-line: not risky, immediately dispatched
        controller.handlePasteRequest("echo safe")
        XCTAssertEqual(requestedRisky.count, 0)
        XCTAssertEqual(outbound.count, 1)
        XCTAssertEqual(outbound.last, Data("echo safe".utf8))

        // 2. Multi-line unbracketed: risky, requests confirmation and does NOT dispatch to output
        controller.handlePasteRequest("git status\nrm -rf /")
        XCTAssertEqual(requestedRisky.count, 1)
        XCTAssertEqual(requestedRisky.last, "git status\nrm -rf /")
        XCTAssertEqual(outbound.count, 1, "Risky unbracketed paste must not be sent directly to onOutput")

        // 3. Multi-line bracketed: safe, immediately dispatched wrapped in bracketed paste markers
        controller.feed("\u{1b}[?2004h")
        XCTAssertTrue(controller.bracketedPasteMode)
        controller.handlePasteRequest("echo line 1\necho line 2")
        XCTAssertEqual(requestedRisky.count, 1)
        XCTAssertEqual(outbound.count, 2)
        XCTAssertEqual(outbound.last, Data("\u{1b}[200~echo line 1\necho line 2\u{1b}[201~".utf8))
    }

    func testResetCancelsDebouncedResize() {
        let config = ShhTerminalConfiguration(
            resizeDebounceInterval: 0.050,
            initialSize: TerminalSize(columns: 80, rows: 24)
        )
        let controller = ShhTerminalController(configuration: config)

        var resizeCalled = false
        controller.onResize = { _ in
            resizeCalled = true
        }

        controller.handleResize(columns: 100, rows: 40)
        // Reset immediately cancels debounced timer
        controller.reset()

        let exp = expectation(description: "Wait after reset")
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.080) {
            exp.fulfill()
        }
        waitForExpectations(timeout: 1.0)

        XCTAssertFalse(resizeCalled, "Pending resize must be cancelled on reset")
    }

    func testUpdateFirstResponderClearsPendingRequest() {
        let controller = ShhTerminalController()

        controller.requestFirstResponder()
        XCTAssertTrue(controller.hasPendingFirstResponderRequest)
        XCTAssertFalse(controller.isFirstResponder)

        controller.updateFirstResponder(true)
        XCTAssertFalse(controller.hasPendingFirstResponderRequest, "Acquiring first responder must clear pending request")
        XCTAssertTrue(controller.isFirstResponder)
    }

    func testTerminalFontSizeClampsAndResets() {
        final class MemoryStore: TerminalFontSizeStore {
            var value: Double?
            func load() -> Double? { value }
            func save(_ pointSize: Double) { value = pointSize }
        }

        let store = MemoryStore()
        let controller = ShhTerminalController(fontSizeStore: store)

        controller.setTerminalFontSize(100)
        XCTAssertEqual(controller.terminalFontSize, TerminalFontSize.maximumPointSize)
        controller.setTerminalFontSize(1)
        XCTAssertEqual(controller.terminalFontSize, TerminalFontSize.minimumPointSize)
        controller.resetTerminalFontSize()
        XCTAssertEqual(controller.terminalFontSize, TerminalFontSize.defaultPointSize)
        XCTAssertEqual(controller.terminalFontSizePercentage, 100)
    }

    func testTerminalFontSizePersistenceAndShortcuts() {
        final class MemoryStore: TerminalFontSizeStore {
            var value: Double?
            func load() -> Double? { value }
            func save(_ pointSize: Double) { value = pointSize }
        }

        let store = MemoryStore()
        let first = ShhTerminalController(fontSizeStore: store)
        first.handleZoomShortcut(.increase)
        XCTAssertEqual(store.value, TerminalFontSize.defaultPointSize + 1)

        let restored = ShhTerminalController(fontSizeStore: store)
        XCTAssertEqual(restored.terminalFontSize, 15)
        _ = restored.handleZoomShortcut(.decrease)
        XCTAssertEqual(restored.terminalFontSize, 14)
        _ = restored.handleZoomShortcut(.reset)
        XCTAssertEqual(restored.terminalFontSize, 14)
    }

    func testPinchScalingUsesGestureBaselineAndClamps() {
        final class MemoryStore: TerminalFontSizeStore {
            func load() -> Double? { nil }
            func save(_ pointSize: Double) {}
        }

        let controller = ShhTerminalController(
            configuration: ShhTerminalConfiguration(initialFontSize: 14),
            fontSizeStore: MemoryStore()
        )

        controller.applyPinch(scale: 1.5, basePointSize: 14)
        XCTAssertEqual(controller.terminalFontSize, 21)
        controller.applyPinch(scale: 10, basePointSize: 14)
        XCTAssertEqual(controller.terminalFontSize, TerminalFontSize.maximumPointSize)
        controller.applyPinch(scale: 0, basePointSize: 14)
        XCTAssertEqual(controller.terminalFontSize, TerminalFontSize.maximumPointSize)
    }

    func testFontChangeRecalculatesGeometryAndDeliversResize() {
        final class MockEngine: TerminalEngineBridge {
            var bracketedPasteMode = false
            var isAlternateScreenActive = false
            var currentSize = TerminalSize(columns: 100, rows: 30)
            var appliedFontSize: Double?
            var recalculationCount = 0
            func feed(data: Data) {}
            func feed(text: String) {}
            func resize(size: TerminalSize) {}
            func setFontSize(_ pointSize: Double) { appliedFontSize = pointSize }
            func recalculateSize() { recalculationCount += 1 }
            func changeScrollback(_ limit: Int) {}
            func findNext(_ term: String) -> Bool { false }
            func findPrevious(_ term: String) -> Bool { false }
            func searchMatchSummary(_ term: String) -> (index: Int, total: Int) { (0, 0) }
            func clearSearch() {}
            func selectAll() {}
            func selectNone() {}
            func getSelection() -> String? { nil }
            func currentTranscript(limit: Int) -> String { "" }
        }

        final class MemoryFontSizeStore: TerminalFontSizeStore {
            func load() -> Double? { nil }
            func save(_ pointSize: Double) {}
        }

        let config = ShhTerminalConfiguration(resizeDebounceInterval: 0.01)
        let controller = ShhTerminalController(
            configuration: config,
            fontSizeStore: MemoryFontSizeStore()
        )
        let engine = MockEngine()
        controller.attachEngine(engine, firstResponder: nil)

        let exp = expectation(description: "font resize delivered")
        var delivered: TerminalSize?
        controller.onResize = { size in
            delivered = size
            exp.fulfill()
        }
        controller.setTerminalFontSize(18)
        waitForExpectations(timeout: 1)

        XCTAssertEqual(engine.appliedFontSize, 18)
        XCTAssertEqual(engine.recalculationCount, 1)
        XCTAssertEqual(delivered, engine.currentSize)
    }

    func testThemePreferencePersistsAcrossControllers() {
        let defaults = UserDefaults(suiteName: "ShhTerminalTests.theme")!
        defaults.removePersistentDomain(forName: "ShhTerminalTests.theme")
        let store = UserDefaultsTerminalThemeStore(userDefaults: defaults)
        let first = ShhTerminalController(themeStore: store)
        first.setTerminalTheme(.dracula)
        let restored = ShhTerminalController(themeStore: store)
        XCTAssertEqual(restored.terminalTheme, .dracula)
        defaults.removePersistentDomain(forName: "ShhTerminalTests.theme")
    }

    func testThemeApplicationUpdatesControllerWithoutResettingSize() {
        final class MockEngine: TerminalEngineBridge {
            var bracketedPasteMode = false
            var isAlternateScreenActive = false
            var currentSize = TerminalSize(columns: 80, rows: 24)
            var appliedTheme: TerminalThemePreset?
            func feed(data: Data) {}
            func feed(text: String) {}
            func resize(size: TerminalSize) {}
            func setTheme(_ theme: TerminalThemePreset) { appliedTheme = theme }
            func changeScrollback(_ limit: Int) {}
            func findNext(_ term: String) -> Bool { false }
            func findPrevious(_ term: String) -> Bool { false }
            func searchMatchSummary(_ term: String) -> (index: Int, total: Int) { (0, 0) }
            func clearSearch() {}
            func selectAll() {}
            func selectNone() {}
            func getSelection() -> String? { nil }
            func currentTranscript(limit: Int) -> String { "" }
        }

        let controller = ShhTerminalController()
        let engine = MockEngine()
        controller.attachEngine(engine, firstResponder: nil)
        controller.setTerminalTheme(.nord)

        XCTAssertEqual(controller.terminalTheme, .nord)
        XCTAssertEqual(engine.appliedTheme, .nord)
        XCTAssertEqual(controller.size, TerminalSize(columns: 80, rows: 24))
    }

    func testDetachEngineIdentityProtection() {
        final class TestEngine: TerminalEngineBridge {
            var bracketedPasteMode: Bool = false
            var isAlternateScreenActive: Bool = false
            var currentSize: TerminalSize = TerminalSize(columns: 80, rows: 24)
            func feed(data: Data) {}
            func feed(text: String) {}
            func resize(size: TerminalSize) {}
            func changeScrollback(_ limit: Int) {}
            func findNext(_ term: String) -> Bool { true }
            func findPrevious(_ term: String) -> Bool { true }
            func searchMatchSummary(_ term: String) -> (index: Int, total: Int) { (0, 0) }
            func clearSearch() {}
            func selectAll() {}
            func selectNone() {}
            func getSelection() -> String? { nil }
            func currentTranscript(limit: Int) -> String { "" }
        }

        let controller = ShhTerminalController()
        let engine1 = TestEngine()
        let engine2 = TestEngine()

        controller.attachEngine(engine1, firstResponder: nil)
        XCTAssertTrue(controller.attachedBridge === engine1)

        // Detaching a different engine must NOT sever the current attached engine
        controller.detachEngine(engine2)
        XCTAssertTrue(controller.attachedBridge === engine1, "Detaching non-matching bridge must not nil active bridge")

        // Detaching the active engine severs it
        controller.detachEngine(engine1)
        XCTAssertNil(controller.attachedBridge)
    }

#if canImport(UIKit) && canImport(SwiftUI)
    func testResetWhileMountedFollowedByUpdateReattachAndVisibleByteDelivery() async {
        let controller = ShhTerminalController()
        let representable = ShhTerminalView(controller: controller)
        let coordinator = representable.makeCoordinator()

        // 1. Initial makeUIView attaches host view to controller
        let hostView = representable.makeUIView(coordinator: coordinator)
        representable.updateUIView(hostView, coordinator: coordinator)

        XCTAssertTrue(controller.persistentHostView === hostView)
        XCTAssertTrue(controller.attachedBridge === hostView)
        XCTAssertTrue(hostView.controller === controller)

        // 2. Initial visible byte delivery
        controller.feed(Data("Initial visible output\r\n".utf8))
        let initialTranscript = hostView.currentTranscript(limit: 10)
        XCTAssertTrue(initialTranscript.contains("Initial visible output"))

        // 3. Controller reset while mounted severs persistentHostView and attachedBridge
        controller.reset()
        XCTAssertNil(controller.persistentHostView)
        XCTAssertNil(controller.attachedBridge)

        // While detached, feeds only hit headless terminal, visible view does not receive bytes
        controller.feed(Data("Detached mid-stream\r\n".utf8))
        let detachedTranscript = hostView.currentTranscript(limit: 10)
        XCTAssertFalse(detachedTranscript.contains("Detached mid-stream"))

        // 4. SwiftUI updateUIView while view remains mounted must identity-aware reattach hostView
        representable.updateUIView(hostView, coordinator: coordinator)

        XCTAssertTrue(controller.persistentHostView === hostView, "updateUIView must reattach persistentHostView")
        XCTAssertTrue(controller.attachedBridge === hostView, "updateUIView must reattach active UI bridge")
        XCTAssertTrue(hostView.controller === controller)
        XCTAssertTrue(hostView.terminalDelegate === coordinator)

        // 5. Subsequent visible-byte delivery must now reach the visible terminal view
        controller.feed(Data("Visible bytes restored\r\n".utf8))
        let restoredTranscript = hostView.currentTranscript(limit: 10)
        XCTAssertTrue(restoredTranscript.contains("Visible bytes restored"), "Subsequent bytes must feed the visible terminal")

        // 6. Ordinary navigation dismantle must NOT sever host view or active engine
        ShhTerminalView.dismantleUIView(hostView, coordinator: coordinator)
        XCTAssertTrue(controller.persistentHostView === hostView, "Ordinary navigation dismantle must preserve persistentHostView")
        XCTAssertTrue(controller.attachedBridge === hostView, "Ordinary navigation dismantle must preserve attachedBridge for buffer streaming")

        controller.feed(Data("Streamed during background dismantle\r\n".utf8))
        let backgroundTranscript = hostView.currentTranscript(limit: 10)
        XCTAssertTrue(backgroundTranscript.contains("Streamed during background dismantle"))

        // Returning to view via makeUIView re-uses persistentHostView
        let returnedView = representable.makeUIView(coordinator: coordinator)
        XCTAssertTrue(returnedView === hostView)

        // Ordinary updateUIView when already attached remains stable
        representable.updateUIView(returnedView, coordinator: coordinator)
        XCTAssertTrue(controller.persistentHostView === hostView)
        XCTAssertTrue(controller.attachedBridge === hostView)

        // 7. Preserve paste interception through controller
        var outboundSent: [Data] = []
        controller.onOutput = { outboundSent.append($0) }
        var riskyPaste: String?
        controller.onRiskyPasteRequested = { riskyPaste = $0 }

        UIPasteboard.general.string = "safe paste command"
        hostView.paste(nil)
        XCTAssertEqual(outboundSent.last, Data("safe paste command".utf8))

        UIPasteboard.general.string = "risky\nmultiline"
        hostView.paste(nil)
        XCTAssertEqual(riskyPaste, "risky\nmultiline")

        // 8. Preserve VoiceOver transcript equivalence
        let fullTranscript = controller.currentTranscript(limit: 20)
        let viewTranscript = hostView.currentTranscript(limit: 20)
        XCTAssertEqual(fullTranscript, viewTranscript, "VoiceOver transcript through controller must match visible host view transcript")

        // 9. Preserve first responder behavior
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 800, height: 600))
        window.addSubview(hostView)
        window.makeKeyAndVisible()

        controller.requestFirstResponder()
        hostView.didMoveToWindow()
        _ = hostView.becomeFirstResponder()
        XCTAssertTrue(controller.isFirstResponder)

        _ = hostView.resignFirstResponder()
        XCTAssertFalse(controller.isFirstResponder)
        hostView.removeFromSuperview()

        // 10. Preserve resize callbacks
        var reportedResize: TerminalSize?
        let resizeExp = expectation(description: "Resize delivered")
        controller.onResize = { size in
            reportedResize = size
            resizeExp.fulfill()
        }
        coordinator.sizeChanged(source: hostView, newCols: 132, newRows: 43)
        DispatchQueue.main.async {
            controller.flushResize()
        }

        await fulfillment(of: [resizeExp], timeout: 1.0)
        XCTAssertEqual(reportedResize, TerminalSize(columns: 132, rows: 43))
    }

    func testShhTerminalViewHostingControllerResetAndReattach() {
        let controller = ShhTerminalController()
        let representable = ShhTerminalView(controller: controller)
        let hostingController = UIHostingController(rootView: representable)
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 600, height: 400))
        window.rootViewController = hostingController
        window.makeKeyAndVisible()
        hostingController.view.layoutIfNeeded()

        guard let hostView = controller.persistentHostView else {
            XCTFail("persistentHostView should be populated after hostingController layout")
            return
        }
        XCTAssertTrue(controller.attachedBridge === hostView)

        // Reset while mounted
        controller.reset()
        XCTAssertNil(controller.persistentHostView)
        XCTAssertNil(controller.attachedBridge)

        // SwiftUI updateUIView triggered via hostingController update
        hostingController.rootView = ShhTerminalView(controller: controller)
        hostingController.view.setNeedsLayout()
        hostingController.view.layoutIfNeeded()

        XCTAssertTrue(controller.persistentHostView === hostView, "Hosting controller update must reattach host view")
        XCTAssertTrue(controller.attachedBridge === hostView, "Hosting controller update must reattach attachedBridge")

        controller.feed(Data("Hosting Visible Bytes\r\n".utf8))
        XCTAssertTrue(hostView.currentTranscript(limit: 10).contains("Hosting Visible Bytes"))
    }
#endif
}
