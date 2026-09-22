import ShhCore
import ShhSSH
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
                .appDynamicTypeRange()
                .environmentObject(container)
                .onChange(of: scenePhase) { _, newPhase in
                    container.handleScenePhaseChange(newPhase)
                }
                .preferredColorScheme(preferredColorScheme(for: container.appearance))
        }
    }
}

private func preferredColorScheme(for appearance: AppearanceSetting) -> ColorScheme? {
    switch appearance {
    case .system: return nil
    case .light: return .light
    case .dark: return .dark
    }
}

extension View {
    @ViewBuilder func tagChip() -> some View { self.font(.caption2).padding(.horizontal, 5).padding(.vertical, 2).background(Color.accentColor.opacity(0.15), in: Capsule()) }
}

enum AppSection: String, CaseIterable, Identifiable {
    case hosts = "Hosts", sessions = "Sessions", files = "Files", keys = "Keys", snippets = "Snippets", monitoring = "Monitoring", settings = "Settings"
    var id: String { rawValue }
    var systemImage: String {
        switch self {
        case .hosts: "server.rack"
        case .sessions: "rectangle.split.2x1"
        case .files: "folder"
        case .keys: "key.fill"
        case .snippets: "text.badge.plus"
        case .monitoring: "waveform.path.ecg"
        case .settings: "gear"
        }
    }
}

struct RootView: View {
    @EnvironmentObject private var container: AppContainer
    @State private var section: AppSection? = .hosts

    init() {
        if ProcessInfo.processInfo.arguments.contains("--keys") {
            _section = State(initialValue: .keys)
        } else {
            _section = State(initialValue: .hosts)
        }
    }

    var body: some View {
        NavigationSplitView {
            List(AppSection.allCases, selection: $section) { item in
                NavigationLink(value: item) {
                    Label(item.rawValue, systemImage: item.systemImage)
                }
            }
            .navigationTitle("Shh")
        } detail: {
            NavigationStack {
                switch section ?? .hosts {
                case .hosts: HostListView()
                case .sessions: SessionDashboardView()
                case .files: FilesView()
                case .keys: KeyManagementView()
                case .snippets: SnippetsView()
                case .monitoring: MonitoringView()
                case .settings: SettingsView()
                }
            }
        }
        .hostKeyApprovalAlert(container: container)
        .appDynamicTypeRange()
    }
}

struct HostListView: View {
    @EnvironmentObject private var container: AppContainer
    @State private var hosts: [Host] = []
    @State private var search = ""
    @State private var showingEditor = false
    @State private var healthyOnly = false
    @State private var selectedDiscoveredService: DiscoveredSSHService? = nil

    init() {
        if ProcessInfo.processInfo.arguments.contains("--new-host") {
            _showingEditor = State(initialValue: true)
        }
    }
    private var filtered: [Host] { hosts.filter { (search.isEmpty || $0.name.localizedCaseInsensitiveContains(search) || $0.address.localizedCaseInsensitiveContains(search)) && (!healthyOnly || $0.health == .healthy) } }
    var body: some View {
        List {
            if let persistenceMessage = container.persistenceReadinessMessage {
                Section {
                    Label(persistenceMessage, systemImage: "externaldrive.badge.exclamationmark")
                        .font(.footnote)
                        .foregroundStyle(.orange)
                        .accessibilityIdentifier("persistence-readiness-warning")
                } header: {
                    Text("Persistence readiness")
                        .appSectionHeader()
                }
            }
            if !container.discoveredSSHServices.isEmpty {
                Section {
                    ForEach(container.discoveredSSHServices) { service in
                        Button {
                            selectedDiscoveredService = service
                            showingEditor = true
                        } label: {
                            HStack(spacing: 12) {
                                Image(systemName: "network")
                                    .font(.body)
                                    .foregroundStyle(.tint)
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(service.name)
                                        .appRowTitle()
                                        .foregroundStyle(.primary)
                                    Text("\(service.hostname):\(service.port)")
                                        .appRowSubtitle()
                                        .lineLimit(1)
                                        .truncationMode(.tail)
                                        .foregroundStyle(.secondary)
                                }
                                Spacer(minLength: 8)
                                Image(systemName: "plus.circle")
                                    .font(.body)
                                    .foregroundStyle(.tint)
                            }
                            .frame(minHeight: 44)
                        }
                        .accessibilityIdentifier("discovered-host-\(service.id)")
                    }
                } header: {
                    HStack(alignment: .top) {
                        Text("Discovered on Local Network")
                            .appSectionHeader()
                            .fixedSize(horizontal: false, vertical: true)
                        if container.bonjourDiscovery.isSearching {
                            Spacer(minLength: 8)
                            ProgressView()
                                .scaleEffect(0.7)
                        }
                    }
                }
            }
            Section {
                ForEach(filtered) { host in
                    NavigationLink(destination: HostDetailView(host: host)) { HostRow(host: host) }
                }
                .onDelete { offsets in
                    let ids = offsets.map { filtered[$0].id }
                    Task {
                        for id in ids { try? await container.deleteHost(id: id) }
                        await reload()
                    }
                }
            } header: {
                Text("Saved hosts")
                    .appSectionHeader()
            }
        }
        .navigationTitle("Hosts")
        .navigationBarTitleDisplayMode(.inline)
        .searchable(
            text: $search,
            placement: .navigationBarDrawer(displayMode: .always),
            prompt: "Search hosts, groups, tags"
        )
        .appDynamicTypeRange()
        .toolbar {
            ToolbarItemGroup(placement: .topBarTrailing) {
                Menu("Filter", systemImage: "line.3.horizontal.decrease.circle") {
                    Toggle("Healthy only", isOn: $healthyOnly)
                }
                Button("Add", systemImage: "plus") { showingEditor = true }
            }
        }
        .sheet(isPresented: $showingEditor, onDismiss: {
            selectedDiscoveredService = nil
            Task { await reload() }
        }) { HostEditorView(prefillService: selectedDiscoveredService).environmentObject(container) }
        .onAppear {
            container.bonjourDiscovery.startDiscovery()
        }
        .onDisappear {
            container.bonjourDiscovery.stopDiscovery()
        }
        .task {
            await reload()
            if ProcessInfo.processInfo.arguments.contains("--new-host") {
                showingEditor = true
            }
        }
        .onChange(of: container.catalogUpdateToken) { _, _ in
            Task { await reload() }
        }
    }
    private func reload() async { hosts = (try? await container.catalog.listHosts()) ?? [] }
}

struct HostRow: View {
    let host: Host
    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: "server.rack")
                .font(.body)
                .foregroundStyle(.tint)
            VStack(alignment: .leading, spacing: 2) {
                Text(host.name)
                    .appRowTitle()
                Text(host.address)
                    .appRowSubtitle()
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .foregroundStyle(.secondary)
                HStack {
                    if host.groupID != nil { Text("Group").tagChip() }
                    if !host.tagIDs.isEmpty {
                        Text("\(host.tagIDs.count) tag\(host.tagIDs.count == 1 ? "" : "s")").tagChip()
                    }
                }
            }
            Spacer(minLength: 8)
            Text(host.health.label)
                .appRowMetadata()
                .foregroundStyle(host.health == .healthy ? Color.green : Color.secondary)
                .accessibilityLabel("Health \(host.health.label)")
                .layoutPriority(1)
        }
        .frame(minHeight: 44)
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
            if let failure = container.lastConnectionFailure,
               (container.activeSession?.hostID == host.id || container.activeHost?.id == host.id) {
                Section {
                    ConnectionFailureCard(
                        failure: failure,
                        onRetry: { Task { await container.connect(to: host) } },
                        onEdit: { showEditor = true }
                    )
                }
                .listRowInsets(EdgeInsets())
                .listRowBackground(Color.clear)
            }

            Section {
                Button("Connect", systemImage: "bolt.horizontal") { Task { await container.connect(to: host) } }
                    .disabled(isConnectDisabled)
                Button("Edit", systemImage: "pencil") { showEditor = true }
            }
        }
        .navigationTitle(host.name)
        .navigationBarTitleDisplayMode(.inline)
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
            return container.isDemo ? "Mosh (demo adapter)" : "Mosh (UDP)"
        case .cloudflareAccess:
            return "Cloudflare Access"
        case .tailscale:
            return "Tailscale SSH"
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

struct ConnectionFailureCard: View {
    let failure: ConnectionFailure
    let onRetry: () -> Void
    let onEdit: () -> Void
    @State private var copied = false

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 8) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundStyle(.red)
                    .font(.title3)
                Text("Connection failed")
                    .font(.headline.bold())
                    .foregroundStyle(.red)
                Spacer()
                Text(failure.stage.rawValue)
                    .font(.caption2.bold())
                    .padding(.horizontal, 8)
                    .padding(.vertical, 3)
                    .background(Color.red.opacity(0.12))
                    .foregroundStyle(.red)
                    .clipShape(Capsule())
            }

            VStack(alignment: .leading, spacing: 4) {
                Text("Why it failed")
                    .font(.caption.bold())
                    .foregroundStyle(.secondary)
                Text(failure.reason)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.primary)
                if !failure.technicalDetail.isEmpty {
                    Text(failure.technicalDetail)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }

            VStack(alignment: .leading, spacing: 4) {
                Text("What to try")
                    .font(.caption.bold())
                    .foregroundStyle(.secondary)
                Text(failure.recoveryAction)
                    .font(.caption)
                    .foregroundStyle(.primary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Divider()

            HStack(spacing: 12) {
                Button(action: onRetry) {
                    Label("Retry", systemImage: "arrow.clockwise")
                        .font(.caption.bold())
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.small)

                Button(action: onEdit) {
                    Label("Edit Host", systemImage: "pencil")
                        .font(.caption)
                }
                .buttonStyle(.bordered)
                .controlSize(.small)

                Spacer()

                Button {
                    UIPasteboard.general.string = failure.copyableDiagnostics
                    copied = true
                    Task {
                        try? await Task.sleep(nanoseconds: 2_000_000_000)
                        copied = false
                    }
                } label: {
                    Label(copied ? "Copied!" : "Copy Diagnostics", systemImage: copied ? "checkmark" : "doc.on.doc")
                        .font(.caption)
                }
                .buttonStyle(.borderless)
                .controlSize(.small)
            }
        }
        .padding(14)
        .background(Color(uiColor: .secondarySystemGroupedBackground))
        .clipShape(RoundedRectangle(cornerRadius: 12))
        .overlay(
            RoundedRectangle(cornerRadius: 12)
                .stroke(Color.red.opacity(0.25), lineWidth: 1)
        )
    }
}

enum HostConnectionType: String, CaseIterable, Identifiable {
    case direct = "Direct SSH"
    case proxyJump = "ProxyJump Bastion"
    case mosh = "Mosh (UDP)"
    case cloudflareAccess = "Cloudflare Access"
    case tailscale = "Tailscale SSH"
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
    let prefillService: DiscoveredSSHService?
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
    @State private var autoAttachTmux: Bool
    @State private var enableVoice: Bool
    @State private var allowShellCommand: Bool
    @State private var allowAgentMessage: Bool
    @State private var allowInsertOnly: Bool
    @State private var isProductionHost: Bool
    @State private var identities: [IdentityDescriptor] = []
    @State private var showingNewKeySheet = false

    // Mosh settings
    @State private var moshServerCommand: String
    @State private var moshUseCustomPortRange: Bool
    @State private var moshPortRangeStart: String
    @State private var moshPortRangeEnd: String
    @State private var moshPredictionMode: MoshPredictionMode

    // Cloudflare Access settings
    @State private var cloudflareClientID: String
    @State private var cloudflareClientSecret: String
    @State private var cloudflareClientSecretKeychainRef: String
    @State private var cloudflareTunnelDomain: String

    // Tailscale SSH settings
    @State private var tailscaleHostname: String
    @State private var tailscaleCheckHostKey: Bool

