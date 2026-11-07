import XCTest

final class SessionNavigationChromeUITests: XCTestCase {
    private let timeout: TimeInterval = 20

    func testSessionNavigationChromeFreshSystemMocha() throws {
        try runSessionChromeScenario(
            appAppearance: "System",
            terminalTheme: "catppuccinMocha",
            name: "system-mocha-fresh",
            configureSettings: false)
    }

    func testSessionNavigationChromeDarkAppMochaTerminal() throws {
        try runSessionChromeScenario(
            appAppearance: "Dark", terminalTheme: "catppuccinMocha", name: "dark-mocha")
    }

    func testSessionNavigationChromeLightAppMochaTerminal() throws {
        try runSessionChromeScenario(
            appAppearance: "Light", terminalTheme: "catppuccinMocha", name: "light-mocha")
    }

    func testSessionNavigationChromeLightAppLatteTerminal() throws {
        try runSessionChromeScenario(
            appAppearance: "Light", terminalTheme: "catppuccinLatte", name: "light-latte")
    }

    private func runSessionChromeScenario(
        appAppearance: String,
        terminalTheme: String,
        name: String,
        configureSettings: Bool = true
    ) throws {
        continueAfterFailure = false

        let app = XCUIApplication()
        app.launchArguments = ["--demo"]
        app.launchEnvironment["SHH_DEMO_MODE"] = "1"
        add(
            XCTAttachment(
                string:
                    "appAppearance=\(appAppearance)\nterminalTheme=\(terminalTheme)\nscenario=\(name)"
            ))
        addTeardownBlock { [weak self] in
            guard let self, app.state != .notRunning else { return }
            self.capture(app, named: "\(name)-teardown")
        }

        app.launch()
        if configureSettings {
            configureAppearanceAndTheme(app, appearance: appAppearance, theme: terminalTheme)
        }

        let demoHost = app.staticTexts["Demo Workbox"]
        XCTAssertTrue(demoHost.waitForExistence(timeout: timeout), app.debugDescription)
        demoHost.tap()
        require(app.buttons["Connect"], in: app, named: "Connect").tap()

        let trustAlert = app.alerts["Approve Host Key?"]
        XCTAssertTrue(trustAlert.waitForExistence(timeout: timeout), app.debugDescription)
        require(trustAlert.buttons["Trust Once"], in: app, named: "Trust Once").tap()
        require(app.buttons["Open session"], in: app, named: "Open session").tap()

        let navigationBar = app.navigationBars["Terminal"]
        XCTAssertTrue(navigationBar.waitForExistence(timeout: timeout), app.debugDescription)
        let back = require(app.buttons["BackButton"], in: app, named: "session back")
        XCTAssertTrue(back.isHittable)
        XCTAssertTrue(
            app.otherElements["session-header-voice-button"].waitForExistence(timeout: timeout))
        XCTAssertTrue(app.buttons["Session tools"].waitForExistence(timeout: timeout))
        XCTAssertTrue(app.otherElements["Terminal surface"].waitForExistence(timeout: timeout))
        XCTAssertTrue(app.staticTexts["Demo Workbox"].exists, app.debugDescription)
        Thread.sleep(forTimeInterval: 1)
        capture(app, named: "\(name)-session")
    }

    private func configureAppearanceAndTheme(
        _ app: XCUIApplication, appearance: String, theme: String
    ) {
        let back = require(app.buttons["BackButton"], in: app, named: "hosts back")
        back.tap()
        require(app.buttons["Settings"], in: app, named: "Settings section").tap()

        let settingsNavigationBar = app.navigationBars["Settings"]
        XCTAssertTrue(
            settingsNavigationBar.waitForExistence(timeout: timeout), app.debugDescription)
        let settingsCollection = app.collectionViews.firstMatch
        XCTAssertTrue(settingsCollection.waitForExistence(timeout: timeout), app.debugDescription)

        let appearanceOption = reveal(
            settingsCollection.buttons[appearance],
            in: settingsCollection,
            app: app,
            named: "appearance \(appearance)")
        appearanceOption.tap()
        XCTAssertTrue(appearanceOption.isSelected, app.debugDescription)

        let themeLink = reveal(
            settingsCollection.buttons["terminal-theme-navigation-link"],
            in: settingsCollection,
            app: app,
            named: "terminal theme link")
        themeLink.tap()
        let themeRow = require(
            app.buttons["theme-row-\(theme)"], in: app, named: "terminal theme \(theme)")
        themeRow.tap()

        require(app.buttons["BackButton"], in: app, named: "settings back").tap()
        let selectedThemeName = theme == "catppuccinLatte" ? "Catppuccin Latte" : "Catppuccin Mocha"
        XCTAssertTrue(
            app.staticTexts[selectedThemeName].waitForExistence(timeout: timeout),
            app.debugDescription)
        require(app.buttons["BackButton"], in: app, named: "settings root back").tap()
        require(app.buttons["Hosts"], in: app, named: "Hosts section").tap()
    }

    private func reveal(
        _ element: XCUIElement,
        in collection: XCUIElement,
        app: XCUIApplication,
        named name: String
    ) -> XCUIElement {
        for _ in 0..<8 {
            if element.exists && element.isHittable {
                return element
            }
            collection.swipeUp()
        }
        XCTAssertTrue(element.exists, "Missing \(name)\n\(app.debugDescription)")
        XCTAssertTrue(element.isHittable, "Not hittable: \(name)")
        return element
    }

    @discardableResult
    private func require(_ element: XCUIElement, in app: XCUIApplication, named name: String)
        -> XCUIElement
    {
        XCTAssertTrue(
            element.waitForExistence(timeout: timeout), "Missing \(name)\n\(app.debugDescription)")
        XCTAssertTrue(element.isHittable, "Not hittable: \(name)")
        XCTAssertFalse(element.frame.isEmpty, "No accessibility frame: \(name)")
        return element
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
