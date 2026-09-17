import XCTest
@testable import ShhCore

final class SendImageTests: XCTestCase {
    private let onePixelPNG = Data(base64Encoded: "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mNk+A8AAQUBAScY42YAAAAASUVORK5CYII=")!

    func testValidatorAcceptsImageContentAndDerivesType() throws {
        let image = try SendImageValidator.validate(onePixelPNG)
        XCTAssertEqual(image.fileExtension, "png")
        XCTAssertEqual(image.uniformTypeIdentifier, "public.png")
        XCTAssertEqual(image.data, onePixelPNG)
    }

    func testValidatorRejectsMalformedAndOversizedData() {
        XCTAssertThrowsError(try SendImageValidator.validate(Data("not an image".utf8))) { error in
            XCTAssertEqual(error as? SendImageError, .malformedImage)
        }
        XCTAssertThrowsError(try SendImageValidator.validate(onePixelPNG, limits: SendImageLimits(maximumBytes: 4))) { error in
            XCTAssertEqual(error as? SendImageError, .imageTooLarge)
        }
    }

    func testDestinationAndFilenameDoNotTrustInputExtension() throws {
        XCTAssertEqual(try SendImageDestination.defaultDirectory(username: "dev").description, "/home/dev/.shh/images")
        XCTAssertThrowsError(try SendImageDestination.defaultDirectory(username: "dev/../root"))
        XCTAssertThrowsError(try SendImageDestination.configuredDirectory("relative/path"))
        let name = SendImageNaming.fileName(extension: "PNG", id: UUID(uuidString: "AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEEE")!)
        XCTAssertEqual(name, "shh-image-aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee.png")
    }

    func testShellQuoteEscapesAndDoesNotAppendReturn() throws {
        let quoted = try SendImageNaming.shellQuote("/home/dev/.shh/images/it's.png")
        XCTAssertEqual(quoted, "'/home/dev/.shh/images/it'\\''s.png'")
        XCTAssertFalse(quoted.contains("\n"))
        XCTAssertThrowsError(try SendImageNaming.shellQuote("/tmp/\0image.png"))
    }
}
