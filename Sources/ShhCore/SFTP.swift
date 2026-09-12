import Foundation

// MARK: - POSIX Permissions

public struct PosixPermissions: Hashable, Codable, Sendable, CustomStringConvertible {
    public let rawValue: UInt32

    public init(rawValue: UInt32) {
        self.rawValue = rawValue
    }

    public init(octal: UInt32) {
        self.rawValue = octal
    }

    public init?(octalString: String) {
        guard let value = UInt32(octalString, radix: 8) else { return nil }
        self.rawValue = value
    }

    public var octalValue: UInt32 {
        rawValue & 0o7777
    }

    public var octalString: String {
        String(format: "%04o", octalValue)
    }

    public var ownerRead: Bool { (rawValue & 0o400) != 0 }
    public var ownerWrite: Bool { (rawValue & 0o200) != 0 }
    public var ownerExecute: Bool { (rawValue & 0o100) != 0 }

    public var groupRead: Bool { (rawValue & 0o040) != 0 }
    public var groupWrite: Bool { (rawValue & 0o020) != 0 }
    public var groupExecute: Bool { (rawValue & 0o010) != 0 }

    public var othersRead: Bool { (rawValue & 0o004) != 0 }
    public var othersWrite: Bool { (rawValue & 0o002) != 0 }
    public var othersExecute: Bool { (rawValue & 0o001) != 0 }

    public var setuid: Bool { (rawValue & 0o4000) != 0 }
    public var setgid: Bool { (rawValue & 0o2000) != 0 }
    public var sticky: Bool { (rawValue & 0o1000) != 0 }

    public var isDirectory: Bool { (rawValue & 0o170000) == 0o040000 }
    public var isRegularFile: Bool { (rawValue & 0o170000) == 0o100000 }
    public var isSymlink: Bool { (rawValue & 0o170000) == 0o120000 }
    public var isCharacterDevice: Bool { (rawValue & 0o170000) == 0o020000 }
    public var isBlockDevice: Bool { (rawValue & 0o170000) == 0o060000 }
    public var isFIFO: Bool { (rawValue & 0o170000) == 0o010000 }
    public var isSocket: Bool { (rawValue & 0o170000) == 0o140000 }

    public var entryType: RemoteFileEntryType {
        if isDirectory { return .directory }
        if isSymlink { return .symlink }
        if isRegularFile { return .file }
        return .other
    }

    public var symbolicString: String {
        var result = ""
        result.append(ownerRead ? "r" : "-")
        result.append(ownerWrite ? "w" : "-")
        if setuid {
            result.append(ownerExecute ? "s" : "S")
        } else {
            result.append(ownerExecute ? "x" : "-")
        }

        result.append(groupRead ? "r" : "-")
        result.append(groupWrite ? "w" : "-")
        if setgid {
            result.append(groupExecute ? "s" : "S")
        } else {
            result.append(groupExecute ? "x" : "-")
        }

        result.append(othersRead ? "r" : "-")
        result.append(othersWrite ? "w" : "-")
        if sticky {
            result.append(othersExecute ? "t" : "T")
        } else {
            result.append(othersExecute ? "x" : "-")
        }

        return result
    }

    public var description: String {
        symbolicString
    }

    public static let standardDirectory = PosixPermissions(rawValue: 0o040755)
    public static let standardFile = PosixPermissions(rawValue: 0o100644)
    public static let secureDirectory = PosixPermissions(rawValue: 0o040700)
    public static let secureFile = PosixPermissions(rawValue: 0o100600)
    public static let executableFile = PosixPermissions(rawValue: 0o100755)
}

// MARK: - Remote File Entry Type

public enum RemoteFileEntryType: String, Codable, Sendable, Hashable, CaseIterable {
    case file
    case directory
    case symlink
    case other

    public var isDirectory: Bool { self == .directory }
    public var isFile: Bool { self == .file }
    public var isSymlink: Bool { self == .symlink }
}

public typealias RemoteFileType = RemoteFileEntryType

// MARK: - SFTP Repository Error

public enum SFTPRepositoryError: Error, Equatable, Sendable, LocalizedError {
    case notFound(path: String)
    case permissionDenied(path: String)
    case alreadyExists(path: String)
    case isDirectory(path: String)
    case notADirectory(path: String)
    case directoryNotEmpty(path: String)
    case invalidPath(String)
    case cancelled
    case connectionClosed
    case remoteFailure(String)

