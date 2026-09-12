import SwiftUI
import UniformTypeIdentifiers
import ShhCore

/// Settings view providing zero-knowledge encrypted vault backup export, import, preview, and restore.
struct VaultBackupView: View {
    @EnvironmentObject private var container: AppContainer

    private enum ImportStep {
        case passphrase
        case preview(VaultPayload)
    }

    // MARK: - Export State
    @State private var exportPassphrase = ""
    @State private var exportConfirmPassphrase = ""
    @State private var exportErrorMessage: String? = nil
    @State private var exportSuccessMessage: String? = nil
    @State private var isExporting = false
    @State private var exportedFileURL: URL? = nil

    // MARK: - Import State
    @State private var showFileImporter = false
    @State private var stagedImportURL: URL? = nil
    @State private var stagedImportData: Data? = nil
    @State private var showImportModal = false
    @State private var importStep: ImportStep = .passphrase
    @State private var importPassphrase = ""
    @State private var importErrorMessage: String? = nil
    @State private var isDecrypting = false
    @State private var previewPayload: VaultPayload? = nil
    @State private var showReplaceConfirmation = false
    @State private var importSuccessMessage: String? = nil

    var body: some View {
        Form {
            // Security notice
            Section {
                VStack(alignment: .leading, spacing: 6) {
                    Label("Zero-Knowledge Vault Backup", systemImage: "lock.shield.fill")
                        .font(.headline)
                        .foregroundStyle(.tint)
                    Text("Backups are encrypted using AES-256-GCM and PBKDF2-HMAC-SHA256 (600,000 iterations). Private keys, passwords, and Keychain credential secrets are never included in backups. Only you hold the decryption key.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            } header: {
                Text("Security Guarantee")
            }

            // Status banners
            if let error = exportErrorMessage ?? importErrorMessage {
                Section {
                    VStack(alignment: .leading, spacing: 4) {
                        Label("Operation Error", systemImage: "exclamationmark.triangle.fill")
                            .foregroundStyle(.red)
                            .font(.headline)
                        Text(error)
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    }
                    .accessibilityIdentifier("vault-backup-error-banner")
                }
            }

            if let success = exportSuccessMessage ?? importSuccessMessage {
                Section {
                    Label(success, systemImage: "checkmark.circle.fill")
                        .foregroundStyle(.green)
                        .font(.subheadline)
                        .accessibilityIdentifier("vault-backup-success-banner")
                }
            }

            // Export section
            Section {
                SecureField("Passphrase", text: $exportPassphrase)
                    .accessibilityIdentifier("vault-export-passphrase-field")
                SecureField("Confirm Passphrase", text: $exportConfirmPassphrase)
                    .accessibilityIdentifier("vault-export-confirm-field")

                Button {
                    performExport()
                } label: {
                    HStack {
                        Label("Export Encrypted Backup", systemImage: "square.and.arrow.up")
                        if isExporting {
                            Spacer()
                            ProgressView()
                        }
                    }
                }
                .disabled(exportPassphrase.isEmpty || exportConfirmPassphrase.isEmpty || isExporting)
                .accessibilityIdentifier("vault-export-button")

                if let exportedFileURL {
                    ShareLink(item: exportedFileURL) {
                        Label("Share Exported .shhbackup", systemImage: "square.and.arrow.up.fill")
                    }
                    .accessibilityIdentifier("vault-export-share-link")
                }
            } header: {
                Text("Export Backup (.shhbackup)")
            } footer: {
                Text("Choose a strong passphrase. There is no password recovery or backdoor.")
            }

            // Import section
            Section {
                Button {
                    showFileImporter = true
                } label: {
                    Label("Choose .shhbackup File...", systemImage: "folder")
                }
                .accessibilityIdentifier("vault-import-choose-file-button")
            } header: {
                Text("Restore Backup")
            } footer: {
                Text("Restoring allows you to preview the backup schema and record counts before choosing whether to merge or replace existing records.")
            }
        }
        .navigationTitle("Vault Backup & Sync")
        .fileImporter(
            isPresented: $showFileImporter,
            allowedContentTypes: [
                UTType(filenameExtension: "shhbackup") ?? .data,
                UTType.data,
                UTType.json
            ],
            allowsMultipleSelection: false
        ) { result in
            handleFileImport(result: result)
        }
        .sheet(isPresented: $showImportModal, onDismiss: {
            clearImportState()
        }) {
            importModalSheet
        }
        .onDisappear {
            clearExportedFile()
            clearImportState()
        }
    }

    // MARK: - Export Logic

    private func performExport() {
        exportErrorMessage = nil
        exportSuccessMessage = nil
        clearExportedFile()

        let pass = exportPassphrase
        let confirm = exportConfirmPassphrase

        guard !pass.isEmpty else {
            exportErrorMessage = "Passphrase cannot be empty."
            return
        }

        guard pass == confirm else {
            exportErrorMessage = "Passphrases do not match. Please re-enter."
            return
        }

        isExporting = true

        Task {
            defer {
                // Deterministic passphrase clearing
                self.exportPassphrase = ""
                self.exportConfirmPassphrase = ""
                self.isExporting = false
            }

            do {
                let data = try await container.exportVaultBackup(passphrase: pass)
                let formatter = DateFormatter()
                formatter.dateFormat = "yyyy-MM-dd-HHmmss"
                let dateStr = formatter.string(from: Date())
                let fileName = "ShhVault-\(dateStr).shhbackup"
                let tempURL = FileManager.default.temporaryDirectory.appendingPathComponent(fileName)

                try data.write(to: tempURL, options: .atomic)
                self.exportedFileURL = tempURL
                self.exportSuccessMessage = "Encrypted backup created successfully (\(data.count) bytes)."
            } catch {
                self.exportErrorMessage = error.localizedDescription
            }
        }
    }

    private func clearExportedFile() {
        if let url = exportedFileURL {
            try? FileManager.default.removeItem(at: url)
            exportedFileURL = nil
        }
    }

    // MARK: - Import Logic

    private func handleFileImport(result: Result<[URL], Error>) {
        importErrorMessage = nil
        importSuccessMessage = nil

        switch result {
        case .success(let urls):
            guard let selectedURL = urls.first else { return }

            let hasAccess = selectedURL.startAccessingSecurityScopedResource()
            defer {
                if hasAccess {
                    selectedURL.stopAccessingSecurityScopedResource()
                }
            }

            let stagingDir = FileManager.default.temporaryDirectory.appendingPathComponent("VaultImportStaging", isDirectory: true)
            try? FileManager.default.createDirectory(at: stagingDir, withIntermediateDirectories: true)
            let stagedFile = stagingDir.appendingPathComponent(UUID().uuidString + ".shhbackup")

            do {
                if FileManager.default.fileExists(atPath: stagedFile.path) {
                    try FileManager.default.removeItem(at: stagedFile)
                }
                try FileManager.default.copyItem(at: selectedURL, to: stagedFile)
                let data = try Data(contentsOf: stagedFile)
                self.stagedImportURL = stagedFile
                self.stagedImportData = data
                self.importPassphrase = ""
                self.importErrorMessage = nil
                self.importStep = .passphrase
                self.showImportModal = true
            } catch {
                self.importErrorMessage = "Failed to stage import file: \(error.localizedDescription)"
                clearImportState()
            }

        case .failure(let error):
            self.importErrorMessage = "Failed to select file: \(error.localizedDescription)"
            clearImportState()
        }
    }

    private func decryptAndPreview() {
        guard let data = stagedImportData else {
            importErrorMessage = "Staged backup file data is missing."
            showImportModal = false
            return
        }

        let pass = importPassphrase
        guard !pass.isEmpty else {
            importErrorMessage = "Passphrase cannot be empty."
            return
        }

        isDecrypting = true
        importErrorMessage = nil

        Task {
            defer {
                // Deterministic passphrase clearing
                self.importPassphrase = ""
                self.isDecrypting = false
            }

            do {
                let payload = try container.previewVaultBackup(data: data, passphrase: pass)
                self.previewPayload = payload
                self.importStep = .preview(payload)
            } catch let vaultErr as VaultBackupError {
                self.importErrorMessage = vaultErr.errorDescription
            } catch {
                self.importErrorMessage = "Decryption failed: \(error.localizedDescription)"
            }
        }
    }

    private func performRestore(mode: RestoreMode) {
        guard let payload = previewPayload else { return }

        Task {
            do {
                try await container.restoreCatalog(from: payload.catalog, mode: mode)
                let modeName = mode == .merge ? "merged" : "replaced"
                self.importSuccessMessage = "Successfully \(modeName) catalog (\(payload.catalog.hosts.count) hosts restored)."
                self.showImportModal = false
                clearImportState()
            } catch {
                self.importErrorMessage = "Failed to restore catalog: \(error.localizedDescription)"
            }
        }
    }

    private func clearImportState() {
        if let url = stagedImportURL {
            try? FileManager.default.removeItem(at: url)
        }
        stagedImportURL = nil
        stagedImportData = nil
        importPassphrase = ""
        previewPayload = nil
    }

    // MARK: - Import Modal Sheet

    private var importModalSheet: some View {
        NavigationStack {
            switch importStep {
            case .passphrase:
                passphrasePromptSheet
            case .preview(let payload):
                backupPreviewSheet(payload: payload)
            }
        }
        .editorSheetPresentation()
    }

    // MARK: - Passphrase Prompt Sheet

    private var passphrasePromptSheet: some View {
        Form {
            Section {
                Text("Enter the passphrase used to encrypt this backup file.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                SecureField("Backup Passphrase", text: $importPassphrase)
                    .accessibilityIdentifier("vault-import-passphrase-field")
            } header: {
                Text("Enter Passphrase")
            }

            if let err = importErrorMessage {
                Section {
                    Text(err)
                        .font(.caption)
                        .foregroundStyle(.red)
                        .accessibilityIdentifier("vault-import-decrypt-error")
                }
            }

            Section {
                Button {
                    decryptAndPreview()
                } label: {
                    HStack {
                        Text("Decrypt & Preview")
                        if isDecrypting {
                            Spacer()
                            ProgressView()
                        }
                    }
                }
                .disabled(importPassphrase.isEmpty || isDecrypting)
                .accessibilityIdentifier("vault-import-decrypt-button")
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .navigationTitle("Decrypt Backup")
        .toolbar {
            ToolbarItem(placement: .cancellationAction) {
                Button("Cancel") {
                    showImportModal = false
                    clearImportState()
                }
            }
        }
    }

    // MARK: - Preview Sheet

    private func backupPreviewSheet(payload: VaultPayload) -> some View {
        Form {
            Section {
                LabeledContent("Schema Version", value: "v\(payload.catalog.metadata.schemaVersion)")
                LabeledContent("Exported Date", value: formattedDate(payload.exportedAt))
            } header: {
                Text("Backup Envelope")
            }

            Section {
                LabeledContent("Hosts", value: "\(payload.catalog.hosts.count)")
                LabeledContent("Identities", value: "\(payload.catalog.identities.count)")
                LabeledContent("Snippets", value: "\(payload.catalog.snippets.count)")
                LabeledContent("Groups", value: "\(payload.catalog.groups.count)")
                LabeledContent("Tags", value: "\(payload.catalog.tags.count)")
            } header: {
                Text("Catalog Contents")
            }

            Section {
                Button {
                    performRestore(mode: .merge)
                } label: {
                    Label("Merge into Existing Catalog", systemImage: "arrow.triangle.merge")
                }
                .accessibilityIdentifier("vault-restore-merge-button")

                Button(role: .destructive) {
                    showReplaceConfirmation = true
                } label: {
                    Label("Replace Entire Catalog", systemImage: "exclamationmark.arrow.triangle.2.circlepath")
                }
                .accessibilityIdentifier("vault-restore-replace-button")
            } header: {
                Text("Restore Options")
            } footer: {
                Text("• Merge adds new records and updates matching records while preserving other existing items.\n• Replace completely overwrites your existing catalog with the backup.")
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .navigationTitle("Backup Preview")
        .toolbar {
            ToolbarItem(placement: .cancellationAction) {
                Button("Cancel") {
                    showImportModal = false
                    clearImportState()
                }
            }
        }
        .alert("Confirm Catalog Replacement", isPresented: $showReplaceConfirmation) {
            Button("Replace Entire Catalog", role: .destructive) {
                performRestore(mode: .replace)
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This action is destructive and will replace all current hosts, identities, groups, tags, and snippets with the contents of this backup.")
        }
    }

    private func formattedDate(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .short
        return formatter.string(from: date)
    }
}
