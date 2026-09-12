import Foundation

// MARK: - Herdr Agent State

public enum HerdrAgentState: Equatable, Hashable, Sendable {
    case idle
    case working
    case blocked(reason: String)
    case completed(summary: String)

    public var statusName: String {
        switch self {
        case .idle: return "idle"
        case .working: return "working"
        case .blocked: return "blocked"
        case .completed: return "completed"
        }
    }

    public var isIdle: Bool { self == .idle }
    public var isWorking: Bool { self == .working }

    public var isBlocked: Bool {
        if case .blocked = self { return true }
        return false
    }

    public var isCompleted: Bool {
        if case .completed = self { return true }
        return false
    }

    public var blockedReason: String? {
        if case .blocked(let reason) = self { return reason }
        return nil
    }

    public var completedSummary: String? {
        if case .completed(let summary) = self { return summary }
        return nil
    }
}

extension HerdrAgentState: Codable {
    private enum CodingKeys: String, CodingKey {
        case status
        case state
        case reason
        case summary
        case message
    }

    public init(from decoder: Decoder) throws {
        // Try decoding single string primitive: "idle", "working", "blocked: ...", etc.
        if let singleValue = try? decoder.singleValueContainer(),
           let string = try? singleValue.decode(String.self) {
            let lower = string.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            switch lower {
            case "idle":
                self = .idle
                return
            case "working", "running", "active":
                self = .working
                return
            case "completed", "done", "success", "finished":
                self = .completed(summary: "")
                return
            case "blocked", "waiting":
                self = .blocked(reason: "")
                return
            default:
                if lower.hasPrefix("blocked:") || lower.hasPrefix("blocked -") {
                    let prefixLen = lower.hasPrefix("blocked:") ? 8 : 9
                    let reason = string.dropFirst(prefixLen).trimmingCharacters(in: .whitespacesAndNewlines)
                    self = .blocked(reason: reason)
                    return
                }
                if lower.hasPrefix("completed:") || lower.hasPrefix("completed -") || lower.hasPrefix("done:") || lower.hasPrefix("done -") {
                    let prefixLen: Int
                    if lower.hasPrefix("done:") { prefixLen = 5 }
                    else if lower.hasPrefix("done -") { prefixLen = 6 }
                    else if lower.hasPrefix("completed:") { prefixLen = 10 }
                    else { prefixLen = 11 }
                    let summary = string.dropFirst(prefixLen).trimmingCharacters(in: .whitespacesAndNewlines)
                    self = .completed(summary: summary)
                    return
                }
                throw DecodingError.dataCorrupted(
                    DecodingError.Context(codingPath: decoder.codingPath, debugDescription: "Unknown agent state string: '\(string)'")
                )
            }
        }

        let container = try decoder.container(keyedBy: CodingKeys.self)
        let statusString = (try? container.decodeIfPresent(String.self, forKey: .status)) ??
                           (try? container.decodeIfPresent(String.self, forKey: .state))
        guard let status = statusString?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() else {
            throw DecodingError.dataCorrupted(
                DecodingError.Context(codingPath: decoder.codingPath, debugDescription: "Missing status or state key for HerdrAgentState")
            )
        }

        switch status {
        case "idle":
            self = .idle
        case "working", "running", "active":
            self = .working
        case "blocked", "waiting":
            let reason = (try? container.decodeIfPresent(String.self, forKey: .reason)) ??
                         (try? container.decodeIfPresent(String.self, forKey: .message)) ?? ""
            self = .blocked(reason: reason)
        case "completed", "done", "success", "finished":
            let summary = (try? container.decodeIfPresent(String.self, forKey: .summary)) ??
                          (try? container.decodeIfPresent(String.self, forKey: .message)) ?? ""
            self = .completed(summary: summary)
        default:
            throw DecodingError.dataCorrupted(
                DecodingError.Context(codingPath: decoder.codingPath, debugDescription: "Unknown agent state: '\(status)'")
            )
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .idle:
            try container.encode("idle", forKey: .status)
        case .working:
            try container.encode("working", forKey: .status)
        case .blocked(let reason):
            try container.encode("blocked", forKey: .status)
            try container.encode(reason, forKey: .reason)
        case .completed(let summary):
            try container.encode("completed", forKey: .status)
            try container.encode(summary, forKey: .summary)
        }
    }
}

// MARK: - Herdr Pane

public struct HerdrPane: Identifiable, Equatable, Hashable, Sendable {
    public let id: String
    public let label: String
    public let agentState: HerdrAgentState
    public let currentCommand: String?
    public let lastActivity: Date?

