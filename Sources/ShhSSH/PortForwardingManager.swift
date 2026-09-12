import Foundation
import NIOCore
import NIOPosix
@preconcurrency import NIOSSH
import ShhCore

public actor PortForwardingManager: PortForwardingManaging, ForwardingService {
    private let connection: LiveSSHConnection
    private let group: EventLoopGroup
    private let ownsGroup: Bool
    private var sessions: [UUID: ForwardingSessionState] = [:]
    private var trafficCounters: [UUID: ForwardingTrafficCounter] = [:]
    private var listenerChannels: [UUID: Channel] = [:]
    private var activeBridgedChannels: [UUID: [Channel]] = [:]
    private var remoteRulesByListeningPort: [Int: PortForwardingRule] = [:]
    private var streamContinuations: [UUID: AsyncStream<[ForwardingSessionState]>.Continuation] = [:]
    private var isRemoteHandlerRegistered = false

    public init(connection: LiveSSHConnection, group: EventLoopGroup? = nil) {
        self.connection = connection
        if let group {
            self.group = group
            self.ownsGroup = false
        } else {
            self.group = connection.group
            self.ownsGroup = false
        }
    }

    public func startForwarding(rule: PortForwardingRule) async throws -> ForwardingSessionState {
        if let existing = sessions[rule.id], existing.status == .active {
            return existing
        }

        let counter = ForwardingTrafficCounter { [weak self] in
            Task { [weak self] in
                await self?.broadcast()
            }
        }
        trafficCounters[rule.id] = counter

        var sessionState = ForwardingSessionState(
            ruleID: rule.id,
            rule: rule,
            status: .starting,
            startedAt: Date()
        )
        sessions[rule.id] = sessionState
        broadcast()

        do {
            switch rule.type {
            case .local:
                guard let remoteHost = rule.remoteHost, !remoteHost.isEmpty,
                      let remotePort = rule.remotePort, remotePort > 0 else {
                    throw ShhValidationError.invalidDestination
                }

                let bootstrap = ServerBootstrap(group: group)
                    .serverChannelOption(ChannelOptions.socketOption(.so_reuseaddr), value: 1)
                    .childChannelInitializer { [weak self, connection, counter, rule] clientChannel in
                        let promise = clientChannel.eventLoop.makePromise(of: Void.self)
                        Task { [weak self] in
                            var openedSSHChannel: Channel? = nil
                            do {
                                let sshChannel = try await connection.createDirectTCPIPChannel(
                                    targetHost: remoteHost,
                                    targetPort: Int(remotePort),
                                    originatorAddress: clientChannel.remoteAddress
                                )
                                openedSSHChannel = sshChannel
                                await self?.registerBridgedChannel(ruleID: rule.id, channel: clientChannel)
                                await self?.registerBridgedChannel(ruleID: rule.id, channel: sshChannel)

                                let (glueClient, glueSSH) = GlueHandler.matchedPair()
                                let clientTraffic = TrafficCounterHandler(counter: counter, isClientSide: true)
                                let sshTraffic = TrafficCounterHandler(counter: counter, isClientSide: false)

                                _ = try await clientChannel.pipeline.addHandlers([clientTraffic, glueClient]).get()
                                _ = try await sshChannel.pipeline.addHandlers([sshTraffic, glueSSH]).get()
                                promise.succeed(())
                            } catch {
                                _ = try? await openedSSHChannel?.close()
                                _ = try? await clientChannel.close()
                                promise.succeed(())
                            }
                        }
                        return promise.futureResult
                    }

                let boundChannel = try await bootstrap.bind(host: rule.localHost, port: Int(rule.localPort)).get()
                listenerChannels[rule.id] = boundChannel

                let boundPort = UInt16(boundChannel.localAddress?.port ?? Int(rule.localPort))
                sessionState.status = .active
                sessionState.boundPort = boundPort
                sessions[rule.id] = sessionState
                broadcast()
                return sessionState

            case .dynamic:
                let bootstrap = ServerBootstrap(group: group)
                    .serverChannelOption(ChannelOptions.socketOption(.so_reuseaddr), value: 1)
                    .childChannelInitializer { [weak self, connection, counter, rule] clientChannel in
                        let handler = SOCKS5ServerHandler(
                            connection: connection,
                            counter: counter,
                            onChannelOpened: { [weak self] sshChannel in
                                Task { [weak self] in
                                    await self?.registerBridgedChannel(ruleID: rule.id, channel: clientChannel)
                                    await self?.registerBridgedChannel(ruleID: rule.id, channel: sshChannel)
                                }
                            }
                        )
                        return clientChannel.pipeline.addHandler(handler)
                    }

                let boundChannel = try await bootstrap.bind(host: rule.localHost, port: Int(rule.localPort)).get()
                listenerChannels[rule.id] = boundChannel

                let boundPort = UInt16(boundChannel.localAddress?.port ?? Int(rule.localPort))
                sessionState.status = .active
                sessionState.boundPort = boundPort
                sessions[rule.id] = sessionState
                broadcast()
                return sessionState

            case .remote:
                let listenHost = rule.remoteHost ?? "127.0.0.1"
                let listenPort = Int(rule.remotePort ?? 0)

                let boundPortInt = try await connection.requestRemoteForwarding(
                    bindHost: listenHost,
                    bindPort: listenPort
                )
                let effectivePort = boundPortInt != nil ? UInt16(boundPortInt!) : (rule.remotePort ?? 0)
                remoteRulesByListeningPort[Int(effectivePort)] = rule

                if !isRemoteHandlerRegistered {
                    isRemoteHandlerRegistered = true
                    connection.registerForwardedTCPIPHandler { [weak self] forwardedChannel, forwarded in
                        guard let self else { return forwardedChannel.close() }
                        return forwardedChannel.eventLoop.flatSubmit {
                            let promise = forwardedChannel.eventLoop.makePromise(of: Void.self)
                            Task {
                                await self.handleInboundForwarded(
                                    channel: forwardedChannel,
                                    forwarded: forwarded,
                                    promise: promise
                                )
                            }
                            return promise.futureResult
                        }
                    }
                }

                sessionState.status = .active
                sessionState.boundPort = effectivePort
                sessions[rule.id] = sessionState
                broadcast()
                return sessionState
            }
        } catch {
            sessionState.status = .failed(reason: error.localizedDescription)
            sessionState.errorDescription = error.localizedDescription
            sessions[rule.id] = sessionState
            broadcast()
            throw error
        }
    }

    public func stopForwarding(ruleID: UUID) async throws {
        guard var state = sessions[ruleID] else { return }

        if let listener = listenerChannels.removeValue(forKey: ruleID) {
            _ = try? await listener.close().get()
        }

        if let channels = activeBridgedChannels.removeValue(forKey: ruleID) {
            for channel in channels {
                _ = try? await channel.close().get()
            }
        }

        if state.rule.type == .remote {
            let listenHost = state.rule.remoteHost ?? "127.0.0.1"
            let port = Int(state.boundPort ?? state.rule.remotePort ?? 0)
            remoteRulesByListeningPort.removeValue(forKey: port)
            _ = try? await connection.cancelRemoteForwarding(bindHost: listenHost, bindPort: port)
        }

        state.status = .stopped
        state.activeConnectionsCount = 0
        sessions[ruleID] = state
        broadcast()
    }

    public func stopAll() async {
        let ruleIDs = Array(sessions.keys)
        for id in ruleIDs {
            try? await stopForwarding(ruleID: id)
        }
    }

    public func activeSessions() async -> [ForwardingSessionState] {
        refreshSnapshots()
        return Array(sessions.values.filter { $0.status == .active || $0.status == .starting })
    }

    public func sessionState(for ruleID: UUID) async -> ForwardingSessionState? {
        refreshSnapshot(for: ruleID)
        return sessions[ruleID]
    }

    public func sessionStatesStream() async -> AsyncStream<[ForwardingSessionState]> {
        let id = UUID()
        return AsyncStream { continuation in
            self.streamContinuations[id] = continuation
            self.refreshSnapshots()
            continuation.yield(Array(self.sessions.values))
            continuation.onTermination = { [weak self] _ in
                Task { [weak self] in
                    await self?.removeContinuation(id: id)
                }
            }
        }
    }

    // ForwardingService conformance
    public func start(_ rule: ForwardingRule, for host: ShhCore.Host) async throws {
        let pfRule = PortForwardingRule(from: rule)
        _ = try await startForwarding(rule: pfRule)
    }

    public func stop(_ rule: ForwardingRule) async {
        try? await stopForwarding(ruleID: rule.id)
    }

    // Internal helpers
    func registerBridgedChannel(ruleID: UUID, channel: Channel) {
        if activeBridgedChannels[ruleID] == nil {
            activeBridgedChannels[ruleID] = []
        }
        activeBridgedChannels[ruleID]?.append(channel)
        channel.closeFuture.whenComplete { [weak self] _ in
            Task { [weak self] in
                await self?.removeBridgedChannel(ruleID: ruleID, channel: channel)
            }
        }
    }

    private func removeBridgedChannel(ruleID: UUID, channel: Channel) {
        activeBridgedChannels[ruleID]?.removeAll(where: { $0 === channel })
    }

    private func handleInboundForwarded(
        channel: Channel,
        forwarded: SSHChannelType.ForwardedTCPIP,
        promise: EventLoopPromise<Void>
    ) async {
        guard let rule = remoteRulesByListeningPort[forwarded.listeningPort],
              let counter = trafficCounters[rule.id] else {
            _ = try? await channel.close()
            promise.succeed(())
            return
        }

        var connectedLocalChannel: Channel? = nil
        do {
            let bootstrap = ClientBootstrap(group: group)
            let localChannel = try await bootstrap.connect(host: rule.localHost, port: Int(rule.localPort)).get()
            connectedLocalChannel = localChannel

            registerBridgedChannel(ruleID: rule.id, channel: localChannel)
            registerBridgedChannel(ruleID: rule.id, channel: channel)

            let (glueLocal, glueSSH) = GlueHandler.matchedPair()
            let localTraffic = TrafficCounterHandler(counter: counter, isClientSide: true)
            let sshTraffic = TrafficCounterHandler(counter: counter, isClientSide: false)

            _ = try await localChannel.pipeline.addHandlers([localTraffic, glueLocal]).get()
            _ = try await channel.pipeline.addHandlers([DataToBufferCodec(), sshTraffic, glueSSH]).get()
            promise.succeed(())
        } catch {
            _ = try? await connectedLocalChannel?.close()
            _ = try? await channel.close()
            promise.succeed(())
        }
    }

    private func refreshSnapshot(for ruleID: UUID) {
        guard var state = sessions[ruleID], let counter = trafficCounters[ruleID] else { return }
        let snap = counter.snapshot()
        state.bytesSent = snap.sent
        state.bytesReceived = snap.received
        state.activeConnectionsCount = snap.activeConnections
        state.lastActivityAt = snap.lastActivity
        sessions[ruleID] = state
    }

    private func refreshSnapshots() {
        for ruleID in sessions.keys {
            refreshSnapshot(for: ruleID)
        }
    }

    private func broadcast() {
        refreshSnapshots()
        let current = Array(sessions.values)
        for cont in streamContinuations.values {
            cont.yield(current)
        }
    }

    private func removeContinuation(id: UUID) {
        streamContinuations.removeValue(forKey: id)
    }

    deinit {
        let listeners = Array(listenerChannels.values)
        for listener in listeners {
            listener.close(promise: nil)
        }
    }
}
