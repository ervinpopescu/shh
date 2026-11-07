import XCTest

private struct KeyboardGeometry {
    let windowFrame: CGRect
    let fullSurfaceFrame: CGRect
    let compactSurfaceFrame: CGRect
}

final class CommandDialKeyboardUITests: XCTestCase {
    private let timeout: TimeInterval = 20
    private let roundingTolerance: CGFloat = 1
    private let orbitTolerance: CGFloat = 1.5

    func testCommandDialNativeRotationPreservesCurrentNavigationAnchors() throws {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchArguments = ["--demo"]
        app.launchEnvironment["SHH_DEMO_MODE"] = "1"
        addTeardownBlock { [weak self] in
            guard let self, app.state != .notRunning else { return }
            self.capture(app, named: "rotation-teardown")
        }
        app.launch()
        completeDemoSessionSetup(app)
        let portrait = openRotationCursor(app)
        let landscape = verifyRotationLandscape(app, portrait: portrait)
        verifyRotationPortraitRestore(app, portrait: portrait, landscape: landscape)
    }

    func testCommandDialRealSoftwareKeyboardAcceptance() throws {
        continueAfterFailure = false

        let app = XCUIApplication()
        app.launchArguments = ["--demo"]
        app.launchEnvironment["SHH_DEMO_MODE"] = "1"
        addTeardownBlock { [weak self] in
            guard let self, app.state != .notRunning else { return }
            self.capture(app, named: "teardown")
        }

        app.launch()
        completeDemoSessionSetup(app)
        establishKeyboardHiddenState(app)
        let keyboardGeometry = runInitialKeyboardPhase(app)
        runCursorAndDismissPhase(app, geometry: keyboardGeometry)
    }

    private func runInitialKeyboardPhase(_ app: XCUIApplication) -> KeyboardGeometry {
        requireDialTarget(
            app.buttons["command-dial-trigger"], in: app, named: "command-dial-trigger"
        ).tap()
        let surface = require(
            app.otherElements["command-dial-surface"], in: app, named: "dial-surface-initial")
        let initialWindowFrame = app.windows.firstMatch.frame
        let fullSurfaceFrame = requireStableFrame(of: surface, named: "initial-full-surface")
        XCTAssertTrue(initialWindowFrame.contains(fullSurfaceFrame), app.debugDescription)
        let initialRootFrames = requireRootFrames(
            app, keyboardFrame: nil, viewportName: "initial-full-viewport")
        let initialHome = requireDialTarget(
            app.buttons["command-dial-home"], in: app, named: "initial-dial-home")
        let initialHeader = require(
            app.staticTexts["command-dial-breadcrumb"], in: app, named: "initial-dial-header")
        assertSurfaceGeometry(
            surface: surface, header: initialHeader, cards: initialRootFrames.values,
            hub: initialHome.frame, keyboardFrame: nil, named: "initial-full")
        capture(app, named: "dial-initial-full")
        print("initial surface=\(surface.frame) rootFrames=\(initialRootFrames)")
        assertRadialCenters(initialRootFrames, hubFrame: initialHome.frame, named: "initial-full")

        requireDialTarget(
            app.buttons["command-dial-node-root-input"], in: app, named: "root-input"
        ).tap()
        requireDialTarget(
            app.buttons["command-dial-node-input-keyboard"], in: app, named: "input-keyboard"
        )
        .tap()

        continueKeyboardIntroductionIfPresent(app)
        let keyboardFrame = requireNormalKeyboard(app)
        let windowFrame = app.windows.firstMatch.frame
        XCTAssertTrue(
            windowFrame.contains(keyboardFrame),
            "Keyboard is not inside the app window: keyboard=\(keyboardFrame), window=\(windowFrame)"
        )
        print("software keyboard frame=\(keyboardFrame) window=\(windowFrame)")
        capture(app, named: "keyboard-visible-after-dial-action")

        requireDialTarget(
            app.buttons["command-dial-trigger"], in: app, named: "trigger-after-keyboard-action"
        )
        .tap()
        let compactSurface = require(
            app.otherElements["command-dial-surface"], in: app, named: "dial-surface-compact")
        let compactKeyboardFrame = requireStableKeyboardFrame(
            app, named: "compact-keyboard-after-dial-open")
        let compactSurfaceFrame = requireStableFrame(
            of: compactSurface, named: "compact-keyboard-surface")
        XCTAssertTrue(windowFrame.contains(compactSurfaceFrame), app.debugDescription)
        XCTAssertLessThan(
            compactSurfaceFrame.height, fullSurfaceFrame.height,
            "Compact surface did not shrink while the keyboard is visible: "
                + "full=\(fullSurfaceFrame), compact=\(compactSurfaceFrame)")
        print("surface full=\(fullSurfaceFrame) compact=\(compactSurfaceFrame)")
        let compactRootFrames = requireRootFrames(
            app, keyboardFrame: compactKeyboardFrame, viewportName: "compact-keyboard-viewport")
        let compactHome = requireDialTarget(
            app.buttons["command-dial-home"], in: app, named: "compact-dial-home")
        let compactHeader = require(
            app.staticTexts["command-dial-breadcrumb"], in: app, named: "compact-dial-header")
        assertSurfaceGeometry(
            surface: compactSurface, header: compactHeader, cards: compactRootFrames.values,
            hub: compactHome.frame, keyboardFrame: compactKeyboardFrame, named: "compact-keyboard")
        capture(app, named: "dial-compact-keyboard-visible")
        print("compact rootFrames=\(compactRootFrames) keyboard=\(compactKeyboardFrame)")
        assertRadialCenters(
            compactRootFrames, hubFrame: compactHome.frame, named: "compact-keyboard")
        return KeyboardGeometry(
            windowFrame: windowFrame, fullSurfaceFrame: fullSurfaceFrame,
            compactSurfaceFrame: compactSurfaceFrame)
    }

