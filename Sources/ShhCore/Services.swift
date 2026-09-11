import Foundation
#if canImport(Security)
import Security
#endif

public enum TransportError: Error, Equatable, Sendable { case invalidConfiguration, authenticationRequired, hostKeyChanged(old: String, new: String), timeout, networkUnavailable, unsupported, cancelled, remoteFailure(String) }
public struct HostKeyChallenge: Sendable, Equatable { public var hostname: String; public var port: UInt16; public var algorithm: String; public var fingerprint: String; public init(hostname: String, port: UInt16, algorithm: String, fingerprint: String) { self.hostname = hostname; self.port = port; self.algorithm = algorithm; self.fingerprint = fingerprint } }
public enum TrustDecision: Sendable, Equatable { case trustOnce; case trustPermanently; case reject }
public protocol HostTrustEvaluator: Sendable { func evaluate(_ challenge: HostKeyChallenge) async -> TrustDecision }
public enum TerminalEvent: Sendable, Equatable { case bytes(Data); case closed; case error(TransportError) }
public protocol SSHConnection: Sendable { func events() async -> AsyncThrowingStream<TerminalEvent, Error>; func send(_ data: Data) async throws; func resize(_ size: TerminalSize) async throws; func close() async }
public protocol SSHTransport: Sendable { func connect(host: Host, identity: IdentityDescriptor?, trustEvaluator: any HostTrustEvaluator) async throws -> any SSHConnection }

public actor DemoSSHConnection: SSHConnection {
    private var continuation: AsyncThrowingStream<TerminalEvent, Error>.Continuation?
    public init() {}
    public func events() async -> AsyncThrowingStream<TerminalEvent, Error> {
        AsyncThrowingStream { continuation in
            Task { await self.install(continuation) }
        }
    }
    private func install(_ continuation: AsyncThrowingStream<TerminalEvent, Error>.Continuation) {
        self.continuation = continuation
        continuation.yield(.bytes(Data("Shh demo session ready. Type a command below.\\r\\n$ ".utf8)))
    }
    public func send(_ data: Data) async throws {
        continuation?.yield(.bytes(Data("\\r\\n[demo] ".utf8) + data + Data("\\r\\n$ ".utf8)))
    }
    public func resize(_ size: TerminalSize) async throws {}
    public func close() async { continuation?.yield(.closed); continuation?.finish() }
}
public struct DemoSSHTransport: SSHTransport {
    public init() {}
    public func connect(host: Host, identity: IdentityDescriptor?, trustEvaluator: any HostTrustEvaluator) async throws -> any SSHConnection {
        let challenge = HostKeyChallenge(hostname: host.hostname, port: host.port, algorithm: "ssh-ed25519", fingerprint: "SHA256:demo-fingerprint")
        guard await trustEvaluator.evaluate(challenge) != .reject else { throw TransportError.remoteFailure("Host key was rejected") }
        return DemoSSHConnection()
    }
}

