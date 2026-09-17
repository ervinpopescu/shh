import XCTest
@testable import ShhTerminal

final class TerminalScrollIntentTests: XCTestCase {
    func testPrimaryScrollbackNeverProducesPTYIntent() {
        var reducer = TerminalScrollIntentReducer()
        var state = TerminalScrollIntentReducer.State()
        let context = TerminalScrollContext(surface: .primary, mouseReporting: false)

        XCTAssertEqual(reducer.reduce(.init(phase: .began), context: context, state: &state), [.native])
        XCTAssertEqual(reducer.reduce(.init(phase: .changed, translationY: -500), context: context, state: &state), [.native])
    }

    func testAlternateScreenQuantizesRowsAndBoundsOutput() {
        var reducer = TerminalScrollIntentReducer()
        var state = TerminalScrollIntentReducer.State()
        let context = TerminalScrollContext(surface: .alternate, mouseReporting: false, rowHeight: 20, rowCount: 24)

        _ = reducer.reduce(.init(phase: .began), context: context, state: &state)
        let intents = reducer.reduce(.init(phase: .changed, translationY: -85), context: context, state: &state)
        XCTAssertEqual(intents, [.key(.down), .key(.down), .key(.down), .key(.down)])
        XCTAssertLessThanOrEqual(intents.count, 4)
    }

    func testMouseModeUsesWheelButtonsAndCancellationDoesNotLeakInput() {
        var reducer = TerminalScrollIntentReducer()
        var state = TerminalScrollIntentReducer.State()
        let context = TerminalScrollContext(surface: .alternate, mouseReporting: true)

        _ = reducer.reduce(.init(phase: .began), context: context, state: &state)
        XCTAssertEqual(
            reducer.reduce(.init(phase: .changed, translationY: 30), context: context, state: &state),
            [.mouseWheel(.up)]
        )
        XCTAssertTrue(reducer.reduce(.init(phase: .cancelled), context: context, state: &state).isEmpty)
        XCTAssertTrue(reducer.reduce(.init(phase: .changed, translationY: 100), context: context, state: &state).isEmpty)
    }

    func testVelocityIsBoundedAndCanRequestPageIntent() {
        var reducer = TerminalScrollIntentReducer(maximumIntentsPerUpdate: 8)
        var state = TerminalScrollIntentReducer.State()
        let context = TerminalScrollContext(surface: .alternate, mouseReporting: false, rowHeight: 20, rowCount: 24)

        _ = reducer.reduce(.init(phase: .began), context: context, state: &state)
        let intents = reducer.reduce(.init(phase: .changed, translationY: -100, velocityY: -10_000), context: context, state: &state)
        XCTAssertEqual(intents.first, .key(.pageDown))
        XCTAssertLessThanOrEqual(intents.count, 1)
    }

    func testFallbackSuppressesKeyIntentsAcrossGesture() {
        var reducer = TerminalScrollIntentReducer()
        var state = TerminalScrollIntentReducer.State()
        let context = TerminalScrollContext(
            surface: .alternate,
            mouseReporting: false,
            copyModeFallbackAvailable: true
        )
        XCTAssertEqual(
            reducer.reduce(.init(phase: .began), context: context, state: &state),
            [.copyModeFallback]
        )
        XCTAssertEqual(
            reducer.reduce(.init(phase: .changed, translationY: -80, velocityY: -2_000), context: context, state: &state),
            []
        )
        XCTAssertEqual(
            reducer.reduce(.init(phase: .changed, translationY: 80, velocityY: 2_000), context: context, state: &state),
            []
        )
        XCTAssertEqual(
            reducer.reduce(.init(phase: .ended), context: context, state: &state),
            []
        )
    }

    func testAlternateScreenEmitsNavigationKeysWhenCopyModeFallbackUnavailable() {
        var reducer = TerminalScrollIntentReducer()
        var state = TerminalScrollIntentReducer.State()
        let context = TerminalScrollContext(
            surface: .alternate,
            mouseReporting: false,
            rowHeight: 20,
            rowCount: 24,
            copyModeFallbackAvailable: false
        )

        // Began phase must not emit copyModeFallback
        XCTAssertEqual(reducer.reduce(.init(phase: .began), context: context, state: &state), [])

        // Changed phase must emit navigation keys rather than being swallowed
        let downIntents = reducer.reduce(.init(phase: .changed, translationY: -85), context: context, state: &state)
        XCTAssertFalse(downIntents.isEmpty, "Alternate screen touches must not be swallowed when copyModeFallback is unavailable")
        XCTAssertEqual(downIntents, [.key(.down), .key(.down), .key(.down), .key(.down)])

        let upIntents = reducer.reduce(.init(phase: .changed, translationY: 50), context: context, state: &state)
        XCTAssertFalse(upIntents.isEmpty)
        XCTAssertEqual(upIntents, [.key(.up), .key(.up)])
    }

}
