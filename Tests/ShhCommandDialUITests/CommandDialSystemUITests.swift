import XCTest

final class CommandDialSystemUITests: XCTestCase {
    private let timeout: TimeInterval = 20

    func testCommandDialProductionAccessibilityPath() throws {
        continueAfterFailure = false

        let app = XCUIApplication()
        app.launchArguments = ["--demo"]
        app.launchEnvironment["SHH_DEMO_MODE"] = "1"
        addTeardownBlock { [weak self] in
            guard let self, app.state != .notRunning else { return }
            self.capture(app, named: "teardown")
        }

        app.launch()
        capture(app, named: "hosts")

        let demoHost = app.staticTexts["Demo Workbox"]
        XCTAssertTrue(demoHost.waitForExistence(timeout: timeout), app.debugDescription)
        XCTAssertTrue(demoHost.isHittable)
        demoHost.tap()

        let connect = app.buttons["Connect"]
        require(connect, in: app, named: "Connect").tap()

        let trustAlert = app.alerts["Approve Host Key?"]
        XCTAssertTrue(trustAlert.waitForExistence(timeout: timeout), app.debugDescription)
        capture(app, named: "trust-alert")
        let trustOnce = trustAlert.buttons["Trust Once"]
        require(trustOnce, in: app, named: "Trust Once").tap()

        let openSession = app.buttons["Open session"]
        let openSessionTarget = require(openSession, in: app, named: "Open session")
        verifyHostDetailActionRow(app, footer: openSessionTarget)

        let openSessionFrame = openSessionTarget.frame
        XCTAssertGreaterThanOrEqual(
            openSessionFrame.width, 44,
            "Open session target is narrower than 44 points: actual frame \(openSessionFrame)")
        XCTAssertGreaterThanOrEqual(
            openSessionFrame.height, 44,
            "Open session target is shorter than 44 points: actual frame \(openSessionFrame)")
        let edgeInset: CGFloat = 2.5
        let nearBottomEdge = openSessionTarget.coordinate(
            withNormalizedOffset: CGVector(
                dx: 0.5,
                dy: max(0, 1 - edgeInset / openSessionFrame.height)))
        nearBottomEdge.tap()

        let trigger = app.buttons["command-dial-trigger"]
        _ = requireDialTarget(trigger, in: app, named: "command-dial-trigger")
        capture(app, named: "session-trigger")
        trigger.tap()

        let surface = app.otherElements["command-dial-surface"]
        _ = require(surface, in: app, named: "command-dial-surface")
        capture(app, named: "dial-root")

        let rootInput = app.buttons["command-dial-node-root-input"]
        requireDialTarget(rootInput, in: app, named: "command-dial-node-root-input").tap()
        capture(app, named: "dial-input")

        let navigate = app.buttons["command-dial-node-input-navigate"]
        requireDialTarget(navigate, in: app, named: "command-dial-node-input-navigate").tap()
        capture(app, named: "dial-navigate")

        let cursor = requireDialTarget(
            app.buttons["command-dial-node-input-navigate-cursor"],
            in: app,
            named: "command-dial-node-input-navigate-cursor")
        capture(app, named: "dial-cursor")
        cursor.tap()
        let expectedCursorChildren = [
            "command-dial-node-key-arrow-up",
            "command-dial-node-key-arrow-right",
            "command-dial-node-key-arrow-down",
            "command-dial-node-key-arrow-left",
        ]
        for identifier in expectedCursorChildren {
            _ = requireDialTarget(
                app.buttons[identifier], in: app, named: "cursor-child-\(identifier)")
        }
        XCTAssertTrue(surface.exists, "Cursor activation must leave the dial rendered")
        capture(app, named: "dial-cursor-children")

        tapHome(in: app, named: "command-dial-home-back")
        _ = requireDialTarget(
            app.buttons["command-dial-node-input-navigate-cursor"],
            in: app,
            named: "command-dial-node-input-navigate-cursor-after-back")
        tapHome(in: app, named: "command-dial-home-navigate")
        _ = requireDialTarget(
            app.buttons["command-dial-node-input-navigate"],
            in: app,
            named: "command-dial-node-input-navigate-after-back")
        tapHome(in: app, named: "command-dial-home-input")
        _ = requireDialTarget(
            app.buttons["command-dial-node-root-input"],
            in: app,
            named: "command-dial-node-root-input-after-back")
        tapHome(in: app, named: "command-dial-home-root-close")
        XCTAssertFalse(surface.waitForExistence(timeout: 2), app.debugDescription)
        capture(app, named: "dial-closed")

        requireDialTarget(trigger, in: app, named: "command-dial-trigger-reopened").tap()
        _ = require(surface, in: app, named: "command-dial-surface-reopened")
        let reopenedInput = app.buttons["command-dial-node-root-input"]
        _ = requireDialTarget(
            reopenedInput, in: app, named: "command-dial-node-root-input-reopened")
        capture(app, named: "dial-reopened")
        tapHome(in: app, named: "command-dial-home-final-close")
        XCTAssertFalse(surface.waitForExistence(timeout: 2), app.debugDescription)
    }

