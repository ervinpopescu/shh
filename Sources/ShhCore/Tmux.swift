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

// MARK: - List Parser & Errors

public enum TmuxParseError: Error, Equatable, Sendable, LocalizedError {
    case emptyLine
    case invalidFieldCount(expected: Int, actual: Int, line: String = "")
    case invalidSessionID(String)
    case invalidSessionName(String = "")
    case invalidWindowsCount(String)
    case invalidTimestamp(field: String, value: String = "")
    case invalidAttachedCount(String)

    public var errorDescription: String? {
        switch self {
        case .emptyLine:
            return "Line is empty."
        case .invalidFieldCount(let expected, let actual, _):
            return "Expected \(expected) delimited fields, got \(actual)."
        case .invalidSessionID(let id):
            let safeID = id.hasPrefix("$") && id.dropFirst().allSatisfy(\.isNumber) ? id : "invalid"
            return "Invalid tmux session ID: '\(safeID)'"
        case .invalidSessionName:
            return "Invalid or empty tmux session name."
        case .invalidWindowsCount(let count):
            return "Invalid windows count: '\(count)'"
        case .invalidTimestamp(let field, _):
            return "Invalid timestamp for '\(field)'."
        case .invalidAttachedCount(let count):
            return "Invalid attached count: '\(count)'"
        }
    }

    public var recoverySuggestion: String? {
        "Refresh sessions or verify remote tmux version."
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

        let rawSessionID: String
        let rawName: String
        let rawWindows: String
        let rawCreated: String
        let rawActivity: String
        let rawAttached: String

        if sanitized.contains("\t") {
            // Priority 1: Tab-delimited format
            let fields = sanitized.components(separatedBy: "\t")
            guard fields.count == 6 else {
                throw TmuxParseError.invalidFieldCount(expected: 6, actual: fields.count, line: line)
            }
            rawSessionID = fields[0]
            rawName = fields[1]
            rawWindows = fields[2]
            rawCreated = fields[3]
            rawActivity = fields[4]
            rawAttached = fields[5]
        } else if sanitized.contains("|") {
            // Priority 2: Printable pipe-delimited format with explicit escaping (#{q:session_name})
            let parts = sanitized.components(separatedBy: "|")
            guard parts.count >= 6 else {
                throw TmuxParseError.invalidFieldCount(expected: 6, actual: parts.count, line: line)
            }
            rawSessionID = parts[0]
            rawAttached = parts[parts.count - 1]
            rawActivity = parts[parts.count - 2]
            rawCreated = parts[parts.count - 3]
            rawWindows = parts[parts.count - 4]

            let nameParts = parts[1..<(parts.count - 4)]
            let escapedName = nameParts.joined(separator: "|")
            rawName = unescapeTmuxQuotedName(escapedName)
        } else if sanitized.contains("_") {
            // Priority 3: Legacy underscore-sanitized output (e.g. tmux 3.7c sanitizing tabs to _)
            // Parse safely from the right: attached, activity, created, windows
            let parts = sanitized.components(separatedBy: "_")
            guard parts.count >= 6 else {
                throw TmuxParseError.invalidFieldCount(expected: 6, actual: parts.count, line: line)
            }
            rawAttached = parts[parts.count - 1]
            rawActivity = parts[parts.count - 2]
            rawCreated = parts[parts.count - 3]
            rawWindows = parts[parts.count - 4]

            // Remaining prefix contains session ID and name
            let prefixParts = parts[0..<(parts.count - 4)]
            let prefix = prefixParts.joined(separator: "_")

            guard prefix.hasPrefix("$") else {
                throw TmuxParseError.invalidSessionID(prefix)
            }

            guard let firstUnderscore = prefix.firstIndex(of: "_") else {
                throw TmuxParseError.invalidFieldCount(expected: 6, actual: 1, line: line)
            }

            rawSessionID = String(prefix[..<firstUnderscore])
            rawName = String(prefix[prefix.index(after: firstUnderscore)...])
        } else {
            throw TmuxParseError.invalidFieldCount(expected: 6, actual: 1, line: line)
        }

        // Strict Bounds & Field Validation
        let sessionID = rawSessionID.trimmingCharacters(in: .whitespaces)
        guard sessionID.hasPrefix("$"), sessionID.count > 1, sessionID.count <= 16,
              sessionID.dropFirst().allSatisfy(\.isNumber) else {
            throw TmuxParseError.invalidSessionID(sessionID)
        }

        let name = rawName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else {
            throw TmuxParseError.invalidSessionName(name)
        }
        guard name.count <= TmuxSessionName.maximumLength else {
            throw TmuxParseError.invalidSessionName(name)
        }
        guard !name.unicodeScalars.contains(where: { scalar in
            scalar.value < 0x20 || scalar.value == 0x7F || (0x80...0x9F).contains(scalar.value) ||
            scalar.properties.generalCategory == .control || scalar == "\0" || scalar == "\n" || scalar == "\r"
        }) else {
            throw TmuxParseError.invalidSessionName(name)
        }

        guard let windows = Int(rawWindows.trimmingCharacters(in: .whitespaces)), windows >= 0, windows <= 100_000 else {
            throw TmuxParseError.invalidWindowsCount(rawWindows)
        }

        guard let createdSeconds = Double(rawCreated.trimmingCharacters(in: .whitespaces)),
              createdSeconds >= 0, createdSeconds <= 4_102_444_800 else {
            throw TmuxParseError.invalidTimestamp(field: "created", value: rawCreated)
        }

        guard let activitySeconds = Double(rawActivity.trimmingCharacters(in: .whitespaces)),
              activitySeconds >= 0, activitySeconds <= 4_102_444_800 else {
            throw TmuxParseError.invalidTimestamp(field: "activity", value: rawActivity)
        }

        guard let attached = Int(rawAttached.trimmingCharacters(in: .whitespaces)), attached >= 0, attached <= 100_000 else {
            throw TmuxParseError.invalidAttachedCount(rawAttached)
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

    public static func unescapeTmuxQuotedName(_ text: String) -> String {
        var result = ""
        var isEscaping = false
        for char in text {
            if isEscaping {
                result.append(char)
                isEscaping = false
            } else if char == "\\" {
                isEscaping = true
            } else {
                result.append(char)
            }
        }
        if isEscaping {
            result.append("\\")
        }
        return result
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

    /// Printable collision-resistant delimiter format string with explicit shell escaping for list-sessions
    public static let listSessionsFormat: String = "#{session_id}|#{q:session_name}|#{session_windows}|#{session_created}|#{session_activity}|#{session_attached}"

    /// Exact list-sessions command template
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
