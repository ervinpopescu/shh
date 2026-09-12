import Foundation

// MARK: - Mosh Port Range

public struct MoshPortRange: Codable, Hashable, Sendable, CustomStringConvertible {
    public var start: UInt16
    public var end: UInt16

    public init(start: UInt16, end: UInt16) {
        if start <= end {
            self.start = start
            self.end = end
        } else {
            self.start = end
            self.end = start
        }
    }

    public init(_ range: ClosedRange<UInt16>) {
        self.start = range.lowerBound
        self.end = range.upperBound
    }

    public init(port: UInt16) {
        self.start = port
        self.end = port
    }

    public var isSinglePort: Bool {
        start == end
    }

    public var range: ClosedRange<UInt16> {
        start...end
    }

    public var description: String {
        isSinglePort ? "\(start)" : "\(start):\(end)"
    }

    public static let standard = MoshPortRange(start: 60001, end: 60999)
}

// MARK: - Mosh Prediction Mode

public enum MoshPredictionMode: String, Codable, CaseIterable, Sendable {
    case adaptive
    case always
    case never
    case experimental

    public var flagValue: String {
        rawValue
    }
}

// MARK: - Mosh Options

public struct MoshOptions: Codable, Hashable, Sendable {
    public var serverCommand: String
    public var portRange: MoshPortRange?
    public var predictionMode: MoshPredictionMode
    public var sshOptions: SSHOptions

    public init(
        serverCommand: String = "mosh-server",
        portRange: MoshPortRange? = nil,
        predictionMode: MoshPredictionMode = .adaptive,
        sshOptions: SSHOptions = SSHOptions()
    ) {
        self.serverCommand = serverCommand
        self.portRange = portRange
        self.predictionMode = predictionMode
        self.sshOptions = sshOptions
    }

    enum CodingKeys: String, CodingKey {
        case serverCommand, portRange, predictionMode, sshOptions
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.serverCommand = try container.decodeIfPresent(String.self, forKey: .serverCommand) ?? "mosh-server"
        self.portRange = try container.decodeIfPresent(MoshPortRange.self, forKey: .portRange)
        self.predictionMode = try container.decodeIfPresent(MoshPredictionMode.self, forKey: .predictionMode) ?? .adaptive
        self.sshOptions = try container.decodeIfPresent(SSHOptions.self, forKey: .sshOptions) ?? SSHOptions()
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(serverCommand, forKey: .serverCommand)
        try container.encodeIfPresent(portRange, forKey: .portRange)
        try container.encode(predictionMode, forKey: .predictionMode)
        try container.encode(sshOptions, forKey: .sshOptions)
    }
}

// MARK: - Mosh Session Key

public final class MoshSessionKey: @unchecked Sendable, CustomStringConvertible, CustomDebugStringConvertible {
    private var storage: [UInt8]
    private var _isZeroized: Bool = false
    private let lock = NSLock()

    public init(base64: String) {
        let trimmed = base64.trimmingCharacters(in: .whitespacesAndNewlines)
        self.storage = Array(trimmed.utf8)
    }

    public init(bytes: [UInt8]) {
        self.storage = bytes
    }

    public var isZeroized: Bool {
        lock.withLock { _isZeroized }
    }

    public var base64String: String {
        lock.withLock {
            guard !_isZeroized else { return "" }
            return String(decoding: storage, as: UTF8.self)
        }
    }

    public var rawBytes: [UInt8] {
        lock.withLock {
            guard !_isZeroized else { return [] }
            return storage
        }
    }

    public func zeroize() {
        lock.withLock {
            guard !_isZeroized else { return }
            for i in 0..<storage.count {
                storage[i] = 0
            }
            storage.removeAll()
            _isZeroized = true
        }
    }

    deinit {
        zeroize()
    }

    public var description: String {
        "[REDACTED]"
    }

    public var debugDescription: String {
        "[REDACTED]"
    }
}

extension MoshSessionKey: Equatable {
    public static func == (lhs: MoshSessionKey, rhs: MoshSessionKey) -> Bool {
        lhs.base64String == rhs.base64String
    }
}

extension MoshSessionKey: Hashable {
    public func hash(into hasher: inout Hasher) {
        hasher.combine(base64String)
    }
}

// MARK: - Mosh Session Info

public struct MoshSessionInfo: Sendable, Equatable, CustomStringConvertible, CustomDebugStringConvertible {
    public var udpPort: UInt16
    public var sessionKey: MoshSessionKey
    public var pid: Int?

