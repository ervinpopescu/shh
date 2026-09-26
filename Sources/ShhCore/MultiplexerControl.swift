import Foundation

// MARK: - Typed out-of-band multiplexer controls

/// Every value used to address a tmux object is validated before it reaches a
/// shell command. This deliberately does not accept names as targets.
public struct TmuxWindowID: Hashable, Sendable, Codable, CustomStringConvertible {
    public let value: String
    public init(_ value: String) throws {
        let valid = (value.hasPrefix("@") ? String(value.dropFirst()) : value)
        guard !valid.isEmpty, valid.allSatisfy(\.isNumber) else {
            throw MultiplexerControlError.invalidIdentifier(value)
        }
        self.value = value.hasPrefix("@") ? value : "@" + value
    }
    public var description: String { value }
    public var shellArgument: String { ShellQuoting.quote(value) }
}

public struct TmuxPaneID: Hashable, Sendable, Codable, CustomStringConvertible {
    public let value: String
    public init(_ value: String) throws {
        let valid = (value.hasPrefix("%") ? String(value.dropFirst()) : value)
        guard !valid.isEmpty, valid.allSatisfy(\.isNumber) else {
            throw MultiplexerControlError.invalidIdentifier(value)
        }
        self.value = value.hasPrefix("%") ? value : "%" + value
    }
    public var description: String { value }
    public var shellArgument: String { ShellQuoting.quote(value) }
}

/// tmux reports client_tty as an absolute tty path. Keeping this type strict
/// prevents a detach operation from accidentally becoming a selector.
public struct TmuxClientTTY: Hashable, Sendable, Codable, CustomStringConvertible {
    public let value: String
    public init(_ value: String) throws {
        guard value.hasPrefix("/"), value.count <= 512,
            value.allSatisfy({
                $0.isASCII
                    && ($0.isLetter || $0.isNumber || $0 == "/" || $0 == "_" || $0 == "-"
                        || $0 == ".")
            })
        else {
            throw MultiplexerControlError.invalidIdentifier(value)
        }
        self.value = value
    }
    public var description: String { value }
    public var shellArgument: String { ShellQuoting.quote(value) }
}

public struct TmuxWindowTarget: Hashable, Sendable, Codable {
    public let sessionID: TmuxSessionID
    public let windowID: TmuxWindowID
    public init(sessionID: TmuxSessionID, windowID: TmuxWindowID) {
        self.sessionID = sessionID
        self.windowID = windowID
    }
    public var value: String { "\(sessionID.value):\(windowID.value)" }
    public var shellArgument: String { ShellQuoting.quote(value) }
}

public struct TmuxPaneTarget: Hashable, Sendable, Codable {
    public let sessionID: TmuxSessionID
    public let windowID: TmuxWindowID?
    public let paneID: TmuxPaneID?
    public init(sessionID: TmuxSessionID, windowID: TmuxWindowID? = nil, paneID: TmuxPaneID? = nil)
    {
        self.sessionID = sessionID
        self.windowID = windowID
        self.paneID = paneID
    }
    public var value: String {
        if let windowID, let paneID {
            return "\(sessionID.value):\(windowID.value).\(paneID.value)"
        } else if let windowID {
            return "\(sessionID.value):\(windowID.value)"
        } else {
            return sessionID.value
        }
    }
    public var shellArgument: String { ShellQuoting.quote(value) }
}

public struct TmuxControlTarget: Hashable, Sendable, Codable {
    public let sessionID: TmuxSessionID
    public let window: TmuxWindowTarget?
    public let pane: TmuxPaneTarget?
    public let clientTTY: TmuxClientTTY?

    public init(
        sessionID: TmuxSessionID, window: TmuxWindowTarget? = nil,
        pane: TmuxPaneTarget? = nil, clientTTY: TmuxClientTTY? = nil
    ) {
        self.sessionID = sessionID
        self.window = window
        self.pane = pane
        self.clientTTY = clientTTY
    }
}

public enum TmuxPaneDirection: String, CaseIterable, Hashable, Sendable {
    case left, right, up, down

    public var flag: String {
        switch self {
        case .left: return "L"
        case .right: return "R"
        case .up: return "U"
        case .down: return "D"
        }
    }
}