    public init(
        id: String,
        label: String,
        agentState: HerdrAgentState,
        currentCommand: String? = nil,
        lastActivity: Date? = nil
    ) {
        self.id = id
        self.label = label
        self.agentState = agentState
        self.currentCommand = currentCommand
        self.lastActivity = lastActivity
    }
}

extension HerdrPane: Codable {
    private enum CodingKeys: String, CodingKey {
        case id
        case label
        case title
        case name
        case agentState
        case agent_state
        case state
        case status
        case currentCommand
        case current_command
        case command
        case lastActivity
        case last_activity
        case activity
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.id = try container.decode(String.self, forKey: .id)

        self.label = (try? container.decodeIfPresent(String.self, forKey: .label)) ??
                     (try? container.decodeIfPresent(String.self, forKey: .title)) ??
                     (try? container.decodeIfPresent(String.self, forKey: .name)) ?? ""

        if let state = try? container.decodeIfPresent(HerdrAgentState.self, forKey: .agentState) {
            self.agentState = state
        } else if let state = try? container.decodeIfPresent(HerdrAgentState.self, forKey: .agent_state) {
            self.agentState = state
        } else if let state = try? container.decodeIfPresent(HerdrAgentState.self, forKey: .state) {
            self.agentState = state
        } else if let state = try? container.decodeIfPresent(HerdrAgentState.self, forKey: .status) {
            self.agentState = state
        } else {
            self.agentState = (try? HerdrAgentState(from: decoder)) ?? .idle
        }

        self.currentCommand = (try? container.decodeIfPresent(String.self, forKey: .currentCommand)) ??
                              (try? container.decodeIfPresent(String.self, forKey: .current_command)) ??
                              (try? container.decodeIfPresent(String.self, forKey: .command))

        if let date = try? container.decodeIfPresent(Date.self, forKey: .lastActivity) {
            self.lastActivity = date
        } else if let date = try? container.decodeIfPresent(Date.self, forKey: .last_activity) {
            self.lastActivity = date
        } else if let date = try? container.decodeIfPresent(Date.self, forKey: .activity) {
            self.lastActivity = date
        } else if let isoString = (try? container.decodeIfPresent(String.self, forKey: .lastActivity)) ??
                                  (try? container.decodeIfPresent(String.self, forKey: .last_activity)) ??
                                  (try? container.decodeIfPresent(String.self, forKey: .activity)),
                  let parsed = ISO8601DateFormatter().date(from: isoString) {
            self.lastActivity = parsed
        } else if let epoch = (try? container.decodeIfPresent(Double.self, forKey: .lastActivity)) ??
                              (try? container.decodeIfPresent(Double.self, forKey: .last_activity)) ??
                              (try? container.decodeIfPresent(Double.self, forKey: .activity)) {
            self.lastActivity = Date(timeIntervalSince1970: epoch)
        } else {
            self.lastActivity = nil
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(label, forKey: .label)
        try container.encode(agentState, forKey: .agentState)
        try container.encodeIfPresent(currentCommand, forKey: .currentCommand)
        if let lastActivity {
            let iso = ISO8601DateFormatter().string(from: lastActivity)
            try container.encode(iso, forKey: .lastActivity)
        }
    }
}

// MARK: - Herdr Workspace

public struct HerdrWorkspace: Identifiable, Equatable, Hashable, Sendable {
    public let id: String
    public var label: String
    public var cwd: String
    public var panes: [HerdrPane]

    public init(
        id: String,
        label: String,
        cwd: String,
        panes: [HerdrPane] = []
    ) {
        self.id = id
        self.label = label
        self.cwd = cwd
        self.panes = panes
    }
}

extension HerdrWorkspace: Codable {
    private enum CodingKeys: String, CodingKey {
        case id
        case label
        case name
        case title
        case cwd
        case workingDirectory = "working_directory"
        case path
        case panes
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.id = try container.decode(String.self, forKey: .id)
        self.label = (try? container.decodeIfPresent(String.self, forKey: .label)) ??
                     (try? container.decodeIfPresent(String.self, forKey: .name)) ??
                     (try? container.decodeIfPresent(String.self, forKey: .title)) ?? ""
        self.cwd = (try? container.decodeIfPresent(String.self, forKey: .cwd)) ??
                   (try? container.decodeIfPresent(String.self, forKey: .workingDirectory)) ??
                   (try? container.decodeIfPresent(String.self, forKey: .path)) ?? ""
        self.panes = (try? container.decodeIfPresent([HerdrPane].self, forKey: .panes)) ?? []
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(label, forKey: .label)
        try container.encode(cwd, forKey: .cwd)
        try container.encode(panes, forKey: .panes)
    }
}

// MARK: - Herdr Availability

public enum HerdrAvailability: Equatable, Hashable, Sendable, Codable {
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

