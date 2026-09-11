import Foundation
import ShhCore
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
    private var connection: (any SSHConnection)?
    private var eventTask: Task<Void, Never>?
    private var terminalGrid = TerminalGrid()
    private var ansiParser = ANSIParser()
    private var redactor = Redactor()

    init() {
        catalog = InMemoryCatalog()
        transport = DemoSSHTransport()
        trustStore = InMemoryTrustStore()
        credentialStore = KeychainCredentialStore()
        transcriber = UnavailableTranscriber()
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
        let session = TerminalSession(hostID: host.id, state: .connecting, capabilities: ["ansi", "resize"])
        activeSession = session
        await loadRedactionSecret(for: host)
        do {
            let connection = try await transport.connect(host: host, identity: await identity(for: host), trustEvaluator: trustStore)
            guard activeSession?.id == session.id else {
                await connection.close()
                return
            }
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
                        case .closed: self.activeSession?.state = .disconnected
                        case .error: self.activeSession?.state = .failed; self.terminalText += "\nConnection error."
                        }
                    }
                } catch {
                    guard self?.activeSession?.id == session.id else { return }
                    self?.activeSession?.state = .failed
                    self?.terminalText += "\nConnection error."
                }
            }
        } catch let error as TransportError {
            switch error {
            case .hostKeyApprovalRequired(let challenge):
                pendingTrustChallenge = challenge
                pendingTrustHost = host
                activeSession?.state = .disconnected
            case .hostKeyChanged:
                activeSession?.state = .failed
                terminalText = "Connection refused: the host key changed."
            default:
                activeSession?.state = .failed
                terminalText = "Connection unavailable."
            }
        } catch {
            activeSession?.state = .failed
            terminalText = "Connection unavailable."
        }
    }

    func approvePendingHostKey(permanently: Bool) async {
        guard let challenge = pendingTrustChallenge, let host = pendingTrustHost else { return }
        if permanently { await trustStore.save(challenge) } else { await trustStore.trustOnce(challenge) }
        pendingTrustChallenge = nil
        pendingTrustHost = nil
        await connect(to: host)
    }

    func rejectPendingHostKey() {
        pendingTrustChallenge = nil
        pendingTrustHost = nil
        activeSession?.state = .disconnected
    }

    func send(_ command: String, approved: Bool = false) async -> Bool {
        guard CommandPolicy().canSend(command, approved: approved), activeSession?.state == .connected, let connection else { return false }
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
