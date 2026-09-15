import Foundation

/// A platform-neutral RGB color used by terminal themes.
public struct TerminalColor: Codable, Hashable, Sendable {
    public let red: UInt8
    public let green: UInt8
    public let blue: UInt8

    public init(red: UInt8, green: UInt8, blue: UInt8) {
        self.red = red
        self.green = green
        self.blue = blue
    }

    public init(hex: String) {
        let normalized = hex.trimmingCharacters(in: .whitespacesAndNewlines)
            .trimmingCharacters(in: CharacterSet(charactersIn: "#"))
        let value = UInt32(normalized, radix: 16) ?? 0
        self.init(red: UInt8((value >> 16) & 0xff), green: UInt8((value >> 8) & 0xff), blue: UInt8(value & 0xff))
    }

    public var hex: String { String(format: "#%02X%02X%02X", red, green, blue) }
}

public struct TerminalThemePalette: Codable, Hashable, Sendable {
    public let foreground: TerminalColor
    public let background: TerminalColor
    public let cursor: TerminalColor
    public let selection: TerminalColor
    public let ansi: [TerminalColor]

    public init(foreground: TerminalColor, background: TerminalColor, cursor: TerminalColor, selection: TerminalColor, ansi: [TerminalColor]) {
        self.foreground = foreground
        self.background = background
        self.cursor = cursor
        self.selection = selection
        self.ansi = Array(ansi.prefix(16)) + Array(repeating: background, count: max(0, 16 - ansi.count))
    }

    public var ansiColors: [TerminalColor] { ansi }
}

public enum TerminalThemePreset: String, CaseIterable, Codable, Hashable, Sendable, Identifiable {
    case catppuccinMocha, catppuccinLatte, solarizedDark, solarizedLight, nord, dracula

    public static let `default`: TerminalThemePreset = .catppuccinMocha
    public var id: String { rawValue }
    public var displayName: String {
        switch self {
        case .catppuccinMocha: return "Catppuccin Mocha"
        case .catppuccinLatte: return "Catppuccin Latte"
        case .solarizedDark: return "Solarized Dark"
        case .solarizedLight: return "Solarized Light"
        case .nord: return "Nord"
        case .dracula: return "Dracula"
        }
    }

    public var palette: TerminalThemePalette {
        switch self {
        case .catppuccinMocha: return Self.palette("#CDD6F4", "#1E1E2E", "#F5E0DC", "#585B70", ["#45475A", "#F38BA8", "#A6E3A1", "#F9E2AF", "#89B4FA", "#F5C2E7", "#94E2D5", "#BAC2DE", "#585B70", "#F38BA8", "#A6E3A1", "#F9E2AF", "#89B4FA", "#F5C2E7", "#94E2D5", "#A6ADC8"])
        case .catppuccinLatte: return Self.palette("#4C4F69", "#EFF1F5", "#DC8A78", "#ACB0BE", ["#5C5F77", "#D20F39", "#40A02B", "#DF8E1D", "#1E66F5", "#EA76CB", "#179299", "#6C6F85", "#8C8FA1", "#D20F39", "#40A02B", "#DF8E1D", "#1E66F5", "#EA76CB", "#179299", "#5C5F77"])
        case .solarizedDark: return Self.palette("#839496", "#002B36", "#93A1A1", "#073642", ["#073642", "#DC322F", "#859900", "#B58900", "#268BD2", "#D33682", "#2AA198", "#EEE8D5", "#002B36", "#CB4B16", "#586E75", "#657B83", "#839496", "#6C71C4", "#93A1A1", "#FDF6E3"])
        case .solarizedLight: return Self.palette("#657B83", "#FDF6E3", "#586E75", "#EEE8D5", ["#073642", "#DC322F", "#859900", "#B58900", "#268BD2", "#D33682", "#2AA198", "#EEE8D5", "#002B36", "#CB4B16", "#586E75", "#657B83", "#839496", "#6C71C4", "#93A1A1", "#FDF6E3"])
        case .nord: return Self.palette("#D8DEE9", "#2E3440", "#ECEFF4", "#434C5E", ["#3B4252", "#BF616A", "#A3BE8C", "#EBCB8B", "#81A1C1", "#B48EAD", "#88C0D0", "#E5E9F0", "#4C566A", "#BF616A", "#A3BE8C", "#EBCB8B", "#81A1C1", "#B48EAD", "#8FBCBB", "#ECEFF4"])
        case .dracula: return Self.palette("#F8F8F2", "#282A36", "#F8F8F2", "#44475A", ["#21222C", "#FF5555", "#50FA7B", "#F1FA8C", "#BD93F9", "#FF79C6", "#8BE9FD", "#F8F8F2", "#6272A4", "#FF6E6E", "#69FF94", "#FFFFA5", "#D6ACFF", "#FF92DF", "#A4FFFF", "#FFFFFF"])
        }
    }