    public var errorDescription: String? {
        switch self {
        case .notFound(let path):
            return "No such file or directory: \(path)"
        case .permissionDenied(let path):
            return "Permission denied: \(path)"
        case .alreadyExists(let path):
            return "File or directory already exists: \(path)"
        case .isDirectory(let path):
            return "Path is a directory: \(path)"
        case .notADirectory(let path):
            return "Path is not a directory: \(path)"
        case .directoryNotEmpty(let path):
            return "Directory is not empty: \(path)"
        case .invalidPath(let details):
            return "Invalid path: \(details)"
        case .cancelled:
            return "Operation cancelled"
        case .connectionClosed:
            return "SFTP connection closed"
        case .remoteFailure(let details):
            return "SFTP failure: \(details)"
        }
    }
}

// MARK: - Transfer Models

public enum TransferDirection: String, Codable, Sendable, Hashable, CaseIterable {
    case upload
    case download
}

public enum TransferState: String, Codable, Sendable, Hashable, CaseIterable {
    case queued
    case transferring
    case completed
    case failed
    case cancelled

    public var isTerminal: Bool {
        switch self {
        case .completed, .failed, .cancelled:
            return true
        case .queued, .transferring:
            return false
        }
    }
}

public struct TransferProgress: Hashable, Sendable, Codable {
    public var bytesTransferred: Int64
    public var totalBytes: Int64

    public init(bytesTransferred: Int64, totalBytes: Int64) {
        self.bytesTransferred = bytesTransferred
        self.totalBytes = totalBytes
    }

    public var fractionCompleted: Double {
        guard totalBytes > 0 else { return 0.0 }
        return min(1.0, max(0.0, Double(bytesTransferred) / Double(totalBytes)))
    }
}

public struct TransferTask: Identifiable, Hashable, Sendable, Codable {
    public let id: UUID
    public var direction: TransferDirection
    public var remotePath: RemotePath
    public var localURL: URL
    public var state: TransferState
    public var bytesTransferred: Int64
    public var totalBytes: Int64
    public var errorMessage: String?
    public var createdAt: Date
    public var updatedAt: Date

    public var fractionCompleted: Double {
        guard totalBytes > 0 else { return 0.0 }
        return min(1.0, max(0.0, Double(bytesTransferred) / Double(totalBytes)))
    }

    public init(
        id: UUID = UUID(),
        direction: TransferDirection,
        remotePath: RemotePath,
        localURL: URL,
        state: TransferState = .queued,
        bytesTransferred: Int64 = 0,
        totalBytes: Int64 = 0,
        errorMessage: String? = nil,
        createdAt: Date = Date(),
        updatedAt: Date = Date()
    ) {
        self.id = id
        self.direction = direction
        self.remotePath = remotePath
        self.localURL = localURL
        self.state = state
        self.bytesTransferred = bytesTransferred
        self.totalBytes = totalBytes
        self.errorMessage = errorMessage
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }
}

public struct TransferQueueState: Hashable, Sendable, Codable {
    public var tasks: [TransferTask]

    public init(tasks: [TransferTask] = []) {
        self.tasks = tasks
    }

    public var queuedTasks: [TransferTask] {
        tasks.filter { $0.state == .queued }
    }

    public var activeTasks: [TransferTask] {
        tasks.filter { $0.state == .transferring }
    }

    public var completedTasks: [TransferTask] {
        tasks.filter { $0.state == .completed }
    }

    public var failedTasks: [TransferTask] {
        tasks.filter { $0.state == .failed }
    }

    public var cancelledTasks: [TransferTask] {
        tasks.filter { $0.state == .cancelled }
    }

    public var totalBytesTransferred: Int64 {
        tasks.reduce(0) { $0 + $1.bytesTransferred }
    }

    public var totalExpectedBytes: Int64 {
        tasks.reduce(0) { $0 + $1.totalBytes }
    }

    public var overallProgress: Double {
        let total = totalExpectedBytes
        guard total > 0 else { return 0.0 }
        return min(1.0, max(0.0, Double(totalBytesTransferred) / Double(total)))
    }

    public func task(withID id: UUID) -> TransferTask? {
        tasks.first { $0.id == id }
    }

    public mutating func enqueue(_ task: TransferTask) {
        tasks.append(task)
    }

    public mutating func update(_ task: TransferTask) {
        if let idx = tasks.firstIndex(where: { $0.id == task.id }) {
            tasks[idx] = task
        }
    }