    private func runCursorAndDismissPhase(_ app: XCUIApplication, geometry: KeyboardGeometry) {
        let rootInput = requireDialTarget(
            app.buttons["command-dial-node-root-input"], in: app, named: "compact-root-input")
        let rootInputCenter = rootInput.frame.center
        rootInput.tap()
        let inputBack = requireDialTarget(
            app.buttons["command-dial-home"], in: app, named: "input-back")
        XCTAssertEqual(inputBack.frame.center.x, rootInputCenter.x, accuracy: roundingTolerance)
        XCTAssertEqual(inputBack.frame.center.y, rootInputCenter.y, accuracy: roundingTolerance)

        let navigate = requireDialTarget(
            app.buttons["command-dial-node-input-navigate"], in: app, named: "input-navigate")
        let navigateCenter = navigate.frame.center
        navigate.tap()
        let navigateBack = requireDialTarget(
            app.buttons["command-dial-home"], in: app, named: "navigate-back")
        XCTAssertEqual(navigateBack.frame.center.x, navigateCenter.x, accuracy: roundingTolerance)
        XCTAssertEqual(navigateBack.frame.center.y, navigateCenter.y, accuracy: roundingTolerance)

        let cursor = requireDialTarget(
            app.buttons["command-dial-node-input-navigate-cursor"],
            in: app,
            named: "input-navigate-cursor")
        let cursorCenter = cursor.frame.center
        cursor.tap()
        let cursorBack = requireDialTarget(
            app.buttons["command-dial-home"], in: app, named: "cursor-back")
        XCTAssertEqual(cursorBack.frame.center.x, cursorCenter.x, accuracy: roundingTolerance)
        XCTAssertEqual(cursorBack.frame.center.y, cursorCenter.y, accuracy: roundingTolerance)
        let cursorKeyboardFrame = requireStableKeyboardFrame(
            app, named: "compact-keyboard-after-cursor-open")

        let cursorIdentifiers = [
            "command-dial-node-key-arrow-up",
            "command-dial-node-key-arrow-right",
            "command-dial-node-key-arrow-down",
            "command-dial-node-key-arrow-left",
        ]
        var compactCursorFrames: [String: CGRect] = [:]
        var orderedCursorFrames: [(String, CGRect)] = []
        for identifier in cursorIdentifiers {
            let target = requireDialTarget(
                app.buttons[identifier], in: app, named: "compact-\(identifier)")
            requireFrameAboveKeyboard(
                target.frame,
                keyboardFrame: cursorKeyboardFrame,
                windowFrame: geometry.windowFrame,
                named: "compact-\(identifier)")
            compactCursorFrames[identifier] = target.frame
            orderedCursorFrames.append((identifier, target.frame))
        }
        XCTAssertEqual(compactCursorFrames.count, 4)
        let cursorHome = requireDialTarget(
            app.buttons["command-dial-home"], in: app, named: "compact-cursor-home")
        let cursorHeader = require(
            app.staticTexts["command-dial-breadcrumb"], in: app, named: "compact-cursor-header")
        let cursorSurface = require(
            app.otherElements["command-dial-surface"], in: app, named: "compact-cursor-surface")
        XCTAssertTrue(geometry.windowFrame.contains(cursorSurface.frame), app.debugDescription)
        assertSurfaceGeometry(
            surface: cursorSurface, header: cursorHeader, cards: compactCursorFrames.values,
            hub: cursorHome.frame, keyboardFrame: cursorKeyboardFrame, named: "compact-cursor")
        assertRadialCenters(
            compactCursorFrames, hubFrame: cursorHome.frame, named: "compact-cursor")
        assertCursorDirections(orderedCursorFrames, hubFrame: cursorHome.frame)
        capture(app, named: "dial-compact-cursor-children")
        print("compact cursorFrames=\(compactCursorFrames)")

        revealAccessoryDismissKeyboard(app).tap()
        XCTAssertTrue(waitForKeyboard(app, visible: false), app.debugDescription)
        let postDismissSurface = app.otherElements["command-dial-surface"]
        if postDismissSurface.exists {
            let fullCursorFrames = requireCursorFrames(
                app, identifiers: cursorIdentifiers, keyboardFrame: nil, viewportName: "full-cursor"
            )
            let settledSurfaceFrame = requireStableFrame(
                of: postDismissSurface, named: "post-dismiss-surface")
            XCTAssertTrue(
                geometry.windowFrame.contains(settledSurfaceFrame), app.debugDescription)
            assertViewportExpanded(settledSurfaceFrame, geometry: geometry, named: "post-dismiss")
            let fullHeader = require(
                app.staticTexts["command-dial-breadcrumb"], in: app,
                named: "full-cursor-header")
            let fullHome = requireDialTarget(
                app.buttons["command-dial-home"], in: app, named: "full-cursor-home")
            assertSurfaceGeometry(
                surface: postDismissSurface, header: fullHeader, cards: fullCursorFrames.values,
                hub: fullHome.frame, keyboardFrame: nil, named: "full-cursor")
            assertRadialCenters(fullCursorFrames, hubFrame: fullHome.frame, named: "full-cursor")
            capture(app, named: "dial-full-cursor-after-keyboard-dismiss")
            print("keyboard dismissal preserved dial path; full cursorFrames=\(fullCursorFrames)")
            return
        }

        print("keyboard dismissal also dismissed the command dial; path preservation not observed")
        requireDialTarget(
            app.buttons["command-dial-trigger"], in: app, named: "trigger-after-dismiss"
        ).tap()
        let reopenedSurface = require(
            app.otherElements["command-dial-surface"], in: app,
            named: "dial-surface-full-reopened")
        let reopenedSurfaceFrame = requireStableFrame(
            of: reopenedSurface, named: "reopened-full-surface")
        XCTAssertTrue(geometry.windowFrame.contains(reopenedSurfaceFrame), app.debugDescription)
        assertViewportExpanded(reopenedSurfaceFrame, geometry: geometry, named: "reopened")
        let reopenedRootFrames = requireRootFrames(
            app, keyboardFrame: nil, viewportName: "reopened-full-viewport")
        let reopenedHome = requireDialTarget(
            app.buttons["command-dial-home"], in: app, named: "reopened-dial-home")
        capture(app, named: "dial-full-reopened-after-keyboard-dismiss")
        print("reopened full rootFrames=\(reopenedRootFrames)")
        assertRadialCenters(
            reopenedRootFrames, hubFrame: reopenedHome.frame, named: "reopened-full")
    }

