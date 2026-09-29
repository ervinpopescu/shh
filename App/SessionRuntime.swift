import Foundation
import ShhCore
import ShhSSH
import ShhTerminal

/// Owns the state and callback lifetime for one interactive SSH terminal.
///
/// This is the first migration seam for multi-session support. AppContainer still
/// owns the selected-session projections and the SFTP, forwarding, Mosh, voice,
/// tmux, and Herdr adapters. Those adapters intentionally remain single-session
/// until their connection ownership is moved to this runtime as follow-up work.
@MainActor
final class SessionRuntime {
    struct CallbackToken: Equatable, Sendable {
        let sessionID: UUID
        let generation: UInt64
    }

    let host: Host
    let terminalController: ShhTerminalController
    private(set) var session: TerminalSession
    private(set) var connection: any SSHConnection
    private(set) var redactor: Redactor
    private(set) var terminalGrid: TerminalGrid
    private(set) var ansiParser: ANSIParser
    private(set) var terminalText = ""
    private(set) var reconnectState: ReconnectState = .idle
    private(set) var reconnectGeneration: UInt64 = 0

    private(set) var eventTask: Task<Void, Never>?
    private(set) var outboundTask: Task<Void, Never>?
    private(set) var terminalResizeTask: Task<Bool, Never>?

    private var callbackGeneration: UInt64 = 0

    convenience init(
        host: Host,
        session: TerminalSession,
        connection: any SSHConnection
    ) {
        self.init(
            host: host,
            session: session,
            connection: connection,
            terminalController: ShhTerminalController(),
            redactor: Redactor()
        )
    }

    init(
        host: Host,
        session: TerminalSession,
        connection: any SSHConnection,
        terminalController: ShhTerminalController,
        redactor: Redactor
    ) {
        self.host = host
        self.session = session
        self.connection = connection
        self.terminalController = terminalController
        self.redactor = redactor
        self.terminalGrid = TerminalGrid(size: session.terminalSize)
        self.ansiParser = ANSIParser()
    }

    var callbackToken: CallbackToken {
        CallbackToken(sessionID: session.id, generation: callbackGeneration)
    }

    func accepts(_ token: CallbackToken) -> Bool {
        token == callbackToken && session.state == .connected
    }

    func setRedactor(_ redactor: Redactor) {
        self.redactor = redactor
        (connection as? LiveSSHConnection)?.setRedactor(redactor)
    }

    /// Activates the current connection and wires callbacks to this runtime.
    func activate() {
        session.state = .connected
        reconnectState = .connected
        installCallbacks()
        startEventMonitoring()
    }

    /// Replaces only this session's transport. The session identity and terminal
    /// model remain stable, while the generation rejects callbacks from the old
    /// connection even if its event stream races cancellation.
    func reconnect(with replacement: any SSHConnection) async {
        invalidateCallbacks()
        let previous = connection
        connection = replacement
        reconnectGeneration &+= 1
        reconnectState = .connecting(attempt: Int(reconnectGeneration))
        redactor = Redactor()
        session.state = .connecting
        terminalGrid = TerminalGrid(size: session.terminalSize)
        ansiParser = ANSIParser()
        terminalText = ""
        terminalController.reset()
        session.state = .connected
        reconnectState = .connected
        installCallbacks()
        startEventMonitoring()
        await previous.close()
    }

    @discardableResult
    func send(_ data: Data) async -> Bool {
        guard session.state == .connected else { return false }
        let token = callbackToken
        let activeConnection = connection
        do {
            try await activeConnection.send(data)
            return accepts(token)
        } catch {
            return false
        }
    }

    @discardableResult
    func resize(_ size: TerminalSize) async -> Bool {
        guard session.state == .connected else { return false }
        let token = callbackToken
        let activeConnection = connection
        do {
            try await activeConnection.resize(size)
            guard accepts(token) else { return false }
            session.terminalSize = size
            terminalGrid.resize(size)
            return true
        } catch {
            return false
        }
    }

    func disconnect() async {
        invalidateCallbacks()
        session.state = .disconnected
        reconnectState = .idle
        redactor = Redactor()
        let activeConnection = connection
        await activeConnection.close()
    }

    private func installCallbacks() {
        let token = callbackToken
        terminalController.onOutput = { [weak self] data in
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.enqueue(data, token: token)
            }
        }
        terminalController.onResize = { [weak self] size in
            Task { @MainActor [weak self] in
                guard let self, self.accepts(token) else { return }
                self.enqueueResize(size, token: token)
            }
        }
    }

    private func enqueue(_ data: Data, token: CallbackToken) {
        let previous = outboundTask
        outboundTask = Task { @MainActor [weak self] in
            _ = await previous?.value
            guard let self, self.accepts(token) else { return }
            _ = await self.send(data)
        }
    }

    private func enqueueResize(_ size: TerminalSize, token: CallbackToken) {
        let previous = terminalResizeTask
        let task = Task { @MainActor [weak self] in
            _ = await previous?.value
            guard let self, self.accepts(token) else { return false }
            return await self.resize(size)
        }
        terminalResizeTask = task
    }

    private func startEventMonitoring() {
        eventTask?.cancel()
        let eventsConnection = connection
        let token = callbackToken
        eventTask = Task { @MainActor [weak self] in
            do {
                let events = await eventsConnection.events()
                for try await event in events {
                    guard let self, self.accepts(token), !Task.isCancelled else { return }
                    switch event {
                    case .bytes(let data):
                        self.consume(data)
                    case .closed:
                        self.session.state = .disconnected
                        self.reconnectState = .idle
                        self.redactor = Redactor()
                        self.detachCallbacks()
                    case .error:
                        self.session.state = .failed
                        self.reconnectState = .failed(reason: "Connection failed.")
                        self.redactor = Redactor()
                        self.detachCallbacks()
                    }
                }
            } catch {
                guard let self, self.accepts(token), !Task.isCancelled else { return }
                self.session.state = .failed
                self.reconnectState = .failed(reason: "Connection failed.")
                self.redactor = Redactor()
                self.detachCallbacks()
            }
        }
    }

    private func consume(_ data: Data) {
        let redacted = Data(redactor.redact(String(decoding: data, as: UTF8.self)).utf8)
        terminalText += String(decoding: redacted, as: UTF8.self)
        ansiParser.consume(redacted, into: &terminalGrid)
        terminalController.feed(redacted)
    }

    private func invalidateCallbacks() {
        callbackGeneration &+= 1
        eventTask?.cancel()
        eventTask = nil
        outboundTask?.cancel()
        outboundTask = nil
        terminalResizeTask?.cancel()
        terminalResizeTask = nil
        terminalController.onOutput = nil
        terminalController.onResize = nil
    }

    private func detachCallbacks() {
        outboundTask?.cancel()
        outboundTask = nil
        terminalResizeTask?.cancel()
        terminalResizeTask = nil
        terminalController.onOutput = nil
        terminalController.onResize = nil
    }
}
