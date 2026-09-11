import Foundation
import Crypto
import NIOCore
import NIOSSH
import ShhCore

final class HostKeyValidatorDelegate: NIOSSHClientServerAuthenticationDelegate, @unchecked Sendable {
    private let hostname: String
    private let port: UInt16
    private let strictChecking: StrictHostKeyChecking
    private let trustEvaluator: any HostTrustEvaluator
    private let onChallengeReceived: (@Sendable (HostKeyChallenge) -> Void)?
    private let lock = NSLock()
    private var _capturedError: TransportError?

    var capturedError: TransportError? {
        lock.withLock { _capturedError }
    }

    init(
        hostname: String,
        port: UInt16,
        strictChecking: StrictHostKeyChecking,
        trustEvaluator: any HostTrustEvaluator,
        onChallengeReceived: (@Sendable (HostKeyChallenge) -> Void)? = nil
    ) {
        self.hostname = hostname
        self.port = port
        self.strictChecking = strictChecking
        self.trustEvaluator = trustEvaluator
        self.onChallengeReceived = onChallengeReceived
    }

    func validateHostKey(hostKey: NIOSSHPublicKey, validationCompletePromise: EventLoopPromise<Void>) {
        let openSSHRepresentation = String(openSSHPublicKey: hostKey)
        let algorithm = String(openSSHRepresentation.split(separator: " ").first ?? "ssh-ed25519")

        var buffer = ByteBufferAllocator().buffer(capacity: 256)
        _ = hostKey.write(to: &buffer)
        let bytes = buffer.readBytes(length: buffer.readableBytes) ?? []
        let digest = SHA256.hash(data: bytes)
        let base64 = Data(digest).base64EncodedString().trimmingCharacters(in: CharacterSet(charactersIn: "="))
        let fingerprint = "SHA256:\(base64)"
        let challenge = HostKeyChallenge(
            hostname: hostname,
            port: port,
            algorithm: algorithm,
            fingerprint: fingerprint
        )

        onChallengeReceived?(challenge)

        Task {
            let decision = await self.trustEvaluator.evaluate(challenge)
            switch decision {
            case .trustPermanently, .trustOnce:
                validationCompletePromise.succeed(())
            case .reject:
                let status = await self.trustEvaluator.status(for: challenge)
                let error: TransportError
                switch status {
                case .changed(let oldFingerprint):
                    error = .hostKeyChanged(old: oldFingerprint, new: challenge.fingerprint)
                case .unknown:
                    if self.strictChecking == .trustedOnly {
                        error = .remoteFailure("Host key is not trusted")
                    } else {
                        error = .hostKeyApprovalRequired(challenge)
                    }
                case .trusted:
                    error = .remoteFailure("Host key was rejected")
                }
                self.lock.withLock {
                    self._capturedError = error
                }
                validationCompletePromise.fail(error)
            }
        }
    }
}
