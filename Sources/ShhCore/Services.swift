import Foundation
#if canImport(Security)
import Security
#endif

public enum TransportError: Error, Equatable, Sendable { case invalidConfiguration, authenticationRequired, hostKeyChanged(old: String, new: String), hostKeyApprovalRequired(HostKeyChallenge), timeout, networkUnavailable, unsupported, cancelled, remoteFailure(String) }
public struct HostKeyChallenge: Sendable, Equatable, Identifiable {
    public var hostname: String
    public var port: UInt16
    public var algorithm: String
    public var fingerprint: String
    public init(hostname: String, port: UInt16, algorithm: String, fingerprint: String) {
        self.hostname = TrustRecord.canonicalHost(hostname); self.port = port; self.algorithm = algorithm; self.fingerprint = fingerprint
    }
    public var id: String { "\(hostname):\(port):\(algorithm.lowercased()):\(fingerprint)" }
}
public enum TrustStatus: Equatable, Sendable { case unknown; case trusted; case changed(oldFingerprint: String) }
public enum TrustDecision: Sendable, Equatable { case trustOnce; case trustPermanently; case reject }
public protocol HostTrustEvaluator: Sendable {
    func status(for challenge: HostKeyChallenge) async -> TrustStatus
    func evaluate(_ challenge: HostKeyChallenge) async -> TrustDecision
}
public enum TerminalEvent: Sendable, Equatable { case bytes(Data); case closed; case error(TransportError) }
public protocol SSHConnection: Sendable { func events() async -> AsyncThrowingStream<TerminalEvent, Error>; func send(_ data: Data) async throws; func resize(_ size: TerminalSize) async throws; func close() async }
public protocol SSHTransport: Sendable {
    func connect(host: Host, identity: IdentityDescriptor?, trustEvaluator: any HostTrustEvaluator, initialSize: TerminalSize) async throws -> any SSHConnection
}

public extension SSHTransport {
    func connect(host: Host, identity: IdentityDescriptor?, trustEvaluator: any HostTrustEvaluator, initialSize: TerminalSize = TerminalSize(columns: 80, rows: 24)) async throws -> any SSHConnection {
        try await connect(host: host, identity: identity, trustEvaluator: trustEvaluator, initialSize: initialSize)
    }
}

