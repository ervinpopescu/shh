import Foundation
import ShhCore
import SwiftUI
#if canImport(UIKit)
import UIKit
#endif

// MARK: - SFTP Browser View

struct FilesView: View {
    @EnvironmentObject private var container: AppContainer

    @State private var showingCreateFolder = false
    @State private var newFolderName = ""
    @State private var showingCreateFile = false
    @State private var newFileName = ""
    @State private var showingRename = false
    @State private var fileToRename: RemoteFile? = nil
    @State private var renameNewName = ""
    @State private var fileToDelete: RemoteFile? = nil
    @State private var fileToMove: RemoteFile? = nil
    @State private var showingFileImporter = false
    @State private var errorMessage: String? = nil
    @State private var showingErrorAlert = false

    var body: some View {
        mainContent
            .navigationTitle(container.currentPath.isRoot ? "Files" : container.currentPath.lastComponent)
            .navigationBarTitleDisplayMode(.inline)
            .searchable(text: $container.fileSearchQuery, prompt: "Search files")
            .toolbar { toolbarContent }
            .fileModals(
                showingCreateFolder: $showingCreateFolder,
                newFolderName: $newFolderName,
                showingCreateFile: $showingCreateFile,
                newFileName: $newFileName,
                showingRename: $showingRename,
                fileToRename: $fileToRename,
                renameNewName: $renameNewName,
                fileToDelete: $fileToDelete,
                fileToMove: $fileToMove,
                showingFileImporter: $showingFileImporter,
                errorMessage: $errorMessage,
                showingErrorAlert: $showingErrorAlert
            )
    }

    @ViewBuilder
    private var mainContent: some View {
        if container.sftpRepository == nil {
            if let error = container.sftpErrorMessage {
                ContentUnavailableView(
                    "SFTP Unavailable",
                    systemImage: "exclamationmark.triangle",
                    description: Text("Failed to initialize SFTP subsystem: \(error)")
                )
            } else {
                ContentUnavailableView(
                    "SFTP Not Connected",
                    systemImage: "folder.badge.gearshape",
                    description: Text("Connect to an SSH host to browse remote files.")
                )
            }
        } else {
            VStack(spacing: 0) {
                BreadcrumbsBarView()
                Divider()

                if container.isLoadingDirectory && container.currentDirectoryFiles.isEmpty {
                    Spacer()
                    ProgressView("Loading directory...")
                        .accessibilityLabel("Loading directory")
                    Spacer()
                } else if let error = container.directoryErrorMessage, container.currentDirectoryFiles.isEmpty {
                    ContentUnavailableView(
                        "Directory Unavailable",
                        systemImage: "exclamationmark.triangle",
                        description: Text(error)
                    )
                    Button("Retry") {
                        Task { await container.refreshCurrentDirectory() }
                    }
                    .buttonStyle(.borderedProminent)
                    .padding()
                } else if container.sortedAndFilteredFiles.isEmpty {
                    if !container.fileSearchQuery.isEmpty {
                        ContentUnavailableView.search(text: container.fileSearchQuery)
                    } else {
                        ContentUnavailableView(
                            "Empty Directory",
                            systemImage: "folder",
                            description: Text("This folder has no files.")
                        )
                    }
                } else {
                    fileList
                }
            }
        }
    }

    @ToolbarContentBuilder
    private var toolbarContent: some ToolbarContent {
        ToolbarItemGroup(placement: .primaryAction) {
            transferQueueButton
            addMenu
            sortMenu
            refreshButton
        }
    }

    // MARK: - File List

    private var fileList: some View {
        List {
            ForEach(container.sortedAndFilteredFiles) { file in
                RemoteFileRowView(file: file)
                    .contentShape(Rectangle())
                    .onTapGesture {
                        Task { await container.openItem(file) }
                    }
                    .contextMenu {
                        if file.isDirectory || file.isSymlink {
                            Button("Open Folder", systemImage: "folder") {
                                Task { await container.navigateTo(file.path) }
                            }
                        }
                        if !file.isDirectory {
                            Button("Preview", systemImage: "eye") {
                                Task { await container.loadPreview(for: file) }
                            }
                            Button("Edit in Editor", systemImage: "pencil") {
                                Task {
                                    do {
                                        try await container.openEditor(for: file)
                                    } catch {
                                        errorMessage = error.localizedDescription
                                        showingErrorAlert = true
                                    }
                                }
                            }
                            Button("Download", systemImage: "arrow.down.circle") {
                                Task { _ = await container.enqueueDownload(file: file) }
                            }
                        }
                        Button("Rename", systemImage: "pencil.line") {
                            fileToRename = file
                            renameNewName = file.name
                            showingRename = true
                        }
                        Button("Move", systemImage: "arrow.right.circle") {
                            fileToMove = file
                        }
                        Divider()
                        Button("Delete", systemImage: "trash", role: .destructive) {
                            fileToDelete = file
                        }
                    }
                    .swipeActions(edge: .leading) {
                        if !file.isDirectory {
                            Button {
                                Task { _ = await container.enqueueDownload(file: file) }
                            } label: {
                                Label("Download", systemImage: "arrow.down.circle")
                            }
                            .tint(.blue)
                        }
                    }
                    .swipeActions(edge: .trailing) {
                        Button(role: .destructive) {
                            fileToDelete = file
                        } label: {
                            Label("Delete", systemImage: "trash")
                        }
                        Button {
                            fileToRename = file
                            renameNewName = file.name
                            showingRename = true
                        } label: {
                            Label("Rename", systemImage: "pencil")
                        }
                        .tint(.orange)
                    }
            }
        }
        .listStyle(.plain)
        .refreshable {
            await container.refreshCurrentDirectory()
        }
    }

