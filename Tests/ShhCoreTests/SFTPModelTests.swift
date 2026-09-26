import XCTest
@testable import ShhCore

final class SFTPModelTests: XCTestCase {

    // MARK: - 1. RemotePath Normalization and Edge Cases

    func testRemotePathNormalization() {
        XCTAssertEqual(RemotePath("/var/log/../tmp/./app").description, "/var/tmp/app")
        XCTAssertEqual(RemotePath("///var///log///").description, "/var/log")
        XCTAssertEqual(RemotePath("/a/./b/./c/").description, "/a/b/c")
        XCTAssertEqual(RemotePath("/").description, "/")
        XCTAssertEqual(RemotePath("").description, "/")
        XCTAssertTrue(RemotePath("/").isRoot)
        XCTAssertFalse(RemotePath("/var").isRoot)
    }

    func testRemotePathRootClamping() {
        // Traversal above root clamps to root, never underflows
        XCTAssertEqual(RemotePath("/../../etc/passwd").description, "/etc/passwd")
        XCTAssertEqual(RemotePath("/../../../..").description, "/")
        XCTAssertEqual(RemotePath("a/../../b").description, "/b")
    }

    func testRemotePathHelpers() {
        let path = RemotePath("/home/dev/projects/shh/file.swift")
        XCTAssertEqual(path.lastComponent, "file.swift")
        XCTAssertEqual(path.pathExtension, "swift")
        XCTAssertEqual(path.deletingPathExtension().description, "/home/dev/projects/shh/file")
        XCTAssertEqual(path.parent.description, "/home/dev/projects/shh")
        XCTAssertEqual(RemotePath("/a").parent.description, "/")
        XCTAssertEqual(RemotePath("/").parent.description, "/")

        let appended = RemotePath("/var").appending("log").appending("system.log")
        XCTAssertEqual(appended.description, "/var/log/system.log")
    }

    func testRemotePathTraversalEscapePrevention() throws {
        let base = RemotePath("/var/www/site")

        // Legitimate subpaths
        let validChild = try base.appendingSafely("images/logo.png")
        XCTAssertEqual(validChild.description, "/var/www/site/images/logo.png")
        XCTAssertTrue(validChild.isDescendant(of: base))
        XCTAssertTrue(base.contains(validChild))

        // Legitimate child with internal backtrack
        let internalBacktrack = try base.appendingSafely("assets/../images/logo.png")
        XCTAssertEqual(internalBacktrack.description, "/var/www/site/images/logo.png")

        // Escape attempts throw invalidPath error
        XCTAssertThrowsError(try base.appendingSafely("../../etc/passwd")) { error in
            guard case SFTPRepositoryError.invalidPath = error else {
                XCTFail("Expected invalidPath error, got \(error)")
                return
            }
        }

        XCTAssertThrowsError(try base.appendingSafely("../../../../root")) { error in
            guard case SFTPRepositoryError.invalidPath = error else {
                XCTFail("Expected invalidPath error, got \(error)")
                return
            }
        }

        // Resolving with allowEscape = true permits escaping when explicitly asked
        let escaped = try base.resolving(child: "../../etc/passwd", allowEscape: true)
        XCTAssertEqual(escaped.description, "/var/etc/passwd")
    }

    // MARK: - 2. PosixPermissions