    private static func palette(_ foreground: String, _ background: String, _ cursor: String, _ selection: String, _ ansi: [String]) -> TerminalThemePalette {
        TerminalThemePalette(foreground: TerminalColor(hex: foreground), background: TerminalColor(hex: background), cursor: TerminalColor(hex: cursor), selection: TerminalColor(hex: selection), ansi: ansi.map(TerminalColor.init(hex:)))
    }
}

public enum AppearanceSetting: String, CaseIterable, Codable, Hashable, Sendable, Identifiable {
    case system, light, dark
    public static let `default`: AppearanceSetting = .system
    public var id: String { rawValue }
    public var displayName: String { rawValue.capitalized }
}

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
    // Kept for decoding older catalogs, but no longer persisted for new data.
    public var defaultSession: String?
    public var autoAttach: Bool

    public init(defaultSession: String? = nil, autoAttach: Bool = false) {
        self.defaultSession = defaultSession
        self.autoAttach = autoAttach
    }

    private enum CodingKeys: String, CodingKey { case defaultSession, autoAttach }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        defaultSession = try container.decodeIfPresent(String.self, forKey: .defaultSession)
        autoAttach = try container.decodeIfPresent(Bool.self, forKey: .autoAttach) ?? false
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        // A configured default target is legacy state and must not be emitted.
        try container.encode(autoAttach, forKey: .autoAttach)
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
        // Legacy flattened tmux keys remain decode-only for compatibility.
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
    public var mosh: CapabilityAvailability = .available
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

public enum ConnectionStage: String, Codable, Sendable, CaseIterable {
    case configuration = "Configuration"
    case credential = "Credential"
    case dns = "DNS"
    case tcp = "TCP"
    case hostKey = "Host Key"
    case sshNegotiation = "SSH Negotiation"
    case authentication = "Authentication"
    case ptyShell = "PTY/Shell"
    case proxyJump = "ProxyJump/Mosh"
}

public struct ConnectionFailure: Codable, Sendable, Equatable, Identifiable {
    public var id: UUID
    public var stage: ConnectionStage
    public var reason: String
    public var technicalDetail: String
    public var recoveryAction: String
    public var timestamp: Date

    public init(
        id: UUID = UUID(),
        stage: ConnectionStage,
        reason: String,
        technicalDetail: String,
        recoveryAction: String,
        timestamp: Date = Date()
    ) {
        self.id = id
        self.stage = stage
        self.reason = reason
        self.technicalDetail = technicalDetail
        self.recoveryAction = recoveryAction
        self.timestamp = timestamp
    }

    public var copyableDiagnostics: String {
        let formatter = ISO8601DateFormatter()
        return """
        Connection Failure Diagnostics
        -----------------------------
        Stage: \(stage.rawValue)
        Reason: \(reason)
        Technical Detail: \(technicalDetail)
        Suggested Action: \(recoveryAction)
        Timestamp: \(formatter.string(from: timestamp))
        """
    }