    func completeDemoSessionSetup(_ app: XCUIApplication) {
        let demoHost = app.staticTexts["Demo Workbox"]
        XCTAssertTrue(demoHost.waitForExistence(timeout: timeout), app.debugDescription)
        XCTAssertTrue(demoHost.isHittable, app.debugDescription)
        demoHost.tap()

        require(app.buttons["Connect"], in: app, named: "Connect").tap()
        let trustAlert = app.alerts["Approve Host Key?"]
        XCTAssertTrue(trustAlert.waitForExistence(timeout: timeout), app.debugDescription)
        require(trustAlert.buttons["Trust Once"], in: app, named: "Trust Once").tap()

        let openSession = require(app.buttons["Open session"], in: app, named: "Open session")
        let collection = app.collectionViews.firstMatch
        XCTAssertTrue(collection.waitForExistence(timeout: timeout), app.debugDescription)
        let edit = app.buttons["Edit"]
        XCTAssertTrue(edit.waitForExistence(timeout: timeout), app.debugDescription)
        for _ in 0..<8 {
            if edit.isEnabled && edit.isHittable && !edit.frame.isEmpty
                && edit.frame.maxY <= openSession.frame.minY
            {
                break
            }
            collection.swipeUp()
        }
        XCTAssertTrue(edit.isEnabled && edit.isHittable, app.debugDescription)
        XCTAssertLessThanOrEqual(edit.frame.maxY, openSession.frame.minY + roundingTolerance)

        let frame = openSession.frame
        XCTAssertGreaterThanOrEqual(frame.width, 44)
        XCTAssertGreaterThanOrEqual(frame.height, 44)
        let nearBottomEdge = openSession.coordinate(
            withNormalizedOffset: CGVector(
                dx: 0.5, dy: max(0, 1 - 2.5 / frame.height)))
        nearBottomEdge.tap()
        XCTAssertTrue(
            app.buttons["command-dial-trigger"].waitForExistence(timeout: timeout),
            app.debugDescription)
    }

    private func establishKeyboardHiddenState(_ app: XCUIApplication) {
        if app.keyboards.firstMatch.exists {
            revealAccessoryDismissKeyboard(app).tap()
            XCTAssertTrue(waitForKeyboard(app, visible: false), app.debugDescription)
        }
        XCTAssertFalse(app.keyboards.firstMatch.exists, app.debugDescription)
    }

    private func requireRootFrames(
        _ app: XCUIApplication, keyboardFrame: CGRect?, viewportName: String
    ) -> [String: CGRect] {
        let identifiers = [
            "command-dial-node-root-input",
            "command-dial-node-root-session",
            "command-dial-node-root-saved",
            "command-dial-node-root-share",
        ]
        var frames: [String: CGRect] = [:]
        let windowFrame = app.windows.firstMatch.frame
        for identifier in identifiers {
            let target = require(
                app.buttons[identifier], in: app, named: "\(viewportName)-\(identifier)",
                requireHittable: targetIsExpectedToBeEnabled(app.buttons[identifier]))
            if target.isEnabled {
                XCTAssertTrue(target.isHittable, "Enabled target is not hittable: \(identifier)")
            }
            XCTAssertGreaterThanOrEqual(target.frame.width, 44, identifier)
            XCTAssertGreaterThanOrEqual(target.frame.height, 44, identifier)
            if let keyboardFrame {
                requireFrameAboveKeyboard(
                    target.frame, keyboardFrame: keyboardFrame, windowFrame: windowFrame,
                    named: "\(viewportName)-\(identifier)")
            } else {
                requireFrameInside(target.frame, viewport: windowFrame, named: identifier)
            }
            frames[identifier] = target.frame
        }
        XCTAssertEqual(frames.count, 4)
        return frames
    }

    private func requireCursorFrames(
        _ app: XCUIApplication, identifiers: [String], keyboardFrame: CGRect?, viewportName: String
    ) -> [String: CGRect] {
        let windowFrame = app.windows.firstMatch.frame
        var frames: [String: CGRect] = [:]
        for identifier in identifiers {
            let target = requireDialTarget(
                app.buttons[identifier], in: app, named: "\(viewportName)-\(identifier)")
            if let keyboardFrame {
                requireFrameAboveKeyboard(
                    target.frame, keyboardFrame: keyboardFrame, windowFrame: windowFrame,
                    named: "\(viewportName)-\(identifier)")
            } else {
                requireFrameInside(target.frame, viewport: windowFrame, named: identifier)
            }
            frames[identifier] = target.frame
        }
        XCTAssertEqual(frames.count, 4)
        return frames
    }

}