    public var unavailableReason: String? {
        switch self {
        case .available: return nil
        case .unavailable(let reason): return reason
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

    public static func parse(output: String, exitCode: Int32 = 0) -> HerdrAvailability {
        guard exitCode == 0 else {
            let trimmed = output.trimmingCharacters(in: .whitespacesAndNewlines)
            return .unavailable(reason: trimmed.isEmpty ? "herdr process exited with code \(exitCode)" : trimmed)
        }
        let trimmed = output.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            return .unavailable(reason: "Empty probe output")
        }
        return .available(version: trimmed)
    }

    public static func parse(result: SSHCommandResult) -> HerdrAvailability {
        if result.isSuccess {
            return parse(output: result.stdout, exitCode: result.exitCode)
        } else {
            let err = result.stderr.trimmingCharacters(in: .whitespacesAndNewlines)
            let out = result.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
            let reason = !err.isEmpty ? err : (!out.isEmpty ? out : "herdr probe failed with code \(result.exitCode)")
            return .unavailable(reason: reason)
        }
    }
}

// MARK: - Herdr Command Templates

public enum HerdrCommand: Hashable, Sendable {
    case base
    case remoteLaunch(workbox: String)
    case workspaceCreate(cwd: String, label: String)
    case tabCreate(label: String)
    case paneSplit(pane: String, direction: String = "right")
    case paneRun(pane: String, command: String)
    case paneRead(pane: String, source: String = "recent-unwrapped")
    case waitAgentStatus(pane: String? = nil, status: String? = nil)
    case workspaceList(format: String = "json")
    case paneList(workspace: String? = nil, format: String = "json")
    case status(format: String = "json")
    case version

    public static let defaultBinary: String = "herdr"
    public static let probe: String = "herdr --version"
    public static var waitAgentStatus: HerdrCommand { .waitAgentStatus() }

    public static func remote(host: String) -> HerdrCommand {
        .remoteLaunch(workbox: host)
    }

    public static func workspaceCreate(name: String) -> HerdrCommand {
        .workspaceCreate(cwd: ".", label: name)
    }

    public static func tabCreate(name: String) -> HerdrCommand {
        .tabCreate(label: name)
    }

    public static func paneSplit(direction: String) -> HerdrCommand {
        .paneSplit(pane: "", direction: direction)
    }

    public static func paneRun(command: String) -> HerdrCommand {
        .paneRun(pane: "", command: command)
    }

    public static var paneRead: HerdrCommand {
        .paneRead(pane: "")
    }

    public var renderedCommand: String {
        switch self {
        case .base:
            return "herdr"
        case .remoteLaunch(let workbox):
            return "herdr --remote \(ShellQuoting.quote(workbox))"
        case .workspaceCreate(let cwd, let label):
            return "herdr workspace create --cwd \(ShellQuoting.quote(cwd)) --label \(ShellQuoting.quote(label))"
        case .tabCreate(let label):
            return "herdr tab create --label \(ShellQuoting.quote(label))"
        case .paneSplit(let pane, let direction):
            if pane.isEmpty {
                return "herdr pane split \(ShellQuoting.quote(direction))"
            }
            return "herdr pane split \(ShellQuoting.quote(pane)) --direction \(ShellQuoting.quote(direction))"
        case .paneRun(let pane, let command):
            if pane.isEmpty {
                return "herdr pane run \(ShellQuoting.quote(command))"
            }
            return "herdr pane run \(ShellQuoting.quote(pane)) \(ShellQuoting.quote(command))"
        case .paneRead(let pane, let source):
            if pane.isEmpty {
                return "herdr pane read"
            }
            return "herdr pane read \(ShellQuoting.quote(pane)) --source \(ShellQuoting.quote(source))"
        case .waitAgentStatus(let pane, let status):
            if let pane = pane, !pane.isEmpty {
                if let status = status, !status.isEmpty {
                    return "herdr wait agent-status \(ShellQuoting.quote(pane)) --status \(ShellQuoting.quote(status))"
                } else {
                    return "herdr wait agent-status \(ShellQuoting.quote(pane))"
                }
            } else if let status = status, !status.isEmpty {
                return "herdr wait agent-status --status \(ShellQuoting.quote(status))"
            } else {
                return "herdr wait agent-status"
            }
        case .workspaceList(let format):
            return "herdr workspace list --format \(ShellQuoting.quote(format))"
        case .paneList(let workspace, let format):
            if let workspace = workspace, !workspace.isEmpty {
                return "herdr pane list \(ShellQuoting.quote(workspace)) --format \(ShellQuoting.quote(format))"
            }
            return "herdr pane list --format \(ShellQuoting.quote(format))"
        case .status(let format):
            return "herdr status --format \(ShellQuoting.quote(format))"
        case .version:
            return "herdr --version"
        }
    }
}

// MARK: - Herdr Parser Errors

public enum HerdrParseError: Error, Equatable, Sendable, LocalizedError {
    case emptyOutput
    case invalidJSON(String)
    case missingRequiredField(String)
    case invalidState(String)
    case executionFailed(String)

