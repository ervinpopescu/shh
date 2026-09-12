import XCTest
@testable import ShhCore

final class EncryptedVaultBackupTests: XCTestCase {
    private let service = EncryptedVaultService()
    private let testOptions = VaultExportOptions(iterations: 10_000, saltLength: 32)

    func testVaultRoundTripEncryptionAndDecryption() async throws {
        let catalog = InMemoryCatalog(seedDemoData: true)
        let snapshot = await catalog.snapshot()

        var preferences = VaultPreferences()
        preferences.defaultTerminalFont = "Menlo-Regular"
        preferences.defaultTerminalFontSize = 14.0
        preferences.voiceProvider = "apple-speech"
        preferences.customSettings["theme"] = "dark"

        let passphrase = "correct-horse-battery-staple"
        let backup = try service.exportBackup(
            catalog: snapshot,
            preferences: preferences,
            passphrase: passphrase,
            options: testOptions
        )

        XCTAssertEqual(backup.format, EncryptedVaultBackup.currentFormat)
        XCTAssertEqual(backup.version, EncryptedVaultBackup.currentVersion)
        XCTAssertEqual(backup.kdf.iterations, 10_000)
        XCTAssertFalse(backup.checksum.isEmpty)

        let restored = try service.restoreBackup(backup: backup, passphrase: passphrase)

        XCTAssertEqual(restored.catalog.hosts.count, snapshot.hosts.count)
        XCTAssertEqual(restored.catalog.groups.count, snapshot.groups.count)
        XCTAssertEqual(restored.catalog.identities.count, snapshot.identities.count)
        XCTAssertEqual(restored.catalog.snippets.count, snapshot.snippets.count)
        XCTAssertEqual(restored.preferences.defaultTerminalFont, "Menlo-Regular")
        XCTAssertEqual(restored.preferences.defaultTerminalFontSize, 14.0)
        XCTAssertEqual(restored.preferences.customSettings["theme"], "dark")

        XCTAssertTrue(service.verifyPassphrase(backup: backup, passphrase: passphrase))
    }

    func testVaultRandomSaltsAndNonces() async throws {
        let catalog = InMemoryCatalog(seedDemoData: true)
        let snapshot = await catalog.snapshot()
        let passphrase = "test-passphrase-randomness"

        let backup1 = try service.exportBackup(catalog: snapshot, passphrase: passphrase, options: testOptions)
        let backup2 = try service.exportBackup(catalog: snapshot, passphrase: passphrase, options: testOptions)

        XCTAssertNotEqual(backup1.kdf.salt, backup2.kdf.salt)
        XCTAssertNotEqual(backup1.cipher.nonce, backup2.cipher.nonce)
        XCTAssertNotEqual(backup1.cipher.ciphertext, backup2.cipher.ciphertext)
        XCTAssertNotEqual(backup1.cipher.tag, backup2.cipher.tag)
        XCTAssertNotEqual(backup1.checksum, backup2.checksum)
    }

    func testVaultWrongPassphraseRejection() async throws {
        let catalog = InMemoryCatalog(seedDemoData: true)
        let snapshot = await catalog.snapshot()
        let backup = try service.exportBackup(catalog: snapshot, passphrase: "correct-password", options: testOptions)

        XCTAssertThrowsError(try service.restoreBackup(backup: backup, passphrase: "wrong-password")) { error in
            guard let vaultError = error as? VaultBackupError else {
                XCTFail("Expected VaultBackupError, got \(error)")
                return
            }
            XCTAssertEqual(vaultError, .authenticationFailed)
        }

        XCTAssertFalse(service.verifyPassphrase(backup: backup, passphrase: "wrong-password"))
    }

    func testVaultTamperDetectionCiphertext() async throws {
        let catalog = InMemoryCatalog(seedDemoData: true)
        let snapshot = await catalog.snapshot()
        let backup = try service.exportBackup(catalog: snapshot, passphrase: "tamper-check-pw", options: testOptions)

        var tampered = backup
        var ciphertextBytes = Array(tampered.cipher.ciphertext)
        ciphertextBytes[0] ^= 0xFF
        tampered.cipher.ciphertext = Data(ciphertextBytes)

        XCTAssertThrowsError(try service.restoreBackup(backup: tampered, passphrase: "tamper-check-pw")) { error in
            guard let vaultError = error as? VaultBackupError else {
                XCTFail("Expected VaultBackupError, got \(error)")
                return
            }
            XCTAssertEqual(vaultError, .authenticationFailed)
        }
    }

