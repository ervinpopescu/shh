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

    @MainActor
    func testTerminalControllerCopyModeFallbackAvailabilityGating() {
        let controller = ShhTerminalController()

        // 1. Both disabled
        XCTAssertFalse(controller.copyModeFallbackEnabled)
        XCTAssertNil(controller.onCopyModeFallbackRequested)
        XCTAssertFalse(controller.isCopyModeFallbackAvailable)

        // 2. Enabled by session layer, but no handler registered (production state)
        controller.copyModeFallbackEnabled = true
        XCTAssertFalse(controller.isCopyModeFallbackAvailable)

        var requested = false
        controller.requestCopyModeFallback()
        XCTAssertFalse(requested, "Requesting copy mode fallback when unavailable must be a no-op")

        // 3. Enabled and handler registered
        controller.onCopyModeFallbackRequested = { requested = true }
        XCTAssertTrue(controller.isCopyModeFallbackAvailable)

        controller.requestCopyModeFallback()
        XCTAssertTrue(requested)

        // 4. Handler registered, but session layer disables fallback
        requested = false
        controller.copyModeFallbackEnabled = false
        XCTAssertFalse(controller.isCopyModeFallbackAvailable)

        controller.requestCopyModeFallback()
        XCTAssertFalse(requested)
    }
}

#if canImport(UIKit)
import UIKit
import SwiftTerm