    private var transferQueueButton: some View {
        Button {
            container.isTransferQueueOpen = true
        } label: {
            let activeCount = container.transferQueueState.activeTasks.count + container.transferQueueState.queuedTasks.count
            ZStack(alignment: .topTrailing) {
                Image(systemName: activeCount > 0 ? "arrow.left.arrow.right.circle.fill" : "tray")
                    .imageScale(.medium)
                if activeCount > 0 {
                    Text("\(activeCount)")
                        .font(.system(size: 10, weight: .bold))
                        .foregroundColor(.white)
                        .padding(3)
                        .background(Color.blue, in: Circle())
                        .offset(x: 8, y: -8)
                }
            }
        }
        .accessibilityLabel("Transfer queue, \(container.transferQueueState.tasks.count) transfers")
    }

    private var addMenu: some View {
        Menu {
            Button {
                newFolderName = ""
                showingCreateFolder = true
            } label: {
                Label("New Folder", systemImage: "folder.badge.plus")
            }

            Button {
                newFileName = ""
                showingCreateFile = true
            } label: {
                Label("New File", systemImage: "doc.badge.plus")
            }

            Button {
                showingFileImporter = true
            } label: {
                Label("Upload from Device", systemImage: "arrow.up.doc")
            }
        } label: {
            Image(systemName: "plus")
        }
        .accessibilityLabel("Add folder, file, or upload")
    }

    private var sortMenu: some View {
        Menu {
            Picker("Sort by", selection: $container.sortField) {
                ForEach(FileSortField.allCases) { field in
                    Text(field.rawValue).tag(field)
                }
            }
            Divider()
            Toggle("Ascending", isOn: $container.sortAscending)
        } label: {
            Image(systemName: "arrow.up.arrow.down")
        }
        .accessibilityLabel("Sort files")
    }

    private var refreshButton: some View {
        Button {
            Task { await container.refreshCurrentDirectory() }
        } label: {
            Image(systemName: "arrow.clockwise")
        }
        .accessibilityLabel("Refresh directory")
    }
}

// MARK: - File Modals View Modifier

private extension View {
    func fileModals(
        showingCreateFolder: Binding<Bool>,
        newFolderName: Binding<String>,
        showingCreateFile: Binding<Bool>,
        newFileName: Binding<String>,
        showingRename: Binding<Bool>,
        fileToRename: Binding<RemoteFile?>,
        renameNewName: Binding<String>,
        fileToDelete: Binding<RemoteFile?>,
        fileToMove: Binding<RemoteFile?>,
        showingFileImporter: Binding<Bool>,
        errorMessage: Binding<String?>,
        showingErrorAlert: Binding<Bool>
    ) -> some View {
        modifier(FileModalsModifier(
            showingCreateFolder: showingCreateFolder,
            newFolderName: newFolderName,
            showingCreateFile: showingCreateFile,
            newFileName: newFileName,
            showingRename: showingRename,
            fileToRename: fileToRename,
            renameNewName: renameNewName,
            fileToDelete: fileToDelete,
            fileToMove: fileToMove,
            showingFileImporter: showingFileImporter,
            errorMessage: errorMessage,
            showingErrorAlert: showingErrorAlert
        ))
    }
}

private struct FileModalsModifier: ViewModifier {
    @EnvironmentObject private var container: AppContainer

    @Binding var showingCreateFolder: Bool
    @Binding var newFolderName: String
    @Binding var showingCreateFile: Bool
    @Binding var newFileName: String
    @Binding var showingRename: Bool
    @Binding var fileToRename: RemoteFile?
    @Binding var renameNewName: String
    @Binding var fileToDelete: RemoteFile?
    @Binding var fileToMove: RemoteFile?
    @Binding var showingFileImporter: Bool
    @Binding var errorMessage: String?
    @Binding var showingErrorAlert: Bool

