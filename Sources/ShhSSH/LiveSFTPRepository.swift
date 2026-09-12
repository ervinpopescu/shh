import Foundation
import NIOCore
import NIOPosix
@preconcurrency import NIOSSH
import Citadel
import ShhCore

public final class LiveSFTPRepository: SFTPRepository, RemoteFileRepository, @unchecked Sendable {
    private let sftpClient: SFTPClient
    private let sshClient: SSHClient?
    private let customGroup: MultiThreadedEventLoopGroup?
    private let lock = NSLock()
    private var isClosed = false

    public init(
        sftpClient: SFTPClient,
        sshClient: SSHClient? = nil,
        customGroup: MultiThreadedEventLoopGroup? = nil
    ) {
        self.sftpClient = sftpClient
        self.sshClient = sshClient
        self.customGroup = customGroup
    }

    public convenience init(sshClient: SSHClient) async throws {
        let sftp = try await sshClient.openSFTP()
        self.init(sftpClient: sftp, sshClient: sshClient)
    }

    public static func connect(
        host: ShhCore.Host,
        identity: IdentityDescriptor?,
        trustEvaluator: any HostTrustEvaluator,
        credentialStore: any CredentialStore,
        options: SSHOptions = SSHOptions(),
        group: MultiThreadedEventLoopGroup? = nil
    ) async throws -> LiveSFTPRepository {
        if Task.isCancelled { throw TransportError.cancelled }

        let ownsGroup = (group == nil)
        let eventLoopGroup = group ?? MultiThreadedEventLoopGroup(numberOfThreads: 1)

        let validator = HostKeyValidatorDelegate(
            hostname: host.hostname,
            port: host.port,
            strictChecking: options.strictHostKeyChecking,
            trustEvaluator: trustEvaluator
        )

        let userAuthDelegate = LiveSSHUserAuthDelegate(
            username: host.username,
            resolveCredential: {
                try await LiveSSHTransport.resolveAuthenticationCredential(
                    identity: identity,
                    credentialStore: credentialStore
                )
            }
        )

        let authMethod = SSHAuthenticationMethod.custom(userAuthDelegate)
        let hostKeyValidator = SSHHostKeyValidator.custom(validator)

        let client: SSHClient
        do {
            client = try await Citadel.SSHClient.connect(
                host: host.hostname,
                port: Int(host.port),
                authenticationMethod: authMethod,
                hostKeyValidator: hostKeyValidator,
                reconnect: .never,
                group: eventLoopGroup
            )
        } catch {
            if ownsGroup {
                try? await eventLoopGroup.shutdownGracefully()
            }
            if let captured = validator.capturedError {
                throw captured
            }
            if Task.isCancelled || error is CancellationError {
                throw TransportError.cancelled
            }
            throw error
        }

        if let captured = validator.capturedError {
            try? await client.close()
            if ownsGroup {
                try? await eventLoopGroup.shutdownGracefully()
            }
            throw captured
        }

        let sftp: SFTPClient
        do {
            sftp = try await client.openSFTP()
        } catch {
            try? await client.close()
            if ownsGroup {
                try? await eventLoopGroup.shutdownGracefully()
            }
            if Task.isCancelled || error is CancellationError {
                throw TransportError.cancelled
            }
            throw error
        }

        return LiveSFTPRepository(
            sftpClient: sftp,
            sshClient: client,
            customGroup: ownsGroup ? eventLoopGroup : nil
        )
    }

    public func close() async {
        let alreadyClosed = lock.withLock {
            let prev = isClosed
            isClosed = true
            return prev
        }
        guard !alreadyClosed else { return }

        if let sshClient {
            try? await sshClient.close()
        }
        if let customGroup {
            try? await customGroup.shutdownGracefully()
        }
    }

    // MARK: - SFTPRepository Implementation

    public func listDirectory(at path: RemotePath) async throws -> [RemoteFile] {
        try checkActiveAndCancellation()
        do {
            let names = try await sftpClient.listDirectory(atPath: path.description)
            var files: [RemoteFile] = []
            for name in names {
                for component in name.components {
                    guard component.filename != "." && component.filename != ".." else { continue }
                    let childPath = path.appending(component.filename)
                    let file = mapComponentToRemoteFile(component, at: childPath)
                    files.append(file)
                }
            }

            return files.sorted { lhs, rhs in
                if lhs.isDirectory != rhs.isDirectory {
                    return lhs.isDirectory && !rhs.isDirectory
                }
                return lhs.name.localizedStandardCompare(rhs.name) == .orderedAscending
            }
        } catch {
            throw mapError(error, path: path.description)
        }
    }

    public func fetchAttributes(at path: RemotePath) async throws -> RemoteFile {
        try checkActiveAndCancellation()
        do {
            let attrs = try await sftpClient.getAttributes(at: path.description)
            return mapAttributesToRemoteFile(attrs, at: path)
        } catch {
            throw mapError(error, path: path.description)
        }
    }