extension CommandDialKeyboardUITests {
    @objc func testCommandDialSelectedCursorAfterBackKeepsCurrentTargets() throws {
        continueAfterFailure = false

        let app = XCUIApplication()
        app.launchArguments = ["--demo"]
        app.launchEnvironment["SHH_DEMO_MODE"] = "1"
        addTeardownBlock { [weak self] in
            guard let self, app.state != .notRunning else { return }
            self.capture(app, named: "selected-cursor-after-back-teardown")
        }
        app.launch()
        completeDemoSessionSetup(app)
        _ = openRotationCursor(app)
        let portraitWindow = requireRotationWindow(
            app, landscape: false, named: "selected-portrait")
        let cursorHub = requireDialTarget(
            app.buttons["command-dial-home"], in: app, named: "selected-cursor-hub-before-back")
        let cursorCenter = cursorHub.frame.center
        cursorHub.tap()
        let navigateHeader = require(
            app.staticTexts["command-dial-breadcrumb"], in: app,
            named: "selected-cursor-returned-navigate-header")
        XCTAssertTrue(
            navigateHeader.label.contains("Commands / Input / Navigate"), app.debugDescription)
        for identifier in rotationCursorIdentifiers {
            XCTAssertFalse(
                app.buttons[identifier].exists,
                "Cursor control remained on Navigate: \(identifier)\n\(app.debugDescription)")
        }

        let cursor = requireDialTarget(
            app.buttons["command-dial-node-input-navigate-cursor"], in: app,
            named: "selected-cursor-card-after-back")
        let complete = requireDialTarget(
            app.buttons["command-dial-node-input-navigate-complete"], in: app,
            named: "complete-card-next-to-selected-cursor")
        let control = requireDialTarget(
            app.buttons["command-dial-node-input-navigate-control"], in: app,
            named: "control-card-next-to-selected-cursor")
        let back = requireDialTarget(
            app.buttons["command-dial-home"], in: app, named: "navigate-back-after-cursor")
        XCTAssertEqual(cursor.frame.center.x, cursorCenter.x, accuracy: roundingTolerance)
        XCTAssertEqual(cursor.frame.center.y, cursorCenter.y, accuracy: roundingTolerance)

        let window = requireRotationWindow(app, landscape: false, named: "selected-after-back")
        XCTAssertEqual(window.width, portraitWindow.width, accuracy: roundingTolerance)
        XCTAssertEqual(window.height, portraitWindow.height, accuracy: roundingTolerance)
        let surface = require(
            app.otherElements["command-dial-surface"], in: app,
            named: "selected-cursor-after-back-surface")
        _ = requireStableFrame(of: surface, named: "selected-cursor-after-back-surface")
        let cards = [
            "Cursor": cursor.frame,
            "Complete": complete.frame,
            "Control": control.frame,
        ]
        assertSurfaceGeometry(
            surface: surface, header: navigateHeader, cards: cards.values, hub: back.frame,
            keyboardFrame: nil, named: "selected-cursor-after-back-portrait")
        capture(app, named: "selected-cursor-after-back-portrait")
        print(
            "selected portrait Navigate after Cursor Back window=\(window) "
                + "surface=\(surface.frame) cursor=\(cursor.frame) "
                + "complete=\(complete.frame) control=\(control.frame) back=\(back.frame)")
    }

    private func assertRadialCenters(
        _ frames: [String: CGRect], hubFrame: CGRect, named: String
    ) {
        let centers = frames.values.map(\.center)
        let hubCenter = hubFrame.center
        let radii = centers.map { hypot($0.x - hubCenter.x, $0.y - hubCenter.y) }
        let radiusSpread = (radii.max() ?? 0) - (radii.min() ?? 0)
        XCTAssertLessThanOrEqual(
            radiusSpread, orbitTolerance,
            "Centers do not share a radial orbit for \(named): hub=\(hubCenter), radii=\(radii), frames=\(frames)"
        )
        guard centers.count >= 3 else {
            XCTFail("Not enough centers for radial check: \(named)")
            return
        }
        let minX = centers.map(\.x).min() ?? 0
        let maxX = centers.map(\.x).max() ?? 0
        let minY = centers.map(\.y).min() ?? 0
        let maxY = centers.map(\.y).max() ?? 0
        let boundingArea = max(1, (maxX - minX) * (maxY - minY))
        var largestTriangleArea: CGFloat = 0
        for first in 0..<(centers.count - 2) {
            for second in (first + 1)..<(centers.count - 1) {
                for third in (second + 1)..<centers.count {
                    let firstCenter = centers[first]
                    let secondCenter = centers[second]
                    let thirdCenter = centers[third]
                    let area =
                        abs(
                            (secondCenter.x - firstCenter.x) * (thirdCenter.y - firstCenter.y)
                                - (secondCenter.y - firstCenter.y) * (thirdCenter.x - firstCenter.x)
                        ) / 2
                    largestTriangleArea = max(largestTriangleArea, area)
                }
            }
        }
        XCTAssertGreaterThan(
            largestTriangleArea, boundingArea * 0.01,
            "Root centers are effectively collinear for \(named): centers=\(centers)")
        print(
            "\(named) centers=\(centers) radii=\(radii) radiusSpread=\(radiusSpread) "
                + "largestTriangleArea=\(largestTriangleArea)"
        )
    }

    private func revealAccessoryDismissKeyboard(_ app: XCUIApplication) -> XCUIElement {
        let dismissKeyboard = app.buttons["terminal-accessory-dismiss-keyboard-button"]
        let knownAccessoryControl = app.buttons["terminal-accessory-tilde-button"]
        XCTAssertTrue(
            knownAccessoryControl.waitForExistence(timeout: timeout),
            "Missing public terminal accessory control\n\(app.debugDescription)")
        XCTAssertFalse(knownAccessoryControl.frame.isEmpty, app.debugDescription)

        guard
            let scrollView = app.scrollViews.allElementsBoundByIndex.first(where: {
                $0.buttons["terminal-accessory-tilde-button"].exists
            })
        else {
            XCTFail(
                "Missing production terminal accessory horizontal scroll view\n\(app.debugDescription)"
            )
            return dismissKeyboard
        }
        XCTAssertTrue(scrollView.exists, app.debugDescription)
        XCTAssertFalse(scrollView.frame.isEmpty, app.debugDescription)
        XCTAssertTrue(scrollView.frame.contains(knownAccessoryControl.frame.center))

        for _ in 0..<8 {
            let viewportFrame = scrollView.frame
            let dismissFrame = dismissKeyboard.frame
            let fullyContained = !dismissFrame.isEmpty && viewportFrame.contains(dismissFrame)
            if dismissKeyboard.exists && fullyContained {
                XCTAssertTrue(dismissKeyboard.isHittable, app.debugDescription)
                return require(
                    dismissKeyboard, in: app,
                    named: "terminal-accessory-dismiss-keyboard-button")
            }
            scrollView.swipeLeft()
        }
        let viewportFrame = scrollView.frame
        XCTAssertTrue(
            dismissKeyboard.exists && !dismissKeyboard.frame.isEmpty
                && viewportFrame.contains(dismissKeyboard.frame),
            "Dismiss control did not become fully visible in the production accessory viewport")
        return require(
            dismissKeyboard, in: app, named: "terminal-accessory-dismiss-keyboard-button")
    }