    public var errorDescription: String? {
        switch self {
        case .emptyOutput:
            return "Herdr command output was empty."
        case .invalidJSON(let message):
            return "Failed to parse Herdr JSON: \(message)"
        case .missingRequiredField(let field):
            return "Missing required field '\(field)' in Herdr output."
        case .invalidState(let state):
            return "Unknown or invalid Herdr agent state: '\(state)'"
        case .executionFailed(let message):
            return "Herdr command failed: \(message)"
        }
    }
}

// MARK: - Herdr Output Parser

public enum HerdrOutputParser: Sendable {
    private static var jsonDecoder: JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .custom { decoder in
            let container = try decoder.singleValueContainer()
            if let string = try? container.decode(String.self) {
                if let date = ISO8601DateFormatter().date(from: string) {
                    return date
                }
                let isoFractional = ISO8601DateFormatter()
                isoFractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
                if let date = isoFractional.date(from: string) {
                    return date
                }
            } else if let timestamp = try? container.decode(Double.self) {
                return Date(timeIntervalSince1970: timestamp)
            }
            throw DecodingError.dataCorrupted(
                DecodingError.Context(codingPath: decoder.codingPath, debugDescription: "Invalid date format")
            )
        }
        return decoder
    }

    private struct WorkspacesWrapper: Decodable {
        let workspaces: [HerdrWorkspace]
    }

    private struct PanesWrapper: Decodable {
        let panes: [HerdrPane]
    }

    private struct RecentUnwrappedWrapper: Decodable {
        let output: String?
        let text: String?
        let content: String?
        let lines: [String]?
    }

    /// Strips ANSI escape sequences from text.
    /// Never scrape terminal colors to infer state. State is determined strictly from
    /// structured output tokens or JSON fields.
    public static func stripANSIEscapes(_ text: String) -> String {
        text.replacingOccurrences(
            of: "\\x1B\\[[0-?]*[ -/]*[@-~]",
            with: "",
            options: .regularExpression
        )
    }

    public static func parseWorkspaces(from output: String) throws -> [HerdrWorkspace] {
        let clean = stripANSIEscapes(output).trimmingCharacters(in: .whitespacesAndNewlines)
        guard !clean.isEmpty else { throw HerdrParseError.emptyOutput }
        let data = Data(clean.utf8)

        if let list = try? jsonDecoder.decode([HerdrWorkspace].self, from: data) {
            return list
        }
        if let wrapped = try? jsonDecoder.decode(WorkspacesWrapper.self, from: data) {
            return wrapped.workspaces
        }
        if let single = try? jsonDecoder.decode(HerdrWorkspace.self, from: data) {
            return [single]
        }

        throw HerdrParseError.invalidJSON("Could not decode workspaces from output")
    }

    public static func parseWorkspace(from output: String) throws -> HerdrWorkspace {
        let clean = stripANSIEscapes(output).trimmingCharacters(in: .whitespacesAndNewlines)
        guard !clean.isEmpty else { throw HerdrParseError.emptyOutput }
        let data = Data(clean.utf8)

        if let single = try? jsonDecoder.decode(HerdrWorkspace.self, from: data) {
            return single
        }
        if let list = try? jsonDecoder.decode([HerdrWorkspace].self, from: data), let first = list.first {
            return first
        }
        if let wrapped = try? jsonDecoder.decode(WorkspacesWrapper.self, from: data), let first = wrapped.workspaces.first {
            return first
        }

        throw HerdrParseError.invalidJSON("Could not decode workspace from output")
    }

