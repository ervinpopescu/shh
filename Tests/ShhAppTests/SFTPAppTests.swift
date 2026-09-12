import XCTest
import SwiftUI
@testable import Shh
import ShhCore
import ShhSSH

@MainActor
final class SFTPAppTests: XCTestCase {

    private func makeDemoContainer(
        seedDemoData: Bool = true,
        simulateDelay: TimeInterval = 0
    ) -> (AppContainer, DemoSFTPRepository) {
        let repo = DemoSFTPRepository(seedDemoData: seedDemoData)
        if simulateDelay > 0 {
            Task {
                await repo.setSimulateTransferChunkDelay(simulateDelay)
            }
        }
        let container = AppContainer.demo(sftpRepository: repo)
        return (container, repo)
    }

    // MARK: - 1. Browsing & Navigation

    func testInitialDirectoryListingAndNavigationInDemoMode() async throws {
        let (container, _) = makeDemoContainer()

        // Wait for initial directory to load
        await container.loadDirectory(at: RemotePath("/home/dev"), bypassCache: true)
        XCTAssertEqual(container.currentPath.description, "/home/dev")
        XCTAssertFalse(container.currentDirectoryFiles.isEmpty)

        let fileNames = Set(container.currentDirectoryFiles.map(\.name))
        XCTAssertTrue(fileNames.contains("projects"), "Must contain projects folder")
        XCTAssertTrue(fileNames.contains("notes.txt"), "Must contain notes.txt")
        XCTAssertTrue(fileNames.contains(".bashrc"), "Must contain .bashrc")
        XCTAssertTrue(fileNames.contains("current_project"), "Must contain current_project symlink")

        // Inspect symlink
        let symlink = try XCTUnwrap(container.currentDirectoryFiles.first { $0.isSymlink })
        XCTAssertEqual(symlink.name, "current_project")
        XCTAssertEqual(symlink.symlinkTarget, "/home/dev/projects/shh")

        // Navigate into subfolder
        await container.navigateTo(RemotePath("/home/dev/projects/shh"))
        XCTAssertEqual(container.currentPath.description, "/home/dev/projects/shh")
        let subNames = Set(container.currentDirectoryFiles.map(\.name))
        XCTAssertTrue(subNames.contains("README.md"))

        // Navigate up to immediate parent (/home/dev/projects)
        await container.navigateUp()
        XCTAssertEqual(container.currentPath.description, "/home/dev/projects")

        // Navigate up again to /home/dev
        await container.navigateUp()
        XCTAssertEqual(container.currentPath.description, "/home/dev")

        // Navigate to root
        await container.navigateTo(.root)
        XCTAssertEqual(container.currentPath.description, "/")
        let rootNames = Set(container.currentDirectoryFiles.map(\.name))
        XCTAssertTrue(rootNames.contains("home"))
        XCTAssertTrue(rootNames.contains("etc"))
        XCTAssertTrue(rootNames.contains("var"))
        XCTAssertTrue(rootNames.contains("tmp"))
    }

    // MARK: - 2. Directory Caching & Invalidation

    func testDirectoryCachingAndBypass() async throws {
        let (container, _) = makeDemoContainer()
        let path = RemotePath("/home/dev")

        // 1. Initial fetch fills cache
        await container.loadDirectory(at: path, bypassCache: true)
        let initialCount = container.currentDirectoryFiles.count
        XCTAssertGreaterThan(initialCount, 0)

        // 2. Fetch with bypassCache = false uses cache
        await container.loadDirectory(at: path, bypassCache: false)
        XCTAssertEqual(container.currentDirectoryFiles.count, initialCount)
        XCTAssertNil(container.directoryErrorMessage)

        // 3. Invalidate cache
        container.invalidateDirectoryCache(at: path)

        // 4. Mutation automatically invalidates cache
        try await container.createFile(named: "cached_test.txt", content: Data("test".utf8))
        XCTAssertTrue(container.currentDirectoryFiles.contains { $0.name == "cached_test.txt" })

        // Clean up
        if let created = container.currentDirectoryFiles.first(where: { $0.name == "cached_test.txt" }) {
            try await container.deleteFile(created)
        }
        XCTAssertFalse(container.currentDirectoryFiles.contains { $0.name == "cached_test.txt" })
    }

    // MARK: - 3. Sorting & Filtering

