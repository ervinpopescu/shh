import Foundation
import CryptoKit
#if canImport(CommonCrypto)
import CommonCrypto
#endif

/// User preferences bundle included in vault backups and sync.
public struct VaultPreferences: Codable, Hashable, Sendable {
    public var defaultTerminalFont: String?
    public var defaultTerminalFontSize: Double?
    public var voiceProvider: String?
    public var voiceAutoPunctuation: Bool
    public var customSettings: [String: String]

    public init(
        defaultTerminalFont: String? = nil,
        defaultTerminalFontSize: Double? = nil,
        voiceProvider: String? = nil,
        voiceAutoPunctuation: Bool = true,
        customSettings: [String: String] = [:]
    ) {
        self.defaultTerminalFont = defaultTerminalFont
        self.defaultTerminalFontSize = defaultTerminalFontSize
        self.voiceProvider = voiceProvider
        self.voiceAutoPunctuation = voiceAutoPunctuation
        self.customSettings = customSettings
    }
}

/// Decrypted payload containing catalog snapshot, preferences, and export timestamp.
public struct VaultPayload: Codable, Sendable {
    public var catalog: CatalogSnapshot
    public var preferences: VaultPreferences
    public var exportedAt: Date

    public init(
        catalog: CatalogSnapshot,
        preferences: VaultPreferences = VaultPreferences(),
        exportedAt: Date = Date()
    ) {
        self.catalog = catalog
        self.preferences = preferences
        self.exportedAt = exportedAt
    }
}

/// Export configuration options for vault encryption.
public struct VaultExportOptions: Sendable {
    public static let defaultIterations: Int = 600_000
    public static let minimumIterations: Int = 10_000

    public var iterations: Int
    public var saltLength: Int

    public init(
        iterations: Int = VaultExportOptions.defaultIterations,
        saltLength: Int = 32
    ) {
        self.iterations = max(iterations, VaultExportOptions.minimumIterations)
        self.saltLength = max(saltLength, 16)
    }
}

/// Errors raised during vault encryption, decryption, and verification.
public enum VaultBackupError: Error, LocalizedError, Sendable, Equatable {
    case emptyPassphrase
    case unsupportedFormat(String)
    case unsupportedVersion(Int)
    case unsupportedKDF(String)
    case unsupportedCipher(String)
    case insufficientIterations(Int)
    case corruptedPayload(String)
    case authenticationFailed
    case credentialsDisallowed(String)
    case serializationFailed(String)

    public var errorDescription: String? {
        switch self {
        case .emptyPassphrase:
            return "Passphrase cannot be empty."
        case .unsupportedFormat(let format):
            return "Unsupported vault backup format: \(format)."
        case .unsupportedVersion(let version):
            return "Unsupported vault backup version: \(version)."
        case .unsupportedKDF(let kdf):
            return "Unsupported key derivation algorithm: \(kdf)."
        case .unsupportedCipher(let cipher):
            return "Unsupported cipher algorithm: \(cipher)."
        case .insufficientIterations(let count):
            return "PBKDF2 iteration count is too low (\(count))."
        case .corruptedPayload(let reason):
            return "Vault backup payload is corrupted: \(reason)."
        case .authenticationFailed:
            return "Vault authentication failed: wrong passphrase or corrupted payload."
        case .credentialsDisallowed(let reason):
            return "Vault payload contains prohibited secret material: \(reason)."
        case .serializationFailed(let reason):
            return "Vault backup serialization failed: \(reason)."
        }
    }
}

/// Versioned, encrypted vault backup envelope.
public struct EncryptedVaultBackup: Codable, Sendable, Equatable {
    public static let currentFormat = "shh-vault-v1"
    public static let currentVersion = 1

    public var format: String
    public var version: Int
    public var createdAt: Date
    public var kdf: KDFParameters
    public var cipher: CipherPayload
    public var checksum: String

    public init(
        format: String = EncryptedVaultBackup.currentFormat,
        version: Int = EncryptedVaultBackup.currentVersion,
        createdAt: Date = Date(),
        kdf: KDFParameters,
        cipher: CipherPayload,
        checksum: String
    ) {
        self.format = format
        self.version = version
        self.createdAt = createdAt
        self.kdf = kdf
        self.cipher = cipher
        self.checksum = checksum
    }

    public struct KDFParameters: Codable, Sendable, Equatable, Hashable {
        public static let defaultAlgorithm = "PBKDF2-HMAC-SHA256"