    private func requireStableKeyboardFrame(_ app: XCUIApplication, named: String) -> CGRect {
        let keyboard = app.keyboards.firstMatch
        XCTAssertTrue(keyboard.waitForExistence(timeout: timeout), app.debugDescription)
        var previousFrame: CGRect?
        var stableSamples = 0
        let expectation = XCTNSPredicateExpectation(
            predicate: NSPredicate { _, _ in
                let frame = keyboard.frame
                guard keyboard.exists, !frame.isEmpty, frame.width > 0, frame.height > 0 else {
                    return false
                }
                if previousFrame == frame {
                    stableSamples += 1
                } else {
                    previousFrame = frame
                    stableSamples = 0
                }
                return stableSamples >= 2
            }, object: nil)
        XCTAssertEqual(
            XCTWaiter.wait(for: [expectation], timeout: timeout), .completed,
            "Keyboard frame did not stabilize for \(named): \(app.debugDescription)")
        let frame = keyboard.frame
        XCTAssertGreaterThan(frame.width, 0, named)
        XCTAssertGreaterThan(frame.height, 0, named)
        return frame
    }

    private func requireStableFrame(of element: XCUIElement, named: String) -> CGRect {
        var previousFrame: CGRect?
        var stableSamples = 0
        let expectation = XCTNSPredicateExpectation(
            predicate: NSPredicate { _, _ in
                let frame = element.frame
                guard element.exists, !frame.isEmpty else { return false }
                if previousFrame == frame {
                    stableSamples += 1
                } else {
                    previousFrame = frame
                    stableSamples = 0
                }
                return stableSamples >= 2
            }, object: nil)
        XCTAssertEqual(
            XCTWaiter.wait(for: [expectation], timeout: timeout), .completed,
            "Frame did not stabilize for \(named)")
        return element.frame
    }

    private func assertViewportExpanded(
        _ settledFrame: CGRect, geometry: KeyboardGeometry, named: String
    ) {
        XCTAssertGreaterThan(
            settledFrame.height, geometry.compactSurfaceFrame.height,
            "Surface did not expand after keyboard dismissal (\(named)): "
                + "compact=\(geometry.compactSurfaceFrame), settled=\(settledFrame)")
        XCTAssertEqual(
            settledFrame.height, geometry.fullSurfaceFrame.height, accuracy: roundingTolerance,
            "Surface did not return to the initial full height (\(named)): "
                + "full=\(geometry.fullSurfaceFrame), settled=\(settledFrame)")
        print(
            "viewport expansion \(named): compact=\(geometry.compactSurfaceFrame) "
                + "settled=\(settledFrame) full=\(geometry.fullSurfaceFrame)")
    }

    @discardableResult
    private func waitForKeyboard(_ app: XCUIApplication, visible: Bool) -> Bool {
        let keyboard = app.keyboards.firstMatch
        let expectation = XCTNSPredicateExpectation(
            predicate: NSPredicate { _, _ in keyboard.exists == visible }, object: nil)
        _ = XCTWaiter.wait(for: [expectation], timeout: timeout)
        return keyboard.exists == visible
    }

    private func targetIsExpectedToBeEnabled(_ element: XCUIElement) -> Bool {
        guard element.waitForExistence(timeout: timeout) else { return false }
        return element.isEnabled
    }

    @discardableResult
    private func require(
        _ element: XCUIElement,
        in app: XCUIApplication,
        named name: String,
        requireHittable: Bool = true
    ) -> XCUIElement {
        XCTAssertTrue(
            element.waitForExistence(timeout: timeout), "Missing \(name)\n\(app.debugDescription)")
        if requireHittable {
            XCTAssertTrue(element.isHittable, "Not hittable: \(name)\n\(app.debugDescription)")
        }
        XCTAssertFalse(element.frame.isEmpty, "No accessibility frame: \(name)")
        return element
    }

    private func requireDialTarget(
        _ element: XCUIElement, in app: XCUIApplication, named name: String
    ) -> XCUIElement {
        let target = require(element, in: app, named: name)
        XCTAssertTrue(target.isEnabled, "Dial target is disabled: \(name)")
        XCTAssertGreaterThanOrEqual(
            target.frame.width, 44, "Target is narrower than 44 points: \(name)")
        XCTAssertGreaterThanOrEqual(
            target.frame.height, 44, "Target is shorter than 44 points: \(name)")
        return target
    }

}

extension CommandDialKeyboardUITests {
    private func assertSurfaceGeometry(
        surface: XCUIElement, header: XCUIElement, cards: Dictionary<String, CGRect>.Values,
        hub: CGRect, keyboardFrame: CGRect?, named: String
    ) {
        let visibleSurface =
            keyboardFrame.map {
                surface.frame.intersection(
                    CGRect(
                        x: surface.frame.minX, y: surface.frame.minY, width: surface.frame.width,
                        height: max(0, $0.minY - surface.frame.minY)))
            } ?? surface.frame
        XCTAssertFalse(visibleSurface.isEmpty, named)
        XCTAssertTrue(visibleSurface.contains(hub), "Hub is outside surface: \(named)")
        XCTAssertFalse(header.frame.intersects(hub), "Header intersects hub: \(named)")
        for card in cards {
            XCTAssertTrue(visibleSurface.contains(card), "Card is outside surface: \(named)")
            XCTAssertFalse(card.intersects(header.frame), "Card intersects header: \(named)")
            XCTAssertFalse(card.intersects(hub), "Card intersects hub: \(named)")
            XCTAssertTrue(surface.frame.contains(card), "Card is outside surface: \(named)")
        }
        let cardArray = Array(cards)
        for index in cardArray.indices {
            for otherIndex in cardArray.indices where otherIndex > index {
                XCTAssertFalse(
                    cardArray[index].intersects(cardArray[otherIndex]),
                    "Cards overlap: \(named) \(cardArray[index]) \(cardArray[otherIndex])")
            }
        }
    }