    func body(content: Content) -> some View {
        content
            .sheet(isPresented: Binding(
                get: { container.previewFile != nil },
                set: { if !$0 { container.closePreview() } }
            )) {
                FilePreviewSheet(onEdit: { file in
                    container.closePreview()
                    Task {
                        try? await Task.sleep(nanoseconds: 350_000_000)
                        do {
                            try await container.openEditor(for: file)
                        } catch {
                            errorMessage = error.localizedDescription
                            showingErrorAlert = true
                        }
                    }
                })
                .environmentObject(container)
            }
            .sheet(isPresented: Binding(
                get: { container.activeEditingFile != nil },
                set: { if !$0 { container.closeEditor() } }
            )) {
                FileEditorSheet()
                    .environmentObject(container)
            }
            .sheet(isPresented: $container.isTransferQueueOpen) {
                TransferQueueDrawerView()
                    .environmentObject(container)
            }
            .sheet(item: $fileToMove) { file in
                FileMovePickerSheet(file: file)
                    .environmentObject(container)
            }
            .alert("New Folder", isPresented: $showingCreateFolder) {
                TextField("Folder name", text: $newFolderName)
                Button("Create") {
                    let name = newFolderName
                    newFolderName = ""
                    Task {
                        do {
                            try await container.createDirectory(named: name)
                        } catch {
                            errorMessage = error.localizedDescription
                            showingErrorAlert = true
                        }
                    }
                }
                Button("Cancel", role: .cancel) { newFolderName = "" }
            } message: {
                Text("Enter a name for the new remote directory.")
            }
            .alert("New File", isPresented: $showingCreateFile) {
                TextField("File name", text: $newFileName)
                Button("Create") {
                    let name = newFileName
                    newFileName = ""
                    Task {
                        do {
                            try await container.createFile(named: name)
                        } catch {
                            errorMessage = error.localizedDescription
                            showingErrorAlert = true
                        }
                    }
                }
                Button("Cancel", role: .cancel) { newFileName = "" }
            } message: {
                Text("Enter a name for the new empty file.")
            }
            .alert("Rename File", isPresented: $showingRename) {
                TextField("New name", text: $renameNewName)
                Button("Rename") {
                    guard let file = fileToRename else { return }
                    let newName = renameNewName
                    fileToRename = nil
                    renameNewName = ""
                    Task {
                        do {
                            try await container.renameFile(file, to: newName)
                        } catch {
                            errorMessage = error.localizedDescription
                            showingErrorAlert = true
                        }
                    }
                }
                Button("Cancel", role: .cancel) {
                    fileToRename = nil
                    renameNewName = ""
                }
            } message: {
                if let file = fileToRename {
                    Text("Enter a new name for '\(file.name)'.")
                }
            }
            .alert("Error", isPresented: $showingErrorAlert) {
                Button("OK", role: .cancel) { errorMessage = nil }
            } message: {
                Text(errorMessage ?? "An unexpected error occurred.")
            }
            .confirmationDialog(
                "Delete Item",
                isPresented: Binding(
                    get: { fileToDelete != nil },
                    set: { if !$0 { fileToDelete = nil } }
                ),
                titleVisibility: .visible,
                presenting: fileToDelete
            ) { file in
                Button("Delete '\(file.name)'", role: .destructive) {
                    Task {
                        do {
                            try await container.deleteFile(file)
                        } catch {
                            errorMessage = error.localizedDescription
                            showingErrorAlert = true
                        }
                    }
                }
                Button("Cancel", role: .cancel) {}
            } message: { file in
                Text("Are you sure you want to delete '\(file.name)'? This action cannot be undone.")
            }
            .confirmationDialog(
                "File Conflict",
                isPresented: Binding(
                    get: { container.pendingConflict != nil },
                    set: { if !$0 { container.resolvePendingConflict(overwrite: false) } }
                ),
                titleVisibility: .visible,
                presenting: container.pendingConflict
            ) { conflict in
                Button("Overwrite", role: .destructive) {
                    container.resolvePendingConflict(overwrite: true)
                }
                Button("Cancel Transfer", role: .cancel) {
                    container.resolvePendingConflict(overwrite: false)
                }
            } message: { conflict in
                Text("A file named '\(conflict.existingItemName)' already exists at the destination (\(conflict.destinationDescription)). Do you want to overwrite it?")
            }
            .fileImporter(
                isPresented: $showingFileImporter,
                allowedContentTypes: [.item],
                allowsMultipleSelection: true
            ) { result in
                switch result {
                case .success(let urls):
                    let uploadBaseDir = FileManager.default.temporaryDirectory.appendingPathComponent("ShhUploads", isDirectory: true)
                    try? FileManager.default.createDirectory(at: uploadBaseDir, withIntermediateDirectories: true)

                    for url in urls {
                        guard url.startAccessingSecurityScopedResource() else { continue }
                        let stagedFolder = uploadBaseDir.appendingPathComponent(UUID().uuidString, isDirectory: true)
                        try? FileManager.default.createDirectory(at: stagedFolder, withIntermediateDirectories: true)
                        let stagedURL = stagedFolder.appendingPathComponent(url.lastPathComponent)

                        do {
                            if FileManager.default.fileExists(atPath: stagedURL.path) {
                                try? FileManager.default.removeItem(at: stagedURL)
                            }
                            try FileManager.default.copyItem(at: url, to: stagedURL)
                            url.stopAccessingSecurityScopedResource()

                            Task {
                                _ = await container.enqueueUpload(localURL: stagedURL)
                            }
                        } catch {
                            url.stopAccessingSecurityScopedResource()
                            errorMessage = "Failed to prepare '\(url.lastPathComponent)' for upload: \(error.localizedDescription)"
                            showingErrorAlert = true
                        }
                    }
                case .failure(let error):
                    errorMessage = error.localizedDescription
                    showingErrorAlert = true
                }
            }
    }
}

