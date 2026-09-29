import Foundation
import ShhCore

public actor MoshConnection: MoshSessionControlling, SSHConnection {
    public private(set) var sessionInfo: MoshSessionInfo
    public private(set) var moshState: MoshState
    public private(set) var roamingState: NetworkRoamingState
    public let options: MoshOptions
    public let remoteHostname: String

    private let channel: any MoshDatagramChannel
    private var eventContinuation: AsyncThrowingStream<TerminalEvent, Error>.Continuation?
    private var pendingEvents: [TerminalEvent] = []
    private var stateContinuations: [UUID: AsyncStream<MoshState>.Continuation] = [:]
    private static let teardownTimeoutNanoseconds: UInt64 = 1_000_000_000
    private var receiveTask: Task<Void, Never>?
    private var closeTask: Task<Void, Never>?
    private var activeDatagramOperations = 0
    private var sequenceNumber: UInt64 = 0
    private(set) var isClosed: Bool = false
    private(set) var didQuarantine = false
    private var terminalError: TransportError?

    public init(
        sessionInfo: MoshSessionInfo,
        options: MoshOptions = MoshOptions(),
        remoteHostname: String,
        channel: any MoshDatagramChannel,
        initialRoamingState: NetworkRoamingState = NetworkRoamingState()
    ) {
        self.sessionInfo = sessionInfo
        self.options = options
        self.remoteHostname = remoteHostname
        self.channel = channel
        self.moshState = .connected
        self.roamingState = initialRoamingState
    }

    public func start() async throws {
        try await channel.start()
        guard !isClosed else { return }
        startReceiveLoop()
        transitionState(to: .connected)
    }

    public func events() async -> AsyncThrowingStream<TerminalEvent, Error> {
        AsyncThrowingStream { continuation in
            if self.isClosed {
                if let terminalError = self.terminalError {
                    continuation.yield(.error(terminalError))
                    continuation.finish(throwing: terminalError)
                } else {
                    continuation.yield(.closed)
                    continuation.finish()
                }
                return
            }

            self.eventContinuation = continuation
            for event in self.pendingEvents {
                continuation.yield(event)
            }
            self.pendingEvents.removeAll()
            continuation.onTermination = { @Sendable [weak self] _ in
                Task { [weak self] in
                    await self?.close()
                }
            }
        }
    }

    public func moshStateUpdates() async -> AsyncStream<MoshState> {
        AsyncStream { continuation in
            let id = UUID()
            self.stateContinuations[id] = continuation
            continuation.yield(self.moshState)
            continuation.onTermination = { @Sendable [weak self] _ in
                Task { [weak self] in
                    await self?.removeStateContinuation(id)
                }
            }
        }
    }

    private func removeStateContinuation(_ id: UUID) {
        stateContinuations.removeValue(forKey: id)
    }

    private func transitionState(to newState: MoshState) {
        self.moshState = newState
        for continuation in stateContinuations.values {
            continuation.yield(newState)
        }
    }

    public func send(_ data: Data) async throws {
        try beginDatagramOperation()
        defer { finishDatagramOperation() }
        sequenceNumber &+= 1
        let datagram = MoshDatagram(
            kind: .data,
            sequenceNumber: sequenceNumber,
            payload: data
        )
        try await channel.send(datagram: datagram.encode())
    }

    public func resize(_ size: TerminalSize) async throws {
        try beginDatagramOperation()
        defer { finishDatagramOperation() }
        sequenceNumber &+= 1
        var payload = Data()
        var cols = UInt16(size.columns).bigEndian
        var rows = UInt16(size.rows).bigEndian
        withUnsafeBytes(of: &cols) { payload.append(contentsOf: $0) }
        withUnsafeBytes(of: &rows) { payload.append(contentsOf: $0) }

        let datagram = MoshDatagram(
            kind: .resize,
            sequenceNumber: sequenceNumber,
            payload: payload
        )
        try await channel.send(datagram: datagram.encode())
    }

    public func handleNetworkRoaming(_ newState: NetworkRoamingState) async throws {
        guard !isClosed else { return }
        try beginDatagramOperation()
        defer { finishDatagramOperation() }

        // Transition to roaming state
        transitionState(to: .roaming(newState))
        self.roamingState = newState

        // If remote address or port changed, update channel endpoint
        if let newAddress = newState.remoteAddress, !newAddress.isEmpty {
            guard newAddress == remoteHostname else {
                throw TransportError.invalidConfiguration
            }
            let port = newState.remotePort ?? sessionInfo.udpPort
            try await channel.updateEndpoint(host: newAddress, port: port)
        }

        // Send roaming probe to announce client's new socket endpoint to mosh-server
        sequenceNumber &+= 1
        let probe = MoshDatagram(
            kind: .roamingProbe,
            sequenceNumber: sequenceNumber,
            payload: Data("ROAM".utf8)
        )
        try await channel.send(datagram: probe.encode())

        // Roaming transition successfully complete, back to connected
        guard !isClosed else { throw TransportError.networkUnavailable }
        transitionState(to: .connected)
    }

    public func close() async {
        await close(with: nil)
    }

    private func close(with terminalError: TransportError?) async {
        if let closeTask {
            await closeTask.value
            return
        }

        isClosed = true
        self.terminalError = terminalError
        let receiveTask = self.receiveTask
        self.receiveTask = nil
        receiveTask?.cancel()
        transitionState(
            to: .disconnected(reason: terminalError?.localizedDescription ?? "Session closed")
        )
        for continuation in stateContinuations.values {
            continuation.finish()
        }
        stateContinuations.removeAll()
        finishEventStream(with: terminalError)

        let task: Task<Void, Never> = Task { [weak self] in
            guard let self else { return }
            await self.finishClose(receiveTask: receiveTask)
        }
        closeTask = task
        await task.value
    }

    private func finishClose(receiveTask: Task<Void, Never>?) async {
        let deadline = teardownDeadline()
        let datagramsDrained = await waitForDatagramDrain(until: deadline)
        if !datagramsDrained {
            didQuarantine = true
        }

        if datagramsDrained && deadline > DispatchTime.now().uptimeNanoseconds {
            sequenceNumber &+= 1
            let teardown = MoshDatagram(kind: .teardown, sequenceNumber: sequenceNumber)
            let teardownTask = Task<Void, Never> { [channel] in
                try? await channel.send(datagram: teardown.encode())
            }
            if !(await waitForCompletion(teardownTask, until: deadline)) {
                didQuarantine = true
            }
        }

        let channelCloseTask = Task<Void, Never> { [channel] in
            await channel.close()
        }
        if !(await waitForCompletion(channelCloseTask, until: deadline)) {
            didQuarantine = true
            await Task.yield()
        }
        let receiveDrained = await waitForCompletion(receiveTask, until: deadline)
        if !receiveDrained, receiveTask != nil {
            didQuarantine = true
        }

        // Zero and redact the key from memory on teardown!
        sessionInfo.zeroize()
    }

    private func beginDatagramOperation() throws {
        guard !isClosed else {
            throw TransportError.networkUnavailable
        }
        activeDatagramOperations += 1
    }

    private func finishDatagramOperation() {
        activeDatagramOperations = max(0, activeDatagramOperations - 1)
    }

    private func waitForDatagramDrain(until deadline: UInt64) async -> Bool {
        while activeDatagramOperations > 0 {
            let now = DispatchTime.now().uptimeNanoseconds
            guard deadline > now else { return false }
            try? await Task.sleep(nanoseconds: min(deadline - now, 1_000_000))
        }
        return true
    }

    private func finishEventStream(with error: TransportError?) {
        if let error {
            eventContinuation?.yield(.error(error))
            eventContinuation?.finish(throwing: error)
        } else {
            eventContinuation?.yield(.closed)
            eventContinuation?.finish()
        }
        eventContinuation = nil
        pendingEvents.removeAll()
    }

    private func teardownDeadline() -> UInt64 {
        DispatchTime.now().uptimeNanoseconds &+ Self.teardownTimeoutNanoseconds
    }

    private func waitForCompletion(
        _ task: Task<Void, Never>?,
        until deadline: UInt64
    ) async -> Bool {
        guard let task else { return true }
        let now = DispatchTime.now().uptimeNanoseconds
        guard deadline > now else { return false }
        let signal = AsyncStream<Bool> { continuation in
            Task {
                await task.value
                continuation.yield(true)
                continuation.finish()
            }
            Task {
                try? await Task.sleep(nanoseconds: deadline - now)
                continuation.yield(false)
                continuation.finish()
            }
        }
        var iterator = signal.makeAsyncIterator()
        return await iterator.next() ?? false
    }

    public func testResponsiveness(timeout: TimeInterval = 3.0) async -> Bool {
        return !isClosed && moshState == .connected
    }

    private func startReceiveLoop() {
        receiveTask?.cancel()
        receiveTask = Task { [weak self] in
            guard let self else { return }
            let datagramStream = self.channel.incomingDatagrams()
            do {
                for try await data in datagramStream {
                    guard !Task.isCancelled else { break }
                    await self.handleInboundDatagram(data)
                }
            } catch {
                if !Task.isCancelled {
                    await self.handleChannelError(error)
                }
            }
        }
    }

    private func handleInboundDatagram(_ data: Data) {
        guard !isClosed else { return }
        if let packet = MoshDatagram.decode(from: data) {
            switch packet.kind {
            case .data:
                if !packet.payload.isEmpty {
                    if let eventContinuation {
                        eventContinuation.yield(.bytes(packet.payload))
                    } else {
                        pendingEvents.append(.bytes(packet.payload))
                    }
                }
            case .keepalive, .roamingProbe, .resize:
                break
            case .teardown:
                Task { [weak self] in
                    await self?.close()
                }
            }
        }
    }

    private func handleChannelError(_ error: Error) async {
        guard !isClosed else { return }
        await close(with: .networkUnavailable)
    }
}

public typealias LiveMoshConnection = MoshConnection
