import Foundation
import Crypto
import Citadel
import NIOCore
import NIOSSH
import ShhCore

public enum Ed25519Parser {
    public static func parse(from text: String) throws -> Curve25519.Signing.PrivateKey {
        try parse(from: Data(text.utf8))
    }

    public static func parse(from data: Data) throws -> Curve25519.Signing.PrivateKey {
        if let text = String(data: data, encoding: .utf8) {
            let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmed.contains("-----BEGIN RSA PRIVATE KEY-----") || trimmed.contains("ssh-rsa") {
                throw TransportError.invalidPrivateKey(detail: "RSA private keys are not currently supported. Please use an Ed25519 key or password.")
            }
            if trimmed.contains("-----BEGIN EC PRIVATE KEY-----") || trimmed.contains("ecdsa-") {
                throw TransportError.invalidPrivateKey(detail: "ECDSA private keys are not currently supported. Please use an Ed25519 key or password.")
            }
            if trimmed.contains("-----BEGIN OPENSSH PRIVATE KEY-----") {
                if let cipher = openSSHCipherName(text: trimmed), cipher != "none" {
                    throw TransportError.invalidPrivateKey(detail: "Passphrase-encrypted OpenSSH keys are not yet supported. Please import an unencrypted Ed25519 key.")
                }
                if let parsed = parseOpenSSHDirect(text: trimmed) {
                    return parsed
                }
                if let key = try? Curve25519.Signing.PrivateKey(sshEd25519: trimmed) {
                    return key
                }
                throw TransportError.invalidPrivateKey(detail: "Could not parse Ed25519 private key. Ensure the entire key block is included.")
            }
            if trimmed.contains("-----BEGIN PRIVATE KEY-----") {
                let base64Body = trimmed
                    .components(separatedBy: .newlines)
                    .filter { !$0.hasPrefix("-----") && !$0.isEmpty }
                    .joined()
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                if let decoded = Data(base64Encoded: base64Body) {
                    if decoded.count == 48 {
                        let rawKey = decoded.suffix(32)
                        if let key = try? Curve25519.Signing.PrivateKey(rawRepresentation: rawKey) {
                            return key
                        }
                    } else if decoded.count > 48 {
                        if let marker = decoded.range(of: Data([0x04, 0x20])) {
                            let start = marker.upperBound
                            if decoded.count >= start + 32 {
                                let rawKey = decoded.subdata(in: start..<(start + 32))
                                if let key = try? Curve25519.Signing.PrivateKey(rawRepresentation: rawKey) {
                                    return key
                                }
                            }
                        }
                    }
                }
            }
            if let decoded = Data(base64Encoded: trimmed), decoded.count == 32 {
                do {
                    return try Curve25519.Signing.PrivateKey(rawRepresentation: decoded)
                } catch {
                    throw TransportError.invalidPrivateKey(detail: "Could not parse Ed25519 private key. Ensure the entire key block is included.")
                }
            }
            if trimmed.count == 64 && trimmed.allSatisfy(\.isHexDigit) {
                var hexBytes = [UInt8]()
                hexBytes.reserveCapacity(32)
                var index = trimmed.startIndex
                while index < trimmed.endIndex {
                    let nextIndex = trimmed.index(index, offsetBy: 2)
                    if let byte = UInt8(trimmed[index..<nextIndex], radix: 16) {
                        hexBytes.append(byte)
                    }
                    index = nextIndex
                }
                if hexBytes.count == 32, let key = try? Curve25519.Signing.PrivateKey(rawRepresentation: Data(hexBytes)) {
                    return key
                }
            }
        }
        if data.count == 32 {
            do {
                return try Curve25519.Signing.PrivateKey(rawRepresentation: data)
            } catch {
                throw TransportError.invalidPrivateKey(detail: "Could not parse Ed25519 private key. Ensure the entire key block is included.")
            }
        }
        if let key = try? Curve25519.Signing.PrivateKey(sshEd25519: data) {
            return key
        }
        throw TransportError.invalidPrivateKey(detail: "Could not parse Ed25519 private key. Ensure the entire key block is included.")
    }

    private static func openSSHCipherName(text: String) -> String? {
        let base64Body = text
            .components(separatedBy: .newlines)
            .filter { !$0.hasPrefix("-----") && !$0.isEmpty }
            .joined()
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard let data = Data(base64Encoded: base64Body) else { return nil }
        var buffer = ByteBuffer(data: data)
        guard buffer.readString(length: 15) == "openssh-key-v1\0" else { return nil }
        guard let cipherBytes = readSSHStringBytes(from: &buffer) else { return nil }
        return String(bytes: cipherBytes, encoding: .utf8)
    }