    func testPosixPermissionsFormattingAndInspection() {
        let dirPerms = PosixPermissions.standardDirectory
        XCTAssertEqual(dirPerms.octalString, "0755")
        XCTAssertEqual(dirPerms.symbolicString, "rwxr-xr-x")
        XCTAssertTrue(dirPerms.isDirectory)
        XCTAssertFalse(dirPerms.isRegularFile)
        XCTAssertTrue(dirPerms.ownerRead)
        XCTAssertTrue(dirPerms.ownerWrite)
        XCTAssertTrue(dirPerms.ownerExecute)
        XCTAssertTrue(dirPerms.groupRead)
        XCTAssertFalse(dirPerms.groupWrite)
        XCTAssertTrue(dirPerms.groupExecute)
        XCTAssertTrue(dirPerms.othersRead)
        XCTAssertFalse(dirPerms.othersWrite)
        XCTAssertTrue(dirPerms.othersExecute)

        let filePerms = PosixPermissions.standardFile
        XCTAssertEqual(filePerms.octalString, "0644")
        XCTAssertEqual(filePerms.symbolicString, "rw-r--r--")
        XCTAssertTrue(filePerms.isRegularFile)
        XCTAssertFalse(filePerms.isDirectory)

        let secureFile = PosixPermissions.secureFile
        XCTAssertEqual(secureFile.octalString, "0600")
        XCTAssertEqual(secureFile.symbolicString, "rw-------")

        let secureDir = PosixPermissions.secureDirectory
        XCTAssertEqual(secureDir.octalString, "0700")
        XCTAssertEqual(secureDir.symbolicString, "rwx------")

        // Sticky bit (e.g. /tmp: 01777)
        let tmpPerms = PosixPermissions(rawValue: 0o041777)
        XCTAssertTrue(tmpPerms.sticky)
        XCTAssertEqual(tmpPerms.symbolicString, "rwxrwxrwt")

        // Setuid (e.g. 04755)
        let suidPerms = PosixPermissions(rawValue: 0o104755)
        XCTAssertTrue(suidPerms.setuid)
        XCTAssertEqual(suidPerms.symbolicString, "rwsr-xr-x")

        // Setgid (e.g. 02755)
        let sgidPerms = PosixPermissions(rawValue: 0o102755)
        XCTAssertTrue(sgidPerms.setgid)
        XCTAssertEqual(sgidPerms.symbolicString, "rwxr-sr-x")
    }

    func testPosixPermissionsParsingFromOctalString() {
        let perms = PosixPermissions(octalString: "0755")
        XCTAssertNotNil(perms)
        XCTAssertEqual(perms?.octalValue, 0o755)

        XCTAssertNil(PosixPermissions(octalString: "not-octal"))
    }

    func testPosixPermissionsCodableRoundTrip() throws {
        let original = PosixPermissions(rawValue: 0o100644)
        let encoder = JSONEncoder()
        let decoder = JSONDecoder()
        let data = try encoder.encode(original)
        let decoded = try decoder.decode(PosixPermissions.self, from: data)
        XCTAssertEqual(original, decoded)
    }

    // MARK: - 3. RemoteFile Model

    func testRemoteFileLegacyAndFullInit() throws {
        // Legacy initializer
        var legacy = RemoteFile(name: "legacy.txt", isDirectory: false, size: 1024)
        XCTAssertEqual(legacy.id, "legacy.txt")
        XCTAssertEqual(legacy.name, "legacy.txt")
        XCTAssertEqual(legacy.path.description, "/legacy.txt")
        XCTAssertEqual(legacy.size, 1024)
        XCTAssertFalse(legacy.isDirectory)
        XCTAssertTrue(legacy.isFile)

        legacy.isDirectory = true
        XCTAssertTrue(legacy.isDirectory)
        XCTAssertFalse(legacy.isFile)

        // Full initializer
        let now = Date()
        let full = RemoteFile(
            name: "link_to_shh",
            path: RemotePath("/home/dev/link_to_shh"),
            entryType: .symlink,
            size: 16,
            permissions: PosixPermissions(rawValue: 0o120777),
            modificationDate: now,
            accessDate: now,
            symlinkTarget: "/home/dev/projects/shh"
        )
        XCTAssertTrue(full.isSymlink)
        XCTAssertEqual(full.symlinkTarget, "/home/dev/projects/shh")
        XCTAssertEqual(full.path.description, "/home/dev/link_to_shh")

        // Codable round-trip
        let data = try JSONEncoder().encode(full)
        let decoded = try JSONDecoder().decode(RemoteFile.self, from: data)
        XCTAssertEqual(full.id, decoded.id)
        XCTAssertEqual(full.name, decoded.name)
        XCTAssertEqual(full.path, decoded.path)
        XCTAssertEqual(full.entryType, decoded.entryType)
        XCTAssertEqual(full.size, decoded.size)
        XCTAssertEqual(full.symlinkTarget, decoded.symlinkTarget)
    }

