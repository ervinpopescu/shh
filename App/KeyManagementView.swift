import ShhCore
import ShhSSH
import SwiftUI
#if canImport(UIKit)
import UIKit
#endif

// MARK: - Badge View

struct IdentityKindBadge: View {
    let kind: IdentityKind

    var body: some View {
        Text(title)
            .font(.caption2.bold())
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(background)
            .foregroundStyle(foreground)
            .clipShape(Capsule())
            .accessibilityIdentifier("identity-kind-badge-\(kind.rawValue)")
    }

    private var title: String {
        switch kind {
        case .privateKey: return "Ed25519 Key"
        case .password: return "Password"
        case .agent: return "Agent"
        }
    }

    private var background: Color {
        switch kind {
        case .privateKey: return Color.purple.opacity(0.15)
        case .password: return Color.orange.opacity(0.15)
        case .agent: return Color.blue.opacity(0.15)
        }
    }

    private var foreground: Color {
        switch kind {
        case .privateKey: return .purple
        case .password: return .orange
        case .agent: return .blue
        }
    }
}

// MARK: - Key Management View

struct KeyManagementView: View {
    @EnvironmentObject private var container: AppContainer
    @State private var identities: [IdentityDescriptor] = []
    @State private var showingEditor = false
    @State private var search = ""
    @State private var errorMessage: String?

    init() {
        if ProcessInfo.processInfo.arguments.contains("--new-key") {
            _showingEditor = State(initialValue: true)
        }
    }

    private var filtered: [IdentityDescriptor] {
        if search.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return identities
        }
        return identities.filter {
            $0.name.localizedCaseInsensitiveContains(search) ||
            ($0.publicFingerprint?.localizedCaseInsensitiveContains(search) ?? false)
        }
    }

    var body: some View {
        List {
            if identities.isEmpty {
                Section {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("No SSH keys or credentials saved.")
                            .font(AppTypography.rowTitle)
                        Text("Generate or import an Ed25519 private key or save a password credential to authenticate with your remote hosts.")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                        Button {
                            showingEditor = true
                        } label: {
                            Label("Add Identity", systemImage: "plus")
                        }
                        .buttonStyle(.borderedProminent)
                        .padding(.top, 4)
                    }
                    .padding(.vertical, 8)
                }
            } else {
                Section("Identities") {
                    ForEach(filtered) { identity in
                        NavigationLink(destination: IdentityDetailView(identity: identity)) {
                            IdentityRow(identity: identity)
                        }
                        .accessibilityIdentifier("identity-link-\(identity.id)")
                    }
                    .onDelete(perform: deleteIdentities)
                }
            }
        }
        .navigationTitle("Keys & Credentials")
        .navigationBarTitleDisplayMode(.inline)
        .searchable(text: $search, prompt: "Search keys and fingerprints")
        .autocorrectionDisabled()
        .textInputAutocapitalization(.never)
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button {
                    showingEditor = true
                } label: {
                    Label("Add", systemImage: "plus")
                }
                .accessibilityIdentifier("add-identity-button")
            }
        }
        .sheet(isPresented: $showingEditor, onDismiss: {
            Task { await reload() }
        }) {
            IdentityEditorView()
                .environmentObject(container)
        }
        .task {
            await reload()
        }
        .refreshable {
            await reload()
        }
        .alert("Error", isPresented: Binding(get: { errorMessage != nil }, set: { if !$0 { errorMessage = nil } })) {
            Button("OK", role: .cancel) { errorMessage = nil }
        } message: {
            if let err = errorMessage {
                Text(err)
            }
        }
    }

    private func reload() async {
        identities = (try? await container.catalog.identities()) ?? []
    }

    private func deleteIdentities(at offsets: IndexSet) {
        let targets = offsets.map { filtered[$0].id }
        Task {
            for id in targets {
                do {
                    try await container.deleteIdentity(id: id)
                } catch {
                    errorMessage = error.localizedDescription
                }
            }
            await reload()
        }
    }
}

// MARK: - Identity Row

struct IdentityRow: View {
    let identity: IdentityDescriptor