public actor DemoSSHConnection: SSHConnection, SSHCommandExecuting {
    private var continuation: AsyncThrowingStream<TerminalEvent, Error>.Continuation?
    private var commandHandler: (@Sendable (String) -> SSHCommandResult)?

    public init(commandHandler: (@Sendable (String) -> SSHCommandResult)? = nil) {
        self.commandHandler = commandHandler
    }

    public func setCommandHandler(_ handler: (@Sendable (String) -> SSHCommandResult)?) {
        self.commandHandler = handler
    }

    public func events() async -> AsyncThrowingStream<TerminalEvent, Error> {
        AsyncThrowingStream { continuation in
            Task { self.install(continuation) }
        }
    }
    private func install(_ continuation: AsyncThrowingStream<TerminalEvent, Error>.Continuation) {
        self.continuation = continuation
        continuation.yield(.bytes(Data("Shh demo session ready. Type a command below.\r\n$ ".utf8)))
    }
    public func send(_ data: Data) async throws {
        continuation?.yield(.bytes(Data("\r\n[demo] ".utf8) + data + Data("\r\n$ ".utf8)))
    }
    public func resize(_ size: TerminalSize) async throws {}
    public func close() async { continuation?.yield(.closed); continuation?.finish() }

    public func executeCommand(_ command: String) async throws -> SSHCommandResult {
        try await executeCommand(command, timeout: nil, maxOutputBytes: nil)
    }

    public func executeCommand(
        _ command: String,
        timeout: TimeInterval?,
        maxOutputBytes: Int?
    ) async throws -> SSHCommandResult {
        if let commandHandler {
            let res = commandHandler(command)
            if let maxOutputBytes, res.stdout.utf8.count + res.stderr.utf8.count > maxOutputBytes {
                throw TransportError.remoteFailure("Command output exceeded maximum allowed size of \(maxOutputBytes) bytes")
            }
            return res
        }

        let trimmed = command.trimmingCharacters(in: .whitespacesAndNewlines)
        let result: SSHCommandResult
        if trimmed == TmuxCommand.probe || trimmed == "tmux -V" {
            result = SSHCommandResult(exitCode: 0, stdout: "tmux 3.4\n", stderr: "")
        } else if trimmed == TmuxCommand.listSessions || trimmed.contains("list-sessions") {
            let sample = "$0\tdefault\t1\t1700000000\t1700000000\t1\n"
            result = SSHCommandResult(exitCode: 0, stdout: sample, stderr: "")
        } else if trimmed.contains("has-session") {
            if trimmed.contains("$0") || trimmed.contains("default") {
                result = SSHCommandResult(exitCode: 0, stdout: "", stderr: "")
            } else {
                result = SSHCommandResult(exitCode: 1, stdout: "", stderr: "can't find session\n")
            }
        } else {
            result = SSHCommandResult(exitCode: 0, stdout: "[demo] \(command)\n", stderr: "")
        }

        if let maxOutputBytes, result.stdout.utf8.count + result.stderr.utf8.count > maxOutputBytes {
            throw TransportError.remoteFailure("Command output exceeded maximum allowed size of \(maxOutputBytes) bytes")
        }
        return result
    }
}
public struct DemoSSHTransport: SSHTransport {
    public init() {}
    public func connect(host: Host, identity: IdentityDescriptor?, trustEvaluator: any HostTrustEvaluator, initialSize: TerminalSize = TerminalSize(columns: 80, rows: 24)) async throws -> any SSHConnection {
        let challenge = HostKeyChallenge(hostname: host.hostname, port: host.port, algorithm: "ssh-ed25519", fingerprint: "SHA256:demo-fingerprint")
        guard await trustEvaluator.evaluate(challenge) != .reject else {
            switch await trustEvaluator.status(for: challenge) {
            case .unknown:
                if case .ssh(let options) = host.connection, options.strictHostKeyChecking == .trustedOnly {
                    throw TransportError.remoteFailure("Host key is not trusted")
                }
                throw TransportError.hostKeyApprovalRequired(challenge)
            case .changed(let oldFingerprint):
                throw TransportError.hostKeyChanged(old: oldFingerprint, new: challenge.fingerprint)
            case .trusted:
                break
            }
            throw TransportError.remoteFailure("Host key was rejected")
        }
        return DemoSSHConnection()
    }
}

public protocol CredentialStore: Sendable { func save(_ secret: Data, reference: String) async throws; func load(reference: String) async throws -> Data; func delete(reference: String) async throws }
public enum KeychainError: Error, Equatable, Sendable { case unavailable; case status(Int32) }
#if canImport(Security)
public struct KeychainCredentialStore: CredentialStore {
    private let service: String
    private let accessGroup: String?
    public init(service: String = "com.ervinpopescu.shh.secrets", accessGroup: String? = nil) { self.service = service; self.accessGroup = accessGroup }
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
    private var oneTimeRecords: Set<String> = []
    public init() {}
    public func evaluate(_ challenge: HostKeyChallenge) async -> TrustDecision {
        switch status(for: challenge) {
        case .trusted: return .trustPermanently
        case .changed: return .reject
        case .unknown:
            guard oneTimeRecords.remove(challenge.id) != nil else { return .reject }
            return .trustOnce
        }
    }
    public func status(for challenge: HostKeyChallenge) -> TrustStatus {
        let record = TrustRecord(hostname: challenge.hostname, port: challenge.port, keyAlgorithm: challenge.algorithm, sha256Fingerprint: challenge.fingerprint)
        guard let old = records[record.lookupKey] else { return .unknown }
        return old.sha256Fingerprint == challenge.fingerprint ? .trusted : .changed(oldFingerprint: old.sha256Fingerprint)
    }
    public func trustOnce(_ challenge: HostKeyChallenge) { oneTimeRecords.insert(challenge.id) }
    public func save(_ challenge: HostKeyChallenge) {
        let record = TrustRecord(hostname: challenge.hostname, port: challenge.port, keyAlgorithm: challenge.algorithm, sha256Fingerprint: challenge.fingerprint)
        records[record.lookupKey] = record
        oneTimeRecords.remove(challenge.id)
    }
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
    public mutating func moveCursor(row: Int, column: Int) {
        cursorRow = min(max(0, row), size.rows - 1)
        cursorColumn = min(max(0, column), size.columns - 1)
    }
    public mutating func backspace() { cursorColumn = max(0, cursorColumn - 1) }
    public mutating func clear() { rows = Array(repeating: Array(repeating: TerminalCell(), count: size.columns), count: size.rows); cursorColumn = 0; cursorRow = 0 }
    public var plainText: String { rows.map { String($0.map(\.character)) }.joined(separator: "\n") }
    public var transcriptText: String { (scrollback + rows).map { String($0.map(\.character)) }.joined(separator: "\n") }
}

