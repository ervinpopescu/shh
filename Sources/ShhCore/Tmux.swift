import Foundation

// MARK: - Remote Command Execution Models & Contracts

public struct SSHCommandResult: Equatable, Hashable, Sendable, Codable {
    public var exitCode: Int32
    public var stdout: String
    public var stderr: String

    public init(exitCode: Int32, stdout: String, stderr: String = "") {
        self.exitCode = exitCode
        self.stdout = stdout
        self.stderr = stderr
    }

    public var isSuccess: Bool { exitCode == 0 }
}

public typealias RemoteCommandResult = SSHCommandResult

public protocol SSHCommandExecuting: Sendable {
    func executeCommand(_ command: String) async throws -> SSHCommandResult
    func executeCommand(_ command: String, timeout: TimeInterval?, maxOutputBytes: Int?) async throws -> SSHCommandResult
}

public extension SSHCommandExecuting {
    func execute(_ command: String) async throws -> SSHCommandResult {
        try await executeCommand(command)
    }

    func executeCommand(_ command: String, timeout: TimeInterval?, maxOutputBytes: Int?) async throws -> SSHCommandResult {
        try await executeCommand(command)
    }

    func executeCommand(_ command: String, timeout: TimeInterval?) async throws -> SSHCommandResult {
        try await executeCommand(command, timeout: timeout, maxOutputBytes: nil)
    }
}

// MARK: - Tmux Availability

public enum TmuxAvailability: Equatable, Hashable, Sendable, Codable {
    case available(version: String)
    case unavailable(reason: String)

    public var isAvailable: Bool {
        switch self {
        case .available: return true
        case .unavailable: return false
        }
    }

    public var version: String? {
        switch self {
        case .available(let v): return v
        case .unavailable: return nil
        }
    }

    public var capability: CapabilityAvailability {
        switch self {
        case .available:
            return .available
        case .unavailable(let reason):
            return .unavailable(reason: reason)
        }
    }

    public static func parse(output: String, exitCode: Int32 = 0) -> TmuxAvailability {
        guard exitCode == 0 else {
            let trimmed = output.trimmingCharacters(in: .whitespacesAndNewlines)
            return .unavailable(reason: trimmed.isEmpty ? "tmux process exited with code \(exitCode)" : trimmed)
        }
        let trimmed = output.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            return .unavailable(reason: "Empty probe output")
        }
        return .available(version: trimmed)
    }

    public static func parse(result: SSHCommandResult) -> TmuxAvailability {
        if result.isSuccess {
            return parse(output: result.stdout, exitCode: result.exitCode)
        } else {
            let err = result.stderr.trimmingCharacters(in: .whitespacesAndNewlines)
            let out = result.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
            let reason = !err.isEmpty ? err : (!out.isEmpty ? out : "tmux probe failed with code \(result.exitCode)")
            return .unavailable(reason: reason)
        }
    }
}

// MARK: - Tmux Session Info

public struct TmuxSessionInfo: Identifiable, Equatable, Hashable, Sendable, Codable {
    public let sessionID: String
    public let name: String
    public let windowsCount: Int
    public let createdAt: Date
    public let lastActivityAt: Date
    public let attachedClients: Int

    public var id: String { sessionID }
    public var isAttached: Bool { attachedClients > 0 }

    // Tmux field name aliases for discoverability
    public var windows: Int { windowsCount }
    public var created: Date { createdAt }
    public var activity: Date { lastActivityAt }
    public var attached: Int { attachedClients }

    public init(
        sessionID: String,
        name: String,
        windowsCount: Int,
        createdAt: Date,
        lastActivityAt: Date,
        attachedClients: Int
    ) {
        self.sessionID = sessionID
        self.name = name
        self.windowsCount = windowsCount
        self.createdAt = createdAt
        self.lastActivityAt = lastActivityAt
        self.attachedClients = attachedClients
    }

    public static func parseList(from output: String) throws -> [TmuxSessionInfo] {
        try TmuxListSessionsParser.parse(output)
    }
}

public typealias TmuxSession = TmuxSessionInfo

// MARK: - Tab-delimited List Parser