public protocol CredentialStore: Sendable { func save(_ secret: Data, reference: String) async throws; func load(reference: String) async throws -> Data; func delete(reference: String) async throws }
public enum KeychainError: Error, Equatable, Sendable { case unavailable; case status(Int32) }
#if canImport(Security)
public struct KeychainCredentialStore: CredentialStore {
    private let service: String
    private let accessGroup: String?
    public init(service: String = "com.example.Shh.secrets", accessGroup: String? = nil) { self.service = service; self.accessGroup = accessGroup }
    private func baseQuery(reference: String) -> [CFString: Any] {
        var query: [CFString: Any] = [kSecClass: kSecClassGenericPassword, kSecAttrService: service, kSecAttrAccount: reference]
        if let accessGroup { query[kSecAttrAccessGroup] = accessGroup }
        return query
    }
    public func save(_ secret: Data, reference: String) async throws {
        var query = baseQuery(reference: reference); query[kSecValueData] = secret; query[kSecAttrAccessible] = kSecAttrAccessibleWhenUnlockedThisDeviceOnly
        SecItemDelete(baseQuery(reference: reference) as CFDictionary)
        let status = SecItemAdd(query as CFDictionary, nil); guard status == errSecSuccess else { throw KeychainError.status(status) }
    }
    public func load(reference: String) async throws -> Data {
        var query = baseQuery(reference: reference); query[kSecReturnData] = true; query[kSecMatchLimit] = kSecMatchLimitOne
        var result: CFTypeRef?; let status = SecItemCopyMatching(query as CFDictionary, &result)
        guard status == errSecSuccess, let data = result as? Data else { throw KeychainError.status(status) }; return data
    }
    public func delete(reference: String) async throws { let status = SecItemDelete(baseQuery(reference: reference) as CFDictionary); guard status == errSecSuccess || status == errSecItemNotFound else { throw KeychainError.status(status) } }
}
#else
public struct KeychainCredentialStore: CredentialStore {
    public init() {}
    public func save(_ secret: Data, reference: String) async throws { throw KeychainError.unavailable }
    public func load(reference: String) async throws -> Data { throw KeychainError.unavailable }
    public func delete(reference: String) async throws { throw KeychainError.unavailable }
}
#endif
public actor InMemoryCredentialStore: CredentialStore {
    private var values: [String: Data] = [:]
    public init() {}
    public func save(_ secret: Data, reference: String) async throws { values[reference] = secret }
    public func load(reference: String) async throws -> Data { guard let value = values[reference] else { throw TransportError.authenticationRequired }; return value }
    public func delete(reference: String) async throws { values.removeValue(forKey: reference) }
}

public actor InMemoryTrustStore: HostTrustEvaluator {
    private var records: [String: TrustRecord] = [:]
    public init() {}
    public func evaluate(_ challenge: HostKeyChallenge) async -> TrustDecision {
        let record = TrustRecord(hostname: challenge.hostname, port: challenge.port, keyAlgorithm: challenge.algorithm, sha256Fingerprint: challenge.fingerprint)
        if let old = records[record.lookupKey] {
            guard old.sha256Fingerprint == challenge.fingerprint else { return .reject }
            return .trustPermanently
        }
        return .trustOnce
    }
    public func save(_ challenge: HostKeyChallenge) { let record = TrustRecord(hostname: challenge.hostname, port: challenge.port, keyAlgorithm: challenge.algorithm, sha256Fingerprint: challenge.fingerprint); records[record.lookupKey] = record }
    public func allRecords() -> [TrustRecord] { Array(records.values) }
}

public struct Redactor: Sendable {
    public var secrets: [String]
    public init(secrets: [String] = []) { self.secrets = secrets.filter { !$0.isEmpty } }
    public func redact(_ value: String) -> String { secrets.reduce(value) { $0.replacingOccurrences(of: $1, with: "[REDACTED]") } }
}

