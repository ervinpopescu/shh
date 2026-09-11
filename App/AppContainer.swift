import Foundation
import ShhCore
import ShhSSH
import SwiftUI

@MainActor
final class AppContainer: ObservableObject {
    let catalog: InMemoryCatalog
    let transport: any SSHTransport
    let trustStore: InMemoryTrustStore
    let credentialStore: any CredentialStore
    let transcriber: any LocalTranscriber
    @Published var activeSession: TerminalSession?
    @Published var terminalText = ""
    @Published var speechState: SpeechComposerState = .idle
    @Published var pendingTrustChallenge: HostKeyChallenge?
    private var pendingTrustHost: Host?
    private(set) var connection: (any SSHConnection)?
    private var eventTask: Task<Void, Never>?
    private var terminalGrid = TerminalGrid()
    private var ansiParser = ANSIParser()
    private(set) var redactor = Redactor()

    var isDemo: Bool {
        transport is DemoSSHTransport
    }

    init(
        catalog: InMemoryCatalog = InMemoryCatalog(),
        trustStore: InMemoryTrustStore = InMemoryTrustStore(),
        credentialStore: (any CredentialStore)? = nil,
        transport: (any SSHTransport)? = nil,
        transcriber: any LocalTranscriber = UnavailableTranscriber()
    ) {
        let resolvedCredentialStore = credentialStore ?? KeychainCredentialStore()
        self.catalog = catalog
        self.trustStore = trustStore
        self.credentialStore = resolvedCredentialStore
        self.transport = transport ?? LiveSSHTransport(credentialStore: resolvedCredentialStore)
        self.transcriber = transcriber
    }

    static func demo(
        catalog: InMemoryCatalog = InMemoryCatalog(),
        trustStore: InMemoryTrustStore = InMemoryTrustStore(),
        credentialStore: any CredentialStore = InMemoryCredentialStore(),
        transcriber: any LocalTranscriber = UnavailableTranscriber()
    ) -> AppContainer {
        AppContainer(
            catalog: catalog,
            trustStore: trustStore,
            credentialStore: credentialStore,
            transport: DemoSSHTransport(),
            transcriber: transcriber
        )
    }

    static func statusMessage(for error: Error) -> String {
        guard let transportError = error as? TransportError else {
            return "Connection unavailable."
        }
        switch transportError {
        case .authenticationRequired:
            return "Authentication required."
        case .timeout:
            return "Connection timed out."
        case .networkUnavailable:
            return "Network unavailable."
        case .unsupported, .invalidConfiguration:
            return "Unsupported configuration."
        case .cancelled:
            return "Connection cancelled."
        case .hostKeyChanged:
            return "Connection refused: host key has changed."
        case .hostKeyApprovalRequired:
            return "Host key approval required."
        case .remoteFailure:
            return "Connection failed."
        }
    }

    func connect(to host: Host) async {
        guard activeSession?.state != .connecting else { return }
        eventTask?.cancel()
        await connection?.close()
        connection = nil
        pendingTrustChallenge = nil
        pendingTrustHost = nil
        terminalGrid = TerminalGrid()
        ansiParser = ANSIParser()
        terminalText = ""
        redactor = Redactor()
        let session = TerminalSession(hostID: host.id, state: .connecting, capabilities: ["ansi", "resize"])
        activeSession = session
        do {
            let connection = try await transport.connect(
                host: host,
                identity: await identity(for: host),
                trustEvaluator: trustStore,
                initialSize: terminalGrid.size
            )
            guard activeSession?.id == session.id, activeSession?.state == .connecting else {
                await connection.close()
                return
            }
            // Host key is accepted and connection succeeded; load redaction secret if available
            await loadRedactionSecret(for: host)
            self.connection = connection
            activeSession?.state = .connected
            let events = await connection.events()
            eventTask = Task { @MainActor [weak self] in
                do {
                    for try await event in events {
                        guard let self, self.activeSession?.id == session.id else { return }
                        switch event {
                        case .bytes(let data):
                            self.ansiParser.consume(self.redacted(data), into: &self.terminalGrid)
                            self.terminalText = self.terminalGrid.transcriptText
                        case .closed:
                            self.activeSession?.state = .disconnected
                            self.redactor = Redactor()
                        case .error(let error):
                            self.activeSession?.state = .failed
                            self.terminalText += "\n" + Self.statusMessage(for: error)
                            self.redactor = Redactor()
                        }
                    }
                } catch {
                    guard self?.activeSession?.id == session.id else { return }
                    self?.activeSession?.state = .failed
                    self?.terminalText += "\n" + Self.statusMessage(for: error)
                    self?.redactor = Redactor()
                }
            }
        } catch let error as TransportError {
            guard activeSession?.id == session.id, activeSession?.state == .connecting else { return }
            switch error {
            case .hostKeyApprovalRequired(let challenge):
                pendingTrustChallenge = challenge
                pendingTrustHost = host
                activeSession?.state = .disconnected
            case .cancelled:
                activeSession?.state = .disconnected
                terminalText = Self.statusMessage(for: error)
            default:
                activeSession?.state = .failed
                terminalText = Self.statusMessage(for: error)
            }
        } catch {
            guard activeSession?.id == session.id, activeSession?.state == .connecting else { return }
            activeSession?.state = .failed
            terminalText = "Connection unavailable."
        }
    }

    func approvePendingHostKey(permanently: Bool) async {
        guard let challenge = pendingTrustChallenge, let host = pendingTrustHost else { return }
        if permanently {
            await trustStore.save(challenge)
        } else {
            await trustStore.trustOnce(challenge)
        }
        pendingTrustChallenge = nil
        pendingTrustHost = nil
        await connect(to: host)
    }

    func rejectPendingHostKey() {
        pendingTrustChallenge = nil
        pendingTrustHost = nil
        activeSession?.state = .disconnected
        redactor = Redactor()
    }

    func send(_ command: String, approved: Bool = false) async -> Bool {
        guard CommandPolicy().canSend(command, approved: approved),
              activeSession?.state == .connected,
              let connection else { return false }
        do {
            try await connection.send(Data(command.utf8))
            return true
        } catch {
            terminalText += "\nSend failed."
            return false
        }
    }

    func disconnect() async {
        eventTask?.cancel()
        await connection?.close()
        connection = nil
        activeSession?.state = .disconnected
        redactor = Redactor()
    }

    private func identity(for host: Host) async -> IdentityDescriptor? {
        guard let identityID = host.identityID,
              let identities = try? await catalog.identities() else { return nil }
        return identities.first(where: { $0.id == identityID })
    }

    private func loadRedactionSecret(for host: Host) async {
        redactor = Redactor()
        guard let identityID = host.identityID,
              let identities = try? await catalog.identities(),
              let identity = identities.first(where: { $0.id == identityID }),
              let secret = try? await credentialStore.load(reference: identity.keychainReference),
              let value = String(data: secret, encoding: .utf8), !value.isEmpty else { return }
        redactor = Redactor(secrets: [value])
    }

    private func redacted(_ data: Data) -> Data {
        Data(redactor.redact(String(decoding: data, as: UTF8.self)).utf8)
    }
}