    init(existing: Host? = nil, prefillService: DiscoveredSSHService? = nil) {
        self.existing = existing
        self.prefillService = prefillService
        _name = State(initialValue: prefillService?.name ?? existing?.name ?? "")
        _hostname = State(initialValue: prefillService?.hostname ?? existing?.hostname ?? "")
        _username = State(initialValue: existing?.username ?? "")
        let portValue: Int
        if let p = prefillService?.port {
            portValue = Int(p)
        } else if let p = existing?.port {
            portValue = Int(p)
        } else {
            portValue = 22
        }
        _port = State(initialValue: "\(portValue)")
        _identityID = State(initialValue: existing?.identityID)

        let initialType: HostConnectionType
        let initialBastions: [UUID]
        if case .proxyJump(let jumpOpts) = existing?.connection {
            initialType = .proxyJump
            initialBastions = jumpOpts.config.hostIDs
            _moshServerCommand = State(initialValue: "mosh-server")
            _moshUseCustomPortRange = State(initialValue: false)
            _moshPortRangeStart = State(initialValue: "60001")
            _moshPortRangeEnd = State(initialValue: "60999")
            _moshPredictionMode = State(initialValue: .adaptive)
            _cloudflareClientID = State(initialValue: "")
            _cloudflareClientSecret = State(initialValue: "")
            _cloudflareClientSecretKeychainRef = State(initialValue: "")
            _cloudflareTunnelDomain = State(initialValue: "")
            _tailscaleHostname = State(initialValue: "")
            _tailscaleCheckHostKey = State(initialValue: false)
        } else if case .mosh(let moshOpts) = existing?.connection {
            initialType = .mosh
            initialBastions = []
            _moshServerCommand = State(initialValue: moshOpts.serverCommand)
            _moshUseCustomPortRange = State(initialValue: moshOpts.portRange != nil)
            _moshPortRangeStart = State(initialValue: moshOpts.portRange.map { String($0.start) } ?? "60001")
            _moshPortRangeEnd = State(initialValue: moshOpts.portRange.map { String($0.end) } ?? "60999")
            _moshPredictionMode = State(initialValue: moshOpts.predictionMode)
            _cloudflareClientID = State(initialValue: "")
            _cloudflareClientSecret = State(initialValue: "")
            _cloudflareClientSecretKeychainRef = State(initialValue: "")
            _cloudflareTunnelDomain = State(initialValue: "")
            _tailscaleHostname = State(initialValue: "")
            _tailscaleCheckHostKey = State(initialValue: false)
        } else if case .cloudflareAccess(let cfOpts) = existing?.connection {
            initialType = .cloudflareAccess
            initialBastions = []
            _moshServerCommand = State(initialValue: "mosh-server")
            _moshUseCustomPortRange = State(initialValue: false)
            _moshPortRangeStart = State(initialValue: "60001")
            _moshPortRangeEnd = State(initialValue: "60999")
            _moshPredictionMode = State(initialValue: .adaptive)
            _cloudflareClientID = State(initialValue: cfOpts.clientID)
            _cloudflareClientSecret = State(initialValue: "")
            _cloudflareClientSecretKeychainRef = State(initialValue: cfOpts.clientSecretKeychainRef)
            _cloudflareTunnelDomain = State(initialValue: cfOpts.tunnelDomain)
            _tailscaleHostname = State(initialValue: "")
            _tailscaleCheckHostKey = State(initialValue: false)
        } else if case .tailscale(let tsOpts) = existing?.connection {
            initialType = .tailscale
            initialBastions = []
            _moshServerCommand = State(initialValue: "mosh-server")
            _moshUseCustomPortRange = State(initialValue: false)
            _moshPortRangeStart = State(initialValue: "60001")
            _moshPortRangeEnd = State(initialValue: "60999")
            _moshPredictionMode = State(initialValue: .adaptive)
            _cloudflareClientID = State(initialValue: "")
            _cloudflareClientSecret = State(initialValue: "")
            _cloudflareClientSecretKeychainRef = State(initialValue: "")
            _cloudflareTunnelDomain = State(initialValue: "")
            _tailscaleHostname = State(initialValue: tsOpts.tailscaleHostname)
            _tailscaleCheckHostKey = State(initialValue: tsOpts.checkHostKey)
        } else {
            initialType = .direct
            initialBastions = []
            _moshServerCommand = State(initialValue: "mosh-server")
            _moshUseCustomPortRange = State(initialValue: false)
            _moshPortRangeStart = State(initialValue: "60001")
            _moshPortRangeEnd = State(initialValue: "60999")
            _moshPredictionMode = State(initialValue: .adaptive)
            _cloudflareClientID = State(initialValue: "")
            _cloudflareClientSecret = State(initialValue: "")
            _cloudflareClientSecretKeychainRef = State(initialValue: "")
            _cloudflareTunnelDomain = State(initialValue: "")
            _tailscaleHostname = State(initialValue: "")
            _tailscaleCheckHostKey = State(initialValue: false)
        }
        _connectionType = State(initialValue: initialType)
        _bastionHops = State(initialValue: initialBastions.map { BastionHopItem(hostID: $0) })
        _forwardingRules = State(initialValue: existing?.forwardingRules ?? [])

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

    /// Identities sorted alphabetically by name with UUID tie-breaking.
    private var pickerIdentities: [IdentityDescriptor] {
        identities.sorted {
            let nameOrder = $0.name.localizedCaseInsensitiveCompare($1.name)
            return nameOrder == .orderedSame ? $0.id.uuidString < $1.id.uuidString : nameOrder == .orderedAscending
        }
    }

    /// Disambiguates identities with identical names by appending their
    /// public key fingerprint suffix.
    private func identityLabel(_ identity: IdentityDescriptor) -> String {
        let duplicateName = identities.filter { $0.name.caseInsensitiveCompare(identity.name) == .orderedSame }.count > 1
        guard duplicateName, let fingerprint = identity.publicFingerprint else { return identity.name }
        return "\(identity.name) (\(fingerprint.suffix(8)))"
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
                if !container.discoveredSSHServices.isEmpty {
                    Section {
                        ForEach(container.discoveredSSHServices) { service in
                            Button {
                                name = service.name
                                hostname = service.hostname
                                port = String(service.port)
                            } label: {
                                HStack {
                                    VStack(alignment: .leading, spacing: 2) {
                                        Text(service.name)
                                            .appRowTitle()
                                            .foregroundStyle(.primary)
                                        Text("\(service.hostname):\(service.port)")
                                            .appRowSubtitle()
                                            .foregroundStyle(.secondary)
                                    }
                                    Spacer()
                                    Image(systemName: "arrow.down.circle")
                                        .foregroundStyle(Color.accentColor)
                                }
                            }
                            .accessibilityIdentifier("discovered-service-\(service.id)")
                        }
                    } header: {
                        HStack {
                            Text("Discovered on Local Network")
                            if container.bonjourDiscovery.isSearching {
                                Spacer()
                                ProgressView()
                                    .scaleEffect(0.7)
                            }
                        }
                    }
                }

                Section("Host metadata") {
                    TextField("Name", text: $name)
                        .autocorrectionDisabled()
                        .textInputAutocapitalization(.never)
                        .accessibilityIdentifier("host-editor-name-field")
                    TextField("Hostname", text: $hostname)
                        .autocorrectionDisabled()
                        .textInputAutocapitalization(.never)
                        .accessibilityIdentifier("host-editor-hostname-field")
                    TextField("Username", text: $username)
                        .autocorrectionDisabled()
                        .textInputAutocapitalization(.never)
                        .accessibilityIdentifier("host-editor-username-field")
                    TextField("Port", text: $port).keyboardType(.numberPad)
                        .autocorrectionDisabled()
                        .textInputAutocapitalization(.never)
                        .accessibilityIdentifier("host-editor-port-field")
                    HStack {
                        Picker("Identity", selection: $identityID) {
                            Text("None").tag(UUID?.none)
                            if let selectedID = identityID,
                               !identities.contains(where: { $0.id == selectedID }) {
                                Text("Missing identity (\(selectedID.uuidString.prefix(8)))")
                                    .tag(Optional(selectedID))
                            }
                            ForEach(pickerIdentities) { identity in
                                Text(identityLabel(identity)).tag(Optional(identity.id))
                            }
                        }
                        .accessibilityIdentifier("host-editor-identity-picker")

                        Button("New Key", systemImage: "plus") {
                            showingNewKeySheet = true
                        }
                        .buttonStyle(.borderless)
                        .accessibilityIdentifier("host-editor-new-key-button")
                    }
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
                    } else if connectionType == .mosh {
                        TextField("Mosh Server Command", text: $moshServerCommand)
                            .accessibilityIdentifier("host-editor-mosh-server-command-field")
                            .accessibilityLabel("Mosh server command")
                            .textInputAutocapitalization(.never)
                            .disableAutocorrection(true)

                        Toggle("Custom Port Range", isOn: $moshUseCustomPortRange)
                            .accessibilityIdentifier("host-editor-mosh-port-range-toggle")
                            .accessibilityLabel("Custom UDP port range")

                        if moshUseCustomPortRange {
                            HStack {
                                TextField("Start Port", text: $moshPortRangeStart)
                                    .keyboardType(.numberPad)
                                    .autocorrectionDisabled()
                                    .textInputAutocapitalization(.never)
                                    .accessibilityIdentifier("host-editor-mosh-port-start-field")
                                    .accessibilityLabel("Mosh start port")
                                Text("-")
                                    .foregroundStyle(.secondary)
                                    .accessibilityHidden(true)
                                TextField("End Port", text: $moshPortRangeEnd)
                                    .keyboardType(.numberPad)
                                    .autocorrectionDisabled()
                                    .textInputAutocapitalization(.never)
                                    .accessibilityIdentifier("host-editor-mosh-port-end-field")
                                    .accessibilityLabel("Mosh end port")
                            }
                            if !isMoshPortRangeValid {
                                Text("Port numbers must be between 1 and 65535.")
                                    .font(.caption)
                                    .foregroundStyle(.red)
                                    .accessibilityIdentifier("host-editor-mosh-port-range-error")
                            }
                        }

                        Picker("Prediction Mode", selection: $moshPredictionMode) {
                            ForEach(MoshPredictionMode.allCases, id: \.self) { mode in
                                Text(mode.rawValue.capitalized).tag(mode)
                            }
                        }
                        .accessibilityIdentifier("host-editor-mosh-prediction-picker")
                        .accessibilityLabel("Mosh prediction mode picker")
                    } else if connectionType == .cloudflareAccess {
                        TextField("Tunnel Domain", text: $cloudflareTunnelDomain, prompt: Text("e.g. ssh.example.com"))
                            .accessibilityIdentifier("host-editor-cf-tunnel-domain-field")
                            .accessibilityLabel("Cloudflare Tunnel Domain")
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()

                        TextField("Service Token Client ID", text: $cloudflareClientID, prompt: Text("e.g. xxxxxxxx.access"))
                            .accessibilityIdentifier("host-editor-cf-client-id-field")
                            .accessibilityLabel("Cloudflare Access Client ID")
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()

                        SecureField("Service Token Client Secret", text: $cloudflareClientSecret, prompt: Text("Saved securely to Keychain"))
                            .accessibilityIdentifier("host-editor-cf-client-secret-field")
                            .accessibilityLabel("Cloudflare Access Client Secret")
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                    } else if connectionType == .tailscale {
                        TextField("Tailscale Hostname or IP", text: $tailscaleHostname, prompt: Text("e.g. node.tailscale.net"))
                            .accessibilityIdentifier("host-editor-tailscale-hostname-field")
                            .accessibilityLabel("Tailscale Hostname or IP")
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()

                        Toggle("Strict Host Key Checking", isOn: $tailscaleCheckHostKey)
                            .accessibilityIdentifier("host-editor-tailscale-check-key-toggle")
                            .accessibilityLabel("Check Host Key")
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
                    Toggle("Auto-attach last used tmux session", isOn: $autoAttachTmux)
                        .accessibilityIdentifier("host-editor-auto-attach-toggle")
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
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .navigationTitle(existing == nil ? "New host" : "Edit host")
            .navigationBarTitleDisplayMode(.inline)
            .task {
                identities = (try? await container.catalog.identities()) ?? []
                allHosts = (try? await container.catalog.listHosts()) ?? []
            }
            .sheet(isPresented: $showingAddRule) {
                PortForwardingRuleEditorSheet { newRule in
                    forwardingRules.append(newRule)
                }
            }
            .sheet(isPresented: $showingNewKeySheet) {
                IdentityEditorView { newIdentity in
                    Task {
                        identities = (try? await container.catalog.identities()) ?? []
                        identityID = newIdentity.id
                    }
                }
                .environmentObject(container)
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
                        .disabled(name.isEmpty || hostname.isEmpty || username.isEmpty || (connectionType == .proxyJump && bastionHops.isEmpty) || !isMoshPortRangeValid)
                        .accessibilityIdentifier("host-editor-save-button")
                }
                ToolbarItemGroup(placement: .keyboard) {
                    Spacer()
                    Button {
                        UIApplication.shared.sendAction(#selector(UIResponder.resignFirstResponder), to: nil, from: nil, for: nil)
                    } label: {
                        Label("Dismiss Keyboard", systemImage: "keyboard.chevron.compact.down")
                    }
                    .accessibilityLabel("Dismiss keyboard")
                    .accessibilityIdentifier("host-editor-dismiss-keyboard-button")
                }
            }
        }
        .onAppear {
            container.bonjourDiscovery.startDiscovery()
        }
        .onDisappear {
            container.bonjourDiscovery.stopDiscovery()
        }
        .editorSheetPresentation()
    }

    private var isMoshPortRangeValid: Bool {
        guard connectionType == .mosh && moshUseCustomPortRange else { return true }
        guard let start = UInt16(moshPortRangeStart),
              let end = UInt16(moshPortRangeEnd),
              start > 0, end > 0 else { return false }
        return true
    }

    func buildHost(secretRef: String? = nil) -> Host? {
        guard isMoshPortRangeValid else { return nil }
        if connectionType == .proxyJump && bastionHops.isEmpty { return nil }
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
        } else if case .mosh(let opts) = existing?.connection {
            existingSSH = opts.sshOptions
        } else {
            existingSSH = SSHOptions()
        }

        if connectionType == .proxyJump && !bastionHops.isEmpty {
            let hopHostIDs = bastionHops.map(\.hostID)
            profile = .proxyJump(ProxyJumpOptions(hopHostIDs: hopHostIDs, sshOptions: existingSSH))
        } else if connectionType == .mosh {
            let portRange: MoshPortRange?
            if moshUseCustomPortRange,
               let start = UInt16(moshPortRangeStart),
               let end = UInt16(moshPortRangeEnd) {
                portRange = MoshPortRange(start: start, end: end)
            } else {
                portRange = nil
            }
            let serverCmd = moshServerCommand.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                ? "mosh-server"
                : moshServerCommand.trimmingCharacters(in: .whitespacesAndNewlines)

            profile = .mosh(MoshOptions(
                serverCommand: serverCmd,
                portRange: portRange,
                predictionMode: moshPredictionMode,
                sshOptions: existingSSH
            ))
        } else if connectionType == .cloudflareAccess {
            let effectiveTunnel = cloudflareTunnelDomain.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                ? hostname.trimmingCharacters(in: .whitespacesAndNewlines)
                : cloudflareTunnelDomain.trimmingCharacters(in: .whitespacesAndNewlines)
            let ref = secretRef ?? (cloudflareClientSecretKeychainRef.isEmpty ? "cf-secret-\(UUID().uuidString)" : cloudflareClientSecretKeychainRef)
            profile = .cloudflareAccess(CloudflareAccessOptions(
                clientID: cloudflareClientID.trimmingCharacters(in: .whitespacesAndNewlines),
                clientSecretKeychainRef: ref,
                tunnelDomain: effectiveTunnel
            ))
        } else if connectionType == .tailscale {
            let effectiveTSHostname = tailscaleHostname.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                ? hostname.trimmingCharacters(in: .whitespacesAndNewlines)
                : tailscaleHostname.trimmingCharacters(in: .whitespacesAndNewlines)
            profile = .tailscale(TailscaleOptions(
                tailscaleHostname: effectiveTSHostname,
                checkHostKey: tailscaleCheckHostKey
            ))
        } else {
            profile = .ssh(existingSSH)
        }

        let effectiveHostname: String
        if hostname.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            if connectionType == .tailscale {
                effectiveHostname = tailscaleHostname.trimmingCharacters(in: .whitespacesAndNewlines)
            } else if connectionType == .cloudflareAccess {
                effectiveHostname = cloudflareTunnelDomain.trimmingCharacters(in: .whitespacesAndNewlines)
            } else {
                effectiveHostname = hostname
            }
        } else {
            effectiveHostname = hostname
        }

