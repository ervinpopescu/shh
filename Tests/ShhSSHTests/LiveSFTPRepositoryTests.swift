import XCTest
import NIOCore
import NIOPosix
@preconcurrency import NIOSSH
import Crypto
import Citadel
@testable import ShhCore
@testable import ShhSSH

final class LiveSFTPRepositoryTests: XCTestCase {
    private var server: SSHServer?
    private var group: MultiThreadedEventLoopGroup?

    override func tearDown() async throws {
        if let server {
            try? await server.close()
            try? await Task.sleep(nanoseconds: 20_000_000)
        }
        if let group {
            try? await group.shutdownGracefully()
        }
    }

    // MARK: - Test Box Helper

    private final class TestBox<T>: @unchecked Sendable {
        private let lock = NSLock()
        private var _value: T

        init(_ value: T) {
            self._value = value
        }

        var value: T {
            lock.withLock { _value }
        }

        func mutate(_ transform: (inout T) -> Void) {
            lock.withLock { transform(&_value) }
        }
    }

    // MARK: - Test SFTP Delegate for In-Process Citadel SFTP Server

    private final class MockSFTPFileHandle: SFTPFileHandle, @unchecked Sendable {
        private let lock = NSLock()
        private var buffer: ByteBuffer
        private var isClosed = false
        var simulateDelay: TimeInterval = 0
        var onWrite: (@Sendable (ByteBuffer) -> Void)?

        init(buffer: ByteBuffer, simulateDelay: TimeInterval = 0, onWrite: (@Sendable (ByteBuffer) -> Void)? = nil) {
            self.buffer = buffer
            self.simulateDelay = simulateDelay
            self.onWrite = onWrite
        }

        func read(at offset: UInt64, length: UInt32) async throws -> ByteBuffer {
            if simulateDelay > 0 {
                try await Task.sleep(nanoseconds: UInt64(simulateDelay * 1_000_000_000))
            }
            return lock.withLock {
                guard Int(offset) < buffer.readableBytes else {
                    return ByteBuffer()
                }
                let available = buffer.readableBytes - Int(offset)
                let toRead = min(Int(length), available)
                var slice = buffer
                slice.moveReaderIndex(to: Int(offset))
                return slice.readSlice(length: toRead) ?? ByteBuffer()
            }
        }

        func write(_ data: ByteBuffer, atOffset offset: UInt64) async throws -> SFTPStatusCode {
            if simulateDelay > 0 {
                try await Task.sleep(nanoseconds: UInt64(simulateDelay * 1_000_000_000))
            }
            return lock.withLock {
                let required = Int(offset) + data.readableBytes
                if buffer.capacity < required {
                    buffer.reserveCapacity(required)
                }
                _ = buffer.setBuffer(data, at: Int(offset))
                if buffer.writerIndex < required {
                    buffer.moveWriterIndex(to: required)
                }
                onWrite?(buffer)
                return .ok
            }
        }

        func close() async throws -> SFTPStatusCode {
            lock.withLock { isClosed = true }
            return .ok
        }

        func readFileAttributes() async throws -> SFTPFileAttributes {
            lock.withLock {
                var attrs = SFTPFileAttributes(size: UInt64(buffer.readableBytes))
                attrs.permissions = 0o100644
                return attrs
            }
        }

        func setFileAttributes(to attributes: SFTPFileAttributes) async throws {}
    }

    private final class MockSFTPDirectoryHandle: SFTPDirectoryHandle, @unchecked Sendable {
        private let components: [SFTPPathComponent]

        init(components: [SFTPPathComponent]) {
            self.components = components
        }

        func listFiles(context: SSHContext) async throws -> [SFTPFileListing] {
            [SFTPFileListing(path: components)]
        }
    }

    private final class MockSFTPDelegate: SFTPDelegate, @unchecked Sendable {
        private let lock = NSLock()
        var files: [String: ByteBuffer] = [:]
        var directories: Set<String> = ["/"]
        var returnErrorOnRemove: SFTPStatusCode? = nil
        var simulateHandleDelay: TimeInterval = 0

        init() {
            var sampleBuffer = ByteBufferAllocator().buffer(capacity: 32)
            sampleBuffer.writeString("Hello LiveSFTPRepository")
            files["/hello.txt"] = sampleBuffer

            directories.insert("/sub")
            var subBuffer = ByteBufferAllocator().buffer(capacity: 64)
            subBuffer.writeString("Sub file content")
            files["/sub/subfile.txt"] = subBuffer
        }