    private func assertCursorDirections(_ orderedFrames: [(String, CGRect)], hubFrame: CGRect) {
        let expected = [
            "command-dial-node-key-arrow-up", "command-dial-node-key-arrow-right",
            "command-dial-node-key-arrow-down", "command-dial-node-key-arrow-left",
        ]
        XCTAssertEqual(orderedFrames.map(\.0), expected)
        let centers = orderedFrames.map { $0.1.center }
        XCTAssertEqual(Set(centers.map { "\($0.x),\($0.y)" }).count, expected.count)
        XCTAssertTrue(orderedFrames.allSatisfy { $0.1.width >= 44 && $0.1.height >= 44 })
        XCTAssertTrue(orderedFrames.allSatisfy { !$0.1.intersects(hubFrame) })

        let vectors = centers.map {
            CGPoint(x: $0.x - hubFrame.midX, y: $0.y - hubFrame.midY)
        }
        let crossProducts = zip(vectors, vectors.dropFirst()).map { first, second in
            first.x * second.y - first.y * second.x
        }
        XCTAssertTrue(
            crossProducts.allSatisfy { abs($0) > 1 },
            "Cursor labels must occupy a real angular sweep: \(orderedFrames)")
        let sweepSign = crossProducts.first.map { $0 < 0 ? -1 : 1 } ?? 0
        XCTAssertNotEqual(sweepSign, 0)
        XCTAssertTrue(
            crossProducts.allSatisfy { ($0 < 0 ? -1 : 1) == sweepSign },
            "Cursor labels must follow the production model sequence around one inward fan: \(orderedFrames)"
        )
    }

    private func continueKeyboardIntroductionIfPresent(_ app: XCUIApplication) {
        let continueButton = app.buttons["Continue"]
        if continueButton.waitForExistence(timeout: 2) {
            XCTAssertTrue(continueButton.isHittable, app.debugDescription)
            continueButton.tap()
            let expectation = XCTNSPredicateExpectation(
                predicate: NSPredicate { _, _ in !continueButton.exists }, object: nil)
            XCTAssertEqual(
                XCTWaiter.wait(for: [expectation], timeout: timeout), .completed,
                "Keyboard introduction did not disappear before normal keyboard measurement")
        }
    }

    private func requireNormalKeyboard(_ app: XCUIApplication) -> CGRect {
        let keyboardFrame = requireStableKeyboardFrame(app, named: "normal-keyboard")
        let keyboard = app.keyboards.firstMatch
        let qKey = keyboard.keys["q"]
        XCTAssertTrue(qKey.waitForExistence(timeout: timeout), app.debugDescription)
        XCTAssertFalse(qKey.frame.isEmpty, app.debugDescription)
        XCTAssertGreaterThan(qKey.frame.width, 0, app.debugDescription)
        XCTAssertGreaterThan(qKey.frame.height, 0, app.debugDescription)
        XCTAssertTrue(qKey.isHittable, app.debugDescription)
        print("normal QWERTY keyboard is visible: frame=\(keyboardFrame), q=\(qKey.frame)")
        return keyboardFrame
    }

    func requireFrameAboveKeyboard(
        _ frame: CGRect, keyboardFrame: CGRect, windowFrame: CGRect, named name: String
    ) {
        let visibleViewport = CGRect(
            x: windowFrame.minX,
            y: windowFrame.minY,
            width: windowFrame.width,
            height: max(0, keyboardFrame.minY - windowFrame.minY))
        requireFrameInside(frame, viewport: visibleViewport, named: name)
    }

    func requireFrameInside(_ frame: CGRect, viewport: CGRect, named name: String) {
        XCTAssertGreaterThanOrEqual(frame.minX, viewport.minX - roundingTolerance, name)
        XCTAssertGreaterThanOrEqual(frame.minY, viewport.minY - roundingTolerance, name)
        XCTAssertLessThanOrEqual(frame.maxX, viewport.maxX + roundingTolerance, name)
        XCTAssertLessThanOrEqual(frame.maxY, viewport.maxY + roundingTolerance, name)
    }

    func capture(_ app: XCUIApplication, named name: String) {
        let screenshot = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        screenshot.name = "\(name)-screenshot"
        screenshot.lifetime = .keepAlways
        add(screenshot)

        let hierarchy = XCTAttachment(string: app.debugDescription)
        hierarchy.name = "\(name)-hierarchy"
        hierarchy.lifetime = .keepAlways
        add(hierarchy)
    }
}

extension CGRect {
    fileprivate var center: CGPoint { CGPoint(x: midX, y: midY) }
}

struct RotationGeometry {
    let window: CGRect
    let path: String
    let cursorIDs: [String]
    let cursorAnchor: CGPoint
}