public enum TmuxParseError: Error, Equatable, Sendable, LocalizedError {
    case emptyLine
    case invalidFieldCount(expected: Int, actual: Int, line: String)
    case invalidSessionID(String)
    case invalidSessionName(String)
    case invalidWindowsCount(String)
    case invalidTimestamp(field: String, value: String)
    case invalidAttachedCount(String)

    public var errorDescription: String? {
        switch self {
        case .emptyLine:
            return "Line is empty."
        case .invalidFieldCount(let expected, let actual, let line):
            return "Expected \(expected) tab-delimited fields, got \(actual) in line: '\(line)'"
        case .invalidSessionID(let id):
            return "Invalid tmux session ID: '\(id)'"
        case .invalidSessionName(let name):
            return "Invalid tmux session name: '\(name)'"
        case .invalidWindowsCount(let count):
            return "Invalid windows count: '\(count)'"
        case .invalidTimestamp(let field, let value):
            return "Invalid timestamp for '\(field)': '\(value)'"
        case .invalidAttachedCount(let count):
            return "Invalid attached count: '\(count)'"
        }
    }
}

public enum TmuxListSessionsParser {
    public static func parse(_ output: String) throws -> [TmuxSessionInfo] {
        let trimmed = output.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return [] }

        let lines = output.components(separatedBy: .newlines)
        var sessions: [TmuxSessionInfo] = []

        for line in lines {
            let lineTrimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
            if lineTrimmed.isEmpty { continue }
            let session = try parseLine(line)
            sessions.append(session)
        }
        return sessions
    }

    public static func parseLine(_ line: String) throws -> TmuxSessionInfo {
        var sanitized = line
        if sanitized.hasSuffix("\r") {
            sanitized.removeLast()
        }

        guard !sanitized.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw TmuxParseError.emptyLine
        }

        let fields = sanitized.components(separatedBy: "\t")
        guard fields.count == 6 else {
            throw TmuxParseError.invalidFieldCount(expected: 6, actual: fields.count, line: line)
        }

        let sessionID = fields[0].trimmingCharacters(in: .whitespaces)
        guard sessionID.hasPrefix("$"), sessionID.count > 1, sessionID.dropFirst().allSatisfy(\.isNumber) else {
            throw TmuxParseError.invalidSessionID(sessionID)
        }

        let name = fields[1]
        guard !name.isEmpty else {
            throw TmuxParseError.invalidSessionName(name)
        }

        guard let windows = Int(fields[2].trimmingCharacters(in: .whitespaces)), windows >= 0 else {
            throw TmuxParseError.invalidWindowsCount(fields[2])
        }

        guard let createdSeconds = Double(fields[3].trimmingCharacters(in: .whitespaces)) else {
            throw TmuxParseError.invalidTimestamp(field: "created", value: fields[3])
        }

        guard let activitySeconds = Double(fields[4].trimmingCharacters(in: .whitespaces)) else {
            throw TmuxParseError.invalidTimestamp(field: "activity", value: fields[4])
        }

        guard let attached = Int(fields[5].trimmingCharacters(in: .whitespaces)), attached >= 0 else {
            throw TmuxParseError.invalidAttachedCount(fields[5])
        }

        return TmuxSessionInfo(
            sessionID: sessionID,
            name: name,
            windowsCount: windows,
            createdAt: Date(timeIntervalSince1970: createdSeconds),
            lastActivityAt: Date(timeIntervalSince1970: activitySeconds),
            attachedClients: attached
        )
    }
}

// MARK: - Validated Create Names

public struct TmuxSessionName: Equatable, Hashable, Sendable, Codable, CustomStringConvertible {
    public static let maximumLength: Int = 128

    public let value: String
    public var rawValue: String { value }