    private static func readSSHStringBytes(from buffer: inout ByteBuffer) -> [UInt8]? {
        guard let length = buffer.readInteger(as: UInt32.self),
              let bytes = buffer.readBytes(length: Int(length)) else {
            return nil
        }
        return bytes
    }

    private static func parseOpenSSHDirect(text: String) -> Curve25519.Signing.PrivateKey? {
        let base64Body = text
            .components(separatedBy: .newlines)
            .filter { !$0.hasPrefix("-----") && !$0.isEmpty }
            .joined()
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard let data = Data(base64Encoded: base64Body) else { return nil }
        var buffer = ByteBuffer(data: data)
        guard buffer.readString(length: 15) == "openssh-key-v1\0" else { return nil }
        guard let cipherBytes = readSSHStringBytes(from: &buffer),
              String(bytes: cipherBytes, encoding: .utf8) == "none" else { return nil }
        guard let _ = readSSHStringBytes(from: &buffer) else { return nil } // kdf
        guard let _ = readSSHStringBytes(from: &buffer) else { return nil } // kdfOptions
        guard let numKeys = buffer.readInteger(as: UInt32.self), numKeys == 1 else { return nil }
        guard let _ = readSSHStringBytes(from: &buffer) else { return nil } // public key block
        guard let privBlockBytes = readSSHStringBytes(from: &buffer) else { return nil }

        var privBuffer = ByteBuffer(bytes: privBlockBytes)
        guard let check1 = privBuffer.readInteger(as: UInt32.self),
              let check2 = privBuffer.readInteger(as: UInt32.self),
              check1 == check2 else { return nil }
        guard let keyTypeBytes = readSSHStringBytes(from: &privBuffer),
              String(bytes: keyTypeBytes, encoding: .utf8) == "ssh-ed25519" else { return nil }
        guard let _ = readSSHStringBytes(from: &privBuffer) else { return nil } // pubkey in priv block
        guard let keyBytes = readSSHStringBytes(from: &privBuffer), keyBytes.count >= 32 else { return nil }
        let seed = Data(keyBytes.prefix(32))
        return try? Curve25519.Signing.PrivateKey(rawRepresentation: seed)
    }

    public static func openSSHPublicKeyData(from publicKey: Curve25519.Signing.PublicKey) -> Data {
        var data = Data()
        let prefix = "ssh-ed25519"
        var prefixLength = UInt32(prefix.utf8.count).bigEndian
        data.append(Data(bytes: &prefixLength, count: 4))
        data.append(Data(prefix.utf8))
        var keyLength = UInt32(publicKey.rawRepresentation.count).bigEndian
        data.append(Data(bytes: &keyLength, count: 4))
        data.append(publicKey.rawRepresentation)
        return data
    }

    public static func openSSHPublicKeyString(from publicKey: Curve25519.Signing.PublicKey, comment: String? = nil) -> String {
        let wire = openSSHPublicKeyData(from: publicKey)
        let base64 = wire.base64EncodedString()
        if let comment = comment?.trimmingCharacters(in: .whitespacesAndNewlines), !comment.isEmpty {
            return "ssh-ed25519 \(base64) \(comment)"
        }
        return "ssh-ed25519 \(base64)"
    }

    public static func fingerprint(from publicKey: Curve25519.Signing.PublicKey) -> String {
        let wire = openSSHPublicKeyData(from: publicKey)
        let digest = SHA256.hash(data: wire)
        let base64 = Data(digest).base64EncodedString().trimmingCharacters(in: CharacterSet(charactersIn: "="))
        return "SHA256:\(base64)"
    }

    public static func generateKeyPair(comment: String? = nil) -> (
        privateKey: Curve25519.Signing.PrivateKey,
        openSSHPrivateKey: String,
        openSSHPublicKey: String,
        fingerprint: String
    ) {
        let privateKey = Curve25519.Signing.PrivateKey()
        let openSSHPrivateKey = privateKey.makeSSHRepresentation(comment: comment ?? "")
        let publicKey = privateKey.publicKey
        let openSSHPublicKey = openSSHPublicKeyString(from: publicKey, comment: comment)
        let fp = fingerprint(from: publicKey)
        return (privateKey, openSSHPrivateKey, openSSHPublicKey, fp)
    }
}
