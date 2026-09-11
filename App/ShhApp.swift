import ShhCore
import SwiftUI

@main
struct ShhApp: App {
    @StateObject private var container: AppContainer

    init() {
        if ProcessInfo.processInfo.arguments.contains("--demo") ||
            ProcessInfo.processInfo.environment["SHH_DEMO_MODE"] == "1" {
            _container = StateObject(wrappedValue: AppContainer.demo())
        } else {
            _container = StateObject(wrappedValue: AppContainer())
        }
    }

    var body: some Scene {
        WindowGroup { RootView().environmentObject(container) }
    }
}

extension View {
    @ViewBuilder func tagChip() -> some View { self.font(.caption2).padding(.horizontal, 5).padding(.vertical, 2).background(Color.accentColor.opacity(0.15), in: Capsule()) }
}

enum AppSection: String, CaseIterable, Identifiable {
    case hosts = "Hosts", sessions = "Sessions", files = "Files", snippets = "Snippets", monitoring = "Monitoring", settings = "Settings"
    var id: String { rawValue }
    var systemImage: String {
        switch self { case .hosts: "server.rack"; case .sessions: "rectangle.split.2x1"; case .files: "folder"; case .snippets: "text.badge.plus"; case .monitoring: "waveform.path.ecg"; case .settings: "gear" }
    }
}

struct RootView: View {
    @EnvironmentObject private var container: AppContainer
    @State private var section: AppSection? = .hosts
    var body: some View {
        NavigationSplitView {
            List(AppSection.allCases, selection: $section) { item in
                Label(item.rawValue, systemImage: item.systemImage).tag(item as AppSection?)
            }
            .navigationTitle("Shh")
            .safeAreaInset(edge: .bottom) { capabilityFooter }
        } detail: {
            switch section ?? .hosts {
            case .hosts: HostListView()
            case .sessions: SessionDashboardView()
            case .files: FilesView()
            case .snippets: SnippetsView()
            case .monitoring: MonitoringView()
            case .settings: SettingsView()
            }
        }
    }
    private var capabilityFooter: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(container.isDemo ? "Offline demo mode" : "Live SSH mode").font(.caption.bold())
            Text(container.isDemo ? "SSH, SFTP, Mosh and Whisper adapters are replaceable capabilities." : "Live SSH transport active. SFTP, Mosh, and Whisper are not enabled in this build.").font(.caption2).foregroundStyle(.secondary)
        }.padding().frame(maxWidth: .infinity, alignment: .leading).background(.thinMaterial)
    }
}

struct HostListView: View {
    @EnvironmentObject private var container: AppContainer
    @State private var hosts: [Host] = []
    @State private var search = ""
    @State private var showingEditor = false
    @State private var healthyOnly = false
    private var filtered: [Host] { hosts.filter { (search.isEmpty || $0.name.localizedCaseInsensitiveContains(search) || $0.address.localizedCaseInsensitiveContains(search)) && (!healthyOnly || $0.health == .healthy) } }
    var body: some View {
        List {
            Section("Saved hosts") {
                ForEach(filtered) { host in
                    NavigationLink(destination: HostDetailView(host: host)) { HostRow(host: host) }
                }
                .onDelete { offsets in
                    let ids = offsets.map { filtered[$0].id }
                    Task {
                        for id in ids { try? await container.catalog.delete(id: id) }
                        await reload()
                    }
                }
            }
        }
        .navigationTitle("Hosts")
        .searchable(text: $search, prompt: "Search hosts, groups, tags")
        .toolbar { Menu("Filter", systemImage: "line.3.horizontal.decrease.circle") { Toggle("Healthy only", isOn: $healthyOnly) }; Button("Add", systemImage: "plus") { showingEditor = true } }
        .sheet(isPresented: $showingEditor, onDismiss: { Task { await reload() } }) { HostEditorView().environmentObject(container) }
        .task { await reload() }
    }
    private func reload() async { hosts = (try? await container.catalog.listHosts()) ?? [] }
}

