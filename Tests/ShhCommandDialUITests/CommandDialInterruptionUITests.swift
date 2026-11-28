import XCTest

extension CommandDialKeyboardUITests {
    @objc func testCommandDialBackgroundResumePreservesCursorNavigation() throws {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchArguments = ["--demo"]
        app.launchEnvironment["SHH_DEMO_MODE"] = "1"
        app.launch()
        completeDemoSessionSetup(app)
        let cursor = prepareInterruptionCursor(app)
        let resumedHubPoint = backgroundAndResume(app, cursor: cursor)
        verifyInterruptionParentRoundTrip(app, cursor: cursor, resumedHubPoint: resumedHubPoint)
    }

    private struct CursorSnapshot {
        let ids: [String]
        let window: CGRect
        let surface: CGRect
        let path: String
        let targetFrames: [String: CGRect]
        let hubPoint: CGPoint
    }

    private func prepareInterruptionCursor(_ app: XCUIApplication) -> CursorSnapshot {
        let initial = openRotationCursor(app)
        let savedSurface = requireInterruptionElement(
            app.otherElements["command-dial-surface"], named: "initial surface"
        ).frame
        let savedPath = initial.path
        XCTAssertEqual(
            savedPath,
            "Demo Workbox, Primary terminal, Commands / Input / Navigate / Cursor, Connected, 4 actions",
            app.debugDescription)
        XCTAssertEqual(
            requireInterruptionElement(
                app.staticTexts["command-dial-breadcrumb"], named: "initial breadcrumb"
            ).label,
            savedPath)
        let cursorFrames = requireInterruptionTargets(
            app, identifiers: initial.cursorIDs, named: "before background")
        let cursorHub = requireInterruptionElement(
            app.buttons["command-dial-home"], named: "initial Cursor Back")
        let cursorHubPoint = cursorHub.frame.center
        XCTAssertEqual(cursorHubPoint.x, initial.cursorAnchor.x, accuracy: 1)
        XCTAssertEqual(cursorHubPoint.y, initial.cursorAnchor.y, accuracy: 1)
        assertInterruptionFrame(
            requireInterruptionElement(app.windows.firstMatch, named: "initial window").frame,
            equals: initial.window, named: "initial window")
        capture(app, named: "background-preservation-before")
        print(
            "background-preservation before state=\(app.state.rawValue) window=\(initial.window) "
                + "surface=\(savedSurface) path=\(savedPath) hub=\(cursorHubPoint) "
                + "targets=\(cursorFrames)")
        return CursorSnapshot(
            ids: initial.cursorIDs, window: initial.window, surface: savedSurface, path: savedPath,
            targetFrames: cursorFrames, hubPoint: cursorHubPoint)
    }

    private func backgroundAndResume(_ app: XCUIApplication, cursor: CursorSnapshot) -> CGPoint {
        XCUIDevice.shared.press(.home)
        waitForInterruptionAppState(app, .runningBackground, or: .runningBackgroundSuspended)
        XCTAssertTrue(
            app.state == .runningBackground || app.state == .runningBackgroundSuspended,
            "App did not reach a genuine background state: \(app.state.rawValue)")
        print("background-preservation observed background state=\(app.state.rawValue)")
        captureBackgroundEvidence(app)

        app.activate()
        waitForInterruptionAppState(app, .runningForeground)
        XCTAssertEqual(app.state, .runningForeground, "App did not return to foreground")
        let resumedWindow = requireInterruptionElement(
            app.windows.firstMatch, named: "resumed window"
        ).frame
        assertInterruptionFrame(resumedWindow, equals: cursor.window, named: "resumed window")
        let resumedSurface = requireInterruptionElement(
            app.otherElements["command-dial-surface"], named: "resumed surface"
        ).frame
        assertInterruptionFrame(resumedSurface, equals: cursor.surface, named: "resumed surface")
        let resumedPath = requireInterruptionElement(
            app.staticTexts["command-dial-breadcrumb"], named: "resumed breadcrumb"
        ).label
        XCTAssertEqual(resumedPath, cursor.path, app.debugDescription)
        let resumedFrames = requireInterruptionTargets(
            app, identifiers: cursor.ids, named: "after resume")
        for identifier in cursor.ids {
            assertInterruptionFrame(
                resumedFrames[identifier]!, equals: cursor.targetFrames[identifier]!,
                named: identifier)
        }
        let resumedHub = requireInterruptionElement(
            app.buttons["command-dial-home"], named: "resumed Cursor Back")
        XCTAssertEqual(resumedHub.frame.center.x, cursor.hubPoint.x, accuracy: 1)
        XCTAssertEqual(resumedHub.frame.center.y, cursor.hubPoint.y, accuracy: 1)
        print(
            "background-preservation resumed state=\(app.state.rawValue) window=\(resumedWindow) "
                + "surface=\(resumedSurface) path=\(resumedPath) "
                + "hub=\(resumedHub.frame.center) targets=\(resumedFrames)")
        capture(app, named: "background-preservation-resumed-cursor")
        return resumedHub.frame.center
    }

