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

    func testPrimaryMultiplexerWithMouseReportingEmitsWheelIntents() {
        var reducer = TerminalScrollIntentReducer()
        var state = TerminalScrollIntentReducer.State()
        let context = TerminalScrollContext(
            surface: .primary,
            mouseReporting: true
        )

        XCTAssertEqual(reducer.reduce(.init(phase: .began), context: context, state: &state), [])
        XCTAssertEqual(
            reducer.reduce(.init(phase: .changed, translationY: -30), context: context, state: &state),
            [.mouseWheel(.up)]
        )
        XCTAssertEqual(
            reducer.reduce(.init(phase: .changed, translationY: 30), context: context, state: &state),
            [.mouseWheel(.down)]
        )
    }

    func testPrimaryMultiplexerWithoutMouseReportingFallsBackToNativeScrollback() {
        var reducer = TerminalScrollIntentReducer()
        var state = TerminalScrollIntentReducer.State()
        let context = TerminalScrollContext(
            surface: .primary,
            mouseReporting: false
        )

        XCTAssertEqual(reducer.reduce(.init(phase: .began), context: context, state: &state), [.native])
        XCTAssertEqual(
            reducer.reduce(.init(phase: .changed, translationY: -80), context: context, state: &state),
            [.native]
        )
    }

    func testAlternateScreenQuantizesRowsAndBoundsOutput() {
        var reducer = TerminalScrollIntentReducer()
        var state = TerminalScrollIntentReducer.State()
        let context = TerminalScrollContext(surface: .alternate, mouseReporting: false, rowHeight: 20, rowCount: 24)

        _ = reducer.reduce(.init(phase: .began), context: context, state: &state)
        let intents = reducer.reduce(.init(phase: .changed, translationY: -85), context: context, state: &state)
        XCTAssertEqual(intents, [.key(.up), .key(.up), .key(.up), .key(.up)])
        XCTAssertLessThanOrEqual(intents.count, 4)
    }

    func testMouseModeUsesWheelButtonsAndCancellationDoesNotLeakInput() {
        var reducer = TerminalScrollIntentReducer()
        var state = TerminalScrollIntentReducer.State()
        let context = TerminalScrollContext(surface: .alternate, mouseReporting: true)

        _ = reducer.reduce(.init(phase: .began), context: context, state: &state)
        XCTAssertEqual(
            reducer.reduce(.init(phase: .changed, translationY: -30), context: context, state: &state),
            [.mouseWheel(.up)]
        )
        XCTAssertEqual(
            reducer.reduce(.init(phase: .changed, translationY: 30), context: context, state: &state),
            [.mouseWheel(.down)]
        )
        XCTAssertTrue(reducer.reduce(.init(phase: .cancelled), context: context, state: &state).isEmpty)
        XCTAssertTrue(reducer.reduce(.init(phase: .changed, translationY: 100), context: context, state: &state).isEmpty)
    }

    func testMouseModeBatchesWheelTicksWithinReducerLimit() {
        var reducer = TerminalScrollIntentReducer()
        var state = TerminalScrollIntentReducer.State()
        let context = TerminalScrollContext(surface: .alternate, mouseReporting: true, rowHeight: 20)

        _ = reducer.reduce(.init(phase: .began), context: context, state: &state)
        XCTAssertEqual(
            reducer.reduce(.init(phase: .changed, translationY: -100), context: context, state: &state),
            Array(repeating: .mouseWheel(.up), count: 4),
            "Large movement remains batched but bounded to four wheel ticks"
        )
    }

    func testVelocityIsBoundedAndCanRequestPageIntent() {
        var reducer = TerminalScrollIntentReducer(maximumIntentsPerUpdate: 8)
        var state = TerminalScrollIntentReducer.State()
        let context = TerminalScrollContext(surface: .alternate, mouseReporting: false, rowHeight: 20, rowCount: 24)

        _ = reducer.reduce(.init(phase: .began), context: context, state: &state)
        let intents = reducer.reduce(.init(phase: .changed, translationY: -100, velocityY: -10_000), context: context, state: &state)
        XCTAssertEqual(intents.first, .key(.pageUp))
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
        let upIntents = reducer.reduce(.init(phase: .changed, translationY: -85), context: context, state: &state)
        XCTAssertFalse(upIntents.isEmpty, "Alternate screen touches must not be swallowed when copyModeFallback is unavailable")
        XCTAssertEqual(upIntents, [.key(.up), .key(.up), .key(.up), .key(.up)])

        let downIntents = reducer.reduce(.init(phase: .changed, translationY: 50), context: context, state: &state)
        XCTAssertFalse(downIntents.isEmpty)
        XCTAssertEqual(downIntents, [.key(.down), .key(.down)])
    }

    func testFallbackStateResetsAfterModeExit() {
        var reducer = TerminalScrollIntentReducer()
        var state = TerminalScrollIntentReducer.State()
        let context = TerminalScrollContext(
            surface: .alternate,
            mouseReporting: false,
            copyModeFallbackAvailable: true
        )

        XCTAssertEqual(reducer.reduce(.init(phase: .began), context: context, state: &state), [.copyModeFallback])
        XCTAssertEqual(reducer.reduce(.init(phase: .ended), context: context, state: &state), [])
        XCTAssertEqual(reducer.reduce(.init(phase: .began), context: context, state: &state), [.copyModeFallback])

        XCTAssertEqual(reducer.reduce(.init(phase: .cancelled), context: context, state: &state), [])
        XCTAssertEqual(reducer.reduce(.init(phase: .began), context: context, state: &state), [.copyModeFallback])
    }
}