    func testVaultTamperDetectionTag() async throws {
        let catalog = InMemoryCatalog(seedDemoData: true)
        let snapshot = await catalog.snapshot()
        let backup = try service.exportBackup(catalog: snapshot, passphrase: "tag-tamper-pw", options: testOptions)

        var tampered = backup
        var tagBytes = Array(tampered.cipher.tag)
        tagBytes[0] ^= 0xAA
        tampered.cipher.tag = Data(tagBytes)

        XCTAssertThrowsError(try service.restoreBackup(backup: tampered, passphrase: "tag-tamper-pw")) { error in
            guard let vaultError = error as? VaultBackupError else {
                XCTFail("Expected VaultBackupError, got \(error)")
                return
            }
            XCTAssertEqual(vaultError, .authenticationFailed)
        }
    }

    func testVaultTamperDetectionSalt() async throws {
        let catalog = InMemoryCatalog(seedDemoData: true)
        let snapshot = await catalog.snapshot()
        let backup = try service.exportBackup(catalog: snapshot, passphrase: "salt-tamper-pw", options: testOptions)

        var tampered = backup
        var saltBytes = Array(tampered.kdf.salt)
        saltBytes[0] ^= 0x55
        tampered.kdf.salt = Data(saltBytes)

        XCTAssertThrowsError(try service.restoreBackup(backup: tampered, passphrase: "salt-tamper-pw")) { error in
            guard let vaultError = error as? VaultBackupError else {
                XCTFail("Expected VaultBackupError, got \(error)")
                return
            }
            XCTAssertEqual(vaultError, .authenticationFailed)
        }
    }

    func testVaultTamperDetectionChecksum() async throws {
        let catalog = InMemoryCatalog(seedDemoData: true)
        let snapshot = await catalog.snapshot()
        let backup = try service.exportBackup(catalog: snapshot, passphrase: "checksum-tamper-pw", options: testOptions)

        var tampered = backup
        tampered.checksum = "0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef"

        XCTAssertThrowsError(try service.restoreBackup(backup: tampered, passphrase: "checksum-tamper-pw")) { error in
            guard let vaultError = error as? VaultBackupError else {
                XCTFail("Expected VaultBackupError, got \(error)")
                return
            }
            XCTAssertEqual(vaultError, .authenticationFailed)
        }
    }

    func testVaultUnsupportedVersionAndFormatRejection() async throws {
        let catalog = InMemoryCatalog(seedDemoData: true)
        let snapshot = await catalog.snapshot()
        let backup = try service.exportBackup(catalog: snapshot, passphrase: "pw", options: testOptions)

        var invalidVersion = backup
        invalidVersion.version = 999
        XCTAssertThrowsError(try service.restoreBackup(backup: invalidVersion, passphrase: "pw")) { error in
            XCTAssertEqual(error as? VaultBackupError, .unsupportedVersion(999))
        }

        var invalidFormat = backup
        invalidFormat.format = "unsupported-format-v9"
        XCTAssertThrowsError(try service.restoreBackup(backup: invalidFormat, passphrase: "pw")) { error in
            XCTAssertEqual(error as? VaultBackupError, .unsupportedFormat("unsupported-format-v9"))
        }
    }

    func testVaultInsufficientIterationsRejection() async throws {
        let catalog = InMemoryCatalog(seedDemoData: true)
        let snapshot = await catalog.snapshot()
        let backup = try service.exportBackup(catalog: snapshot, passphrase: "pw", options: testOptions)

        var lowIterations = backup
        lowIterations.kdf.iterations = 500
        XCTAssertThrowsError(try service.restoreBackup(backup: lowIterations, passphrase: "pw")) { error in
            XCTAssertEqual(error as? VaultBackupError, .insufficientIterations(500))
        }
    }

