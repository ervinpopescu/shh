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
    private var stateContinuations: [UUID: AsyncStream<MoshState>.Continuation] = [:]
    private var receiveTask: Task<Void, Never>?
    private var sequenceNumber: UInt64 = 0
    private var isClosed: Bool = false

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
        startReceiveLoop()
        transitionState(to: .connected)
    }

    public func events() async -> AsyncThrowingStream<TerminalEvent, Error> {
        AsyncThrowingStream { continuation in
            self.eventContinuation = continuation
            continuation.onTermination = { @Sendable _ in
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
            continuation.onTermination = { @Sendable _ in
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
        guard !isClosed else {
            throw TransportError.networkUnavailable
        }
        sequenceNumber &+= 1
        let datagram = MoshDatagram(
            kind: .data,
            sequenceNumber: sequenceNumber,
            payload: data
        )
        try await channel.send(datagram: datagram.encode())
    }

    public func resize(_ size: TerminalSize) async throws {
        guard !isClosed else {
            throw TransportError.networkUnavailable
        }
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

        // Transition to roaming state
        transitionState(to: .roaming(newState))
        self.roamingState = newState

        // If remote address or port changed, update channel endpoint
        if let newAddress = newState.remoteAddress, !newAddress.isEmpty {
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
        transitionState(to: .connected)
    }

    public func close() async {
        guard !isClosed else { return }
        isClosed = true

        receiveTask?.cancel()
        receiveTask = nil

        // Attempt graceful teardown packet transmission
        sequenceNumber &+= 1
        let teardown = MoshDatagram(kind: .teardown, sequenceNumber: sequenceNumber)
        try? await channel.send(datagram: teardown.encode())

        await channel.close()

        // Zero and redact the key from memory on teardown!
        sessionInfo.zeroize()

        transitionState(to: .disconnected(reason: "Session closed"))
        for continuation in stateContinuations.values {
            continuation.finish()
        }
        stateContinuations.removeAll()

        eventContinuation?.yield(.closed)
        eventContinuation?.finish()
        eventContinuation = nil
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
                    eventContinuation?.yield(.bytes(packet.payload))
                }
            case .keepalive, .roamingProbe, .resize:
                break
            case .teardown:
                Task { [weak self] in
                    await self?.close()
                }
            }
        } else {
            eventContinuation?.yield(.bytes(data))
        }
    }

    private func handleChannelError(_ error: Error) {
        guard !isClosed else { return }
        transitionState(to: .disconnected(reason: error.localizedDescription))
        eventContinuation?.yield(.error(.networkUnavailable))
        Task { [weak self] in
            await self?.close()
        }
    }
}

public typealias LiveMoshConnection = MoshConnection
