import Foundation

public enum ShhValidationError: Error, Equatable, Sendable {
    case empty(field: String)
    case invalidPort
    case invalidHost
    case invalidBindAddress
    case invalidDestination
    case duplicateName
}

public struct Group: Identifiable, Codable, Hashable, Sendable {
    public let id: UUID
    public var name: String
    public var sortOrder: Int
    public init(id: UUID = UUID(), name: String, sortOrder: Int = 0) throws {
        guard !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw ShhValidationError.empty(field: "group name") }
        self.id = id; self.name = name; self.sortOrder = sortOrder
    }
}

public struct Tag: Identifiable, Codable, Hashable, Sendable {
    public let id: UUID
    public var name: String
    public var color: String
    public init(id: UUID = UUID(), name: String, color: String = "blue") throws {
        guard !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw ShhValidationError.empty(field: "tag name") }
        self.id = id; self.name = name; self.color = color
    }
}

public enum IdentityKind: String, Codable, CaseIterable, Sendable { case password, privateKey, agent }

public struct IdentityDescriptor: Identifiable, Codable, Hashable, Sendable {
    public let id: UUID
    public var name: String
    public var kind: IdentityKind
    public var publicFingerprint: String?
    /// Opaque Keychain item identifier. It is not secret material.
    public var keychainReference: String
    public let createdAt: Date
    public init(id: UUID = UUID(), name: String, kind: IdentityKind, publicFingerprint: String? = nil, keychainReference: String, createdAt: Date = Date()) throws {
        guard !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw ShhValidationError.empty(field: "identity name") }
        guard !keychainReference.isEmpty else { throw ShhValidationError.empty(field: "keychain reference") }
        self.id = id; self.name = name; self.kind = kind; self.publicFingerprint = publicFingerprint
        self.keychainReference = keychainReference; self.createdAt = createdAt
    }
}

public enum StrictHostKeyChecking: String, Codable, CaseIterable, Sendable { case prompt, trustedOnly }
public struct SSHOptions: Codable, Hashable, Sendable {
    public var connectTimeoutSeconds: Double
    public var keepAliveSeconds: Double?
    public var compression: Bool
    public var strictHostKeyChecking: StrictHostKeyChecking
    public init(connectTimeoutSeconds: Double = 15, keepAliveSeconds: Double? = 60, compression: Bool = false, strictHostKeyChecking: StrictHostKeyChecking = .prompt) {
        self.connectTimeoutSeconds = connectTimeoutSeconds; self.keepAliveSeconds = keepAliveSeconds
        self.compression = compression; self.strictHostKeyChecking = strictHostKeyChecking
    }
}
public struct MoshOptions: Codable, Hashable, Sendable { public init() {} }

public struct ProxyJumpEndpoint: Codable, Hashable, Sendable {
    public var hostname: String
    public var port: UInt16
    public var username: String
    public var identityID: UUID?

    public init(hostname: String, port: UInt16 = 22, username: String, identityID: UUID? = nil) {
        self.hostname = hostname
        self.port = port
        self.username = username
        self.identityID = identityID
    }
}

public enum ProxyJumpHop: Codable, Hashable, Sendable {
    case hostID(UUID)
    case endpoint(ProxyJumpEndpoint)
}

public struct ProxyJumpConfig: Codable, Hashable, Sendable {
    public var hops: [ProxyJumpHop]

    public init(hops: [ProxyJumpHop] = []) {
        self.hops = hops
    }

    public init(hostIDs: [UUID]) {
        self.hops = hostIDs.map { .hostID($0) }
    }

    public init(endpoints: [ProxyJumpEndpoint]) {
        self.hops = endpoints.map { .endpoint($0) }
    }

    public var hostIDs: [UUID] {
        hops.compactMap {
            switch $0 {
            case .hostID(let id): return id
            case .endpoint: return nil
            }
        }
    }
}

public struct ProxyJumpOptions: Codable, Hashable, Sendable {
    public var config: ProxyJumpConfig
    public var sshOptions: SSHOptions