public protocol HostRepository: Sendable { func listHosts() async throws -> [Host]; func save(_ host: Host) async throws; func delete(id: UUID) async throws }
public protocol CatalogRepository: HostRepository { func groups() async throws -> [Group]; func tags() async throws -> [Tag]; func identities() async throws -> [IdentityDescriptor]; func snippets() async throws -> [Snippet]; func save(_ group: Group) async throws; func save(_ tag: Tag) async throws; func save(_ identity: IdentityDescriptor) async throws; func save(_ snippet: Snippet) async throws }
public struct StoreMetadata: Codable, Hashable, Sendable { public static let currentSchemaVersion = 1; public var schemaVersion: Int; public init(schemaVersion: Int = StoreMetadata.currentSchemaVersion) { self.schemaVersion = schemaVersion } }
public struct CatalogSnapshot: Codable, Sendable { public var metadata: StoreMetadata; public var hosts: [Host]; public var groups: [Group]; public var tags: [Tag]; public var identities: [IdentityDescriptor]; public var snippets: [Snippet]; public init(metadata: StoreMetadata = StoreMetadata(), hosts: [Host] = [], groups: [Group] = [], tags: [Tag] = [], identities: [IdentityDescriptor] = [], snippets: [Snippet] = []) { self.metadata = metadata; self.hosts = hosts; self.groups = groups; self.tags = tags; self.identities = identities; self.snippets = snippets } }
public actor InMemoryCatalog: CatalogRepository {
    private var hostValues: [UUID: Host] = [:]; private var groupValues: [UUID: Group] = [:]; private var tagValues: [UUID: Tag] = [:]; private var identityValues: [UUID: IdentityDescriptor] = [:]; private var snippetValues: [UUID: Snippet] = [:]
    public init(seedDemoData: Bool = true) {
        guard seedDemoData else { return }
        let group = try? Group(name: "Development", sortOrder: 0); let tag = try? Tag(name: "iPad", color: "teal"); let identity = try? IdentityDescriptor(name: "Demo Key", kind: .privateKey, publicFingerprint: "SHA256:demo", keychainReference: "kc-demo")
        if let group, let tag, let identity, let host = try? Host(name: "Demo Workbox", hostname: "demo.invalid", username: "dev", groupID: group.id, tagIDs: [tag.id], identityID: identity.id) { groupValues[group.id] = group; tagValues[tag.id] = tag; identityValues[identity.id] = identity; hostValues[host.id] = host }
        if let snippet = try? Snippet(name: "List files", body: "ls -la") { snippetValues[snippet.id] = snippet }
    }
    public func listHosts() async throws -> [Host] { hostValues.values.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending } }
    public func save(_ host: Host) async throws { hostValues[host.id] = host }
    public func delete(id: UUID) async throws { hostValues.removeValue(forKey: id) }
    public func groups() async throws -> [Group] { groupValues.values.sorted { $0.sortOrder < $1.sortOrder } }
    public func tags() async throws -> [Tag] { tagValues.values.sorted { $0.name < $1.name } }
    public func identities() async throws -> [IdentityDescriptor] { Array(identityValues.values) }
    public func snippets() async throws -> [Snippet] { snippetValues.values.sorted { $0.name < $1.name } }
    public func save(_ group: Group) async throws { groupValues[group.id] = group }
    public func save(_ tag: Tag) async throws { tagValues[tag.id] = tag }
    public func save(_ identity: IdentityDescriptor) async throws { identityValues[identity.id] = identity }
    public func save(_ snippet: Snippet) async throws { snippetValues[snippet.id] = snippet }
    public func snapshot() -> CatalogSnapshot { CatalogSnapshot(hosts: Array(hostValues.values), groups: Array(groupValues.values), tags: Array(tagValues.values), identities: Array(identityValues.values), snippets: Array(snippetValues.values)) }
}

public struct TerminalCell: Hashable, Sendable { public var character: Character; public var inverse: Bool; public init(character: Character = " ", inverse: Bool = false) { self.character = character; self.inverse = inverse } }
public struct TerminalGrid: Sendable {
    public private(set) var size: TerminalSize; public private(set) var rows: [[TerminalCell]]; public private(set) var cursorColumn = 0; public private(set) var cursorRow = 0; public private(set) var scrollback: [[TerminalCell]] = []; public var scrollbackLimit: Int = 500
    public init(size: TerminalSize = TerminalSize(), scrollbackLimit: Int = 500) { self.size = size; self.scrollbackLimit = scrollbackLimit; self.rows = Array(repeating: Array(repeating: TerminalCell(), count: size.columns), count: size.rows) }
    public mutating func resize(_ newSize: TerminalSize) { size = newSize; rows = rows.prefix(newSize.rows).map { Array($0.prefix(newSize.columns)) + Array(repeating: TerminalCell(), count: max(0, newSize.columns - $0.count)) }; while rows.count < newSize.rows { rows.append(Array(repeating: TerminalCell(), count: newSize.columns)) }; cursorColumn = min(cursorColumn, newSize.columns - 1); cursorRow = min(cursorRow, newSize.rows - 1) }
    public mutating func put(_ character: Character) { guard character != "\n" && character != "\r" else { return }; if cursorColumn >= size.columns { newline() }; rows[cursorRow][cursorColumn] = TerminalCell(character: character); cursorColumn += 1 }
    public mutating func newline() { scrollback.append(rows.removeFirst()); if scrollback.count > scrollbackLimit { scrollback.removeFirst() }; rows.append(Array(repeating: TerminalCell(), count: size.columns)); cursorColumn = 0; cursorRow = min(cursorRow + 1, size.rows - 1) }
    public mutating func carriageReturn() { cursorColumn = 0 }
    public mutating func backspace() { cursorColumn = max(0, cursorColumn - 1) }
    public mutating func clear() { rows = Array(repeating: Array(repeating: TerminalCell(), count: size.columns), count: size.rows); cursorColumn = 0; cursorRow = 0 }
    public var plainText: String { rows.map { String($0.map(\.character)) }.joined(separator: "\n") }
}