public struct ANSIParser: Sendable {
    private var escape = false
    private var bracket = false
    private var parameter = ""
    public init() {}
    public mutating func consume(_ data: Data, into grid: inout TerminalGrid) {
        let text = String(decoding: data, as: UTF8.self)
        for character in text {
            if escape {
                if character == "[" { bracket = true; parameter = ""; continue }
                if bracket {
                    if character.isNumber || character == ";" { parameter.append(character); continue }
                    let values = parameter.split(separator: ";", omittingEmptySubsequences: false).map { Int($0) ?? 0 }
                    switch character {
                    case "H", "f":
                        let row = max(1, values.first ?? 1) - 1
                        let column = max(1, values.dropFirst().first ?? 1) - 1
                        grid.moveCursor(row: row, column: column)
                    case "J": grid.clear()
                    default: break
                    }
                    escape = false; bracket = false; parameter = ""; continue
                }
                escape = false
                continue
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
public struct TmuxAdapter: MultiplexerAdapter {
    public let kind = RemoteMultiplexer.tmux
    public init() {}
    public func command(for action: MultiplexerAction) -> String {
        switch action {
        case .list:
            return TmuxCommand.listSessions
        case .attach(let name):
            if let sessionID = try? TmuxSessionID(name) {
                return TmuxCommand.attachSession(id: sessionID)
            }
            return "env -u TMUX tmux attach-session -d -t \(ShellQuoting.quote(name))"
        case .create(let name):
            if let sessionName = try? TmuxSessionName(name) {
                return TmuxCommand.newSession(name: sessionName)
            }
            return "tmux new-session -A -D -s \(ShellQuoting.quote(name))"
        case .send(let text):
            return "tmux send-keys -t \"${TMUX_PANE}\" -- \(ShellQuoting.quote(text)) Enter"
        }
    }
}
public struct UnavailableMultiplexerAdapter: MultiplexerAdapter { public let kind: RemoteMultiplexer; public init(kind: RemoteMultiplexer) { self.kind = kind }; public func command(for action: MultiplexerAction) -> String { "# \(kind.rawValue) is not enabled in this build" } }

public enum HerdrCommand: Hashable, Sendable { case remoteLaunch(workbox: String); case workspaceCreate(name: String); case tabCreate(name: String); case paneSplit(direction: String); case paneRun(command: String); case paneRead; case waitAgentStatus }
public extension HerdrCommand { var renderedCommand: String { switch self { case .remoteLaunch(let workbox): "herdr --remote \(ShellQuoting.quote(workbox))"; case .workspaceCreate(let name): "herdr workspace create \(ShellQuoting.quote(name))"; case .tabCreate(let name): "herdr tab create \(ShellQuoting.quote(name))"; case .paneSplit(let direction): "herdr pane split \(ShellQuoting.quote(direction))"; case .paneRun(let command): "herdr pane run \(ShellQuoting.quote(command))"; case .paneRead: "herdr pane read"; case .waitAgentStatus: "herdr wait agent-status" } } }

public enum CommandRisk: String, Equatable, Sendable { case safe, reviewRequired, blocked }

private struct ShellToken {
    let value: String
    let isOperator: Bool
}

private struct ShellLexResult {
    let tokens: [ShellToken]
    let hasUnsupportedSyntax: Bool
    let isBalanced: Bool
    let commandSubstitutions: [String]
}

/// A deliberately small shell lexer, not a shell interpreter. It understands quoting and
/// command separators so policy decisions do not depend on whitespace or flag spelling. Shell
/// expansion, aliases, functions, and platform-specific command behavior remain outside its
/// model; those cases are sent to review instead of being treated as safe.
private enum ShellTokenizer {
    static func tokenize(_ source: String) -> ShellLexResult {
        let characters = Array(source)
        var tokens: [ShellToken] = []
        var word = ""
        var quote: Character?
        var unsupported = false
        var index = 0
        let commandSubstitutions = commandSubstitutions(in: source)

        func flushWord() {
            guard !word.isEmpty else { return }
            tokens.append(ShellToken(value: word, isOperator: false))
            word = ""
        }

        while index < characters.count {
            let character = characters[index]
            if let activeQuote = quote {
                if character == activeQuote {
                    quote = nil
                } else if activeQuote == "'" {
                    word.append(character)
                } else if character == "\\" {
                    guard index + 1 < characters.count else {
                        unsupported = true
                        break
                    }
                    index += 1
                    word.append(characters[index])
                } else {
                    if character == "$" || (activeQuote == "\"" && character == "`") { unsupported = true }
                    word.append(character)
                }
                index += 1
                continue
            }

            if character == "'" || character == "\"" {
                quote = character
                index += 1
                continue
            }
            if character == "\\" {
                guard index + 1 < characters.count else {
                    unsupported = true
                    break
                }
                index += 1
                word.append(characters[index])
                index += 1
                continue
            }
            if character.isWhitespace {
                flushWord()
                // A newline is a command separator, unlike spaces and tabs.
                if character == "\n" || character == "\r" {
                    tokens.append(ShellToken(value: ";", isOperator: true))
                }
                index += 1
                continue
            }
            if character == "$" {
                unsupported = true
                word.append(character)
                index += 1
                continue
            }
            if character == "`" {
                flushWord()
                tokens.append(ShellToken(value: "`", isOperator: true))
                unsupported = true
                index += 1
                continue
            }
            if "|;&><(){}".contains(character) {
                flushWord()
                var operation = String(character)
                if index + 1 < characters.count {
                    let next = characters[index + 1]
                    if (character == "|" && next == "|") || (character == "&" && next == "&") ||
                        (character == ">" && next == ">") || (character == "<" && next == "<") ||
                        (character == "&" && next == ">") {
                        operation.append(next)
                        index += 1
                    }
                }
                tokens.append(ShellToken(value: operation, isOperator: true))
                index += 1
                continue
            }
            if character == "#" && word.isEmpty {
                unsupported = true
            }
            word.append(character)
            index += 1
        }

        flushWord()
        return ShellLexResult(
            tokens: tokens,
            hasUnsupportedSyntax: unsupported,
            isBalanced: quote == nil,
            commandSubstitutions: commandSubstitutions
        )
    }

    static func commandSubstitutions(in source: String) -> [String] {
        let characters = Array(source)
        var substitutions: [String] = []
        var quote: Character?
        var index = 0

        while index < characters.count {
            let character = characters[index]
            if let activeQuote = quote {
                if character == "\\" && activeQuote == "\"" {
                    index += 2
                    continue
                }
                if character == activeQuote {
                    quote = nil
                    index += 1
                    continue
                }
                if activeQuote == "\"" {
                    if character == "$", index + 1 < characters.count, characters[index + 1] == "(" {
                        if let (body, endIndex) = parenthesizedBody(in: characters, openingIndex: index + 1) {
                            substitutions.append(body)
                            index = endIndex + 1
                            continue
                        }
                    }
                    if character == "`", let (body, endIndex) = backtickBody(in: characters, openingIndex: index) {
                        substitutions.append(body)
                        index = endIndex + 1
                        continue
                    }
                }
                index += 1
                continue
            }

            if character == "'" || character == "\"" {
                quote = character
                index += 1
                continue
            }
            if character == "\\" {
                index += 2
                continue
            }
            if character == "$", index + 1 < characters.count, characters[index + 1] == "(" {
                if let (body, endIndex) = parenthesizedBody(in: characters, openingIndex: index + 1) {
                    substitutions.append(body)
                    index = endIndex + 1
                    continue
                }
            }
            if character == "`", let (body, endIndex) = backtickBody(in: characters, openingIndex: index) {
                substitutions.append(body)
                index = endIndex + 1
                continue
            }
            index += 1
        }
        return substitutions
    }

    static func tmuxFormatCommands(in source: String) -> [String] {
        let characters = Array(source)
        var commands: [String] = []
        var index = 0
        while index + 1 < characters.count {
            guard characters[index] == "#", characters[index + 1] == "(" else {
                index += 1
                continue
            }
            if let (body, endIndex) = parenthesizedBody(in: characters, openingIndex: index + 1) {
                commands.append(body)
                index = endIndex + 1
            } else {
                index += 2
            }
        }
        return commands
    }

    private static func parenthesizedBody(in characters: [Character], openingIndex: Int) -> (String, Int)? {
        var depth = 1
        var quote: Character?
        var index = openingIndex + 1
        while index < characters.count {
            let character = characters[index]
            if let activeQuote = quote {
                if character == "\\" {
                    index += 2
                    continue
                }
                if character == activeQuote { quote = nil }
                index += 1
                continue
            }
            if character == "'" || character == "\"" {
                quote = character
            } else if character == "\\" {
                index += 2
                continue
            } else if character == "(" {
                depth += 1
            } else if character == ")" {
                depth -= 1
                if depth == 0 {
                    return (String(characters[(openingIndex + 1)..<index]), index)
                }
            }
            index += 1
        }
        return nil
    }

    private static func backtickBody(in characters: [Character], openingIndex: Int) -> (String, Int)? {
        var index = openingIndex + 1
        while index < characters.count {
            if characters[index] == "\\" {
                index += 2
                continue
            }
            if characters[index] == "`" {
                return (String(characters[(openingIndex + 1)..<index]), index)
            }
            index += 1
        }
        return nil
    }
}

public struct CommandPolicy: Sendable {
    private static let safeCommands: Set<String> = [
        "[", "basename", "cat", "cd", "command", "cut", "date", "dirname", "df", "du", "echo",
        "false", "file", "free", "git", "grep", "groups", "head", "help", "hostname", "id", "less",
        "ls", "man", "more", "printf", "pwd", "realpath", "readlink", "rg", "sort", "stat", "tail",
        "test", "tmux", "tree", "true", "tty", "uname", "uniq", "uptime", "whoami", "which", "wc"
    ]
    private static let shellInterpreters: Set<String> = ["ash", "bash", "dash", "fish", "ksh", "sh", "zsh"]
    private static let commandWrappers: Set<String> = ["builtin", "command", "env", "exec", "nice", "nohup", "sudo", "timeout", "xargs"]
    private static let diskCommands: Set<String> = [
        "blkdiscard", "diskutil", "fdisk", "format", "gdisk", "mkfs", "mkswap", "parted", "sfdisk", "shred", "wipefs"
    ]

    public init() {}

    public func classify(_ command: String) -> CommandRisk {
        let lexed = ShellTokenizer.tokenize(commandWithoutTrailingLineEndings(command))
        guard lexed.isBalanced, !lexed.tokens.isEmpty else { return .reviewRequired }

        if isForkBomb(lexed.tokens) { return .blocked }
        let segments = splitIntoSegments(lexed.tokens)
        let substitutionRisk = commandSubstitutionRisk(lexed.commandSubstitutions)
        if substitutionRisk == .blocked { return .blocked }
        var sawReview = lexed.hasUnsupportedSyntax || substitutionRisk == .reviewRequired
        var sawCompoundCommand = false

        for token in lexed.tokens where token.isOperator {
            if ["|", "||", "&&", ";", "&", "`", "(", ")", "{", "}"].contains(token.value) {
                sawCompoundCommand = true
            }
        }
        sawReview = sawReview || sawCompoundCommand

        for segment in segments {
            switch classifySegment(segment) {
            case .blocked: return .blocked
            case .reviewRequired: sawReview = true
            case .safe: break
            }
        }
        return sawReview ? .reviewRequired : .safe
    }

    public func canSend(_ command: String, approved: Bool) -> Bool {
        switch classify(command) {
        case .safe: return true
        case .reviewRequired: return approved
        case .blocked: return false
        }
    }

    private func commandWithoutTrailingLineEndings(_ command: String) -> String {
        var normalized = command
        while let last = normalized.last {
            if last != "\n" && last != "\r" { break }
            normalized.removeLast()
        }
        return normalized
    }

    private func splitIntoSegments(_ tokens: [ShellToken]) -> [[ShellToken]] {
        var result: [[ShellToken]] = [[]]
        for token in tokens {
            if token.isOperator && ["|", "||", "&&", ";", "&", "`", "(", ")", "{", "}"].contains(token.value) {
                if !result[result.count - 1].isEmpty { result.append([]) }
            } else {
                result[result.count - 1].append(token)
            }
        }
        return result.filter { !$0.isEmpty }
    }

    private func classifySegment(_ segment: [ShellToken]) -> CommandRisk {
        let words = segment.filter { !$0.isOperator }.map(\.value)
        guard let executableIndex = executableIndex(in: words) else { return .reviewRequired }
        let executable = commandName(words[executableIndex])
        let arguments = Array(words.dropFirst(executableIndex + 1))

        if executable == "rm" {
            return rmRisk(arguments)
        }
        if executable == "dd" {
            return ddRisk(arguments)
        }
        if Self.diskCommands.contains(executable) || executable.hasPrefix("mkfs.") {
            return diskRisk(executable: executable, arguments: arguments)
        }
        if executable == "chmod" || executable == "chown" {
            return systemPathRisk(arguments: arguments, recursiveFlag: arguments.contains { $0 == "-R" || $0 == "-r" || $0 == "--recursive" })
        }
        if executable == "find" {
            return findRisk(arguments)
        }
        if executable == "shutdown" || executable == "reboot" || executable == "poweroff" || executable == "halt" || executable == "init" || executable == "systemctl" || executable == "kill" {
            return .reviewRequired
        }
        if Self.shellInterpreters.contains(executable) {
            return interpreterRisk(arguments)
        }
        if executable == "tmux" {
            let risk = tmuxRisk(arguments)
            if risk == .blocked { return .blocked }
            if words.prefix(executableIndex).contains(where: { commandName($0) == "sudo" }) {
                return .reviewRequired
            }
            return risk
        }
        if executable == "python" || executable == "python3" || executable == "perl" || executable == "ruby" || executable == "node" {
            return .reviewRequired
        }
        if executable == "curl" || executable == "wget" {
            return .reviewRequired
        }
        if words.prefix(executableIndex).contains(where: { commandName($0) == "sudo" }) {
            return .reviewRequired
        }
        if executable == "sudo" { return .reviewRequired }
        if executable == "eval" {
            let nested = classify(arguments.joined(separator: " "))
            return nested == .blocked ? .blocked : .reviewRequired
        }
        if !Self.safeCommands.contains(executable) { return .reviewRequired }
        if executable == "git" { return gitRisk(arguments) }

        // Redirection is intentionally never considered safe, even for a normally read-only tool.
        if segment.contains(where: { $0.isOperator && [">", ">>", "<", "<<", "&>"].contains($0.value) }) {
            return .reviewRequired
        }
        return .safe
    }

    private func executableIndex(in words: [String]) -> Int? {
        var index = 0
        while index < words.count, isAssignment(words[index]) { index += 1 }
        guard index < words.count else { return nil }

        while index < words.count {
            let name = commandName(words[index])
            guard Self.commandWrappers.contains(name) else { return index }
            if name == "sudo" {
                index += 1
                while index < words.count, words[index].hasPrefix("-") {
                    let option = words[index]
                    index += 1
                    if ["-C", "-g", "-p", "-R", "-u", "--chdir", "--group", "--prompt", "--user"].contains(option), index < words.count { index += 1 }
                }
                return index < words.count ? index : nil
            } else if name == "env" {
                index += 1
                while index < words.count {
                    if isAssignment(words[index]) { index += 1; continue }
                    if ["-u", "--unset"].contains(words[index]), index + 1 < words.count { index += 2; continue }
                    if words[index].hasPrefix("-") { index += 1; continue }
                    break
                }
            } else if name == "command" {
                index += 1
                while index < words.count, words[index].hasPrefix("-") { index += 1 }
            } else if name == "exec" {
                index += 1
                while index < words.count {
                    let option = words[index]
                    if option == "--" {
                        index += 1
                        break
                    }
                    if option == "-a" {
                        index += min(2, words.count - index)
                    } else if option.hasPrefix("-") {
                        index += 1
                    } else {
                        break
                    }
                }
            } else if name == "nice" {
                index += 1
                if index < words.count, ["-n", "--adjustment"].contains(words[index]) { index += min(2, words.count - index) }
            } else if name == "timeout" {
                index += 1
                while index < words.count, words[index].hasPrefix("-") { index += 1 }
                if index < words.count { index += 1 } // duration
            } else if name == "xargs" {
                index += 1
                while index < words.count, words[index].hasPrefix("-") { index += 1 }
            } else {
                index += 1
            }
        }
        return nil
    }

    private func interpreterRisk(_ arguments: [String]) -> CommandRisk {
        guard let cIndex = arguments.firstIndex(of: "-c"), cIndex + 1 < arguments.count else { return .reviewRequired }
        let nested = classify(arguments[cIndex + 1])
        return nested == .blocked ? .blocked : .reviewRequired
    }

    private func rmRisk(_ arguments: [String]) -> CommandRisk {
        // A slash embedded in a short-option token is malformed but was historically blocked;
        // keep that conservative behavior rather than attempting to guess shell/parser recovery.
        if arguments.contains(where: { $0.hasPrefix("-") && !$0.hasPrefix("--") && $0.contains("/") }) { return .blocked }
        let operands = optionOperands(arguments)
        if operands.contains(where: { isCriticalPath($0) }) { return .blocked }
        return .reviewRequired
    }

    private func ddRisk(_ arguments: [String]) -> CommandRisk {
        let output = arguments.compactMap { argument -> String? in
            guard let separator = argument.firstIndex(of: "=") else { return nil }
            return argument[..<separator].lowercased() == "of" ? String(argument[argument.index(after: separator)...]) : nil
        }
        return output.contains(where: { isDiskPath($0) }) ? .blocked : .reviewRequired
    }

    private func diskRisk(executable: String, arguments: [String]) -> CommandRisk {
        if executable == "format" || executable == "mkfs" || executable == "mkswap" {
            return arguments.contains(where: { isDiskPath($0) }) ? .blocked : .reviewRequired
        }
        if executable == "diskutil" && arguments.contains(where: { ["eraseDisk", "eraseVolume", "partitionDisk"].contains($0) }) { return .blocked }
        return arguments.contains(where: { isDiskPath($0) }) ? .blocked : .reviewRequired
    }

    private func systemPathRisk(arguments: [String], recursiveFlag: Bool) -> CommandRisk {
        let operands = optionOperands(arguments)
        return operands.contains(where: { isCriticalPath($0) }) && recursiveFlag ? .blocked : .reviewRequired
    }

    private func findRisk(_ arguments: [String]) -> CommandRisk {
        if arguments.contains("-delete"), optionOperands(arguments).contains(where: { isCriticalPath($0) }) { return .blocked }
        guard let execIndex = arguments.firstIndex(where: { $0 == "-exec" || $0 == "-execdir" }) else { return .reviewRequired }
        let nestedArguments = arguments.dropFirst(execIndex + 1).prefix(while: { $0 != ";" && $0 != "+" })
        let nested = classifySegment(nestedArguments.map { ShellToken(value: $0, isOperator: false) })
        return nested == .blocked ? .blocked : .reviewRequired
    }

    private func gitRisk(_ arguments: [String]) -> CommandRisk {
        let subcommands = arguments.filter { !$0.hasPrefix("-") }
        guard let subcommand = subcommands.first else { return .reviewRequired }
        return ["branch", "diff", "log", "ls-files", "show", "status", "rev-parse"].contains(subcommand) ? .safe : .reviewRequired
    }

    private func tmuxRisk(_ arguments: [String]) -> CommandRisk {
        let formatCommands = arguments.flatMap(ShellTokenizer.tmuxFormatCommands(in:))
        if !formatCommands.isEmpty {
            let formatRisk = commandSubstitutionRisk(formatCommands)
            if formatRisk == .blocked { return .blocked }
        }

        // Global destructive actions are always blocked even after approval
        if arguments.contains("kill-server") {
            return .blocked
        }

        if arguments.contains(where: { $0 == "kill-session" || $0 == "kill-sess" }) {
            let hasGlobalKillFlag = arguments.contains { arg in
                if arg == "--all" { return true }
                if arg.hasPrefix("-") && !arg.hasPrefix("--") {
                    let flags = arg.dropFirst()
                    return flags.contains("a") || flags.contains("g")
                }
                return false
            }
            if hasGlobalKillFlag {
                return .blocked
            }
            return .reviewRequired
        }

        if let runShellIndex = arguments.firstIndex(where: { $0 == "run-shell" || $0 == "if-shell" }),
           runShellIndex + 1 < arguments.count {
            let nestedCmd = arguments[runShellIndex + 1]
            if classify(nestedCmd) == .blocked {
                return .blocked
            }
            return .reviewRequired
        }

        // Exact probe form: tmux -V (with optional global flags like -u, but no subcommand)
        let isProbe = arguments.contains("-V") && arguments.allSatisfy { $0.hasPrefix("-") }
        if isProbe {
            return formatCommands.isEmpty ? .safe : .reviewRequired
        }

        let (subcommand, _) = parseTmuxSubcommand(arguments: arguments)
        guard let action = subcommand else {
            return .reviewRequired
        }

        let isReadOnlyList = ["list-sessions", "ls", "list-windows", "lsw"].contains(action)
        let isHasSession = ["has-session", "has"].contains(action)

        if isReadOnlyList || isHasSession {
            return formatCommands.isEmpty ? .safe : .reviewRequired
        }

        return .reviewRequired
    }

    private func parseTmuxSubcommand(arguments: [String]) -> (subcommand: String?, remaining: [String]) {
        var index = 0
        while index < arguments.count {
            let arg = arguments[index]
            if ["-c", "-f", "-L", "-S"].contains(arg) {
                index += 2
                continue
            }
            if arg.hasPrefix("-") {
                index += 1
                continue
            }
            return (arg, Array(arguments.dropFirst(index + 1)))
        }
        return (nil, [])
    }

    private func commandSubstitutionRisk(_ substitutions: [String]) -> CommandRisk {
        var sawReview = false
        for substitution in substitutions {
            switch classify(substitution) {
            case .blocked: return .blocked
            case .reviewRequired: sawReview = true
            case .safe: break
            }
        }
        return sawReview ? .reviewRequired : (substitutions.isEmpty ? .safe : .reviewRequired)
    }

    private func optionOperands(_ arguments: [String]) -> [String] {
        var operands: [String] = []
        var optionsEnded = false
        for argument in arguments {
            if !optionsEnded && argument == "--" {
                optionsEnded = true
            } else if !optionsEnded && argument.hasPrefix("-") && argument != "-" {
                continue
            } else {
                operands.append(argument)
            }
        }
        return operands
    }

    private func isAssignment(_ value: String) -> Bool {
        guard let equals = value.firstIndex(of: "=") else { return false }
        let name = value[..<equals]
        return !name.isEmpty && name.first?.isLetter == true && name.allSatisfy { $0.isLetter || $0.isNumber || $0 == "_" }
    }

    private func commandName(_ value: String) -> String {
        value.split(separator: "/").last.map { String($0).lowercased() } ?? value.lowercased()
    }

    private func isCriticalPath(_ value: String) -> Bool {
        let normalized = value.split(separator: "/", omittingEmptySubsequences: true).reduce(into: [Substring]()) { result, component in
            if component == "." { return }
            if component == ".." { if !result.isEmpty { result.removeLast() } } else { result.append(component) }
        }
        guard value.hasPrefix("/") else { return false }
        if normalized.isEmpty || normalized.first?.contains(where: { $0 == "*" || $0 == "?" || $0 == "[" || $0 == "{" }) == true { return true }
        let topLevel = String(normalized[0]).lowercased()
        return ["bin", "boot", "dev", "etc", "lib", "lib64", "proc", "sbin", "sys", "usr"].contains(topLevel)
    }

    private func isDiskPath(_ value: String) -> Bool {
        guard value.hasPrefix("/dev/") else { return false }
        let device = value.dropFirst(5).lowercased()
        return !["null", "zero", "random", "urandom", "stdin", "stdout", "stderr"].contains(device) &&
            ["sd", "hd", "vd", "xvd", "nvme", "mmc", "md", "dm-", "mapper/", "disk", "loop"].contains(where: { device.hasPrefix($0) })
    }

    private func isForkBomb(_ tokens: [ShellToken]) -> Bool {
        let words = tokens.filter { !$0.isOperator }.map(\.value)
        let operators = Set(tokens.filter(\.isOperator).map(\.value))
        return words.first == ":" && words.filter { $0 == ":" }.count >= 3 && operators.contains("|") && operators.contains("&") && operators.contains("{") && operators.contains("}")
    }
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

public actor SessionCoordinator {
    private var sessions: [UUID: TerminalSession] = [:]
    public init() {}
    public func begin(hostID: UUID) -> TerminalSession { let session = TerminalSession(hostID: hostID); sessions[session.id] = session; return session }
    public func update(_ session: TerminalSession) { guard sessions[session.id] != nil else { return }; sessions[session.id] = session }
    public func end(id: UUID) { sessions[id]?.state = .disconnected }
    public func current() -> [TerminalSession] { Array(sessions.values) }
}