    // MARK: - 4. Transfer Models & Queue State

    func testTransferProgressCalculations() {
        let empty = TransferProgress(bytesTransferred: 0, totalBytes: 0)
        XCTAssertEqual(empty.fractionCompleted, 0.0)

        let half = TransferProgress(bytesTransferred: 50, totalBytes: 100)
        XCTAssertEqual(half.fractionCompleted, 0.5)

        let done = TransferProgress(bytesTransferred: 100, totalBytes: 100)
        XCTAssertEqual(done.fractionCompleted, 1.0)

        let overshoot = TransferProgress(bytesTransferred: 150, totalBytes: 100)
        XCTAssertEqual(overshoot.fractionCompleted, 1.0)
    }

    func testTransferTaskLifecycleAndQueueState() {
        var queueState = TransferQueueState()
        XCTAssertEqual(queueState.tasks.count, 0)

        let task1 = TransferTask(
            direction: .upload,
            remotePath: RemotePath("/home/dev/data.bin"),
            localURL: URL(fileURLWithPath: "/tmp/data.bin"),
            totalBytes: 1000
        )
        queueState.enqueue(task1)
        XCTAssertEqual(queueState.queuedTasks.count, 1)
        XCTAssertEqual(queueState.activeTasks.count, 0)
        XCTAssertEqual(queueState.overallProgress, 0.0)

        // Transition to transferring
        var runningTask = task1
        runningTask.state = .transferring
        runningTask.bytesTransferred = 500
        queueState.update(runningTask)
        XCTAssertEqual(queueState.activeTasks.count, 1)
        XCTAssertEqual(queueState.queuedTasks.count, 0)
        XCTAssertEqual(queueState.overallProgress, 0.5)

        // Transition to completed
        var completedTask = runningTask
        completedTask.state = .completed
        completedTask.bytesTransferred = 1000
        queueState.update(completedTask)
        XCTAssertEqual(queueState.completedTasks.count, 1)
        XCTAssertEqual(queueState.activeTasks.count, 0)
        XCTAssertEqual(queueState.overallProgress, 1.0)

        // Clear terminal
        queueState.clearTerminal()
        XCTAssertEqual(queueState.tasks.count, 0)
    }

    func testTransferQueueCoordinatorWorkflow() async {
        let coordinator = TransferQueueCoordinator()
        let task = await coordinator.enqueue(
            direction: .download,
            remotePath: RemotePath("/etc/hosts"),
            localURL: URL(fileURLWithPath: "/tmp/hosts"),
            totalBytes: 200
        )
        XCTAssertEqual(task.state, .queued)

        await coordinator.updateProgress(id: task.id, bytesTransferred: 100, totalBytes: 200)
        var snapshot = await coordinator.snapshot()
        XCTAssertEqual(snapshot.activeTasks.count, 1)
        XCTAssertEqual(snapshot.task(withID: task.id)?.bytesTransferred, 100)

        await coordinator.markCompleted(id: task.id)
        snapshot = await coordinator.snapshot()
        XCTAssertEqual(snapshot.completedTasks.count, 1)
        XCTAssertEqual(snapshot.task(withID: task.id)?.state, .completed)

        // Cancellation workflow
        let task2 = await coordinator.enqueue(
            direction: .upload,
            remotePath: RemotePath("/home/dev/upload.zip"),
            localURL: URL(fileURLWithPath: "/tmp/upload.zip"),
            totalBytes: 5000
        )
        let cancelledExpectation = expectation(description: "Cancellation handler invoked")
        await coordinator.registerCancellation(id: task2.id) {
            cancelledExpectation.fulfill()
        }
        await coordinator.cancel(id: task2.id)
        await fulfillment(of: [cancelledExpectation], timeout: 1.0)

        snapshot = await coordinator.snapshot()
        XCTAssertEqual(snapshot.task(withID: task2.id)?.state, .cancelled)
    }