    private func verifyInterruptionParentRoundTrip(
        _ app: XCUIApplication, cursor: CursorSnapshot, resumedHubPoint: CGPoint
    ) {
        app.buttons["command-dial-home"].tap()
        let navigatePath =
            "Demo Workbox, Primary terminal, Commands / Input / Navigate, Connected, 3 actions"
        XCTAssertEqual(
            requireInterruptionElement(
                app.staticTexts["command-dial-breadcrumb"], named: "Navigate breadcrumb"
            ).label,
            navigatePath, app.debugDescription)
        for identifier in cursor.ids {
            XCTAssertFalse(
                app.buttons[identifier].exists, "Cursor leaf remained after Back: \(identifier)")
        }
        let returnedCursor = requireInterruptionElement(
            app.buttons["command-dial-node-input-navigate-cursor"], named: "returned Cursor card")
        XCTAssertTrue(returnedCursor.isEnabled, app.debugDescription)
        XCTAssertGreaterThanOrEqual(returnedCursor.frame.width, 44)
        XCTAssertGreaterThanOrEqual(returnedCursor.frame.height, 44)
        XCTAssertEqual(returnedCursor.frame.center.x, resumedHubPoint.x, accuracy: 1)
        XCTAssertEqual(returnedCursor.frame.center.y, resumedHubPoint.y, accuracy: 1)
        let navigateWindow = requireInterruptionElement(
            app.windows.firstMatch, named: "Navigate window"
        ).frame
        let navigateSurface = requireInterruptionElement(
            app.otherElements["command-dial-surface"], named: "Navigate surface"
        ).frame
        let navigateBack = requireInterruptionElement(
            app.buttons["command-dial-home"], named: "Navigate Back")
        let cursorCardPoint = returnedCursor.frame.center
        print(
            "background-preservation parent-round-trip path=\(navigatePath) "
                + "window=\(navigateWindow) surface=\(navigateSurface) "
                + "cursorCard=\(returnedCursor.frame) back=\(navigateBack.frame)")
        capture(app, named: "background-preservation-navigate-parent")

        let cursorCard = requireInterruptionElement(
            app.buttons["command-dial-node-input-navigate-cursor"],
            named: "Cursor card before activation")
        XCTAssertEqual(cursorCard.frame.center.x, cursorCardPoint.x, accuracy: 1)
        XCTAssertEqual(cursorCard.frame.center.y, cursorCardPoint.y, accuracy: 1)
        cursorCard.tap()
        XCTAssertEqual(
            requireInterruptionElement(
                app.staticTexts["command-dial-breadcrumb"], named: "restored Cursor breadcrumb"
            ).label,
            cursor.path, app.debugDescription)
        _ = requireInterruptionTargets(
            app, identifiers: cursor.ids, named: "after parent round trip")
        let finalBack = requireInterruptionElement(
            app.buttons["command-dial-home"], named: "restored Cursor Back")
        XCTAssertEqual(finalBack.frame.center.x, cursorCardPoint.x, accuracy: 1)
        XCTAssertEqual(finalBack.frame.center.y, cursorCardPoint.y, accuracy: 1)
        assertInterruptionFrame(
            requireInterruptionElement(app.windows.firstMatch, named: "final window").frame,
            equals: navigateWindow, named: "round-trip window")
        assertInterruptionFrame(
            requireInterruptionElement(
                app.otherElements["command-dial-surface"], named: "final surface"
            ).frame,
            equals: navigateSurface, named: "round-trip surface")
        print(
            "background-preservation parent-restored path=\(cursor.path) "
                + "back=\(finalBack.frame.center)")
        capture(app, named: "background-preservation-parent-restored")
    }

    private func captureBackgroundEvidence(_ app: XCUIApplication) {
        let screenshot = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        screenshot.name = "background-preservation-background-screenshot"
        screenshot.lifetime = .keepAlways
        add(screenshot)

        let state = XCTAttachment(string: "XCUIApplication.state.rawValue=\(app.state.rawValue)")
        state.name = "background-preservation-app-state"
        state.lifetime = .keepAlways
        add(state)
    }

    private func requireInterruptionElement(_ element: XCUIElement, named name: String)
        -> XCUIElement
    {
        XCTAssertTrue(element.waitForExistence(timeout: 20), "Missing \(name)")
        XCTAssertTrue(element.isHittable, "Not hittable: \(name)")
        return element
    }

    private func requireInterruptionTargets(
        _ app: XCUIApplication, identifiers: [String], named name: String
    ) -> [String: CGRect] {
        var frames: [String: CGRect] = [:]
        for identifier in identifiers {
            let target = requireInterruptionElement(
                app.buttons[identifier], named: "\(name) \(identifier)")
            XCTAssertTrue(target.isEnabled, "Disabled target: \(identifier)")
            XCTAssertGreaterThanOrEqual(target.frame.width, 44, identifier)
            XCTAssertGreaterThanOrEqual(target.frame.height, 44, identifier)
            frames[identifier] = target.frame
        }
        XCTAssertEqual(frames.count, 4)
        let back = requireInterruptionElement(
            app.buttons["command-dial-home"], named: "\(name) Back")
        XCTAssertTrue(back.isEnabled)
        XCTAssertGreaterThanOrEqual(back.frame.width, 44)
        XCTAssertGreaterThanOrEqual(back.frame.height, 44)
        return frames
    }

    private func waitForInterruptionAppState(
        _ app: XCUIApplication, _ state: XCUIApplication.State,
        or alternative: XCUIApplication.State? = nil
    ) {
        let expectation = XCTNSPredicateExpectation(
            predicate: NSPredicate { _, _ in
                app.state == state || (alternative != nil && app.state == alternative)
            }, object: nil)
        XCTAssertEqual(XCTWaiter.wait(for: [expectation], timeout: 20), .completed)
    }

    private func assertInterruptionFrame(
        _ actual: CGRect, equals expected: CGRect, named name: String
    ) {
        XCTAssertEqual(actual.minX, expected.minX, accuracy: 1, "\(name) minX")
        XCTAssertEqual(actual.minY, expected.minY, accuracy: 1, "\(name) minY")
        XCTAssertEqual(actual.width, expected.width, accuracy: 1, "\(name) width")
        XCTAssertEqual(actual.height, expected.height, accuracy: 1, "\(name) height")
    }
}

extension CGRect {
    fileprivate var center: CGPoint { CGPoint(x: midX, y: midY) }
}