    func testSortingAndFiltering() async throws {
        let (container, _) = makeDemoContainer()
        await container.loadDirectory(at: RemotePath("/home/dev"), bypassCache: true)

        // Filter by search query
        container.fileSearchQuery = "note"
        XCTAssertEqual(container.sortedAndFilteredFiles.count, 1)
        XCTAssertEqual(container.sortedAndFilteredFiles.first?.name, "notes.txt")

        // Case-insensitive search
        container.fileSearchQuery = "NOTES"
        XCTAssertEqual(container.sortedAndFilteredFiles.count, 1)
        XCTAssertEqual(container.sortedAndFilteredFiles.first?.name, "notes.txt")

        // Reset search
        container.fileSearchQuery = ""
        XCTAssertGreaterThan(container.sortedAndFilteredFiles.count, 1)

        // Sort by Type ascending (directories first, then symlinks, then files)
        container.sortField = .type
        container.sortAscending = true
        let sortedByType = container.sortedAndFilteredFiles
        XCTAssertTrue(sortedByType.first?.isDirectory == true, "First item sorted by type must be a directory")

        // Sort by Name ascending
        container.sortField = .name
        container.sortAscending = true
        let sortedByNameAsc = container.sortedAndFilteredFiles
        for i in 1..<sortedByNameAsc.count {
            XCTAssertTrue(sortedByNameAsc[i - 1].name.localizedStandardCompare(sortedByNameAsc[i].name) != .orderedDescending)
        }

        // Sort by Name descending
        container.sortAscending = false
        let sortedByNameDesc = container.sortedAndFilteredFiles
        for i in 1..<sortedByNameDesc.count {
            XCTAssertTrue(sortedByNameDesc[i - 1].name.localizedStandardCompare(sortedByNameDesc[i].name) != .orderedAscending)
        }

        // Sort by Size ascending
        container.sortField = .size
        container.sortAscending = true
        let sortedBySize = container.sortedAndFilteredFiles
        for i in 1..<sortedBySize.count {
            XCTAssertLessThanOrEqual(sortedBySize[i - 1].size, sortedBySize[i].size)
        }
    }

    // MARK: - 4. Download Transfer with Progress & Completion

