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

    @MainActor
    func testTerminalControllerCopyModeFallbackAvailabilityGating() {
        let controller = ShhTerminalController()

        // 1. Both disabled
        XCTAssertFalse(controller.copyModeFallbackEnabled)
        XCTAssertNil(controller.onCopyModeFallbackRequested)
        XCTAssertFalse(controller.isCopyModeFallbackAvailable)
        XCTAssertFalse(controller.copyModeFallbackAvailable)

        // 2. Enabled by session layer, but no handler registered (production state)
        controller.copyModeFallbackEnabled = true
        XCTAssertFalse(controller.isCopyModeFallbackAvailable)
        XCTAssertFalse(controller.copyModeFallbackAvailable)

        var requested = false
        controller.requestCopyModeFallback()
        XCTAssertFalse(requested, "Requesting copy mode fallback when unavailable must be a no-op")

        // 3. Enabled and handler registered
        controller.onCopyModeFallbackRequested = { requested = true }
        XCTAssertTrue(controller.isCopyModeFallbackAvailable)
        XCTAssertTrue(controller.copyModeFallbackAvailable)

        controller.requestCopyModeFallback()
        XCTAssertTrue(requested)

        // 4. Handler registered, but session layer disables fallback
        requested = false
        controller.copyModeFallbackEnabled = false
        XCTAssertFalse(controller.isCopyModeFallbackAvailable)
        XCTAssertFalse(controller.copyModeFallbackAvailable)

        controller.requestCopyModeFallback()
        XCTAssertFalse(requested)
    }
}

#if canImport(UIKit)
import UIKit
import SwiftTerm

extension TerminalScrollIntentTests {
    private func resolveEvidenceDirectory() -> URL? {
        if let envPath = ProcessInfo.processInfo.environment["EVIDENCE_DIR"], !envPath.isEmpty {
            let url = URL(fileURLWithPath: envPath, isDirectory: true)
            if (try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)) != nil ||
                FileManager.default.fileExists(atPath: url.path) {
                return url
            }
        }
        let fallback = FileManager.default.temporaryDirectory.appendingPathComponent("shh-evidence", isDirectory: true)
        if (try? FileManager.default.createDirectory(at: fallback, withIntermediateDirectories: true)) != nil ||
            FileManager.default.fileExists(atPath: fallback.path) {
            return fallback
        }
        return FileManager.default.temporaryDirectory
    }

    @MainActor
    private func saveSnapshot(view: UIView, named filename: String) {
        guard let directory = resolveEvidenceDirectory() else { return }
        let cleanName = URL(fileURLWithPath: filename).lastPathComponent
        let targetURL = directory.appendingPathComponent(cleanName)
        let renderer = UIGraphicsImageRenderer(bounds: view.bounds)
        let image = renderer.image { ctx in
            view.layer.render(in: ctx.cgContext)
        }
        if let png = image.pngData() {
            try? png.write(to: targetURL)
        }
    }

    @MainActor
    private func saveSnapshot(view: UIView, filename: String) {
        saveSnapshot(view: view, named: filename)
    }

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
        saveSnapshot(view: hostView, filename: "terminal-primary-buffer.png")

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
        saveSnapshot(view: hostView, filename: "terminal-mouse-reporting.png")

        XCTAssertTrue(hostView.gestureRecognizerShouldBegin(hostView.scrollGesture))

        var ptyOutput = Data()
        controller.onOutput = { ptyOutput.append($0) }

        // Swipe up (finger moves down -> translationY > 0 -> wheel up)
        hostView.processScrollGesture(
            phase: .began,
            translationY: 0,
            location: CGPoint(x: 100, y: 100)
        )
        hostView.processScrollGesture(
            phase: .changed,
            translationY: 50,
            location: CGPoint(x: 100, y: 100)
        )

        let received = String(decoding: ptyOutput, as: UTF8.self)
        XCTAssertTrue(received.contains("\u{1b}[<64;"), "Should contain SGR wheel-up sequence: \(received)")

        ptyOutput.removeAll()
        // Swipe down (finger moves up -> translationY < 0 -> wheel down)
        hostView.processScrollGesture(
            phase: .changed,
            translationY: -50,
            location: CGPoint(x: 100, y: 100)
        )
        let receivedDown = String(decoding: ptyOutput, as: UTF8.self)
        XCTAssertTrue(receivedDown.contains("\u{1b}[<65;"), "Should contain SGR wheel-down sequence: \(receivedDown)")

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
        saveSnapshot(view: hostView, filename: "terminal-alternate-buffer.png")

        XCTAssertTrue(hostView.gestureRecognizerShouldBegin(hostView.scrollGesture))

        var ptyOutput = Data()
        controller.onOutput = { ptyOutput.append($0) }

        // Small swipe up in alternate buffer -> arrow up
        hostView.processScrollGesture(phase: .began, translationY: 0)
        hostView.processScrollGesture(phase: .changed, translationY: 30)

        let receivedUp = String(decoding: ptyOutput, as: UTF8.self)
        XCTAssertTrue(receivedUp.contains("\u{1b}[A") || receivedUp.contains("\u{1b}OA"), "Expected arrow up sequence: \(receivedUp)")

        ptyOutput.removeAll()
        // High velocity swipe down -> page down
        hostView.processScrollGesture(phase: .changed, translationY: -100, velocityY: -3000)
        let receivedPageDown = String(decoding: ptyOutput, as: UTF8.self)
        XCTAssertTrue(receivedPageDown.contains("\u{1b}[6~"), "Expected page down sequence: \(receivedPageDown)")

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
        saveSnapshot(view: hostView, filename: "terminal-tmux-fallback.png")

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

        // 2. Changed phase with swipe up (translationY > 0 -> arrow up)
        hostView.processScrollGesture(phase: .changed, translationY: 30)
        let receivedUp = String(decoding: ptyOutput, as: UTF8.self)
        XCTAssertFalse(receivedUp.isEmpty, "Touch scrolling must never be swallowed when copy mode fallback handler is unwired")
        XCTAssertTrue(receivedUp.contains("\u{1b}[A") || receivedUp.contains("\u{1b}OA"), "Expected arrow up sequence: \(receivedUp)")

        ptyOutput.removeAll()
        // 3. Changed phase with high velocity swipe down -> page down
        hostView.processScrollGesture(phase: .changed, translationY: -100, velocityY: -3000)
        let receivedPageDown = String(decoding: ptyOutput, as: UTF8.self)
        XCTAssertFalse(receivedPageDown.isEmpty, "Touch scrolling must emit page navigation keys")
        XCTAssertTrue(receivedPageDown.contains("\u{1b}[6~"), "Expected page down sequence: \(receivedPageDown)")

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