    func testVaultEmptyPassphraseRejection() async throws {
        let catalog = InMemoryCatalog(seedDemoData: true)
        let snapshot = await catalog.snapshot()

        XCTAssertThrowsError(try service.exportBackup(catalog: snapshot, passphrase: "   ", options: testOptions)) { error in
            XCTAssertEqual(error as? VaultBackupError, .emptyPassphrase)
        }
    }

    func testVaultAbsenceOfSecrets() async throws {
        let catalog = InMemoryCatalog(seedDemoData: true)
        let snapshot = await catalog.snapshot()
        let backupData = try service.exportBackupData(catalog: snapshot, passphrase: "safe-password", options: testOptions)

        let jsonString = String(data: backupData, encoding: .utf8)!
        XCTAssertFalse(jsonString.contains("BEGIN OPENSSH PRIVATE KEY"))
        XCTAssertFalse(jsonString.contains("BEGIN RSA PRIVATE KEY"))
        XCTAssertFalse(jsonString.contains("BEGIN EC PRIVATE KEY"))

        // Create an invalid snapshot containing a raw private key string in a snippet body
        var dirtySnapshot = snapshot
        let leakedSnippet = try Snippet(name: "Leaked", body: "-----BEGIN OPENSSH PRIVATE KEY-----\ntest\n-----END OPENSSH PRIVATE KEY-----")
        dirtySnapshot.snippets.append(leakedSnippet)

        XCTAssertThrowsError(try service.exportBackup(catalog: dirtySnapshot, passphrase: "safe-password", options: testOptions)) { error in
            guard let vaultError = error as? VaultBackupError else {
                XCTFail("Expected VaultBackupError, got \(error)")
                return
            }
            guard case .credentialsDisallowed = vaultError else {
                XCTFail("Expected credentialsDisallowed, got \(vaultError)")
                return
            }
        }
    }

    func testVaultMaximumIterationsRejection() async throws {
        let catalog = InMemoryCatalog(seedDemoData: true)
        let snapshot = await catalog.snapshot()
        let backup = try service.exportBackup(catalog: snapshot, passphrase: "pw", options: testOptions)

        // Iterations above maximum (5_000_000)
        var highIterations = backup
        highIterations.kdf.iterations = 5_000_001
        XCTAssertThrowsError(try service.restoreBackup(backup: highIterations, passphrase: "pw")) { error in
            XCTAssertEqual(error as? VaultBackupError, .insufficientIterations(5_000_001))
        }

        // Extremely large iterations (64-bit integer overflow guard)
        var overflowIterations = backup
        overflowIterations.kdf.iterations = Int.max
        XCTAssertThrowsError(try service.restoreBackup(backup: overflowIterations, passphrase: "pw")) { error in
            XCTAssertEqual(error as? VaultBackupError, .insufficientIterations(Int.max))
        }

        // Negative iterations
        var negativeIterations = backup
        negativeIterations.kdf.iterations = -100
        XCTAssertThrowsError(try service.restoreBackup(backup: negativeIterations, passphrase: "pw")) { error in
            XCTAssertEqual(error as? VaultBackupError, .insufficientIterations(-100))
        }
    }

    func testVaultMaximumDataSizeBound() async throws {
        // Construct simulated oversized payload exceeding 50 MB
        let oversizedData = Data(count: 51 * 1024 * 1024)
        XCTAssertThrowsError(try service.restoreBackup(data: oversizedData, passphrase: "pw")) { error in
            guard case .corruptedPayload(let details)? = error as? VaultBackupError else {
                XCTFail("Expected corruptedPayload, got \(error)")
                return
            }
            XCTAssertTrue(details.contains("50MB") || details.contains("exceeds"))
        }
    }