    var body: some View {
        HStack(alignment: .center, spacing: 12) {
            Image(systemName: identity.kind == .privateKey ? "key.fill" : "lock.fill")
                .font(.title3)
                .foregroundStyle(identity.kind == .privateKey ? .purple : .orange)
                .frame(width: 28)

            VStack(alignment: .leading, spacing: 3) {
                HStack {
                    Text(identity.name)
                        .font(AppTypography.rowTitle)
                    IdentityKindBadge(kind: identity.kind)
                }

                if let fp = identity.publicFingerprint {
                    Text(fp)
                        .font(.caption.monospaced())
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                } else {
                    Text("Password credential")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Text("Created \(identity.createdAt.formatted(date: .abbreviated, time: .omitted))")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }
        }
        .padding(.vertical, 2)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(identity.name), \(identity.kind == .privateKey ? "Ed25519 Key" : "Password")")
    }
}

// MARK: - Identity Detail View

struct IdentityDetailView: View {
    @EnvironmentObject private var container: AppContainer
    @Environment(\.dismiss) private var dismiss
    let identity: IdentityDescriptor

    @State private var publicKeyText: String = ""
    @State private var isLoadingKey: Bool = false
    @State private var didCopy: Bool = false
    @State private var showingDeleteConfirm = false
    @State private var errorMessage: String?

    var body: some View {
        Form {
            Section("Identity Details") {
                LabeledContent("Name", value: identity.name)
                LabeledContent("Type") {
                    IdentityKindBadge(kind: identity.kind)
                }
                LabeledContent("Created", value: identity.createdAt.formatted(date: .abbreviated, time: .shortened))
                if let fp = identity.publicFingerprint {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Fingerprint")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        Text(fp)
                            .font(.subheadline.monospaced())
                            .textSelection(.enabled)
                    }
                    .padding(.vertical, 2)
                }
            }

            if identity.kind == .privateKey {
                Section("Public Key") {
                    if isLoadingKey {
                        HStack {
                            ProgressView()
                            Text("Loading public key...")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    } else if !publicKeyText.isEmpty {
                        VStack(alignment: .leading, spacing: 8) {
                            Text(publicKeyText)
                                .font(.caption.monospaced())
                                .textSelection(.enabled)
                                .padding(8)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .background(Color(.secondarySystemBackground))
                                .clipShape(RoundedRectangle(cornerRadius: 6))
                                .accessibilityIdentifier("identity-public-key-text")

                            Button {
                                copyPublicKey()
                            } label: {
                                HStack {
                                    Image(systemName: didCopy ? "checkmark" : "doc.on.doc")
                                    Text(didCopy ? "Copied Public Key!" : "Copy Public Key")
                                }
                                .frame(maxWidth: .infinity)
                            }
                            .buttonStyle(.borderedProminent)
                            .accessibilityIdentifier("copy-public-key-button")
                        }
                    } else {
                        Text("Unable to load public key from Keychain.")
                            .font(.caption)
                            .foregroundStyle(.red)
                    }
                }
            }

            Section {
                Button(role: .destructive) {
                    showingDeleteConfirm = true
                } label: {
                    Label("Delete Identity", systemImage: "trash")
                        .foregroundStyle(.red)
                }
                .accessibilityIdentifier("delete-identity-button")
            }
        }
        .navigationTitle(identity.name)
        .navigationBarTitleDisplayMode(.inline)
        .task {
            await loadPublicKey()
        }
        .confirmationDialog(
            "Delete Identity?",
            isPresented: $showingDeleteConfirm,
            titleVisibility: .visible
        ) {
            Button("Delete", role: .destructive) {
                Task {
                    do {
                        try await container.deleteIdentity(id: identity.id)
                        dismiss()
                    } catch {
                        errorMessage = error.localizedDescription
                    }
                }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Are you sure you want to delete '\(identity.name)'? Hosts using this credential will no longer have an associated identity.")
        }
        .alert("Error", isPresented: Binding(get: { errorMessage != nil }, set: { if !$0 { errorMessage = nil } })) {
            Button("OK", role: .cancel) { errorMessage = nil }
        } message: {
            if let err = errorMessage {
                Text(err)
            }
        }
    }

    private func loadPublicKey() async {
        guard identity.kind == .privateKey else { return }
        isLoadingKey = true
        defer { isLoadingKey = false }
        do {
            if let pubKey = try await container.openSSHPublicKey(for: identity) {
                publicKeyText = pubKey
            }
        } catch {
            // Keep inline warning in the view without presenting a blocking modal alert.
        }
    }

    private func copyPublicKey() {
        #if canImport(UIKit)
        UIPasteboard.general.string = publicKeyText
        #endif
        withAnimation {
            didCopy = true
        }
        Task {
            try? await Task.sleep(nanoseconds: 2_000_000_000)
            withAnimation {
                didCopy = false
            }
        }
    }
}

// MARK: - Identity Editor View

enum IdentityEditorMode: String, CaseIterable, Identifiable {
    case generate = "Generate Key"
    case importKey = "Import Key"
    case password = "Password"