    // MARK: - 5. DemoSFTPRepository Directory Listing

    func testDemoSFTPRepositoryListing() async throws {
        let repo = DemoSFTPRepository(seedDemoData: true)

        let rootItems = try await repo.listDirectory(at: .root)
        let rootNames = Set(rootItems.map(\.name))
        XCTAssertTrue(rootNames.contains("home"))
        XCTAssertTrue(rootNames.contains("etc"))
        XCTAssertTrue(rootNames.contains("var"))
        XCTAssertTrue(rootNames.contains("tmp"))

        // Directories first, then alphabetical
        let devItems = try await repo.listDirectory(at: RemotePath("/home/dev"))
        XCTAssertFalse(devItems.isEmpty)
        let firstItem = try XCTUnwrap(devItems.first)
        XCTAssertTrue(firstItem.isDirectory, "First item should be a directory due to sorting")

        // Symlink inspection
        let symlink = devItems.first { $0.isSymlink }
        XCTAssertNotNil(symlink)
        XCTAssertEqual(symlink?.name, "current_project")
        XCTAssertEqual(symlink?.symlinkTarget, "/home/dev/projects/shh")
    }

    // MARK: - 6. DemoSFTPRepository Byte Fidelity (Read / Write)

    func testDemoSFTPRepositoryReadFileAndWriteFileByteFidelity() async throws {
        let repo = DemoSFTPRepository(seedDemoData: true)

        // Read seeded file
        let readmeData = try await repo.readFile(at: RemotePath("/home/dev/projects/shh/README.md"))
        let readmeString = String(data: readmeData, encoding: .utf8)
        XCTAssertTrue(readmeString?.contains("iPadOS SSH") == true)

        // Write a 100KB payload with structured bytes
        var payload = Data(capacity: 100_000)
        for i in 0..<100_000 {
            payload.append(UInt8(i % 256))
        }

        let progressUpdates = TestBox<[Double]>([])
        let writePath = RemotePath("/home/dev/test_payload.bin")
        try await repo.writeFile(data: payload, at: writePath) { progress in
            progressUpdates.mutate { $0.append(progress.fractionCompleted) }
        }

        // Byte fidelity check
        let readBack = try await repo.readFile(at: writePath)
        XCTAssertEqual(payload, readBack, "Read back data must match written data byte-for-byte")

        // Progress checks
        let recordedProgress = progressUpdates.value
        XCTAssertFalse(recordedProgress.isEmpty)
        XCTAssertEqual(recordedProgress.last, 1.0)
        // Monotonically non-decreasing
        for i in 1..<recordedProgress.count {
            XCTAssertGreaterThanOrEqual(recordedProgress[i], recordedProgress[i - 1])
        }

        // Attributes check
        let attrs = try await repo.fetchAttributes(at: writePath)
        XCTAssertEqual(attrs.size, 100_000)
        XCTAssertTrue(attrs.isFile)
    }

    // MARK: - 7. DemoSFTPRepository Download and Upload

