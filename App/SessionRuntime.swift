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
        let transportGeneration: UInt64
    }

    private struct PendingTasks {
        let event: Task<Void, Never>?
        let outbound: Task<Bool, Never>?
        let resize: Task<Bool, Never>?
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
    private(set) var outboundTask: Task<Bool, Never>?
    private(set) var terminalResizeTask: Task<Bool, Never>?

    private var callbackGeneration: UInt64 = 0
    private var transportGeneration: UInt64 = 0
    private var eventReadyWaiters: [CheckedContinuation<Void, Never>] = []
    /// Marks a transport before invoking close so timeout paths cannot invoke
    /// a second close on the same object during later teardown attempts.
    private var closeStartedConnectionIdentity: ObjectIdentifier?

    private static let teardownTimeoutNanoseconds: UInt64 = 250_000_000

    /// Receives already-redacted terminal bytes after this runtime feeds the
    /// shared terminal controller. AppContainer uses this projection to retain
    /// its legacy terminal text API without owning the event stream.
    var onOutput: (@MainActor (Data) -> Void)?

    /// Receives successful terminal resize projections for legacy app state.
    var onResize: (@MainActor (TerminalSize) -> Void)?

    /// Receives terminal termination after the runtime has invalidated callbacks
    /// and closed the transport. The runtime remains the owner of the transport;
    /// the owner may use this hook to start recovery or update projections.
    var onTermination: (@MainActor (TerminalEvent?) async -> Void)?

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
        CallbackToken(
            sessionID: session.id,
            generation: callbackGeneration,
            transportGeneration: transportGeneration
        )
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

    /// Activates the runtime and waits until the transport event stream has
    /// been subscribed. This closes the admission race for callers that emit
    /// an event immediately after connect returns.
    func activateAndWait() async {
        activate()
        await withCheckedContinuation { continuation in
            eventReadyWaiters.append(continuation)
        }
    }

    /// Updates the session state projection for external lifecycle probes.
    func updateSessionState(_ state: TerminalSessionState) {
        session.state = state
    }

    /// Replaces only this session's transport. The session identity and terminal
    /// model remain stable, while the generation rejects callbacks from the old
    /// connection even if its event stream races cancellation.
    @discardableResult
    func reconnect(
        with replacement: any SSHConnection,
        redactor replacementRedactor: Redactor = Redactor()
    ) async -> Bool {
        let previous = connection
        let pending = invalidateCallbacks()
        transportGeneration &+= 1
        reconnectGeneration &+= 1
        reconnectState = .connecting(attempt: Int(reconnectGeneration))
        session.state = .connecting
        redactor = Redactor()

        let deadline = teardownDeadline()
        guard
            await closeAndAwaitQuiescence(
                previous,
                pending: pending,
                deadline: deadline
            )
        else {
            failTeardown()
            return false
        }

        connection = replacement
        redactor = replacementRedactor
        terminalGrid = TerminalGrid(size: session.terminalSize)
        ansiParser = ANSIParser()
        terminalText = ""
        terminalController.reset()
        session.state = .connected
        reconnectState = .connected
        installCallbacks()
        startEventMonitoring()
        return true
    }

    @discardableResult
    func send(_ data: Data) async -> Bool {
        guard session.state == .connected else { return false }
        let token = callbackToken
        let activeConnection = connection
        let previous = outboundTask
        let task = Task { @MainActor [weak self] in
            _ = await previous?.value
            guard let self, self.accepts(token) else { return false }
            do {
                try await activeConnection.send(data)
                return self.accepts(token)
            } catch {
                return false
            }
        }
        outboundTask = task
        return await task.value
    }

    @discardableResult
    func resize(_ size: TerminalSize) async -> Bool {
        guard session.state == .connected else { return false }
        return await queueResize(size, token: callbackToken).value
    }

    func disconnect() async {
        let activeConnection = connection
        let pending = invalidateCallbacks()
        session.state = .disconnected
        reconnectState = .idle
        redactor = Redactor()
        _ = await closeAndAwaitQuiescence(
            activeConnection,
            pending: pending,
            deadline: teardownDeadline()
        )
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
                _ = self.queueResize(size, token: token)
            }
        }
    }

    private func enqueue(_ data: Data, token: CallbackToken) {
        guard accepts(token) else { return }
        let previous = outboundTask
        let activeConnection = connection
        let task = Task { @MainActor [weak self] in
            _ = await previous?.value
            guard let self, self.accepts(token) else { return false }
            do {
                try await activeConnection.send(data)
                return self.accepts(token)
            } catch {
                return false
            }
        }
        outboundTask = task
    }

    private func queueResize(_ size: TerminalSize, token: CallbackToken) -> Task<Bool, Never> {
        let previous = terminalResizeTask
        let activeConnection = connection
        let task = Task { @MainActor [weak self] in
            _ = await previous?.value
            guard let self, self.accepts(token) else { return false }
            do {
                try await activeConnection.resize(size)
                guard self.accepts(token) else { return false }
                self.session.terminalSize = size
                self.terminalGrid.resize(size)
                self.onResize?(size)
                return true
            } catch {
                return false
            }
        }
        terminalResizeTask = task
        return task
    }

    private func startEventMonitoring() {
        eventTask?.cancel()
        let eventsConnection = connection
        let token = callbackToken
        eventTask = Task { @MainActor [weak self] in
            guard let self else { return }
            do {
                let events = await eventsConnection.events()
                let waiters = self.eventReadyWaiters
                self.eventReadyWaiters.removeAll()
                waiters.forEach { $0.resume() }
                for try await event in events {
                    guard self.accepts(token), !Task.isCancelled else { return }
                    switch event {
                    case .bytes(let data):
                        self.consume(data)
                    case .closed:
                        await self.terminate(
                            connection: eventsConnection,
                            token: token,
                            state: .disconnected,
                            reconnectState: .idle
                        )
                        await self.onTermination?(.closed)
                        return
                    case .error(let error):
                        await self.terminate(
                            connection: eventsConnection,
                            token: token,
                            state: .failed,
                            reconnectState: .failed(reason: "Connection failed.")
                        )
                        await self.onTermination?(.error(error))
                        return
                    }
                }
                guard self.accepts(token), !Task.isCancelled else { return }
                await self.terminate(
                    connection: eventsConnection,
                    token: token,
                    state: .disconnected,
                    reconnectState: .idle
                )
                await self.onTermination?(.closed)
            } catch {
                guard self.accepts(token), !Task.isCancelled else { return }
                await self.terminate(
                    connection: eventsConnection,
                    token: token,
                    state: .failed,
                    reconnectState: .failed(reason: "Connection failed.")
                )
                await self.onTermination?(nil)
            }
        }
    }

    private func terminate(
        connection: any SSHConnection,
        token: CallbackToken,
        state: TerminalSessionState,
        reconnectState: ReconnectState
    ) async {
        guard accepts(token) else { return }
        session.state = state
        self.reconnectState = reconnectState
        redactor = Redactor()
        let pending = invalidateCallbacks()
        _ = await closeAndAwaitQuiescence(
            connection,
            pending: PendingTasks(event: nil, outbound: pending.outbound, resize: pending.resize),
            deadline: teardownDeadline()
        )
        // The event task invokes this method and must not await itself.
    }

    private func consume(_ data: Data) {
        let redacted = Data(redactor.redact(String(decoding: data, as: UTF8.self)).utf8)
        terminalText += String(decoding: redacted, as: UTF8.self)
        ansiParser.consume(redacted, into: &terminalGrid)
        terminalController.feed(redacted)
        onOutput?(redacted)
    }

    private func invalidateCallbacks() -> PendingTasks {
        callbackGeneration &+= 1
        let pending = PendingTasks(
            event: eventTask,
            outbound: outboundTask,
            resize: terminalResizeTask
        )
        eventTask?.cancel()
        eventTask = nil
        eventReadyWaiters.forEach { $0.resume() }
        eventReadyWaiters.removeAll()
        outboundTask?.cancel()
        outboundTask = nil
        terminalResizeTask?.cancel()
        terminalResizeTask = nil
        terminalController.onOutput = nil
        terminalController.onResize = nil
        return pending
    }

    private func teardownDeadline() -> UInt64 {
        DispatchTime.now().uptimeNanoseconds &+ Self.teardownTimeoutNanoseconds
    }

    private func closeAndAwaitQuiescence(
        _ connection: any SSHConnection,
        pending: PendingTasks,
        deadline: UInt64
    ) async -> Bool {
        let connectionIdentity = ObjectIdentifier(connection as AnyObject)
        if closeStartedConnectionIdentity != connectionIdentity {
            // Record close ownership before awaiting. The close operation may
            // outlive the bounded wait when a transport is non-cooperative.
            closeStartedConnectionIdentity = connectionIdentity
            guard
                await waitForCompletion(
                    until: deadline,
                    operation: {
                        await connection.close()
                    })
            else {
                return false
            }
        }

        if let outbound = pending.outbound {
            guard
                await waitForCompletion(
                    until: deadline,
                    operation: {
                        _ = await outbound.value
                    })
            else {
                return false
            }
        }
        if let resize = pending.resize {
            guard
                await waitForCompletion(
                    until: deadline,
                    operation: {
                        _ = await resize.value
                    })
            else {
                return false
            }
        }
        if let event = pending.event {
            guard
                await waitForCompletion(
                    until: deadline,
                    operation: {
                        _ = await event.value
                    })
            else {
                return false
            }
        }
        return true
    }

    private func waitForCompletion(
        until deadline: UInt64,
        operation: @escaping @Sendable () async -> Void
    ) async -> Bool {
        let now = DispatchTime.now().uptimeNanoseconds
        guard deadline > now else { return false }
        let remaining = deadline - now

        let signal = AsyncStream<Bool> { continuation in
            Task {
                await operation()
                continuation.yield(true)
                continuation.finish()
            }
            Task {
                try? await Task.sleep(nanoseconds: remaining)
                continuation.yield(false)
                continuation.finish()
            }
        }
        var iterator = signal.makeAsyncIterator()
        return await iterator.next() ?? false
    }

    private func failTeardown() {
        session.state = .failed
        reconnectState = .failed(reason: "Connection shutdown timed out.")
        redactor = Redactor()
        terminalController.onOutput = nil
        terminalController.onResize = nil
    }
}