    public func readFile(at path: RemotePath) async throws -> Data {
        try checkActiveAndCancellation()
        do {
            let file = try await sftpClient.openFile(filePath: path.description, flags: [.read])
            do {
                let buffer = try await file.readAll()
                try? await file.close()
                return Data(buffer.readableBytesView)
            } catch {
                try? await file.close()
                throw error
            }
        } catch {
            throw mapError(error, path: path.description)
        }
    }

    public func download(
        from remotePath: RemotePath,
        to localURL: URL,
        progress: (@Sendable (TransferProgress) -> Void)? = nil
    ) async throws {
        try checkActiveAndCancellation()
        let tempURL = localURL.deletingLastPathComponent().appendingPathComponent(".\(localURL.lastPathComponent).\(UUID().uuidString).tmp")

        do {
            let attrs = try await sftpClient.getAttributes(at: remotePath.description)
            let totalBytes = Int64(attrs.size ?? 0)

            let parentFolder = localURL.deletingLastPathComponent()
            try FileManager.default.createDirectory(at: parentFolder, withIntermediateDirectories: true)
            FileManager.default.createFile(atPath: tempURL.path, contents: nil)
            let fileHandle = try FileHandle(forWritingTo: tempURL)

            let file = try await sftpClient.openFile(filePath: remotePath.description, flags: [.read])

            var bytesTransferred: Int64 = 0
            let chunkSize: UInt32 = 64 * 1024

            do {
                if totalBytes == 0 {
                    try Task.checkCancellation()
                    progress?(TransferProgress(bytesTransferred: 0, totalBytes: 0))
                } else {
                    while bytesTransferred < totalBytes {
                        try Task.checkCancellation()
                        let chunk = try await file.read(from: UInt64(bytesTransferred), length: chunkSize)
                        guard chunk.readableBytes > 0 else { break }
                        let data = Data(chunk.readableBytesView)
                        try fileHandle.write(contentsOf: data)
                        bytesTransferred += Int64(data.count)
                        progress?(TransferProgress(bytesTransferred: bytesTransferred, totalBytes: totalBytes))
                    }
                }

                try fileHandle.close()
                try? await file.close()

                if FileManager.default.fileExists(atPath: localURL.path) {
                    _ = try FileManager.default.replaceItemAt(localURL, withItemAt: tempURL)
                } else {
                    try FileManager.default.moveItem(at: tempURL, to: localURL)
                }
            } catch {
                try? fileHandle.close()
                try? FileManager.default.removeItem(at: tempURL)
                try? await file.close()
                throw error
            }
        } catch {
            try? FileManager.default.removeItem(at: tempURL)
            throw mapError(error, path: remotePath.description)
        }
    }

    public func writeFile(
        data: Data,
        at remotePath: RemotePath,
        progress: (@Sendable (TransferProgress) -> Void)? = nil
    ) async throws {
        try checkActiveAndCancellation()
        do {
            let file = try await sftpClient.openFile(
                filePath: remotePath.description,
                flags: [.write, .create, .truncate]
            )

            let totalBytes = Int64(data.count)
            var bytesTransferred: Int64 = 0
            let chunkSize = 32 * 1024

            do {
                if totalBytes == 0 {
                    try Task.checkCancellation()
                    let emptyBuffer = ByteBufferAllocator().buffer(capacity: 0)
                    try await file.write(emptyBuffer, at: 0)
                    progress?(TransferProgress(bytesTransferred: 0, totalBytes: 0))
                } else {
                    while bytesTransferred < totalBytes {
                        try Task.checkCancellation()
                        let nextChunkSize = min(chunkSize, Int(totalBytes - bytesTransferred))
                        let chunkData = data.subdata(in: Int(bytesTransferred)..<Int(bytesTransferred) + nextChunkSize)
                        var buffer = ByteBufferAllocator().buffer(capacity: nextChunkSize)
                        buffer.writeBytes(chunkData)

                        try await file.write(buffer, at: UInt64(bytesTransferred))
                        bytesTransferred += Int64(nextChunkSize)
                        progress?(TransferProgress(bytesTransferred: bytesTransferred, totalBytes: totalBytes))
                    }
                }
                try await file.close()
            } catch {
                try? await file.close()
                throw error
            }
        } catch {
            throw mapError(error, path: remotePath.description)
        }
    }

    public func upload(
        from localURL: URL,
        to remotePath: RemotePath,
        progress: (@Sendable (TransferProgress) -> Void)? = nil
    ) async throws {
        try checkActiveAndCancellation()
        guard FileManager.default.fileExists(atPath: localURL.path) else {
            throw SFTPRepositoryError.notFound(path: localURL.path)
        }

        do {
            let fileAttributes = try FileManager.default.attributesOfItem(atPath: localURL.path)
            let totalBytes = (fileAttributes[.size] as? NSNumber)?.int64Value ?? 0
            let fileHandle = try FileHandle(forReadingFrom: localURL)

            let file = try await sftpClient.openFile(
                filePath: remotePath.description,
                flags: [.write, .create, .truncate]
            )

            var bytesTransferred: Int64 = 0
            let chunkSize = 32 * 1024

            do {
                if totalBytes == 0 {
                    try Task.checkCancellation()
                    progress?(TransferProgress(bytesTransferred: 0, totalBytes: 0))
                } else {
                    while bytesTransferred < totalBytes {
                        try Task.checkCancellation()
                        let chunk = fileHandle.readData(ofLength: chunkSize)
                        guard !chunk.isEmpty else { break }
                        var buffer = ByteBufferAllocator().buffer(capacity: chunk.count)
                        buffer.writeBytes(chunk)

                        try await file.write(buffer, at: UInt64(bytesTransferred))
                        bytesTransferred += Int64(chunk.count)
                        progress?(TransferProgress(bytesTransferred: bytesTransferred, totalBytes: totalBytes))
                    }
                }

                try fileHandle.close()
                try await file.close()
            } catch {
                try? fileHandle.close()
                try? await file.close()
                throw error
            }
        } catch {
            throw mapError(error, path: remotePath.description)
        }
    }

