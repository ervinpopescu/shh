import Foundation
import ShhCore
import ShhSSH
import ShhTerminal
import SwiftUI

@MainActor
final class AppContainer: ObservableObject {
    let catalog: InMemoryCatalog
    let transport: any SSHTransport
    let trustStore: InMemoryTrustStore
    let credentialStore: any CredentialStore
    let transcriber: any LocalTranscriber
    let terminalController: ShhTerminalController

    @Published var useLegacyTerminalFallback: Bool
    @Published var activeSession: TerminalSession?
    @Published var terminalText = ""
    @Published var speechState: SpeechComposerState = .idle
    @Published var pendingTrustChallenge: HostKeyChallenge?
    private var pendingTrustHost: Host?
    private(set) var connection: (any SSHConnection)?
    private var eventTask: Task<Void, Never>?
    private var outboundTask: Task<Void, Never>?
    private var terminalGrid = TerminalGrid()
    private var ansiParser = ANSIParser()
    private(set) var redactor = Redactor()

    var isDemo: Bool {
        transport is DemoSSHTransport
    }

    var accessibilityTerminalText: String {
        if useLegacyTerminalFallback {
            return terminalText.isEmpty ? "No terminal output" : terminalText
        }
        let transcript = terminalController.currentTranscript(limit: 50)
        if transcript.isEmpty {
            return terminalText.isEmpty ? "No terminal output" : terminalText
        }
        return transcript
    }

    init(
        catalog: InMemoryCatalog = InMemoryCatalog(),
        trustStore: InMemoryTrustStore = InMemoryTrustStore(),
        credentialStore: (any CredentialStore)? = nil,
        transport: (any SSHTransport)? = nil,
        transcriber: any LocalTranscriber = UnavailableTranscriber(),
        useLegacyTerminalFallback: Bool = false
    ) {
        let resolvedCredentialStore = credentialStore ?? KeychainCredentialStore()
        let fallbackArg = ProcessInfo.processInfo.arguments.contains("--legacy-terminal") ||
            ProcessInfo.processInfo.environment["SHH_LEGACY_TERMINAL"] == "1"
        self.catalog = catalog
        self.trustStore = trustStore
        self.credentialStore = resolvedCredentialStore
        self.transport = transport ?? LiveSSHTransport(credentialStore: resolvedCredentialStore)
        self.transcriber = transcriber
        self.useLegacyTerminalFallback = useLegacyTerminalFallback || fallbackArg
        self.terminalController = ShhTerminalController()
    }

