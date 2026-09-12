import Foundation
import ShhCore

public enum MoshBootstrapError: Error, Equatable, LocalizedError, Sendable {
    case serverCommandNotFound(String)
    case executionFailed(exitStatus: Int32, stderr: String)
    case invalidHandshake(String)
    case missingPortOrKey
    case timeout
    case cancelled
    case invalidServerCommand(String)
    case blockedRemoteCommand(String)

    public var errorDescription: String? {
        switch self {
        case .serverCommandNotFound(let cmd):
            return "Remote server command not found: '\(cmd)'"
        case .executionFailed(let exitStatus, let stderr):
            return "mosh-server failed with exit status \(exitStatus): \(stderr)"
        case .invalidHandshake(let output):
            return "Failed to parse MOSH CONNECT handshake from output: \(MoshBootstrapper.redactKeyTokens(in: output))"
        case .missingPortOrKey:
            return "mosh-server output did not contain valid UDP port and session key"
        case .timeout:
            return "mosh-server bootstrap timed out"
        case .cancelled:
            return "mosh-server bootstrap was cancelled"
        case .invalidServerCommand(let cmd):
            return "Invalid mosh server command contains disallowed characters: '\(cmd)'"
        case .blockedRemoteCommand(let cmd):
            return "Remote command was blocked by policy: '\(cmd)'"
        }
    }
}

public struct MoshBootstrapper: Sendable {
    public init() {}

    public static func redactKeyTokens(in text: String) -> String {
        guard let regex = try? NSRegularExpression(pattern: "MOSH CONNECT\\s+(\\S+)\\s+(\\S+)") else {
            return text
        }
        let range = NSRange(text.startIndex..<text.endIndex, in: text)
        return regex.stringByReplacingMatches(in: text, range: range, withTemplate: "MOSH CONNECT $1 [REDACTED]")
    }

    public static func buildCommand(
        options: MoshOptions,
        initialSize: TerminalSize? = nil,
        remoteCommand: String? = nil
    ) throws -> String {
        var parts: [String] = []
        let rawCmd = options.serverCommand.trimmingCharacters(in: .whitespaces)
        let serverCmd = rawCmd.isEmpty ? "mosh-server" : rawCmd

        let allowedCharacterSet = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789/.-_ ")
        guard serverCmd.unicodeScalars.allSatisfy({ allowedCharacterSet.contains($0) }) else {
            throw MoshBootstrapError.invalidServerCommand(serverCmd)
        }

        if serverCmd.contains(" ") {
            parts.append(ShellQuoting.quote(serverCmd))
        } else {
            parts.append(serverCmd)
        }
        parts.append("new")
        parts.append("-s")
        parts.append("-c 256")

        if let portRange = options.portRange {
            parts.append("-p \(portRange.description)")
        }

        if let size = initialSize {
            parts.append("-l rows=\(size.rows)")
        }

        if let remoteCommand, !remoteCommand.trimmingCharacters(in: .whitespaces).isEmpty {
            let trimmedRemote = remoteCommand.trimmingCharacters(in: .whitespaces)
            let policy = CommandPolicy()
            guard policy.classify(trimmedRemote) != .blocked else {
                throw MoshBootstrapError.blockedRemoteCommand(trimmedRemote)
            }
            parts.append("--")
            parts.append(trimmedRemote)
        }

        return parts.joined(separator: " ")
    }

    public static func parseOutput(_ output: String) throws -> MoshSessionInfo {
        let lines = output.components(separatedBy: CharacterSet.newlines)
        var parsedPort: UInt16?
        var parsedKey: String?
        var parsedPid: Int?

        for line in lines {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.isEmpty { continue }

            // Match "MOSH CONNECT <port> <key>"
            if let connectRange = trimmed.range(of: "MOSH CONNECT") {
                let remainder = trimmed[connectRange.upperBound...].trimmingCharacters(in: .whitespaces)
                let tokens = remainder.components(separatedBy: .whitespaces).filter { !$0.isEmpty }
                if tokens.count >= 2 {
                    if let port = UInt16(tokens[0]) {
                        parsedPort = port
                        parsedKey = tokens[1]
                    }
                }
            }

            // Match optional PID pattern
            if parsedPid == nil {
                if let pidRange = trimmed.range(of: "MOSH PID") {
                    let remainder = trimmed[pidRange.upperBound...].trimmingCharacters(in: .whitespaces)
                    let tokens = remainder.components(separatedBy: .whitespaces).filter { !$0.isEmpty }
                    if let first = tokens.first, let pidVal = Int(first) {
                        parsedPid = pidVal
                    }
                } else if let pidMatch = extractPID(from: trimmed) {
                    parsedPid = pidMatch
                }
            }
        }

        guard let port = parsedPort, let key = parsedKey, !key.isEmpty else {
            throw MoshBootstrapError.invalidHandshake(redactKeyTokens(in: output))
        }

        return MoshSessionInfo(udpPort: port, sessionKey: key, pid: parsedPid)
    }

    private static func extractPID(from line: String) -> Int? {
        let lower = line.lowercased()
        if lower.contains("pid") {
            let components = line.components(separatedBy: CharacterSet(charactersIn: " :[](),="))
            for (idx, comp) in components.enumerated() {
                if comp.lowercased() == "pid" && idx + 1 < components.count {
                    let next = components[idx + 1].trimmingCharacters(in: .whitespaces)
                    if let pid = Int(next) { return pid }
                }
            }
        }
        return nil
    }

    public func bootstrap(
        executor: any SSHCommandExecuting,
        options: MoshOptions,
        initialSize: TerminalSize? = nil,
        remoteCommand: String? = nil,
        timeout: TimeInterval? = 15.0
    ) async throws -> MoshSessionInfo {
        let command = try Self.buildCommand(options: options, initialSize: initialSize, remoteCommand: remoteCommand)
        let result = try await executor.executeCommand(command, timeout: timeout, maxOutputBytes: 65536)

        let stdoutStr = result.stdout
        let stderrStr = result.stderr

        if result.exitCode != 0 && stdoutStr.isEmpty {
            let trimmedStderr = stderrStr.trimmingCharacters(in: CharacterSet.whitespacesAndNewlines)
            if trimmedStderr.contains("command not found") || trimmedStderr.contains("not found") {
                throw MoshBootstrapError.serverCommandNotFound(options.serverCommand)
            }
            throw MoshBootstrapError.executionFailed(exitStatus: result.exitCode, stderr: trimmedStderr)
        }

        let combined = stdoutStr + "\n" + stderrStr
        do {
            return try Self.parseOutput(combined)
        } catch {
            if result.exitCode != 0 {
                let trimmedStderr = stderrStr.trimmingCharacters(in: CharacterSet.whitespacesAndNewlines)
                if trimmedStderr.contains("command not found") || trimmedStderr.contains("not found") {
                    throw MoshBootstrapError.serverCommandNotFound(options.serverCommand)
                }
                throw MoshBootstrapError.executionFailed(exitStatus: result.exitCode, stderr: trimmedStderr)
            }
            throw error
        }
    }
}