    func testVaultPrematurePBKDF2PreventionOnMalformedSaltNonceTag() async throws {
        let catalog = InMemoryCatalog(seedDemoData: true)
        let snapshot = await catalog.snapshot()
        let backup = try service.exportBackup(catalog: snapshot, passphrase: "pw", options: testOptions)

        // Short salt (< 16 bytes)
        var badSalt = backup
        badSalt.kdf.salt = Data(repeating: 1, count: 15)
        XCTAssertThrowsError(try service.restoreBackup(backup: badSalt, passphrase: "pw")) { error in
            guard case .corruptedPayload(let details)? = error as? VaultBackupError else {
                XCTFail("Expected corruptedPayload for short salt, got \(error)")
                return
            }
            XCTAssertTrue(details.contains("Salt length"))
        }

        // Invalid nonce (!= 12 bytes)
        var badNonce = backup
        badNonce.cipher.nonce = Data(repeating: 2, count: 16)
        XCTAssertThrowsError(try service.restoreBackup(backup: badNonce, passphrase: "pw")) { error in
            guard case .corruptedPayload(let details)? = error as? VaultBackupError else {
                XCTFail("Expected corruptedPayload for invalid nonce, got \(error)")
                return
            }
            XCTAssertTrue(details.contains("nonce"))
        }

        // Invalid tag (!= 16 bytes)
        var badTag = backup
        badTag.cipher.tag = Data(repeating: 3, count: 8)
        XCTAssertThrowsError(try service.restoreBackup(backup: badTag, passphrase: "pw")) { error in
            guard case .corruptedPayload(let details)? = error as? VaultBackupError else {
                XCTFail("Expected corruptedPayload for invalid tag, got \(error)")
                return
            }
            XCTAssertTrue(details.contains("tag"))
        }
    }

    func testVaultSecretDetectionInPreferencesAndPuTTY() async throws {
        let catalog = InMemoryCatalog(seedDemoData: true)
        let snapshot = await catalog.snapshot()

        // Secret hidden in customSettings preferences
        var preferencesWithSecret = VaultPreferences()
        preferencesWithSecret.customSettings["api_key"] = "-----BEGIN RSA PRIVATE KEY-----\nMIIEowIBAAKCAQEA..."
        XCTAssertThrowsError(try service.exportBackup(
            catalog: snapshot,
            preferences: preferencesWithSecret,
            passphrase: "pw",
            options: testOptions
        )) { error in
            XCTAssertEqual(error as? VaultBackupError, .credentialsDisallowed("Prohibited private key pattern detected in vault payload."))
        }

        // PKCS#8 encrypted private key
        var preferencesWithPKCS8 = VaultPreferences()
        preferencesWithPKCS8.customSettings["key"] = "-----BEGIN ENCRYPTED PRIVATE KEY-----\nMIIFDjBABgkqhkiG9w0BBQ0wMzAbBgkq..."
        XCTAssertThrowsError(try service.exportBackup(
            catalog: snapshot,
            preferences: preferencesWithPKCS8,
            passphrase: "pw",
            options: testOptions
        )) { error in
            XCTAssertEqual(error as? VaultBackupError, .credentialsDisallowed("Prohibited private key pattern detected in vault payload."))
        }

        // PuTTY private key format
        var preferencesWithPuTTY = VaultPreferences()
        preferencesWithPuTTY.customSettings["putty"] = "PuTTY-User-Key-File-2: ssh-rsa\nEncryption: aes256-cbc..."
        XCTAssertThrowsError(try service.exportBackup(
            catalog: snapshot,
            preferences: preferencesWithPuTTY,
            passphrase: "pw",
            options: testOptions
        )) { error in
            XCTAssertEqual(error as? VaultBackupError, .credentialsDisallowed("Prohibited private key pattern detected in vault payload."))
        }
    }

    func testVaultRawPassphraseDataOverload() async throws {
        let catalog = InMemoryCatalog(seedDemoData: true)
        let snapshot = await catalog.snapshot()
        var passphraseBytes = Data("scrubbable-passphrase-data".utf8)

        let backup = try service.exportBackup(
            catalog: snapshot,
            passphraseData: passphraseBytes,
            options: testOptions
        )

        let restored = try service.restoreBackup(backup: backup, passphraseData: passphraseBytes)
        XCTAssertEqual(restored.catalog.hosts.count, snapshot.hosts.count)

        // Zero out passphrase bytes
        passphraseBytes.resetBytes(in: 0..<passphraseBytes.count)
        XCTAssertEqual(passphraseBytes, Data(repeating: 0, count: passphraseBytes.count))
    }
}
