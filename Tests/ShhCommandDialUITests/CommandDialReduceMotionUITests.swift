import XCTest

extension CommandDialKeyboardUITests {
    @objc func testCommandDialGenuineReduceMotionPreservesNavigation() throws {
        continueAfterFailure = false

        enableGenuineReduceMotionInSettings(
            XCUIApplication(bundleIdentifier: "com.apple.Preferences"))

        let app = XCUIApplication()
        app.launchArguments = ["--demo"]
        app.launchEnvironment["SHH_DEMO_MODE"] = "1"
        addTeardownBlock { [weak self] in
            guard let self, app.state != .notRunning else { return }
            self.captureReduceMotionState(app, named: "genuine-reduce-motion-teardown")
        }
        app.launch()
        completeDemoSessionSetup(app)
        let portrait = openRotationCursor(app)
        let landscape = verifyRotationLandscape(app, portrait: portrait)
        verifyRotationPortraitRestore(app, portrait: portrait, landscape: landscape)
    }

    private func enableGenuineReduceMotionInSettings(_ settings: XCUIApplication) {
        settings.launch()
        captureReduceMotionState(settings, named: "genuine-reduce-motion-settings-home")
        tapSettingsRow("Accessibility", in: settings)
        captureReduceMotionState(settings, named: "genuine-reduce-motion-accessibility")
        tapSettingsRow("Motion", in: settings)

        XCTAssertTrue(
            settings.navigationBars["Motion"].exists || settings.staticTexts["Motion"].exists,
            "Settings did not reach the native Motion page\n\(settings.debugDescription)"
        )
        let reduceMotionRows = settings.switches.matching(
            NSPredicate(format: "label == %@", "Reduce Motion")
        )
        let reduceMotionRow = reduceMotionRows.firstMatch
        guard reduceMotionRows.count == 1, reduceMotionRow.waitForExistence(timeout: 20) else {
            XCTFail(
                "Expected one native Reduce Motion switch row, found \(reduceMotionRows.count)\n"
                    + settings.debugDescription)
            return
        }
        let reduceMotionLeaves = reduceMotionRow.switches
        let reduceMotionLeaf = reduceMotionLeaves.firstMatch
        guard reduceMotionLeaves.count == 1, reduceMotionLeaf.waitForExistence(timeout: 20) else {
            XCTFail(
                "Expected one nested native Reduce Motion toggle, found \(reduceMotionLeaves.count)\n"
                    + settings.debugDescription)
            return
        }
        let owningCells = settings.cells.matching(identifier: "REDUCE_MOTION")
        let owningCell = owningCells.firstMatch
        guard owningCells.count == 1, owningCell.waitForExistence(timeout: 20) else {
            XCTFail(
                "Expected the Reduce Motion Settings table cell, found \(owningCells.count)\n"
                    + settings.debugDescription)
            return
        }
        XCTAssertTrue(reduceMotionLeaf.isHittable, settings.debugDescription)
        let rowFrame = reduceMotionRow.frame
        let leafFrame = reduceMotionLeaf.frame
        let owningCellFrame = owningCell.frame
        let settingsWindowFrame = settings.windows.firstMatch.frame
        let frameTolerance: CGFloat = 1
        XCTAssertTrue(
            !rowFrame.isEmpty && !leafFrame.isEmpty && !owningCellFrame.isEmpty,
            settings.debugDescription)
        XCTAssertTrue(
            settingsWindowFrame.contains(owningCellFrame)
                && settingsWindowFrame.contains(leafFrame),
            settings.debugDescription)
        let tolerantCellFrame = owningCellFrame.insetBy(
            dx: -frameTolerance, dy: -frameTolerance)
        XCTAssertTrue(
            tolerantCellFrame.contains(rowFrame) && tolerantCellFrame.contains(leafFrame),
            settings.debugDescription)

        let initialLeafValue = reduceMotionLeaf.value as? String
        guard let initialLeafValue, ["0", "1"].contains(initialLeafValue) else {
            XCTFail(
                "Unexpected native Reduce Motion toggle value: "
                    + "\(reduceMotionLeaf.value ?? "nil")\n\(settings.debugDescription)")
            return
        }
        print(
            "native Motion before toggle rowFrame=\(rowFrame) rowValue=\(reduceMotionRow.value ?? "nil") "
                + "leafFrame=\(leafFrame) leafValue=\(initialLeafValue)")
        captureReduceMotionState(settings, named: "genuine-reduce-motion-motion-before-toggle")
        if initialLeafValue == "0" {
            reduceMotionLeaf.tap()
        }

        let enabledExpectation = XCTNSPredicateExpectation(
            predicate: NSPredicate { _, _ in
                reduceMotionRow.value as? String == "1"
                    && reduceMotionLeaf.value as? String == "1"
            },
            object: nil)
        let enabledResult = XCTWaiter.wait(for: [enabledExpectation], timeout: 20)
        XCTAssertEqual(
            enabledResult, .completed,
            "Native Settings did not enable the actual Reduce Motion toggle\n"
                + settings.debugDescription)
        XCTAssertEqual(
            reduceMotionLeaf.value as? String, "1",
            "Native Settings leaf toggle is not on\n\(settings.debugDescription)")
        XCTAssertEqual(
            reduceMotionRow.value as? String, "1",
            "Native Settings Reduce Motion row is not on\n\(settings.debugDescription)")
        guard reduceMotionLeaf.value as? String == "1",
            reduceMotionRow.value as? String == "1"
        else { return }

        print(
            "native Motion after toggle rowFrame=\(reduceMotionRow.frame) "
                + "rowValue=\(reduceMotionRow.value ?? "nil") "
                + "leafFrame=\(reduceMotionLeaf.frame) "
                + "leafValue=\(reduceMotionLeaf.value ?? "nil")")
        captureReduceMotionState(settings, named: "genuine-reduce-motion-settings-enabled-proof")
    }

    private func tapSettingsRow(_ label: String, in settings: XCUIApplication) {
        let target = settings.staticTexts[label].firstMatch
        let scrollView = settings.scrollViews.firstMatch
        for _ in 0..<8 {
            if target.exists && target.isHittable {
                target.tap()
                return
            }
            if scrollView.exists && scrollView.isHittable {
                scrollView.swipeUp()
            } else {
                break
            }
        }
        XCTFail(
            "Native Settings row \(label) did not become visible and hittable\n\(settings.debugDescription)"
        )
    }

    private func captureReduceMotionState(_ app: XCUIApplication, named name: String) {
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