        func fileAttributes(atPath path: String, context: SSHContext) async throws -> SFTPFileAttributes {
            lock.withLock {
                if let buffer = files[path] {
                    var attrs = SFTPFileAttributes(size: UInt64(buffer.readableBytes))
                    attrs.permissions = 0o100644
                    return attrs
                } else if directories.contains(path) {
                    var attrs = SFTPFileAttributes(size: 4096)
                    attrs.permissions = 0o040755
                    return attrs
                }
                var attrs = SFTPFileAttributes(size: 0)
                attrs.permissions = 0o100644
                return attrs
            }
        }

        func openFile(_ filePath: String, withAttributes: SFTPFileAttributes, flags: SFTPOpenFileFlags, context: SSHContext) async throws -> SFTPFileHandle {
            lock.withLock {
                let delay = simulateHandleDelay
                let buf = files[filePath] ?? ByteBufferAllocator().buffer(capacity: 64)
                return MockSFTPFileHandle(buffer: buf, simulateDelay: delay) { [weak self] updated in
                    self?.lock.withLock {
                        self?.files[filePath] = updated
                    }
                }
            }
        }

        func removeFile(_ filePath: String, context: SSHContext) async throws -> SFTPStatusCode {
            lock.withLock {
                if let err = returnErrorOnRemove { return err }
                files.removeValue(forKey: filePath)
                return .ok
            }
        }

        func createDirectory(_ filePath: String, withAttributes: SFTPFileAttributes, context: SSHContext) async throws -> SFTPStatusCode {
            lock.withLock {
                directories.insert(filePath)
                return .ok
            }
        }

        func removeDirectory(_ filePath: String, context: SSHContext) async throws -> SFTPStatusCode {
            lock.withLock {
                if let err = returnErrorOnRemove { return err }
                directories.remove(filePath)
                return .ok
            }
        }

        func realPath(for canonicalUrl: String, context: SSHContext) async throws -> [SFTPPathComponent] {
            [
                SFTPPathComponent(
                    filename: canonicalUrl,
                    longname: canonicalUrl,
                    attributes: .none
                )
            ]
        }

        func openDirectory(atPath path: String, context: SSHContext) async throws -> SFTPDirectoryHandle {
            lock.withLock {
                var components: [SFTPPathComponent] = []
                for dir in directories where dir != path && dir.hasPrefix(path) {
                    let rel = String(dir.dropFirst(path == "/" ? 1 : path.count + 1))
                    if !rel.contains("/") && !rel.isEmpty {
                        var attrs = SFTPFileAttributes(size: 4096)
                        attrs.permissions = 0o040755
                        components.append(SFTPPathComponent(filename: rel, longname: "drwxr-xr-x 1 dev dev 4096 \(rel)", attributes: attrs))
                    }
                }
                for (filePath, buf) in files where filePath.hasPrefix(path) {
                    let rel = String(filePath.dropFirst(path == "/" ? 1 : path.count + 1))
                    if !rel.contains("/") && !rel.isEmpty {
                        var attrs = SFTPFileAttributes(size: UInt64(buf.readableBytes))
                        attrs.permissions = 0o100644
                        components.append(SFTPPathComponent(filename: rel, longname: "-rw-r--r-- 1 dev dev \(buf.readableBytes) \(rel)", attributes: attrs))
                    }
                }
                return MockSFTPDirectoryHandle(components: components)
            }
        }

        func setFileAttributes(to attributes: SFTPFileAttributes, atPath path: String, context: SSHContext) async throws -> SFTPStatusCode {
            .ok
        }

        func addSymlink(linkPath: String, targetPath: String, context: SSHContext) async throws -> SFTPStatusCode {
            .ok
        }

        func readSymlink(atPath path: String, context: SSHContext) async throws -> [SFTPPathComponent] {
            []
        }

        func rename(oldPath: String, newPath: String, flags: UInt32, context: SSHContext) async throws -> SFTPStatusCode {
            lock.withLock {
                if let data = files.removeValue(forKey: oldPath) {
                    files[newPath] = data
                    return .ok
                }
                if directories.remove(oldPath) != nil {
                    directories.insert(newPath)
                    return .ok
                }
                return .noSuchFile
            }
        }
    }

    private final class MockAuthDelegate: NIOSSHServerUserAuthenticationDelegate, @unchecked Sendable {
        var supportedAuthenticationMethods: NIOSSHAvailableUserAuthenticationMethods = [.password]

        func requestReceived(
            request: NIOSSHUserAuthenticationRequest,
            responsePromise: EventLoopPromise<NIOSSHUserAuthenticationOutcome>
        ) {
            responsePromise.succeed(.success)
        }
    }