    var id: String { rawValue }
}

struct IdentityEditorView: View {
    @EnvironmentObject private var container: AppContainer
    @Environment(\.dismiss) private var dismiss

    var onCreated: ((IdentityDescriptor) -> Void)? = nil

    private enum Field: Hashable {
        case name
        case comment
        case privateKey
        case password
    }

    @FocusState private var focusedField: Field?
    @State private var mode: IdentityEditorMode = .generate

    init(onCreated: ((IdentityDescriptor) -> Void)? = nil) {
        self.onCreated = onCreated
        if ProcessInfo.processInfo.arguments.contains("--import-key") {
            _mode = State(initialValue: .importKey)
        }
    }

    // Common
    @State private var name: String = ""

    // Generate
    @State private var comment: String = ""
    @State private var generatedPublicKey: String? = nil
    @State private var newlyCreatedIdentity: IdentityDescriptor? = nil
    @State private var didCopyGenerated: Bool = false

    // Import
    @State private var privateKeyText: String = ""

    // Password
    @State private var password: String = ""

    // Error & Loading
    @State private var isProcessing: Bool = false
    @State private var errorMessage: String? = nil

    var body: some View {
        NavigationStack {
            Form {
                if generatedPublicKey == nil {
                    Picker("Mode", selection: $mode) {
                        ForEach(IdentityEditorMode.allCases) { m in
                            Text(m.rawValue).tag(m)
                        }
                    }
                    .pickerStyle(.segmented)
                    .accessibilityIdentifier("identity-editor-mode-picker")

                    Section("Identity Info") {
                        TextField("Name", text: $name)
                            .focused($focusedField, equals: .name)
                            .autocorrectionDisabled()
                            .textInputAutocapitalization(.never)
                            .accessibilityIdentifier("identity-name-field")
                    }

                    switch mode {
                    case .generate:
                        generateSection
                    case .importKey:
                        importSection
                    case .password:
                        passwordSection
                    }
                } else {
                    generatedResultSection
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .navigationTitle(generatedPublicKey == nil ? "New Identity" : "Key Generated")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(generatedPublicKey == nil ? "Cancel" : "Done") {
                        dismiss()
                    }
                    .accessibilityIdentifier("identity-editor-dismiss-button")
                }
                if focusedField != nil {
                    ToolbarItem(placement: .topBarTrailing) {
                        Button("Done") {
                            focusedField = nil
                        }
                        .accessibilityLabel("Dismiss keyboard")
                        .accessibilityIdentifier("identity-editor-done-keyboard-button")
                    }
                }
                ToolbarItemGroup(placement: .keyboard) {
                    Spacer()
                    Button {
                        focusedField = nil
                    } label: {
                        Label("Dismiss Keyboard", systemImage: "keyboard.chevron.compact.down")
                    }
                    .accessibilityLabel("Dismiss keyboard")
                    .accessibilityIdentifier("identity-editor-dismiss-keyboard-button")
                }
            }
            .alert("Error", isPresented: Binding(get: { errorMessage != nil }, set: { if !$0 { errorMessage = nil } })) {
                Button("OK", role: .cancel) { errorMessage = nil }
            } message: {
                if let err = errorMessage {
                    Text(err)
                }
            }
        }
        .editorSheetPresentation()
    }

    // MARK: - Generate Mode