public enum TmuxControlAction: Hashable, Sendable {
    case attachSession(TmuxSessionID)
    case createSession(TmuxSessionName)
    case previousWindow(TmuxSessionID)
    case nextWindow(TmuxSessionID)
    case focusPane(TmuxPaneTarget, direction: TmuxPaneDirection)
    case split(TmuxPaneTarget, vertical: Bool)
    case toggleZoom(TmuxPaneTarget)
    case renameWindow(TmuxWindowTarget, name: TmuxSessionName)
    case sessionPicker(TmuxSessionID)
    case windowPicker(TmuxPaneTarget)
    case copyMode(TmuxPaneTarget)
    case closePane(TmuxPaneTarget)
    case detachClient(session: TmuxSessionID, expectedTTY: TmuxClientTTY?)

    /// All tmux controls mutate multiplexer state or enter an interactive mode.
    /// The command policy classifies them as review-required, so every dial
    /// control must present the same explicit approval affordance.
    public var requiresConfirmation: Bool {
        true
    }
}

public enum HerdrControlAction: Hashable, Sendable {
    case workspaceList
    case workspaceCreate(cwd: String, label: String)
    case tabCreate(label: String)
    case paneList(workspaceID: String?)
    case paneSplit(paneID: String, direction: String)
    case paneRun(paneID: String, command: String)
    case paneRead(paneID: String, source: String)
    case waitAgentStatus(paneID: String?, status: String?)
    case status

    public var requiresConfirmation: Bool {
        if case .paneRun = self { return true }
        return false
    }
}

public enum MultiplexerControlAction: Hashable, Sendable {
    case tmux(TmuxControlAction)
    case herdr(HerdrControlAction)

    public var requiresConfirmation: Bool {
        switch self {
        case .tmux(let action): return action.requiresConfirmation
        case .herdr(let action): return action.requiresConfirmation
        }
    }

    public var displayName: String {
        switch self {
        case .tmux(let action):
            switch action {
            case .previousWindow: return "Previous Window"
            case .nextWindow: return "Next Window"
            case .focusPane(_, let direction): return "Focus \(direction.rawValue.capitalized)"
            case .split(_, let vertical): return vertical ? "Split Vertical" : "Split Horizontal"
            case .toggleZoom: return "Toggle Zoom"
            case .sessionPicker: return "Choose Session"
            case .windowPicker: return "Choose Window"
            case .copyMode: return "Copy Mode"
            case .closePane: return "Close Pane"
            case .attachSession: return "Attach Session"
            case .createSession: return "Create Session"
            case .renameWindow: return "Rename Window"
            case .detachClient: return "Detach Client"
            }
        case .herdr(let action):
            switch action {
            case .workspaceList: return "List Workspaces"
            case .workspaceCreate: return "Create Workspace"
            case .tabCreate: return "Create Tab"
            case .paneList: return "List Panes"
            case .paneSplit: return "Split Pane"
            case .paneRun: return "Run Pane Command"
            case .paneRead: return "Read Pane"
            case .waitAgentStatus: return "Wait for Agent"
            case .status: return "Agent Status"
            }
        }
    }
}

public enum MultiplexerControlError: Error, Equatable, Sendable, LocalizedError {
    case invalidIdentifier(String)
    case unsupportedAction
    case missingTarget
    case ambiguousClient
    case clientNotFound
    case unavailable(String)

    public var errorDescription: String? {
        switch self {
        case .invalidIdentifier: return "The multiplexer identifier is invalid."
        case .unsupportedAction: return "This multiplexer does not support that control."
        case .missingTarget: return "The focused multiplexer object could not be resolved."
        case .ambiguousClient: return "The Shh tmux client could not be identified unambiguously."
        case .clientNotFound: return "The Shh tmux client is no longer connected."
        case .unavailable(let reason): return reason
        }
    }
}

public enum MultiplexerCapability: String, CaseIterable, Hashable, Sendable, Codable {
    case attachSession, createSession, previousWindow, nextWindow, directionalFocus,
        horizontalSplit, verticalSplit
    case zoom, rename, sessionPicker, windowPicker, copyMode, closePane, detachClient
    case workspaceList, workspaceCreate, tabCreate, paneList, paneSplit, paneRun, paneRead,
        waitAgentStatus, status
}

public struct MultiplexerCapabilities: Hashable, Sendable, Codable {
    public let kind: RemoteMultiplexer
    public let supported: Set<MultiplexerCapability>
    public init(kind: RemoteMultiplexer, supported: Set<MultiplexerCapability>) {
        self.kind = kind
        self.supported = supported
    }
    public func contains(_ capability: MultiplexerCapability) -> Bool {
        supported.contains(capability)
    }