    public func createDirectory(at path: RemotePath) async throws {
        try checkActiveAndCancellation()
        do {
            try await sftpClient.createDirectory(atPath: path.description)
        } catch {
            throw mapError(error, path: path.description)
        }
    }

    public func removeFile(at path: RemotePath) async throws {
        try checkActiveAndCancellation()
        do {
            try await sftpClient.remove(at: path.description)
        } catch {
            throw mapError(error, path: path.description)
        }
    }

    public func removeDirectory(at path: RemotePath) async throws {
        try checkActiveAndCancellation()
        do {
            try await sftpClient.rmdir(at: path.description)
        } catch {
            throw mapError(error, path: path.description)
        }
    }

    public func rename(from oldPath: RemotePath, to newPath: RemotePath) async throws {
        try checkActiveAndCancellation()
        do {
            try await sftpClient.rename(at: oldPath.description, to: newPath.description)
        } catch {
            throw mapError(error, path: oldPath.description)
        }
    }

    // MARK: - Private Helpers

    private func checkActiveAndCancellation() throws {
        let closed = lock.withLock { isClosed }
        if closed {
            throw SFTPRepositoryError.connectionClosed
        }
        if Task.isCancelled {
            throw SFTPRepositoryError.cancelled
        }
    }

    private func mapComponentToRemoteFile(_ component: SFTPPathComponent, at path: RemotePath) -> RemoteFile {
        let attrs = component.attributes
        let permissions = attrs.permissions.map { PosixPermissions(rawValue: $0) }
        let entryType: RemoteFileEntryType
        if let perms = permissions {
            entryType = perms.entryType
        } else if component.longname.hasPrefix("d") {
            entryType = .directory
        } else if component.longname.hasPrefix("l") {
            entryType = .symlink
        } else {
            entryType = .file
        }

        var symlinkTarget: String? = nil
        if entryType == .symlink, let arrowRange = component.longname.range(of: " -> ") {
            symlinkTarget = String(component.longname[arrowRange.upperBound...])
        }

        let modificationDate = attrs.accessModificationTime?.modificationTime
        let accessDate = attrs.accessModificationTime?.accessTime
        let size = Int64(attrs.size ?? 0)

        return RemoteFile(
            id: path.description,
            name: component.filename,
            path: path,
            entryType: entryType,
            size: size,
            permissions: permissions,
            modificationDate: modificationDate,
            accessDate: accessDate,
            symlinkTarget: symlinkTarget
        )
    }

    private func mapAttributesToRemoteFile(_ attrs: SFTPFileAttributes, at path: RemotePath) -> RemoteFile {
        let permissions = attrs.permissions.map { PosixPermissions(rawValue: $0) }
        let entryType = permissions?.entryType ?? .file
        let modificationDate = attrs.accessModificationTime?.modificationTime
        let accessDate = attrs.accessModificationTime?.accessTime
        let size = Int64(attrs.size ?? 0)

        return RemoteFile(
            id: path.description,
            name: path.lastComponent,
            path: path,
            entryType: entryType,
            size: size,
            permissions: permissions,
            modificationDate: modificationDate,
            accessDate: accessDate,
            symlinkTarget: nil
        )
    }

    private func mapError(_ error: Error, path: String) -> Error {
        if Task.isCancelled || error is CancellationError {
            return SFTPRepositoryError.cancelled
        }
        if let repoError = error as? SFTPRepositoryError {
            return repoError
        }
        if let transportError = error as? TransportError {
            return transportError
        }
        if let status = error as? SFTPMessage.Status {
            switch status.errorCode {
            case .noSuchFile:
                return SFTPRepositoryError.notFound(path: path)
            case .permissionDenied:
                return SFTPRepositoryError.permissionDenied(path: path)
            case .failure:
                return SFTPRepositoryError.remoteFailure(status.message.isEmpty ? "SFTP server returned failure" : status.message)
            case .noConnection, .connectionLost:
                return SFTPRepositoryError.connectionClosed
            default:
                return SFTPRepositoryError.remoteFailure(status.message.isEmpty ? "SFTP status code: \(status.errorCode.rawValue)" : status.message)
            }
        }
        return SFTPRepositoryError.remoteFailure(error.localizedDescription)
    }
}
