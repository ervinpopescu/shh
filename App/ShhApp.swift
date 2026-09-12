import ShhCore
import ShhTerminal
import SwiftUI

@main
struct ShhApp: App {
    @Environment(\.scenePhase) private var scenePhase
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
        WindowGroup {
            RootView()
                .environmentObject(container)
                .onChange(of: scenePhase) { _, newPhase in
                    container.handleScenePhaseChange(newPhase)
                }
        }
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
        .confirmationDialog("Approve host key?", isPresented: Binding(get: { container.pendingTrustChallenge != nil }, set: { if !$0 { container.rejectPendingHostKey() } }), titleVisibility: .visible) {
            Button("Trust Once") { Task { await container.approvePendingHostKey(permanently: false) } }
            Button("Always Trust") { Task { await container.approvePendingHostKey(permanently: true) } }
            Button("Reject", role: .cancel) { container.rejectPendingHostKey() }
        } message: {
            if let challenge = container.pendingTrustChallenge {
                Text("\(challenge.hostname):\(challenge.port)\n\(challenge.algorithm)\n\(challenge.fingerprint)")
            }
        }
    }
    private var capabilityFooter: some View {
        let surfaceDescription = container.useLegacyTerminalFallback
            ? "Legacy terminal fallback surface active."
            : "SwiftTerm production terminal surface active."
        return VStack(alignment: .leading, spacing: 4) {
            Text(container.isDemo ? "Offline demo mode" : "Live SSH mode").font(.caption.bold())
            Text(container.isDemo
                ? "SSH adapter active in offline demo mode. \(surfaceDescription) SFTP active. ProxyJump and forwarding active. Mosh is not enabled in this build. Local voice AI active."
                : "Live SSH transport active. \(surfaceDescription) SFTP active. ProxyJump and forwarding active. Mosh is not enabled in this build. Local voice AI active.").font(.caption2).foregroundStyle(.secondary)
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
    @State private var showPortForwarding = false
    @State private var bastionHops: [String] = []

    var body: some View {
        Form {
            Section("Endpoint") {
                LabeledContent("Address", value: host.address)
                LabeledContent("Profile", value: profileName)
            }

            if case .proxyJump(let opts) = host.connection {
                Section("ProxyJump Bastion Chain") {
                    if opts.config.hops.isEmpty {
                        Text("No bastion hops configured")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    } else {
                        ForEach(Array(opts.config.hops.enumerated()), id: \.offset) { index, hop in
                            HStack {
                                Label("Hop \(index + 1)", systemImage: "arrow.triangle.branch")
                                Spacer()
                                Text(hopDescription(index: index, hop: hop))
                                    .foregroundStyle(.secondary)
                            }
                            .accessibilityElement(children: .combine)
                            .accessibilityLabel("Hop \(index + 1): \(hopDescription(index: index, hop: hop))")
                            .accessibilityIdentifier("host-detail-hop-\(index)")
                        }
                    }
                }
            }

            Section("Port Forwarding") {
                if host.forwardingRules.isEmpty {
                    Text("No forwarding rules configured.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(host.forwardingRules) { rule in
                        HStack {
                            VStack(alignment: .leading, spacing: 2) {
                                HStack {
                                    Text(rule.name).font(.subheadline.bold())
                                    PortForwardingTypeBadge(type: rule.type)
                                }
                                Text(portForwardingRuleSummary(rule))
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                            Spacer()
                            if isHostActiveSession {
                                let live = container.forwardingSessions.first(where: { $0.ruleID == rule.id })
                                ForwardingStatusPill(status: live?.status ?? .stopped)
                            } else {
                                Text(rule.enabled ? "Auto-start" : "Disabled")
                                    .font(.caption2)
                                    .foregroundStyle(.secondary)
                            }
                        }
                        .accessibilityElement(children: .combine)
                        .accessibilityIdentifier("host-detail-rule-\(rule.id)")
                    }
                }

                if isHostActiveSession {
                    Button {
                        showPortForwarding = true
                    } label: {
                        Label("Manage Forwarders (\(container.activeForwardersCount) active)", systemImage: "arrow.triangle.swap")
                    }
                    .accessibilityIdentifier("host-detail-manage-forwarders-button")
                    .accessibilityLabel("Manage active port forwarders")
                }
            }

            Section("Safety") {
                Label("Secrets stay in Keychain references", systemImage: "lock.shield")
                Label("Unknown host keys require approval", systemImage: "checkmark.shield")
            }
            Section("Voice & Environment") {
                LabeledContent("Voice input", value: host.isVoiceEnabled ? "Enabled" : "Disabled (Default)")
                LabeledContent("Environment", value: host.isProduction ? "Production" : "Standard")
            }
            Section {
                Button("Connect", systemImage: "bolt.horizontal") { Task { await container.connect(to: host) } }
                    .disabled(isConnectDisabled)
                Button("Edit", systemImage: "pencil") { showEditor = true }
                if isFailedForThisHost && !container.terminalText.isEmpty {
                    Label(container.terminalText, systemImage: "exclamationmark.triangle.fill")
                        .font(.caption)
                        .foregroundStyle(.red)
                }
            }
        }
        .navigationTitle(host.name)
        .task {
            bastionHops = await container.resolveBastionNames(for: host)
        }
        .sheet(isPresented: $showEditor) { HostEditorView(existing: host).environmentObject(container) }
        .sheet(isPresented: $showPortForwarding) { PortForwardingSheet().environmentObject(container) }
        .safeAreaInset(edge: .bottom) {
            if let session = container.activeSession, session.hostID == host.id {
                NavigationLink("Open session", destination: SessionView()).buttonStyle(.borderedProminent).padding()
            }
        }
    }

    private var isHostActiveSession: Bool {
        container.activeSession?.hostID == host.id && container.activeSession?.state == .connected
    }

    private var isConnectDisabled: Bool {
        container.activeSession?.state == .connecting ||
            (container.activeSession?.hostID == host.id && container.activeSession?.state == .connected)
    }

    private var isFailedForThisHost: Bool {
        container.activeSession?.hostID == host.id && container.activeSession?.state == .failed
    }

    private var profileName: String {
        switch host.connection {
        case .ssh:
            return container.isDemo ? "SSH (demo adapter)" : "SSH (live adapter)"
        case .proxyJump(let opts):
            return "ProxyJump (\(opts.config.hops.count) hop\(opts.config.hops.count == 1 ? "" : "s"))"
        case .mosh:
            return "Capability unavailable"
        }
    }

    private func hopDescription(index: Int, hop: ProxyJumpHop) -> String {
        if bastionHops.indices.contains(index) && !bastionHops[index].isEmpty {
            return bastionHops[index]
        }
        switch hop {
        case .hostID(let id):
            return id.uuidString.prefix(8) + "..."
        case .endpoint(let ep):
            return "\(ep.username)@\(ep.hostname):\(ep.port)"
        }
    }
}

enum HostConnectionType: String, CaseIterable, Identifiable {
    case direct = "Direct SSH"
    case proxyJump = "ProxyJump Bastion"
    var id: String { rawValue }
}

struct BastionHopItem: Identifiable, Equatable {
    let id: UUID
    var hostID: UUID
    init(id: UUID = UUID(), hostID: UUID) {
        self.id = id
        self.hostID = hostID
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
    @State private var connectionType: HostConnectionType
    @State private var bastionHops: [BastionHopItem]
    @State private var forwardingRules: [PortForwardingRule]
    @State private var showingAddRule = false
    @State private var ruleToEdit: PortForwardingRule? = nil
    @State private var allHosts: [Host] = []
    @State private var defaultTmuxSession: String
    @State private var autoAttachTmux: Bool
    @State private var enableVoice: Bool
    @State private var allowShellCommand: Bool
    @State private var allowAgentMessage: Bool
    @State private var allowInsertOnly: Bool
    @State private var isProductionHost: Bool
    @State private var identities: [IdentityDescriptor] = []

    init(existing: Host? = nil) {
        self.existing = existing
        _name = State(initialValue: existing?.name ?? "")
        _hostname = State(initialValue: existing?.hostname ?? "")
        _username = State(initialValue: existing?.username ?? "")
        _port = State(initialValue: String(existing?.port ?? 22))
        _identityID = State(initialValue: existing?.identityID)

        let initialType: HostConnectionType
        let initialBastions: [UUID]
        if case .proxyJump(let jumpOpts) = existing?.connection {
            initialType = .proxyJump
            initialBastions = jumpOpts.config.hostIDs
        } else {
            initialType = .direct
            initialBastions = []
        }
        _connectionType = State(initialValue: initialType)
        _bastionHops = State(initialValue: initialBastions.map { BastionHopItem(hostID: $0) })
        _forwardingRules = State(initialValue: existing?.forwardingRules ?? [])

        _defaultTmuxSession = State(initialValue: existing?.defaultTmuxSession ?? "")
        _autoAttachTmux = State(initialValue: existing?.autoAttachTmux ?? false)
        _enableVoice = State(initialValue: existing?.isVoiceEnabled ?? false)
        let allowed = existing?.voicePolicy.allowedModes ?? Set(VoiceInputMode.allCases)
        _allowShellCommand = State(initialValue: allowed.contains(.shellCommand))
        _allowAgentMessage = State(initialValue: allowed.contains(.agentMessage))
        _allowInsertOnly = State(initialValue: allowed.contains(.insertOnly))
        _isProductionHost = State(initialValue: existing?.isProduction ?? false)
    }

    private var availableBastions: [Host] {
        allHosts.filter { $0.id != existing?.id }
    }

    private func bastionName(for id: UUID) -> String {
        if let host = allHosts.first(where: { $0.id == id }) {
            return "\(host.name) (\(host.address))"
        }
        return id.uuidString.prefix(8) + "..."
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("Host metadata") {
                    TextField("Name", text: $name)
                        .accessibilityIdentifier("host-editor-name-field")
                    TextField("Hostname", text: $hostname)
                        .accessibilityIdentifier("host-editor-hostname-field")
                    TextField("Username", text: $username)
                        .accessibilityIdentifier("host-editor-username-field")
                    TextField("Port", text: $port).keyboardType(.numberPad)
                        .accessibilityIdentifier("host-editor-port-field")
                    Picker("Identity", selection: $identityID) {
                        Text("None").tag(UUID?.none)
                        ForEach(identities) { identity in
                            Text(identity.name).tag(Optional(identity.id))
                        }
                    }
                    .accessibilityIdentifier("host-editor-identity-picker")
                }

                Section("Connection & ProxyJump") {
                    Picker("Connection Type", selection: $connectionType) {
                        ForEach(HostConnectionType.allCases) { type in
                            Text(type.rawValue).tag(type)
                        }
                    }
                    .pickerStyle(.segmented)
                    .accessibilityIdentifier("host-editor-connection-type-picker")
                    .accessibilityLabel("Connection type picker")

                    if connectionType == .proxyJump {
                        if bastionHops.isEmpty {
                            Text("No jump bastions selected. Add one or more hops from saved hosts.")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        } else {
                            ForEach(Array(bastionHops.enumerated()), id: \.element.id) { index, hop in
                                HStack {
                                    VStack(alignment: .leading, spacing: 2) {
                                        Text("Hop \(index + 1)")
                                            .font(.caption2.bold())
                                            .foregroundStyle(.secondary)
                                        Text(bastionName(for: hop.hostID))
                                            .font(.subheadline)
                                    }
                                    Spacer()
                                    if index > 0 {
                                        Button {
                                            bastionHops.swapAt(index, index - 1)
                                        } label: {
                                            Image(systemName: "arrow.up")
                                        }
                                        .buttonStyle(.borderless)
                                        .accessibilityLabel("Move hop \(index + 1) up")
                                        .accessibilityIdentifier("move-up-hop-\(index)")
                                    }
                                    if index < bastionHops.count - 1 {
                                        Button {
                                            bastionHops.swapAt(index, index + 1)
                                        } label: {
                                            Image(systemName: "arrow.down")
                                        }
                                        .buttonStyle(.borderless)
                                        .accessibilityLabel("Move hop \(index + 1) down")
                                        .accessibilityIdentifier("move-down-hop-\(index)")
                                    }
                                    Button(role: .destructive) {
                                        bastionHops.remove(at: index)
                                    } label: {
                                        Image(systemName: "trash")
                                            .foregroundStyle(.red)
                                    }
                                    .buttonStyle(.borderless)
                                    .accessibilityLabel("Remove hop \(index + 1)")
                                    .accessibilityIdentifier("remove-hop-\(index)")
                                }
                            }
                        }

                        if !availableBastions.isEmpty {
                            Menu {
                                ForEach(availableBastions) { bastion in
                                    Button(bastion.name) {
                                        bastionHops.append(BastionHopItem(hostID: bastion.id))
                                    }
                                }
                            } label: {
                                Label("Add Jump Bastion", systemImage: "plus.circle")
                            }
                            .accessibilityIdentifier("add-bastion-hop-button")
                            .accessibilityLabel("Add jump bastion hop")
                        } else {
                            Text("No other saved hosts available to use as a bastion.")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                }

                Section("Port Forwarding Rules") {
                    if forwardingRules.isEmpty {
                        Text("No forwarding rules configured.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    } else {
                        ForEach($forwardingRules) { $rule in
                            HStack {
                                VStack(alignment: .leading, spacing: 2) {
                                    HStack {
                                        Text(rule.name).font(.subheadline.bold())
                                        PortForwardingTypeBadge(type: rule.type)
                                    }
                                    Text(portForwardingRuleSummary(rule))
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                }
                                .contentShape(Rectangle())
                                .onTapGesture {
                                    ruleToEdit = rule
                                }
                                .accessibilityAction(named: "Edit Rule") {
                                    ruleToEdit = rule
                                }
                                Spacer()
                                Toggle("", isOn: $rule.enabled)
                                    .labelsHidden()
                                    .accessibilityLabel("Enable \(rule.name)")
                                    .accessibilityIdentifier("toggle-rule-\(rule.id)")
                            }
                        }
                        .onDelete { indices in
                            forwardingRules.remove(atOffsets: indices)
                        }
                    }

                    Button {
                        showingAddRule = true
                    } label: {
                        Label("Add Forwarding Rule", systemImage: "plus.circle")
                    }
                    .accessibilityIdentifier("host-editor-add-rule-button")
                    .accessibilityLabel("Add port forwarding rule")
                }

                Section("Tmux preferences") {
                    Toggle("Auto-attach tmux session", isOn: $autoAttachTmux)
                        .accessibilityIdentifier("host-editor-auto-attach-toggle")
                    TextField("Default session name/ID", text: $defaultTmuxSession)
                        .autocorrectionDisabled()
                        .textInputAutocapitalization(.never)
                        .accessibilityIdentifier("host-editor-default-session-field")
                    if let hint = tmuxPreferenceHint {
                        Text(hint.message)
                            .font(.caption)
                            .foregroundStyle(hint.isValid ? Color.secondary : Color.red)
                            .accessibilityIdentifier("host-editor-session-validation-hint")
                    }
                }
                Section("Voice input policy") {
                    Toggle("Enable voice input", isOn: $enableVoice)
                        .accessibilityIdentifier("host-editor-voice-toggle")
                    if enableVoice {
                        Toggle("Allow Shell Commands", isOn: $allowShellCommand)
                        Toggle("Allow Agent Messages", isOn: $allowAgentMessage)
                        Toggle("Allow Insert Text", isOn: $allowInsertOnly)
                    }
                    Toggle("Production environment", isOn: $isProductionHost)
                        .accessibilityIdentifier("host-editor-production-toggle")
                    if isProductionHost {
                        Text("Production hosts require extra confirmation before dispatching agent messages.")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                }
                Section {
                    Text("Passwords and private keys are selected through Keychain identities and never stored in this form.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .navigationTitle(existing == nil ? "New host" : "Edit host")
            .task {
                identities = (try? await container.catalog.identities()) ?? []
                allHosts = (try? await container.catalog.listHosts()) ?? []
            }
            .sheet(isPresented: $showingAddRule) {
                PortForwardingRuleEditorSheet { newRule in
                    forwardingRules.append(newRule)
                }
            }
            .sheet(item: $ruleToEdit) { rule in
                PortForwardingRuleEditorSheet(existingRule: rule) { updatedRule in
                    if let idx = forwardingRules.firstIndex(where: { $0.id == updatedRule.id }) {
                        forwardingRules[idx] = updatedRule
                    }
                }
            }
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") { save() }
                        .disabled(name.isEmpty || hostname.isEmpty || username.isEmpty || !isTmuxPreferenceValid || (connectionType == .proxyJump && bastionHops.isEmpty))
                        .accessibilityIdentifier("host-editor-save-button")
                }
            }
        }
    }

    private var isTmuxPreferenceValid: Bool {
        let trimmed = defaultTmuxSession.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty { return true }
        if trimmed.hasPrefix("$") {
            return (try? TmuxSessionID(trimmed)) != nil
        } else {
            return (try? TmuxSessionName(trimmed)) != nil
        }
    }

    private var tmuxPreferenceHint: (message: String, isValid: Bool)? {
        let trimmed = defaultTmuxSession.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        if trimmed.hasPrefix("$") {
            if (try? TmuxSessionID(trimmed)) != nil {
                return ("Valid tmux session ID", true)
            } else {
                return ("Invalid session ID: must start with '$' followed by digits (e.g. '$0')", false)
            }
        } else {
            do {
                _ = try TmuxSessionName(trimmed)
                return ("Valid tmux session name", true)
            } catch let error as TmuxSessionNameError {
                return (error.localizedDescription, false)
            } catch {
                return ("Invalid session name", false)
            }
        }
    }

    private func save() {
        guard isTmuxPreferenceValid else { return }
        if connectionType == .proxyJump && bastionHops.isEmpty { return }
        let trimmedSession = defaultTmuxSession.trimmingCharacters(in: .whitespacesAndNewlines)
        let sessionPref = trimmedSession.isEmpty ? nil : trimmedSession
        var allowedModes: Set<VoiceInputMode> = []
        if allowShellCommand { allowedModes.insert(.shellCommand) }
        if allowAgentMessage { allowedModes.insert(.agentMessage) }
        if allowInsertOnly { allowedModes.insert(.insertOnly) }
        let voicePolicy = HostVoicePolicy(isEnabled: enableVoice, allowedModes: allowedModes)

        let profile: ConnectionProfile
        let existingSSH: SSHOptions
        if case .ssh(let opts) = existing?.connection {
            existingSSH = opts
        } else if case .proxyJump(let opts) = existing?.connection {
            existingSSH = opts.sshOptions
        } else {
            existingSSH = SSHOptions()
        }

        if connectionType == .proxyJump && !bastionHops.isEmpty {
            let hopHostIDs = bastionHops.map(\.hostID)
            profile = .proxyJump(ProxyJumpOptions(hopHostIDs: hopHostIDs, sshOptions: existingSSH))
        } else {
            profile = .ssh(existingSSH)
        }

        guard let portNumber = UInt16(port),
              let host = try? Host(
                  id: existing?.id ?? UUID(),
                  name: name,
                  hostname: hostname,
                  port: portNumber,
                  username: username,
                  identityID: identityID,
                  connection: profile,
                  defaultTmuxSession: sessionPref,
                  autoAttachTmux: autoAttachTmux,
                  voicePolicy: voicePolicy,
                  isProduction: isProductionHost,
                  forwardingRules: forwardingRules
              ) else { return }
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
    @State private var isCommandDrawerExpanded = false
    @State private var isSearchPresented = false
    @State private var searchQuery = ""
    @State private var pendingRiskyPaste: String?
    @State private var showPortForwarding = false
    private let policy = CommandPolicy()

    var body: some View {
        VStack(spacing: 0) {
            // Header / Status bar
            sessionHeader

            // Reconnect status banner if coordinator is active
            reconnectBanner

            // Search Bar (if presented)
            if isSearchPresented {
                TerminalSearchBar(
                    controller: container.terminalController,
                    query: $searchQuery,
                    onClose: {
                        isSearchPresented = false
                        searchQuery = ""
                        container.terminalController.clearSearch()
                    }
                )
                Divider()
            }

            // Terminal Surface (Production SwiftTerm or Legacy Fallback)
            terminalSurfaceArea

            // Extra-key accessory bar (always accessible above drawer)
            TerminalAccessoryBar(controller: container.terminalController)
            Divider()

            // Collapsible Validated-Command Drawer
            commandDrawer
        }
        .navigationTitle(container.terminalController.title.isEmpty ? "Terminal" : container.terminalController.title)
        .sheet(isPresented: $showMultiplexer) { MultiplexerPicker().environmentObject(container).presentationDetents([.medium, .large]) }
        .sheet(isPresented: $showVoice) { VoiceComposer().environmentObject(container).presentationDetents([.medium, .large]) }
        .sheet(isPresented: $showPortForwarding) { PortForwardingSheet().environmentObject(container).presentationDetents([.medium, .large]) }
        .sheet(item: $pendingSnippet) { snippet in ApprovalSheet(command: snippet.body).environmentObject(container) }
        .sheet(item: $pendingApproval) { request in ApprovalSheet(command: request.command).environmentObject(container) }
        .alert("Command blocked", isPresented: Binding(get: { !blockedCommand.isEmpty }, set: { if !$0 { blockedCommand = "" } })) {
            Button("OK", role: .cancel) { blockedCommand = "" }
        } message: {
            Text("This command is not permitted by the safety policy.")
        }
        .confirmationDialog(
            "Confirm Multi-Line Paste",
            isPresented: Binding(get: { pendingRiskyPaste != nil }, set: { if !$0 { pendingRiskyPaste = nil } }),
            titleVisibility: .visible
        ) {
            Button("Paste Anyway", role: .destructive) {
                if let text = pendingRiskyPaste {
                    container.terminalController.paste(text)
                }
                pendingRiskyPaste = nil
            }
            Button("Cancel", role: .cancel) {
                pendingRiskyPaste = nil
            }
        } message: {
            Text("The remote session does not have bracketed paste enabled. Pasting multiple lines may execute commands immediately without confirmation.")
        }
        .onAppear {
            container.terminalController.onRiskyPasteRequested = { text in
                pendingRiskyPaste = text
            }
        }
    }

    @ViewBuilder
    private var reconnectBanner: some View {
        switch container.reconnectState {
        case .waiting(let attempt, let delay):
            HStack(spacing: 8) {
                ProgressView()
                    .controlSize(.small)
                Text("Reconnecting (attempt \(attempt)/\(ReconnectCoordinator.maxAttempts)) in \(Int(ceil(delay)))s...")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
                Button("Cancel") {
                    Task { await container.cancelReconnect() }
                }
                .font(.caption.bold())
            }
            .padding(.horizontal)
            .padding(.vertical, 6)
            .background(Color.yellow.opacity(0.15))
            Divider()
        case .connecting(let attempt):
            HStack(spacing: 8) {
                ProgressView()
                    .controlSize(.small)
                Text("Reconnecting (attempt \(attempt)/\(ReconnectCoordinator.maxAttempts))...")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
                Button("Cancel") {
                    Task { await container.cancelReconnect() }
                }
                .font(.caption.bold())
            }
            .padding(.horizontal)
            .padding(.vertical, 6)
            .background(Color.blue.opacity(0.15))
            Divider()
        case .exhausted(let attempts):
            HStack(spacing: 8) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundStyle(.orange)
                Text("Reconnection failed after \(attempts) attempts.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
                Button("Retry") {
                    Task { await container.retryReconnect() }
                }
                .font(.caption.bold())
            }
            .padding(.horizontal)
            .padding(.vertical, 6)
            .background(Color.orange.opacity(0.15))
            Divider()
        default:
            EmptyView()
        }
    }

    private var sessionHeader: some View {
        HStack(spacing: 8) {
            Label(
                container.activeSession?.state.rawValue.capitalized ?? "Disconnected",
                systemImage: "circle.fill"
            )
            .font(.subheadline)
            .foregroundStyle(container.activeSession?.state == .connected ? .green : .secondary)

            if !container.terminalController.title.isEmpty {
                Text("•")
                    .foregroundStyle(.secondary)
                    .accessibilityHidden(true)
                Text(container.terminalController.title)
                    .font(.caption)
                    .lineLimit(1)
                    .foregroundStyle(.secondary)
            }

            if let activeTmux = container.activeTmuxSessionID {
                Text("•")
                    .foregroundStyle(.secondary)
                    .accessibilityHidden(true)
                Label(activeTmux, systemImage: "rectangle.3.group")
                    .font(.caption)
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .foregroundStyle(.secondary)
                    .accessibilityLabel("Tmux session \(activeTmux)")
                    .accessibilityIdentifier("active-tmux-indicator")
            }

            if let activeHost = container.activeHost,
               case .proxyJump(let opts) = activeHost.connection,
               !opts.config.hops.isEmpty {
                Text("•")
                    .foregroundStyle(.secondary)
                    .accessibilityHidden(true)
                Label("\(opts.config.hops.count) Hop\(opts.config.hops.count == 1 ? "" : "s")", systemImage: "arrow.triangle.branch")
                    .font(.caption)
                    .lineLimit(1)
                    .foregroundStyle(.secondary)
                    .accessibilityLabel("\(opts.config.hops.count) jump bastion hop\(opts.config.hops.count == 1 ? "" : "s")")
                    .accessibilityIdentifier("session-jump-hops-indicator")
            }

            if container.activeForwardersCount > 0 {
                Text("•")
                    .foregroundStyle(.secondary)
                    .accessibilityHidden(true)
                Button(action: {
                    showPortForwarding = true
                }) {
                    Label("\(container.activeForwardersCount)", systemImage: "arrow.triangle.swap")
                        .font(.caption.bold())
                        .foregroundStyle(Color.accentColor)
                }
                .accessibilityLabel("\(container.activeForwardersCount) active port forwarder\(container.activeForwardersCount == 1 ? "" : "s")")
                .accessibilityIdentifier("session-forwarders-indicator")
            } else if let errorMsg = container.forwardingErrorMessage {
                Text("•")
                    .foregroundStyle(.secondary)
                    .accessibilityHidden(true)
                Button(action: {
                    showPortForwarding = true
                }) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .font(.caption.bold())
                        .foregroundStyle(.orange)
                }
                .accessibilityLabel("Port forwarding alert: \(errorMsg)")
                .accessibilityIdentifier("session-forwarders-error-indicator")
            }

            Spacer()

            // Voice Command Button
            Button(action: {
                container.resetVoiceState()
                showVoice = true
            }) {
                Image(systemName: "mic")
                    .font(.subheadline)
                    .foregroundStyle(container.activeHost?.isVoiceEnabled == true ? Color.accentColor : Color.secondary)
            }
            .accessibilityLabel("Voice command")
            .accessibilityIdentifier("session-header-voice-button")
            .disabled(container.activeSession?.state != .connected)

            // Search Toggle
            Button(action: {
                isSearchPresented.toggle()
                if !isSearchPresented {
                    searchQuery = ""
                    container.terminalController.clearSearch()
                }
            }) {
                Image(systemName: "magnifyingglass")
                    .font(.subheadline)
            }
            .accessibilityLabel(isSearchPresented ? "Close search" : "Search terminal")

            // Keyboard Focus Recovery Button
            Button(action: {
                container.terminalController.recoverFirstResponder()
            }) {
                Image(systemName: "keyboard")
                    .font(.subheadline)
                    .foregroundStyle(container.terminalController.isFirstResponder ? Color.primary : Color.accentColor)
            }
            .accessibilityLabel("Recover keyboard focus")

            // Tools Menu
            Menu {
                Button(action: {
                    if let selection = container.terminalController.getSelection(), !selection.isEmpty {
                        UIPasteboard.general.string = selection
                    }
                }) {
                    Label("Copy Selection", systemImage: "doc.on.doc")
                }

                Button(action: {
                    container.terminalController.selectAll()
                }) {
                    Label("Select All", systemImage: "selection.pin.in.out")
                }

                Button(action: {
                    container.terminalController.selectNone()
                }) {
                    Label("Clear Selection", systemImage: "xmark.circle")
                }

                Button(action: handlePasteFromClipboard) {
                    Label("Paste from Clipboard", systemImage: "doc.on.clipboard")
                }

                Divider()

                Button(action: {
                    showMultiplexer = true
                }) {
                    Label("Multiplexer", systemImage: "rectangle.3.group")
                }
                .accessibilityIdentifier("open-multiplexer-button")
                .accessibilityLabel("Open remote multiplexer sheet")

                Button(action: {
                    showPortForwarding = true
                }) {
                    Label("Port Forwarding (\(container.activeForwardersCount))", systemImage: "arrow.triangle.swap")
                }
                .accessibilityIdentifier("open-port-forwarding-button")
                .accessibilityLabel("Open port forwarding sheet")

                Button(action: {
                    container.useLegacyTerminalFallback.toggle()
                }) {
                    Label(
                        container.useLegacyTerminalFallback ? "Use SwiftTerm Surface" : "Use Legacy Fallback Surface",
                        systemImage: "arrow.triangle.2.circlepath"
                    )
                }

                Divider()

                Button("Disconnect", role: .destructive) {
                    Task { await container.disconnect() }
                }
            } label: {
                Image(systemName: "ellipsis.circle")
                    .font(.subheadline)
            }
            .accessibilityLabel("Session tools")
        }
        .padding(.horizontal)
        .padding(.vertical, 6)
        .background(Color(.systemBackground))
    }

    @ViewBuilder
    private var terminalSurfaceArea: some View {
        if container.useLegacyTerminalFallback {
            ScrollView {
                Text(container.terminalText.isEmpty ? "Terminal output" : container.terminalText)
                    .font(.system(.body, design: .monospaced))
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .textSelection(.enabled)
                    .padding()
            }
            .background(Color.black)
            .foregroundStyle(Color.green)
            .accessibilityLabel("Fallback terminal output")
            .accessibilityValue(Text(container.terminalText.isEmpty ? "No terminal output" : container.terminalText))
        } else {
            ShhTerminalView(controller: container.terminalController)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(Color.black)
                .accessibilityElement(children: .contain)
                .accessibilityLabel("Terminal surface")
        }
    }

    private var commandDrawer: some View {
        VStack(spacing: 6) {
            // Drawer toggle handle
            Button(action: {
                withAnimation(.easeInOut(duration: 0.2)) {
                    isCommandDrawerExpanded.toggle()
                }
            }) {
                HStack {
                    Image(systemName: "checkmark.shield")
                        .font(.caption2)
                    Text("Validated Command Drawer")
                        .font(.caption.weight(.medium))
                    Spacer()
                    Image(systemName: isCommandDrawerExpanded ? "chevron.down" : "chevron.up")
                        .font(.caption2)
                }
                .foregroundStyle(.secondary)
                .padding(.horizontal)
                .padding(.vertical, 6)
                .background(Color(.secondarySystemBackground))
            }
            .buttonStyle(.plain)
            .accessibilityLabel(isCommandDrawerExpanded ? "Collapse command drawer" : "Expand command drawer")

            if isCommandDrawerExpanded {
                VStack(spacing: 8) {
                    HStack {
                        TextField("Command to validate and send", text: $command, axis: .vertical)
                            .lineLimit(1...3)
                            .textFieldStyle(.roundedBorder)
                        Button("Send") {
                            submit(command)
                            command = ""
                        }
                        .buttonStyle(.borderedProminent)
                        .disabled(command.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || container.activeSession?.state != .connected)

                        Button("Speak", systemImage: "mic") {
                            container.resetVoiceState()
                            showVoice = true
                        }
                        .disabled(container.activeSession?.state != .connected)
                        .accessibilityLabel("Push to talk")
                        .accessibilityIdentifier("command-drawer-voice-button")
                    }
                    Text("Composed commands pass through CommandPolicy. Blocked commands are rejected.")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .padding(.horizontal)
                .padding(.bottom, 8)
                .transition(.opacity.combined(with: .move(edge: .bottom)))
            }
        }
        .background(Color(.systemBackground))
    }

    private func handlePasteFromClipboard() {
        guard let text = UIPasteboard.general.string, !text.isEmpty else { return }
        container.terminalController.handlePasteRequest(text)
    }

    private func submit(_ text: String) {
        let value = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty else { return }
        switch policy.classify(value) {
        case .safe:
            Task { _ = await container.sendValidatedCommand(value + "\n") }
        case .reviewRequired:
            pendingApproval = PendingCommand(command: value)
        case .blocked:
            blockedCommand = value
        }
    }
}

struct TerminalSearchBar: View {
    @ObservedObject var controller: ShhTerminalController
    @Binding var query: String
    let onClose: () -> Void

    @State private var matchText = ""

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass")
                .foregroundStyle(.secondary)
            TextField("Search terminal", text: $query)
                .textFieldStyle(.plain)
                .autocorrectionDisabled()
                .textInputAutocapitalization(.never)
                .onSubmit {
                    next()
                }
                .onChange(of: query) { _, newQuery in
                    updateSummary(for: newQuery)
                }
            if !matchText.isEmpty {
                Text(matchText)
                    .font(.caption2.monospaced())
                    .foregroundStyle(.secondary)
            }
            Button(action: previous) {
                Image(systemName: "chevron.up")
                    .padding(4)
            }
            .disabled(query.isEmpty)
            Button(action: next) {
                Image(systemName: "chevron.down")
                    .padding(4)
            }
            .disabled(query.isEmpty)
            Button(action: onClose) {
                Image(systemName: "xmark.circle.fill")
                    .foregroundStyle(.secondary)
                    .padding(4)
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(Color(.secondarySystemBackground))
    }

    private func next() {
        controller.findNext(query)
        updateSummary(for: query)
    }

    private func previous() {
        controller.findPrevious(query)
        updateSummary(for: query)
    }

    private func updateSummary(for term: String) {
        guard !term.isEmpty else {
            matchText = ""
            controller.clearSearch()
            return
        }
        let (idx, count) = controller.searchMatchSummary(term)
        if count == 0 {
            matchText = "0 / 0"
        } else {
            matchText = "\(idx) / \(count)"
        }
    }
}

struct TerminalAccessoryBar: View {
    @ObservedObject var controller: ShhTerminalController
    @State private var isCtrlActive = false
    @State private var isAltActive = false
    @State private var isShiftActive = false

    private var activeModifiers: KeyModifiers {
        var mods: KeyModifiers = []
        if isCtrlActive { mods.insert(.control) }
        if isAltActive { mods.insert(.option) }
        if isShiftActive { mods.insert(.shift) }
        return mods
    }

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 6) {
                // Esc
                AccessoryKeyButton(title: "Esc") {
                    sendKey(.escape)
                }

                // Tab
                AccessoryKeyButton(title: isShiftActive ? "⇧Tab" : "Tab") {
                    sendKey(.tab(shift: isShiftActive))
                    isShiftActive = false
                }

                // Sticky Ctrl Toggle
                AccessoryToggleKeyButton(title: "Ctrl", isActive: isCtrlActive) {
                    isCtrlActive.toggle()
                }

                // Sticky Alt/Meta Toggle
                AccessoryToggleKeyButton(title: "Alt", isActive: isAltActive) {
                    isAltActive.toggle()
                }

                // Sticky Shift Toggle
                AccessoryToggleKeyButton(title: "⇧", isActive: isShiftActive) {
                    isShiftActive.toggle()
                }

                // Ctrl-C
                AccessoryKeyButton(title: "^C", role: .destructive) {
                    sendKey(.ctrlC)
                }

                // Ctrl-D
                AccessoryKeyButton(title: "^D") {
                    sendKey(.ctrlD)
                }

                // Arrow keys
                HStack(spacing: 3) {
                    AccessoryIconButton(systemImage: "arrow.left") {
                        sendKey(.arrow(.left, modifiers: activeModifiers))
                    }
                    AccessoryIconButton(systemImage: "arrow.up") {
                        sendKey(.arrow(.up, modifiers: activeModifiers))
                    }
                    AccessoryIconButton(systemImage: "arrow.down") {
                        sendKey(.arrow(.down, modifiers: activeModifiers))
                    }
                    AccessoryIconButton(systemImage: "arrow.right") {
                        sendKey(.arrow(.right, modifiers: activeModifiers))
                    }
                }

                // Function keys Menu (F1 - F12)
                Menu {
                    ForEach(1...12, id: \.self) { fn in
                        Button("F\(fn)") {
                            sendKey(.functionKey(fn))
                        }
                    }
                } label: {
                    Text("Fn")
                        .font(.system(.subheadline, design: .monospaced).bold())
                        .padding(.horizontal, 10)
                        .frame(minHeight: 36)
                        .background(Color(.secondarySystemFill), in: RoundedRectangle(cornerRadius: 6))
                        .contentShape(Rectangle())
                }

                // Quick Ctrl+ shortcuts Menu
                Menu {
                    Button("Ctrl-A (Beginning of line)") { sendControl("a") }
                    Button("Ctrl-E (End of line)") { sendControl("e") }
                    Button("Ctrl-K (Kill to end)") { sendControl("k") }
                    Button("Ctrl-U (Kill to start)") { sendControl("u") }
                    Button("Ctrl-W (Kill word back)") { sendControl("w") }
                    Button("Ctrl-L (Clear screen)") { sendControl("l") }
                    Button("Ctrl-R (Reverse search)") { sendControl("r") }
                    Button("Ctrl-Z (Suspend)") { sendControl("z") }
                    Button("Ctrl-\\ (Quit)") { sendControl("\\") }
                } label: {
                    Text("Ctrl+")
                        .font(.system(.subheadline, design: .monospaced))
                        .padding(.horizontal, 8)
                        .frame(minHeight: 36)
                        .background(Color(.secondarySystemFill), in: RoundedRectangle(cornerRadius: 6))
                        .contentShape(Rectangle())
                }
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
        }
        .background(Color(.systemGray6))
    }

    private func sendKey(_ key: TerminalKey) {
        controller.send(key: key)
        if isCtrlActive { isCtrlActive = false }
        if isAltActive { isAltActive = false }
        if isShiftActive { isShiftActive = false }
    }

    private func sendControl(_ char: Character) {
        if let data = TerminalKeyEncoder.control(char) {
            controller.send(raw: data)
        }
        isCtrlActive = false
    }
}

struct AccessoryKeyButton: View {
    let title: String
    var role: ButtonRole? = nil
    let action: () -> Void

    var body: some View {
        Button(role: role, action: action) {
            Text(title)
                .font(.system(.subheadline, design: .monospaced).weight(.medium))
                .padding(.horizontal, 10)
                .frame(minHeight: 36)
                .background(role == .destructive ? Color.red.opacity(0.15) : Color(.secondarySystemFill), in: RoundedRectangle(cornerRadius: 6))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

struct AccessoryToggleKeyButton: View {
    let title: String
    let isActive: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Text(title)
                .font(.system(.subheadline, design: .monospaced).weight(.bold))
                .padding(.horizontal, 10)
                .frame(minHeight: 36)
                .foregroundStyle(isActive ? Color.white : Color.primary)
                .background(isActive ? Color.accentColor : Color(.secondarySystemFill), in: RoundedRectangle(cornerRadius: 6))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

struct AccessoryIconButton: View {
    let systemImage: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: systemImage)
                .font(.subheadline)
                .frame(minWidth: 36, minHeight: 36)
                .background(Color(.secondarySystemFill), in: RoundedRectangle(cornerRadius: 6))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

struct ApprovalSheet: View {
    @EnvironmentObject private var container: AppContainer
    @Environment(\.dismiss) private var dismiss
    let command: String
    var onApproved: (() -> Void)? = nil
    @State private var approved = false
    private let policy = CommandPolicy()
    var body: some View {
        NavigationStack {
            Form {
                Section("Exact command") { Text(command).font(.system(.body, design: .monospaced)).textSelection(.enabled) }
                Toggle("I approve sending this command", isOn: $approved)
            }
            .navigationTitle("Confirm command")
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Send") {
                        Task {
                            if await container.sendValidatedCommand(command + "\n", approved: true) {
                                onApproved?()
                                dismiss()
                            }
                        }
                    }
                    .disabled(!approved || policy.classify(command) == .blocked || container.activeSession?.state != .connected)
                }
            }
        }
    }
}

struct MultiplexerPicker: View {
    @EnvironmentObject private var container: AppContainer
    @Environment(\.dismiss) private var dismiss
    @State private var selected = RemoteMultiplexer.tmux
    @State private var newSessionName = ""
    @State private var autoAttach = false
    @State private var defaultSession = ""
    @State private var hasLoadedPreferences = false
    @State private var preferenceError: String? = nil

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Picker("Multiplexer", selection: $selected) {
                        ForEach(RemoteMultiplexer.allCases, id: \.self) { multiplexer in
                            Text(multiplexer.rawValue.capitalized).tag(multiplexer)
                        }
                    }
                    .pickerStyle(.segmented)
                    .accessibilityLabel("Select multiplexer adapter")
                    .accessibilityIdentifier("multiplexer-adapter-picker")
                }

                if selected == .tmux {
                    tmuxContent
                } else {
                    deferredMultiplexerContent
                }
            }
            .navigationTitle("Remote Multiplexer")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Done") { dismiss() }
                        .accessibilityLabel("Close multiplexer sheet")
                        .accessibilityIdentifier("multiplexer-done-button")
                }
                if selected == .tmux && container.activeSession?.state == .connected {
                    ToolbarItem(placement: .confirmationAction) {
                        Button(action: {
                            Task { await container.refreshTmuxState() }
                        }) {
                            if container.isProbingTmux {
                                ProgressView()
                                    .controlSize(.small)
                            } else {
                                Image(systemName: "arrow.clockwise")
                            }
                        }
                        .disabled(container.isProbingTmux)
                        .accessibilityLabel("Refresh tmux sessions")
                        .accessibilityIdentifier("refresh-tmux-button")
                    }
                }
            }
            .task {
                loadHostPreferences()
                if container.activeSession?.state == .connected {
                    await container.refreshTmuxState()
                }
            }
        }
    }

    @ViewBuilder
    private var tmuxContent: some View {
        // Reconnect banner if reconnecting
        if container.reconnectState.isReconnecting {
            Section {
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text("Reconnecting to remote host...")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                    Spacer()
                    Button("Cancel") {
                        Task { await container.cancelReconnect() }
                    }
                    .font(.caption.bold())
                }
            }
        }

        // Live Status & Version
        Section("Tmux Status") {
            HStack {
                Label {
                    VStack(alignment: .leading, spacing: 2) {
                        switch container.tmuxAvailability {
                        case .available(let version):
                            Text(version)
                                .font(.body.weight(.medium))
                            Text(container.isTmuxServerRunning ? "Server running" : "No server running")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        case .unavailable(let reason):
                            Text("Unavailable")
                                .font(.body.weight(.medium))
                            Text(reason)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                } icon: {
                    if container.tmuxAvailability.isAvailable {
                        Image(systemName: "checkmark.circle.fill")
                            .foregroundStyle(.green)
                    } else {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .foregroundStyle(.orange)
                    }
                }

                Spacer()

                if let activeID = container.activeTmuxSessionID {
                    Text("Active: \(activeID)")
                        .font(.caption.bold())
                        .lineLimit(1)
                        .truncationMode(.tail)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 4)
                        .background(Color.accentColor.opacity(0.15))
                        .cornerRadius(6)
                        .accessibilityLabel("Currently attached to session \(activeID)")
                        .accessibilityIdentifier("current-active-tmux-session")
                }
            }
            .accessibilityElement(children: .combine)
            .accessibilityLabel(tmuxStatusAccessibilityLabel)
            .accessibilityIdentifier("tmux-status-row")

            if let error = container.tmuxError {
                Text(error)
                    .font(.caption)
                    .foregroundStyle(.red)
                    .accessibilityLabel("Tmux error: \(error)")
                    .accessibilityIdentifier("tmux-error-message")
            }
        }

        // Sessions List
        if container.tmuxAvailability.isAvailable {
            Section("Sessions") {
                if container.tmuxSessions.isEmpty {
                    Text(container.isTmuxServerRunning ? "No active tmux sessions found. Create a session below to start." : "No tmux server running. Create a session below to start.")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .accessibilityIdentifier("tmux-empty-sessions-label")
                } else {
                    ForEach(container.tmuxSessions) { session in
                        HStack {
                            VStack(alignment: .leading, spacing: 4) {
                                HStack(spacing: 6) {
                                    Text(session.name)
                                        .font(.headline)
                                        .lineLimit(1)
                                        .truncationMode(.tail)
                                    Text(session.sessionID)
                                        .font(.subheadline.monospaced())
                                        .foregroundStyle(.secondary)
                                        .lineLimit(1)
                                }
                                HStack(spacing: 8) {
                                    Label("\(session.windowsCount) win", systemImage: "macwindow")
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                    Text("•")
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                        .accessibilityHidden(true)
                                    Text(session.isAttached ? "Attached (\(session.attachedClients))" : "Detached")
                                        .font(.caption)
                                        .foregroundStyle(session.isAttached ? .orange : .secondary)
                                    Text("•")
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                        .accessibilityHidden(true)
                                    Text(formatActivityDate(session.lastActivityAt))
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                }
                            }
                            Spacer()
                            if container.isTmuxSessionActive(session) {
                                Label("Attached", systemImage: "checkmark")
                                    .font(.caption.bold())
                                    .foregroundStyle(.green)
                                    .accessibilityLabel("Session \(session.name) is currently attached")
                            } else {
                                Button(session.isAttached ? "Takeover" : "Attach") {
                                    Task {
                                        let success = await container.attachTmuxSession(id: session.sessionID)
                                        if success { dismiss() }
                                    }
                                }
                                .buttonStyle(.bordered)
                                .accessibilityLabel("\(session.isAttached ? "Take over" : "Attach to") session \(session.name), ID \(session.sessionID)")
                                .accessibilityIdentifier("attach-session-\(session.sessionID)")
                            }
                        }
                        .padding(.vertical, 2)
                        .accessibilityElement(children: .contain)
                    }
                }
            }

            // Validated Create Form
            Section("New Session") {
                TextField("Session name", text: $newSessionName)
                    .autocorrectionDisabled()
                    .textInputAutocapitalization(.never)
                    .accessibilityLabel("New session name")
                    .accessibilityIdentifier("new-session-name-field")

                if let hint = createValidationHint {
                    Text(hint.message)
                        .font(.caption)
                        .foregroundStyle(hint.isValid ? Color.secondary : Color.red)
                        .accessibilityIdentifier("create-session-hint")
                }

                Button("Create & Attach") {
                    Task {
                        let success = await container.createTmuxSession(name: newSessionName)
                        if success {
                            newSessionName = ""
                            dismiss()
                        }
                    }
                }
                .disabled(!isSessionNameValid || container.activeSession?.state != .connected)
                .accessibilityLabel("Create and attach session \(newSessionName)")
                .accessibilityIdentifier("create-session-button")
            }
        }

        // Host Auto-Attach Preference
        if container.activeHost != nil {
            Section("Host Preference") {
                Toggle("Auto-attach on connect", isOn: $autoAttach)
                    .onChange(of: autoAttach) { _, _ in
                        savePreferences()
                    }
                    .accessibilityLabel("Auto-attach to tmux on connect")
                    .accessibilityIdentifier("sheet-auto-attach-toggle")

                TextField("Default session name/ID", text: $defaultSession)
                    .autocorrectionDisabled()
                    .textInputAutocapitalization(.never)
                    .onChange(of: defaultSession) { _, _ in
                        savePreferences()
                    }
                    .accessibilityLabel("Default session name or ID")
                    .accessibilityIdentifier("sheet-default-session-field")

                if let err = preferenceError {
                    Text(err)
                        .font(.caption)
                        .foregroundStyle(.red)
                        .accessibilityLabel("Default session error: \(err)")
                        .accessibilityIdentifier("default-session-error")
                }
            }
        }
    }

    @ViewBuilder
    private var deferredMultiplexerContent: some View {
        Section {
            VStack(alignment: .leading, spacing: 8) {
                Label("\(selected.rawValue.capitalized) is not enabled", systemImage: "clock.arrow.circlepath")
                    .font(.headline)
                    .foregroundStyle(.secondary)
                Text("Multiplexer adapter \(selected.rawValue.capitalized) is visibly unavailable and deferred in this build. Tmux is the supported remote multiplexer.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                Text("Zellij, Byobu, Screen, and Herdr remain deferred pending terminal multiplexing contracts.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .padding(.vertical, 4)
            .accessibilityIdentifier("deferred-multiplexer-notice")
        }
    }

    private var tmuxStatusAccessibilityLabel: String {
        switch container.tmuxAvailability {
        case .available(let version):
            return "Tmux \(version), \(container.isTmuxServerRunning ? "server running" : "no server running")"
        case .unavailable(let reason):
            return "Tmux unavailable: \(reason)"
        }
    }

    private func formatActivityDate(_ date: Date) -> String {
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .abbreviated
        return formatter.localizedString(for: date, relativeTo: Date())
    }

    private var isSessionNameValid: Bool {
        let trimmed = newSessionName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return false }
        return (try? TmuxSessionName(trimmed)) != nil
    }

    private var createValidationHint: (message: String, isValid: Bool)? {
        let trimmed = newSessionName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        do {
            _ = try TmuxSessionName(trimmed)
            return ("Valid session name", true)
        } catch let error as TmuxSessionNameError {
            return (error.localizedDescription, false)
        } catch {
            return ("Invalid session name", false)
        }
    }

    private func loadHostPreferences() {
        guard !hasLoadedPreferences, let host = container.activeHost else { return }
        autoAttach = host.autoAttachTmux
        defaultSession = host.defaultTmuxSession ?? ""
        hasLoadedPreferences = true
    }

    private func savePreferences() {
        guard hasLoadedPreferences, container.activeHost != nil else { return }
        let trimmed = defaultSession.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmed.isEmpty {
            if trimmed.hasPrefix("$") {
                if (try? TmuxSessionID(trimmed)) == nil {
                    preferenceError = "Invalid session ID format. Must begin with $ followed by digits."
                    return
                }
            } else {
                do {
                    _ = try TmuxSessionName(trimmed)
                } catch {
                    preferenceError = error.localizedDescription
                    return
                }
            }
        }
        preferenceError = nil
        Task {
            try? await container.updateActiveHostPreferences(
                autoAttachTmux: autoAttach,
                defaultTmuxSession: trimmed.isEmpty ? nil : trimmed
            )
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
struct MonitoringView: View { var body: some View { List { Label("Health checks are opt-in", systemImage: "heart.text.square"); Label("Unknown is not authentication success", systemImage: "info.circle"); Label("Live monitoring is foreground-only", systemImage: "iphone") }.navigationTitle("Monitoring") } }
struct SettingsView: View {
    @EnvironmentObject private var container: AppContainer
    var body: some View {
        Form {
            Section("Voice & Local AI") {
                NavigationLink {
                    VoiceSettingsView().environmentObject(container)
                } label: {
                    HStack {
                        Label("Voice & Local AI", systemImage: "waveform.and.mic")
                        Spacer()
                        Text(container.selectedProviderDisplayName)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                .accessibilityIdentifier("settings-voice-navigation-link")
            }
            Section("Security") {
                Toggle("Require biometric presence (hook)", isOn: .constant(false))
                Label("Keychain accessibility: when unlocked, this device only", systemImage: "key.fill")
            }
            Section("Capabilities") {
                Text("ProxyJump, forwarding, SFTP, and live SSH active. Mosh and non-tmux multiplexers: not enabled in this build. WhisperKit and Apple Speech voice transcription: active.")
                    .font(.caption)
            }
            Section("Privacy") {
                Text("Zero transcript analytics. All speech processing is 100% on-device. Audio files are deleted immediately after transcription.")
                    .font(.caption)
            }
        }
        .navigationTitle("Settings")
    }
}