// MARK: - Breadcrumbs Bar View

struct BreadcrumbsBarView: View {
    @EnvironmentObject private var container: AppContainer

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 4) {
                Button {
                    Task { await container.navigateUp() }
                } label: {
                    Image(systemName: "arrow.up")
                        .font(.footnote.weight(.semibold))
                        .padding(.horizontal, 6)
                        .padding(.vertical, 4)
                }
                .disabled(container.currentPath.isRoot)
                .buttonStyle(.bordered)
                .accessibilityLabel("Go to parent directory")

                Divider()
                    .frame(height: 16)

                if container.currentPath.isRoot {
                    Button {
                        Task { await container.navigateTo(.root) }
                    } label: {
                        rootButtonLabel
                    }
                    .buttonStyle(.borderedProminent)
                    .accessibilityLabel("Root directory")
                } else {
                    Button {
                        Task { await container.navigateTo(.root) }
                    } label: {
                        rootButtonLabel
                    }
                    .buttonStyle(.borderless)
                    .accessibilityLabel("Root directory")
                }

                ForEach(Array(container.currentPath.components.enumerated()), id: \.offset) { index, component in
                    Image(systemName: "chevron.right")
                        .font(.caption2)
                        .foregroundColor(.secondary)

                    let isLast = index == container.currentPath.components.count - 1
                    let targetPath = RemotePath(components: Array(container.currentPath.components.prefix(index + 1)))

                    if isLast {
                        Button {
                            Task { await container.navigateTo(targetPath) }
                        } label: {
                            Text(component)
                                .font(.subheadline)
                                .lineLimit(1)
                                .padding(.horizontal, 6)
                                .padding(.vertical, 4)
                        }
                        .buttonStyle(.borderedProminent)
                        .accessibilityLabel("Navigate to \(component)")
                    } else {
                        Button {
                            Task { await container.navigateTo(targetPath) }
                        } label: {
                            Text(component)
                                .font(.subheadline)
                                .lineLimit(1)
                                .padding(.horizontal, 6)
                                .padding(.vertical, 4)
                        }
                        .buttonStyle(.borderless)
                        .accessibilityLabel("Navigate to \(component)")
                    }
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
        }
        .background(Color(uiColor: .secondarySystemBackground))
    }

    private var rootButtonLabel: some View {
        HStack(spacing: 2) {
            Image(systemName: "server.rack")
                .font(.caption2)
            Text("/")
                .font(.subheadline.monospaced())
        }
        .padding(.horizontal, 6)
        .padding(.vertical, 4)
    }
}

// MARK: - Remote File Row View

struct RemoteFileRowView: View {
    let file: RemoteFile

    var body: some View {
        HStack(spacing: 12) {
            fileIcon
                .frame(width: 30, height: 30)

            VStack(alignment: .leading, spacing: 3) {
                HStack {
                    Text(file.name)
                        .font(.body)
                        .foregroundColor(.primary)
                        .lineLimit(1)

                    if file.isSymlink {
                        Image(systemName: "link")
                            .font(.caption2)
                            .foregroundColor(.purple)
                    }
                }

                if let target = file.symlinkTarget {
                    Text("→ \(target)")
                        .font(.caption2.monospaced())
                        .foregroundColor(.purple)
                        .lineLimit(1)
                }

                HStack(spacing: 6) {
                    Text(file.formattedSize)
                    Text("•")
                    Text(file.formattedDate)

                    if let permissions = file.permissions {
                        Text("•")
                        Text(permissions.symbolicString)
                            .font(.caption2.monospaced())
                    }
                }
                .font(.caption)
                .foregroundColor(.secondary)
                .lineLimit(1)
            }

            Spacer()

            if file.isDirectory {
                Image(systemName: "chevron.right")
                    .font(.caption.weight(.bold))
                    .foregroundColor(.secondary.opacity(0.6))
            }
        }
        .padding(.vertical, 3)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(accessibilityDescription)
        .accessibilityAddTraits(.isButton)
        .accessibilityHint(file.isDirectory ? "Double tap to open folder" : (file.isSymlink ? "Double tap to open folder or preview file" : "Double tap to preview file"))
    }