        public var algorithm: String
        public var iterations: Int
        public var salt: Data

        public init(
            algorithm: String = KDFParameters.defaultAlgorithm,
            iterations: Int = VaultExportOptions.defaultIterations,
            salt: Data
        ) {
            self.algorithm = algorithm
            self.iterations = iterations
            self.salt = salt
        }
    }

    public struct CipherPayload: Codable, Sendable, Equatable, Hashable {
        public static let defaultAlgorithm = "AES-256-GCM"

        public var algorithm: String
        public var nonce: Data
        public var tag: Data
        public var ciphertext: Data

        public init(
            algorithm: String = CipherPayload.defaultAlgorithm,
            nonce: Data,
            tag: Data,
            ciphertext: Data
        ) {
            self.algorithm = algorithm
            self.nonce = nonce
            self.tag = tag
            self.ciphertext = ciphertext
        }
    }
}

/// Local-first encrypted sync models.
public enum SyncRecordType: String, Codable, Sendable, CaseIterable {
    case host
    case group
    case tag
    case identity
    case snippet
    case preference
}

public struct SyncRecord: Codable, Sendable, Equatable, Identifiable {
    public var id: UUID
    public var type: SyncRecordType
    public var version: UInt64
    public var updatedAt: Date
    public var isDeleted: Bool
    public var encryptedData: Data

    public init(
        id: UUID = UUID(),
        type: SyncRecordType,
        version: UInt64 = 1,
        updatedAt: Date = Date(),
        isDeleted: Bool = false,
        encryptedData: Data
    ) {
        self.id = id
        self.type = type
        self.version = version
        self.updatedAt = updatedAt
        self.isDeleted = isDeleted
        self.encryptedData = encryptedData
    }
}

public struct SyncMetadata: Codable, Sendable, Equatable {
    public var deviceID: UUID
    public var generation: UInt64
    public var lastSyncTimestamp: Date?

    public init(
        deviceID: UUID = UUID(),
        generation: UInt64 = 0,
        lastSyncTimestamp: Date? = nil
    ) {
        self.deviceID = deviceID
        self.generation = generation
        self.lastSyncTimestamp = lastSyncTimestamp
    }
}

public struct SyncManifest: Codable, Sendable, Equatable {
    public static let currentSchemaVersion = 1

    public var schemaVersion: Int
    public var metadata: SyncMetadata
    public var records: [SyncRecord]

    public init(
        schemaVersion: Int = SyncManifest.currentSchemaVersion,
        metadata: SyncMetadata = SyncMetadata(),
        records: [SyncRecord] = []
    ) {
        self.schemaVersion = schemaVersion
        self.metadata = metadata
        self.records = records
    }
}

/// Service providing zero-knowledge encrypted backup and restore for Shh vaults.
public struct EncryptedVaultService: Sendable {
    public init() {}

    /// Export a catalog snapshot and preferences to an authenticated encrypted backup.
    public func exportBackup(
        catalog: CatalogSnapshot,
        preferences: VaultPreferences = VaultPreferences(),
        passphrase: String,
        options: VaultExportOptions = VaultExportOptions()
    ) throws -> EncryptedVaultBackup {
        guard !passphrase.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw VaultBackupError.emptyPassphrase
        }

        // Validate that catalog contains no secret material before encrypting
        try validateNoSecrets(in: catalog)