    public mutating func remove(id: UUID) {
        tasks.removeAll { $0.id == id }
    }

    public mutating func clearTerminal() {
        tasks.removeAll { $0.state.isTerminal }
    }
}

public actor TransferQueueCoordinator {
    private var state: TransferQueueState = TransferQueueState()
    private var taskCancels: [UUID: @Sendable () -> Void] = [:]

    public init() {}

    public func snapshot() -> TransferQueueState {
        state
    }

    @discardableResult
    public func enqueue(
        direction: TransferDirection,
        remotePath: RemotePath,
        localURL: URL,
        totalBytes: Int64 = 0
    ) -> TransferTask {
        let task = TransferTask(
            direction: direction,
            remotePath: remotePath,
            localURL: localURL,
            state: .queued,
            totalBytes: totalBytes
        )
        state.enqueue(task)
        return task
    }

    public func updateProgress(id: UUID, bytesTransferred: Int64, totalBytes: Int64) {
        guard var task = state.task(withID: id) else { return }
        task.state = .transferring
        task.bytesTransferred = bytesTransferred
        task.totalBytes = max(task.totalBytes, totalBytes)
        task.updatedAt = Date()
        state.update(task)
    }

    public func markCompleted(id: UUID) {
        guard var task = state.task(withID: id) else { return }
        task.state = .completed
        task.bytesTransferred = max(task.bytesTransferred, task.totalBytes)
        task.updatedAt = Date()
        state.update(task)
        taskCancels.removeValue(forKey: id)
    }

    public func markFailed(id: UUID, error: String) {
        guard var task = state.task(withID: id) else { return }
        task.state = .failed
        task.errorMessage = error
        task.updatedAt = Date()
        state.update(task)
        taskCancels.removeValue(forKey: id)
    }

    public func cancel(id: UUID) {
        guard var task = state.task(withID: id) else { return }
        task.state = .cancelled
        task.updatedAt = Date()
        state.update(task)
        if let cancelHandler = taskCancels.removeValue(forKey: id) {
            cancelHandler()
        }
    }

    public func registerCancellation(id: UUID, handler: @escaping @Sendable () -> Void) {
        taskCancels[id] = handler
    }

    public func remove(id: UUID) {
        state.remove(id: id)
        taskCancels.removeValue(forKey: id)
    }

    public func clearTerminal() {
        state.clearTerminal()
    }
}

// MARK: - File Sort & Conflict Models

public enum FileSortField: String, CaseIterable, Identifiable, Sendable, Codable {
    case name = "Name"
    case date = "Date"
    case size = "Size"
    case type = "Type"

    public var id: String { rawValue }
}

public struct FileTransferConflict: Identifiable, @unchecked Sendable {
    public let id: UUID
    public let direction: TransferDirection
    public let remotePath: RemotePath
    public let localURL: URL
    public let existingItemName: String
    public let destinationDescription: String
    public let continuation: @Sendable (Bool) -> Void

    public init(
        id: UUID = UUID(),
        direction: TransferDirection,
        remotePath: RemotePath,
        localURL: URL,
        existingItemName: String,
        destinationDescription: String,
        continuation: @escaping @Sendable (Bool) -> Void
    ) {
        self.id = id
        self.direction = direction
        self.remotePath = remotePath
        self.localURL = localURL
        self.existingItemName = existingItemName
        self.destinationDescription = destinationDescription
        self.continuation = continuation
    }
}

// MARK: - SFTP Repository Protocol

public protocol SFTPRepository: Sendable {
    func listDirectory(at path: RemotePath) async throws -> [RemoteFile]
    func readFile(at path: RemotePath) async throws -> Data
    func download(from remotePath: RemotePath, to localURL: URL, progress: (@Sendable (TransferProgress) -> Void)?) async throws
    func writeFile(data: Data, at remotePath: RemotePath, progress: (@Sendable (TransferProgress) -> Void)?) async throws
    func upload(from localURL: URL, to remotePath: RemotePath, progress: (@Sendable (TransferProgress) -> Void)?) async throws
    func createDirectory(at path: RemotePath) async throws
    func removeFile(at path: RemotePath) async throws
    func removeDirectory(at path: RemotePath) async throws
    func rename(from oldPath: RemotePath, to newPath: RemotePath) async throws
    func fetchAttributes(at path: RemotePath) async throws -> RemoteFile
}