    // MARK: - Server Helper

    private func findAvailablePort() throws -> Int {
        let tempGroup = MultiThreadedEventLoopGroup(numberOfThreads: 1)
        defer { try? tempGroup.syncShutdownGracefully() }
        let bootstrap = ServerBootstrap(group: tempGroup)
            .serverChannelOption(ChannelOptions.socket(SocketOptionLevel(SOL_SOCKET), SO_REUSEADDR), value: 1)
        let channel = try bootstrap.bind(host: "127.0.0.1", port: 0).wait()
        let port = channel.localAddress!.port!
        try channel.close().wait()
        return port
    }

    private func startServer(delegate: MockSFTPDelegate) async throws -> (UInt16, Curve25519.Signing.PublicKey) {
        let elg = MultiThreadedEventLoopGroup(numberOfThreads: 1)
        self.group = elg

        let port = try findAvailablePort()
        let hostKey = Curve25519.Signing.PrivateKey()
        let nioKey = NIOSSHPrivateKey(ed25519Key: hostKey)

        let sftpServer = try await SSHServer.host(
            host: "127.0.0.1",
            port: port,
            hostKeys: [nioKey],
            authenticationDelegate: MockAuthDelegate(),
            group: elg
        )
        sftpServer.enableSFTP(withDelegate: delegate)
        self.server = sftpServer

        return (UInt16(port), hostKey.publicKey)
    }

    private func connectRepo(port: UInt16, hostPubKey: Curve25519.Signing.PublicKey) async throws -> LiveSFTPRepository {
        var buffer = ByteBufferAllocator().buffer(capacity: 64)
        let prefix = "ssh-ed25519"
        buffer.writeInteger(UInt32(prefix.utf8.count))
        buffer.writeBytes(prefix.utf8)
        let keyBytes = Array(hostPubKey.rawRepresentation)
        buffer.writeInteger(UInt32(keyBytes.count))
        buffer.writeBytes(keyBytes)
        let fingerprint = "SHA256:" + Data(SHA256.hash(data: Data(buffer.readableBytesView))).base64EncodedString().trimmingCharacters(in: CharacterSet(charactersIn: "="))

        let trustStore = InMemoryTrustStore()
        let challenge = HostKeyChallenge(hostname: "127.0.0.1", port: port, algorithm: "ssh-ed25519", fingerprint: fingerprint)
        await trustStore.save(challenge)

        let credStore = InMemoryCredentialStore()
        try await credStore.save(Data("password".utf8), reference: "kc-test-pass")
        let identity = try IdentityDescriptor(name: "Test Identity", kind: .password, keychainReference: "kc-test-pass")

        let host = try ShhCore.Host(
            name: "Test Host",
            hostname: "127.0.0.1",
            port: port,
            username: "testuser",
            connection: .ssh(SSHOptions(strictHostKeyChecking: .prompt))
        )

        return try await LiveSFTPRepository.connect(
            host: host,
            identity: identity,
            trustEvaluator: trustStore,
            credentialStore: credStore
        )
    }

    // MARK: - Tests