public struct ANSIParser: Sendable {
    public init() {}
    public mutating func consume(_ data: Data, into grid: inout TerminalGrid) {
        let text = String(decoding: data, as: UTF8.self); var iterator = text.makeIterator(); var escape = false; var bracket = false; var parameter = ""
        while let character = iterator.next() {
            if escape {
                if character == "[" { bracket = true; parameter = ""; continue }
                if bracket {
                    if character.isNumber || character == ";" { parameter.append(character); continue }
                    if character == "H" || character == "f" { grid.carriageReturn(); continue }
                    if character == "J" { grid.clear(); escape = false; bracket = false; continue }
                    escape = false; bracket = false; continue
                }
                escape = false; continue
            }
            if character == "\u{1B}" { escape = true; continue }
            switch character { case "\n": grid.newline(); case "\r": grid.carriageReturn(); case "\u{08}": grid.backspace(); default: grid.put(character) }
        }
    }
}

public struct ShellQuoting: Sendable {
    public static func quote(_ value: String) -> String { "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'" }
}
public enum MultiplexerAction: Hashable, Sendable { case list; case attach(name: String); case create(name: String); case send(text: String) }
public protocol MultiplexerAdapter: Sendable { var kind: RemoteMultiplexer { get }; func command(for action: MultiplexerAction) -> String }
public struct TmuxAdapter: MultiplexerAdapter { public let kind = RemoteMultiplexer.tmux; public init() {}; public func command(for action: MultiplexerAction) -> String { switch action { case .list: "tmux list-sessions"; case .attach(let name): "tmux attach-session -t \(ShellQuoting.quote(name))"; case .create(let name): "tmux new-session -A -s \(ShellQuoting.quote(name))"; case .send(let text): "tmux send-keys -t \"${TMUX_PANE}\" -- \(ShellQuoting.quote(text)) Enter" } } }
public struct UnavailableMultiplexerAdapter: MultiplexerAdapter { public let kind: RemoteMultiplexer; public init(kind: RemoteMultiplexer) { self.kind = kind }; public func command(for action: MultiplexerAction) -> String { "# \(kind.rawValue) is not enabled in this build" } }

public enum HerdrCommand: Hashable, Sendable { case remoteLaunch(workbox: String); case workspaceCreate(name: String); case tabCreate(name: String); case paneSplit(direction: String); case paneRun(command: String); case paneRead; case waitAgentStatus }
public extension HerdrCommand { var renderedCommand: String { switch self { case .remoteLaunch(let workbox): "herdr --remote \(ShellQuoting.quote(workbox))"; case .workspaceCreate(let name): "herdr workspace create \(ShellQuoting.quote(name))"; case .tabCreate(let name): "herdr tab create \(ShellQuoting.quote(name))"; case .paneSplit(let direction): "herdr pane split \(ShellQuoting.quote(direction))"; case .paneRun(let command): "herdr pane run \(ShellQuoting.quote(command))"; case .paneRead: "herdr pane read"; case .waitAgentStatus: "herdr wait agent-status" } } }