    public static let tmux = MultiplexerCapabilities(
        kind: .tmux,
        supported: [
            .attachSession, .createSession, .previousWindow, .nextWindow, .directionalFocus,
            .horizontalSplit, .verticalSplit, .zoom, .rename, .sessionPicker, .windowPicker,
            .copyMode, .closePane, .detachClient,
        ])
    /// Herdr capabilities mirror the currently modeled workspace and pane
    /// objects. There is intentionally no tmux-style focus, zoom, detach, or
    /// close capability here.
    public static let herdr = MultiplexerCapabilities(
        kind: .herdr,
        supported: [
            .workspaceList, .workspaceCreate, .tabCreate, .paneList, .paneSplit,
            .paneRun, .paneRead, .waitAgentStatus, .status,
        ])
}

public protocol MultiplexerControl: Sendable {
    var kind: RemoteMultiplexer { get }
    var capabilities: MultiplexerCapabilities { get }
    func command(for action: MultiplexerControlAction) throws -> String
    func execute(_ action: MultiplexerControlAction, using executor: any SSHCommandExecuting)
        async throws -> SSHCommandResult
}

private func validatedHerdrIdentifier(_ value: String) throws -> String {
    guard !value.isEmpty, value.count <= 256,
        !value.unicodeScalars.contains(where: { $0.value < 0x20 || $0.properties.isWhitespace })
    else {
        throw MultiplexerControlError.invalidIdentifier(value)
    }
    return value
}

private func executablePrefix(_ executable: String) throws -> String {
    guard
        executable == "tmux" || executable == "herdr"
            || (executable.hasPrefix("/") && executable.count <= 512
                && !executable.unicodeScalars.contains(where: {
                    $0.value < 0x20 || $0.properties.isWhitespace
                }))
    else {
        throw MultiplexerControlError.invalidIdentifier(executable)
    }
    return executable == "tmux" || executable == "herdr"
        ? executable : ShellQuoting.quote(executable)
}

public struct TmuxControl: MultiplexerControl {
    public let kind: RemoteMultiplexer = .tmux
    public let capabilities: MultiplexerCapabilities = .tmux
    public let executable: String
    public init(executable: String = "tmux") throws {
        _ = try executablePrefix(executable)
        self.executable = executable == "tmux" ? executable : ShellQuoting.quote(executable)
    }

    public func command(for action: MultiplexerControlAction) throws -> String {
        guard case .tmux(let action) = action else {
            throw MultiplexerControlError.unsupportedAction
        }
        let binary = executable
        switch action {
        case .attachSession(let session):
            return "env -u TMUX \(binary) attach-session -d -t \(session.shellArgument)"
        case .createSession(let name): return "\(binary) new-session -A -D -s \(name.shellArgument)"
        case .previousWindow(let session):
            return "\(binary) previous-window -t \(session.shellArgument)"
        case .nextWindow(let session): return "\(binary) next-window -t \(session.shellArgument)"
        case .focusPane(let target, let direction):
            return "\(binary) select-pane -t \(target.shellArgument) -\(direction.flag)"
        case .split(let target, let vertical):
            return "\(binary) split-window -\(vertical ? "v" : "h") -t \(target.shellArgument)"
        case .toggleZoom(let target): return "\(binary) resize-pane -Z -t \(target.shellArgument)"
        case .renameWindow(let target, let name):
            return "\(binary) rename-window -t \(target.shellArgument) \(name.shellArgument)"
        case .sessionPicker(let session):
            return "\(binary) choose-tree -s -w -t \(session.shellArgument)"
        case .windowPicker(let target): return "\(binary) choose-tree -w -t \(target.shellArgument)"
        case .copyMode(let target): return "\(binary) copy-mode -t \(target.shellArgument)"
        case .closePane(let target): return "\(binary) kill-pane -t \(target.shellArgument)"
        case .detachClient(let session, let expectedTTY):
            guard let tty = expectedTTY else { throw MultiplexerControlError.missingTarget }
            return "\(binary) detach-client -s \(session.shellArgument) -t \(tty.shellArgument)"
        }
    }

    public func execute(_ action: MultiplexerControlAction, using executor: any SSHCommandExecuting)
        async throws -> SSHCommandResult
    {
        if case .tmux(.detachClient(let session, let expectedTTY)) = action, expectedTTY == nil {
            // Resolve from tmux's client table immediately before detaching. In
            // particular, never guess based on list order or detach a session.
            let identity = try await TmuxClientResolver.resolve(sessionID: session, using: executor)
            return try await executor.executeCommand(
                command(for: .tmux(.detachClient(session: session, expectedTTY: identity.tty))))
        }
        return try await executor.executeCommand(command(for: action))
    }
}

