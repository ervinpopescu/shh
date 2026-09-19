import XCTest
@testable import ShhCore

final class CommandDialTests: XCTestCase {
    func testHierarchyAndStableCommonKeyIDs() {
        let model = CommandDialModel()
        XCTAssertEqual(model.roots.map(\.id), [
            "root.common-keys", "root.snippets", "root.voice", "root.keyboard", "root.multiplexer", "root.send-image"
        ])
        let common = try! XCTUnwrap(model.roots.first { $0.action == .category(.commonKeys) })
        XCTAssertEqual(common.children.first?.id, "key.escape")
        XCTAssertEqual(common.children.last?.id, "key.enter")
    }

    func testNavigationBackAndDisabledNodes() {
        let model = CommandDialModel(connected: false)
        var state = CommandDialNavigation()
        state.open()
        XCTAssertFalse(model.roots[0].isEnabled)
        state.enter(model.roots[0])
        XCTAssertTrue(state.path.isEmpty)

        let connected = CommandDialModel()
        state.enter(connected.roots[0])
        XCTAssertEqual(state.path, ["root.common-keys"])
        state.back()
        XCTAssertTrue(state.path.isEmpty)
        state.dismiss()
        XCTAssertFalse(state.isOpen)
    }

    func testSwipeCategorySelectionKeepsDialOpenAndSwitchesWithoutReentering() throws {
        let model = CommandDialModel()
        var state = CommandDialNavigation(isOpen: true)
        let commonKeys = try XCTUnwrap(model.roots.first { $0.action == .category(.commonKeys) })
        let keyboard = try XCTUnwrap(model.roots.first { $0.action == .keyboard })

        state.selectCategory(commonKeys)
        XCTAssertTrue(state.isOpen)
        XCTAssertTrue(state.path.isEmpty)
        XCTAssertEqual(state.selectedNodeID, commonKeys.id)

        state.selectCategory(keyboard)
        XCTAssertTrue(state.isOpen)
        XCTAssertTrue(state.path.isEmpty)
        XCTAssertEqual(state.selectedNodeID, keyboard.id)
    }

    func testDisabledCategoryCannotBeSelectedBySwipe() throws {
        let model = CommandDialModel(connected: false)
        var state = CommandDialNavigation(isOpen: true)
        let category = try XCTUnwrap(model.roots.first)

        state.selectCategory(category)

        XCTAssertNil(state.selectedNodeID)
        XCTAssertTrue(state.path.isEmpty)
    }

    func testPinnedLiteralsAreBoundedAndDeduplicated() {
        let model = CommandDialModel(pinnedLiterals: ["  ls ", "ls", "", String(repeating: "x", count: 65)])
        let common = model.roots[0]
        XCTAssertEqual(common.children.filter { $0.id.hasPrefix("literal.") }.map(\.title), ["ls"])
    }

    func testPinnedLiteralsAreInsertOnlyAndPolicyGated() {
        XCTAssertFalse(CommandDialModel.isInsertOnlyTerminalText("ls\n"))
        XCTAssertFalse(CommandDialModel.isInsertOnlyTerminalText("ls\u{03}"))
        let model = CommandDialModel(pinnedLiterals: ["sudo reboot", "rm -rf /", "echo hello"])
        let common = model.roots[0]
        XCTAssertEqual(common.children.filter { $0.id.hasPrefix("literal.") }.count, 3)
        XCTAssertEqual(common.children.first { $0.title == "rm -rf /" }?.availability, .blocked(reason: "Safety policy"))
        XCTAssertEqual(common.children.first { $0.title == "sudo reboot" }?.availability, .reviewRequired)
    }

    func testMultiplexerControlsAreReachableAsChildren() throws {
        let sessionID = try TmuxSessionID("$1")
        let windowID = try TmuxWindowID("@2")
        let paneID = try TmuxPaneID("%3")
        let windowTarget = TmuxWindowTarget(sessionID: sessionID, windowID: windowID)
        let paneTarget = TmuxPaneTarget(sessionID: sessionID, windowID: windowID, paneID: paneID)
        let controls = CommandDialMultiplexerMenu.nodes(
            tmuxSessionID: sessionID, tmuxPaneTarget: paneTarget, tmuxWindowTarget: windowTarget,
            capabilities: .tmux
        )
        let model = CommandDialModel(multiplexerChildren: controls)
        let root = try XCTUnwrap(model.roots.first { $0.id == "root.multiplexer" })
        XCTAssertFalse(root.children.isEmpty)
        XCTAssertTrue(root.children.allSatisfy { if case .multiplexerControl = $0.action { return true }; return false })
        let actions = root.children.compactMap { node -> MultiplexerControlAction? in
            guard case .multiplexerControl(let action) = node.action else { return nil }
            return action
        }
        XCTAssertTrue(actions.allSatisfy(\.requiresConfirmation))
        XCTAssertFalse(root.children.contains { $0.id == "mux.tmux.session-picker" })
        XCTAssertFalse(root.children.contains { $0.id == "mux.tmux.window-picker" })
    }

    func testReviewAndBlockedSnippetAvailability() {
        let reviewID = UUID()
        let blockedID = UUID()
        let model = CommandDialModel(snippets: [
            DialSnippetDescriptor(id: reviewID, name: "Review", preview: "sudo", availability: .reviewRequired),
            DialSnippetDescriptor(id: blockedID, name: "Blocked", preview: "fork", availability: .blocked(reason: "Safety policy"))
        ])
        let snippets = try! XCTUnwrap(model.roots.first { $0.id == "root.snippets" })
        XCTAssertTrue(snippets.children.first { $0.id.contains(reviewID.uuidString) }?.isEnabled == true)
        XCTAssertFalse(snippets.children.first { $0.id.contains(blockedID.uuidString) }?.isEnabled == true)
    }

    func testPreferencesRoundTripAndNoTransientState() throws {
        let preferences = CommandDialPreferences(placement: .leading, size: .regular, hapticsEnabled: false,
                                                  pinnedCategories: [.commonKeys], pinnedLiterals: ["~/"])
        let data = try JSONEncoder().encode(preferences)
        let decoded = try JSONDecoder().decode(CommandDialPreferences.self, from: data)
        XCTAssertEqual(decoded, preferences)
        XCTAssertFalse(String(decoding: data, as: UTF8.self).contains("secret"))
    }
}