    public var hopHostIDs: [UUID] {
        get { config.hostIDs }
        set { config = ProxyJumpConfig(hostIDs: newValue) }
    }

    public init(config: ProxyJumpConfig, sshOptions: SSHOptions = SSHOptions()) {
        self.config = config
        self.sshOptions = sshOptions
    }

    public init(hopHostIDs: [UUID] = [], sshOptions: SSHOptions = SSHOptions()) {
        self.config = ProxyJumpConfig(hostIDs: hopHostIDs)
        self.sshOptions = sshOptions
    }

    enum CodingKeys: String, CodingKey {
        case config, sshOptions, hopHostIDs
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        if let config = try container.decodeIfPresent(ProxyJumpConfig.self, forKey: .config) {
            self.config = config
        } else if let hopHostIDs = try container.decodeIfPresent([UUID].self, forKey: .hopHostIDs) {
            self.config = ProxyJumpConfig(hostIDs: hopHostIDs)
        } else {
            self.config = ProxyJumpConfig()
        }
        self.sshOptions = try container.decodeIfPresent(SSHOptions.self, forKey: .sshOptions) ?? SSHOptions()
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(config, forKey: .config)
        try container.encode(config.hostIDs, forKey: .hopHostIDs)
        try container.encode(sshOptions, forKey: .sshOptions)
    }
}

public enum ConnectionProfile: Codable, Hashable, Sendable { case ssh(SSHOptions); case mosh(MoshOptions); case proxyJump(ProxyJumpOptions) }

public enum HealthState: Codable, Hashable, Sendable {
    case unknown, checking, healthy, degraded(reason: String), offline
    public var label: String {
        switch self { case .unknown: "Unknown"; case .checking: "Checking"; case .healthy: "Healthy"; case .degraded(let reason): "Degraded: \(reason)"; case .offline: "Offline" }
    }
}

public struct HostTmuxPreferences: Codable, Hashable, Sendable {
    public var defaultSession: String?
    public var autoAttach: Bool

    public init(defaultSession: String? = nil, autoAttach: Bool = false) {
        self.defaultSession = defaultSession
        self.autoAttach = autoAttach
    }
}

public struct Host: Identifiable, Codable, Hashable, Sendable {
    public let id: UUID
    public var name: String
    public var hostname: String
    public var port: UInt16
    public var username: String
    public var groupID: UUID?
    public var tagIDs: Set<UUID>
    public var identityID: UUID?
    public var connection: ConnectionProfile
    public var health: HealthState
    public var lastUsedAt: Date?
    public var tmuxPreferences: HostTmuxPreferences
    public var voicePolicy: HostVoicePolicy
    public var isProduction: Bool
    public var forwardingRules: [PortForwardingRule]

    public var isVoiceEnabled: Bool {
        voicePolicy.isEnabled
    }

    public var defaultTmuxSession: String? {
        get { tmuxPreferences.defaultSession }
        set { tmuxPreferences.defaultSession = newValue }
    }

    public var autoAttachTmux: Bool {
        get { tmuxPreferences.autoAttach }
        set { tmuxPreferences.autoAttach = newValue }
    }