extension CommandDialKeyboardUITests {
    func openRotationCursor(_ app: XCUIApplication) -> RotationGeometry {
        requireDialTarget(app.buttons["command-dial-trigger"], in: app, named: "rotation-trigger")
            .tap()
        let window = requireRotationWindow(app, landscape: false, named: "initial-portrait")
        let frames = requireRootFrames(app, keyboardFrame: nil, viewportName: "rotation-root")
        let surface = require(
            app.otherElements["command-dial-surface"], in: app, named: "rotation-root-surface")
        let hub = requireDialTarget(
            app.buttons["command-dial-home"], in: app, named: "rotation-root-hub")
        let header = require(
            app.staticTexts["command-dial-breadcrumb"], in: app, named: "rotation-root-header")
        assertRotationGeometry(
            surface: surface, header: header, frames: frames, hub: hub.frame, window: window,
            named: "root-portrait")
        assertRadialCenters(frames, hubFrame: hub.frame, named: "root-portrait")
        capture(app, named: "rotation-root-portrait")

        let input = requireDialTarget(
            app.buttons["command-dial-node-root-input"], in: app, named: "rotation-root-input")
        let inputCenter = input.frame.center
        input.tap()
        assertRotationBackAnchor(app, matching: inputCenter, named: "Input")
        let navigate = requireDialTarget(
            app.buttons["command-dial-node-input-navigate"], in: app,
            named: "rotation-input-navigate")
        let navigateCenter = navigate.frame.center
        navigate.tap()
        assertRotationBackAnchor(app, matching: navigateCenter, named: "Navigate")
        let cursor = requireDialTarget(
            app.buttons["command-dial-node-input-navigate-cursor"], in: app,
            named: "rotation-navigate-cursor")
        let cursorCenter = cursor.frame.center
        cursor.tap()
        assertRotationBackAnchor(app, matching: cursorCenter, named: "Cursor")
        let ids = rotationCursorIdentifiers
        let cursorFrames = requireCursorFrames(
            app, identifiers: ids, keyboardFrame: nil, viewportName: "rotation-cursor-portrait")
        let cursorSurface = require(
            app.otherElements["command-dial-surface"], in: app,
            named: "rotation-cursor-portrait-surface")
        let cursorHub = requireDialTarget(
            app.buttons["command-dial-home"], in: app, named: "rotation-cursor-portrait-hub")
        let cursorHeader = require(
            app.staticTexts["command-dial-breadcrumb"], in: app,
            named: "rotation-cursor-portrait-header")
        assertRotationGeometry(
            surface: cursorSurface, header: cursorHeader, frames: cursorFrames,
            hub: cursorHub.frame, window: window, named: "cursor-portrait")
        assertRadialCenters(cursorFrames, hubFrame: cursorHub.frame, named: "cursor-portrait")
        assertCursorDirections(ids.map { ($0, cursorFrames[$0]!) }, hubFrame: cursorHub.frame)
        capture(app, named: "rotation-cursor-portrait")
        print(
            "rotation portrait window=\(window) surface=\(cursorSurface.frame) header=\(cursorHeader.frame) hub=\(cursorHub.frame) frames=\(cursorFrames)"
        )
        return RotationGeometry(
            window: window, path: cursorHeader.label, cursorIDs: ids, cursorAnchor: cursorCenter)
    }

    func verifyRotationLandscape(_ app: XCUIApplication, portrait: RotationGeometry)
        -> CGRect
    {
        XCUIDevice.shared.orientation = .landscapeLeft
        let window = requireRotationWindowChange(
            app, from: portrait.window, landscape: true, named: "landscape-left")
        let surface = require(
            app.otherElements["command-dial-surface"], in: app, named: "rotation-landscape-surface")
        let header = require(
            app.staticTexts["command-dial-breadcrumb"], in: app, named: "rotation-landscape-header")
        XCTAssertEqual(header.label, portrait.path, app.debugDescription)
        let hub = requireDialTarget(
            app.buttons["command-dial-home"], in: app, named: "rotation-landscape-hub")
        let frames = requireCursorFrames(
            app, identifiers: portrait.cursorIDs, keyboardFrame: nil,
            viewportName: "rotation-landscape")
        assertRotationGeometry(
            surface: surface, header: header, frames: frames, hub: hub.frame, window: window,
            named: "cursor-landscape")
        assertRadialCenters(frames, hubFrame: hub.frame, named: "cursor-landscape")
        assertCursorDirections(portrait.cursorIDs.map { ($0, frames[$0]!) }, hubFrame: hub.frame)
        let anchor = hub.frame.center
        capture(app, named: "rotation-cursor-landscape-left")
        print(
            "rotation landscape window=\(window) surface=\(surface.frame) header=\(header.frame) hub=\(hub.frame) frames=\(frames)"
        )
        // Back targets the selected parent at the current level, not Cursor's former hub.
        app.buttons["command-dial-home"].tap()
        let navigateHeader = require(
            app.staticTexts["command-dial-breadcrumb"], in: app,
            named: "rotation-landscape-navigate-header")
        XCTAssertEqual(
            navigateHeader.label,
            "Demo Workbox, Primary terminal, Commands / Input / Navigate, Connected, 3 actions",
            app.debugDescription)
        for identifier in portrait.cursorIDs {
            XCTAssertFalse(
                app.buttons[identifier].exists,
                "Cursor control remained on Navigate: \(identifier)")
        }
        let cursor = requireDialTarget(
            app.buttons["command-dial-node-input-navigate-cursor"], in: app,
            named: "rotation-landscape-navigate-cursor")
        let returnedCursorCenter = cursor.frame.center
        capture(app, named: "rotation-navigate-landscape-after-back")
        XCTAssertEqual(returnedCursorCenter.x, anchor.x, accuracy: roundingTolerance)
        XCTAssertEqual(returnedCursorCenter.y, anchor.y, accuracy: roundingTolerance)

        cursor.tap()
        let restoredHeader = require(
            app.staticTexts["command-dial-breadcrumb"], in: app,
            named: "rotation-landscape-reactivated-cursor-header")
        XCTAssertEqual(restoredHeader.label, portrait.path, app.debugDescription)
        _ = requireDialTarget(
            app.buttons["command-dial-home"], in: app,
            named: "rotation-landscape-reactivated-cursor-hub")
        assertRotationBackAnchor(
            app, matching: returnedCursorCenter,
            named: "Cursor reselected landscape current parent")
        capture(app, named: "rotation-cursor-landscape-reactivated")
        return window
    }
}

extension CommandDialKeyboardUITests {
    private var rotationCursorIdentifiers: [String] {
        [
            "command-dial-node-key-arrow-up", "command-dial-node-key-arrow-right",
            "command-dial-node-key-arrow-down", "command-dial-node-key-arrow-left",
        ]
    }