        guard let portNumber = UInt16(port) else { return nil }
        return try? Host(
            id: existing?.id ?? UUID(),
            name: name,
            hostname: effectiveHostname,
            port: portNumber,
            username: username,
            identityID: identityID,
            connection: profile,
            autoAttachTmux: autoAttachTmux,
            voicePolicy: voicePolicy,
            isProduction: isProductionHost,
            forwardingRules: forwardingRules
        )
    }

    func save() {
        let trimmedSecret = cloudflareClientSecret.trimmingCharacters(in: .whitespacesAndNewlines)
        let secretRef = cloudflareClientSecretKeychainRef.isEmpty ? "cf-secret-\(UUID().uuidString)" : cloudflareClientSecretKeychainRef

        Task {
            if connectionType == .cloudflareAccess && !trimmedSecret.isEmpty {
                try? await container.credentialStore.save(Data(trimmedSecret.utf8), reference: secretRef)
            }
            guard let host = buildHost(secretRef: secretRef) else { return }
            do {
                try await container.saveHost(host)
                dismiss()
            } catch { }
        }
    }
}

struct SessionDashboardView: View {
    @EnvironmentObject private var container: AppContainer
    var body: some View { Group { if container.activeSession != nil { SessionView() } else { ContentUnavailableView("No active sessions", systemImage: "rectangle.split.2x1", description: Text("Connect a host to create a foreground session.")) } }.navigationTitle("Sessions").navigationBarTitleDisplayMode(.inline) }
}

struct PendingCommand: Identifiable {
    let id = UUID()
    let command: String
}

struct SessionView: View {
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
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
    @State private var showTelemetry = false
    @State private var isZenMode: Bool = false
    private let policy = CommandPolicy()

    private func terminalColor(_ value: TerminalColor) -> Color {
        Color(red: Double(value.red) / 255, green: Double(value.green) / 255, blue: Double(value.blue) / 255)
    }

    private var connectionStatusColor: Color {
        if container.isForegroundRecoveryInProgress {
            return .yellow
        }
        switch container.reconnectState {
        case .waiting, .connecting:
            return .yellow
        default:
            switch container.activeSession?.state {
            case .connected:
                return .green
            case .connecting:
                return .yellow
            case .failed, .disconnected, .none:
                return .red
            }
        }
    }

    private var connectionStatusText: String {
        if container.isForegroundRecoveryInProgress {
            return "Checking connection"
        }
        switch container.reconnectState {
        case .waiting:
            return "Reconnecting"
        case .connecting:
            return "Connecting"
        default:
            return container.activeSession?.state.rawValue.capitalized ?? "Disconnected"
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            // Live Network Roaming Recovery Indicator Banner
            roamingRecoveryBanner

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

            // Connection Failure Banner (if failed)
            if let failure = container.lastConnectionFailure, container.activeSession?.state == .failed {
                ConnectionFailureCard(
                    failure: failure,
                    onRetry: {
                        if let host = container.activeHost {
                            Task { await container.connect(to: host) }
                        }
                    },
                    onEdit: {}
                )
                .padding()
            }

            // Terminal Surface (Production SwiftTerm, or iPadOS Side-by-Side Split View)
            if horizontalSizeClass == .regular && container.secondaryPaneMode != .none {
                splitPaneArea
            } else {
                terminalSurfaceArea
            }

            // Extra-key accessory bar (always accessible above drawer)
            TerminalAccessoryBar(controller: container.terminalController)
            Divider()

            // Collapsible Validated-Command Drawer
            commandDrawer
        }
        .navigationTitle(container.terminalController.title.isEmpty ? "Terminal" : container.terminalController.title)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar(isZenMode ? .hidden : .visible, for: .navigationBar)
        .navigationBarHidden(isZenMode)
        .toolbar {
            ToolbarItem(placement: .principal) {
                HStack(spacing: 6) {
                    Circle()
                        .fill(connectionStatusColor)
                        .frame(width: 8, height: 8)
                        .accessibilityLabel(connectionStatusText)

                    if let host = container.activeHost {
                        Text(host.name)
                            .font(.subheadline.weight(.semibold))
                            .lineLimit(1)
                        if horizontalSizeClass != .compact {
                            Text("\(host.username)@\(host.hostname)")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                        }
                    } else {
                        Text(container.terminalController.title.isEmpty ? "Terminal" : container.terminalController.title)
                            .font(.subheadline.weight(.semibold))
                            .lineLimit(1)
                    }

                    if let moshState = container.moshState, moshState.isRoaming {
                        Label("Roaming", systemImage: "arrow.triangle.2.circlepath")
                            .font(.caption2.bold())
                            .foregroundStyle(.orange)
                            .lineLimit(1)
                            .accessibilityLabel("Network roaming re-syncing")
                            .accessibilityIdentifier("mosh-roaming-indicator")
                    } else if container.activeSession?.state == .connected,
                              (container.moshState == nil || container.moshState?.isConnected == true),
                              let port = container.moshSessionPort {
                        Label("UDP :\(port)", systemImage: "bolt.horizontal.fill")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                            .accessibilityLabel("Connected via Mosh UDP port \(port)")
                            .accessibilityIdentifier("mosh-connected-indicator")
                    }

                    if container.activeForwardersCount > 0 {
                        Button(action: {
                            showPortForwarding = true
                        }) {
                            Label("\(container.activeForwardersCount)", systemImage: "arrow.triangle.swap")
                                .font(.caption2.bold())
                                .foregroundStyle(Color.accentColor)
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel("\(container.activeForwardersCount) active port forwarder\(container.activeForwardersCount == 1 ? "" : "s")")
                        .accessibilityIdentifier("session-forwarders-indicator")
                    }

                    if let errorMsg = container.forwardingErrorMessage {
                        Button(action: {
                            showPortForwarding = true
                        }) {
                            Image(systemName: "exclamationmark.triangle.fill")
                                .font(.caption2.bold())
                                .foregroundStyle(.orange)
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel("Port forwarding alert: \(errorMsg)")
                        .accessibilityIdentifier("session-forwarders-error-indicator")
                    }
                }
            }

            ToolbarItemGroup(placement: .primaryAction) {
                if horizontalSizeClass != .compact {
                    Button(action: {
                        isSearchPresented.toggle()
                        if !isSearchPresented {
                            searchQuery = ""
                            container.terminalController.clearSearch()
                        }
                    }) {
                        Image(systemName: "magnifyingglass")
                    }
                    .accessibilityLabel(isSearchPresented ? "Close search" : "Search terminal")

                    Button(action: {
                        container.terminalController.recoverFirstResponder()
                    }) {
                        Image(systemName: "keyboard")
                            .foregroundStyle(container.terminalController.isFirstResponder ? Color.primary : Color.accentColor)
                    }
                    .accessibilityLabel("Recover keyboard focus")
                }

                Button(action: {
                    container.resetVoiceState()
                    showVoice = true
                }) {
                    Image(systemName: "mic")
                        .foregroundStyle(container.activeHost?.isVoiceEnabled == true ? Color.accentColor : Color.secondary)
                }
                .accessibilityLabel("Voice command")
                .accessibilityIdentifier("session-header-voice-button")
                .disabled(container.activeSession?.state != .connected)

                Menu {
                    if horizontalSizeClass == .compact {
                        Button(action: {
                            isSearchPresented.toggle()
                            if !isSearchPresented {
                                searchQuery = ""
                                container.terminalController.clearSearch()
                            }
                        }) {
                            Label("Search Terminal", systemImage: "magnifyingglass")
                        }

                        Button(action: {
                            container.terminalController.recoverFirstResponder()
                        }) {
                            Label("Recover Keyboard Focus", systemImage: "keyboard")
                        }

                        Divider()
                    }

                    Menu {
                        Button(action: {
                            container.terminalController.increaseTerminalFontSize()
                        }) {
                            Label("Increase Size (Cmd +)", systemImage: "plus")
                        }
                        .disabled(container.terminalController.terminalFontSize >= TerminalFontSize.maximumPointSize)

                        Button(action: {
                            container.terminalController.decreaseTerminalFontSize()
                        }) {
                            Label("Decrease Size (Cmd -)", systemImage: "minus")
                        }
                        .disabled(container.terminalController.terminalFontSize <= TerminalFontSize.minimumPointSize)

                        Button(action: {
                            container.terminalController.resetTerminalFontSize()
                        }) {
                            Label("Reset Size (Cmd 0)", systemImage: "arrow.counterclockwise")
                        }

                        Divider()

                        ForEach([6, 8, 10, 12, 14, 16, 18], id: \.self) { preset in
                            Button(action: {
                                container.terminalController.setTerminalFontSize(Double(preset))
                            }) {
                                let percentage = TerminalFontSize.percentage(for: Double(preset))
                                if Int(container.terminalController.terminalFontSize.rounded()) == preset {
                                    Label("\(preset) pt (\(percentage)%)", systemImage: "checkmark")
                                } else {
                                    Text("\(preset) pt (\(percentage)%)")
                                }
                            }
                        }
                    } label: {
                        Label("Text Size (\(container.terminalController.terminalFontSizePercentage)%)", systemImage: "textformat.size")
                    }

                    Divider()

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
                        Label("Paste", systemImage: "doc.on.clipboard")
                    }

                    Divider()

                    Button(action: {
                        withAnimation {
                            isZenMode = true
                        }
                    }) {
                        Label("Zen Mode (Full Screen)", systemImage: "arrow.up.left.and.arrow.down.right")
                    }
                    .accessibilityIdentifier("open-zen-mode-button")
                    .accessibilityLabel("Enter Zen Mode full screen")

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
                        Label("Port Forwarding", systemImage: "arrow.triangle.swap")
                    }
                    .accessibilityIdentifier("open-port-forwarding-button")
                    .accessibilityLabel("Open port forwarding sheet")

                    Button(action: {
                        showTelemetry = true
                    }) {
                        Label("Server Telemetry", systemImage: "gauge.with.dots.needle.bottom.50percent")
                    }
                    .accessibilityIdentifier("open-telemetry-button")
                    .accessibilityLabel("Open server telemetry monitoring sheet")

                    if horizontalSizeClass == .regular {
                        Divider()

                        Menu {
                            Button(action: {
                                if let host = container.activeHost {
                                    container.openSecondarySFTP(for: host)
                                }
                            }) {
                                Label("Split with SFTP Browser", systemImage: "folder")
                            }
                            .disabled(container.activeHost == nil)
                            .accessibilityIdentifier("split-with-sftp-button")

                            if container.secondaryPaneMode != .none {
                                Button(action: {
                                    container.closeSecondaryPane()
                                }) {
                                    Label("Close Split View", systemImage: "xmark")
                                }
                                .accessibilityIdentifier("close-split-view-button")
                            }
                        } label: {
                            Label("Split View", systemImage: "rectangle.split.2x1")
                        }
                        .accessibilityIdentifier("split-view-menu")
                    }

                    Divider()

                    Button("Disconnect", role: .destructive) {
                        Task { await container.disconnect() }
                    }
                } label: {
                    Image(systemName: "ellipsis.circle")
                }
                .accessibilityLabel("Session tools")
            }
        }
        .sheet(isPresented: $showMultiplexer) { MultiplexerPicker().environmentObject(container).presentationDetents([.medium, .large]) }
        .sheet(isPresented: $showVoice) { VoiceComposer().environmentObject(container).presentationDetents([.medium, .large]) }
        .sheet(isPresented: $showPortForwarding) { PortForwardingSheet().environmentObject(container).presentationDetents([.medium, .large]) }
        .sheet(isPresented: $showTelemetry) { ServerTelemetrySheet().environmentObject(container).presentationDetents([.medium]) }
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
        .overlay(alignment: .topTrailing) {
            if isZenMode {
                Button(action: {
                    withAnimation {
                        isZenMode = false
                    }
                }) {
                    Image(systemName: "arrow.down.right.and.arrow.up.left")
                        .font(.body.weight(.semibold))
                        .foregroundStyle(.primary.opacity(0.85))
                        .padding(.horizontal, 10)
                        .padding(.vertical, 6)
                        .background(.ultraThinMaterial, in: Capsule())
                        .shadow(color: .black.opacity(0.15), radius: 4, x: 0, y: 2)
                }
                .buttonStyle(.plain)
                .padding(.top, 8)
                .padding(.trailing, 12)
                .transition(.opacity.combined(with: .scale(scale: 0.9)))
                .accessibilityIdentifier("exit-zen-mode-button")
                .accessibilityLabel("Exit Zen Mode")
            }
        }
        .onAppear {
            container.terminalController.onRiskyPasteRequested = { text in
                pendingRiskyPaste = text
            }
        }
    }