    static func demo(
        catalog: InMemoryCatalog = InMemoryCatalog(),
        trustStore: InMemoryTrustStore = InMemoryTrustStore(),
        credentialStore: any CredentialStore = InMemoryCredentialStore(),
        transcriber: any LocalTranscriber = UnavailableTranscriber(),
        useLegacyTerminalFallback: Bool = false
    ) -> AppContainer {
        AppContainer(
            catalog: catalog,
            trustStore: trustStore,
            credentialStore: credentialStore,
            transport: DemoSSHTransport(),
            transcriber: transcriber,
            useLegacyTerminalFallback: useLegacyTerminalFallback
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
        detachCallbacks()
        await connection?.close()
        connection = nil
        pendingTrustChallenge = nil
        pendingTrustHost = nil
        terminalGrid = TerminalGrid()
        ansiParser = ANSIParser()
        terminalText = ""
        redactor = Redactor()
        terminalController.reset()

        let session = TerminalSession(hostID: host.id, state: .connecting, capabilities: ["ansi", "resize"])
        activeSession = session
        let initialSize = terminalController.size
        do {
            let connection = try await transport.connect(
                host: host,
                identity: await identity(for: host),
                trustEvaluator: trustStore,
                initialSize: initialSize
            )
            guard activeSession?.id == session.id, activeSession?.state == .connecting else {
                await connection.close()
                return
            }
            // Host key is accepted and connection succeeded; load redaction secret if available
            await loadRedactionSecret(for: host)
            self.connection = connection
            activeSession?.state = .connected

            // Wire debounced resize callback to active connection
            terminalController.onResize = { [weak self, sessionID = session.id] newSize in
                Task { @MainActor [weak self] in
                    guard let self,
                          self.activeSession?.id == sessionID,
                          self.activeSession?.state == .connected,
                          let activeConnection = self.connection else { return }
                    try? await activeConnection.resize(newSize)
                }
            }

            // Wire interactive terminal output to raw outbound path
            terminalController.onOutput = { [weak self, sessionID = session.id] data in
                guard let self,
                      self.activeSession?.id == sessionID,
                      self.activeSession?.state == .connected else { return }
                self.enqueueRawInteractive(data, sessionID: sessionID)
            }

            let events = await connection.events()
            eventTask = Task { @MainActor [weak self] in
                do {
                    for try await event in events {
                        guard let self, self.activeSession?.id == session.id else { return }
                        switch event {
                        case .bytes(let data):
                            let redactedData = self.redacted(data)
                            if self.useLegacyTerminalFallback {
                                self.ansiParser.consume(redactedData, into: &self.terminalGrid)
                                self.terminalText = self.terminalGrid.transcriptText
                            } else {
                                self.terminalController.feed(redactedData)
                            }
                        case .closed:
                            self.activeSession?.state = .disconnected
                            self.detachCallbacks()
                            if !self.useLegacyTerminalFallback {
                                self.terminalController.feed("\r\n\u{1b}[90m[Connection closed]\u{1b}[0m\r\n")
                            }
                            self.redactor = Redactor()
                        case .error(let error):
                            self.activeSession?.state = .failed
                            self.detachCallbacks()
                            let message = Self.statusMessage(for: error)
                            self.terminalText += "\n" + message
                            if !self.useLegacyTerminalFallback {
                                self.terminalController.feed("\r\n\u{1b}[31m[" + message + "]\u{1b}[0m\r\n")
                            }
                            self.redactor = Redactor()
                        }
                    }
                } catch {
                    guard let self, self.activeSession?.id == session.id else { return }
                    self.activeSession?.state = .failed
                    self.detachCallbacks()
                    let message = Self.statusMessage(for: error)
                    self.terminalText += "\n" + message
                    if !self.useLegacyTerminalFallback {
                        self.terminalController.feed("\r\n\u{1b}[31m[" + message + "]\u{1b}[0m\r\n")
                    }
                    self.redactor = Redactor()
                }
            }
        } catch let error as TransportError {
            guard activeSession?.id == session.id, activeSession?.state == .connecting else { return }
            detachCallbacks()
            let message = Self.statusMessage(for: error)
            terminalText = message
            if !useLegacyTerminalFallback {
                terminalController.feed("\r\n\u{1b}[31m[" + message + "]\u{1b}[0m\r\n")
            }
            switch error {
            case .hostKeyApprovalRequired(let challenge):
                pendingTrustChallenge = challenge
                pendingTrustHost = host
                activeSession?.state = .disconnected
            case .cancelled:
                activeSession?.state = .disconnected
            default:
                activeSession?.state = .failed
            }
        } catch {
            guard activeSession?.id == session.id, activeSession?.state == .connecting else { return }
            detachCallbacks()
            let message = "Connection unavailable."
            activeSession?.state = .failed
            terminalText = message
            if !useLegacyTerminalFallback {
                terminalController.feed("\r\n\u{1b}[31m[" + message + "]\u{1b}[0m\r\n")
            }
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

    @discardableResult
    func sendRawInteractive(_ data: Data) async -> Bool {
        guard activeSession?.state == .connected,
              let connection else { return false }
        do {
            try await connection.send(data)
            return true
        } catch {
            return false
        }
    }

    @discardableResult
    func sendValidatedCommand(_ command: String, approved: Bool = false) async -> Bool {
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

    @discardableResult
    func send(_ command: String, approved: Bool = false) async -> Bool {
        await sendValidatedCommand(command, approved: approved)
    }

    func disconnect() async {
        detachCallbacks()
        eventTask?.cancel()
        eventTask = nil
        await connection?.close()
        connection = nil
        activeSession?.state = .disconnected
        redactor = Redactor()
    }

    private func detachCallbacks() {
        terminalController.onResize = nil
        terminalController.onOutput = nil
        outboundTask?.cancel()
        outboundTask = nil
    }

    private func enqueueRawInteractive(_ data: Data, sessionID: UUID) {
        let previousTask = outboundTask
        outboundTask = Task { @MainActor [weak self] in
            _ = await previousTask?.value
            guard let self,
                  self.activeSession?.id == sessionID,
                  self.activeSession?.state == .connected else { return }
            _ = await self.sendRawInteractive(data)
        }
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

    internal func redacted(_ data: Data) -> Data {
        guard !redactor.secrets.isEmpty else { return data }
        return Data(redactor.redact(String(decoding: data, as: UTF8.self)).utf8)
    }
}