        let payload = VaultPayload(
            catalog: catalog,
            preferences: preferences,
            exportedAt: Date()
        )

        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys]
        guard let payloadData = try? encoder.encode(payload) else {
            throw VaultBackupError.serializationFailed("Failed to encode vault payload.")
        }

        // Generate cryptographically secure random salt
        let salt = generateRandomBytes(count: options.saltLength)

        // Derive 256-bit symmetric key using PBKDF2-HMAC-SHA256
        let derivedKey = try deriveKey(passphrase: passphrase, salt: salt, iterations: options.iterations)

        // Generate 12-byte random nonce for AES-GCM
        let nonce = AES.GCM.Nonce()

        // Associated Authenticated Data (AAD) binds format, version, and creation date
        let createdAt = payload.exportedAt
        let aadString = "\(EncryptedVaultBackup.currentFormat):\(EncryptedVaultBackup.currentVersion):\(Int64(createdAt.timeIntervalSince1970))"
        let aadData = Data(aadString.utf8)

        // Encrypt using AES-256-GCM
        let sealedBox: AES.GCM.SealedBox
        do {
            sealedBox = try AES.GCM.seal(payloadData, using: derivedKey, nonce: nonce, authenticating: aadData)
        } catch {
            throw VaultBackupError.serializationFailed("AES-GCM seal failed: \(error.localizedDescription)")
        }

        let nonceData = Data(nonce)
        let tagData = sealedBox.tag
        let ciphertext = sealedBox.ciphertext

        // Compute authenticated checksum (SHA-256 over nonce + tag + ciphertext)
        let checksum = computeChecksum(nonce: nonceData, tag: tagData, ciphertext: ciphertext)

        return EncryptedVaultBackup(
            format: EncryptedVaultBackup.currentFormat,
            version: EncryptedVaultBackup.currentVersion,
            createdAt: createdAt,
            kdf: EncryptedVaultBackup.KDFParameters(
                algorithm: EncryptedVaultBackup.KDFParameters.defaultAlgorithm,
                iterations: options.iterations,
                salt: salt
            ),
            cipher: EncryptedVaultBackup.CipherPayload(
                algorithm: EncryptedVaultBackup.CipherPayload.defaultAlgorithm,
                nonce: nonceData,
                tag: tagData,
                ciphertext: ciphertext
            ),
            checksum: checksum
        )
    }

    /// Export backup directly to serialized JSON Data.
    public func exportBackupData(
        catalog: CatalogSnapshot,
        preferences: VaultPreferences = VaultPreferences(),
        passphrase: String,
        options: VaultExportOptions = VaultExportOptions()
    ) throws -> Data {
        let backup = try exportBackup(catalog: catalog, preferences: preferences, passphrase: passphrase, options: options)
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        guard let data = try? encoder.encode(backup) else {
            throw VaultBackupError.serializationFailed("Failed to encode backup envelope.")
        }
        return data
    }

    /// Restore and decrypt a vault backup with passphrase verification.
    public func restoreBackup(
        backup: EncryptedVaultBackup,
        passphrase: String
    ) throws -> VaultPayload {
        guard !passphrase.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw VaultBackupError.emptyPassphrase
        }

        // Validate envelope headers
        guard backup.format == EncryptedVaultBackup.currentFormat else {
            throw VaultBackupError.unsupportedFormat(backup.format)
        }
        guard backup.version == EncryptedVaultBackup.currentVersion else {
            throw VaultBackupError.unsupportedVersion(backup.version)
        }
        guard backup.kdf.algorithm == EncryptedVaultBackup.KDFParameters.defaultAlgorithm else {
            throw VaultBackupError.unsupportedKDF(backup.kdf.algorithm)
        }
        guard backup.cipher.algorithm == EncryptedVaultBackup.CipherPayload.defaultAlgorithm else {
            throw VaultBackupError.unsupportedCipher(backup.cipher.algorithm)
        }
        guard backup.kdf.iterations >= VaultExportOptions.minimumIterations else {
            throw VaultBackupError.insufficientIterations(backup.kdf.iterations)
        }

        // Verify authenticated checksum
        let expectedChecksum = computeChecksum(
            nonce: backup.cipher.nonce,
            tag: backup.cipher.tag,
            ciphertext: backup.cipher.ciphertext
        )
        guard backup.checksum == expectedChecksum else {
            throw VaultBackupError.authenticationFailed
        }

        // Derive key
        let derivedKey = try deriveKey(
            passphrase: passphrase,
            salt: backup.kdf.salt,
            iterations: backup.kdf.iterations
        )

        // Reconstruct AES-GCM nonce and sealed box
        guard let nonce = try? AES.GCM.Nonce(data: backup.cipher.nonce) else {
            throw VaultBackupError.corruptedPayload("Invalid GCM nonce length.")
        }

        guard let sealedBox = try? AES.GCM.SealedBox(
            nonce: nonce,
            ciphertext: backup.cipher.ciphertext,
            tag: backup.cipher.tag
        ) else {
            throw VaultBackupError.corruptedPayload("Invalid GCM sealed box structure.")
        }

        // Reconstruct AAD
        let aadString = "\(backup.format):\(backup.version):\(Int64(backup.createdAt.timeIntervalSince1970))"
        let aadData = Data(aadString.utf8)

        // Authenticated decrypt
        let decryptedData: Data
        do {
            decryptedData = try AES.GCM.open(sealedBox, using: derivedKey, authenticating: aadData)
        } catch {
            throw VaultBackupError.authenticationFailed
        }

        // Decode payload
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        guard let payload = try? decoder.decode(VaultPayload.self, from: decryptedData) else {
            throw VaultBackupError.corruptedPayload("Failed to decode decrypted vault payload.")
        }

        // Verify catalog contains no prohibited secrets
        try validateNoSecrets(in: payload.catalog)

        return payload
    }

    /// Restore and decrypt from serialized JSON Data.
    public func restoreBackup(
        data: Data,
        passphrase: String
    ) throws -> VaultPayload {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        guard let backup = try? decoder.decode(EncryptedVaultBackup.self, from: data) else {
            throw VaultBackupError.corruptedPayload("Failed to parse backup envelope JSON.")
        }
        return try restoreBackup(backup: backup, passphrase: passphrase)
    }

    /// Verify whether a passphrase correctly decrypts the backup without throwing.
    public func verifyPassphrase(backup: EncryptedVaultBackup, passphrase: String) -> Bool {
        do {
            _ = try restoreBackup(backup: backup, passphrase: passphrase)
            return true
        } catch {
            return false
        }
    }

    // MARK: - Internal Cryptographic Primitives

    private func deriveKey(passphrase: String, salt: Data, iterations: Int) throws -> SymmetricKey {
        #if canImport(CommonCrypto)
        var derivedKeyData = Data(repeating: 0, count: 32)
        let status = derivedKeyData.withUnsafeMutableBytes { derivedKeyBytes in
            salt.withUnsafeBytes { saltBytes in
                CCKeyDerivationPBKDF(
                    CCPBKDFAlgorithm(kCCPBKDF2),
                    passphrase,
                    passphrase.utf8.count,
                    saltBytes.bindMemory(to: UInt8.self).baseAddress,
                    salt.count,
                    CCPseudoRandomAlgorithm(kCCPRFHmacAlgSHA256),
                    UInt32(iterations),
                    derivedKeyBytes.bindMemory(to: UInt8.self).baseAddress,
                    32
                )
            }
        }
        guard status == 0 else {
            throw VaultBackupError.corruptedPayload("PBKDF2 key derivation failed with code \(status).")
        }
        defer {
            // Zero memory of temporary key buffer
            derivedKeyData.resetBytes(in: 0..<derivedKeyData.count)
        }
        return SymmetricKey(data: derivedKeyData)
        #else
        // Fallback or non-Darwin HKDF derivation
        let inputKey = SymmetricKey(data: Data(passphrase.utf8))
        return HKDF<SHA256>.deriveKey(inputKeyMaterial: inputKey, salt: salt, outputByteCount: 32)
        #endif
    }

    private func computeChecksum(nonce: Data, tag: Data, ciphertext: Data) -> String {
        var hasher = SHA256()
        hasher.update(data: nonce)
        hasher.update(data: tag)
        hasher.update(data: ciphertext)
        let digest = hasher.finalize()
        return digest.map { String(format: "%02x", $0) }.joined()
    }

    private func generateRandomBytes(count: Int) -> Data {
        #if canImport(Security)
        var bytes = [UInt8](repeating: 0, count: count)
        let status = SecRandomCopyBytes(kSecRandomDefault, count, &bytes)
        if status == errSecSuccess {
            return Data(bytes)
        }
        #endif
        return Data((0..<count).map { _ in UInt8.random(in: 0...255) })
    }

    private func validateNoSecrets(in catalog: CatalogSnapshot) throws {
        // Confirm no private key headers or secret markers exist in any identity or host
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        guard let data = try? encoder.encode(catalog),
              let jsonString = String(data: data, encoding: .utf8) else {
            return
        }

        let forbiddenPatterns = [
            "-----BEGIN OPENSSH PRIVATE KEY-----",
            "-----BEGIN RSA PRIVATE KEY-----",
            "-----BEGIN EC PRIVATE KEY-----",
            "-----BEGIN PRIVATE KEY-----",
            "-----BEGIN DSA PRIVATE KEY-----"
        ]

        for pattern in forbiddenPatterns {
            if jsonString.contains(pattern) {
                throw VaultBackupError.credentialsDisallowed("Prohibited private key pattern detected in catalog snapshot.")
            }
        }
    }
}