    @ViewBuilder
    private var roamingRecoveryBanner: some View {
        if let moshState = container.moshState, moshState.isRoaming {
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 8) {
                    ProgressView()
                        .controlSize(.small)
                    Text("Network Roaming - Re-syncing")
                        .font(.caption.bold())
                        .foregroundStyle(.primary)
                    if let iface = container.networkRoamingState?.currentInterface {
                        Text("(\(iface.displayName))")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                }
                VStack(alignment: .leading, spacing: 4) {
                    HStack(spacing: 8) {
                        ProgressView()
                            .controlSize(.small)
                        Text("Network Roaming - Re-syncing")
                            .font(.caption.bold())
                            .foregroundStyle(.primary)
                    }
                    if let iface = container.networkRoamingState?.currentInterface {
                        Text("Interface: \(iface.displayName)")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            }
            .padding(.horizontal)
            .padding(.vertical, 6)
            .background(Color.orange.opacity(0.15))
            .accessibilityElement(children: .combine)
            .accessibilityLabel("Network roaming re-syncing to \(container.networkRoamingState?.currentInterface.displayName ?? "new interface")")
            .accessibilityIdentifier("mosh-roaming-banner")
            Divider()
        }
    }

    @ViewBuilder
    private var reconnectBanner: some View {
        if container.isForegroundRecoveryInProgress {
            HStack(spacing: 8) {
                ProgressView()
                    .controlSize(.small)
                Text("Checking connection after returning to the foreground...")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
            }
            .padding(.horizontal)
            .padding(.vertical, 6)
            .background(Color.yellow.opacity(0.15))
            .accessibilityElement(children: .combine)
            .accessibilityLabel("Checking connection after returning to the foreground")
            .accessibilityIdentifier("foreground-recovery-banner")
        } else {
            switch container.reconnectState {
        case .waiting(let attempt, let delay):
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 8) {
                    ProgressView()
                        .controlSize(.small)
                    Text("Reconnecting (attempt \(attempt)/\(ReconnectCoordinator.maxAttempts)) in \(Int(ceil(delay)))s...")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Spacer()
                    Button("Retry Now") {
                        Task { await container.retryReconnect() }
                    }
                    .font(.caption.bold())
                    .accessibilityIdentifier("reconnect-retry-button")
                    .accessibilityLabel("Retry connection immediately")

                    Button("Cancel") {
                        Task { await container.cancelReconnect() }
                    }
                    .font(.caption.bold())
                    .foregroundStyle(.secondary)
                    .accessibilityIdentifier("reconnect-cancel-button")
                    .accessibilityLabel("Cancel reconnection")
                }
                VStack(alignment: .leading, spacing: 6) {
                    HStack(spacing: 8) {
                        ProgressView()
                            .controlSize(.small)
                        Text("Reconnecting (attempt \(attempt)/\(ReconnectCoordinator.maxAttempts)) in \(Int(ceil(delay)))s...")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    HStack(spacing: 12) {
                        Button("Retry Now") {
                            Task { await container.retryReconnect() }
                        }
                        .font(.caption.bold())
                        .accessibilityIdentifier("reconnect-retry-button")
                        .accessibilityLabel("Retry connection immediately")

                        Button("Cancel") {
                            Task { await container.cancelReconnect() }
                        }
                        .font(.caption.bold())
                        .foregroundStyle(.secondary)
                        .accessibilityIdentifier("reconnect-cancel-button")
                        .accessibilityLabel("Cancel reconnection")
                    }
                }
            }
            .padding(.horizontal)
            .padding(.vertical, 6)
            .background(Color.yellow.opacity(0.15))
            Divider()
        case .connecting(let attempt):
            ViewThatFits(in: .horizontal) {
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
                    .accessibilityIdentifier("reconnect-cancel-button")
                    .accessibilityLabel("Cancel reconnection")
                }
                VStack(alignment: .leading, spacing: 6) {
                    HStack(spacing: 8) {
                        ProgressView()
                            .controlSize(.small)
                        Text("Reconnecting (attempt \(attempt)/\(ReconnectCoordinator.maxAttempts))...")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    Button("Cancel") {
                        Task { await container.cancelReconnect() }
                    }
                    .font(.caption.bold())
                    .accessibilityIdentifier("reconnect-cancel-button")
                    .accessibilityLabel("Cancel reconnection")
                }
            }
            .padding(.horizontal)
            .padding(.vertical, 6)
            .background(Color.blue.opacity(0.15))
            Divider()
        case .exhausted(let attempts):
            ViewThatFits(in: .horizontal) {
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
                    .accessibilityIdentifier("reconnect-retry-button")
                    .accessibilityLabel("Retry connection")

                    Button("Cancel") {
                        Task { await container.cancelReconnect() }
                    }
                    .font(.caption.bold())
                    .foregroundStyle(.secondary)
                    .accessibilityIdentifier("reconnect-cancel-button")
                    .accessibilityLabel("Dismiss reconnection")
                }
                VStack(alignment: .leading, spacing: 6) {
                    HStack(spacing: 8) {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .foregroundStyle(.orange)
                        Text("Reconnection failed after \(attempts) attempts.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    HStack(spacing: 12) {
                        Button("Retry") {
                            Task { await container.retryReconnect() }
                        }
                        .font(.caption.bold())
                        .accessibilityIdentifier("reconnect-retry-button")
                        .accessibilityLabel("Retry connection")

                        Button("Cancel") {
                            Task { await container.cancelReconnect() }
                        }
                        .font(.caption.bold())
                        .foregroundStyle(.secondary)
                        .accessibilityIdentifier("reconnect-cancel-button")
                        .accessibilityLabel("Dismiss reconnection")
                    }
                }
            }
            .padding(.horizontal)
            .padding(.vertical, 6)
            .background(Color.orange.opacity(0.15))
            Divider()
        case .failed(let reason):
            HStack(spacing: 8) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundStyle(.red)
                Text(reason)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
                Button("Retry") {
                    Task { await container.retryReconnect() }
                }
                .font(.caption.bold())
                .accessibilityIdentifier("reconnect-retry-button")
                .accessibilityLabel("Retry connection")
            }
            .padding(.horizontal)
            .padding(.vertical, 6)
            .background(Color.red.opacity(0.15))
            .accessibilityElement(children: .contain)
            .accessibilityIdentifier("reconnect-failure-banner")
            Divider()
        case .cancelled:
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 8) {
                    Text("Reconnection cancelled.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Spacer()
                    Button("Retry") {
                        Task { await container.retryReconnect() }
                    }
                    .font(.caption.bold())
                    .accessibilityIdentifier("reconnect-retry-button")
                    .accessibilityLabel("Retry connection")
                }
                VStack(alignment: .leading, spacing: 6) {
                    Text("Reconnection cancelled.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Button("Retry") {
                        Task { await container.retryReconnect() }
                    }
                    .font(.caption.bold())
                    .accessibilityIdentifier("reconnect-retry-button")
                    .accessibilityLabel("Retry connection")
                }
            }
            .padding(.horizontal)
            .padding(.vertical, 6)
            .background(Color.gray.opacity(0.15))
            Divider()
            default:
                EmptyView()
            }
        }
    }

    @ViewBuilder
    private var splitPaneArea: some View {
        GeometryReader { geometry in
            let dividerWidth: CGFloat = 1
            let paneWidth = max(0, (geometry.size.width - dividerWidth) / 2)
            HStack(spacing: 0) {
                // Left pane (50% width): Primary terminal
                terminalSurfaceArea
                    .frame(width: paneWidth, height: geometry.size.height)

                // Center divider line: A subtle vertical divider with a drag handle or clean hairline border
                centerDivider
                    .frame(width: dividerWidth, height: geometry.size.height)

                // Right pane (50% width): Secondary header bar and content
                secondaryPaneView
                    .frame(width: paneWidth, height: geometry.size.height)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var centerDivider: some View {
        ZStack {
            Rectangle()
                .fill(Color(uiColor: .separator))
                .frame(width: 1)
            Capsule()
                .fill(Color.secondary.opacity(0.4))
                .frame(width: 4, height: 32)
        }
        .frame(width: 1)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Split pane divider")
    }

    @ViewBuilder
    private var secondaryPaneView: some View {
        VStack(spacing: 0) {
            // Header bar with title and close button
            secondaryPaneHeader

            Divider()

            // Content
            switch container.secondaryPaneMode {
            case .none:
                EmptyView()
            case .sftp(let host):
                SFTPBrowserView(host: host)
            case .terminal:
                ShhTerminalView(controller: container.secondaryTerminalController)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .background(Color.black)
                    .accessibilityElement(children: .contain)
                    .accessibilityLabel("Secondary terminal surface")
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var secondaryPaneTitle: String {
        switch container.secondaryPaneMode {
        case .none:
            return ""
        case .sftp(let host):
            return "SFTP: \(host.name)"
        case .terminal(let host):
            return "Terminal: \(host.name)"
        }
    }

    private var secondaryPaneIcon: String {
        switch container.secondaryPaneMode {
        case .sftp:
            return "folder"
        case .terminal:
            return "terminal"
        case .none:
            return ""
        }
    }

    private var secondaryPaneHeader: some View {
        HStack(spacing: 8) {
            Label(secondaryPaneTitle, systemImage: secondaryPaneIcon)
                .font(.subheadline.weight(.semibold))
                .lineLimit(1)
            Spacer()
            Button(action: {
                container.closeSecondaryPane()
            }) {
                Image(systemName: "xmark.circle.fill")
                    .font(.body)
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Close secondary pane")
            .accessibilityIdentifier("secondary-pane-close-button")
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(Color(uiColor: .secondarySystemBackground))
    }

    @ViewBuilder
    private var terminalSurfaceArea: some View {
        ShhTerminalView(controller: container.terminalController)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(Color.black)
            .accessibilityElement(children: .contain)
            .accessibilityLabel("Terminal surface")
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
                            .autocorrectionDisabled()
                            .textInputAutocapitalization(.never)
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

struct TerminalZoomControls: View {
    @ObservedObject var controller: ShhTerminalController

    var body: some View {
        HStack(spacing: 12) {
            Button {
                controller.decreaseTerminalFontSize()
            } label: {
                Image(systemName: "minus")
                    .frame(minWidth: 32, minHeight: 32)
            }
            .accessibilityLabel("Decrease terminal text size")
            .accessibilityIdentifier("terminal-zoom-decrease")
            .disabled(controller.terminalFontSize <= TerminalFontSize.minimumPointSize)

            Button {
                controller.resetTerminalFontSize()
            } label: {
                Text("\(controller.terminalFontSizePercentage)%")
                    .monospacedDigit()
                    .frame(minWidth: 56, minHeight: 32)
            }
            .accessibilityLabel("Reset terminal text size")
            .accessibilityValue("\(controller.terminalFontSizePercentage) percent")
            .accessibilityIdentifier("terminal-zoom-reset")

            Button {
                controller.increaseTerminalFontSize()
            } label: {
                Image(systemName: "plus")
                    .frame(minWidth: 32, minHeight: 32)
            }
            .accessibilityLabel("Increase terminal text size")
            .accessibilityIdentifier("terminal-zoom-increase")
            .disabled(controller.terminalFontSize >= TerminalFontSize.maximumPointSize)
        }
        .buttonStyle(.bordered)
        .controlSize(.small)
        .frame(maxWidth: .infinity, alignment: .trailing)
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .background(Color(.secondarySystemBackground))
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("terminal-zoom-controls")
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

/// Accessory toolbar positioned above the keyboard providing quick-access terminal
/// keys and sticky modifiers (Ctrl, Alt, Shift). Modifiers are held in the controller's
/// `TerminalInputCoordinator` so that soft/hardware keyboard input and accessory buttons
/// share active modifier state.
struct TerminalAccessoryBar: View {
    @ObservedObject var controller: ShhTerminalController
    @ObservedObject private var inputCoordinator: TerminalInputCoordinator

    init(controller: ShhTerminalController) {
        self.controller = controller
        self._inputCoordinator = ObservedObject(wrappedValue: controller.inputCoordinator)
    }

    private var activeModifiers: KeyModifiers {
        inputCoordinator.activeModifiers
    }

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 6) {
                // Esc
                AccessoryKeyButton(title: "Esc") {
                    sendKey(.escape)
                }

                // Tab
                AccessoryKeyButton(title: inputCoordinator.isShiftActive ? "⇧Tab" : "Tab") {
                    sendKey(.tab(shift: inputCoordinator.isShiftActive))
                }

                // Sticky Ctrl Toggle
                AccessoryToggleKeyButton(title: "Ctrl", isActive: inputCoordinator.isControlActive) {
                    inputCoordinator.toggleControl()
                }

                // Sticky Alt/Meta Toggle
                AccessoryToggleKeyButton(title: "Alt", isActive: inputCoordinator.isAltActive) {
                    inputCoordinator.toggleAlt()
                }

                // Sticky Shift Toggle
                AccessoryToggleKeyButton(title: "⇧", isActive: inputCoordinator.isShiftActive) {
                    inputCoordinator.toggleShift()
                }

                // Ctrl-C
                AccessoryKeyButton(title: "^C", role: .destructive) {
                    sendKey(.ctrlC)
                }

                // Ctrl-D
                AccessoryKeyButton(title: "^D") {
                    sendKey(.ctrlD)
                }

                // Symbols (~, /, |, -)
                AccessoryKeyButton(title: "~") {
                    sendText("~")
                }
                .accessibilityLabel("Tilde")
                .accessibilityIdentifier("terminal-accessory-tilde-button")

                AccessoryKeyButton(title: "/") {
                    sendText("/")
                }
                .accessibilityLabel("Slash")
                .accessibilityIdentifier("terminal-accessory-slash-button")

                AccessoryKeyButton(title: "|") {
                    sendText("|")
                }
                .accessibilityLabel("Pipe")
                .accessibilityIdentifier("terminal-accessory-pipe-button")

                AccessoryKeyButton(title: "-") {
                    sendText("-")
                }
                .accessibilityLabel("Minus")
                .accessibilityIdentifier("terminal-accessory-minus-button")

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

                // Dismiss Keyboard
                AccessoryIconButton(systemImage: "keyboard.chevron.compact.down") {
                    controller.resignFirstResponder()
                }
                .accessibilityLabel("Dismiss keyboard")
                .accessibilityIdentifier("terminal-accessory-dismiss-keyboard-button")
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
        }
        .background(Color(.systemGray6))
    }

    private func sendKey(_ key: TerminalKey) {
        controller.send(accessoryKey: key)
    }

    private func sendControl(_ char: Character) {
        controller.send(accessoryKey: .control(char))
    }

    private func sendText(_ text: String) {
        controller.send(accessoryText: text)
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
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .navigationTitle("Confirm command")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
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
        .editorSheetPresentation()
    }
}

struct MultiplexerPicker: View {
    @EnvironmentObject private var container: AppContainer
    @Environment(\.dismiss) private var dismiss
    @State private var selected = RemoteMultiplexer.tmux
    @State private var newSessionName = ""
    @State private var autoAttach = false
    @State private var hasLoadedPreferences = false

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
                } else if selected == .herdr {
                    herdrContent
                } else {
                    deferredMultiplexerContent
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .navigationTitle("Remote Multiplexer")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Done") { dismiss() }
                        .accessibilityLabel("Close multiplexer sheet")
                        .accessibilityIdentifier("multiplexer-done-button")
                }
                if (selected == .tmux || selected == .herdr) && container.activeSession?.state == .connected {
                    ToolbarItem(placement: .confirmationAction) {
                        Button(action: {
                            Task {
                                if selected == .tmux {
                                    await container.refreshTmuxState()
                                } else if selected == .herdr {
                                    await container.refreshHerdrState()
                                }
                            }
                        }) {
                            if (selected == .tmux && container.isProbingTmux) || (selected == .herdr && container.isProbingHerdr) {
                                ProgressView()
                                    .controlSize(.small)
                            } else {
                                Image(systemName: "arrow.clockwise")
                            }
                        }
                        .disabled((selected == .tmux && container.isProbingTmux) || (selected == .herdr && container.isProbingHerdr))
                        .accessibilityLabel(selected == .tmux ? "Refresh tmux sessions" : "Refresh Herdr workspaces")
                        .accessibilityIdentifier(selected == .tmux ? "refresh-tmux-button" : "refresh-herdr-button")
                    }
                }
            }
            .task {
                loadHostPreferences()
                if container.activeSession?.state == .connected {
                    if selected == .tmux {
                        await container.refreshTmuxState()
                    } else if selected == .herdr {
                        await container.refreshHerdrState()
                    }
                }
            }
            .onChange(of: selected) { _, newSelection in
                if container.activeSession?.state == .connected {
                    Task {
                        if newSelection == .tmux {
                            await container.refreshTmuxState()
                        } else if newSelection == .herdr {
                            await container.refreshHerdrState()
                        }
                    }
                }
            }
        }
        .editorSheetPresentation(detents: [.medium, .large])
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
                                        .appRowTitle()
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
                Toggle("Auto-attach last used session on connect", isOn: $autoAttach)
                    .onChange(of: autoAttach) { _, _ in
                        savePreferences()
                    }
                    .accessibilityLabel("Auto-attach to tmux on connect")
                    .accessibilityIdentifier("sheet-auto-attach-toggle")

            }
        }
    }

    @ViewBuilder
    private var herdrContent: some View {
        HerdrAgentCardsView()
    }

    @ViewBuilder
    private var deferredMultiplexerContent: some View {
        Section {
            VStack(alignment: .leading, spacing: 8) {
                Label("\(selected.rawValue.capitalized) is not enabled", systemImage: "clock.arrow.circlepath")
                    .font(.headline)
                    .foregroundStyle(.secondary)
                Text("Multiplexer adapter \(selected.rawValue.capitalized) is visibly unavailable and deferred in this build. Tmux and Herdr are the supported remote multiplexers.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                Text("Zellij, Byobu, and Screen remain deferred pending terminal multiplexing contracts.")
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
        hasLoadedPreferences = true
    }

    private func savePreferences() {
        guard hasLoadedPreferences, container.activeHost != nil else { return }
        Task {
            try? await container.updateActiveHostPreferences(
                autoAttachTmux: autoAttach,
                defaultTmuxSession: nil
            )
        }
    }
}

// MARK: - Herdr UI Components

struct HerdrAgentStateBadge: View {
    let state: HerdrAgentState

    var body: some View {
        HStack(spacing: 4) {
            badgeIcon
            Text(badgeTitle)
                .font(.caption2.bold())
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 3)
        .background(badgeColor.opacity(0.12))
        .foregroundStyle(badgeColor)
        .clipShape(Capsule())
        .overlay(
            Capsule()
                .stroke(badgeColor.opacity(0.3), lineWidth: 1)
        )
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Agent status: \(badgeTitle)")
        .accessibilityIdentifier("agent-state-badge-\(state.statusName)")
    }

    @ViewBuilder
    private var badgeIcon: some View {
        switch state {
        case .idle:
            Image(systemName: "pause.circle.fill")
                .font(.caption2)
        case .working:
            ProgressView()
                .controlSize(.mini)
                .tint(.blue)
        case .blocked:
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.caption2)
        case .completed:
            Image(systemName: "checkmark.circle.fill")
                .font(.caption2)
        }
    }

    private var badgeTitle: String {
        switch state {
        case .idle: return "Idle"
        case .working: return "Working"
        case .blocked: return "Blocked"
        case .completed: return "Completed"
        }
    }

    private var badgeColor: Color {
        switch state {
        case .idle: return .secondary
        case .working: return .blue
        case .blocked: return .orange
        case .completed: return .green
        }
    }
}

struct HerdrAgentCardView: View {
    let pane: HerdrPane
    let onReadOutput: () -> Void
    let onSendCommand: () -> Void
    let onSplitPane: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            // Header: Pane Title + ID and State Badge
            ViewThatFits(in: .horizontal) {
                HStack(alignment: .center) {
                    headerTitles
                    Spacer()
                    HerdrAgentStateBadge(state: pane.agentState)
                        .fixedSize(horizontal: true, vertical: false)
                        .layoutPriority(1)
                }
                VStack(alignment: .leading, spacing: 6) {
                    HerdrAgentStateBadge(state: pane.agentState)
                        .fixedSize(horizontal: true, vertical: false)
                    headerTitles
                }
            }

            // State-specific reason or summary
            switch pane.agentState {
            case .blocked(let reason) where !reason.isEmpty:
                HStack(alignment: .top, spacing: 6) {
                    Image(systemName: "hand.raised.fill")
                        .font(.caption)
                        .foregroundStyle(.orange)
                    Text(reason)
                        .font(.caption)
                        .foregroundStyle(.orange)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .padding(6)
                .background(Color.orange.opacity(0.1))
                .cornerRadius(6)
                .accessibilityElement(children: .combine)
                .accessibilityLabel("Blocked reason: \(reason)")
                .accessibilityIdentifier("pane-blocked-reason-\(pane.id)")
            case .completed(let summary) where !summary.isEmpty:
                HStack(alignment: .top, spacing: 6) {
                    Image(systemName: "text.badge.checkmark")
                        .font(.caption)
                        .foregroundStyle(.green)
                    Text(summary)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .padding(6)
                .background(Color.green.opacity(0.1))
                .cornerRadius(6)
                .accessibilityElement(children: .combine)
                .accessibilityLabel("Completed summary: \(summary)")
                .accessibilityIdentifier("pane-completed-summary-\(pane.id)")
            default:
                EmptyView()
            }

            // Current Command if present
            if let cmd = pane.currentCommand, !cmd.isEmpty {
                HStack(spacing: 6) {
                    Image(systemName: "terminal")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                    Text(cmd)
                        .font(.caption.monospaced())
                        .foregroundStyle(.primary)
                        .lineLimit(2)
                        .truncationMode(.tail)
                }
                .accessibilityElement(children: .combine)
                .accessibilityLabel("Current command: \(cmd)")
                .accessibilityIdentifier("pane-command-\(pane.id)")
            }

            // Last Activity if present
            if let lastActivity = pane.lastActivity {
                HStack(spacing: 4) {
                    Image(systemName: "clock")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                    Text("Active \(formatRelativeDate(lastActivity))")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                }
                .accessibilityElement(children: .combine)
                .accessibilityLabel("Active \(formatRelativeDate(lastActivity))")
            }

            Divider()

            // Card Actions: Read Output, Send Command, Split Pane
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 8) {
                    actionButtons
                }
                VStack(spacing: 6) {
                    actionButtons
                }
            }
        }
        .padding(12)
        .background(Color(uiColor: .secondarySystemGroupedBackground))
        .cornerRadius(12)
        .overlay(
            RoundedRectangle(cornerRadius: 12)
                .stroke(Color(uiColor: .separator).opacity(0.5), lineWidth: 1)
        )
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("herdr-agent-card-\(pane.id)")
    }

    private var headerTitles: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(pane.label.isEmpty ? pane.id : pane.label)
                .appRowTitle()
                .lineLimit(1)
                .truncationMode(.tail)
            if !pane.label.isEmpty && pane.label != pane.id {
                Text(pane.id)
                    .font(.caption.monospaced())
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
        }
    }

    @ViewBuilder
    private var actionButtons: some View {
        Button(action: onReadOutput) {
            Label("Output", systemImage: "text.alignleft")
                .font(.caption.weight(.medium))
                .lineLimit(1)
        }
        .buttonStyle(.bordered)
        .accessibilityLabel("Read recent output for pane \(pane.label.isEmpty ? pane.id : pane.label)")
        .accessibilityHint("Opens sheet displaying unwrapped output")
        .accessibilityIdentifier("pane-read-output-\(pane.id)")

        Button(action: onSendCommand) {
            Label("Command", systemImage: "terminal")
                .font(.caption.weight(.medium))
                .lineLimit(1)
        }
        .buttonStyle(.bordered)
        .accessibilityLabel("Send command to pane \(pane.label.isEmpty ? pane.id : pane.label)")
        .accessibilityHint("Opens dialog to enter and execute command")
        .accessibilityIdentifier("pane-send-command-\(pane.id)")

        Button(action: onSplitPane) {
            Label("Split", systemImage: "rectangle.split.2x1")
                .font(.caption.weight(.medium))
                .lineLimit(1)
        }
        .buttonStyle(.bordered)
        .accessibilityLabel("Split pane \(pane.label.isEmpty ? pane.id : pane.label)")
        .accessibilityHint("Splits this pane vertically")
        .accessibilityIdentifier("pane-split-\(pane.id)")
    }

    private func formatRelativeDate(_ date: Date) -> String {
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .abbreviated
        return formatter.localizedString(for: date, relativeTo: Date())
    }
}

struct HerdrOutputSheet: View {
    @EnvironmentObject private var container: AppContainer
    @Environment(\.dismiss) private var dismiss
    let pane: HerdrPane
    @State private var output: String = ""
    @State private var isLoading: Bool = true
    @State private var errorMessage: String? = nil
    @State private var copied: Bool = false

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                if isLoading {
                    VStack(spacing: 12) {
                        ProgressView()
                        Text("Reading recent output...")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .accessibilityIdentifier("herdr-output-loading")
                } else if let error = errorMessage {
                    VStack(spacing: 8) {
                        Image(systemName: "exclamationmark.triangle")
                            .font(.title2)
                            .foregroundStyle(.red)
                        Text(error)
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                            .multilineTextAlignment(.center)
                            .padding(.horizontal)
                        Button("Retry") {
                            Task { await loadOutput() }
                        }
                        .buttonStyle(.bordered)
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .accessibilityIdentifier("herdr-output-error")
                } else if output.isEmpty {
                    VStack(spacing: 8) {
                        Image(systemName: "text.alignleft")
                            .font(.title2)
                            .foregroundStyle(.secondary)
                        Text("No recent output available.")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .accessibilityIdentifier("herdr-output-empty")
                } else {
                    ScrollView([.horizontal, .vertical]) {
                        Text(output)
                            .font(.system(.footnote, design: .monospaced))
                            .textSelection(.enabled)
                            .fixedSize(horizontal: true, vertical: false)
                            .frame(maxWidth: .infinity, alignment: .topLeading)
                            .padding()
                    }
                    .accessibilityIdentifier("herdr-output-text")
                }
            }
            .navigationTitle("Output: \(pane.label.isEmpty ? pane.id : pane.label)")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Done") { dismiss() }
                        .accessibilityIdentifier("herdr-output-done-button")
                }
                ToolbarItemGroup(placement: .confirmationAction) {
                    Button(action: {
                        UIPasteboard.general.string = output
                        copied = true
                        Task {
                            try? await Task.sleep(nanoseconds: 1_500_000_000)
                            copied = false
                        }
                    }) {
                        Image(systemName: copied ? "checkmark" : "doc.on.doc")
                    }
                    .disabled(output.isEmpty || isLoading)
                    .accessibilityLabel(copied ? "Copied" : "Copy output")
                    .accessibilityIdentifier("herdr-output-copy-button")

                    Button(action: {
                        Task { await loadOutput() }
                    }) {
                        Image(systemName: "arrow.clockwise")
                    }
                    .disabled(isLoading)
                    .accessibilityLabel("Refresh output")
                    .accessibilityIdentifier("herdr-output-refresh-button")
                }
            }
            .task {
                await loadOutput()
            }
        }
        .editorSheetPresentation()
        .accessibilityIdentifier("herdr-output-sheet")
    }

    private func loadOutput() async {
        isLoading = true
        errorMessage = nil
        do {
            output = try await container.readHerdrPaneOutput(paneID: pane.id)
            isLoading = false
        } catch {
            errorMessage = error.localizedDescription
            isLoading = false
        }
    }
}