    public static func parsePanes(from output: String) throws -> [HerdrPane] {
        let clean = stripANSIEscapes(output).trimmingCharacters(in: .whitespacesAndNewlines)
        guard !clean.isEmpty else { throw HerdrParseError.emptyOutput }
        let data = Data(clean.utf8)

        if let list = try? jsonDecoder.decode([HerdrPane].self, from: data) {
            return list
        }
        if let wrapped = try? jsonDecoder.decode(PanesWrapper.self, from: data) {
            return wrapped.panes
        }
        if let single = try? jsonDecoder.decode(HerdrPane.self, from: data) {
            return [single]
        }

        throw HerdrParseError.invalidJSON("Could not decode panes from output")
    }

    public static func parsePane(from output: String) throws -> HerdrPane {
        let clean = stripANSIEscapes(output).trimmingCharacters(in: .whitespacesAndNewlines)
        guard !clean.isEmpty else { throw HerdrParseError.emptyOutput }
        let data = Data(clean.utf8)

        if let single = try? jsonDecoder.decode(HerdrPane.self, from: data) {
            return single
        }
        if let list = try? jsonDecoder.decode([HerdrPane].self, from: data), let first = list.first {
            return first
        }
        if let wrapped = try? jsonDecoder.decode(PanesWrapper.self, from: data), let first = wrapped.panes.first {
            return first
        }

        throw HerdrParseError.invalidJSON("Could not decode pane from output")
    }

    public static func parseAgentState(from output: String) throws -> HerdrAgentState {
        let clean = stripANSIEscapes(output).trimmingCharacters(in: .whitespacesAndNewlines)
        guard !clean.isEmpty else { throw HerdrParseError.emptyOutput }
        let data = Data(clean.utf8)

        if let state = try? jsonDecoder.decode(HerdrAgentState.self, from: data) {
            return state
        }
        if let pane = try? jsonDecoder.decode(HerdrPane.self, from: data) {
            return pane.agentState
        }

        let lower = clean.lowercased()
        if lower == "idle" {
            return .idle
        }
        if lower == "working" || lower == "running" || lower == "active" {
            return .working
        }
        if lower == "completed" || lower == "done" || lower == "success" || lower == "finished" {
            return .completed(summary: "")
        }
        if lower.hasPrefix("completed:") || lower.hasPrefix("completed -") || lower.hasPrefix("done:") || lower.hasPrefix("done -") {
            let prefixLen: Int
            if lower.hasPrefix("done:") { prefixLen = 5 }
            else if lower.hasPrefix("done -") { prefixLen = 6 }
            else if lower.hasPrefix("completed:") { prefixLen = 10 }
            else { prefixLen = 11 }
            let summary = clean.dropFirst(prefixLen).trimmingCharacters(in: .whitespacesAndNewlines)
            return .completed(summary: summary)
        }
        if lower == "blocked" || lower == "waiting" {
            return .blocked(reason: "")
        }
        if lower.hasPrefix("blocked:") || lower.hasPrefix("blocked -") || lower.hasPrefix("waiting:") || lower.hasPrefix("waiting -") {
            let prefixLen: Int
            if lower.hasPrefix("blocked:") { prefixLen = 8 }
            else if lower.hasPrefix("blocked -") { prefixLen = 9 }
            else if lower.hasPrefix("waiting:") { prefixLen = 8 }
            else { prefixLen = 9 }
            let reason = clean.dropFirst(prefixLen).trimmingCharacters(in: .whitespacesAndNewlines)
            return .blocked(reason: reason)
        }

        throw HerdrParseError.invalidState(clean)
    }

    public static func parseRecentUnwrapped(from output: String) -> String {
        let clean = stripANSIEscapes(output)
        let trimmed = clean.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty { return "" }

        if trimmed.hasPrefix("{"), trimmed.hasSuffix("}"),
           let data = trimmed.data(using: .utf8),
           let wrapper = try? JSONDecoder().decode(RecentUnwrappedWrapper.self, from: data) {
            if let out = wrapper.output { return out.replacingOccurrences(of: "\r\n", with: "\n") }
            if let text = wrapper.text { return text.replacingOccurrences(of: "\r\n", with: "\n") }
            if let content = wrapper.content { return content.replacingOccurrences(of: "\r\n", with: "\n") }
            if let lines = wrapper.lines { return lines.map { $0.replacingOccurrences(of: "\r\n", with: "\n") }.joined(separator: "\n") }
        }

        return clean.replacingOccurrences(of: "\r\n", with: "\n")
    }
}
