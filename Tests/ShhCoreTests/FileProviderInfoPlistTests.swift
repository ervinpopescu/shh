import Foundation
import XCTest

final class FileProviderInfoPlistTests: XCTestCase {
    func testExtensionUsesValidNonUIFileProviderExtensionPoint() throws {
        let sourceFile = URL(fileURLWithPath: #filePath)
        let repositoryRoot = sourceFile
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let infoPlistURL = repositoryRoot.appendingPathComponent("FileProviderExtension/Info.plist")
        let data = try Data(contentsOf: infoPlistURL)
        let plist = try XCTUnwrap(
            PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any]
        )
        let extensionDictionary = try XCTUnwrap(plist["NSExtension"] as? [String: Any])
        XCTAssertEqual(
            extensionDictionary["NSExtensionPointIdentifier"] as? String,
            "com.apple.fileprovider-nonui"
        )
    }
}