    @ViewBuilder
    private var fileIcon: some View {
        let name = file.iconName
        let color: Color = {
            if file.isDirectory { return .accentColor }
            if file.isSymlink { return .purple }
            let ext = file.path.pathExtension.lowercased()
            switch ext {
            case "png", "jpg", "jpeg", "gif", "webp", "bmp", "svg", "heic", "ico":
                return .green
            case "swift", "py", "sh", "bash", "zsh", "c", "h", "cpp", "hpp":
                return .orange
            case "zip", "gz", "tar", "bz2", "xz", "7z":
                return .yellow
            default:
                return .secondary
            }
        }()

        Image(systemName: name)
            .font(.title3)
            .foregroundColor(color)
    }

    private var accessibilityDescription: String {
        let kind = file.isDirectory ? "Directory" : (file.isSymlink ? "Symlink" : "File")
        let sizeText = file.isDirectory ? "" : ", size \(file.formattedSize)"
        let perms = file.permissions.map { ", permissions \($0.symbolicString)" } ?? ""
        let target = file.symlinkTarget.map { ", pointing to \($0)" } ?? ""
        return "\(kind) \(file.name)\(target)\(sizeText), modified \(file.formattedDate)\(perms)"
    }
}

// MARK: - File Preview Sheet

struct FilePreviewSheet: View {
    var onEdit: ((RemoteFile) -> Void)? = nil
    @EnvironmentObject private var container: AppContainer

    var body: some View {
        NavigationStack {
            Group {
                if container.isPreviewLoading {
                    VStack(spacing: 12) {
                        ProgressView()
                        Text("Loading preview...")
                            .font(.subheadline)
                            .foregroundColor(.secondary)
                    }
                } else if let error = container.previewErrorMessage {
                    ContentUnavailableView(
                        "Preview Unavailable",
                        systemImage: "exclamationmark.triangle",
                        description: Text(error)
                    )
                } else if let file = container.previewFile, let data = container.previewData {
                    previewContent(for: file, data: data)
                } else {
                    ContentUnavailableView(
                        "No Preview Available",
                        systemImage: "doc.questionmark",
                        description: Text("File could not be displayed.")
                    )
                }
            }
            .navigationTitle(container.previewFile?.name ?? "Preview")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Done") {
                        container.closePreview()
                    }
                }
                ToolbarItemGroup(placement: .primaryAction) {
                    if let file = container.previewFile {
                        if !isImageFile(file) {
                            Button("Edit", systemImage: "pencil") {
                                if let onEdit {
                                    onEdit(file)
                                } else {
                                    container.closePreview()
                                    Task {
                                        try? await Task.sleep(nanoseconds: 350_000_000)
                                        do {
                                            try await container.openEditor(for: file)
                                        } catch {
                                            container.editorErrorMessage = error.localizedDescription
                                        }
                                    }
                                }
                            }
                        }

                        Button("Download", systemImage: "arrow.down.circle") {
                            Task {
                                _ = await container.enqueueDownload(file: file)
                            }
                        }

                        if let data = container.previewData, let text = String(data: data, encoding: .utf8) {
                            ShareLink(item: text) {
                                Image(systemName: "square.and.arrow.up")
                            }
                        }
                    }
                }
            }
        }
    }

    @ViewBuilder
    private func previewContent(for file: RemoteFile, data: Data) -> some View {
        if isImageFile(file), let image = UIImage(data: data) {
            ImagePreviewView(image: image, file: file)
        } else if let text = String(data: data, encoding: .utf8) ?? String(data: data, encoding: .ascii) {
            CodePreviewView(text: text, file: file)
        } else {
            BinaryHexPreviewView(data: data, file: file)
        }
    }

    private func isImageFile(_ file: RemoteFile) -> Bool {
        let ext = file.path.pathExtension.lowercased()
        return ["png", "jpg", "jpeg", "gif", "webp", "bmp", "ico"].contains(ext)
    }
}

// MARK: - Code & Monospaced Text Preview

struct CodePreviewView: View {
    let text: String
    let file: RemoteFile

    private var lines: [String] {
        text.components(separatedBy: "\n")
    }