    public init(
        id: UUID = UUID(),
        name: String,
        hostname: String,
        port: UInt16 = 22,
        username: String,
        groupID: UUID? = nil,
        tagIDs: Set<UUID> = [],
        identityID: UUID? = nil,
        connection: ConnectionProfile = .ssh(SSHOptions()),
        health: HealthState = .unknown,
        lastUsedAt: Date? = nil,
        tmuxPreferences: HostTmuxPreferences = HostTmuxPreferences(),
        defaultTmuxSession: String? = nil,
        autoAttachTmux: Bool = false,
        voicePolicy: HostVoicePolicy = .disabled,
        isProduction: Bool? = nil,
        forwardingRules: [PortForwardingRule] = []
    ) throws {
        guard !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw ShhValidationError.empty(field: "host name") }
        guard !hostname.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw ShhValidationError.empty(field: "hostname") }
        guard !username.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw ShhValidationError.empty(field: "username") }
        guard port != 0 else { throw ShhValidationError.invalidPort }
        self.id = id; self.name = name; self.hostname = hostname; self.port = port; self.username = username
        self.groupID = groupID; self.tagIDs = tagIDs; self.identityID = identityID; self.connection = connection
        self.health = health; self.lastUsedAt = lastUsedAt
        self.voicePolicy = voicePolicy
        self.forwardingRules = forwardingRules
        let inferredProd = name.localizedCaseInsensitiveContains("prod") || hostname.localizedCaseInsensitiveContains("prod")
        self.isProduction = isProduction ?? inferredProd
        if defaultTmuxSession != nil || autoAttachTmux {
            self.tmuxPreferences = HostTmuxPreferences(
                defaultSession: defaultTmuxSession ?? tmuxPreferences.defaultSession,
                autoAttach: autoAttachTmux || tmuxPreferences.autoAttach
            )
        } else {
            self.tmuxPreferences = tmuxPreferences
        }
    }

    public var address: String { "\(username)@\(hostname):\(port)" }

    enum CodingKeys: String, CodingKey {
        case id, name, hostname, port, username, groupID, tagIDs, identityID, connection, health, lastUsedAt
        case tmuxPreferences, defaultTmuxSession, autoAttachTmux, autoAttach
        case voicePolicy, isProduction, forwardingRules
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.id = try container.decode(UUID.self, forKey: .id)
        self.name = try container.decode(String.self, forKey: .name)
        self.hostname = try container.decode(String.self, forKey: .hostname)
        self.port = try container.decode(UInt16.self, forKey: .port)
        self.username = try container.decode(String.self, forKey: .username)
        self.groupID = try container.decodeIfPresent(UUID.self, forKey: .groupID)
        self.tagIDs = try container.decodeIfPresent(Set<UUID>.self, forKey: .tagIDs) ?? []
        self.identityID = try container.decodeIfPresent(UUID.self, forKey: .identityID)
        self.connection = try container.decodeIfPresent(ConnectionProfile.self, forKey: .connection) ?? .ssh(SSHOptions())
        self.health = try container.decodeIfPresent(HealthState.self, forKey: .health) ?? .unknown
        self.lastUsedAt = try container.decodeIfPresent(Date.self, forKey: .lastUsedAt)
        self.voicePolicy = try container.decodeIfPresent(HostVoicePolicy.self, forKey: .voicePolicy) ?? .disabled
        let inferredProd = name.localizedCaseInsensitiveContains("prod") || hostname.localizedCaseInsensitiveContains("prod")
        self.isProduction = (try? container.decodeIfPresent(Bool.self, forKey: .isProduction)) ?? inferredProd
        self.forwardingRules = (try? container.decodeIfPresent([PortForwardingRule].self, forKey: .forwardingRules)) ?? []

        if let prefs = try container.decodeIfPresent(HostTmuxPreferences.self, forKey: .tmuxPreferences) {
            self.tmuxPreferences = prefs
        } else {
            let session = try container.decodeIfPresent(String.self, forKey: .defaultTmuxSession)
            let auto = try container.decodeIfPresent(Bool.self, forKey: .autoAttachTmux)
                ?? (try? container.decodeIfPresent(Bool.self, forKey: .autoAttach))
                ?? false
            self.tmuxPreferences = HostTmuxPreferences(defaultSession: session, autoAttach: auto)
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(name, forKey: .name)
        try container.encode(hostname, forKey: .hostname)
        try container.encode(port, forKey: .port)
        try container.encode(username, forKey: .username)
        try container.encodeIfPresent(groupID, forKey: .groupID)
        try container.encode(tagIDs, forKey: .tagIDs)
        try container.encodeIfPresent(identityID, forKey: .identityID)
        try container.encode(connection, forKey: .connection)
        try container.encode(health, forKey: .health)
        try container.encodeIfPresent(lastUsedAt, forKey: .lastUsedAt)
        try container.encode(tmuxPreferences, forKey: .tmuxPreferences)
        try container.encodeIfPresent(defaultTmuxSession, forKey: .defaultTmuxSession)
        try container.encode(autoAttachTmux, forKey: .autoAttachTmux)
        try container.encode(voicePolicy, forKey: .voicePolicy)
        try container.encode(isProduction, forKey: .isProduction)
        try container.encode(forwardingRules, forKey: .forwardingRules)
    }
}