public enum CommandRisk: String, Equatable, Sendable { case safe, reviewRequired, blocked }
public struct CommandPolicy: Sendable {
    public init() {}
    public func classify(_ command: String) -> CommandRisk {
        let lower = command.lowercased().replacingOccurrences(of: " ", with: "")
        if lower.contains("rm-rf/") || lower.contains(":(){:|:&};:") { return .blocked }
        if ["shutdown", "reboot", "mkfs", "ddif=", "curl|sh", "wget|sh"].contains(where: { lower.contains($0) }) { return .reviewRequired }
        return .safe
    }
    public func canSend(_ command: String, approved: Bool) -> Bool { classify(command) == .safe || approved }
}

public struct RemotePath: Hashable, Codable, Sendable, CustomStringConvertible {
    public let components: [String]
    public init(_ raw: String) { components = raw.split(separator: "/", omittingEmptySubsequences: true).reduce(into: []) { result, part in if part == ".." { if !result.isEmpty { result.removeLast() } } else if part != "." { result.append(String(part)) } } }
    public var description: String { "/" + components.joined(separator: "/") }
}
public struct RemoteFile: Identifiable, Hashable, Sendable { public let id: String; public var name: String; public var isDirectory: Bool; public var size: Int64; public init(name: String, isDirectory: Bool, size: Int64 = 0) { self.id = name; self.name = name; self.isDirectory = isDirectory; self.size = size } }
public protocol RemoteFileRepository: Sendable { func list(at path: RemotePath) async throws -> [RemoteFile] }
public struct UnavailableFileRepository: RemoteFileRepository { public init() {}; public func list(at path: RemotePath) async throws -> [RemoteFile] { throw TransportError.unsupported } }

public protocol HealthChecking: Sendable { func check(_ host: Host) async -> HealthState }
public struct DemoHealthChecker: HealthChecking { public init() {}; public func check(_ host: Host) async -> HealthState { .unknown } }
public protocol ForwardingService: Sendable { func start(_ rule: ForwardingRule, for host: Host) async throws; func stop(_ rule: ForwardingRule) async }
public struct UnavailableForwardingService: ForwardingService { public init() {}; public func start(_ rule: ForwardingRule, for host: Host) async throws { throw TransportError.unsupported }; public func stop(_ rule: ForwardingRule) async {} }
public protocol SyncService: Sendable { func synchronize() async throws }
public struct UnavailableSyncService: SyncService { public init() {}; public func synchronize() async throws { throw TransportError.unsupported } }
public protocol AudioRecorder: Sendable { func start() async throws; func stop() async throws -> Data; func cancel() async }
public struct UnavailableAudioRecorder: AudioRecorder { public init() {}; public func start() async throws { throw TranscriptionError.modelUnavailable }; public func stop() async throws -> Data { throw TranscriptionError.modelUnavailable }; public func cancel() async {} }

public actor SessionCoordinator {
    private var sessions: [UUID: TerminalSession] = [:]
    public init() {}
    public func begin(hostID: UUID) -> TerminalSession { let session = TerminalSession(hostID: hostID); sessions[session.id] = session; return session }
    public func update(_ session: TerminalSession) { guard sessions[session.id] != nil else { return }; sessions[session.id] = session }
    public func end(id: UUID) { sessions[id]?.state = .disconnected }
    public func current() -> [TerminalSession] { Array(sessions.values) }
}

public enum SpeechComposerState: Equatable, Sendable { case idle; case recording; case transcribing; case preview(text: String); case unavailable; case cancelled }
public enum TranscriptionError: Error, Equatable, Sendable { case modelUnavailable; case cancelled }
public protocol LocalTranscriber: Sendable { func transcribe(audio: Data) async throws -> String }
public struct UnavailableTranscriber: LocalTranscriber { public init() {}; public func transcribe(audio: Data) async throws -> String { throw TranscriptionError.modelUnavailable } }