    var body: some View {
        VStack(spacing: 0) {
            metadataBanner
            Divider()

            ScrollView([.horizontal, .vertical]) {
                LazyVStack(alignment: .leading, spacing: 2) {
                    ForEach(Array(lines.enumerated()), id: \.offset) { index, line in
                        HStack(alignment: .top, spacing: 12) {
                            Text("\(index + 1)")
                                .font(.system(.caption2, design: .monospaced))
                                .foregroundColor(.secondary.opacity(0.7))
                                .frame(width: 36, alignment: .trailing)
                                .accessibilityHidden(true)

                            Text(formatSyntaxLine(line))
                                .font(.system(.footnote, design: .monospaced))
                                .textSelection(.enabled)
                        }
                    }
                }
                .padding(12)
            }
        }
    }

    private var metadataBanner: some View {
        HStack {
            Text("\(lines.count) lines")
            Text("•")
            Text(file.formattedSize)
            Text("•")
            Text(file.permissions?.symbolicString ?? "unknown")
            Spacer()
        }
        .font(.caption.monospaced())
        .foregroundColor(.secondary)
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .background(Color(uiColor: .secondarySystemBackground))
    }

    private func formatSyntaxLine(_ line: String) -> AttributedString {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        if trimmed.hasPrefix("//") || trimmed.hasPrefix("#") {
            var commentAttr = AttributedString(line.isEmpty ? " " : line)
            commentAttr.foregroundColor = .gray
            return commentAttr
        }

        let keywords: Set<String> = [
            "func", "import", "let", "var", "class", "struct", "enum", "if", "else",
            "return", "for", "while", "guard", "switch", "case", "break", "public",
            "private", "static", "init", "self", "true", "false", "nil", "async",
            "await", "throws", "try", "def", "echo", "export", "alias", "cd", "ls"
        ]

        var attributed = AttributedString()
        let scanner = Scanner(string: line)
        scanner.charactersToBeSkipped = nil
        let wordSet = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "_"))

        while !scanner.isAtEnd {
            if let word = scanner.scanCharacters(from: wordSet) {
                var wordAttr = AttributedString(word)
                if keywords.contains(word) {
                    wordAttr.foregroundColor = .purple
                    wordAttr.inlinePresentationIntent = .stronglyEmphasized
                } else if Int(word) != nil {
                    wordAttr.foregroundColor = .blue
                }
                attributed.append(wordAttr)
            } else if let other = scanner.scanUpToCharacters(from: wordSet) {
                var otherAttr = AttributedString(other)
                if other.contains("\"") || other.contains("'") {
                    otherAttr.foregroundColor = .orange
                }
                attributed.append(otherAttr)
            }
        }

        return attributed.characters.isEmpty ? AttributedString(" ") : attributed
    }
}

// MARK: - Image Preview View

struct ImagePreviewView: View {
    let image: UIImage
    let file: RemoteFile

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("\(Int(image.size.width)) × \(Int(image.size.height)) px")
                Text("•")
                Text(file.formattedSize)
                Spacer()
            }
            .font(.caption.monospaced())
            .foregroundColor(.secondary)
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            .background(Color(uiColor: .secondarySystemBackground))

            Divider()

            ScrollView([.horizontal, .vertical]) {
                Image(uiImage: image)
                    .resizable()
                    .scaledToFit()
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .padding()
            }
        }
    }
}

// MARK: - Binary Hex Preview View

struct BinaryHexPreviewView: View {
    let data: Data
    let file: RemoteFile

    private var hexDump: String {
        let maxBytes = min(data.count, 512)
        var lines: [String] = []
        for i in stride(from: 0, to: maxBytes, by: 16) {
            let chunk = data.subdata(in: i..<min(i + 16, maxBytes))
            let hex = chunk.map { String(format: "%02x", $0) }.joined(separator: " ")
            let ascii = chunk.map { (32...126).contains($0) ? String(UnicodeScalar($0)) : "." }.joined()
            let paddedHex = hex.padding(toLength: 48, withPad: " ", startingAt: 0)
            lines.append(String(format: "%04x: %@  |%@|", i, paddedHex, ascii))
        }
        if data.count > 512 {
            lines.append("... (\(data.count - 512) more bytes)")
        }
        return lines.joined(separator: "\n")
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("Binary data")
                Text("•")
                Text(file.formattedSize)
                Spacer()
            }
            .font(.caption.monospaced())
            .foregroundColor(.secondary)
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            .background(Color(uiColor: .secondarySystemBackground))

            Divider()

            ScrollView([.horizontal, .vertical]) {
                Text(hexDump)
                    .font(.system(.footnote, design: .monospaced))
                    .padding()
            }
        }
    }
}

// MARK: - In-App Text File Editor Sheet

