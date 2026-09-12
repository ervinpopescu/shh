import Foundation

private struct DemoNode: Sendable {
    var path: RemotePath
    var name: String
    var entryType: RemoteFileEntryType
    var size: Int64
    var permissions: PosixPermissions
    var modificationDate: Date
    var accessDate: Date
    var symlinkTarget: String?
    var data: Data?

    func toRemoteFile() -> RemoteFile {
        RemoteFile(
            id: path.description,
            name: name,
            path: path,
            entryType: entryType,
            size: size,
            permissions: permissions,
            modificationDate: modificationDate,
            accessDate: accessDate,
            symlinkTarget: symlinkTarget
        )
    }
}

public actor DemoSFTPRepository: SFTPRepository, RemoteFileRepository {
    private var nodes: [String: DemoNode] = [:]
    public var simulateTransferChunkDelay: TimeInterval = 0

    public init(seedDemoData: Bool = true) {
        if seedDemoData {
            self.nodes = Self.makeDefaultHierarchy()
        } else {
            self.nodes = Self.makeMinimalHierarchy()
        }
    }

    public func reset(seedDemoData: Bool = true) {
        if seedDemoData {
            self.nodes = Self.makeDefaultHierarchy()
        } else {
            self.nodes = Self.makeMinimalHierarchy()
        }
    }

    public func seedDefaultHierarchy() {
        self.nodes = Self.makeDefaultHierarchy()
    }

    private static func makeMinimalHierarchy() -> [String: DemoNode] {
        let root = RemotePath.root
        return [
            root.description: DemoNode(
                path: root,
                name: "/",
                entryType: .directory,
                size: 4096,
                permissions: .standardDirectory,
                modificationDate: Date(),
                accessDate: Date(),
                symlinkTarget: nil,
                data: nil
            )
        ]
    }

    private static func makeDefaultHierarchy() -> [String: DemoNode] {
        var result: [String: DemoNode] = [:]
        let now = Date(timeIntervalSince1970: 1700000000)

        func addDir(_ path: RemotePath, _ perms: PosixPermissions) {
            result[path.description] = DemoNode(
                path: path,
                name: path.isRoot ? "/" : path.lastComponent,
                entryType: .directory,
                size: 4096,
                permissions: perms,
                modificationDate: now,
                accessDate: now,
                symlinkTarget: nil,
                data: nil
            )
        }

        func addFile(_ path: RemotePath, _ data: Data, _ perms: PosixPermissions) {
            result[path.description] = DemoNode(
                path: path,
                name: path.lastComponent,
                entryType: .file,
                size: Int64(data.count),
                permissions: perms,
                modificationDate: now,
                accessDate: now,
                symlinkTarget: nil,
                data: data
            )
        }

        func addSymlink(_ path: RemotePath, _ target: String) {
            result[path.description] = DemoNode(
                path: path,
                name: path.lastComponent,
                entryType: .symlink,
                size: Int64(target.utf8.count),
                permissions: PosixPermissions(rawValue: 0o120777),
                modificationDate: now,
                accessDate: now,
                symlinkTarget: target,
                data: nil
            )
        }

        // Root
        addDir(.root, .standardDirectory)

        // /home & /home/dev
        addDir(RemotePath("/home"), .standardDirectory)
        addDir(RemotePath("/home/dev"), PosixPermissions(rawValue: 0o040750))

        // /home/dev/.bashrc
        let bashrc = """
        # ~/.bashrc: executed by bash(1) for non-login shells.
        export PS1='\\u@\\h:\\w\\$ '
        alias ll='ls -la'
        alias la='ls -A'
        alias l='ls -CF'
        """.data(using: .utf8)!
        addFile(RemotePath("/home/dev/.bashrc"), bashrc, .standardFile)

        // /home/dev/.ssh & authorized_keys
        addDir(RemotePath("/home/dev/.ssh"), .secureDirectory)
        let authKeys = "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIGt79f4Y6uE3xO demo@ipad\n".data(using: .utf8)!
        addFile(RemotePath("/home/dev/.ssh/authorized_keys"), authKeys, .secureFile)

        // /home/dev/projects/shh
        addDir(RemotePath("/home/dev/projects"), .standardDirectory)
        addDir(RemotePath("/home/dev/projects/shh"), .standardDirectory)
        let readme = "# Shh\niPadOS SSH and SFTP client.\n".data(using: .utf8)!
        addFile(RemotePath("/home/dev/projects/shh/README.md"), readme, .standardFile)

        // /home/dev/notes.txt
        let notes = "Milestone 6 Stage 1: SFTP models and repository protocol.\n".data(using: .utf8)!
        addFile(RemotePath("/home/dev/notes.txt"), notes, .standardFile)

        // /home/dev/current_project -> /home/dev/projects/shh
        addSymlink(RemotePath("/home/dev/current_project"), "/home/dev/projects/shh")

        // /var/log/system.log
        addDir(RemotePath("/var"), .standardDirectory)
        addDir(RemotePath("/var/log"), .standardDirectory)
        let syslog = "Sep 12 12:00:00 server sshd[1234]: Accepted publickey for dev\n".data(using: .utf8)!
        addFile(RemotePath("/var/log/system.log"), syslog, PosixPermissions(rawValue: 0o100640))

        // /etc/hosts & /etc/os-release
        addDir(RemotePath("/etc"), .standardDirectory)
        let hosts = "127.0.0.1 localhost\n::1 localhost\n".data(using: .utf8)!
        addFile(RemotePath("/etc/hosts"), hosts, .standardFile)
        let osRelease = "NAME=\"Debian GNU/Linux\"\nVERSION=\"12 (bookworm)\"\nID=debian\n".data(using: .utf8)!
        addFile(RemotePath("/etc/os-release"), osRelease, .standardFile)

        // /tmp with sticky bit (01777)
        addDir(RemotePath("/tmp"), PosixPermissions(rawValue: 0o041777))

        return result
    }

    // MARK: - Testing Affordances

    public func addFile(at path: RemotePath, data: Data, permissions: PosixPermissions = .standardFile) {
        nodes[path.description] = DemoNode(
            path: path,
            name: path.lastComponent,
            entryType: .file,
            size: Int64(data.count),
            permissions: permissions,
            modificationDate: Date(),
            accessDate: Date(),
            symlinkTarget: nil,
            data: data
        )
    }

    public func addDirectory(at path: RemotePath, permissions: PosixPermissions = .standardDirectory) {
        nodes[path.description] = DemoNode(
            path: path,
            name: path.isRoot ? "/" : path.lastComponent,
            entryType: .directory,
            size: 4096,
            permissions: permissions,
            modificationDate: Date(),
            accessDate: Date(),
            symlinkTarget: nil,
            data: nil
        )
    }

    public func addSymlink(at path: RemotePath, target: String) {
        nodes[path.description] = DemoNode(
            path: path,
            name: path.lastComponent,
            entryType: .symlink,
            size: Int64(target.utf8.count),
            permissions: PosixPermissions(rawValue: 0o120777),
            modificationDate: Date(),
            accessDate: Date(),
            symlinkTarget: target,
            data: nil
        )
    }

    // MARK: - SFTPRepository & RemoteFileRepository Implementation

    public func listDirectory(at path: RemotePath) async throws -> [RemoteFile] {
        try Task.checkCancellation()
        guard let parentNode = nodes[path.description] else {
            throw SFTPRepositoryError.notFound(path: path.description)
        }
        guard parentNode.entryType == .directory else {
            throw SFTPRepositoryError.notADirectory(path: path.description)
        }

        let directChildren = nodes.values.filter { node in
            node.path != path && node.path.parent == path
        }

        return directChildren.map { $0.toRemoteFile() }.sorted { lhs, rhs in
            if lhs.isDirectory != rhs.isDirectory {
                return lhs.isDirectory && !rhs.isDirectory
            }
            return lhs.name.localizedStandardCompare(rhs.name) == .orderedAscending
        }
    }

    public func fetchAttributes(at path: RemotePath) async throws -> RemoteFile {
        try Task.checkCancellation()
        guard let node = nodes[path.description] else {
            throw SFTPRepositoryError.notFound(path: path.description)
        }
        return node.toRemoteFile()
    }

    public func readFile(at path: RemotePath) async throws -> Data {
        try Task.checkCancellation()
        guard let node = nodes[path.description] else {
            throw SFTPRepositoryError.notFound(path: path.description)
        }
        guard node.entryType != .directory else {
            throw SFTPRepositoryError.isDirectory(path: path.description)
        }
        return node.data ?? Data()
    }

    public func writeFile(
        data: Data,
        at remotePath: RemotePath,
        progress: (@Sendable (TransferProgress) -> Void)? = nil
    ) async throws {
        try Task.checkCancellation()
        guard let parentNode = nodes[remotePath.parent.description], parentNode.entryType == .directory else {
            throw SFTPRepositoryError.notFound(path: remotePath.parent.description)
        }
        if let existing = nodes[remotePath.description], existing.entryType == .directory {
            throw SFTPRepositoryError.isDirectory(path: remotePath.description)
        }

        let totalBytes = Int64(data.count)
        var bytesTransferred: Int64 = 0
        let chunkSize = 32 * 1024

        if totalBytes == 0 {
            try Task.checkCancellation()
            progress?(TransferProgress(bytesTransferred: 0, totalBytes: 0))
        } else {
            while bytesTransferred < totalBytes {
                try Task.checkCancellation()
                if simulateTransferChunkDelay > 0 {
                    try await Task.sleep(nanoseconds: UInt64(simulateTransferChunkDelay * 1_000_000_000))
                }
                let step = min(chunkSize, Int(totalBytes - bytesTransferred))
                bytesTransferred += Int64(step)
                progress?(TransferProgress(bytesTransferred: bytesTransferred, totalBytes: totalBytes))
            }
        }

        let now = Date()
        nodes[remotePath.description] = DemoNode(
            path: remotePath,
            name: remotePath.lastComponent,
            entryType: .file,
            size: totalBytes,
            permissions: .standardFile,
            modificationDate: now,
            accessDate: now,
            symlinkTarget: nil,
            data: data
        )
    }

    public func download(
        from remotePath: RemotePath,
        to localURL: URL,
        progress: (@Sendable (TransferProgress) -> Void)? = nil
    ) async throws {
        try Task.checkCancellation()
        let data = try await readFile(at: remotePath)
        let totalBytes = Int64(data.count)
        var bytesTransferred: Int64 = 0
        let chunkSize = 32 * 1024

        let tempURL = localURL.deletingLastPathComponent().appendingPathComponent(".\(localURL.lastPathComponent).\(UUID().uuidString).tmp")

        do {
            try FileManager.default.createDirectory(at: localURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            FileManager.default.createFile(atPath: tempURL.path, contents: nil)
            let fileHandle = try FileHandle(forWritingTo: tempURL)

            if totalBytes == 0 {
                try Task.checkCancellation()
                progress?(TransferProgress(bytesTransferred: 0, totalBytes: 0))
            } else {
                while bytesTransferred < totalBytes {
                    try Task.checkCancellation()
                    if simulateTransferChunkDelay > 0 {
                        try await Task.sleep(nanoseconds: UInt64(simulateTransferChunkDelay * 1_000_000_000))
                    }
                    let step = min(chunkSize, Int(totalBytes - bytesTransferred))
                    let chunk = data.subdata(in: Int(bytesTransferred)..<Int(bytesTransferred) + step)
                    try fileHandle.write(contentsOf: chunk)
                    bytesTransferred += Int64(step)
                    progress?(TransferProgress(bytesTransferred: bytesTransferred, totalBytes: totalBytes))
                }
            }

            try fileHandle.close()

            if FileManager.default.fileExists(atPath: localURL.path) {
                _ = try FileManager.default.replaceItemAt(localURL, withItemAt: tempURL)
            } else {
                try FileManager.default.moveItem(at: tempURL, to: localURL)
            }
        } catch {
            try? FileManager.default.removeItem(at: tempURL)
            throw error
        }
    }

    public func upload(
        from localURL: URL,
        to remotePath: RemotePath,
        progress: (@Sendable (TransferProgress) -> Void)? = nil
    ) async throws {
        try Task.checkCancellation()
        guard FileManager.default.fileExists(atPath: localURL.path) else {
            throw SFTPRepositoryError.notFound(path: localURL.path)
        }
        let data = try Data(contentsOf: localURL)
        try await writeFile(data: data, at: remotePath, progress: progress)
    }

    public func createDirectory(at path: RemotePath) async throws {
        try Task.checkCancellation()
        if path.isRoot {
            throw SFTPRepositoryError.alreadyExists(path: "/")
        }
        guard let parent = nodes[path.parent.description], parent.entryType == .directory else {
            throw SFTPRepositoryError.notFound(path: path.parent.description)
        }
        guard nodes[path.description] == nil else {
            throw SFTPRepositoryError.alreadyExists(path: path.description)
        }

        let now = Date()
        nodes[path.description] = DemoNode(
            path: path,
            name: path.lastComponent,
            entryType: .directory,
            size: 4096,
            permissions: .standardDirectory,
            modificationDate: now,
            accessDate: now,
            symlinkTarget: nil,
            data: nil
        )
    }

    public func removeFile(at path: RemotePath) async throws {
        try Task.checkCancellation()
        guard let node = nodes[path.description] else {
            throw SFTPRepositoryError.notFound(path: path.description)
        }
        guard node.entryType != .directory else {
            throw SFTPRepositoryError.isDirectory(path: path.description)
        }
        nodes.removeValue(forKey: path.description)
    }

    public func removeDirectory(at path: RemotePath) async throws {
        try Task.checkCancellation()
        if path.isRoot {
            throw SFTPRepositoryError.permissionDenied(path: "/")
        }
        guard let node = nodes[path.description] else {
            throw SFTPRepositoryError.notFound(path: path.description)
        }
        guard node.entryType == .directory else {
            throw SFTPRepositoryError.notADirectory(path: path.description)
        }
        let hasChildren = nodes.values.contains { $0.path != path && $0.path.parent == path }
        if hasChildren {
            throw SFTPRepositoryError.directoryNotEmpty(path: path.description)
        }
        nodes.removeValue(forKey: path.description)
    }

    public func rename(from oldPath: RemotePath, to newPath: RemotePath) async throws {
        try Task.checkCancellation()
        guard let existingNode = nodes[oldPath.description] else {
            throw SFTPRepositoryError.notFound(path: oldPath.description)
        }
        guard let newParent = nodes[newPath.parent.description], newParent.entryType == .directory else {
            throw SFTPRepositoryError.notFound(path: newPath.parent.description)
        }

        let oldPrefix = oldPath.description == "/" ? "/" : oldPath.description + "/"
        let newPrefix = newPath.description == "/" ? "/" : newPath.description + "/"

        let descendants = nodes.filter { $0.key.hasPrefix(oldPrefix) }
        for (key, descNode) in descendants {
            nodes.removeValue(forKey: key)
            let relativeSuffix = String(key.dropFirst(oldPrefix.count))
            let updatedPath = RemotePath(newPrefix + relativeSuffix)
            var updatedNode = descNode
            updatedNode.path = updatedPath
            updatedNode.name = updatedPath.lastComponent
            nodes[updatedPath.description] = updatedNode
        }

        nodes.removeValue(forKey: oldPath.description)
        var renamed = existingNode
        renamed.path = newPath
        renamed.name = newPath.lastComponent
        nodes[newPath.description] = renamed
    }
}