struct HostRow: View {
    let host: Host
    var body: some View {
        HStack {
            Image(systemName: "server.rack").foregroundStyle(.tint)
            VStack(alignment: .leading) { Text(host.name).font(.headline); Text(host.address).font(.caption).foregroundStyle(.secondary); HStack { if host.groupID != nil { Text("Group").tagChip() }; if !host.tagIDs.isEmpty { Text("\(host.tagIDs.count) tag\(host.tagIDs.count == 1 ? "" : "s")").tagChip() } } }
            Spacer()
            Text(host.health.label).font(.caption2).foregroundStyle(host.health == .healthy ? Color.green : Color.secondary).accessibilityLabel("Health \(host.health.label)")
        }
    }
}

struct HostDetailView: View {
    @EnvironmentObject private var container: AppContainer
    let host: Host
    @State private var showEditor = false
    var body: some View {
        Form {
            Section("Endpoint") { LabeledContent("Address", value: host.address); LabeledContent("Profile", value: profileName) }
            Section("Safety") {
                Label("Secrets stay in Keychain references", systemImage: "lock.shield")
                Label("Unknown host keys require approval", systemImage: "checkmark.shield")
            }
            Section {
                Button("Connect", systemImage: "bolt.horizontal") { Task { await container.connect(to: host) } }
                    .disabled(container.activeSession?.state == .connected)
                Button("Edit", systemImage: "pencil") { showEditor = true }
            }
        }
        .navigationTitle(host.name)
        .sheet(isPresented: $showEditor) { HostEditorView(existing: host).environmentObject(container) }
        .confirmationDialog("Approve host key?", isPresented: Binding(get: { container.pendingTrustChallenge != nil }, set: { if !$0 { container.rejectPendingHostKey() } }), titleVisibility: .visible) {
            Button("Trust Once") { Task { await container.approvePendingHostKey(permanently: false) } }
            Button("Always Trust") { Task { await container.approvePendingHostKey(permanently: true) } }
            Button("Reject", role: .cancel) { container.rejectPendingHostKey() }
        } message: {
            if let challenge = container.pendingTrustChallenge {
                Text("\(challenge.hostname):\(challenge.port)\n\(challenge.algorithm)\n\(challenge.fingerprint)")
            }
        }
        .safeAreaInset(edge: .bottom) { if container.activeSession != nil { NavigationLink("Open session", destination: SessionView()).buttonStyle(.borderedProminent).padding() } }
    }
    private var profileName: String {
        if case .ssh = host.connection {
            return container.isDemo ? "SSH (demo adapter)" : "SSH (live adapter)"
        }
        return "Capability unavailable"
    }
}

struct HostEditorView: View {
    @EnvironmentObject private var container: AppContainer
    @Environment(\.dismiss) private var dismiss
    let existing: Host?
    @State private var name: String
    @State private var hostname: String
    @State private var username: String
    @State private var port: String
    @State private var identityID: UUID?
    @State private var identities: [IdentityDescriptor] = []
    init(existing: Host? = nil) { self.existing = existing; _name = State(initialValue: existing?.name ?? ""); _hostname = State(initialValue: existing?.hostname ?? ""); _username = State(initialValue: existing?.username ?? ""); _port = State(initialValue: String(existing?.port ?? 22)); _identityID = State(initialValue: existing?.identityID) }
    var body: some View {
        NavigationStack {
            Form { Section("Host metadata") { TextField("Name", text: $name); TextField("Hostname", text: $hostname); TextField("Username", text: $username); TextField("Port", text: $port).keyboardType(.numberPad); Picker("Identity", selection: $identityID) { Text("None").tag(UUID?.none); ForEach(identities) { identity in Text(identity.name).tag(Optional(identity.id)) } } }; Section { Text("Passwords and private keys are selected through Keychain identities and never stored in this form.").font(.caption).foregroundStyle(.secondary) } }
                .navigationTitle(existing == nil ? "New host" : "Edit host")
                .task { identities = (try? await container.catalog.identities()) ?? [] }
                .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }; ToolbarItem(placement: .confirmationAction) { Button("Save") { save() }.disabled(name.isEmpty || hostname.isEmpty || username.isEmpty) } }
        }
    }
    private func save() {
        guard let portNumber = UInt16(port), let host = try? Host(id: existing?.id ?? UUID(), name: name, hostname: hostname, port: portNumber, username: username, identityID: identityID, connection: existing?.connection ?? .ssh(SSHOptions())) else { return }
        Task {
            do {
                try await container.catalog.save(host)
                dismiss()
            } catch { }
        }
    }
}

