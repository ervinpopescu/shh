import Combine
import XCTest
@testable import ShhTerminal

@MainActor
final class TerminalInputCoordinatorTests: XCTestCase {
    func testControlSpaceAndAtProduceNulAndAreOneShot() {
        let coordinator = TerminalInputCoordinator()

        coordinator.toggleControl()
        XCTAssertEqual(coordinator.processKeyboardInput(Data(" ".utf8)), Data([0x00]))
        XCTAssertFalse(coordinator.isControlActive)

        coordinator.toggleControl()
        XCTAssertEqual(coordinator.processKeyboardInput(Data("@".utf8)), Data([0x00]))
        XCTAssertEqual(coordinator.processKeyboardInput(Data("@".utf8)), Data("@".utf8))
    }

    func testControlLettersAndPunctuation() {
        let cases: [(String, UInt8)] = [
            ("a", 0x01), ("Z", 0x1A), ("[", 0x1B), ("\\", 0x1C),
            ("]", 0x1D), ("^", 0x1E), ("_", 0x1F), ("?", 0x7F)
        ]

        for (character, expected) in cases {
            let coordinator = TerminalInputCoordinator()
            coordinator.toggleControl()
            XCTAssertEqual(
                coordinator.processKeyboardInput(Data(character.utf8)),
                Data([expected]),
                "Ctrl-\(character)"
            )
            XCTAssertFalse(coordinator.isControlActive)
        }
    }

    func testAltPrefixesASCIIAndShiftChangesAccessoryText() {
        let coordinator = TerminalInputCoordinator()

        coordinator.toggleAlt()
        XCTAssertEqual(coordinator.processKeyboardInput(Data("x".utf8)), Data([0x1B, 0x78]))

        coordinator.toggleShift()
        XCTAssertEqual(coordinator.encodeAccessoryText("a"), Data("A".utf8))
        XCTAssertFalse(coordinator.isShiftActive)
    }

    func testUTF8AndEscapeSequencesPassThroughWithoutPartialTransforms() {
        let coordinator = TerminalInputCoordinator()
        coordinator.toggleControl()
        let utf8 = Data("é".utf8)
        XCTAssertEqual(coordinator.processKeyboardInput(utf8), utf8)
        XCTAssertTrue(coordinator.isControlActive)
        let partialUTF8 = Data([0xC3])
        XCTAssertEqual(coordinator.processKeyboardInput(partialUTF8), partialUTF8)
        XCTAssertTrue(coordinator.isControlActive)

        let sequence = Data([0x1B, 0x5B, 0x41])
        XCTAssertEqual(coordinator.processKeyboardInput(sequence), sequence)
        XCTAssertFalse(coordinator.isControlActive)

        coordinator.toggleControl()
        XCTAssertEqual(coordinator.processKeyboardInput(Data("b".utf8)), Data([0x02]))
        XCTAssertFalse(coordinator.isControlActive)
    }

    func testEncodedAccessoryActionsDoNotDoubleApplyModifiers() {
        let coordinator = TerminalInputCoordinator()

        coordinator.toggleControl()
        XCTAssertEqual(
            coordinator.encodeAccessory(.arrow(.up)),
            Data([0x1B, 0x5B, 0x31, 0x3B, 0x35, 0x41])
        )
        XCTAssertFalse(coordinator.isControlActive)

        coordinator.toggleAlt()
        XCTAssertEqual(coordinator.encodeAccessory(.functionKey(1)), Data([0x1B, 0x4F, 0x50]))
        XCTAssertFalse(coordinator.isAltActive)

        coordinator.toggleControl()
        XCTAssertEqual(coordinator.encodeAccessory(.ctrlC), Data([0x03]))
        XCTAssertFalse(coordinator.isControlActive)
    }

    func testPasteAndMultiByteAccessoryTextDoNotConsumeModifiers() {
        let coordinator = TerminalInputCoordinator()
        coordinator.toggleControl()
        let paste = TerminalKeyEncoder.encodePaste("a\né", bracketed: true)
        XCTAssertEqual(coordinator.encodeAccessory(.paste("a\né", bracketed: true)), paste)
        XCTAssertTrue(coordinator.isControlActive)

        let text = "é"
        XCTAssertEqual(coordinator.encodeAccessoryText(text), Data(text.utf8))
        XCTAssertTrue(coordinator.isControlActive)
        XCTAssertEqual(coordinator.encodeAccessoryText("c"), Data([0x03]))
    }

    #if canImport(UIKit) && canImport(SwiftUI)
    func testStickyModifiersSurviveViewCoordinatorReattachment() {
        let controller = ShhTerminalController()
        controller.inputCoordinator.toggleControl()

        let firstCoordinator = ShhTerminalView(controller: controller).makeCoordinator()
        let reattachedCoordinator = ShhTerminalView(controller: controller).makeCoordinator()
        XCTAssertTrue(firstCoordinator.controller === controller)
        XCTAssertTrue(reattachedCoordinator.controller === controller)
        XCTAssertTrue(controller.inputCoordinator.isControlActive)
        XCTAssertEqual(controller.inputCoordinator.processKeyboardInput(Data(" ".utf8)), Data([0x00]))
    }
    #endif

    func testClearAndControllerKeyboardDelegatePath() {
        let coordinator = TerminalInputCoordinator()
        coordinator.toggleControl()
        coordinator.toggleAlt()
        coordinator.clear()
        XCTAssertEqual(coordinator.activeModifiers, [])

        let controller = ShhTerminalController()
        var sent: [Data] = []
        controller.onOutput = { sent.append($0) }
        controller.inputCoordinator.toggleControl()
        controller.handleOutput(Data(" ".utf8))
        XCTAssertEqual(sent, [Data([0x00])])
        XCTAssertFalse(controller.inputCoordinator.isControlActive)
    }

    func testControllerForwardsInputCoordinatorObjectWillChange() {
        let controller = ShhTerminalController()
        var changeCount = 0
        let cancellable = controller.objectWillChange.sink {
            changeCount += 1
        }
        controller.inputCoordinator.toggleControl()
        XCTAssertEqual(changeCount, 1)
        controller.inputCoordinator.clear()
        XCTAssertEqual(changeCount, 2)
        _ = cancellable
    }
}