    func testLiveSFTPRepositoryEndToEndWithCitadelServer() async throws {
        let delegate = MockSFTPDelegate()
        let (port, hostPubKey) = try await startServer(delegate: delegate)
        let repo = try await connectRepo(port: port, hostPubKey: hostPubKey)

        // 1. listDirectory
        let entries = try await repo.listDirectory(at: .root)
        let names = entries.map(\.name)
        XCTAssertTrue(names.contains("hello.txt"))
        XCTAssertTrue(names.contains("sub"))

        let helloFile = try XCTUnwrap(entries.first { $0.name == "hello.txt" })
        XCTAssertTrue(helloFile.isFile)
        XCTAssertEqual(helloFile.permissions?.octalString, "0644")

        // 2. readFile
        let helloData = try await repo.readFile(at: RemotePath("/hello.txt"))
        XCTAssertEqual(String(data: helloData, encoding: .utf8), "Hello LiveSFTPRepository")

        // 3. fetchAttributes
        let attrs = try await repo.fetchAttributes(at: RemotePath("/hello.txt"))
        XCTAssertEqual(attrs.name, "hello.txt")
        XCTAssertEqual(attrs.size, Int64("Hello LiveSFTPRepository".utf8.count))

        // 4. writeFile with progress and large payload (byte fidelity)
        var largePayload = Data(capacity: 96_000)
        for i in 0..<96_000 {
            largePayload.append(UInt8(i % 256))
        }
        let newFilePath = RemotePath("/large_file.bin")
        let writeProgressCalls = TestBox(0)
        try await repo.writeFile(data: largePayload, at: newFilePath) { _ in
            writeProgressCalls.mutate { $0 += 1 }
        }
        XCTAssertGreaterThan(writeProgressCalls.value, 0)

        // Verify byte fidelity after write
        let readLargeBack = try await repo.readFile(at: newFilePath)
        XCTAssertEqual(readLargeBack, largePayload, "Payload read back must match byte-for-byte")

        // 5. download with progress
        let tempDownloadURL = FileManager.default.temporaryDirectory.appendingPathComponent("live_test_dl_\(UUID().uuidString).txt")
        defer { try? FileManager.default.removeItem(at: tempDownloadURL) }

        let downloadProgressCalls = TestBox(0)
        try await repo.download(from: RemotePath("/hello.txt"), to: tempDownloadURL) { _ in
            downloadProgressCalls.mutate { $0 += 1 }
        }
        XCTAssertTrue(FileManager.default.fileExists(atPath: tempDownloadURL.path))
        let downloadedText = try String(contentsOf: tempDownloadURL, encoding: .utf8)
        XCTAssertEqual(downloadedText, "Hello LiveSFTPRepository")
        XCTAssertGreaterThan(downloadProgressCalls.value, 0)

        // 6. upload with progress
        let tempUploadURL = FileManager.default.temporaryDirectory.appendingPathComponent("live_test_up_\(UUID().uuidString).txt")
        let uploadText = "File from local disk uploaded to SFTP"
        try uploadText.write(to: tempUploadURL, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: tempUploadURL) }

        let uploadProgressCalls = TestBox(0)
        try await repo.upload(from: tempUploadURL, to: RemotePath("/disk_upload.txt")) { _ in
            uploadProgressCalls.mutate { $0 += 1 }
        }
        XCTAssertGreaterThan(uploadProgressCalls.value, 0)

        // 7. createDirectory
        try await repo.createDirectory(at: RemotePath("/my_folder"))

        // 8. rename
        try await repo.rename(from: RemotePath("/hello.txt"), to: RemotePath("/renamed_hello.txt"))

        // 9. removeFile
        try await repo.removeFile(at: RemotePath("/renamed_hello.txt"))

        // 10. removeDirectory
        try await repo.removeDirectory(at: RemotePath("/my_folder"))

        await repo.close()
    }

    func testLiveSFTPRepositoryErrorMapping() async throws {
        let delegate = MockSFTPDelegate()
        delegate.returnErrorOnRemove = .permissionDenied

        let (port, hostPubKey) = try await startServer(delegate: delegate)
        let repo = try await connectRepo(port: port, hostPubKey: hostPubKey)

        // removeFile when server returns permissionDenied
        do {
            try await repo.removeFile(at: RemotePath("/hello.txt"))
            XCTFail("Should have thrown permissionDenied")
        } catch let error as SFTPRepositoryError {
            XCTAssertEqual(error, .permissionDenied(path: "/hello.txt"))
        }

        // After close, operations throw connectionClosed
        await repo.close()
        do {
            _ = try await repo.readFile(at: RemotePath("/hello.txt"))
            XCTFail("Should have thrown connectionClosed")
        } catch let error as SFTPRepositoryError {
            XCTAssertEqual(error, .connectionClosed)
        }
    }

    func testLiveSFTPRepositoryCancellationCleansUpLocalTempFile() async throws {
        let delegate = MockSFTPDelegate()
        delegate.simulateHandleDelay = 0.1
        let (port, hostPubKey) = try await startServer(delegate: delegate)
        let repo = try await connectRepo(port: port, hostPubKey: hostPubKey)

        let targetURL = FileManager.default.temporaryDirectory.appendingPathComponent("cancel_download_\(UUID().uuidString).bin")
        defer { try? FileManager.default.removeItem(at: targetURL) }

        // Test 1: Immediate cancellation
        let cancelledTask = Task {
            try await repo.download(from: RemotePath("/hello.txt"), to: targetURL)
        }
        cancelledTask.cancel()

        do {
            try await cancelledTask.value
            XCTFail("Task should have failed on cancellation")
        } catch {
            XCTAssertTrue(error is CancellationError || (error as? SFTPRepositoryError) == .cancelled)
        }

        // Target file should not have been moved into place
        XCTAssertFalse(FileManager.default.fileExists(atPath: targetURL.path))

        await repo.close()
    }
}