struct HerdrSendCommandSheet: View {
    @EnvironmentObject private var container: AppContainer
    @Environment(\.dismiss) private var dismiss
    let pane: HerdrPane
    @State private var command: String = ""
    @State private var isExecuting: Bool = false
    @State private var executionError: String? = nil

    private var commandRisk: CommandRisk {
        let trimmed = command.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return .safe }
        let rendered = HerdrCommand.paneRun(pane: pane.id, command: trimmed).renderedCommand
        return CommandPolicy().classify(rendered)
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("Target Pane") {
                    HStack {
                        Text("Pane")
                        Spacer()
                        Text(pane.label.isEmpty ? pane.id : pane.label)
                            .foregroundStyle(.secondary)
                    }
                    HStack {
                        Text("Pane ID")
                        Spacer()
                        Text(pane.id)
                            .font(.caption.monospaced())
                            .foregroundStyle(.secondary)
                    }
                }

                Section("Command") {
                    TextField("Enter command (e.g. cargo test, npm start)", text: $command)
                        .font(.system(.body, design: .monospaced))
                        .autocorrectionDisabled()
                        .textInputAutocapitalization(.never)
                        .onSubmit {
                            let trimmed = command.trimmingCharacters(in: .whitespacesAndNewlines)
                            if !trimmed.isEmpty && commandRisk != .blocked && !isExecuting {
                                Task { await runCommand() }
                            }
                        }
                        .accessibilityLabel("Command to run in pane")
                        .accessibilityIdentifier("herdr-command-input-field")

                    // Real-time Policy Evaluation Banner
                    if !command.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                        switch commandRisk {
                        case .blocked:
                            HStack(alignment: .top, spacing: 6) {
                                Image(systemName: "xmark.octagon.fill")
                                    .foregroundStyle(.red)
                                Text("Blocked: Destructive command rejected by safety policy.")
                                    .font(.caption)
                                    .foregroundStyle(.red)
                            }
                            .accessibilityIdentifier("herdr-command-blocked-warning")
                        case .reviewRequired:
                            HStack(alignment: .top, spacing: 6) {
                                Image(systemName: "exclamationmark.shield.fill")
                                    .foregroundStyle(.orange)
                                Text("Review required: Command executes remotely in agent pane. Tap Run to approve.")
                                    .font(.caption)
                                    .foregroundStyle(.orange)
                            }
                            .accessibilityIdentifier("herdr-command-review-notice")
                        case .safe:
                            HStack(alignment: .top, spacing: 6) {
                                Image(systemName: "checkmark.shield.fill")
                                    .foregroundStyle(.green)
                                Text("Safe: Command passed safety review.")
                                    .font(.caption)
                                    .foregroundStyle(.green)
                            }
                            .accessibilityIdentifier("herdr-command-safe-notice")
                        }
                    }
                }

                if let err = executionError {
                    Section {
                        Text(err)
                            .font(.caption)
                            .foregroundStyle(.red)
                            .accessibilityIdentifier("herdr-command-execution-error")
                    }
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .navigationTitle("Send Command")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                        .accessibilityIdentifier("herdr-command-cancel-button")
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button(action: {
                        Task { await runCommand() }
                    }) {
                        if isExecuting {
                            ProgressView()
                                .controlSize(.small)
                        } else {
                            Text("Run")
                        }
                    }
                    .disabled(command.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || commandRisk == .blocked || isExecuting)
                    .accessibilityLabel(isExecuting ? "Executing command" : "Execute command in pane")
                    .accessibilityIdentifier("herdr-command-run-button")
                }
                ToolbarItemGroup(placement: .keyboard) {
                    Spacer()
                    Button {
                        UIApplication.shared.sendAction(#selector(UIResponder.resignFirstResponder), to: nil, from: nil, for: nil)
                    } label: {
                        Label("Dismiss Keyboard", systemImage: "keyboard.chevron.compact.down")
                    }
                    .accessibilityLabel("Dismiss keyboard")
                    .accessibilityIdentifier("herdr-command-dismiss-keyboard-button")
                }
            }
        }
        .editorSheetPresentation()
        .accessibilityIdentifier("herdr-send-command-sheet")
    }

    private func runCommand() async {
        let trimmed = command.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        isExecuting = true
        executionError = nil
        let result = await container.runHerdrPaneCommand(paneID: pane.id, command: trimmed, approved: true)
        isExecuting = false
        if result.success {
            dismiss()
        } else {
            executionError = result.error ?? "Failed to execute command"
        }
    }
}