    private func verifyHostDetailActionRow(_ app: XCUIApplication, footer: XCUIElement) {
        let collection = app.collectionViews.firstMatch
        XCTAssertTrue(collection.waitForExistence(timeout: timeout), app.debugDescription)
        let edit = app.buttons["Edit"]
        XCTAssertTrue(edit.waitForExistence(timeout: timeout), app.debugDescription)
        XCTAssertFalse(edit.frame.isEmpty, "No accessibility frame: Edit")
        capture(app, named: "host-detail-open-session-before-tap")

        var actionRowRevealed = false
        for _ in 0..<8 {
            let editFrame = edit.frame
            let footerFrame = footer.frame
            if edit.isEnabled && edit.isHittable && !editFrame.isEmpty
                && editFrame.maxY <= footerFrame.minY
            {
                actionRowRevealed = true
                break
            }
            collection.swipeUp()
        }
        XCTAssertTrue(
            actionRowRevealed,
            "Edit action row was not fully revealed above the fixed footer: "
                + "edit=\(edit.frame), footer=\(footer.frame)")
        XCTAssertTrue(edit.isEnabled, "Edit action is disabled")
        XCTAssertTrue(edit.isHittable, "Edit action is not hittable after bounded scrolling")
        let revealedEditFrame = edit.frame
        let revealedFooterFrame = footer.frame
        XCTAssertLessThanOrEqual(
            revealedEditFrame.maxY, revealedFooterFrame.minY,
            "Edit action overlaps the Open session footer: "
                + "edit=\(revealedEditFrame), footer=\(revealedFooterFrame)")
        capture(app, named: "host-detail-action-row-revealed")
    }

    private func require(
        _ element: XCUIElement, in app: XCUIApplication, named name: String
    ) -> XCUIElement {
        XCTAssertTrue(element.waitForExistence(timeout: timeout), "Missing \(name)")
        XCTAssertTrue(element.isHittable, "Not hittable: \(name)")
        let frame = element.frame
        XCTAssertFalse(frame.isEmpty, "No accessibility frame: \(name)")
        let appFrame = app.windows.firstMatch.frame
        let roundingTolerance: CGFloat = 1
        XCTAssertGreaterThanOrEqual(
            frame.minX, appFrame.minX - roundingTolerance,
            "Target extends left of app window: \(name)")
        XCTAssertGreaterThanOrEqual(
            frame.minY, appFrame.minY - roundingTolerance,
            "Target extends above app window: \(name)")
        XCTAssertLessThanOrEqual(
            frame.maxX, appFrame.maxX + roundingTolerance,
            "Target extends right of app window: \(name)")
        XCTAssertLessThanOrEqual(
            frame.maxY, appFrame.maxY + roundingTolerance,
            "Target extends below app window: \(name)")
        return element
    }

    private func requireDialTarget(
        _ element: XCUIElement, in app: XCUIApplication, named name: String
    ) -> XCUIElement {
        let target = require(element, in: app, named: name)
        XCTAssertGreaterThanOrEqual(
            target.frame.width, 44, "Target is narrower than 44 points: \(name)")
        XCTAssertGreaterThanOrEqual(
            target.frame.height, 44, "Target is shorter than 44 points: \(name)")
        return target
    }

    private func tapHome(in app: XCUIApplication, named name: String) {
        let home = app.buttons["command-dial-home"]
        requireDialTarget(home, in: app, named: name).tap()
        capture(app, named: name)
    }

    private func capture(_ app: XCUIApplication, named name: String) {
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