public struct TrustRecord: Codable, Hashable, Sendable {
    public enum Decision: String, Codable, Sendable { case trustedPermanently }
    public var hostname: String
    public var port: UInt16
    public var keyAlgorithm: String
    public var sha256Fingerprint: String
    public var decision: Decision
    public var firstSeen: Date
    public var lastSeen: Date
    public init(hostname: String, port: UInt16, keyAlgorithm: String, sha256Fingerprint: String, decision: Decision = .trustedPermanently, firstSeen: Date = Date(), lastSeen: Date = Date()) {
        self.hostname = Self.canonicalHost(hostname); self.port = port; self.keyAlgorithm = keyAlgorithm; self.sha256Fingerprint = sha256Fingerprint
        self.decision = decision; self.firstSeen = firstSeen; self.lastSeen = lastSeen
    }
    public static func canonicalHost(_ value: String) -> String {
        var host = value.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        while host.hasSuffix(".") { host.removeLast() }
        return host
    }
    public var lookupKey: String { "\(Self.canonicalHost(hostname)):\(port):\(keyAlgorithm.lowercased())" }
}

public enum ForwardingMode: String, Codable, CaseIterable, Sendable { case local, remote, dynamicSOCKS }
public struct ForwardingRule: Identifiable, Codable, Hashable, Sendable {
    public let id: UUID
    public var mode: ForwardingMode
    public var bindAddress: String
    public var bindPort: UInt16
    public var destinationHost: String?
    public var destinationPort: UInt16?
    public init(id: UUID = UUID(), mode: ForwardingMode, bindAddress: String = "127.0.0.1", bindPort: UInt16, destinationHost: String? = nil, destinationPort: UInt16? = nil) throws {
        guard bindPort != 0 else { throw ShhValidationError.invalidPort }
        guard !bindAddress.isEmpty else { throw ShhValidationError.invalidBindAddress }
        if mode != .dynamicSOCKS && (destinationHost?.isEmpty != false || destinationPort == nil || destinationPort == 0) { throw ShhValidationError.invalidDestination }
        self.id = id; self.mode = mode; self.bindAddress = bindAddress; self.bindPort = bindPort; self.destinationHost = destinationHost; self.destinationPort = destinationPort
    }
    public var requiresNonLoopbackApproval: Bool { bindAddress != "127.0.0.1" && bindAddress != "::1" && bindAddress.lowercased() != "localhost" }
}

public enum PortForwardingType: String, Codable, CaseIterable, Sendable {
    case local
    case remote
    case dynamic
}

public struct PortForwardingRule: Identifiable, Codable, Hashable, Sendable {
    public let id: UUID
    public var name: String
    public var type: PortForwardingType
    public var localHost: String
    public var localPort: UInt16
    public var remoteHost: String?
    public var remotePort: UInt16?
    public var enabled: Bool

    public var isEnabled: Bool {
        get { enabled }
        set { enabled = newValue }
    }

