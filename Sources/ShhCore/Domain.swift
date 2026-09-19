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

    private enum CodingKeys: String, CodingKey {
        case connectTimeoutSeconds, keepAliveSeconds, compression, strictHostKeyChecking
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.connectTimeoutSeconds = try container.decodeIfPresent(Double.self, forKey: .connectTimeoutSeconds) ?? 15
        self.keepAliveSeconds = try container.decodeIfPresent(Double.self, forKey: .keepAliveSeconds) ?? 60
        self.compression = try container.decodeIfPresent(Bool.self, forKey: .compression) ?? false
        self.strictHostKeyChecking = try container.decodeIfPresent(StrictHostKeyChecking.self, forKey: .strictHostKeyChecking) ?? .prompt
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

public struct CloudflareAccessOptions: Codable, Hashable, Sendable {
    public var clientID: String
    public var clientSecretKeychainRef: String
    public var tunnelDomain: String

    public init(
        clientID: String,
        clientSecretKeychainRef: String,
        tunnelDomain: String
    ) {
        self.clientID = clientID
        self.clientSecretKeychainRef = clientSecretKeychainRef
        self.tunnelDomain = tunnelDomain
    }
}

public struct TailscaleOptions: Codable, Hashable, Sendable {
    public var tailscaleHostname: String
    public var checkHostKey: Bool

    public init(
        tailscaleHostname: String,
        checkHostKey: Bool = false
    ) {
        self.tailscaleHostname = tailscaleHostname
        self.checkHostKey = checkHostKey
    }
}

public typealias HostConnectionType = ConnectionProfile

public enum ConnectionProfile: Codable, Hashable, Sendable {
    case ssh(SSHOptions)
    case mosh(MoshOptions)
    case proxyJump(ProxyJumpOptions)
    case cloudflareAccess(CloudflareAccessOptions)
    case tailscale(TailscaleOptions)

    public static func standard(_ options: SSHOptions = SSHOptions()) -> ConnectionProfile {
        .ssh(options)
    }

    private enum CodingKeys: String, CodingKey {
        case ssh
        case standard
        case mosh
        case proxyJump
        case cloudflareAccess
        case tailscale
        case type
    }

    public init(from decoder: Decoder) throws {
        if let single = try? decoder.singleValueContainer(), let str = try? single.decode(String.self) {
            switch str.lowercased() {
            case "standard", "ssh", "direct":
                self = .ssh(SSHOptions())
                return
            case "mosh":
                self = .mosh(MoshOptions())
                return
            case "proxyjump":
                self = .proxyJump(ProxyJumpOptions())
                return
            case "cloudflareaccess", "cloudflare":
                self = .cloudflareAccess(CloudflareAccessOptions(clientID: "", clientSecretKeychainRef: "", tunnelDomain: ""))
                return
            case "tailscale":
                self = .tailscale(TailscaleOptions(tailscaleHostname: ""))
                return
            default:
                break
            }
        }

        let container = try decoder.container(keyedBy: CodingKeys.self)

        if container.contains(.ssh) {
            let opts = try container.decodeIfPresent(SSHOptions.self, forKey: .ssh) ?? SSHOptions()
            self = .ssh(opts)
            return
        }

        if container.contains(.standard) {
            let opts = try container.decodeIfPresent(SSHOptions.self, forKey: .standard) ?? SSHOptions()
            self = .ssh(opts)
            return
        }

        if container.contains(.mosh) {
            let opts = try container.decode(MoshOptions.self, forKey: .mosh)
            self = .mosh(opts)
            return
        }

        if container.contains(.proxyJump) {
            let opts = try container.decode(ProxyJumpOptions.self, forKey: .proxyJump)
            self = .proxyJump(opts)
            return
        }

        if container.contains(.cloudflareAccess) {
            let opts = try container.decode(CloudflareAccessOptions.self, forKey: .cloudflareAccess)
            self = .cloudflareAccess(opts)
            return
        }

        if container.contains(.tailscale) {
            let opts = try container.decode(TailscaleOptions.self, forKey: .tailscale)
            self = .tailscale(opts)
            return
        }

        if let typeString = try container.decodeIfPresent(String.self, forKey: .type) {
            switch typeString.lowercased() {
            case "standard", "ssh", "direct":
                let opts = (try? container.decodeIfPresent(SSHOptions.self, forKey: .ssh)) ?? SSHOptions()
                self = .ssh(opts)
                return
            case "mosh":
                let opts = (try? container.decode(MoshOptions.self, forKey: .mosh)) ?? MoshOptions()
                self = .mosh(opts)
                return
            case "proxyjump":
                let opts = (try? container.decode(ProxyJumpOptions.self, forKey: .proxyJump)) ?? ProxyJumpOptions()
                self = .proxyJump(opts)
                return
            case "cloudflareaccess", "cloudflare":
                if let opts = try? container.decode(CloudflareAccessOptions.self, forKey: .cloudflareAccess) {
                    self = .cloudflareAccess(opts)
                    return
                }
            case "tailscale":
                if let opts = try? container.decode(TailscaleOptions.self, forKey: .tailscale) {
                    self = .tailscale(opts)
                    return
                }
            default:
                break
            }
        }

        self = .ssh(SSHOptions())
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .ssh(let opts):
            try container.encode(opts, forKey: .ssh)
        case .mosh(let opts):
            try container.encode(opts, forKey: .mosh)
        case .proxyJump(let opts):
            try container.encode(opts, forKey: .proxyJump)
        case .cloudflareAccess(let opts):
            try container.encode(opts, forKey: .cloudflareAccess)
        case .tailscale(let opts):
            try container.encode(opts, forKey: .tailscale)
        }
    }
}

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
    /// Absolute SFTP directory override for Command Dial image uploads.
    /// Nil uses a private directory under the remote home.
    public var sendImageDestination: String?

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
        forwardingRules: [PortForwardingRule] = [],
        sendImageDestination: String? = nil
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
        self.sendImageDestination = sendImageDestination
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
        case voicePolicy, isProduction, forwardingRules, sendImageDestination
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
        if let state = try? container.decode(HealthState.self, forKey: .health) {
            self.health = state
        } else if let str = try? container.decode(String.self, forKey: .health) {
            switch str.lowercased() {
            case "healthy": self.health = .healthy
            case "checking": self.health = .checking
            case "offline": self.health = .offline
            default: self.health = .unknown
            }
        } else {
            self.health = .unknown
        }
        self.lastUsedAt = try container.decodeIfPresent(Date.self, forKey: .lastUsedAt)
        self.voicePolicy = try container.decodeIfPresent(HostVoicePolicy.self, forKey: .voicePolicy) ?? .disabled
        let inferredProd = name.localizedCaseInsensitiveContains("prod") || hostname.localizedCaseInsensitiveContains("prod")
        self.isProduction = (try? container.decodeIfPresent(Bool.self, forKey: .isProduction)) ?? inferredProd
        self.forwardingRules = (try? container.decodeIfPresent([PortForwardingRule].self, forKey: .forwardingRules)) ?? []
        self.sendImageDestination = try container.decodeIfPresent(String.self, forKey: .sendImageDestination)

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
        try container.encodeIfPresent(sendImageDestination, forKey: .sendImageDestination)
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