struct SessionDashboardView: View {
    @EnvironmentObject private var container: AppContainer
    var body: some View { Group { if container.activeSession != nil { SessionView() } else { ContentUnavailableView("No active sessions", systemImage: "rectangle.split.2x1", description: Text("Connect a host to create a foreground session.")) } }.navigationTitle("Sessions") }
}

struct PendingCommand: Identifiable {
    let id = UUID()
    let command: String
}

struct SessionView: View {
    @EnvironmentObject private var container: AppContainer
    @State private var command = ""
    @State private var pendingSnippet: Snippet?
    @State private var pendingApproval: PendingCommand?
    @State private var blockedCommand = ""
    @State private var showMultiplexer = false
    @State private var showVoice = false
    private let policy = CommandPolicy()
    var body: some View {
        VStack(spacing: 0) {
            HStack { Label(container.activeSession?.state.rawValue.capitalized ?? "Disconnected", systemImage: "circle.fill").foregroundStyle(container.activeSession?.state == .connected ? .green : .secondary); Spacer(); Menu("Tools", systemImage: "ellipsis.circle") { Button("Multiplexer", systemImage: "rectangle.3.group") { showMultiplexer = true }; Button("Disconnect", role: .destructive) { Task { await container.disconnect() } } } }.padding(.horizontal)
            ScrollView { Text(container.terminalText.isEmpty ? "Terminal output" : container.terminalText).font(.system(.body, design: .monospaced)).frame(maxWidth: .infinity, alignment: .leading).textSelection(.enabled).padding() }.background(Color.black).foregroundStyle(Color.green).accessibilityLabel("Terminal output").accessibilityValue(Text(container.terminalText.isEmpty ? "No terminal output" : container.terminalText))
            HStack { TextField("Command or paste", text: $command, axis: .vertical).textFieldStyle(.roundedBorder); Button("Send") { submit(command); command = "" }.disabled(command.isEmpty || container.activeSession?.state != .connected); Button("Speak", systemImage: "mic") { container.speechState = .idle; showVoice = true }.accessibilityLabel("Push to talk") }.padding()
        }
        .navigationTitle("Terminal")
        .sheet(isPresented: $showMultiplexer) { MultiplexerPicker().presentationDetents([.medium]) }
        .sheet(isPresented: $showVoice) { VoiceComposer().environmentObject(container).presentationDetents([.medium]) }
        .sheet(item: $pendingSnippet) { snippet in ApprovalSheet(command: snippet.body).environmentObject(container) }
        .sheet(item: $pendingApproval) { request in ApprovalSheet(command: request.command).environmentObject(container) }
        .alert("Command blocked", isPresented: Binding(get: { !blockedCommand.isEmpty }, set: { if !$0 { blockedCommand = "" } })) { Button("OK", role: .cancel) { blockedCommand = "" } } message: { Text("This command is not permitted by the safety policy.") }
    }
    private func submit(_ text: String) {
        let value = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty else { return }
        switch policy.classify(value) {
        case .safe: Task { _ = await container.send(value + "\n") }
        case .reviewRequired: pendingApproval = PendingCommand(command: value)
        case .blocked: blockedCommand = value
        }
    }
}

struct ApprovalSheet: View {
    @EnvironmentObject private var container: AppContainer
    @Environment(\.dismiss) private var dismiss
    let command: String
    @State private var approved = false
    private let policy = CommandPolicy()
    var body: some View {
        NavigationStack {
            Form {
                Section("Exact command") { Text(command).font(.system(.body, design: .monospaced)).textSelection(.enabled) }
                Toggle("I approve sending this command", isOn: $approved)
            }
            .navigationTitle("Confirm command")
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Send") { Task { if await container.send(command + "\n", approved: true) { dismiss() } } }.disabled(!approved || policy.classify(command) == .blocked || container.activeSession?.state != .connected) } }
        }
    }
}