struct HerdrCreateWorkspaceSheet: View {
    @EnvironmentObject private var container: AppContainer
    @Environment(\.dismiss) private var dismiss
    @State private var label: String = ""
    @State private var cwd: String = "."
    @State private var isCreating: Bool = false
    @State private var errorMessage: String? = nil

    var body: some View {
        NavigationStack {
            Form {
                Section("Workspace Details") {
                    TextField("Workspace Label (e.g. backend, web)", text: $label)
                        .autocorrectionDisabled()
                        .textInputAutocapitalization(.never)
                        .onSubmit {
                            let trimmed = label.trimmingCharacters(in: .whitespacesAndNewlines)
                            if !trimmed.isEmpty && !isCreating {
                                Task { await createWorkspace() }
                            }
                        }
                        .accessibilityLabel("Workspace label")
                        .accessibilityIdentifier("herdr-new-workspace-label")

                    TextField("Working Directory (e.g. /home/dev/project)", text: $cwd)
                        .font(.system(.body, design: .monospaced))
                        .autocorrectionDisabled()
                        .textInputAutocapitalization(.never)
                        .onSubmit {
                            let trimmed = label.trimmingCharacters(in: .whitespacesAndNewlines)
                            if !trimmed.isEmpty && !isCreating {
                                Task { await createWorkspace() }
                            }
                        }
                        .accessibilityLabel("Working directory")
                        .accessibilityIdentifier("herdr-new-workspace-cwd")
                }

                if let error = errorMessage {
                    Section {
                        Text(error)
                            .font(.caption)
                            .foregroundStyle(.red)
                            .accessibilityIdentifier("herdr-create-workspace-error")
                    }
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .navigationTitle("Create Workspace")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                        .accessibilityIdentifier("herdr-create-workspace-cancel-button")
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button(action: {
                        Task { await createWorkspace() }
                    }) {
                        if isCreating {
                            ProgressView()
                                .controlSize(.small)
                        } else {
                            Text("Create")
                        }
                    }
                    .disabled(label.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || isCreating)
                    .accessibilityLabel(isCreating ? "Creating workspace" : "Create workspace")
                    .accessibilityIdentifier("herdr-create-workspace-confirm-button")
                }
                ToolbarItemGroup(placement: .keyboard) {
                    Spacer()
                    Button {
                        UIApplication.shared.sendAction(#selector(UIResponder.resignFirstResponder), to: nil, from: nil, for: nil)
                    } label: {
                        Label("Dismiss Keyboard", systemImage: "keyboard.chevron.compact.down")
                    }
                    .accessibilityLabel("Dismiss keyboard")
                    .accessibilityIdentifier("herdr-create-workspace-dismiss-keyboard-button")
                }
            }
        }
        .editorSheetPresentation()
        .accessibilityIdentifier("herdr-create-workspace-sheet")
    }

    private func createWorkspace() async {
        isCreating = true
        errorMessage = nil
        let result = await container.createHerdrWorkspace(label: label, cwd: cwd)
        isCreating = false
        if result.success {
            dismiss()
        } else {
            errorMessage = result.error ?? "Failed to create workspace"
        }
    }
}

struct HerdrAgentCardsView: View {
    @EnvironmentObject private var container: AppContainer
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    var isStandalone: Bool = false