    public init(udpPort: UInt16, sessionKey: MoshSessionKey, pid: Int? = nil) {
        self.udpPort = udpPort
        self.sessionKey = sessionKey
        self.pid = pid
    }

    public init(udpPort: UInt16, sessionKey: String, pid: Int? = nil) {
        self.udpPort = udpPort
        self.sessionKey = MoshSessionKey(base64: sessionKey)
        self.pid = pid
    }

    public mutating func zeroize() {
        sessionKey.zeroize()
    }

    public var description: String {
        "MoshSessionInfo(udpPort: \(udpPort), sessionKey: \(sessionKey.description), pid: \(String(describing: pid)))"
    }

    public var debugDescription: String {
        "MoshSessionInfo(udpPort: \(udpPort), sessionKey: \(sessionKey.debugDescription), pid: \(String(describing: pid)))"
    }
}

// MARK: - Network Roaming State

public enum NetworkInterfaceType: String, Codable, Hashable, Sendable, CaseIterable {
    case wifi
    case cellular
    case wired
    case loopback
    case other
    case unknown

    public var displayName: String {
        switch self {
        case .wifi: return "Wi-Fi"
        case .cellular: return "Cellular"
        case .wired: return "Wired Ethernet"
        case .loopback: return "Loopback"
        case .other: return "Other"
        case .unknown: return "Unknown"
        }
    }
}

public struct NetworkRoamingState: Codable, Hashable, Sendable, Equatable {
    public var previousInterface: NetworkInterfaceType?
    public var currentInterface: NetworkInterfaceType
    public var isExpensive: Bool
    public var isConstrained: Bool
    public var remoteAddress: String?
    public var remotePort: UInt16?
    public var timestamp: Date

    public init(
        previousInterface: NetworkInterfaceType? = nil,
        currentInterface: NetworkInterfaceType = .unknown,
        isExpensive: Bool = false,
        isConstrained: Bool = false,
        remoteAddress: String? = nil,
        remotePort: UInt16? = nil,
        timestamp: Date = Date()
    ) {
        self.previousInterface = previousInterface
        self.currentInterface = currentInterface
        self.isExpensive = isExpensive
        self.isConstrained = isConstrained
        self.remoteAddress = remoteAddress
        self.remotePort = remotePort
        self.timestamp = timestamp
    }

    public var hasInterfaceChanged: Bool {
        guard let previousInterface else { return false }
        return previousInterface != currentInterface
    }

    public func transitioning(
        to newInterface: NetworkInterfaceType,
        isExpensive: Bool? = nil,
        isConstrained: Bool? = nil,
        remoteAddress: String? = nil,
        remotePort: UInt16? = nil,
        timestamp: Date = Date()
    ) -> NetworkRoamingState {
        NetworkRoamingState(
            previousInterface: self.currentInterface,
            currentInterface: newInterface,
            isExpensive: isExpensive ?? self.isExpensive,
            isConstrained: isConstrained ?? self.isConstrained,
            remoteAddress: remoteAddress ?? self.remoteAddress,
            remotePort: remotePort ?? self.remotePort,
            timestamp: timestamp
        )
    }
}

// MARK: - Mosh State

public enum MoshState: Equatable, Sendable {
    case bootstrapping
    case connected
    case roaming(NetworkRoamingState)
    case disconnected(reason: String?)

    public static var roaming: MoshState {
        .roaming(NetworkRoamingState())
    }

    public static var disconnected: MoshState {
        .disconnected(reason: nil)
    }

    public var isBootstrapping: Bool {
        if case .bootstrapping = self { return true }
        return false
    }

    public var isConnected: Bool {
        if case .connected = self { return true }
        return false
    }

    public var isRoaming: Bool {
        if case .roaming = self { return true }
        return false
    }

    public var isDisconnected: Bool {
        if case .disconnected = self { return true }
        return false
    }

    public var roamingState: NetworkRoamingState? {
        if case .roaming(let state) = self { return state }
        return nil
    }

    public var disconnectReason: String? {
        if case .disconnected(let reason) = self { return reason }
        return nil
    }
}

// MARK: - Mosh Protocols

public protocol MoshSessionControlling: SSHConnection, Sendable {
    var sessionInfo: MoshSessionInfo { get async }
    var moshState: MoshState { get async }
    var roamingState: NetworkRoamingState { get async }
    func moshStateUpdates() async -> AsyncStream<MoshState>
    func handleNetworkRoaming(_ newState: NetworkRoamingState) async throws
}