    public static func from(error: Error, host: Host? = nil) -> ConnectionFailure {
        if let transportError = error as? TransportError {
            switch transportError {
            case .dnsFailure(let detail):
                return ConnectionFailure(
                    stage: .dns,
                    reason: "Could not resolve hostname.",
                    technicalDetail: detail.isEmpty ? "DNS lookup failed for target host." : detail,
                    recoveryAction: "Check the host address spelling and your device network/DNS configuration."
                )
            case .connectionRefused:
                return ConnectionFailure(
                    stage: .tcp,
                    reason: "Connection refused by remote server.",
                    technicalDetail: "Remote port refused TCP connection (ECONNREFUSED).",
                    recoveryAction: "Verify that SSH service is running on the target port and firewall rules permit connections."
                )
            case .timeout:
                return ConnectionFailure(
                    stage: .tcp,
                    reason: "Connection timed out reaching host.",
                    technicalDetail: "TCP handshake timed out or network was unreachable.",
                    recoveryAction: "Check remote host reachability and network connection."
                )
            case .networkUnavailable:
                return ConnectionFailure(
                    stage: .tcp,
                    reason: "Network is unavailable or unreachable.",
                    technicalDetail: "Network interface is down or target route is unreachable.",
                    recoveryAction: "Check your Wi-Fi/cellular connection and try again."
                )
            case .missingCredential(let reference):
                let safeRef = reference.prefix(6) + "..."
                return ConnectionFailure(
                    stage: .credential,
                    reason: "Saved credential could not be found in Keychain.",
                    technicalDetail: "Keychain item (ref: \(safeRef)) was not found or inaccessible.",
                    recoveryAction: "Re-import or generate a new SSH key for this identity in Key Management."
                )
            case .invalidPrivateKey(let detail):
                return ConnectionFailure(
                    stage: .credential,
                    reason: "Private key format invalid or unreadable.",
                    technicalDetail: detail,
                    recoveryAction: "Verify key format and ensure it is an unencrypted OpenSSH or PKCS#8 Ed25519 private key."
                )
            case .authenticationRequired:
                return ConnectionFailure(
                    stage: .authentication,
                    reason: "Authentication rejected by remote server.",
                    technicalDetail: "Server rejected public key authentication.",
                    recoveryAction: "Ensure your public key is added to ~/.ssh/authorized_keys on the remote server."
                )
            case .hostKeyChanged(let old, let new):
                let safeOld = old.prefix(16) + "..."
                let safeNew = new.prefix(16) + "..."
                return ConnectionFailure(
                    stage: .hostKey,
                    reason: "Host key has changed.",
                    technicalDetail: "Host key mismatch. Saved: \(safeOld), Received: \(safeNew).",
                    recoveryAction: "Confirm whether the server was recently reinstalled or rotated its key before trusting."
                )
            case .hostKeyApprovalRequired:
                return ConnectionFailure(
                    stage: .hostKey,
                    reason: "Host key verification required.",
                    technicalDetail: "The server presented an unrecognized host key.",
                    recoveryAction: "Approve the host key fingerprint to connect."
                )
            case .invalidConfiguration:
                return ConnectionFailure(
                    stage: .configuration,
                    reason: "Invalid connection configuration.",
                    technicalDetail: "Host options or parameters could not be validated.",
                    recoveryAction: "Review host connection settings in the editor."
                )
            case .unsupported:
                return ConnectionFailure(
                    stage: .configuration,
                    reason: "Unsupported connection feature.",
                    technicalDetail: "The requested auth method or transport feature is not supported.",
                    recoveryAction: "Check host settings or switch to standard SSH direct connection."
                )
            case .cancelled:
                return ConnectionFailure(
                    stage: .configuration,
                    reason: "Connection was cancelled.",
                    technicalDetail: "The user or system cancelled the connection.",
                    recoveryAction: "Tap Connect to retry."
                )
            case .remoteFailure(let message):
                let lower = message.lowercased()
                if lower.contains("pty") || lower.contains("shell") {
                    return ConnectionFailure(
                        stage: .ptyShell,
                        reason: "Remote shell allocation failed.",
                        technicalDetail: "Server rejected pseudo-terminal or shell initialization request.",
                        recoveryAction: "Check remote user shell and account permissions."
                    )
                }
                if lower.contains("bastion") || lower.contains("proxyjump") || lower.contains("hop") {
                    return ConnectionFailure(
                        stage: .proxyJump,
                        reason: "ProxyJump bastion connection failed.",
                        technicalDetail: "Failed to establish SSH connection through intermediate hop.",
                        recoveryAction: "Verify intermediate bastion host availability and credentials."
                    )
                }
                if lower.contains("mosh") {
                    return ConnectionFailure(
                        stage: .proxyJump,
                        reason: "Mosh session bootstrap failed.",
                        technicalDetail: "Failed to start or connect to mosh-server.",
                        recoveryAction: "Ensure mosh-server is installed on remote host and UDP ports are open."
                    )
                }
                return ConnectionFailure(
                    stage: .sshNegotiation,
                    reason: "SSH negotiation failed.",
                    technicalDetail: "Remote failure during protocol handshake: \(Redactor().redact(message))",
                    recoveryAction: "Verify remote SSH server health, algorithm compatibility, and logs."
                )
            }
        }

        let desc = error.localizedDescription
        let descr = String(describing: error)
        let combined = "\(desc) \(descr)".lowercased()
        if combined.contains("nodename") || combined.contains("servname") || combined.contains("dns") || combined.contains("unknownhost") {
            return ConnectionFailure(
                stage: .dns,
                reason: "Could not resolve hostname.",
                technicalDetail: "DNS resolution failed for remote host.",
                recoveryAction: "Check the host address spelling and your network's DNS settings."
            )
        }
        if combined.contains("refused") {
            return ConnectionFailure(
                stage: .tcp,
                reason: "Connection refused by remote server.",
                technicalDetail: "Target port rejected connection.",
                recoveryAction: "Verify SSH service is running and accessible."
            )
        }
        return ConnectionFailure(
            stage: .sshNegotiation,
            reason: "Connection failed.",
            technicalDetail: "An unexpected error occurred: \(Redactor().redact(desc))",
            recoveryAction: "Check network settings and try connecting again."
        )
    }
}