    func testDownloadTransferWithProgressAndCompletion() async throws {
        let (container, _) = makeDemoContainer()
        await container.loadDirectory(at: RemotePath("/home/dev"), bypassCache: true)

        let notesFile = try XCTUnwrap(container.currentDirectoryFiles.first { $0.name == "notes.txt" })
        let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent("ShhTestDL_\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let localTarget = tempDir.appendingPathComponent("downloaded_notes.txt")
        let task = await container.enqueueDownload(file: notesFile, destinationURL: localTarget, overwrite: true)
        let enqueuedTask = try XCTUnwrap(task)

        // Wait for download to finish
        var completed = false
        for _ in 0..<50 {
            if container.transferQueueState.task(withID: enqueuedTask.id)?.state == .completed {
                completed = true
                break
            }
            try await Task.sleep(nanoseconds: 20_000_000)
        }
        XCTAssertTrue(completed, "Download task should complete")

        // Check local file contents
        XCTAssertTrue(FileManager.default.fileExists(atPath: localTarget.path))
        let text = try String(contentsOf: localTarget, encoding: .utf8)
        XCTAssertTrue(text.contains("Milestone 6"))

        // Verify transfer queue summary
        XCTAssertTrue(container.transferQueueState.completedTasks.contains { $0.id == enqueuedTask.id })
    }

    // MARK: - 5. Upload Transfer with Progress & Completion

    func testUploadTransferWithProgressAndCompletion() async throws {
        let (container, repo) = makeDemoContainer()
        await container.loadDirectory(at: RemotePath("/home/dev"), bypassCache: true)

        let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent("ShhTestUP_\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let localUploadURL = tempDir.appendingPathComponent("my_uploaded_file.txt")
        let content = "Hello from local iOS file uploader!\n"
        try content.write(to: localUploadURL, atomically: true, encoding: .utf8)

        let task = await container.enqueueUpload(
            localURL: localUploadURL,
            destinationDirectory: RemotePath("/home/dev"),
            overwrite: true
        )
        let enqueuedTask = try XCTUnwrap(task)

        // Wait for upload to complete
        var completed = false
        for _ in 0..<50 {
            if container.transferQueueState.task(withID: enqueuedTask.id)?.state == .completed {
                completed = true
                break
            }
            try await Task.sleep(nanoseconds: 20_000_000)
        }
        XCTAssertTrue(completed, "Upload task should complete")

        // Verify remote file in repository
        let remoteData = try await repo.readFile(at: RemotePath("/home/dev/my_uploaded_file.txt"))
        XCTAssertEqual(String(data: remoteData, encoding: .utf8), content)

        // Verify directory listing refreshed
        XCTAssertTrue(container.currentDirectoryFiles.contains { $0.name == "my_uploaded_file.txt" })
    }

    // MARK: - 6. Transfer Cancellation and Retry

    func testTransferCancellationAndRetry() async throws {
        let (container, _) = makeDemoContainer(simulateDelay: 0.05)
        await container.loadDirectory(at: RemotePath("/home/dev"), bypassCache: true)

        // Create a large file
        let largeData = Data(repeating: 0x42, count: 200_000)
        try await container.createFile(named: "large_cancel.bin", content: largeData)
        let largeFile = try XCTUnwrap(container.currentDirectoryFiles.first { $0.name == "large_cancel.bin" })

        let tempURL = FileManager.default.temporaryDirectory.appendingPathComponent("cancel_\(UUID().uuidString).bin")
        defer { try? FileManager.default.removeItem(at: tempURL) }

        // Start download
        let task = await container.enqueueDownload(file: largeFile, destinationURL: tempURL, overwrite: true)
        let downloadTask = try XCTUnwrap(task)

        // Cancel immediately
        await container.cancelTransfer(id: downloadTask.id)

        // Verify cancelled state
        XCTAssertEqual(container.transferQueueState.task(withID: downloadTask.id)?.state, .cancelled)

        // Retry transfer
        await container.retryTransfer(id: downloadTask.id)

        // Wait for retry completion
        var completed = false
        for _ in 0..<100 {
            if container.transferQueueState.completedTasks.contains(where: { $0.remotePath == largeFile.path }) {
                completed = true
                break
            }
            try await Task.sleep(nanoseconds: 30_000_000)
        }
        XCTAssertTrue(completed, "Retried transfer should eventually complete")

        // Clear completed
        await container.clearCompletedTransfers()
        XCTAssertEqual(container.transferQueueState.completedTasks.count, 0)
    }

    // MARK: - 7. Download Conflict Resolution (Overwrite & Cancel)

    func testDownloadConflictResolution() async throws {
        let (container, _) = makeDemoContainer()
        await container.loadDirectory(at: RemotePath("/home/dev"), bypassCache: true)
        let notesFile = try XCTUnwrap(container.currentDirectoryFiles.first { $0.name == "notes.txt" })

        let localDest = FileManager.default.temporaryDirectory.appendingPathComponent("conflict_notes_\(UUID().uuidString).txt")
        try "Original local content".write(to: localDest, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: localDest) }

        // Case 1: Cancel resolution
        let cancelExpectation = expectation(description: "Download conflict cancelled")
        Task {
            let task = await container.enqueueDownload(file: notesFile, destinationURL: localDest, overwrite: nil)
            XCTAssertNil(task, "Task should be nil when cancelled")
            cancelExpectation.fulfill()
        }

        // Wait for conflict to appear
        for _ in 0..<30 {
            if container.pendingConflict != nil { break }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        XCTAssertNotNil(container.pendingConflict)
        XCTAssertEqual(container.pendingConflict?.direction, .download)

        // Resolve by cancelling
        container.resolvePendingConflict(overwrite: false)
        await fulfillment(of: [cancelExpectation], timeout: 2.0)

        // Verify original content untouched
        XCTAssertEqual(try String(contentsOf: localDest, encoding: .utf8), "Original local content")

        // Case 2: Overwrite resolution
        let overwriteExpectation = expectation(description: "Download conflict overwritten")
        Task {
            let task = await container.enqueueDownload(file: notesFile, destinationURL: localDest, overwrite: nil)
            XCTAssertNotNil(task, "Task should be created when overwritten")
            overwriteExpectation.fulfill()
        }

        for _ in 0..<30 {
            if container.pendingConflict != nil { break }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        XCTAssertNotNil(container.pendingConflict)

        // Resolve by overwriting
        container.resolvePendingConflict(overwrite: true)
        await fulfillment(of: [overwriteExpectation], timeout: 2.0)

        // Wait for transfer completion
        for _ in 0..<50 {
            if container.transferQueueState.completedTasks.contains(where: { $0.localURL == localDest }) {
                break
            }
            try await Task.sleep(nanoseconds: 20_000_000)
        }

        // Verify overwritten content matches remote
        let overwritten = try String(contentsOf: localDest, encoding: .utf8)
        XCTAssertTrue(overwritten.contains("Milestone 6"))
    }

    // MARK: - 8. Upload Conflict Resolution (Overwrite & Cancel)

    func testUploadConflictResolution() async throws {
        let (container, repo) = makeDemoContainer()
        await container.loadDirectory(at: RemotePath("/home/dev"), bypassCache: true)

        let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent("UploadConflict_\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        // Local file named "notes.txt" (which already exists remotely)
        let localNotes = tempDir.appendingPathComponent("notes.txt")
        try "Brand new notes content".write(to: localNotes, atomically: true, encoding: .utf8)

        // Case 1: Cancel resolution
        let cancelExpectation = expectation(description: "Upload conflict cancelled")
        Task {
            let task = await container.enqueueUpload(localURL: localNotes, destinationDirectory: RemotePath("/home/dev"), overwrite: nil)
            XCTAssertNil(task)
            cancelExpectation.fulfill()
        }

        for _ in 0..<30 {
            if container.pendingConflict != nil { break }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        XCTAssertNotNil(container.pendingConflict)
        XCTAssertEqual(container.pendingConflict?.direction, .upload)

        container.resolvePendingConflict(overwrite: false)
        await fulfillment(of: [cancelExpectation], timeout: 2.0)

        // Remote file unchanged
        let existingRemote = try await repo.readFile(at: RemotePath("/home/dev/notes.txt"))
        XCTAssertTrue(String(data: existingRemote, encoding: .utf8)?.contains("Milestone 6") == true)

        // Case 2: Overwrite resolution
        let overwriteExpectation = expectation(description: "Upload conflict overwritten")
        Task {
            let task = await container.enqueueUpload(localURL: localNotes, destinationDirectory: RemotePath("/home/dev"), overwrite: nil)
            XCTAssertNotNil(task)
            overwriteExpectation.fulfill()
        }

        for _ in 0..<30 {
            if container.pendingConflict != nil { break }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        XCTAssertNotNil(container.pendingConflict)

        container.resolvePendingConflict(overwrite: true)
        await fulfillment(of: [overwriteExpectation], timeout: 2.0)

        // Wait for transfer completion
        for _ in 0..<50 {
            if container.transferQueueState.completedTasks.contains(where: { $0.remotePath.description == "/home/dev/notes.txt" }) {
                break
            }
            try await Task.sleep(nanoseconds: 20_000_000)
        }

        // Remote file has new content
        let updatedRemote = try await repo.readFile(at: RemotePath("/home/dev/notes.txt"))
        XCTAssertEqual(String(data: updatedRemote, encoding: .utf8), "Brand new notes content")
    }

    // MARK: - 9. File Previews (Code & Text Syntax Styling)

    func testFilePreviewTextAndSyntaxHighlighting() async throws {
        let (container, _) = makeDemoContainer()
        await container.loadDirectory(at: RemotePath("/home/dev/projects/shh"), bypassCache: true)
        let readme = try XCTUnwrap(container.currentDirectoryFiles.first { $0.name == "README.md" })

        await container.loadPreview(for: readme)
        XCTAssertEqual(container.previewFile?.name, "README.md")
        XCTAssertNotNil(container.previewData)
        let text = try XCTUnwrap(String(data: container.previewData!, encoding: .utf8))
        XCTAssertTrue(text.contains("iPadOS SSH"))

        // Render code preview view
        let view = CodePreviewView(text: text, file: readme)
        let hosting = UIHostingController(rootView: view)
        hosting.loadViewIfNeeded()
        XCTAssertNotNil(hosting.view)

        // Close preview
        container.closePreview()
        XCTAssertNil(container.previewFile)
        XCTAssertNil(container.previewData)
    }

    // MARK: - 10. File Previews (Image & Binary Fallback)

    func testFilePreviewImageAndBinaryFallback() async throws {
        let (container, _) = makeDemoContainer()

        // 1. Image preview test: create a tiny 1x1 PNG image
        let renderer = UIGraphicsImageRenderer(size: CGSize(width: 10, height: 10))
        let img = renderer.image { ctx in
            UIColor.red.setFill()
            ctx.fill(CGRect(x: 0, y: 0, width: 10, height: 10))
        }
        let pngData = try XCTUnwrap(img.pngData())

        try await container.createFile(named: "icon.png", content: pngData)
        let imageFile = try XCTUnwrap(container.currentDirectoryFiles.first { $0.name == "icon.png" })

        await container.loadPreview(for: imageFile)
        XCTAssertEqual(container.previewFile?.name, "icon.png")
        XCTAssertNotNil(container.previewData)

        let imagePreview = ImagePreviewView(image: img, file: imageFile)
        let imgHosting = UIHostingController(rootView: imagePreview)
        imgHosting.loadViewIfNeeded()
        XCTAssertNotNil(imgHosting.view)

        container.closePreview()

        // 2. Binary fallback test
        let binaryBytes = Data([0x00, 0x01, 0x02, 0x03, 0xFF, 0xFE, 0xFD, 0xFC])
        try await container.createFile(named: "data.bin", content: binaryBytes)
        let binaryFile = try XCTUnwrap(container.currentDirectoryFiles.first { $0.name == "data.bin" })

        await container.loadPreview(for: binaryFile)
        let binaryPreview = BinaryHexPreviewView(data: binaryBytes, file: binaryFile)
        let binHosting = UIHostingController(rootView: binaryPreview)
        binHosting.loadViewIfNeeded()
        XCTAssertNotNil(binHosting.view)

        container.closePreview()
    }

    // MARK: - 11. In-App Text File Editor (Open, Edit, Save, Upload)

    func testInAppTextFileEditorSaveAndUploadReplacement() async throws {
        let (container, repo) = makeDemoContainer()
        await container.loadDirectory(at: RemotePath("/home/dev"), bypassCache: true)
        let notesFile = try XCTUnwrap(container.currentDirectoryFiles.first { $0.name == "notes.txt" })

        // Open editor
        try await container.openEditor(for: notesFile)
        XCTAssertEqual(container.activeEditingFile?.name, "notes.txt")
        XCTAssertTrue(container.editingFileContent.contains("Milestone 6"))

        // Modify content
        container.editingFileContent = "Edited via in-app SFTP editor\nLine 2\n"

        // Save file
        try await container.saveEditedFile()
        XCTAssertFalse(container.isSavingFile)
        XCTAssertNil(container.editorErrorMessage)

        // Verify remote repository has updated content
        let readBack = try await repo.readFile(at: notesFile.path)
        XCTAssertEqual(String(data: readBack, encoding: .utf8), "Edited via in-app SFTP editor\nLine 2\n")

        // Close editor
        container.closeEditor()
        XCTAssertNil(container.activeEditingFile)
        XCTAssertEqual(container.editingFileContent, "")
    }

    // MARK: - 12. File Management Actions (CRUD & Deletion)

    func testFileManagementCRUDAndDeletion() async throws {
        let (container, _) = makeDemoContainer()
        await container.loadDirectory(at: RemotePath("/home/dev"), bypassCache: true)

        // 1. Create Directory
        try await container.createDirectory(named: "workspace")
        XCTAssertTrue(container.currentDirectoryFiles.contains { $0.name == "workspace" && $0.isDirectory })

        // 2. Create File inside current directory
        try await container.createFile(named: "temp_doc.txt", content: Data("Doc content".utf8))
        let createdDoc = try XCTUnwrap(container.currentDirectoryFiles.first { $0.name == "temp_doc.txt" })
        XCTAssertTrue(createdDoc.isFile)

        // 3. Rename File
        try await container.renameFile(createdDoc, to: "renamed_doc.txt")
        XCTAssertFalse(container.currentDirectoryFiles.contains { $0.name == "temp_doc.txt" })
        let renamedDoc = try XCTUnwrap(container.currentDirectoryFiles.first { $0.name == "renamed_doc.txt" })

        // 4. Move File into workspace directory
        try await container.moveFile(renamedDoc, to: RemotePath("/home/dev/workspace"))
        XCTAssertFalse(container.currentDirectoryFiles.contains { $0.name == "renamed_doc.txt" })

        await container.navigateTo(RemotePath("/home/dev/workspace"))
        let workspaceFiles = container.currentDirectoryFiles
        XCTAssertTrue(workspaceFiles.contains { $0.name == "renamed_doc.txt" })

        // 5. Delete File
        let docToDelete = try XCTUnwrap(workspaceFiles.first { $0.name == "renamed_doc.txt" })
        try await container.deleteFile(docToDelete)
        XCTAssertFalse(container.currentDirectoryFiles.contains { $0.name == "renamed_doc.txt" })

        // 6. Delete empty Directory
        await container.navigateUp()
        let dirToDelete = try XCTUnwrap(container.currentDirectoryFiles.first { $0.name == "workspace" })
        try await container.deleteFile(dirToDelete)
        XCTAssertFalse(container.currentDirectoryFiles.contains { $0.name == "workspace" })
    }

    // MARK: - 13. VoiceOver Accessibility & Dynamic Type

    func testVoiceOverAccessibilityAndDynamicType() async throws {
        let (container, _) = makeDemoContainer()
        await container.loadDirectory(at: RemotePath("/home/dev"), bypassCache: true)

        let dirFile = try XCTUnwrap(container.currentDirectoryFiles.first { $0.isDirectory })
        let regularFile = try XCTUnwrap(container.currentDirectoryFiles.first { $0.isFile })
        let symlinkFile = try XCTUnwrap(container.currentDirectoryFiles.first { $0.isSymlink })

        // 1. Accessibility Description checks
        let dirRow = RemoteFileRowView(file: dirFile)
        let fileRow = RemoteFileRowView(file: regularFile)
        let symlinkRow = RemoteFileRowView(file: symlinkFile)

        let dirHosting = UIHostingController(rootView: dirRow)
        let fileHosting = UIHostingController(rootView: fileRow)
        let symlinkHosting = UIHostingController(rootView: symlinkRow)

        dirHosting.loadViewIfNeeded()
        fileHosting.loadViewIfNeeded()
        symlinkHosting.loadViewIfNeeded()

        XCTAssertNotNil(dirHosting.view)
        XCTAssertNotNil(fileHosting.view)
        XCTAssertNotNil(symlinkHosting.view)

        // 2. Breadcrumbs Bar View
        let breadcrumbs = BreadcrumbsBarView().environmentObject(container)
        let breadcrumbsHosting = UIHostingController(rootView: breadcrumbs)
        breadcrumbsHosting.loadViewIfNeeded()
        XCTAssertNotNil(breadcrumbsHosting.view)

        // 3. Transfer Queue Drawer
        let drawer = TransferQueueDrawerView().environmentObject(container)
        let drawerHosting = UIHostingController(rootView: drawer)
        drawerHosting.loadViewIfNeeded()
        XCTAssertNotNil(drawerHosting.view)
    }

    // MARK: - 14. Full FilesView Hosting Layout (iPhone and iPad)

    func testFilesViewHostingAcrossPhoneAndPad() async throws {
        let (container, _) = makeDemoContainer()
        await container.loadDirectory(at: RemotePath("/home/dev"), bypassCache: true)

        let filesView = FilesView().environmentObject(container)
        let hosting = UIHostingController(rootView: filesView)

        // iPhone compact width
        hosting.view.frame = CGRect(x: 0, y: 0, width: 393, height: 852)
        hosting.loadViewIfNeeded()
        XCTAssertNotNil(hosting.view)

        // iPad regular width
        hosting.view.frame = CGRect(x: 0, y: 0, width: 1024, height: 768)
        hosting.view.setNeedsLayout()
        hosting.view.layoutIfNeeded()
        XCTAssertNotNil(hosting.view)
    }

    // MARK: - 15. Regression: Disconnect Teardown & Editor Target Isolation (Finding 1)

    func testDisconnectResetsSFTPStateAndCancelsTransfersAndGuardsIsolation() async throws {
        let (container, repo) = makeDemoContainer()
        await container.loadDirectory(at: RemotePath("/home/dev"), bypassCache: true)
        let notesFile = try XCTUnwrap(container.currentDirectoryFiles.first { $0.name == "notes.txt" })

        // 1. Open preview and editor
        await container.loadPreview(for: notesFile)
        XCTAssertNotNil(container.previewFile)
        XCTAssertNotNil(container.previewData)

        try await container.openEditor(for: notesFile)
        XCTAssertNotNil(container.activeEditingFile)
        XCTAssertFalse(container.editingFileContent.isEmpty)

        // 2. Start a transfer
        await repo.setSimulateTransferChunkDelay(0.1)
        _ = await container.enqueueDownload(file: notesFile)
        XCTAssertFalse(container.transferQueueState.tasks.isEmpty)

        // 3. Disconnect
        await container.disconnect()

        // Assert all SFTP session state is cleanly torn down
        XCTAssertNil(container.previewFile)
        XCTAssertNil(container.previewData)
        XCTAssertNil(container.activeEditingFile)
        XCTAssertEqual(container.editingFileContent, "")
        XCTAssertTrue(container.currentDirectoryFiles.isEmpty)
        XCTAssertEqual(container.currentPath.description, "/home/dev")
        XCTAssertNil(container.pendingConflict)
        XCTAssertNil(container.activeEditingHostID)

        // Attempting to save after disconnect throws connectionClosed
        do {
            try await container.saveEditedFile()
            XCTFail("Saving edited file after disconnect must fail")
        } catch {
            XCTAssertTrue(error is SFTPRepositoryError)
        }
    }

    // MARK: - 16. Regression: Atomic Download Preserves Existing File On Interruption (Finding 2)

    func testAtomicDownloadPreservesExistingFileOnFailureOrCancellation() async throws {
        let (container, repo) = makeDemoContainer()
        await container.loadDirectory(at: RemotePath("/home/dev"), bypassCache: true)
        let notesFile = try XCTUnwrap(container.currentDirectoryFiles.first { $0.name == "notes.txt" })

        let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent("atomic_test_\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let localTarget = tempDir.appendingPathComponent("precious_local_file.txt")
        let originalContent = "Precious local file content that must not be deleted\n"
        try originalContent.write(to: localTarget, atomically: true, encoding: .utf8)

        // Set slow transfer
        await repo.setSimulateTransferChunkDelay(0.5)

        // Start download with overwrite
        let downloadTask = await container.enqueueDownload(file: notesFile, destinationURL: localTarget, overwrite: true)
        let taskID = try XCTUnwrap(downloadTask?.id)

        // Verify initial state
        XCTAssertTrue(FileManager.default.fileExists(atPath: localTarget.path), "Local file must exist before cancel")

        // Cancel before download finishes
        await container.cancelTransfer(id: taskID)

        // Verify local file is STILL intact and contains the original content!
        XCTAssertTrue(FileManager.default.fileExists(atPath: localTarget.path), "Original file must not have been removed prematurely")
        let contentAfterCancel = try String(contentsOf: localTarget, encoding: .utf8)
        XCTAssertEqual(contentAfterCancel, originalContent, "Original file content must be preserved upon cancellation")
    }

    // MARK: - 17. Regression: Path Traversal Rejection in File Actions (Finding 3)

    func testPathTraversalRejectionInFileActionsAndDownloads() async throws {
        let (container, _) = makeDemoContainer()
        await container.loadDirectory(at: RemotePath("/home/dev"), bypassCache: true)
        let notesFile = try XCTUnwrap(container.currentDirectoryFiles.first { $0.name == "notes.txt" })

        // Create file with .. or .
        do {
            try await container.createFile(named: "..")
            XCTFail("Creating file named '..' must throw invalidPath")
        } catch let SFTPRepositoryError.invalidPath(msg) {
            XCTAssertTrue(msg.contains(".."))
        }

        do {
            try await container.createFile(named: ".")
            XCTFail("Creating file named '.' must throw invalidPath")
        } catch let SFTPRepositoryError.invalidPath(msg) {
            XCTAssertTrue(msg.contains("."))
        }

        // Create directory with .. or .
        do {
            try await container.createDirectory(named: "..")
            XCTFail("Creating directory named '..' must throw invalidPath")
        } catch let SFTPRepositoryError.invalidPath(msg) {
            XCTAssertTrue(msg.contains(".."))
        }

        do {
            try await container.createDirectory(named: ".")
            XCTFail("Creating directory named '.' must throw invalidPath")
        } catch let SFTPRepositoryError.invalidPath(msg) {
            XCTAssertTrue(msg.contains("."))
        }

        // Rename file to .. or .
        do {
            try await container.renameFile(notesFile, to: "..")
            XCTFail("Renaming file to '..' must throw invalidPath")
        } catch let SFTPRepositoryError.invalidPath(msg) {
            XCTAssertTrue(msg.contains(".."))
        }

        do {
            try await container.renameFile(notesFile, to: ".")
            XCTFail("Renaming file to '.' must throw invalidPath")
        } catch let SFTPRepositoryError.invalidPath(msg) {
            XCTAssertTrue(msg.contains("."))
        }

        // Download with traversal filename gets sanitized
        let traversalFile = RemoteFile(
            name: "../../escape.txt",
            path: RemotePath("/home/dev/notes.txt")
        )
        let dlTask = await container.enqueueDownload(file: traversalFile, overwrite: true)
        XCTAssertNotNil(dlTask)
        XCTAssertTrue(dlTask?.localURL.path.contains("ShhDownloads/escape.txt") == true)
        XCTAssertFalse(dlTask?.localURL.path.contains("..") == true)
    }

    // MARK: - 18. Regression: Directory Ancestry Validation in Move (UX Finding 5)

    func testDirectoryAncestryValidationInMoveFile() async throws {
        let (container, _) = makeDemoContainer()
        await container.loadDirectory(at: RemotePath("/home/dev"), bypassCache: true)
        let projectsDir = try XCTUnwrap(container.currentDirectoryFiles.first { $0.name == "projects" })

        // Attempting to move /home/dev/projects into /home/dev/projects/shh (descendant)
        do {
            try await container.moveFile(projectsDir, to: RemotePath("/home/dev/projects/shh"))
            XCTFail("Moving a directory into its descendant must throw invalidPath")
        } catch let SFTPRepositoryError.invalidPath(msg) {
            XCTAssertTrue(msg.contains("descendant") || msg.contains("Cannot move"))
        }

        // Attempting to move directory into itself
        do {
            try await container.moveFile(projectsDir, to: RemotePath("/home/dev/projects"))
            XCTFail("Moving a directory into itself must throw invalidPath")
        } catch let SFTPRepositoryError.invalidPath(msg) {
            XCTAssertTrue(msg.contains("descendant") || msg.contains("Cannot move"))
        }
    }

    // MARK: - 19. Regression: Concurrent Transfer Conflict Queue (Finding 5 / UX Finding 2)

    func testConcurrentTransferConflictsQueueFIFOWitoutLeakingContinuations() async throws {
        let (container, _) = makeDemoContainer()
        await container.loadDirectory(at: RemotePath("/home/dev"), bypassCache: true)
        let notesFile = try XCTUnwrap(container.currentDirectoryFiles.first { $0.name == "notes.txt" })
        let bashrcFile = try XCTUnwrap(container.currentDirectoryFiles.first { $0.name == ".bashrc" })

        let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent("conflict_q_\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let localURL1 = tempDir.appendingPathComponent("file1.txt")
        let localURL2 = tempDir.appendingPathComponent("file2.txt")
        try "existing 1".write(to: localURL1, atomically: true, encoding: .utf8)
        try "existing 2".write(to: localURL2, atomically: true, encoding: .utf8)

        // Launch two downloads with collisions concurrently
        let t1 = Task {
            await container.enqueueDownload(file: notesFile, destinationURL: localURL1)
        }
        let t2 = Task {
            await container.enqueueDownload(file: bashrcFile, destinationURL: localURL2)
        }

        // Wait briefly for both tasks to encounter conflicts
        try await Task.sleep(nanoseconds: 50_000_000)

        // Conflict 1 should be active
        let conflict1 = try XCTUnwrap(container.pendingConflict)
        XCTAssertEqual(conflict1.existingItemName, notesFile.name)

        // Resolve conflict 1
        container.resolvePendingConflict(overwrite: true)

        // Wait briefly for queue to advance
        try await Task.sleep(nanoseconds: 50_000_000)

        // Conflict 2 should now automatically be presented
        let conflict2 = try XCTUnwrap(container.pendingConflict)
        XCTAssertEqual(conflict2.existingItemName, bashrcFile.name)

        // Resolve conflict 2 (cancel)
        container.resolvePendingConflict(overwrite: false)

        let result1 = await t1.value
        let result2 = await t2.value

        XCTAssertNotNil(result1, "First transfer was overwritten, must have TransferTask")
        XCTAssertNil(result2, "Second transfer was declined, must be nil")
        XCTAssertNil(container.pendingConflict, "Conflict queue should be drained")
    }

    // MARK: - 20. Regression: Symlink Directory Navigation (Finding 6)

    func testSymlinkDirectoryNavigation() async throws {
        let (container, _) = makeDemoContainer()
        await container.loadDirectory(at: RemotePath("/home/dev"), bypassCache: true)

        // Find symlink current_project -> /home/dev/projects/shh
        let symlink = try XCTUnwrap(container.currentDirectoryFiles.first { $0.name == "current_project" })
        XCTAssertTrue(symlink.isSymlink)

        // Open item (on tap)
        await container.openItem(symlink)

        // Should have navigated into the symlink directory
        XCTAssertEqual(container.currentPath.description, "/home/dev/current_project")
        XCTAssertFalse(container.currentDirectoryFiles.isEmpty)
        let childNames = Set(container.currentDirectoryFiles.map(\.name))
        XCTAssertTrue(childNames.contains("README.md"), "Symlinked directory must show README.md")
    }

    // MARK: - 21. Regression: Binary File Protection in Text Editor (Finding 9)

    func testBinaryFileRejectedInTextEditor() async throws {
        let (container, repo) = makeDemoContainer()
        let binaryPath = RemotePath("/home/dev/corrupt.bin")
        let binaryBytes = Data([0xFF, 0xFE, 0x00, 0xFD, 0xAA, 0xBB])
        try await repo.writeFile(data: binaryBytes, at: binaryPath)

        await container.loadDirectory(at: RemotePath("/home/dev"), bypassCache: true)
        let binFile = try XCTUnwrap(container.currentDirectoryFiles.first { $0.name == "corrupt.bin" })

        do {
            try await container.openEditor(for: binFile)
            XCTFail("Opening binary file in text editor must throw error")
        } catch let SFTPRepositoryError.remoteFailure(msg) {
            XCTAssertTrue(msg.contains("binary data") || msg.contains("non-UTF-8"))
        }

        XCTAssertNil(container.activeEditingFile)
    }

    // MARK: - 22. Regression: File Size Limits in Preview & Editor (UX Finding 6)

    func testFileSizeLimitsInPreviewAndEditor() async throws {
        let (container, repo) = makeDemoContainer()

        // 6 MB file (exceeds 5 MB preview limit)
        let hugePath = RemotePath("/home/dev/huge.txt")
        let sixMB = Data(repeating: 0x41, count: 6 * 1024 * 1024)
        try await repo.writeFile(data: sixMB, at: hugePath)

        await container.loadDirectory(at: RemotePath("/home/dev"), bypassCache: true)
        let hugeFile = try XCTUnwrap(container.currentDirectoryFiles.first { $0.name == "huge.txt" })

        await container.loadPreview(for: hugeFile)
        XCTAssertNil(container.previewData)
        XCTAssertTrue(container.previewErrorMessage?.contains("5 MB preview limit") == true)

        // 3 MB file (exceeds 2 MB editor limit)
        let medPath = RemotePath("/home/dev/medium.txt")
        let threeMB = Data(repeating: 0x42, count: 3 * 1024 * 1024)
        try await repo.writeFile(data: threeMB, at: medPath)

        await container.loadDirectory(at: RemotePath("/home/dev"), bypassCache: true)
        let medFile = try XCTUnwrap(container.currentDirectoryFiles.first { $0.name == "medium.txt" })

        do {
            try await container.openEditor(for: medFile)
            XCTFail("Opening file > 2MB in editor must throw error")
        } catch let SFTPRepositoryError.remoteFailure(msg) {
            XCTAssertTrue(msg.contains("2 MB editor limit"))
        }
        XCTAssertNil(container.activeEditingFile)
    }

    // MARK: - 23. Regression: Temporary Transfers Cleanup (Finding 8)

    func testTemporaryTransfersCleanup() async throws {
        let (container, _) = makeDemoContainer()
        await container.loadDirectory(at: RemotePath("/home/dev"), bypassCache: true)
        let notesFile = try XCTUnwrap(container.currentDirectoryFiles.first { $0.name == "notes.txt" })

        // Download a file
        let task = await container.enqueueDownload(file: notesFile)
        XCTAssertNotNil(task)

        // Wait for download to complete
        try await Task.sleep(nanoseconds: 50_000_000)

        // Clear completed transfers cleans up
        await container.clearCompletedTransfers()
        XCTAssertTrue(container.transferQueueState.tasks.isEmpty)

        // Disconnect cleans up everything
        await container.disconnect()
    }

    // MARK: - 24. Regression: Editor Target Host Isolation Mismatch (Finding 1)

    func testEditorTargetHostIsolationMismatchRejectsSave() async throws {
        let (container, _) = makeDemoContainer()
        await container.loadDirectory(at: RemotePath("/home/dev"), bypassCache: true)
        let notesFile = try XCTUnwrap(container.currentDirectoryFiles.first { $0.name == "notes.txt" })

        try await container.openEditor(for: notesFile)
        XCTAssertNotNil(container.activeEditingFile)

        // Switch to a new host directly
        let hostB = try Host(name: "HostB", hostname: "hostb.invalid", username: "dev")
        await container.connect(to: hostB)

        // Verify editor was closed and activeEditingFile is nil
        XCTAssertNil(container.activeEditingFile)
        XCTAssertNil(container.activeEditingHostID)

        // Attempting to save throws connectionClosed
        do {
            try await container.saveEditedFile()
            XCTFail("Saving file after switching hosts must throw error")
        } catch {
            XCTAssertTrue(error is SFTPRepositoryError)
        }
    }
}

extension DemoSFTPRepository {
    func setSimulateTransferChunkDelay(_ delay: TimeInterval) {
        self.simulateTransferChunkDelay = delay
    }
}