    public init(_ value: String) throws {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            throw TmuxSessionNameError.empty
        }
        guard value.count <= Self.maximumLength else {
            throw TmuxSessionNameError.oversized(length: value.count, maximum: Self.maximumLength)
        }
        guard !value.contains(":") else {
            throw TmuxSessionNameError.containsColon
        }
        guard !value.contains(".") else {
            throw TmuxSessionNameError.containsPeriod
        }
        guard !value.unicodeScalars.contains(where: { scalar in
            scalar.value < 0x20 || scalar.value == 0x7F || (0x80...0x9F).contains(scalar.value) || scalar.properties.generalCategory == .control
        }) else {
            throw TmuxSessionNameError.containsControlCharacters
        }
        self.value = value
    }

    public init(value: String) throws {
        try self.init(value)
    }

    public var description: String { value }

    /// Escapes tmux '#' format characters by doubling them ('#' -> '##').
    public var tmuxFormatEscaped: String {
        value.replacingOccurrences(of: "#", with: "##")
    }

    /// Shell-quoted representation of the tmux-format-escaped name.
    public var shellArgument: String {
        ShellQuoting.quote(tmuxFormatEscaped)
    }
}

public enum TmuxSessionNameError: Error, Equatable, Sendable, LocalizedError {
    case empty
    case oversized(length: Int, maximum: Int)
    case containsColon
    case containsPeriod
    case containsControlCharacters

    public var errorDescription: String? {
        switch self {
        case .empty:
            return "Tmux session name cannot be empty."
        case .oversized(let length, let maximum):
            return "Tmux session name length (\(length)) exceeds maximum allowed length of \(maximum)."
        case .containsColon:
            return "Tmux session name cannot contain colons (':')."
        case .containsPeriod:
            return "Tmux session name cannot contain periods ('.')."
        case .containsControlCharacters:
            return "Tmux session name cannot contain control characters."
        }
    }
}

// MARK: - Validated Session ID (for Attaching)

public struct TmuxSessionID: Equatable, Hashable, Sendable, Codable, CustomStringConvertible {
    public let value: String
    public var rawValue: String { value }

    public init(_ value: String) throws {
        guard value.hasPrefix("$"), value.count > 1, value.dropFirst().allSatisfy(\.isNumber) else {
            throw TmuxSessionIDError.invalidSessionID(value)
        }
        self.value = value
    }

    public init(value: String) throws {
        try self.init(value)
    }

    public var description: String { value }

    public var shellArgument: String {
        ShellQuoting.quote(value)
    }
}

public enum TmuxSessionIDError: Error, Equatable, Sendable, LocalizedError {
    case invalidSessionID(String)

    public var errorDescription: String? {
        switch self {
        case .invalidSessionID(let id):
            return "Existing tmux sessions must attach by session ID (e.g. '$0'), never by name: '\(id)'"
        }
    }
}

// MARK: - Fixed Command Templates

public enum TmuxCommand: Sendable {
    /// Exact probe template: `tmux -V`
    public static let probe: String = "tmux -V"

    /// Tab-delimited format string for list-sessions
    public static let listSessionsFormat: String = "#{session_id}\t#{session_name}\t#{session_windows}\t#{session_created}\t#{session_activity}\t#{session_attached}"

    /// Exact tab-delimited list-sessions template
    public static let listSessions: String = "tmux list-sessions -F '\(listSessionsFormat)'"

    /// Exact has-session template
    public static func hasSession(id: String) -> String {
        "tmux has-session -t \(ShellQuoting.quote(id))"
    }

    public static func hasSession(id: TmuxSessionID) -> String {
        "tmux has-session -t \(id.shellArgument)"
    }

    /// Exact attach-session takeover template by quoted session ID.
    /// Existing sessions must attach by tmux session ID, never name.
    /// Template: `env -u TMUX tmux attach-session -d -t '<session_id>'`
    public static func attachSession(id: TmuxSessionID) -> String {
        "env -u TMUX tmux attach-session -d -t \(id.shellArgument)"
    }

    public static func attachSession(id: String) throws -> String {
        let sessionID = try TmuxSessionID(id)
        return attachSession(id: sessionID)
    }

    /// Exact new-session template using validated quoted name.
    /// Template: `tmux new-session -A -D -s '<name>'`
    public static func newSession(name: TmuxSessionName) -> String {
        "tmux new-session -A -D -s \(name.shellArgument)"
    }

    public static func newSession(name: String) throws -> String {
        let sessionName = try TmuxSessionName(name)
        return newSession(name: sessionName)
    }
}
