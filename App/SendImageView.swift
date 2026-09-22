import PhotosUI
import ShhCore
import SwiftUI
import UIKit
import UniformTypeIdentifiers

struct SendImageView: View {
    @EnvironmentObject private var container: AppContainer
    @Environment(\.dismiss) private var dismiss
    @State private var photoItem: PhotosPickerItem?
    @State private var showingFileImporter = false
    @State private var operationTask: Task<Void, Never>?

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    PhotosPicker(selection: $photoItem, matching: .images, photoLibrary: .shared())
                    {
                        Label("Choose from Photos", systemImage: "photo.on.rectangle")
                    }
                    .accessibilityIdentifier("send-image-photos-picker")

                    Button {
                        sendClipboardImage()
                    } label: {
                        Label("Use Clipboard Image", systemImage: "doc.on.clipboard")
                    }
                    .accessibilityIdentifier("send-image-clipboard-button")

                    Button {
                        showingFileImporter = true
                    } label: {
                        Label("Choose from Files", systemImage: "folder")
                    }
                    .accessibilityIdentifier("send-image-files-button")
                } header: {
                    Text("Image source")
                } footer: {
                    Text(
                        "Images are checked locally, uploaded only over this host's SFTP connection, and inserted without pressing Return."
                    )
                }

                statusSection
            }
            .navigationTitle("Send Image")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Done") {
                        cancelIfNeeded()
                        dismiss()
                    }
                }
            }
            .fileImporter(
                isPresented: $showingFileImporter,
                allowedContentTypes: [.image],
                allowsMultipleSelection: false
            ) { result in
                guard case .success(let urls) = result, let url = urls.first else { return }
                loadFile(url)
            }
            .onChange(of: photoItem) { _, item in
                guard let item else { return }
                operationTask?.cancel()
                operationTask = Task {
                    do {
                        guard let data = try await item.loadTransferable(type: Data.self) else {
                            return
                        }
                        guard !Task.isCancelled else { return }
                        await MainActor.run { container.beginSendImage(data: data) }
                    } catch {
                        await MainActor.run {
                            container.sendImageErrorMessage = "Could not read the selected image."
                            container.sendImageState = .failed
                        }
                    }
                }
            }
            .onDisappear {
                cancelIfNeeded()
            }
        }
    }

    @ViewBuilder
    private var statusSection: some View {
        switch container.sendImageState {
        case .idle:
            EmptyView()
        case .preparing:
            Section("Transfer") {
                HStack(spacing: 10) {
                    ProgressView()
                    Text("Preparing image…")
                }
                .accessibilityIdentifier("send-image-preparing")
                Button("Cancel", role: .cancel) { container.cancelSendImage() }
            }
        case .transferring(let progress):
            Section("Transfer") {
                ProgressView(value: progress.fractionCompleted) {
                    Text("Uploading image")
                } currentValueLabel: {
                    Text("\(Int(progress.fractionCompleted * 100))%")
                }
                Button("Cancel", role: .cancel) { container.cancelSendImage() }
                    .accessibilityIdentifier("send-image-cancel-button")
            }
        case .completed:
            Section("Transfer") {
                Label("Image inserted into the terminal", systemImage: "checkmark.circle.fill")
                    .foregroundStyle(.green)
                    .accessibilityIdentifier("send-image-completed")
                Text("The path is ready for you to review. Return has not been sent.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        case .cancelled:
            Section("Transfer") {
                Label("Transfer cancelled", systemImage: "xmark.circle")
                    .foregroundStyle(.secondary)
            }
        case .failed:
            Section("Transfer") {
                Label(
                    container.sendImageErrorMessage ?? "Image upload failed.",
                    systemImage: "exclamationmark.triangle"
                )
                .foregroundStyle(.orange)
                Button("Try Again", role: .cancel) {
                    container.sendImageState = .idle
                    container.sendImageErrorMessage = nil
                }
            }
        }
    }

    private func sendClipboardImage() {
        let pasteboard = UIPasteboard.general
        let imageTypes = pasteboard.types.filter { UTType($0)?.conforms(to: .image) == true }
        guard
            let data = imageTypes.lazy.compactMap({ pasteboard.data(forPasteboardType: $0) }).first
        else {
            container.sendImageErrorMessage = "No image is available on the clipboard."
            container.sendImageState = .failed
            return
        }
        container.beginSendImage(data: data)
    }

    private func loadFile(_ url: URL) {
        let accessed = url.startAccessingSecurityScopedResource()
        defer {
            if accessed { url.stopAccessingSecurityScopedResource() }
        }
        do {
            let values = try url.resourceValues(forKeys: [.fileSizeKey])
            if let fileSize = values.fileSize, fileSize > SendImageLimits().maximumBytes {
                container.sendImageErrorMessage = SendImageError.imageTooLarge.localizedDescription
                container.sendImageState = .failed
                return
            }
            let data = try Data(contentsOf: url)
            container.beginSendImage(data: data)
        } catch {
            container.sendImageErrorMessage = "Could not read the selected image."
            container.sendImageState = .failed
        }
    }

    private func cancelIfNeeded() {
        operationTask?.cancel()
        operationTask = nil
        if container.sendImageState.isActive {
            container.cancelSendImage()
        }
    }
}