extension TerminalScrollIntentTests {
    @MainActor
    func testHostViewPrimaryScreenScrollbackNeverInterceptsTouches() {
        let controller = ShhTerminalController()
        let options = TerminalOptions.default
        let hostView = ShhInternalTerminalHostView(
            frame: CGRect(x: 0, y: 0, width: 393, height: 852),
            options: options,
            controller: controller
        )
        let coordinator = ShhTerminalView.Coordinator(controller: controller)
        hostView.terminalDelegate = coordinator
        controller.attachEngine(hostView, firstResponder: hostView)

        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 393, height: 852))
        let vc = UIViewController()
        vc.view = hostView
        window.rootViewController = vc
        window.makeKeyAndVisible()
        hostView.layoutIfNeeded()

        hostView.feed(text: "shh-terminal: primary buffer\r\nline 1\r\nline 2\r\nline 3\r\n")

        var ptyOutput = Data()
        controller.onOutput = { ptyOutput.append($0) }
        var fallbackRequested = false
        controller.onCopyModeFallbackRequested = { fallbackRequested = true }

        // Primary buffer, mouse reporting off
        XCTAssertFalse(hostView.gestureRecognizerShouldBegin(hostView.scrollGesture))

        // Even if gesture events are processed, native scroll produces 0 PTY bytes
        hostView.processScrollGesture(phase: .began, translationY: 0)
        hostView.processScrollGesture(phase: .changed, translationY: -100)
        hostView.processScrollGesture(phase: .ended, translationY: 0)

        XCTAssertTrue(ptyOutput.isEmpty, "Primary scrollback must never inject bytes into PTY")
        XCTAssertFalse(fallbackRequested)
    }

    @MainActor
    func testHostViewMouseModeTranslatesSwipesToWheelEvents() {
        let controller = ShhTerminalController()
        let hostView = ShhInternalTerminalHostView(
            frame: CGRect(x: 0, y: 0, width: 393, height: 852),
            options: .default,
            controller: controller
        )
        let coordinator = ShhTerminalView.Coordinator(controller: controller)
        hostView.terminalDelegate = coordinator
        controller.attachEngine(hostView, firstResponder: hostView)

        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 393, height: 852))
        let vc = UIViewController()
        vc.view = hostView
        window.rootViewController = vc
        window.makeKeyAndVisible()
        hostView.layoutIfNeeded()

        // Turn on SGR mouse tracking: 1000h (mouse tracking), 1006h (SGR mode)
        hostView.feed(text: "\u{1b}[?1000h\u{1b}[?1006h")
        hostView.feed(text: "htop - mouse reporting enabled\r\nTasks: 42, 110 thr; 1 running\r\n")

        XCTAssertTrue(hostView.gestureRecognizerShouldBegin(hostView.scrollGesture))

        var ptyOutput = Data()
        controller.onOutput = { ptyOutput.append($0) }

        // A physical upward swipe has negative translation and reports wheel-up.
        hostView.processScrollGesture(
            phase: .began,
            translationY: 0,
            location: CGPoint(x: 100, y: 100)
        )
        hostView.processScrollGesture(
            phase: .changed,
            translationY: -50,
            location: CGPoint(x: 100, y: 100)
        )

        let terminal = hostView.getTerminal()
        let columnWidth = max(1, hostView.bounds.width / CGFloat(max(1, terminal.cols)))
        let rowHeight = max(1, hostView.bounds.height / CGFloat(max(1, terminal.rows)))
        let column = Int(floor(100 / columnWidth)) + 1
        let row = Int(floor(100 / rowHeight)) + 1
        XCTAssertEqual(
            Array(ptyOutput),
            Array("\u{1b}[<64;\(column);\(row)M".utf8),
            "One touch update must emit exactly one SGR wheel-up event"
        )

        ptyOutput.removeAll()
        hostView.processScrollGesture(phase: .ended, translationY: 0)

        // A separate physical downward swipe reports one wheel-down event.
        hostView.processScrollGesture(phase: .began, translationY: 0, location: CGPoint(x: 100, y: 100))
        hostView.processScrollGesture(
            phase: .changed,
            translationY: 50,
            location: CGPoint(x: 100, y: 100)
        )
        XCTAssertEqual(
            Array(ptyOutput),
            Array("\u{1b}[<65;\(column);\(row)M".utf8),
            "One touch update must emit exactly one SGR wheel-down event"
        )

        hostView.processScrollGesture(phase: .ended, translationY: 0)
    }

    @MainActor
    func testHostViewPrimaryTmuxMouseReportingRoutesWheelEvents() {
        let controller = ShhTerminalController()
        let hostView = ShhInternalTerminalHostView(
            frame: CGRect(x: 0, y: 0, width: 393, height: 852),
            options: .default,
            controller: controller
        )
        let coordinator = ShhTerminalView.Coordinator(controller: controller)
        hostView.terminalDelegate = coordinator
        controller.attachEngine(hostView, firstResponder: hostView)

        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 393, height: 852))
        let vc = UIViewController()
        vc.view = hostView
        window.rootViewController = vc
        window.makeKeyAndVisible()
        hostView.layoutIfNeeded()

        controller.copyModeFallbackEnabled = true
        hostView.feed(text: "\u{1b}[?1000h\u{1b}[?1006h")
        hostView.feed(text: "tmux: primary scrollback\r\nolder output\r\n")

        XCTAssertTrue(controller.copyModeFallbackEnabled)
        XCTAssertTrue(
            hostView.gestureRecognizerShouldBegin(hostView.scrollGesture),
            "Primary tmux scrolling must route through its enabled mouse protocol"
        )
        XCTAssertTrue(hostView.allowMouseReporting, "Mouse reporting stays enabled until the wheel gesture begins")

        var ptyOutput = Data()
        var fallbackRequested = false
        controller.onOutput = { ptyOutput.append($0) }
        controller.onCopyModeFallbackRequested = { fallbackRequested = true }

        hostView.processScrollGesture(phase: .began, translationY: 0, location: CGPoint(x: 0, y: 0))
        XCTAssertFalse(hostView.allowMouseReporting, "SwiftTerm's drag reporter must be suppressed during touch-wheel routing")
        hostView.processScrollGesture(phase: .changed, translationY: -50, location: CGPoint(x: 0, y: 0))
        let upOutput = String(decoding: ptyOutput, as: UTF8.self)
        XCTAssertTrue(upOutput.contains("\u{1b}[<64;1;1M"), "Expected tmux wheel-up event: \(upOutput)")

        ptyOutput.removeAll()
        hostView.processScrollGesture(phase: .changed, translationY: 50, location: CGPoint(x: 0, y: 0))
        let downOutput = String(decoding: ptyOutput, as: UTF8.self)
        XCTAssertTrue(downOutput.contains("\u{1b}[<65;1;1M"), "Expected tmux wheel-down event: \(downOutput)")

        hostView.processScrollGesture(phase: .ended, translationY: 0)
        XCTAssertTrue(hostView.allowMouseReporting)
        XCTAssertTrue(ptyOutput.count > 0)
        XCTAssertFalse(fallbackRequested, "Primary tmux scrolling must not enter copy mode")

        controller.copyModeFallbackEnabled = false
        hostView.setNeedsLayout()
        hostView.layoutIfNeeded()
        XCTAssertTrue(hostView.allowMouseReporting, "Leaving tmux mode must restore mouse reporting")
    }

    @MainActor
    func testHostViewPrimaryTmuxLegacyMouseReportingUsesLegacyWheelEncoding() {
        let controller = ShhTerminalController()
        let hostView = ShhInternalTerminalHostView(
            frame: CGRect(x: 0, y: 0, width: 393, height: 852),
            options: .default,
            controller: controller
        )
        let coordinator = ShhTerminalView.Coordinator(controller: controller)
        hostView.terminalDelegate = coordinator
        controller.attachEngine(hostView, firstResponder: hostView)

        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 393, height: 852))
        let vc = UIViewController()
        vc.view = hostView
        window.rootViewController = vc
        window.makeKeyAndVisible()
        hostView.layoutIfNeeded()

        // Keep tracking enabled but explicitly select the legacy X10 protocol.
        hostView.feed(text: "\u{1b}[?1000h\u{1b}[?1006l")
        var ptyOutput = Data()
        controller.onOutput = { ptyOutput.append($0) }

        hostView.processScrollGesture(
            phase: .began,
            translationY: 0,
            location: CGPoint(x: 0, y: 0)
        )
        hostView.processScrollGesture(
            phase: .changed,
            translationY: -50,
            location: CGPoint(x: 0, y: 0)
        )

        XCTAssertEqual(
            Array(ptyOutput),
            [0x1b, 0x5b, 0x4d, 0x60, 0x21, 0x21],
            "Legacy wheel-up must use button 4 and 1-based coordinates"
        )
        hostView.processScrollGesture(phase: .ended, translationY: 0)
    }

    @MainActor
    func testHostViewAlternateScreenQuantizesNavigationKeys() {
        let controller = ShhTerminalController()
        let hostView = ShhInternalTerminalHostView(
            frame: CGRect(x: 0, y: 0, width: 393, height: 852),
            options: .default,
            controller: controller
        )
        let coordinator = ShhTerminalView.Coordinator(controller: controller)
        hostView.terminalDelegate = coordinator
        controller.attachEngine(hostView, firstResponder: hostView)

        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 393, height: 852))
        let vc = UIViewController()
        vc.view = hostView
        window.rootViewController = vc
        window.makeKeyAndVisible()
        hostView.layoutIfNeeded()

        // Enter alternate screen buffer
        hostView.feed(text: "\u{1b}[?1049h")
        hostView.feed(text: "less README.md (alternate screen, no mouse)\r\nline 1\r\nline 2\r\n")

        XCTAssertTrue(hostView.gestureRecognizerShouldBegin(hostView.scrollGesture))

        var ptyOutput = Data()
        controller.onOutput = { ptyOutput.append($0) }

        // Physical swipe up in alternate buffer -> arrow up
        hostView.processScrollGesture(phase: .began, translationY: 0)
        hostView.processScrollGesture(phase: .changed, translationY: -30)

        let receivedUp = String(decoding: ptyOutput, as: UTF8.self)
        XCTAssertTrue(receivedUp.contains("\u{1b}[A") || receivedUp.contains("\u{1b}OA"), "Expected arrow up sequence: \(receivedUp)")

        ptyOutput.removeAll()
        // High velocity physical swipe up -> page up
        hostView.processScrollGesture(phase: .changed, translationY: -100, velocityY: -3000)
        let receivedPageDown = String(decoding: ptyOutput, as: UTF8.self)
        XCTAssertTrue(receivedPageDown.contains("\u{1b}[5~"), "Expected page up sequence: \(receivedPageDown)")

        hostView.processScrollGesture(phase: .ended, translationY: 0)
    }

    @MainActor
    func testHostViewTmuxFallbackSuppressesKeyInjectionAcrossFullGesture() {
        let controller = ShhTerminalController()
        let hostView = ShhInternalTerminalHostView(
            frame: CGRect(x: 0, y: 0, width: 393, height: 852),
            options: .default,
            controller: controller
        )
        let coordinator = ShhTerminalView.Coordinator(controller: controller)
        hostView.terminalDelegate = coordinator
        controller.attachEngine(hostView, firstResponder: hostView)

        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 393, height: 852))
        let vc = UIViewController()
        vc.view = hostView
        window.rootViewController = vc
        window.makeKeyAndVisible()
        hostView.layoutIfNeeded()

        // Enable tmux fallback mode and alternate buffer
        controller.copyModeFallbackEnabled = true
        hostView.feed(text: "\u{1b}[?1049h")
        hostView.feed(text: "[tmux 0:bash*] dev@server:~$\r\n")

        var fallbackCount = 0
        controller.onCopyModeFallbackRequested = { fallbackCount += 1 }

        var ptyOutput = Data()
        controller.onOutput = { ptyOutput.append($0) }

        // 1. Began phase emits fallback request
        hostView.processScrollGesture(phase: .began, translationY: 0)
        XCTAssertEqual(fallbackCount, 1, "Fallback callback must be invoked on began phase")
        XCTAssertTrue(ptyOutput.isEmpty, "Began phase must send 0 bytes to PTY")

        // 2. Changed phases with small, medium, and high velocity
        hostView.processScrollGesture(phase: .changed, translationY: -50, velocityY: -500)
        hostView.processScrollGesture(phase: .changed, translationY: 100, velocityY: 2000)
        hostView.processScrollGesture(phase: .changed, translationY: -200, velocityY: -5000)
        XCTAssertTrue(ptyOutput.isEmpty, "Changed phases must NEVER inject keys during fallback")

        // 3. Ended phase
        hostView.processScrollGesture(phase: .ended, translationY: 0)
        XCTAssertTrue(ptyOutput.isEmpty, "Ended phase must not send bytes to PTY")
        XCTAssertEqual(fallbackCount, 1, "Fallback callback should only be requested once per gesture")
    }

    @MainActor
    func testHostViewTmuxFallbackWithoutRegisteredHandlerEmitsNavigationKeysAndNeverSwallowsScrolling() {
        let controller = ShhTerminalController()
        let hostView = ShhInternalTerminalHostView(
            frame: CGRect(x: 0, y: 0, width: 393, height: 852),
            options: .default,
            controller: controller
        )
        let coordinator = ShhTerminalView.Coordinator(controller: controller)
        hostView.terminalDelegate = coordinator
        controller.attachEngine(hostView, firstResponder: hostView)

        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 393, height: 852))
        let vc = UIViewController()
        vc.view = hostView
        window.rootViewController = vc
        window.makeKeyAndVisible()
        hostView.layoutIfNeeded()

        // Enable tmux fallback mode, but keep onCopyModeFallbackRequested nil (production state)
        controller.copyModeFallbackEnabled = true
        XCTAssertNil(controller.onCopyModeFallbackRequested)
        XCTAssertFalse(controller.isCopyModeFallbackAvailable)

        hostView.feed(text: "\u{1b}[?1049h")
        hostView.feed(text: "[tmux 0:bash*] dev@server:~$\r\n")

        var ptyOutput = Data()
        controller.onOutput = { ptyOutput.append($0) }

        // 1. Began phase
        hostView.processScrollGesture(phase: .began, translationY: 0)
        XCTAssertTrue(ptyOutput.isEmpty, "Began phase must not send bytes to PTY")

        // 2. Changed phase with physical swipe up -> arrow up
        hostView.processScrollGesture(phase: .changed, translationY: -30)
        let receivedUp = String(decoding: ptyOutput, as: UTF8.self)
        XCTAssertFalse(receivedUp.isEmpty, "Touch scrolling must never be swallowed when copy mode fallback handler is unwired")
        XCTAssertTrue(receivedUp.contains("\u{1b}[A") || receivedUp.contains("\u{1b}OA"), "Expected arrow up sequence: \(receivedUp)")

        ptyOutput.removeAll()
        // 3. Changed phase with high velocity physical swipe up -> page up
        hostView.processScrollGesture(phase: .changed, translationY: -100, velocityY: -3000)
        let receivedPageDown = String(decoding: ptyOutput, as: UTF8.self)
        XCTAssertFalse(receivedPageDown.isEmpty, "Touch scrolling must emit page navigation keys")
        XCTAssertTrue(receivedPageDown.contains("\u{1b}[5~"), "Expected page up sequence: \(receivedPageDown)")

        hostView.processScrollGesture(phase: .ended, translationY: 0)
    }

    @MainActor
    func testHostViewGestureExclusivityAndSelectionProtection() {
        let controller = ShhTerminalController()
        let hostView = ShhInternalTerminalHostView(
            frame: CGRect(x: 0, y: 0, width: 393, height: 852),
            options: .default,
            controller: controller
        )

        // Alternate screen active
        hostView.feed(text: "\u{1b}[?1049h")
        XCTAssertTrue(hostView.gestureRecognizerShouldBegin(hostView.scrollGesture))

        // Select text
        hostView.feed(text: "Some selectable text")
        hostView.setSelectionRange(start: Position(col: 0, row: 0), end: Position(col: 5, row: 0))
        XCTAssertFalse(hostView.gestureRecognizerShouldBegin(hostView.scrollGesture), "Gesture must not begin when active selection exists")
        hostView.selectNone()
        XCTAssertTrue(hostView.gestureRecognizerShouldBegin(hostView.scrollGesture), "Clearing selection must restore scrolling")

        // Gesture simultaneous recognition:
        // Pinch zoom should recognize simultaneously
        let pinch = UIPinchGestureRecognizer()
        XCTAssertTrue(hostView.gestureRecognizer(hostView.scrollGesture, shouldRecognizeSimultaneouslyWith: pinch))

        // Other pan gesture (e.g. SwiftTerm mouse drag) should NOT recognize simultaneously
        let pan = UIPanGestureRecognizer()
        XCTAssertFalse(hostView.gestureRecognizer(hostView.scrollGesture, shouldRecognizeSimultaneouslyWith: pan))
    }
}
#endif