    public init(
        id: UUID = UUID(),
        name: String = "",
        type: PortForwardingType,
        localHost: String = "127.0.0.1",
        localPort: UInt16,
        remoteHost: String? = nil,
        remotePort: UInt16? = nil,
        enabled: Bool = true
    ) throws {
        guard !localHost.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw ShhValidationError.invalidBindAddress
        }
        if type == .local {
            guard let rHost = remoteHost?.trimmingCharacters(in: .whitespacesAndNewlines), !rHost.isEmpty else {
                throw ShhValidationError.invalidDestination
            }
            guard let rPort = remotePort, rPort > 0 else {
                throw ShhValidationError.invalidDestination
            }
        } else if type == .remote {
            guard let rHost = remoteHost?.trimmingCharacters(in: .whitespacesAndNewlines), !rHost.isEmpty else {
                throw ShhValidationError.invalidDestination
            }
            guard remotePort != nil else {
                throw ShhValidationError.invalidDestination
            }
        }
        self.id = id
        self.name = name.isEmpty ? "\(type.rawValue) :\(localPort)" : name
        self.type = type
        self.localHost = localHost
        self.localPort = localPort
        self.remoteHost = remoteHost
        self.remotePort = remotePort
        self.enabled = enabled
    }

    public init(from rule: ForwardingRule, name: String = "", enabled: Bool = true) {
        self.id = rule.id
        self.name = name.isEmpty ? "\(rule.mode.rawValue) :\(rule.bindPort)" : name
        switch rule.mode {
        case .local: self.type = .local
        case .remote: self.type = .remote
        case .dynamicSOCKS: self.type = .dynamic
        }
        self.localHost = rule.bindAddress
        self.localPort = rule.bindPort
        self.remoteHost = rule.destinationHost
        self.remotePort = rule.destinationPort
        self.enabled = enabled
    }

    public func toForwardingRule() throws -> ForwardingRule {
        let mode: ForwardingMode
        switch type {
        case .local: mode = .local
        case .remote: mode = .remote
        case .dynamic: mode = .dynamicSOCKS
        }
        return try ForwardingRule(
            id: id,
            mode: mode,
            bindAddress: localHost,
            bindPort: localPort,
            destinationHost: remoteHost,
            destinationPort: remotePort
        )
    }

    public var requiresNonLoopbackApproval: Bool {
        localHost != "127.0.0.1" && localHost != "::1" && localHost.lowercased() != "localhost"
    }
}

public struct PortForwardingProfile: Identifiable, Codable, Hashable, Sendable {
    public let id: UUID
    public var name: String
    public var hostID: UUID?
    public var rules: [PortForwardingRule]

    public init(
        id: UUID = UUID(),
        name: String,
        hostID: UUID? = nil,
        rules: [PortForwardingRule] = []
    ) {
        self.id = id
        self.name = name
        self.hostID = hostID
        self.rules = rules
    }
}

public enum ForwardingStatus: Codable, Hashable, Sendable {
    case starting
    case active
    case paused
    case failed(reason: String)
    case stopped
}

public struct ForwardingSessionState: Identifiable, Codable, Hashable, Sendable {
    public let id: UUID
    public var ruleID: UUID
    public var rule: PortForwardingRule
    public var status: ForwardingStatus
    public var boundPort: UInt16?
    public var activeConnectionsCount: Int
    public var bytesSent: Int64
    public var bytesReceived: Int64
    public var startedAt: Date?
    public var lastActivityAt: Date?
    public var errorDescription: String?

    public init(
        id: UUID = UUID(),
        ruleID: UUID,
        rule: PortForwardingRule,
        status: ForwardingStatus = .starting,
        boundPort: UInt16? = nil,
        activeConnectionsCount: Int = 0,
        bytesSent: Int64 = 0,
        bytesReceived: Int64 = 0,
        startedAt: Date? = nil,
        lastActivityAt: Date? = nil,
        errorDescription: String? = nil
    ) {
        self.id = id
        self.ruleID = ruleID
        self.rule = rule
        self.status = status
        self.boundPort = boundPort
        self.activeConnectionsCount = activeConnectionsCount
        self.bytesSent = bytesSent
        self.bytesReceived = bytesReceived
        self.startedAt = startedAt
        self.lastActivityAt = lastActivityAt
        self.errorDescription = errorDescription
    }
}

