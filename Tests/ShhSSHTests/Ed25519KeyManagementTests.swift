import XCTest
import Crypto
import Citadel
import NIOCore
import NIOSSH
import ShhCore
@testable import ShhSSH

final class Ed25519KeyManagementTests: XCTestCase {
    func testGenerateKeyPairProducesValidKeysAndFingerprint() {
        let generated = Ed25519Parser.generateKeyPair(comment: "test@device")

        XCTAssertTrue(generated.openSSHPrivateKey.contains("-----BEGIN OPENSSH PRIVATE KEY-----"))
        XCTAssertTrue(generated.openSSHPrivateKey.contains("-----END OPENSSH PRIVATE KEY-----"))

        XCTAssertTrue(generated.openSSHPublicKey.hasPrefix("ssh-ed25519 AAAAC3NzaC1lZDI1NTE5"))
        XCTAssertTrue(generated.openSSHPublicKey.hasSuffix("test@device"))

        XCTAssertTrue(generated.fingerprint.hasPrefix("SHA256:"))
        // Base64 SHA256 digest without = padding is 43 characters; plus 7 for "SHA256:" is 50
        XCTAssertEqual(generated.fingerprint.count, 50)

        // Parse the generated private key back
        XCTAssertNoThrow(try Ed25519Parser.parse(from: generated.openSSHPrivateKey))
    }

    func testOpenSSHPublicKeyFormattingAndFingerprintCalculation() throws {
        let privateKey = Curve25519.Signing.PrivateKey()
        let publicKey = privateKey.publicKey

        // Generate public key without comment
        let pubWithoutComment = Ed25519Parser.openSSHPublicKeyString(from: publicKey, comment: nil)
        XCTAssertTrue(pubWithoutComment.hasPrefix("ssh-ed25519 AAAAC3NzaC1lZDI1NTE5"))
        let components = pubWithoutComment.split(separator: " ")
        XCTAssertEqual(components.count, 2)
        XCTAssertEqual(components[0], "ssh-ed25519")

        // Generate public key with comment
        let pubWithComment = Ed25519Parser.openSSHPublicKeyString(from: publicKey, comment: "user@hostname")
        XCTAssertEqual(pubWithComment, "\(pubWithoutComment) user@hostname")

        // Fingerprint calculation matches NIOSSH wire digest
        let nioPublicKey = try NIOSSHPublicKey.ed25519(publicKey)
        var buffer = ByteBufferAllocator().buffer(capacity: 128)
        _ = nioPublicKey.write(to: &buffer)
        let bytes = buffer.readBytes(length: buffer.readableBytes)!
        let expectedDigest = SHA256.hash(data: bytes)
        let expectedFingerprint = "SHA256:" + Data(expectedDigest).base64EncodedString().trimmingCharacters(in: CharacterSet(charactersIn: "="))

        let computedFingerprint = Ed25519Parser.fingerprint(from: publicKey)
        XCTAssertEqual(computedFingerprint, expectedFingerprint)
    }

    func testImportOpenSSHPrivateKey() throws {
        let originalKey = Curve25519.Signing.PrivateKey()
        let openSSHRepresentation = originalKey.makeSSHRepresentation(comment: "imported-key")

        let parsedKey = try Ed25519Parser.parse(from: openSSHRepresentation)
        XCTAssertEqual(parsedKey.rawRepresentation, originalKey.rawRepresentation)
        XCTAssertEqual(parsedKey.publicKey.rawRepresentation, originalKey.publicKey.rawRepresentation)
    }

    func testImportOpenSSHPrivateKeyWithVariousCommentLengths() throws {
        for comment in ["", "a", "ab", "abc", "abcd", "abcde", "abcdef", "imported@ipad", "a-very-long-comment-for-ssh-key@device"] {
            let originalKey = Curve25519.Signing.PrivateKey()
            let openSSH = originalKey.makeSSHRepresentation(comment: comment)
            let parsed = try Ed25519Parser.parse(from: openSSH)
            XCTAssertEqual(parsed.rawRepresentation, originalKey.rawRepresentation, "Failed for comment: '\(comment)'")
        }
    }

    func testImportPKCS8PEMPrivateKey() throws {
        // Sample PKCS#8 PEM with known 32-byte Ed25519 seed
        let pkcs8Pem = """
        -----BEGIN PRIVATE KEY-----
        MC4CAQAwBQYDK2VwBCIEIHlloGgivvFqKUn4/KhF+LKFRDZKw91yZc4QKk1+iNIj
        -----END PRIVATE KEY-----
        """

        let parsedKey = try Ed25519Parser.parse(from: pkcs8Pem)
        let fp = Ed25519Parser.fingerprint(from: parsedKey.publicKey)
        XCTAssertTrue(fp.hasPrefix("SHA256:"))
    }

    func testImportRawBase64PrivateKey() throws {
        let originalKey = Curve25519.Signing.PrivateKey()
        let base64 = originalKey.rawRepresentation.base64EncodedString()

        let parsedKey = try Ed25519Parser.parse(from: base64)
        XCTAssertEqual(parsedKey.rawRepresentation, originalKey.rawRepresentation)
    }

    func testImportRawHexPrivateKey() throws {
        let originalKey = Curve25519.Signing.PrivateKey()
        let hex = originalKey.rawRepresentation.map { String(format: "%02x", $0) }.joined()

        let parsedKey = try Ed25519Parser.parse(from: hex)
        XCTAssertEqual(parsedKey.rawRepresentation, originalKey.rawRepresentation)
    }

    func testImportInvalidPrivateKeyThrows() {
        XCTAssertThrowsError(try Ed25519Parser.parse(from: "not-a-valid-key")) { error in
            guard let transportError = error as? TransportError else {
                XCTFail("Expected TransportError, got \(error)")
                return
            }
            XCTAssertEqual(transportError, .invalidConfiguration)
        }

        XCTAssertThrowsError(try Ed25519Parser.parse(from: "")) { error in
            XCTAssertEqual(error as? TransportError, .invalidConfiguration)
        }
    }
}