public protocol MoshTransport: Sendable {
    func connect(
        host: Host,
        identity: IdentityDescriptor?,
        trustEvaluator: any HostTrustEvaluator,
        initialSize: TerminalSize
    ) async throws -> any SSHConnection
}

public extension MoshTransport {
    func connect(
        host: Host,
        identity: IdentityDescriptor?,
        trustEvaluator: any HostTrustEvaluator,
        initialSize: TerminalSize = TerminalSize(columns: 80, rows: 24)
    ) async throws -> any SSHConnection {
        try await connect(host: host, identity: identity, trustEvaluator: trustEvaluator, initialSize: initialSize)
    }
}

// MARK: - Demo Mosh Connection

public actor DemoMoshConnection: MoshSessionControlling, SSHConnection {
    public private(set) var sessionInfo: MoshSessionInfo
    public private(set) var moshState: MoshState
    public private(set) var roamingState: NetworkRoamingState
    public let options: MoshOptions
    public let remoteHostname: String

    private var eventContinuation: AsyncThrowingStream<TerminalEvent, Error>.Continuation?
    private var stateContinuations: [UUID: AsyncStream<MoshState>.Continuation] = [:]
    private var isClosed: Bool = false

    public init(
        sessionInfo: MoshSessionInfo,
        options: MoshOptions = MoshOptions(),
        remoteHostname: String = "demo.shh.local",
        initialRoamingState: NetworkRoamingState = NetworkRoamingState(currentInterface: .wifi)
    ) {
        self.sessionInfo = sessionInfo
        self.options = options
        self.remoteHostname = remoteHostname
        self.moshState = .connected
        self.roamingState = initialRoamingState
    }

    public func start() {
        transitionState(to: .connected)
    }

    public func events() async -> AsyncThrowingStream<TerminalEvent, Error> {
        AsyncThrowingStream { continuation in
            self.eventContinuation = continuation
            continuation.yield(.bytes(Data("[mosh connected to demo server: UDP port \(self.sessionInfo.udpPort)]\r\n$ ".utf8)))
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
        guard !isClosed else { throw TransportError.networkUnavailable }
        if let string = String(data: data, encoding: .utf8) {
            if string == "\r" {
                eventContinuation?.yield(.bytes(Data("\r\n$ ".utf8)))
            } else {
                eventContinuation?.yield(.bytes(data))
            }
        } else {
            eventContinuation?.yield(.bytes(data))
        }
    }

    public func resize(_ size: TerminalSize) async throws {
        guard !isClosed else { throw TransportError.networkUnavailable }
    }

    public func handleNetworkRoaming(_ newState: NetworkRoamingState) async throws {
        guard !isClosed else { return }
        transitionState(to: .roaming(newState))
        self.roamingState = newState
        let notice = "\r\n[mosh: roaming to \(newState.currentInterface.displayName)]\r\n$ "
        eventContinuation?.yield(.bytes(Data(notice.utf8)))
        transitionState(to: .connected)
    }

    public func close() async {
        guard !isClosed else { return }
        isClosed = true
        sessionInfo.zeroize()
        transitionState(to: .disconnected(reason: "Closed"))
        for continuation in stateContinuations.values {
            continuation.finish()
        }
        stateContinuations.removeAll()
        eventContinuation?.yield(.closed)
        eventContinuation?.finish()
        eventContinuation = nil
    }
}

// MARK: - Demo Mosh Transport

public struct DemoMoshTransport: MoshTransport, SSHTransport {
    public init() {}

    public func connect(
        host: Host,
        identity: IdentityDescriptor?,
        trustEvaluator: any HostTrustEvaluator,
        initialSize: TerminalSize = TerminalSize(columns: 80, rows: 24)
    ) async throws -> any SSHConnection {
        let challenge = HostKeyChallenge(
            hostname: host.hostname,
            port: host.port,
            algorithm: "ssh-ed25519",
            fingerprint: "SHA256:demo-mosh-fingerprint"
        )
        guard await trustEvaluator.evaluate(challenge) != .reject else {
            throw TransportError.remoteFailure("Host key was rejected")
        }

        let moshOptions: MoshOptions
        if case .mosh(let opts) = host.connection {
            moshOptions = opts
        } else {
            moshOptions = MoshOptions()
        }

        let sessionInfo = MoshSessionInfo(
            udpPort: moshOptions.portRange?.start ?? 60001,
            sessionKey: "demo-mosh-session-key-42a12B4C",
            pid: 42000
        )

        let connection = DemoMoshConnection(
            sessionInfo: sessionInfo,
            options: moshOptions,
            remoteHostname: host.hostname
        )
        await connection.start()
        return connection
    }
}