    private var generateSection: some View {
        Group {
            Section("Key Options") {
                TextField("Comment (optional, e.g. dev@ipad)", text: $comment)
                    .focused($focusedField, equals: .comment)
                    .autocorrectionDisabled()
                    .textInputAutocapitalization(.never)
                    .accessibilityIdentifier("identity-comment-field")
                Text("Generates a new Curve25519 / Ed25519 SSH private key and saves it securely into the Keychain.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section {
                Button {
                    generateEd25519Key()
                } label: {
                    if isProcessing {
                        ProgressView()
                    } else {
                        HStack {
                            Image(systemName: "key.fill")
                            Text("Generate Ed25519 Key")
                        }
                    }
                }
                .disabled(name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || isProcessing)
                .accessibilityIdentifier("generate-key-button")
            }
        }
    }

    // MARK: - Import Mode

    private var importSection: some View {
        Group {
            Section("Private Key Material") {
                TextEditor(text: $privateKeyText)
                    .focused($focusedField, equals: .privateKey)
                    .font(.caption.monospaced())
                    .frame(height: 180)
                    .autocorrectionDisabled()
                    .textInputAutocapitalization(.never)
                    .accessibilityIdentifier("identity-private-key-field")
                Text("Paste an OpenSSH (-----BEGIN OPENSSH PRIVATE KEY-----) or PEM (-----BEGIN PRIVATE KEY-----) formatted Ed25519 private key.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section {
                Button {
                    importPrivateKey()
                } label: {
                    if isProcessing {
                        ProgressView()
                    } else {
                        HStack {
                            Image(systemName: "square.and.arrow.down")
                            Text("Import Private Key")
                        }
                    }
                }
                .disabled(
                    name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ||
                    privateKeyText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ||
                    isProcessing
                )
                .accessibilityIdentifier("import-key-button")
            }
        }
    }

    // MARK: - Password Mode

    private var passwordSection: some View {
        Group {
            Section("Password") {
                SecureField("Password", text: $password)
                    .focused($focusedField, equals: .password)
                    .autocorrectionDisabled()
                    .textInputAutocapitalization(.never)
                    .accessibilityIdentifier("identity-password-field")
                Text("Passwords are saved securely into Keychain and never transmitted in logs.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section {
                Button {
                    savePassword()
                } label: {
                    if isProcessing {
                        ProgressView()
                    } else {
                        HStack {
                            Image(systemName: "lock.fill")
                            Text("Save Password")
                        }
                    }
                }
                .disabled(
                    name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ||
                    password.isEmpty ||
                    isProcessing
                )
                .accessibilityIdentifier("save-password-button")
            }
        }
    }

    // MARK: - Generated Result View

    private var generatedResultSection: some View {
        Section("Public Key") {
            VStack(alignment: .leading, spacing: 10) {
                Text("Your new Ed25519 key was generated and stored securely.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)

                if let pubKey = generatedPublicKey {
                    Text(pubKey)
                        .font(.caption.monospaced())
                        .textSelection(.enabled)
                        .padding(8)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(Color(.secondarySystemBackground))
                        .clipShape(RoundedRectangle(cornerRadius: 6))
                        .accessibilityIdentifier("generated-public-key-text")

                    Button {
                        copyGeneratedKey()
                    } label: {
                        HStack {
                            Image(systemName: didCopyGenerated ? "checkmark" : "doc.on.doc")
                            Text(didCopyGenerated ? "Copied Public Key!" : "Copy Public Key")
                        }
                        .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.borderedProminent)
                    .accessibilityIdentifier("copy-generated-public-key-button")
                }

                Text("Add this public key to the remote host's ~/.ssh/authorized_keys file.")
                    .font(.caption2)
                    .foregroundStyle(.secondary)

                Button("Done") {
                    dismiss()
                }
                .frame(maxWidth: .infinity)
                .padding(.top, 4)
                .accessibilityIdentifier("generated-done-button")
            }
            .padding(.vertical, 4)
        }
    }

    // MARK: - Actions

    private func generateEd25519Key() {
        isProcessing = true
        Task {
            defer { isProcessing = false }
            do {
                let trimmedName = name.trimmingCharacters(in: .whitespacesAndNewlines)
                let trimmedComment = comment.trimmingCharacters(in: .whitespacesAndNewlines)
                let effectiveComment = trimmedComment.isEmpty ? nil : trimmedComment
                let keyComment = effectiveComment ?? trimmedName
                let generated = Ed25519Parser.generateKeyPair(comment: keyComment)
                let identity = try await container.createEd25519Identity(
                    name: name,
                    comment: effectiveComment,
                    keyPair: generated
                )
                newlyCreatedIdentity = identity
                generatedPublicKey = generated.openSSHPublicKey
                onCreated?(identity)
            } catch {
                errorMessage = error.localizedDescription
            }
        }
    }

    private func importPrivateKey() {
        isProcessing = true
        Task {
            defer { isProcessing = false }
            do {
                let identity = try await container.importPrivateKeyIdentity(
                    name: name,
                    privateKeyText: privateKeyText
                )
                onCreated?(identity)
                dismiss()
            } catch {
                errorMessage = error.localizedDescription
            }
        }
    }

    private func savePassword() {
        isProcessing = true
        Task {
            defer { isProcessing = false }
            do {
                let identity = try await container.createPasswordIdentity(
                    name: name,
                    password: password
                )
                onCreated?(identity)
                dismiss()
            } catch {
                errorMessage = error.localizedDescription
            }
        }
    }

    private func copyGeneratedKey() {
        guard let pubKey = generatedPublicKey else { return }
        #if canImport(UIKit)
        UIPasteboard.general.string = pubKey
        #endif
        withAnimation {
            didCopyGenerated = true
        }
        Task {
            try? await Task.sleep(nanoseconds: 2_000_000_000)
            withAnimation {
                didCopyGenerated = false
            }
        }
    }
}