struct FileEditorSheet: View {
    @EnvironmentObject private var container: AppContainer

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                if let error = container.editorErrorMessage {
                    Text(error)
                        .font(.caption)
                        .foregroundColor(.red)
                        .padding(8)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(Color.red.opacity(0.1))
                }

                TextEditor(text: $container.editingFileContent)
                    .font(.system(.footnote, design: .monospaced))
                    .padding(8)
                    .autocorrectionDisabled()
                    .textInputAutocapitalization(.never)

                Divider()

                HStack {
                    let charCount = container.editingFileContent.count
                    let lineCount = container.editingFileContent.components(separatedBy: "\n").count
                    Text("\(lineCount) lines, \(charCount) characters")
                        .font(.caption2.monospaced())
                        .foregroundColor(.secondary)
                    Spacer()
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 6)
                .background(Color(uiColor: .secondarySystemBackground))
            }
            .navigationTitle(container.activeEditingFile?.name ?? "Edit File")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") {
                        container.closeEditor()
                    }
                    .disabled(container.isSavingFile)
                }
                ToolbarItem(placement: .confirmationAction) {
                    if container.isSavingFile {
                        ProgressView()
                    } else {
                        Button("Save") {
                            Task {
                                do {
                                    try await container.saveEditedFile()
                                    container.closeEditor()
                                } catch {
                                    // Error is populated in container.editorErrorMessage
                                }
                            }
                        }
                        .bold()
                    }
                }
            }
        }
    }
}

// MARK: - Transfer Queue Drawer View

struct TransferQueueDrawerView: View {
    @EnvironmentObject private var container: AppContainer
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            Group {
                if container.transferQueueState.tasks.isEmpty {
                    ContentUnavailableView(
                        "No Transfers",
                        systemImage: "arrow.left.arrow.right",
                        description: Text("Uploaded and downloaded files will appear here.")
                    )
                } else {
                    List {
                        if !container.transferQueueState.activeTasks.isEmpty || !container.transferQueueState.queuedTasks.isEmpty {
                            Section("Active Transfers") {
                                ForEach(container.transferQueueState.activeTasks + container.transferQueueState.queuedTasks) { task in
                                    ActiveTransferRow(task: task)
                                }
                            }
                        }

                        if !container.transferQueueState.completedTasks.isEmpty {
                            Section("Completed") {
                                ForEach(container.transferQueueState.completedTasks) { task in
                                    CompletedTransferRow(task: task)
                                }
                            }
                        }

                        if !container.transferQueueState.failedTasks.isEmpty {
                            Section("Failed") {
                                ForEach(container.transferQueueState.failedTasks) { task in
                                    FailedTransferRow(task: task)
                                }
                            }
                        }

                        if !container.transferQueueState.cancelledTasks.isEmpty {
                            Section("Cancelled") {
                                ForEach(container.transferQueueState.cancelledTasks) { task in
                                    CancelledTransferRow(task: task)
                                }
                            }
                        }
                    }
                    .listStyle(.insetGrouped)
                }
            }
            .navigationTitle("Transfer Queue")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Done") {
                        dismiss()
                    }
                }
                ToolbarItem(placement: .primaryAction) {
                    Button("Clear Finished") {
                        Task { await container.clearCompletedTransfers() }
                    }
                    .disabled(
                        container.transferQueueState.completedTasks.isEmpty &&
                        container.transferQueueState.failedTasks.isEmpty &&
                        container.transferQueueState.cancelledTasks.isEmpty
                    )
                }
            }
        }
    }
}

// MARK: - Transfer Queue Rows

private struct ActiveTransferRow: View {
    let task: TransferTask
    @EnvironmentObject private var container: AppContainer

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Image(systemName: task.direction == .download ? "arrow.down.circle.fill" : "arrow.up.circle.fill")
                    .foregroundColor(.blue)
                    .accessibilityHidden(true)

                Text(task.remotePath.lastComponent)
                    .font(.subheadline.bold())
                    .lineLimit(1)

                Spacer()

                Button {
                    Task { await container.cancelTransfer(id: task.id) }
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundColor(.secondary)
                }
                .buttonStyle(.borderless)
                .accessibilityLabel("Cancel transfer \(task.remotePath.lastComponent)")
            }

            ProgressView(value: task.fractionCompleted)

            HStack {
                Text(task.direction == .download ? "Downloading" : "Uploading")
                Spacer()
                Text("\(ByteCountFormatter.string(fromByteCount: task.bytesTransferred, countStyle: .file)) / \(ByteCountFormatter.string(fromByteCount: task.totalBytes, countStyle: .file)) (\(Int(task.fractionCompleted * 100))%)")
            }
            .font(.caption2.monospaced())
            .foregroundColor(.secondary)
        }
        .padding(.vertical, 4)
    }
}