    @State private var selectedOutputPane: HerdrPane?
    @State private var selectedCommandPane: HerdrPane?
    @State private var showCreateWorkspace: Bool = false

    var body: some View {
        if isStandalone {
            NavigationStack {
                Form {
                    cardsContent
                }
                .navigationTitle("Herdr Agents")
                .navigationBarTitleDisplayMode(.inline)
            }
            .sheet(item: $selectedOutputPane) { pane in
                HerdrOutputSheet(pane: pane)
                    .environmentObject(container)
            }
            .sheet(item: $selectedCommandPane) { pane in
                HerdrSendCommandSheet(pane: pane)
                    .environmentObject(container)
            }
            .sheet(isPresented: $showCreateWorkspace) {
                HerdrCreateWorkspaceSheet()
                    .environmentObject(container)
            }
            .onAppear {
                if container.activeSession?.state == .connected {
                    container.startHerdrPolling()
                }
            }
            .onDisappear {
                container.stopHerdrPolling()
            }
        } else {
            cardsContent
                .sheet(item: $selectedOutputPane) { pane in
                    HerdrOutputSheet(pane: pane)
                        .environmentObject(container)
                }
                .sheet(item: $selectedCommandPane) { pane in
                    HerdrSendCommandSheet(pane: pane)
                        .environmentObject(container)
                }
                .sheet(isPresented: $showCreateWorkspace) {
                    HerdrCreateWorkspaceSheet()
                        .environmentObject(container)
                }
                .onAppear {
                    if container.activeSession?.state == .connected {
                        container.startHerdrPolling()
                    }
                }
                .onDisappear {
                    container.stopHerdrPolling()
                }
        }
    }