    func testDemoSFTPRepositoryDownloadAndUpload() async throws {
        let repo = DemoSFTPRepository(seedDemoData: true)
        let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent("shh_test_\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        // Download seeded /etc/hosts
        let localHostsURL = tempDir.appendingPathComponent("hosts.txt")
        let downloadProgressCalls = TestBox(0)
        try await repo.download(from: RemotePath("/etc/hosts"), to: localHostsURL) { _ in
            downloadProgressCalls.mutate { $0 += 1 }
        }
        XCTAssertTrue(FileManager.default.fileExists(atPath: localHostsURL.path))
        let downloadedContent = try String(contentsOf: localHostsURL, encoding: .utf8)
        XCTAssertTrue(downloadedContent.contains("127.0.0.1 localhost"))
        XCTAssertGreaterThan(downloadProgressCalls.value, 0)

        // Upload local file to remote repo
        let uploadPayload = "Uploaded file content for milestone 6 stage 1\n".data(using: .utf8)!
        let localUploadURL = tempDir.appendingPathComponent("upload.txt")
        try uploadPayload.write(to: localUploadURL)

        let remoteUploadPath = RemotePath("/home/dev/upload.txt")
        let uploadProgressCalls = TestBox(0)
        try await repo.upload(from: localUploadURL, to: remoteUploadPath) { _ in
            uploadProgressCalls.mutate { $0 += 1 }
        }

        let remoteData = try await repo.readFile(at: remoteUploadPath)
        XCTAssertEqual(remoteData, uploadPayload)
        XCTAssertGreaterThan(uploadProgressCalls.value, 0)

        // Upload with restricted permissions
        let restrictedUploadPath = RemotePath("/home/dev/upload_restricted.txt")
        let restrictedPerms = PosixPermissions(rawValue: 0o600)
        try await repo.upload(
            from: localUploadURL,
            to: restrictedUploadPath,
            permissions: restrictedPerms
        )
        let restrictedAttrs = try await repo.fetchAttributes(at: restrictedUploadPath)
        XCTAssertEqual(restrictedAttrs.permissions?.rawValue, 0o600)
    }

    // MARK: - 8. DemoSFTPRepository Directory CRUD & Error Mapping

    func testDemoSFTPRepositoryDirectoryCRUDAndErrors() async throws {
        let repo = DemoSFTPRepository(seedDemoData: true)

        // Create directory
        let newDir = RemotePath("/home/dev/documents")
        try await repo.createDirectory(at: newDir)
        let attrs = try await repo.fetchAttributes(at: newDir)
        XCTAssertTrue(attrs.isDirectory)

        // Already exists error
        do {
            try await repo.createDirectory(at: newDir)
            XCTFail("Should have thrown alreadyExists")
        } catch let error as SFTPRepositoryError {
            XCTAssertEqual(error, .alreadyExists(path: newDir.description))
        }

        // Nonexistent parent directory error
        do {
            try await repo.createDirectory(at: RemotePath("/nonexistent/folder/new"))
            XCTFail("Should have thrown notFound")
        } catch let error as SFTPRepositoryError {
            XCTAssertEqual(error, .notFound(path: "/nonexistent/folder"))
        }

        // Add file in newDir
        let childFile = RemotePath("/home/dev/documents/doc.txt")
        try await repo.writeFile(data: Data("text".utf8), at: childFile)

        // Attempting to remove non-empty directory throws directoryNotEmpty
        do {
            try await repo.removeDirectory(at: newDir)
            XCTFail("Should have thrown directoryNotEmpty")
        } catch let error as SFTPRepositoryError {
            XCTAssertEqual(error, .directoryNotEmpty(path: newDir.description))
        }

        // Removing a directory as a file throws isDirectory
        do {
            try await repo.removeFile(at: newDir)
            XCTFail("Should have thrown isDirectory")
        } catch let error as SFTPRepositoryError {
            XCTAssertEqual(error, .isDirectory(path: newDir.description))
        }

        // Removing a file as a directory throws notADirectory
        do {
            try await repo.removeDirectory(at: childFile)
            XCTFail("Should have thrown notADirectory")
        } catch let error as SFTPRepositoryError {
            XCTAssertEqual(error, .notADirectory(path: childFile.description))
        }

        // Reading directory as a file throws isDirectory
        do {
            _ = try await repo.readFile(at: newDir)
            XCTFail("Should have thrown isDirectory")
        } catch let error as SFTPRepositoryError {
            XCTAssertEqual(error, .isDirectory(path: newDir.description))
        }

        // Clean removal
        try await repo.removeFile(at: childFile)
        try await repo.removeDirectory(at: newDir)

        // Now not found
        do {
            _ = try await repo.fetchAttributes(at: newDir)
            XCTFail("Should have thrown notFound")
        } catch let error as SFTPRepositoryError {
            XCTAssertEqual(error, .notFound(path: newDir.description))
        }
    }

    // MARK: - 9. DemoSFTPRepository Rename

    func testDemoSFTPRepositoryRename() async throws {
        let repo = DemoSFTPRepository(seedDemoData: true)
        let oldPath = RemotePath("/home/dev/notes.txt")
        let newPath = RemotePath("/home/dev/archived_notes.txt")

        try await repo.rename(from: oldPath, to: newPath)

        // Old path no longer exists
        do {
            _ = try await repo.readFile(at: oldPath)
            XCTFail("Old path should not exist")
        } catch let error as SFTPRepositoryError {
            XCTAssertEqual(error, .notFound(path: oldPath.description))
        }

        // New path has the content
        let content = try await repo.readFile(at: newPath)
        XCTAssertTrue(String(data: content, encoding: .utf8)?.contains("Milestone 6") == true)
    }

    // MARK: - 10. DemoSFTPRepository Cancellation

    func testDemoSFTPRepositoryCancellation() async throws {
        let repo = DemoSFTPRepository(seedDemoData: true)
        await repo.setSimulateTransferChunkDelay(0.05)

        // Write a large file
        let largeData = Data(repeating: 0x41, count: 500_000)
        try await repo.writeFile(data: largeData, at: RemotePath("/home/dev/large.bin"))

        let tempURL = FileManager.default.temporaryDirectory.appendingPathComponent("cancel_test_\(UUID().uuidString).tmp")
        defer { try? FileManager.default.removeItem(at: tempURL) }

        let downloadTask = Task {
            try await repo.download(from: RemotePath("/home/dev/large.bin"), to: tempURL)
        }

        // Cancel shortly after start
        try await Task.sleep(nanoseconds: 20_000_000)
        downloadTask.cancel()

        do {
            try await downloadTask.value
            XCTFail("Task should have thrown cancellation error")
        } catch {
            XCTAssertTrue(error is CancellationError || (error as? SFTPRepositoryError) == .cancelled)
        }
    }

    // MARK: - 11. UnavailableFileRepository

    func testUnavailableFileRepositoryThrows() async {
        let unavail = UnavailableFileRepository()
        let path = RemotePath("/test")

        await assertThrowsUnsupported { _ = try await unavail.listDirectory(at: path) }
        await assertThrowsUnsupported { _ = try await unavail.readFile(at: path) }
        await assertThrowsUnsupported { try await unavail.createDirectory(at: path) }
        await assertThrowsUnsupported { try await unavail.removeFile(at: path) }
        await assertThrowsUnsupported { try await unavail.removeDirectory(at: path) }
        await assertThrowsUnsupported { try await unavail.rename(from: path, to: RemotePath("/other")) }
        await assertThrowsUnsupported { _ = try await unavail.fetchAttributes(at: path) }
    }

    private func assertThrowsUnsupported(_ operation: () async throws -> Void) async {
        do {
            try await operation()
            XCTFail("Should have thrown TransportError.unsupported")
        } catch let error as TransportError {
            XCTAssertEqual(error, .unsupported)
        } catch {
            XCTFail("Expected TransportError.unsupported, got \(error)")
        }
    }
}

final class TestBox<T>: @unchecked Sendable {
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

extension DemoSFTPRepository {
    func setSimulateTransferChunkDelay(_ delay: TimeInterval) {
        self.simulateTransferChunkDelay = delay
    }
}