public struct HerdrControl: MultiplexerControl {
    public let kind: RemoteMultiplexer = .herdr
    public let capabilities: MultiplexerCapabilities = .herdr
    public let executable: String
    public init(executable: String = "herdr") throws {
        _ = try executablePrefix(executable)
        self.executable = executable == "herdr" ? executable : ShellQuoting.quote(executable)
    }

    public func command(for action: MultiplexerControlAction) throws -> String {
        guard case .herdr(let action) = action else {
            throw MultiplexerControlError.unsupportedAction
        }
        let binary = executable
        switch action {
        case .workspaceList: return "\(binary) workspace list --format 'json'"
        case .workspaceCreate(let cwd, let label):
            return
                "\(binary) workspace create --cwd \(ShellQuoting.quote(cwd)) --label \(ShellQuoting.quote(label))"
        case .tabCreate(let label):
            return "\(binary) tab create --label \(ShellQuoting.quote(label))"
        case .paneList(let workspaceID):
            if let workspaceID {
                return
                    "\(binary) pane list \(ShellQuoting.quote(try validatedHerdrIdentifier(workspaceID))) --format 'json'"
            }
            return "\(binary) pane list --format 'json'"
        case .paneSplit(let paneID, let direction):
            guard ["left", "right", "up", "down"].contains(direction.lowercased()) else {
                throw MultiplexerControlError.unsupportedAction
            }
            return
                "\(binary) pane split \(ShellQuoting.quote(try validatedHerdrIdentifier(paneID))) --direction \(ShellQuoting.quote(direction.lowercased()))"
        case .paneRun(let paneID, let command):
            return
                "\(binary) pane run \(ShellQuoting.quote(try validatedHerdrIdentifier(paneID))) \(ShellQuoting.quote(command))"
        case .paneRead(let paneID, let source):
            return
                "\(binary) pane read \(ShellQuoting.quote(try validatedHerdrIdentifier(paneID))) --source \(ShellQuoting.quote(try validatedHerdrIdentifier(source)))"
        case .waitAgentStatus(let paneID, let status):
            var result = "\(binary) wait agent-status"
            if let paneID {
                result += " \(ShellQuoting.quote(try validatedHerdrIdentifier(paneID)))"
            }
            if let status {
                result += " --status \(ShellQuoting.quote(try validatedHerdrIdentifier(status)))"
            }
            return result
        case .status: return "\(binary) status --format 'json'"
        }
    }

    public func execute(_ action: MultiplexerControlAction, using executor: any SSHCommandExecuting)
        async throws -> SSHCommandResult
    {
        try await executor.executeCommand(command(for: action))
    }
}

// MARK: - Client identity resolution

public struct TmuxClientIdentity: Hashable, Sendable {
    public let tty: TmuxClientTTY
    public let sessionID: TmuxSessionID
    public init(tty: TmuxClientTTY, sessionID: TmuxSessionID) {
        self.tty = tty
        self.sessionID = sessionID
    }
}

public enum TmuxClientResolver {
    public static let listCommand = "tmux list-clients -F '#{client_tty}\t#{session_id}'"

    public static func parse(_ output: String) throws -> [TmuxClientIdentity] {
        try output.split(whereSeparator: \.isNewline).map { line in
            let fields = line.split(separator: "\t", omittingEmptySubsequences: false)
            guard fields.count == 2,
                let tty = try? TmuxClientTTY(String(fields[0])),
                let session = try? TmuxSessionID(String(fields[1]))
            else {
                throw MultiplexerControlError.invalidIdentifier(String(line))
            }
            return TmuxClientIdentity(tty: tty, sessionID: session)
        }
    }

    /// A session may have several clients. Selecting one by list order is
    /// unsafe, so ambiguity is always rejected.
    public static func resolve(
        sessionID: TmuxSessionID, expectedTTY: TmuxClientTTY? = nil,
        using executor: any SSHCommandExecuting
    ) async throws -> TmuxClientIdentity {
        let result = try await executor.executeCommand(listCommand)
        guard result.isSuccess else { throw MultiplexerControlError.clientNotFound }
        let clients = try parse(result.stdout).filter { $0.sessionID == sessionID }
        if let expectedTTY {
            let matches = clients.filter { $0.tty == expectedTTY }
            guard matches.count == 1, let match = matches.first else {
                throw matches.isEmpty
                    ? MultiplexerControlError.clientNotFound
                    : MultiplexerControlError.ambiguousClient
            }
            return match
        }
        guard clients.count == 1, let only = clients.first else {
            throw clients.isEmpty
                ? MultiplexerControlError.clientNotFound : MultiplexerControlError.ambiguousClient
        }
        return only
    }
}