    func verifyRotationPortraitRestore(
        _ app: XCUIApplication, portrait: RotationGeometry, landscape: CGRect
    ) {
        XCUIDevice.shared.orientation = .portrait
        let window = requireRotationWindowChange(
            app, from: landscape, landscape: false, named: "portrait-restored")
        XCTAssertEqual(window.minX, portrait.window.minX, accuracy: roundingTolerance)
        XCTAssertEqual(window.minY, portrait.window.minY, accuracy: roundingTolerance)
        XCTAssertEqual(window.width, portrait.window.width, accuracy: roundingTolerance)
        XCTAssertEqual(window.height, portrait.window.height, accuracy: roundingTolerance)
        let surface = require(
            app.otherElements["command-dial-surface"], in: app, named: "rotation-restored-surface")
        let header = require(
            app.staticTexts["command-dial-breadcrumb"], in: app, named: "rotation-restored-header")
        XCTAssertEqual(header.label, portrait.path, app.debugDescription)
        let hub = requireDialTarget(
            app.buttons["command-dial-home"], in: app, named: "rotation-restored-hub")
        let frames = requireCursorFrames(
            app, identifiers: portrait.cursorIDs, keyboardFrame: nil,
            viewportName: "rotation-restored")
        assertRotationGeometry(
            surface: surface, header: header, frames: frames, hub: hub.frame, window: window,
            named: "cursor-portrait-restored")
        assertRadialCenters(frames, hubFrame: hub.frame, named: "cursor-portrait-restored")
        assertCursorDirections(portrait.cursorIDs.map { ($0, frames[$0]!) }, hubFrame: hub.frame)
        // This is the same portrait viewport and path, so compare to its initial portrait anchor.
        let restoredHubCenter = hub.frame.center
        assertRotationBackAnchor(
            app, matching: portrait.cursorAnchor, named: "Cursor reselected in restored portrait")
        capture(app, named: "rotation-cursor-portrait-restored")
        print(
            "rotation restored window=\(window) surface=\(surface.frame) header=\(header.frame) hub=\(hub.frame) frames=\(frames)"
        )

        hub.tap()
        let navigateHeader = require(
            app.staticTexts["command-dial-breadcrumb"], in: app,
            named: "rotation-restored-navigate-header")
        XCTAssertEqual(
            navigateHeader.label,
            "Demo Workbox, Primary terminal, Commands / Input / Navigate, Connected, 3 actions",
            app.debugDescription)
        for identifier in portrait.cursorIDs {
            XCTAssertFalse(
                app.buttons[identifier].exists,
                "Cursor control remained on Navigate: \(identifier)")
        }
        let cursor = requireDialTarget(
            app.buttons["command-dial-node-input-navigate-cursor"], in: app,
            named: "rotation-restored-navigate-cursor")
        let currentParentCenter = cursor.frame.center
        XCTAssertEqual(
            currentParentCenter.x, restoredHubCenter.x, accuracy: roundingTolerance)
        XCTAssertEqual(
            currentParentCenter.y, restoredHubCenter.y, accuracy: roundingTolerance)
        capture(app, named: "rotation-navigate-portrait-restored-after-back")

        cursor.tap()
        let restoredCursorHeader = require(
            app.staticTexts["command-dial-breadcrumb"], in: app,
            named: "rotation-portrait-reactivated-cursor-header")
        XCTAssertEqual(restoredCursorHeader.label, portrait.path, app.debugDescription)
        assertRotationBackAnchor(
            app, matching: currentParentCenter, named: "Cursor reselected in restored portrait")
        capture(app, named: "rotation-cursor-portrait-restored-reactivated")
    }

    private func requireRotationWindow(_ app: XCUIApplication, landscape: Bool, named: String)
        -> CGRect
    {
        let window = app.windows.firstMatch
        let expectation = XCTNSPredicateExpectation(
            predicate: NSPredicate { _, _ in
                let frame = window.frame
                return window.exists && !frame.isEmpty && (frame.width > frame.height) == landscape
            }, object: nil)
        XCTAssertEqual(
            XCTWaiter.wait(for: [expectation], timeout: timeout), .completed,
            "Window did not reach \(named): \(app.debugDescription)")
        return requireStableFrame(of: window, named: "rotation-window-\(named)")
    }

    private func requireRotationWindowChange(
        _ app: XCUIApplication, from old: CGRect, landscape: Bool, named: String
    ) -> CGRect {
        let window = app.windows.firstMatch
        var previousFrame: CGRect?
        var stable = 0
        let expectation = XCTNSPredicateExpectation(
            predicate: NSPredicate { _, _ in
                let frame = window.frame
                guard window.exists, !frame.isEmpty, (frame.width > frame.height) == landscape,
                    frame != old
                else { return false }
                if previousFrame == frame {
                    stable += 1
                } else {
                    previousFrame = frame
                    stable = 0
                }
                return stable >= 2
            }, object: nil)
        XCTAssertEqual(
            XCTWaiter.wait(for: [expectation], timeout: timeout), .completed,
            "App window did not rotate for \(named): old=\(old), current=\(window.frame)\n\(app.debugDescription)"
        )
        let frame = requireStableFrame(of: window, named: "rotation-window-\(named)")
        let surface = require(
            app.otherElements["command-dial-surface"], in: app, named: "rotation-surface-\(named)")
        _ = requireStableFrame(of: surface, named: "rotation-surface-\(named)")
        return frame
    }

    private func assertRotationBackAnchor(
        _ app: XCUIApplication, matching center: CGPoint, named: String
    ) {
        let back = requireDialTarget(
            app.buttons["command-dial-home"], in: app, named: "rotation-back-\(named)")
        XCTAssertEqual(back.frame.center.x, center.x, accuracy: roundingTolerance)
        XCTAssertEqual(back.frame.center.y, center.y, accuracy: roundingTolerance)
    }

    private func assertRotationGeometry(
        surface: XCUIElement, header: XCUIElement, frames: [String: CGRect], hub: CGRect,
        window: CGRect, named: String
    ) {
        let surfaceFrame = requireStableFrame(of: surface, named: "rotation-surface-\(named)")
        requireFrameInside(surfaceFrame, viewport: window, named: "rotation-surface-\(named)")
        requireFrameInside(header.frame, viewport: surfaceFrame, named: "rotation-header-\(named)")
        assertSurfaceGeometry(
            surface: surface, header: header, cards: frames.values, hub: hub, keyboardFrame: nil,
            named: named)
        for (identifier, frame) in frames {
            XCTAssertGreaterThanOrEqual(frame.width, 44, identifier)
            XCTAssertGreaterThanOrEqual(frame.height, 44, identifier)
            requireFrameInside(frame, viewport: window, named: "rotation-\(named)-\(identifier)")
        }
    }
}