private struct CompletedTransferRow: View {
    let task: TransferTask

    var body: some View {
        HStack {
            Image(systemName: "checkmark.circle.fill")
                .foregroundColor(.green)
                .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: 2) {
                Text(task.remotePath.lastComponent)
                    .font(.subheadline)
                    .lineLimit(1)
                Text(task.direction == .download ? "Downloaded to device" : "Uploaded to server")
                    .font(.caption2)
                    .foregroundColor(.secondary)
            }

            Spacer()

            Text(ByteCountFormatter.string(fromByteCount: task.totalBytes, countStyle: .file))
                .font(.caption.monospaced())
                .foregroundColor(.secondary)
        }
        .padding(.vertical, 2)
    }
}

private struct FailedTransferRow: View {
    let task: TransferTask
    @EnvironmentObject private var container: AppContainer

    var body: some View {
        HStack {
            Image(systemName: "exclamationmark.circle.fill")
                .foregroundColor(.red)
                .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: 2) {
                Text(task.remotePath.lastComponent)
                    .font(.subheadline)
                    .lineLimit(1)
                Text(task.errorMessage ?? "Transfer failed")
                    .font(.caption2)
                    .foregroundColor(.red)
                    .lineLimit(2)
            }

            Spacer()

            Button("Retry") {
                Task { await container.retryTransfer(id: task.id) }
            }
            .buttonStyle(.bordered)
            .font(.caption)
            .accessibilityLabel("Retry transfer \(task.remotePath.lastComponent)")
        }
        .padding(.vertical, 2)
    }
}

private struct CancelledTransferRow: View {
    let task: TransferTask
    @EnvironmentObject private var container: AppContainer

    var body: some View {
        HStack {
            Image(systemName: "slash.circle.fill")
                .foregroundColor(.orange)
                .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: 2) {
                Text(task.remotePath.lastComponent)
                    .font(.subheadline)
                    .lineLimit(1)
                Text("Transfer cancelled")
                    .font(.caption2)
                    .foregroundColor(.secondary)
            }

            Spacer()

            Button("Retry") {
                Task { await container.retryTransfer(id: task.id) }
            }
            .buttonStyle(.bordered)
            .font(.caption)
            .accessibilityLabel("Retry transfer \(task.remotePath.lastComponent)")
        }
        .padding(.vertical, 2)
    }
}

// MARK: - File Move Picker Sheet

struct FileMovePickerSheet: View {
    let file: RemoteFile
    @EnvironmentObject private var container: AppContainer
    @Environment(\.dismiss) private var dismiss

    @State private var selectedDestination: RemotePath = .root
    @State private var directories: [RemoteFile] = []
    @State private var isLoading = false
    @State private var errorMessage: String? = nil

    var body: some View {
        NavigationStack {
            List {
                Section("Current Destination: \(selectedDestination.description)") {
                    if !selectedDestination.isRoot {
                        Button {
                            navigateToDestination(selectedDestination.parent)
                        } label: {
                            Label(".. (Parent Directory)", systemImage: "arrow.up")
                        }
                    }

                    ForEach(directories.filter {
                        $0.isDirectory && $0.name != file.name && (!file.isDirectory || !$0.path.isDescendantOrEqual(to: file.path))
                    }) { dir in
                        Button {
                            navigateToDestination(dir.path)
                        } label: {
                            Label(dir.name, systemImage: "folder.fill")
                        }
                    }
                }
            }
            .navigationTitle("Move '\(file.name)'")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Move Here") {
                        Task {
                            do {
                                try await container.moveFile(file, to: selectedDestination)
                                dismiss()
                            } catch {
                                errorMessage = error.localizedDescription
                            }
                        }
                    }
                    .bold()
                    .disabled(file.isDirectory && selectedDestination.isDescendantOrEqual(to: file.path))
                }
            }
            .alert("Move Failed", isPresented: Binding(
                get: { errorMessage != nil },
                set: { if !$0 { errorMessage = nil } }
            )) {
                Button("OK", role: .cancel) { errorMessage = nil }
            } message: {
                Text(errorMessage ?? "An unexpected error occurred.")
            }
            .task {
                selectedDestination = file.path.parent
                await loadDirectories(at: selectedDestination)
            }
        }
    }

    private func navigateToDestination(_ path: RemotePath) {
        selectedDestination = path
        Task {
            await loadDirectories(at: path)
        }
    }

    private func loadDirectories(at path: RemotePath) async {
        guard let repo = container.sftpRepository else { return }
        isLoading = true
        do {
            let files = try await repo.listDirectory(at: path)
            directories = files.filter { $0.isDirectory }
            isLoading = false
        } catch {
            isLoading = false
            errorMessage = error.localizedDescription
        }
    }
}