/// A validated, secret-free identifier for the last explicitly selected remote
/// multiplexer target. Deferred adapters intentionally have no target case.
public enum LastUsedMultiplexerTarget: Codable, Equatable, Hashable, Sendable {
    case tmux(sessionID: String)
    case herdr(workspaceID: String)

    public var multiplexer: RemoteMultiplexer {
        switch self {
        case .tmux: return .tmux
        case .herdr: return .herdr
        }
    }

    public static func tmuxTarget(_ value: String) -> LastUsedMultiplexerTarget? {
        let value = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty, value.count <= 256,
              !value.unicodeScalars.contains(where: { $0.properties.isWhitespace || $0.value < 0x20 }) else {
            return nil
        }
        return .tmux(sessionID: value)
    }

    public static func herdrTarget(_ value: String) -> LastUsedMultiplexerTarget? {
        let value = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty, value.count <= 256,
              !value.unicodeScalars.contains(where: { $0.properties.isWhitespace || $0.value < 0x20 }) else {
            return nil
        }
        return .herdr(workspaceID: value)
    }
}

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
    /// Deprecated compatibility field. New code uses lastUsedMultiplexerTarget.
    public var tmuxSessionID: String?
    public var lastUsedMultiplexerTarget: LastUsedMultiplexerTarget?
    public var timestamp: Date

    public init(
        hostID: UUID,
        sessionID: UUID = UUID(),
        tmuxSessionID: String? = nil,
        lastUsedMultiplexerTarget: LastUsedMultiplexerTarget? = nil,
        timestamp: Date = Date()
    ) {
        self.hostID = hostID
        self.sessionID = sessionID
        self.tmuxSessionID = tmuxSessionID
        self.lastUsedMultiplexerTarget = lastUsedMultiplexerTarget
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
            case .missingIdentity(let id):
                return ConnectionFailure(
                    stage: .credential,
                    reason: "Saved host identity is missing.",
                    technicalDetail: "Identity descriptor \(id.uuidString) is not present in the catalog.",
                    recoveryAction: "Edit this host and select an available identity, or restore the missing identity before reconnecting."
                )
            case .identityCollision(let id):
                return ConnectionFailure(
                    stage: .credential,
                    reason: "Saved host identity is ambiguous.",
                    technicalDetail: "Identity descriptor \(id.uuidString) shares an ID or Keychain reference with another descriptor.",
                    recoveryAction: "Remove duplicate identity records or Keychain references, then select a single identity before reconnecting."
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

// MARK: - Server Telemetry

public struct ServerTelemetry: Codable, Hashable, Sendable, Identifiable {
    public var id: UUID
    public var timestamp: Date
    public var cpuUsagePercentage: Double?
    public var memoryUsedBytes: Int64?
    public var memoryTotalBytes: Int64?
    public var loadAverage: (Double, Double, Double)?
    public var uptimeSeconds: TimeInterval?

    public init(
        id: UUID = UUID(),
        timestamp: Date = Date(),
        cpuUsagePercentage: Double? = nil,
        memoryUsedBytes: Int64? = nil,
        memoryTotalBytes: Int64? = nil,
        loadAverage: (Double, Double, Double)? = nil,
        uptimeSeconds: TimeInterval? = nil
    ) {
        self.id = id
        self.timestamp = timestamp
        self.cpuUsagePercentage = cpuUsagePercentage
        self.memoryUsedBytes = memoryUsedBytes
        self.memoryTotalBytes = memoryTotalBytes
        self.loadAverage = loadAverage
        self.uptimeSeconds = uptimeSeconds
    }

    public var memoryUsagePercentage: Double? {
        guard let used = memoryUsedBytes, let total = memoryTotalBytes, total > 0 else {
            return nil
        }
        return (Double(used) / Double(total)) * 100.0
    }

    public var formattedUptime: String {
        guard let uptime = uptimeSeconds, uptime >= 0 else {
            return "-"
        }
        let totalSeconds = Int(uptime)
        let days = totalSeconds / 86400
        let hours = (totalSeconds % 86400) / 3600
        let minutes = (totalSeconds % 3600) / 60
        let seconds = totalSeconds % 60

        if days > 0 {
            return "\(days)d \(hours)h"
        } else if hours > 0 {
            return "\(hours)h \(minutes)m"
        } else if minutes > 0 {
            return "\(minutes)m"
        } else {
            return "\(seconds)s"
        }
    }

    public var formattedMemory: String {
        guard let used = memoryUsedBytes, let total = memoryTotalBytes, total > 0 else {
            return "-"
        }
        let usedGB = Double(used) / 1_073_741_824.0
        let totalGB = Double(total) / 1_073_741_824.0
        let pct = Int(round((Double(used) / Double(total)) * 100.0))

        if total >= 1_073_741_824 {
            return String(format: "%.1f / %.1f GB (%d%%)", usedGB, totalGB, pct)
        } else {
            let usedMB = Double(used) / 1_048_576.0
            let totalMB = Double(total) / 1_048_576.0
            return String(format: "%.0f / %.0f MB (%d%%)", usedMB, totalMB, pct)
        }
    }

    public static func == (lhs: ServerTelemetry, rhs: ServerTelemetry) -> Bool {
        lhs.id == rhs.id &&
        lhs.timestamp == rhs.timestamp &&
        lhs.cpuUsagePercentage == rhs.cpuUsagePercentage &&
        lhs.memoryUsedBytes == rhs.memoryUsedBytes &&
        lhs.memoryTotalBytes == rhs.memoryTotalBytes &&
        lhs.loadAverage?.0 == rhs.loadAverage?.0 &&
        lhs.loadAverage?.1 == rhs.loadAverage?.1 &&
        lhs.loadAverage?.2 == rhs.loadAverage?.2 &&
        lhs.uptimeSeconds == rhs.uptimeSeconds
    }

    public func hash(into hasher: inout Hasher) {
        hasher.combine(id)
        hasher.combine(timestamp)
        hasher.combine(cpuUsagePercentage)
        hasher.combine(memoryUsedBytes)
        hasher.combine(memoryTotalBytes)
        if let load = loadAverage {
            hasher.combine(load.0)
            hasher.combine(load.1)
            hasher.combine(load.2)
        } else {
            hasher.combine(0 as Int)
        }
        hasher.combine(uptimeSeconds)
    }

    private enum CodingKeys: String, CodingKey {
        case id
        case timestamp
        case cpuUsagePercentage
        case memoryUsedBytes
        case memoryTotalBytes
        case loadAverage
        case uptimeSeconds
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(timestamp, forKey: .timestamp)
        try container.encodeIfPresent(cpuUsagePercentage, forKey: .cpuUsagePercentage)
        try container.encodeIfPresent(memoryUsedBytes, forKey: .memoryUsedBytes)
        try container.encodeIfPresent(memoryTotalBytes, forKey: .memoryTotalBytes)
        if let load = loadAverage {
            try container.encode([load.0, load.1, load.2], forKey: .loadAverage)
        }
        try container.encodeIfPresent(uptimeSeconds, forKey: .uptimeSeconds)
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.id = try container.decode(UUID.self, forKey: .id)
        self.timestamp = try container.decode(Date.self, forKey: .timestamp)
        self.cpuUsagePercentage = try container.decodeIfPresent(Double.self, forKey: .cpuUsagePercentage)
        self.memoryUsedBytes = try container.decodeIfPresent(Int64.self, forKey: .memoryUsedBytes)
        self.memoryTotalBytes = try container.decodeIfPresent(Int64.self, forKey: .memoryTotalBytes)
        if let loads = try container.decodeIfPresent([Double].self, forKey: .loadAverage), loads.count >= 3 {
            self.loadAverage = (loads[0], loads[1], loads[2])
        } else {
            self.loadAverage = nil
        }
        self.uptimeSeconds = try container.decodeIfPresent(TimeInterval.self, forKey: .uptimeSeconds)
    }
}

// MARK: - Server Telemetry Parser

public struct ServerTelemetryParser: Sendable {
    public init() {}

    public func parse(_ rawOutput: String) -> ServerTelemetry {
        let lines = rawOutput.components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }

        var loadAverage: (Double, Double, Double)?
        var memoryTotalBytes: Int64?
        var memoryUsedBytes: Int64?
        var cpuUsagePercentage: Double?
        var uptimeSeconds: TimeInterval?

        // 1. Parse /proc/loadavg or uptime load average
        for line in lines {
            if let load = parseProcLoadAvg(line) {
                loadAverage = load
                break
            }
        }

        // 2. Parse /proc/meminfo
        if let mem = parseProcMeminfo(lines) {
            memoryTotalBytes = mem.total
            memoryUsedBytes = mem.used
        } else if let mem = parseMacOSVmStat(lines) {
            memoryTotalBytes = mem.total
            memoryUsedBytes = mem.used
        }

        // 3. Parse /proc/stat
        for line in lines {
            if line.hasPrefix("cpu ") || line.hasPrefix("cpu\t") {
                if let cpu = parseProcStatLine(line) {
                    cpuUsagePercentage = cpu
                    break
                }
            }
        }

        // 4. Parse /proc/uptime or uptime command output
        for line in lines {
            if let uptime = parseProcUptime(line) {
                uptimeSeconds = uptime
                break
            }
            if let uptime = parseUptimeCommandLine(line) {
                uptimeSeconds = uptime
                // Fallback load average from uptime line if loadavg was not present
                if loadAverage == nil, let load = parseUptimeLoadAverage(line) {
                    loadAverage = load
                }
                break
            }
        }

        // If loadavg still nil, try extracting from any line with "load average"
        if loadAverage == nil {
            for line in lines {
                if let load = parseUptimeLoadAverage(line) {
                    loadAverage = load
                    break
                }
            }
        }

        return ServerTelemetry(
            timestamp: Date(),
            cpuUsagePercentage: cpuUsagePercentage,
            memoryUsedBytes: memoryUsedBytes,
            memoryTotalBytes: memoryTotalBytes,
            loadAverage: loadAverage,
            uptimeSeconds: uptimeSeconds
        )
    }

    public func parseLinux(
        loadavg: String? = nil,
        meminfo: String? = nil,
        stat: String? = nil,
        uptime: String? = nil
    ) -> ServerTelemetry {
        var combined = ""
        if let loadavg { combined += loadavg + "\n" }
        if let meminfo { combined += meminfo + "\n" }
        if let stat { combined += stat + "\n" }
        if let uptime { combined += uptime + "\n" }
        return parse(combined)
    }

    public func parseMacOS(
        vmStat: String? = nil,
        uptime: String? = nil
    ) -> ServerTelemetry {
        var combined = ""
        if let vmStat { combined += vmStat + "\n" }
        if let uptime { combined += uptime + "\n" }
        return parse(combined)
    }

    // MARK: - Linux /proc Parsers

    private func parseProcLoadAvg(_ line: String) -> (Double, Double, Double)? {
        let tokens = line.split(whereSeparator: \.isWhitespace).map(String.init)
        guard tokens.count >= 3 else { return nil }
        guard let l1 = Double(tokens[0]), let l2 = Double(tokens[1]), let l3 = Double(tokens[2]) else {
            return nil
        }
        // Additional validation: 4th token in /proc/loadavg is typically thread count like "1/234"
        if tokens.count >= 4 && tokens[3].contains("/") {
            return (l1, l2, l3)
        }
        // If exact 3 or 5 tokens of numbers
        if tokens.count == 3 || tokens.count == 5 {
            return (l1, l2, l3)
        }
        return nil
    }

    private func parseProcMeminfo(_ lines: [String]) -> (total: Int64, used: Int64)? {
        var memTotalKB: Int64?
        var memFreeKB: Int64?
        var memAvailableKB: Int64?
        var buffersKB: Int64?
        var cachedKB: Int64?

        for line in lines {
            let parts = line.split(separator: ":", maxSplits: 1).map { $0.trimmingCharacters(in: .whitespaces) }
            guard parts.count == 2 else { continue }
            let key = parts[0]
            let valueTokens = parts[1].split(whereSeparator: \.isWhitespace)
            guard let first = valueTokens.first, let value = Int64(first) else { continue }

            switch key {
            case "MemTotal":
                memTotalKB = value
            case "MemFree":
                memFreeKB = value
            case "MemAvailable":
                memAvailableKB = value
            case "Buffers":
                buffersKB = value
            case "Cached":
                cachedKB = value
            default:
                break
            }
        }

        guard let totalKB = memTotalKB, totalKB > 0 else { return nil }
        let totalBytes = totalKB * 1024

        let availableKB: Int64
        if let avail = memAvailableKB {
            availableKB = avail
        } else if let free = memFreeKB {
            availableKB = free + (buffersKB ?? 0) + (cachedKB ?? 0)
        } else {
            availableKB = 0
        }

        let usedBytes = max(0, totalBytes - (availableKB * 1024))
        return (total: totalBytes, used: usedBytes)
    }

    private func parseProcStatLine(_ line: String) -> Double? {
        let tokens = line.split(whereSeparator: \.isWhitespace).map(String.init)
        guard tokens.count >= 5, tokens[0] == "cpu" else { return nil }
        // Format: cpu  user nice system idle iowait irq softirq steal guest guest_nice
        let values = tokens.dropFirst().compactMap { Double($0) }
        guard values.count >= 4 else { return nil }

        let user = values[0]
        let nice = values[1]
        let system = values[2]
        let idle = values[3]
        let iowait = values.count > 4 ? values[4] : 0.0
        let irq = values.count > 5 ? values[5] : 0.0
        let softirq = values.count > 6 ? values[6] : 0.0
        let steal = values.count > 7 ? values[7] : 0.0

        let busyTime = user + nice + system + irq + softirq + steal
        let idleTime = idle + iowait
        let totalTime = busyTime + idleTime

        guard totalTime > 0 else { return nil }
        let usage = (busyTime / totalTime) * 100.0
        return max(0.0, min(100.0, usage))
    }

    private func parseProcUptime(_ line: String) -> TimeInterval? {
        let tokens = line.split(whereSeparator: \.isWhitespace).map(String.init)
        guard tokens.count == 2, let uptime = Double(tokens[0]), let _ = Double(tokens[1]) else {
            return nil
        }
        return uptime >= 0 ? uptime : nil
    }

    // MARK: - macOS / BSD vm_stat Parser

    private func parseMacOSVmStat(_ lines: [String]) -> (total: Int64, used: Int64)? {
        var pageSize: Int64 = 4096
        var pagesFree: Int64?
        var pagesActive: Int64?
        var pagesInactive: Int64?
        var pagesSpeculative: Int64?
        var pagesWired: Int64?
        var pagesCompressor: Int64?

        var isVmStat = false

        for line in lines {
            if line.contains("Mach Virtual Memory Statistics") {
                isVmStat = true
                if let sizeRange = line.range(of: "page size of ") {
                    let rest = line[sizeRange.upperBound...]
                    let digits = rest.prefix(while: \.isNumber)
                    if let size = Int64(digits), size > 0 {
                        pageSize = size
                    }
                }
                continue
            }

            let parts = line.split(separator: ":", maxSplits: 1).map { $0.trimmingCharacters(in: .whitespaces) }
            guard parts.count == 2 else { continue }
            let key = parts[0].replacingOccurrences(of: "\"", with: "")
            let valStr = parts[1].trimmingCharacters(in: CharacterSet(charactersIn: ". \t"))
            guard let val = Int64(valStr) else { continue }

            switch key {
            case "Pages free":
                pagesFree = val
                isVmStat = true
            case "Pages active":
                pagesActive = val
                isVmStat = true
            case "Pages inactive":
                pagesInactive = val
                isVmStat = true
            case "Pages speculative":
                pagesSpeculative = val
            case "Pages wired down":
                pagesWired = val
            case "Pages occupied by compressor":
                pagesCompressor = val
            default:
                break
            }
        }

        guard isVmStat else { return nil }
        let free = (pagesFree ?? 0) + (pagesSpeculative ?? 0)
        let active = pagesActive ?? 0
        let inactive = pagesInactive ?? 0
        let wired = pagesWired ?? 0
        let compressed = pagesCompressor ?? 0

        let totalPages = free + active + inactive + wired + compressed
        guard totalPages > 0 else { return nil }

        let totalBytes = totalPages * pageSize
        let usedPages = active + wired + compressed
        let usedBytes = usedPages * pageSize
        return (total: totalBytes, used: usedBytes)
    }

    // MARK: - Uptime Command Line Parser

    private func parseUptimeCommandLine(_ line: String) -> TimeInterval? {
        guard let upRange = line.range(of: " up ") else { return nil }
        let afterUp = String(line[upRange.upperBound...])

        // The uptime section ends before ", X user"
        var uptimeStr = afterUp
        if let userRange = afterUp.range(of: " user") {
            let beforeUser = String(afterUp[..<userRange.lowerBound])
            if let lastComma = beforeUser.lastIndex(of: ",") {
                uptimeStr = String(beforeUser[..<lastComma]).trimmingCharacters(in: .whitespaces)
            } else {
                uptimeStr = beforeUser.trimmingCharacters(in: .whitespaces)
            }
        } else if let comma = afterUp.firstIndex(of: ",") {
            uptimeStr = String(afterUp[..<comma]).trimmingCharacters(in: .whitespaces)
        }

        return parseUptimeDurationString(uptimeStr)
    }

    private func parseUptimeDurationString(_ str: String) -> TimeInterval? {
        let cleaned = str.trimmingCharacters(in: .whitespaces)
        guard !cleaned.isEmpty else { return nil }

        var totalSeconds: TimeInterval = 0
        var matched = false

        // Check if string contains comma-separated chunks like "3 days, 4:15" or "10 days, 23 min"
        let parts = cleaned.components(separatedBy: ",").map { $0.trimmingCharacters(in: .whitespaces) }

        for part in parts {
            if part.contains("day") {
                let digits = part.prefix(while: \.isNumber)
                if let days = Double(digits) {
                    totalSeconds += days * 86400
                    matched = true
                }
            } else if part.contains("min") {
                let digits = part.prefix(while: \.isNumber)
                if let mins = Double(digits) {
                    totalSeconds += mins * 60
                    matched = true
                }
            } else if part.contains("hr") || part.contains("hour") {
                let digits = part.prefix(while: \.isNumber)
                if let hrs = Double(digits) {
                    totalSeconds += hrs * 3600
                    matched = true
                }
            } else if part.contains("sec") {
                let digits = part.prefix(while: \.isNumber)
                if let secs = Double(digits) {
                    totalSeconds += secs
                    matched = true
                }
            } else if part.contains(":") {
                // Time format HH:MM
                let timeParts = part.split(separator: ":").map(String.init)
                if timeParts.count == 2, let h = Double(timeParts[0]), let m = Double(timeParts[1]) {
                    totalSeconds += (h * 3600) + (m * 60)
                    matched = true
                } else if timeParts.count == 3, let h = Double(timeParts[0]), let m = Double(timeParts[1]), let s = Double(timeParts[2]) {
                    totalSeconds += (h * 3600) + (m * 60) + s
                    matched = true
                }
            } else if let num = Double(part) {
                // Plain seconds or minutes fallback
                totalSeconds += num
                matched = true
            }
        }

        return matched ? totalSeconds : nil
    }

    private func parseUptimeLoadAverage(_ line: String) -> (Double, Double, Double)? {
        let markers = ["load averages:", "load average:", "load:"]
        for marker in markers {
            if let range = line.range(of: marker, options: .caseInsensitive) {
                let after = String(line[range.upperBound...])
                let tokens = after
                    .replacingOccurrences(of: ",", with: " ")
                    .split(whereSeparator: \.isWhitespace)
                    .compactMap { Double($0) }
                if tokens.count >= 3 {
                    return (tokens[0], tokens[1], tokens[2])
                }
            }
        }
        return nil
    }
}


