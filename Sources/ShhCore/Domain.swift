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
public struct ProxyJumpOptions: Codable, Hashable, Sendable { public var hopHostIDs: [UUID]; public init(hopHostIDs: [UUID] = []) { self.hopHostIDs = hopHostIDs } }
public enum ConnectionProfile: Codable, Hashable, Sendable { case ssh(SSHOptions); case mosh(MoshOptions); case proxyJump(ProxyJumpOptions) }

public enum HealthState: Codable, Hashable, Sendable {
    case unknown, checking, healthy, degraded(reason: String), offline
    public var label: String {
        switch self { case .unknown: "Unknown"; case .checking: "Checking"; case .healthy: "Healthy"; case .degraded(let reason): "Degraded: \(reason)"; case .offline: "Offline" }
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
    public init(id: UUID = UUID(), name: String, hostname: String, port: UInt16 = 22, username: String, groupID: UUID? = nil, tagIDs: Set<UUID> = [], identityID: UUID? = nil, connection: ConnectionProfile = .ssh(SSHOptions()), health: HealthState = .unknown, lastUsedAt: Date? = nil) throws {
        guard !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw ShhValidationError.empty(field: "host name") }
        guard !hostname.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw ShhValidationError.empty(field: "hostname") }
        guard !username.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw ShhValidationError.empty(field: "username") }
        guard port != 0 else { throw ShhValidationError.invalidPort }
        self.id = id; self.name = name; self.hostname = hostname; self.port = port; self.username = username
        self.groupID = groupID; self.tagIDs = tagIDs; self.identityID = identityID; self.connection = connection
        self.health = health; self.lastUsedAt = lastUsedAt
    }
    public var address: String { "\(username)@\(hostname):\(port)" }
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

public enum RemoteMultiplexer: String, Codable, CaseIterable, Sendable { case tmux, zellij, byobu, screen }
public enum CapabilityAvailability: Codable, Hashable, Sendable { case available; case unavailable(reason: String) }
public struct CapabilityMatrix: Codable, Hashable, Sendable {
    public var mosh: CapabilityAvailability = .unavailable(reason: "Not enabled in this build")
    public var proxyJump: CapabilityAvailability = .unavailable(reason: "Not enabled in this build")
    public var forwarding: CapabilityAvailability = .unavailable(reason: "Not enabled in this build")
    public var sftp: CapabilityAvailability = .unavailable(reason: "Not enabled in this build")
    public var tmux: CapabilityAvailability = .unavailable(reason: "Not enabled in this build")
    public init() {}
}
