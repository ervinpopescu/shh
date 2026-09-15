import XCTest
@testable import ShhCore

final class TerminalThemeTests: XCTestCase {
    func testEveryPresetHasCompletePalette() {
        for preset in TerminalThemePreset.allCases {
            let palette = preset.palette
            XCTAssertEqual(palette.ansi.count, 16, preset.rawValue)
            XCTAssertNotEqual(palette.foreground, palette.background, preset.rawValue)
            XCTAssertTrue(palette.ansi.allSatisfy { $0.red <= 255 && $0.green <= 255 && $0.blue <= 255 })
        }
    }

    func testPaletteRoundTripPreservesTypedColors() throws {
        let palette = TerminalThemePreset.nord.palette
        let data = try JSONEncoder().encode(palette)
        let restored = try JSONDecoder().decode(TerminalThemePalette.self, from: data)
        XCTAssertEqual(restored, palette)
        XCTAssertEqual(palette.foreground.hex, "#D8DEE9")
    }

    func testLegacyVaultPreferencesUseProductionDefaults() throws {
        let data = Data(#"{"voiceAutoPunctuation":false}"#.utf8)
        let preferences = try JSONDecoder().decode(VaultPreferences.self, from: data)
        XCTAssertFalse(preferences.voiceAutoPunctuation)
        XCTAssertEqual(preferences.appearance, .system)
        XCTAssertEqual(preferences.terminalTheme, .catppuccinMocha)
    }
}