    @ViewBuilder
    private var cardsContent: some View {
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
        Section("Herdr Status") {
            HStack {
                Label {
                    VStack(alignment: .leading, spacing: 2) {
                        switch container.herdrAvailability {
                        case .available(let version):
                            Text(version)
                                .font(.body.weight(.medium))
                            Text(container.isPollingHerdr ? "Polling active" : "Ready")
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
                    if container.herdrAvailability.isAvailable {
                        Image(systemName: "checkmark.circle.fill")
                            .foregroundStyle(.green)
                    } else {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .foregroundStyle(.orange)
                    }
                }

                Spacer()

                if container.herdrAvailability.isAvailable {
                    Button(action: {
                        if container.isPollingHerdr {
                            container.stopHerdrPolling()
                        } else {
                            container.startHerdrPolling()
                        }
                    }) {
                        HStack(spacing: 4) {
                            if container.isPollingHerdr {
                                ProgressView()
                                    .controlSize(.mini)
                            } else {
                                Image(systemName: "play.circle")
                            }
                            Text(container.isPollingHerdr ? "Polling" : "Poll")
                                .font(.caption.bold())
                        }
                        .padding(.horizontal, 8)
                        .padding(.vertical, 4)
                        .background(container.isPollingHerdr ? Color.accentColor.opacity(0.15) : Color(uiColor: .tertiarySystemFill))
                        .cornerRadius(6)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(container.isPollingHerdr ? "Stop live polling" : "Start live polling")
                    .accessibilityIdentifier("herdr-polling-toggle-button")
                }
            }
            .accessibilityElement(children: .combine)
            .accessibilityLabel(herdrStatusAccessibilityLabel)
            .accessibilityIdentifier("herdr-status-row")

            if let error = container.herdrError {
                Text(error)
                    .font(.caption)
                    .foregroundStyle(.red)
                    .accessibilityLabel("Herdr error: \(error)")
                    .accessibilityIdentifier("herdr-error-message")
            }
        }

        // Workspaces & Agent Cards
        if container.herdrAvailability.isAvailable {
            Section {
                HStack {
                    Text("Workspaces")
                        .font(.headline)
                    Spacer()
                    Button(action: { showCreateWorkspace = true }) {
                        Label("New Workspace", systemImage: "plus")
                            .font(.caption.bold())
                    }
                    .buttonStyle(.bordered)
                    .accessibilityLabel("Create new workspace")
                    .accessibilityIdentifier("herdr-new-workspace-button")
                }
            }

            if container.herdrWorkspaces.isEmpty {
                Section {
                    VStack(spacing: 8) {
                        Text("No Herdr workspaces found.")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                        Button("Create Workspace") {
                            showCreateWorkspace = true
                        }
                        .buttonStyle(.borderedProminent)
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 12)
                    .accessibilityIdentifier("herdr-empty-workspaces-label")
                }
            } else {
                ForEach(container.herdrWorkspaces) { workspace in
                    Section {
                        VStack(alignment: .leading, spacing: 12) {
                            // Workspace Header
                            HStack {
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(workspace.label.isEmpty ? workspace.id : workspace.label)
                                        .appRowTitle()
                                    if !workspace.cwd.isEmpty {
                                        Text(workspace.cwd)
                                            .font(.caption.monospaced())
                                            .foregroundStyle(.secondary)
                                    }
                                }
                                Spacer()
                                Button(container.activeHerdrWorkspaceID == workspace.id ? "Selected" : "Select") {
                                    Task { _ = await container.selectHerdrWorkspace(id: workspace.id) }
                                }
                                .buttonStyle(.bordered)
                                .disabled(container.activeHerdrWorkspaceID == workspace.id)
                                .accessibilityIdentifier("select-herdr-workspace-\(workspace.id)")
                                Text("\(workspace.panes.count) \(workspace.panes.count == 1 ? "agent" : "agents")")
                                    .font(.caption2.bold())
                                    .padding(.horizontal, 6)
                                    .padding(.vertical, 2)
                                    .background(Color(uiColor: .tertiarySystemFill))
                                    .cornerRadius(4)
                            }
                            .accessibilityElement(children: .combine)
                            .accessibilityLabel("Workspace \(workspace.label.isEmpty ? workspace.id : workspace.label), \(workspace.panes.count) agents, directory: \(workspace.cwd)")
                            .accessibilityIdentifier("workspace-header-\(workspace.id)")

                            // Panes Layout
                            if workspace.panes.isEmpty {
                                Text("No agent panes in this workspace.")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            } else if horizontalSizeClass == .regular {
                                LazyVGrid(
                                    columns: [GridItem(.adaptive(minimum: 300, maximum: 500), spacing: 12)],
                                    spacing: 12
                                ) {
                                    ForEach(workspace.panes) { pane in
                                        HerdrAgentCardView(
                                            pane: pane,
                                            onReadOutput: { selectedOutputPane = pane },
                                            onSendCommand: { selectedCommandPane = pane },
                                            onSplitPane: {
                                                Task { await container.splitHerdrPane(paneID: pane.id) }
                                            }
                                        )
                                    }
                                }
                            } else {
                                VStack(spacing: 12) {
                                    ForEach(workspace.panes) { pane in
                                        HerdrAgentCardView(
                                            pane: pane,
                                            onReadOutput: { selectedOutputPane = pane },
                                            onSendCommand: { selectedCommandPane = pane },
                                            onSplitPane: {
                                                Task { await container.splitHerdrPane(paneID: pane.id) }
                                            }
                                        )
                                    }
                                }
                            }
                        }
                        .padding(.vertical, 4)
                    }
                }
            }
        }
    }

    private var herdrStatusAccessibilityLabel: String {
        switch container.herdrAvailability {
        case .available(let version):
            return "Herdr \(version), \(container.isPollingHerdr ? "polling active" : "ready")"
        case .unavailable(let reason):
            return "Herdr unavailable: \(reason)"
        }
    }
}

struct SnippetsView: View {
    @EnvironmentObject private var container: AppContainer
    @State private var snippets: [Snippet] = []
    var body: some View { List(snippets) { snippet in NavigationLink { SnippetEditor(snippet: snippet) } label: { VStack(alignment: .leading) { Text(snippet.name); Text(snippet.body).font(.caption.monospaced()).foregroundStyle(.secondary) } } }.navigationTitle("Snippets").navigationBarTitleDisplayMode(.inline).task { snippets = (try? await container.catalog.snippets()) ?? [] } }
}
struct SnippetEditor: View {
    @EnvironmentObject private var container: AppContainer
    let snippet: Snippet
    @State private var bodyText: String
    @State private var showApproval = false
    init(snippet: Snippet) { self.snippet = snippet; _bodyText = State(initialValue: snippet.body) }
    var body: some View { Form { TextField("Name", text: .constant(snippet.name)).autocorrectionDisabled().textInputAutocapitalization(.never); TextEditor(text: $bodyText).frame(minHeight: 160).autocorrectionDisabled().textInputAutocapitalization(.never); Text("Run always shows this exact text and requires approval.").font(.caption).foregroundStyle(.secondary); Button("Run with approval", systemImage: "play.fill") { showApproval = true }.disabled(bodyText.isEmpty) }.navigationTitle("Snippet").navigationBarTitleDisplayMode(.inline).sheet(isPresented: $showApproval) { ApprovalSheet(command: bodyText).environmentObject(container) } }
}
struct MonitoringView: View { var body: some View { List { Label("Health checks are opt-in", systemImage: "heart.text.square"); Label("Unknown is not authentication success", systemImage: "info.circle"); Label("Live monitoring is foreground-only", systemImage: "iphone") }.navigationTitle("Monitoring").navigationBarTitleDisplayMode(.inline) } }
struct TerminalThemePickerView: View {
    @EnvironmentObject private var container: AppContainer

    private func color(_ value: TerminalColor) -> Color {
        Color(red: Double(value.red) / 255, green: Double(value.green) / 255, blue: Double(value.blue) / 255)
    }

    private var accentColorIndex: Int { 4 }

    private func chips(for preset: TerminalThemePreset) -> some View {
        let palette = preset.palette
        let fg = color(palette.foreground)
        let bg = color(palette.background)
        let cursor = color(palette.cursor)
        let accent = color(palette.ansi.count > accentColorIndex ? palette.ansi[accentColorIndex] : palette.selection)

        return HStack(spacing: 4) {
            Circle().fill(fg).frame(width: 10, height: 10)
            Circle().fill(bg).frame(width: 10, height: 10)
                .overlay(Circle().stroke(Color.secondary.opacity(0.3), lineWidth: 0.5))
            Circle().fill(cursor).frame(width: 10, height: 10)
            Circle().fill(accent).frame(width: 10, height: 10)
        }
    }

    var body: some View {
        Form {
            Section("Preview") {
                TerminalThemePreview(theme: container.terminalTheme)
                    .accessibilityElement(children: .combine)
                    .accessibilityLabel("Terminal theme preview")
                    .accessibilityValue(container.terminalTheme.displayName)
            }

            Section("Themes") {
                ForEach(TerminalThemePreset.allCases) { theme in
                    Button {
                        container.setTerminalTheme(theme)
                    } label: {
                        HStack {
                            Text(theme.displayName)
                                .foregroundStyle(Color.primary)
                            Spacer()
                            chips(for: theme)
                            if theme == container.terminalTheme {
                                Image(systemName: "checkmark")
                                    .foregroundStyle(Color.accentColor)
                                    .fontWeight(.semibold)
                            }
                        }
                    }
                    .accessibilityIdentifier("theme-row-\(theme.rawValue)")
                }
            }
        }
        .navigationTitle("Terminal Theme")
        .navigationBarTitleDisplayMode(.inline)
    }
}

struct TerminalThemePreview: View {
    let theme: TerminalThemePreset

    private func color(_ value: TerminalColor) -> Color {
        Color(red: Double(value.red) / 255, green: Double(value.green) / 255, blue: Double(value.blue) / 255)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("$ ssh user@host")
                .font(.system(.body, design: .monospaced).weight(.medium))
            Text("Connected - ready")
                .font(.system(.caption, design: .monospaced))
                .foregroundStyle(color(theme.palette.ansi[2]))
        }
        .foregroundStyle(color(theme.palette.foreground))
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(color(theme.palette.background), in: RoundedRectangle(cornerRadius: 8))
        .overlay(alignment: .bottomTrailing) {
            Circle()
                .fill(color(theme.palette.cursor))
                .frame(width: 8, height: 8)
                .padding(8)
        }
    }
}

struct SettingsView: View {
    @EnvironmentObject private var container: AppContainer
    var body: some View {
        Form {
            Section("Terminal Preferences") {
                Toggle(isOn: $container.keepScreenAwake) {
                    Label {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Keep Screen Awake")
                            Text("Prevent display from sleeping during active SSH sessions")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    } icon: {
                        Image(systemName: "sun.max.fill")
                    }
                }
                .accessibilityIdentifier("settings-keep-screen-awake-toggle")
            }
            Section("Appearance") {
                Picker("Appearance", selection: Binding(
                    get: { container.appearance },
                    set: { container.setAppearance($0) }
                )) {
                    ForEach(AppearanceSetting.allCases) { appearance in
                        Text(appearance.displayName).tag(appearance)
                    }
                }
                .pickerStyle(.segmented)
                .accessibilityIdentifier("appearance-picker")

                NavigationLink {
                    TerminalThemePickerView().environmentObject(container)
                } label: {
                    HStack {
                        Text("Terminal Theme")
                        Spacer()
                        Text(container.terminalTheme.displayName)
                            .foregroundStyle(.secondary)
                    }
                }
                .accessibilityIdentifier("terminal-theme-navigation-link")

                TerminalThemePreview(theme: container.terminalTheme)
                    .accessibilityElement(children: .combine)
                    .accessibilityLabel("Terminal theme preview")
                    .accessibilityValue(container.terminalTheme.displayName)
            }
            Section("SSH Keys & Credentials") {
                NavigationLink {
                    KeyManagementView().environmentObject(container)
                } label: {
                    Label("SSH Keys & Credentials", systemImage: "key.fill")
                }
                .accessibilityIdentifier("settings-keys-navigation-link")
            }
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
            Section("File Provider & Sync") {
                NavigationLink {
                    FileProviderSettingsView().environmentObject(container)
                } label: {
                    Label("File Provider Domains", systemImage: "folder.badge.gearshape")
                }
                .accessibilityIdentifier("settings-fileprovider-navigation-link")

                NavigationLink {
                    VaultBackupView().environmentObject(container)
                } label: {
                    Label("Vault Backup & Restore", systemImage: "lock.shield")
                }
                .accessibilityIdentifier("settings-vault-backup-navigation-link")
            }
            Section("Security") {
                Toggle("Require biometric presence (hook)", isOn: .constant(false))
                Label("Keychain accessibility: when unlocked, this device only", systemImage: "key.fill")
            }
            Section("Capabilities") {
                Text("Live SSH, ProxyJump, forwarding, SFTP, Mosh UDP roaming, File Provider, and encrypted vault backup active. On-device WhisperKit and Apple Speech voice active. Full Mosh SSP encryption and physical device TestFlight validation pending.")
                    .font(.caption)
            }
            Section("Live Activities") {
                Text("Live Activities display connection status on the Lock Screen and Dynamic Island. They do not extend background socket execution and never expose commands or credentials.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Section("Privacy") {
                Text("Zero transcript analytics. All speech processing is 100% on-device. Audio files are deleted immediately after transcription.")
                    .font(.caption)
            }
        }
        .navigationTitle("Settings")
        .navigationBarTitleDisplayMode(.inline)
    }
}

// MARK: - Server Telemetry UI

struct ServerTelemetryCard: View {
    let telemetry: ServerTelemetry
    var onRefresh: (() -> Void)? = nil

    private var cpuPercentage: Double {
        telemetry.cpuUsagePercentage ?? 0.0
    }

    private var cpuText: String {
        if let cpu = telemetry.cpuUsagePercentage {
            return String(format: "CPU: %.0f%%", cpu)
        } else {
            return "CPU: --%"
        }
    }

    private var memoryBarPercentage: Double {
        telemetry.memoryUsagePercentage ?? 0.0
    }

    private var loadText: String {
        if let load = telemetry.loadAverage {
            return String(format: "%.2f, %.2f, %.2f", load.0, load.1, load.2)
        } else {
            return "-"
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Label("Server Resources", systemImage: "gauge.with.dots.needle.bottom.50percent")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)

                Spacer()

                HStack(spacing: 4) {
                    Image(systemName: "clock")
                        .font(.caption2)
                    Text("Up: \(telemetry.formattedUptime)")
                        .font(.caption2.monospaced())
                }
                .foregroundStyle(.secondary)

                if let onRefresh {
                    Button(action: onRefresh) {
                        Image(systemName: "arrow.clockwise")
                            .font(.caption2)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Refresh telemetry")
                    .accessibilityIdentifier("server-telemetry-refresh-button")
                }
            }

            // CPU Gauge / Meter
            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    Label(cpuText, systemImage: "cpu")
                        .font(.subheadline.weight(.medium))
                    Spacer()
                    if telemetry.loadAverage != nil {
                        Text("Load: \(loadText)")
                            .font(.caption2.monospaced())
                            .foregroundStyle(.secondary)
                    }
                }

                GeometryReader { geo in
                    ZStack(alignment: .leading) {
                        Capsule()
                            .fill(Color.secondary.opacity(0.2))
                        Capsule()
                            .fill(cpuPercentage > 85 ? Color.red : (cpuPercentage > 60 ? Color.orange : Color.accentColor))
                            .frame(width: max(0, min(geo.size.width, geo.size.width * (cpuPercentage / 100.0))))
                    }
                }
                .frame(height: 6)
            }

            // Memory Bar
            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    Label("RAM: \(telemetry.formattedMemory)", systemImage: "memorychip")
                        .font(.subheadline.weight(.medium))
                    Spacer()
                }

                GeometryReader { geo in
                    ZStack(alignment: .leading) {
                        Capsule()
                            .fill(Color.secondary.opacity(0.2))
                        Capsule()
                            .fill(memoryBarPercentage > 90 ? Color.red : (memoryBarPercentage > 75 ? Color.orange : Color.accentColor))
                            .frame(width: max(0, min(geo.size.width, geo.size.width * (memoryBarPercentage / 100.0))))
                    }
                }
                .frame(height: 6)
            }
        }
        .padding(12)
        .background(
            RoundedRectangle(cornerRadius: 12)
                .fill(Color(uiColor: .secondarySystemBackground))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 12)
                .stroke(Color.secondary.opacity(0.15), lineWidth: 1)
        )
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Server Telemetry: \(cpuText), RAM: \(telemetry.formattedMemory), Load: \(loadText), Uptime: \(telemetry.formattedUptime)")
        .accessibilityIdentifier("server-telemetry-card")
    }
}

struct ServerTelemetrySheet: View {
    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject private var container: AppContainer

    var body: some View {
        NavigationStack {
            VStack(spacing: 16) {
                if let host = container.activeHost {
                    let telemetry = container.latestTelemetry[host.id]
                    if let telemetry {
                        ServerTelemetryCard(telemetry: telemetry) {
                            Task { await container.fetchTelemetry(for: host) }
                        }
                    } else {
                        VStack(spacing: 12) {
                            ProgressView()
                            Text("Fetching server telemetry...")
                                .font(.subheadline)
                                .foregroundStyle(.secondary)
                        }
                        .frame(maxWidth: .infinity, minHeight: 120)
                    }

                    Spacer()
                } else {
                    Text("No active server connection.")
                        .foregroundStyle(.secondary)
                    Spacer()
                }
            }
            .padding()
            .navigationTitle("Server Telemetry")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") {
                        dismiss()
                    }
                }
            }
            .task {
                if let host = container.activeHost {
                    container.startTelemetryPolling(for: host)
                    await container.fetchTelemetry(for: host)
                }
            }
        }
    }
}
