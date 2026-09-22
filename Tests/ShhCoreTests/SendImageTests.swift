import XCTest

@testable import ShhCore

final class SendImageTests: XCTestCase {
    private let onePixelPNG = Data(
        base64Encoded:
            "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mNk+A8AAQUBAScY42YAAAAASUVORK5CYII="
    )!

    private let onePixelBMP = Data([
        0x42, 0x4D, 0x3A, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x36, 0x00, 0x00, 0x00,
        0x28, 0x00, 0x00, 0x00, 0x01, 0x00, 0x00, 0x00, 0x01, 0x00, 0x00, 0x00, 0x01, 0x00,
        0x18, 0x00, 0x00, 0x00, 0x00, 0x00, 0x04, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
        0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0xFF, 0xFF,
        0xFF, 0x00,
    ])

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
        XCTAssertThrowsError(
            try SendImageValidator.validate(onePixelPNG, limits: SendImageLimits(maximumBytes: 4))
        ) { error in
            XCTAssertEqual(error as? SendImageError, .imageTooLarge)
        }
    }

    func testDestinationAndFilenameDoNotTrustInputExtension() throws {
        XCTAssertEqual(
            try SendImageDestination.defaultDirectory(username: "dev").description,
            "/home/dev/.shh/images")
        XCTAssertThrowsError(try SendImageDestination.defaultDirectory(username: "dev/../root"))
        XCTAssertNil(try SendImageDestination.configuredDirectory(nil))
        XCTAssertEqual(
            try SendImageDestination.configuredDirectory("/var/images")?.description,
            "/var/images")
        XCTAssertThrowsError(try SendImageDestination.configuredDirectory("/"))
        XCTAssertThrowsError(try SendImageDestination.configuredDirectory("   "))
        XCTAssertThrowsError(try SendImageDestination.configuredDirectory("relative/path"))
        XCTAssertThrowsError(
            try SendImageDestination.configuredDirectory("/home/dev/images\r\nrm -rf /"))
        XCTAssertThrowsError(try SendImageDestination.configuredDirectory("/home/dev/images\0null"))
        let name = SendImageNaming.fileName(
            extension: "PNG", id: UUID(uuidString: "AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEEE")!)
        XCTAssertEqual(name, "shh-image-aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee.png")
    }

    func testShellQuoteEscapesAndDoesNotAppendReturn() throws {
        let quoted = try SendImageNaming.shellQuote("/home/dev/.shh/images/it's.png")
        XCTAssertEqual(quoted, "'/home/dev/.shh/images/it'\\''s.png'")
        XCTAssertFalse(quoted.contains("\n"))
        XCTAssertFalse(quoted.contains("\r"))
        XCTAssertThrowsError(try SendImageNaming.shellQuote(""))
        XCTAssertThrowsError(try SendImageNaming.shellQuote("/tmp/\0image.png"))
        XCTAssertThrowsError(try SendImageNaming.shellQuote("/tmp/image.png\r"))
        XCTAssertThrowsError(try SendImageNaming.shellQuote("/tmp/image.png\n"))
        XCTAssertThrowsError(try SendImageNaming.shellQuote("/tmp/image\u{1B}.png"))
    }

    func testTransferStateIsActive() {
        XCTAssertFalse(SendImageTransferState.idle.isActive)
        XCTAssertTrue(SendImageTransferState.preparing.isActive)
        let progress = TransferProgress(bytesTransferred: 10, totalBytes: 20)
        XCTAssertTrue(SendImageTransferState.transferring(progress).isActive)
        XCTAssertFalse(SendImageTransferState.completed(RemotePath("/tmp/img.png")).isActive)
        XCTAssertFalse(SendImageTransferState.failed.isActive)
        XCTAssertFalse(SendImageTransferState.cancelled.isActive)
    }

    func testSendImageErrorDescriptionsAndValidationEdgeCases() {
        let errors: [(SendImageError, String)] = [
            (.emptyData, "The selected image is empty."),
            (.malformedImage, "The selected file is not a readable image."),
            (.imageTooLarge, "Images must be 20 MB or smaller."),
            (.imageDimensionsTooLarge, "The image dimensions are too large."),
            (.unsupportedImage, "This image format is not supported."),
            (.invalidDestination, "The image destination is invalid."),
            (.unavailable, "Image transfer is unavailable while disconnected."),
            (.hostChanged, "The host changed before the image finished uploading."),
            (.cancelled, "Image transfer cancelled."),
        ]
        for (error, description) in errors {
            XCTAssertEqual(error.errorDescription, description)
        }

        XCTAssertThrowsError(try SendImageValidator.validate(Data())) { error in
            XCTAssertEqual(error as? SendImageError, .emptyData)
        }
        XCTAssertThrowsError(
            try SendImageValidator.validate(onePixelPNG, limits: SendImageLimits(maximumPixels: 0))
        ) { error in
            XCTAssertEqual(error as? SendImageError, .imageDimensionsTooLarge)
        }
        XCTAssertThrowsError(try SendImageValidator.validate(onePixelBMP)) { error in
            XCTAssertEqual(error as? SendImageError, .unsupportedImage)
        }
    }
}