struct MultiplexerPicker: View {
    @State private var selected = RemoteMultiplexer.tmux
    private var preview: String {
        switch selected {
        case .tmux: return TmuxAdapter().command(for: .list)
        default: return UnavailableMultiplexerAdapter(kind: selected).command(for: .list)
        }
    }
    var body: some View {
        NavigationStack {
            Form {
                Picker("Adapter", selection: $selected) { ForEach(RemoteMultiplexer.allCases, id: \.self) { Text($0.rawValue.capitalized).tag($0) } }
                Section("Command preview") { Text(preview).font(.system(.body, design: .monospaced)).textSelection(.enabled) }
                Text("Selection only; multiplexer integration is not enabled in this build.").foregroundStyle(.secondary)
            }
            .navigationTitle("Multiplexer")
        }
    }
}

struct SnippetsView: View {
    @EnvironmentObject private var container: AppContainer
    @State private var snippets: [Snippet] = []
    var body: some View { List(snippets) { snippet in NavigationLink { SnippetEditor(snippet: snippet) } label: { VStack(alignment: .leading) { Text(snippet.name); Text(snippet.body).font(.caption.monospaced()).foregroundStyle(.secondary) } } }.navigationTitle("Snippets").task { snippets = (try? await container.catalog.snippets()) ?? [] } }
}
struct SnippetEditor: View {
    @EnvironmentObject private var container: AppContainer
    let snippet: Snippet
    @State private var bodyText: String
    @State private var showApproval = false
    init(snippet: Snippet) { self.snippet = snippet; _bodyText = State(initialValue: snippet.body) }
    var body: some View { Form { TextField("Name", text: .constant(snippet.name)); TextEditor(text: $bodyText).frame(minHeight: 160); Text("Run always shows this exact text and requires approval.").font(.caption).foregroundStyle(.secondary); Button("Run with approval", systemImage: "play.fill") { showApproval = true }.disabled(bodyText.isEmpty) }.navigationTitle("Snippet").sheet(isPresented: $showApproval) { ApprovalSheet(command: bodyText).environmentObject(container) } }
}
struct VoiceComposer: View {
    @EnvironmentObject private var container: AppContainer
    @Environment(\.dismiss) private var dismiss
    @State private var text = ""
    @State private var pendingApproval: PendingCommand?
    @State private var blocked = false
    private let policy = CommandPolicy()
    var body: some View {
        NavigationStack {
            Form {
                Section("Push to talk") {
                    Button("Recording unavailable", systemImage: "mic.slash") { }
                        .disabled(true)
                    Text("Audio recording and local transcription are not enabled in this build. Type an editable command below.").font(.caption).foregroundStyle(.secondary)
                }
                Section("Editable preview") { TextEditor(text: $text).frame(minHeight: 100) }
            }
            .navigationTitle("Voice command")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) { Button("Send") { submit() }.disabled(text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || container.activeSession?.state != .connected) }
            }
            .sheet(item: $pendingApproval) { request in ApprovalSheet(command: request.command).environmentObject(container) }
            .alert("Command blocked", isPresented: $blocked) { Button("OK", role: .cancel) { blocked = false } } message: { Text("This command is not permitted by the safety policy.") }
        }
    }
    private func submit() {
        let value = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty else { return }
        switch policy.classify(value) {
        case .safe: Task { if await container.send(value + "\n") { dismiss() } }
        case .reviewRequired: pendingApproval = PendingCommand(command: value)
        case .blocked: blocked = true
        }
    }
}
struct FilesView: View { var body: some View { ContentUnavailableView("Files unavailable", systemImage: "folder", description: Text("SFTP is modeled behind RemoteFileRepository and is not enabled in this build.")) .navigationTitle("Files") } }
struct MonitoringView: View { var body: some View { List { Label("Health checks are opt-in", systemImage: "heart.text.square"); Label("Unknown is not authentication success", systemImage: "info.circle"); Label("Live monitoring is foreground-only", systemImage: "iphone") }.navigationTitle("Monitoring") } }
struct SettingsView: View { var body: some View { Form { Section("Security") { Toggle("Require biometric presence (hook)", isOn: .constant(false)); Label("Keychain accessibility: when unlocked, this device only", systemImage: "key.fill") }; Section("Capabilities") { Text("Mosh, ProxyJump, forwarding, SFTP, Whisper, and non-tmux adapters: not enabled in this build.").font(.caption) }; Section("Privacy") { Text("No transcript analytics. Voice processing is local-only when a model is installed.").font(.caption) } }.navigationTitle("Settings") } }
