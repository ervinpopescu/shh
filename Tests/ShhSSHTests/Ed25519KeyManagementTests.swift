import XCTest
import Crypto
import Citadel
import NIOCore
import NIOSSH
import ShhCore
@testable import ShhSSH

final class Ed25519KeyManagementTests: XCTestCase {
    private func pemBoundary(labelWords: [String], side: String) -> String {
        "-----\(side) \(labelWords.joined(separator: " "))-----"
    }

    private func fixturePKCS8PEM() -> String {
        let key = Curve25519.Signing.PrivateKey()
        var der = Data([
            0x30, 0x2e, 0x02, 0x01, 0x00,
            0x30, 0x05, 0x06, 0x03, 0x2b, 0x65, 0x70,
            0x04, 0x22, 0x04, 0x20
        ])
        der.append(key.rawRepresentation)
        let labelWords = ["PRIVATE", "KEY"]
        return "\(pemBoundary(labelWords: labelWords, side: "BEGIN"))\n\(der.base64EncodedString())\n\(pemBoundary(labelWords: labelWords, side: "END"))"
    }

    private func fixtureUnsupportedPEM(labelWords: [String]) -> String {
        let body = Data((UUID().uuidString + UUID().uuidString).utf8).base64EncodedString()
        return "\(pemBoundary(labelWords: labelWords, side: "BEGIN"))\n\(body)\n\(pemBoundary(labelWords: labelWords, side: "END"))"
    }

    func testGenerateKeyPairProducesValidKeysAndFingerprint() {
        let generated = Ed25519Parser.generateKeyPair(comment: "test@device")

        XCTAssertTrue(generated.openSSHPrivateKey.contains(pemBoundary(labelWords: ["OPENSSH", "PRIVATE", "KEY"], side: "BEGIN")))
        XCTAssertTrue(generated.openSSHPrivateKey.contains(pemBoundary(labelWords: ["OPENSSH", "PRIVATE", "KEY"], side: "END")))

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
        let pkcs8Pem = fixturePKCS8PEM()

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
            XCTAssertEqual(
                transportError,
                .invalidPrivateKey(detail: "Could not parse Ed25519 private key. Ensure the entire key block is included.")
            )
        }

        XCTAssertThrowsError(try Ed25519Parser.parse(from: "")) { error in
            XCTAssertEqual(
                error as? TransportError,
                .invalidPrivateKey(detail: "Could not parse Ed25519 private key. Ensure the entire key block is included.")
            )
        }
    }

    func testImportRSAPrivateKeyThrowsInformativeError() {
        let rsaPem = fixtureUnsupportedPEM(labelWords: ["RSA", "PRIVATE", "KEY"])
        XCTAssertThrowsError(try Ed25519Parser.parse(from: rsaPem)) { error in
            XCTAssertEqual(
                error as? TransportError,
                .invalidPrivateKey(detail: "RSA private keys are not currently supported. Please use an Ed25519 key or password.")
            )
        }

        let sshRsa = "ssh-rsa \(Data(UUID().uuidString.utf8).base64EncodedString()) user@example"
        XCTAssertThrowsError(try Ed25519Parser.parse(from: sshRsa)) { error in
            XCTAssertEqual(
                error as? TransportError,
                .invalidPrivateKey(detail: "RSA private keys are not currently supported. Please use an Ed25519 key or password.")
            )
        }
    }

    func testImportECDSAPrivateKeyThrowsInformativeError() {
        let ecPem = fixtureUnsupportedPEM(labelWords: ["EC", "PRIVATE", "KEY"])
        XCTAssertThrowsError(try Ed25519Parser.parse(from: ecPem)) { error in
            XCTAssertEqual(
                error as? TransportError,
                .invalidPrivateKey(detail: "ECDSA private keys are not currently supported. Please use an Ed25519 key or password.")
            )
        }

        let ecdsaKey = "ecdsa-sha2-nistp256 \(Data(UUID().uuidString.utf8).base64EncodedString()) user@example"
        XCTAssertThrowsError(try Ed25519Parser.parse(from: ecdsaKey)) { error in
            XCTAssertEqual(
                error as? TransportError,
                .invalidPrivateKey(detail: "ECDSA private keys are not currently supported. Please use an Ed25519 key or password.")
            )
        }
    }

    func testImportEncryptedOpenSSHPrivateKeyThrowsInformativeError() {
        var buffer = ByteBuffer()
        buffer.writeString("openssh-key-v1\0")
        let cipher = "aes256-ctr"
        buffer.writeInteger(UInt32(cipher.utf8.count))
        buffer.writeString(cipher)
        let kdf = "bcrypt"
        buffer.writeInteger(UInt32(kdf.utf8.count))
        buffer.writeString(kdf)
        buffer.writeInteger(UInt32(0))
        buffer.writeInteger(UInt32(1))
        let dummyBytes = buffer.readBytes(length: buffer.readableBytes)!
        let base64 = Data(dummyBytes).base64EncodedString()
        let labelWords = ["OPENSSH", "PRIVATE", "KEY"]
        let encryptedKey = "\(pemBoundary(labelWords: labelWords, side: "BEGIN"))\n\(base64)\n\(pemBoundary(labelWords: labelWords, side: "END"))"
        XCTAssertThrowsError(try Ed25519Parser.parse(from: encryptedKey)) { error in
            XCTAssertEqual(
                error as? TransportError,
                .invalidPrivateKey(detail: "Passphrase-encrypted OpenSSH keys are not yet supported. Please import an unencrypted Ed25519 key.")
            )
        }
    }
}
