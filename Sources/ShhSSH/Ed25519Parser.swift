import Foundation
import Crypto
import Citadel
import NIOCore
import NIOSSH
import ShhCore

enum Ed25519Parser {
    static func parse(from data: Data) throws -> Curve25519.Signing.PrivateKey {
        if let text = String(data: data, encoding: .utf8) {
            let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmed.contains("-----BEGIN OPENSSH PRIVATE KEY-----") {
                do {
                    return try Curve25519.Signing.PrivateKey(sshEd25519: trimmed)
                } catch {
                    throw TransportError.invalidConfiguration
                }
            }
            if let decoded = Data(base64Encoded: trimmed), decoded.count == 32 {
                do {
                    return try Curve25519.Signing.PrivateKey(rawRepresentation: decoded)
                } catch {
                    throw TransportError.invalidConfiguration
                }
            }
        }
        if data.count == 32 {
            do {
                return try Curve25519.Signing.PrivateKey(rawRepresentation: data)
            } catch {
                throw TransportError.invalidConfiguration
            }
        }
        if let key = try? Curve25519.Signing.PrivateKey(sshEd25519: data) {
            return key
        }
        throw TransportError.invalidConfiguration
    }
}
