import Foundation
import ShhCore
import SwiftUI

@MainActor
final class AppContainer: ObservableObject {
    let catalog: InMemoryCatalog
    let transport: any SSHTransport
    let trustStore: InMemoryTrustStore
    let transcriber: any LocalTranscriber
    @Published var activeSession: TerminalSession?
    @Published var terminalText = ""
    @Published var speechState: SpeechComposerState = .idle
    private var connection: (any SSHConnection)?
    private var eventTask: Task<Void, Never>?

    init() {
        catalog = InMemoryCatalog()
        transport = DemoSSHTransport()
        trustStore = InMemoryTrustStore()
        transcriber = UnavailableTranscriber()
    }

    func connect(to host: Host) async {
        eventTask?.cancel()
        activeSession = TerminalSession(hostID: host.id, state: .connecting, capabilities: ["ansi", "resize"])
        do {
            let connection = try await transport.connect(host: host, identity: nil, trustEvaluator: trustStore)
            self.connection = connection
            activeSession?.state = .connected
            let events = await connection.events()
            eventTask = Task { @MainActor [weak self] in
                do {
                    for try await event in events {
                        guard let self else { return }
                        switch event {
                        case .bytes(let data): self.terminalText += String(decoding: data, as: UTF8.self)
                        case .closed: self.activeSession?.state = .disconnected
                        case .error: self.activeSession?.state = .failed
                        }
                    }
                } catch { self?.activeSession?.state = .failed }
            }
        } catch { activeSession?.state = .failed; terminalText = "Connection unavailable: \(error)" }
    }

    func send(_ command: String) async {
        guard activeSession?.state == .connected, let connection else { return }
        do { try await connection.send(Data(command.utf8)) } catch { terminalText += "\nSend failed: \(error)" }
    }

    func disconnect() async {
        eventTask?.cancel(); await connection?.close(); connection = nil
        activeSession?.state = .disconnected
    }
}