public struct Snippet: Identifiable, Codable, Hashable, Sendable {
    public let id: UUID; public var name: String; public var body: String; public var argumentSchema: [String]; public let createdAt: Date
    public init(id: UUID = UUID(), name: String, body: String, argumentSchema: [String] = [], createdAt: Date = Date()) throws {
        guard !name.isEmpty else { throw ShhValidationError.empty(field: "snippet name") }
        guard !body.isEmpty else { throw ShhValidationError.empty(field: "snippet body") }
        self.id = id; self.name = name; self.body = body; self.argumentSchema = argumentSchema; self.createdAt = createdAt
    }
}
public enum MacroStep: Codable, Hashable, Sendable { case literal(String); case snippet(UUID, arguments: [String: String]); case delay(seconds: Double); case approvalBoundary }
public struct Macro: Identifiable, Codable, Hashable, Sendable {
    public let id: UUID; public var name: String; public var steps: [MacroStep]
    public init(id: UUID = UUID(), name: String, steps: [MacroStep]) throws { guard !name.isEmpty else { throw ShhValidationError.empty(field: "macro name") }; self.id = id; self.name = name; self.steps = steps }
}

public enum TerminalSessionState: String, Codable, Sendable { case connecting, connected, disconnected, failed }
public struct TerminalSize: Codable, Hashable, Sendable { public var columns: Int; public var rows: Int; public init(columns: Int = 80, rows: Int = 24) { self.columns = max(1, columns); self.rows = max(1, rows) } }
public struct TerminalSession: Identifiable, Codable, Hashable, Sendable {
    public let id: UUID; public let hostID: UUID; public let startedAt: Date; public var state: TerminalSessionState; public var terminalSize: TerminalSize; public var capabilities: Set<String>
    public init(id: UUID = UUID(), hostID: UUID, startedAt: Date = Date(), state: TerminalSessionState = .connecting, terminalSize: TerminalSize = TerminalSize(), capabilities: Set<String> = []) { self.id = id; self.hostID = hostID; self.startedAt = startedAt; self.state = state; self.terminalSize = terminalSize; self.capabilities = capabilities }
}

public enum RemoteMultiplexer: String, Codable, CaseIterable, Sendable { case tmux, zellij, byobu, screen, herdr }
public enum CapabilityAvailability: Codable, Hashable, Sendable { case available; case unavailable(reason: String) }
public struct CapabilityMatrix: Codable, Hashable, Sendable {
    public var mosh: CapabilityAvailability = .unavailable(reason: "Not enabled in this build")
    public var proxyJump: CapabilityAvailability = .available
    public var forwarding: CapabilityAvailability = .available
    public var sftp: CapabilityAvailability = .available
    public var tmux: CapabilityAvailability = .unavailable(reason: "Not enabled in this build")
    public var herdr: CapabilityAvailability = .unavailable(reason: "Not enabled in this build")
    public init() {}
}

public struct SessionRestorationMetadata: Codable, Equatable, Hashable, Sendable {
    public var hostID: UUID
    public var sessionID: UUID
    public var tmuxSessionID: String?
    public var timestamp: Date

    public init(
        hostID: UUID,
        sessionID: UUID = UUID(),
        tmuxSessionID: String? = nil,
        timestamp: Date = Date()
    ) {
        self.hostID = hostID
        self.sessionID = sessionID
        self.tmuxSessionID = tmuxSessionID
        self.timestamp = timestamp
    }
}

public protocol SessionRestorationStore: Sendable {
    func save(_ metadata: SessionRestorationMetadata) async throws
    func load() async throws -> SessionRestorationMetadata?
    func clear() async throws
}

public actor InMemorySessionRestorationStore: SessionRestorationStore {
    private var record: SessionRestorationMetadata?

    public init(initial: SessionRestorationMetadata? = nil) {
        self.record = initial
    }

    public func save(_ metadata: SessionRestorationMetadata) async throws {
        self.record = metadata
    }

    public func load() async throws -> SessionRestorationMetadata? {
        return record
    }

    public func clear() async throws {
        self.record = nil
    }
}

