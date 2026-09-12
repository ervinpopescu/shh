import Foundation
import ShhCore
import SwiftUI

// MARK: - Port Forwarding Type Badge

struct PortForwardingTypeBadge: View {
    let type: PortForwardingType

    var body: some View {
        Text(badgeText)
            .font(.caption2.bold())
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(badgeColor.opacity(0.15))
            .foregroundStyle(badgeColor)
            .clipShape(RoundedRectangle(cornerRadius: 4))
            .accessibilityLabel("Port forwarding type: \(accessibilityDescription)")
            .accessibilityIdentifier("badge-forwarding-type-\(type.rawValue)")
    }

    private var badgeText: String {
        switch type {
        case .local: return "Local (-L)"
        case .remote: return "Remote (-R)"
        case .dynamic: return "SOCKS5 (-D)"
        }
    }

    private var accessibilityDescription: String {
        switch type {
        case .local: return "Local port forwarding"
        case .remote: return "Remote port forwarding"
        case .dynamic: return "Dynamic SOCKS5 proxy"
        }
    }

    private var badgeColor: Color {
        switch type {
        case .local: return .blue
        case .remote: return .purple
        case .dynamic: return .orange
        }
    }
}

// MARK: - Forwarding Status Pill

struct ForwardingStatusPill: View {
    let status: ForwardingStatus

    var body: some View {
        HStack(spacing: 4) {
            statusIcon
            Text(statusText)
                .font(.caption2.bold())
        }
        .padding(.horizontal, 6)
        .padding(.vertical, 2)
        .background(statusColor.opacity(0.12))
        .foregroundStyle(statusColor)
        .clipShape(Capsule())
        .accessibilityLabel("Status: \(statusText)")
        .accessibilityIdentifier("forwarding-status-pill")
    }

    @ViewBuilder
    private var statusIcon: some View {
        switch status {
        case .active:
            Circle().fill(Color.green).frame(width: 6, height: 6)
        case .starting:
            ProgressView().controlSize(.mini)
        case .paused:
            Circle().fill(Color.orange).frame(width: 6, height: 6)
        case .stopped:
            Circle().fill(Color.secondary).frame(width: 6, height: 6)
        case .failed:
            Image(systemName: "exclamationmark.triangle.fill").font(.caption2)
        }
    }

    private var statusText: String {
        switch status {
        case .active: return "Active"
        case .starting: return "Starting"
        case .paused: return "Paused"
        case .stopped: return "Stopped"
        case .failed: return "Failed"
        }
    }

    private var statusColor: Color {
        switch status {
        case .active: return .green
        case .starting: return .blue
        case .paused: return .orange
        case .stopped: return .secondary
        case .failed: return .red
        }
    }
}

// MARK: - Rule Summary Helper

func portForwardingRuleSummary(_ rule: PortForwardingRule, boundPort: UInt16? = nil) -> String {
    let localPortStr = "\(boundPort ?? rule.localPort)"
    switch rule.type {
    case .local:
        let rHost = rule.remoteHost ?? "localhost"
        let rPort = rule.remotePort.map { String($0) } ?? "0"
        return "\(rule.localHost):\(localPortStr) -> \(rHost):\(rPort)"
    case .remote:
        let rHost = rule.remoteHost ?? "0.0.0.0"
        let rPort = boundPort.map { String($0) } ?? rule.remotePort.map { String($0) } ?? "0"
        return "remote \(rHost):\(rPort) -> \(rule.localHost):\(rule.localPort)"
    case .dynamic:
        return "SOCKS5 proxy on \(rule.localHost):\(localPortStr)"
    }
}

// MARK: - Port Forwarding Rule Editor Sheet

struct PortForwardingRuleEditorSheet: View {
    @Environment(\.dismiss) private var dismiss
    let existingRule: PortForwardingRule?
    let onSave: (PortForwardingRule) -> Void

    @State private var name: String
    @State private var type: PortForwardingType
    @State private var localHost: String
    @State private var localPort: String
    @State private var remoteHost: String
    @State private var remotePort: String
    @State private var enabled: Bool
    @State private var validationErrorMessage: String?

    init(existingRule: PortForwardingRule? = nil, onSave: @escaping (PortForwardingRule) -> Void) {
        self.existingRule = existingRule
        self.onSave = onSave
        _name = State(initialValue: existingRule?.name ?? "")
        _type = State(initialValue: existingRule?.type ?? .local)
        _localHost = State(initialValue: existingRule?.localHost ?? "127.0.0.1")
        _localPort = State(initialValue: existingRule != nil ? String(existingRule!.localPort) : "")
        _remoteHost = State(initialValue: existingRule?.remoteHost ?? "")
        _remotePort = State(initialValue: existingRule?.remotePort != nil ? String(existingRule!.remotePort!) : "")
        _enabled = State(initialValue: existingRule?.enabled ?? true)
    }

    private var isNonLoopback: Bool {
        let trimmed = localHost.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed != "127.0.0.1" && trimmed != "::1" && trimmed.lowercased() != "localhost" && !trimmed.isEmpty
    }

    private var isFormValid: Bool {
        guard !localHost.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return false }
        guard let lPort = UInt16(localPort), lPort > 0 else { return false }
        if type == .local {
            guard !remoteHost.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return false }
            guard let rPort = UInt16(remotePort), rPort > 0 else { return false }
        } else if type == .remote {
            guard !remoteHost.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return false }
            guard let _ = UInt16(remotePort) else { return false }
        }
        return true
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("Rule Type") {
                    Picker("Type", selection: $type) {
                        Text("Local (-L)").tag(PortForwardingType.local)
                        Text("Remote (-R)").tag(PortForwardingType.remote)
                        Text("SOCKS5 (-D)").tag(PortForwardingType.dynamic)
                    }
                    .pickerStyle(.segmented)
                    .accessibilityIdentifier("rule-type-picker")
                    .accessibilityLabel("Port forwarding type picker")

                    Text(typeDescription)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Section("Rule Details") {
                    TextField("Name (e.g. Web Server, Postgres)", text: $name)
                        .autocorrectionDisabled()
                        .textInputAutocapitalization(.never)
                        .accessibilityIdentifier("rule-name-field")
                        .accessibilityLabel("Rule name")

                    TextField("Local Bind Host (default 127.0.0.1)", text: $localHost)
                        .autocorrectionDisabled()
                        .textInputAutocapitalization(.never)
                        .accessibilityIdentifier("rule-local-host-field")
                        .accessibilityLabel("Local bind host")

                    TextField("Local Port (1-65535)", text: $localPort)
                        .keyboardType(.numberPad)
                        .autocorrectionDisabled()
                        .textInputAutocapitalization(.never)
                        .accessibilityIdentifier("rule-local-port-field")
                        .accessibilityLabel("Local port")

                    if isNonLoopback {
                        HStack(alignment: .top, spacing: 8) {
                            Image(systemName: "exclamationmark.triangle.fill")
                                .foregroundStyle(.orange)
                            Text("Binding to a non-loopback address will expose this tunnel to other devices on your local network.")
                                .font(.caption)
                                .foregroundStyle(.orange)
                        }
                        .accessibilityElement(children: .combine)
                        .accessibilityLabel("Warning: Binding to a non-loopback address will expose this tunnel to other devices on your local network.")
                        .accessibilityIdentifier("non-loopback-warning")
                    }
                }

                if type != .dynamic {
                    Section("Destination (Remote)") {
                        TextField("Remote Host (e.g. localhost, 10.0.0.2)", text: $remoteHost)
                            .autocorrectionDisabled()
                            .textInputAutocapitalization(.never)
                            .accessibilityIdentifier("rule-remote-host-field")
                            .accessibilityLabel("Remote host")

                        TextField(type == .remote ? "Remote Port (0 for auto, 1-65535)" : "Remote Port (1-65535)", text: $remotePort)
                            .keyboardType(.numberPad)
                            .autocorrectionDisabled()
                            .textInputAutocapitalization(.never)
                            .accessibilityIdentifier("rule-remote-port-field")
                            .accessibilityLabel("Remote port")
                    }
                }

                Section("Options") {
                    Toggle("Auto-start on connection", isOn: $enabled)
                        .accessibilityIdentifier("rule-auto-start-toggle")
                        .accessibilityLabel("Auto-start rule on connection")
                }

                if let validationErrorMessage {
                    Section {
                        Text(validationErrorMessage)
                            .font(.caption)
                            .foregroundStyle(.red)
                            .accessibilityIdentifier("rule-validation-error")
                    }
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .navigationTitle(existingRule == nil ? "Add Forwarding Rule" : "Edit Forwarding Rule")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                        .accessibilityIdentifier("rule-cancel-button")
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") { saveRule() }
                        .disabled(!isFormValid)
                        .accessibilityIdentifier("rule-save-button")
                }
                ToolbarItemGroup(placement: .keyboard) {
                    Spacer()
                    Button {
                        UIApplication.shared.sendAction(#selector(UIResponder.resignFirstResponder), to: nil, from: nil, for: nil)
                    } label: {
                        Label("Dismiss Keyboard", systemImage: "keyboard.chevron.compact.down")
                    }
                    .accessibilityLabel("Dismiss keyboard")
                    .accessibilityIdentifier("port-forwarding-rule-dismiss-keyboard-button")
                }
            }
        }
        .editorSheetPresentation()
    }

    private var typeDescription: String {
        switch type {
        case .local:
            return "Local forwarding (-L): forward traffic from a local port on your device through SSH to a remote server."
        case .remote:
            return "Remote forwarding (-R): forward traffic from a port on the remote server through SSH to your local machine or network."
        case .dynamic:
            return "Dynamic forwarding (-D): creates a local SOCKS5 proxy on your device that routes any connection through the SSH host."
        }
    }

    private func saveRule() {
        guard let lPort = UInt16(localPort), lPort > 0 else {
            validationErrorMessage = "Invalid local port. Port must be between 1 and 65535."
            return
        }

        let rHost: String?
        let rPort: UInt16?
        if type == .dynamic {
            rHost = nil
            rPort = nil
        } else {
            let trimmedRHost = remoteHost.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmedRHost.isEmpty else {
                validationErrorMessage = "Remote host is required for this rule type."
                return
            }
            guard let remotePortNumber = UInt16(remotePort), (type == .remote || remotePortNumber > 0) else {
                validationErrorMessage = "Invalid remote port. Port must be between 1 and 65535."
                return
            }
            rHost = trimmedRHost
            rPort = remotePortNumber
        }

        let trimmedName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let resolvedName = trimmedName.isEmpty ? "\(type.rawValue) :\(lPort)" : trimmedName

        do {
            let rule = try PortForwardingRule(
                id: existingRule?.id ?? UUID(),
                name: resolvedName,
                type: type,
                localHost: localHost.trimmingCharacters(in: .whitespacesAndNewlines),
                localPort: lPort,
                remoteHost: rHost,
                remotePort: rPort,
                enabled: enabled
            )
            onSave(rule)
            dismiss()
        } catch {
            validationErrorMessage = error.localizedDescription
        }
    }
}

// MARK: - Port Forwarding Rule Row

struct PortForwardingRuleRow: View {
    let rule: PortForwardingRule
    let liveState: ForwardingSessionState?
    let isConnected: Bool
    let onStart: () -> Void
    let onStop: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            // Header: Name, Type Badge, Status Pill
            ViewThatFits(in: .horizontal) {
                HStack(alignment: .center) {
                    Text(rule.name)
                        .font(.headline)
                    Spacer()
                    PortForwardingTypeBadge(type: rule.type)
                    if isConnected {
                        ForwardingStatusPill(status: effectiveStatus)
                    }
                }
                VStack(alignment: .leading, spacing: 4) {
                    Text(rule.name)
                        .font(.headline)
                    HStack {
                        PortForwardingTypeBadge(type: rule.type)
                        if isConnected {
                            ForwardingStatusPill(status: effectiveStatus)
                        }
                    }
                }
            }

            // Endpoints summary
            Text(portForwardingRuleSummary(rule, boundPort: liveState?.boundPort))
                .font(.caption)
                .foregroundStyle(.secondary)

            // Live traffic statistics if active
            if let state = liveState, state.status == .active || state.bytesSent > 0 || state.bytesReceived > 0 {
                HStack(spacing: 12) {
                    Label("\(state.activeConnectionsCount) active conn", systemImage: "link")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                    Label(trafficString(sent: state.bytesSent, recv: state.bytesReceived), systemImage: "arrow.up.arrow.down")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
                .accessibilityElement(children: .combine)
                .accessibilityLabel("Traffic: \(state.activeConnectionsCount) active connections, \(trafficString(sent: state.bytesSent, recv: state.bytesReceived))")
            }

            // Error notice if failed
            if let state = liveState, case .failed(let reason) = state.status {
                Text(reason)
                    .font(.caption2)
                    .foregroundStyle(.red)
                    .accessibilityLabel("Error: \(reason)")
            }

            // Action control
            if isConnected {
                HStack {
                    Spacer()
                    if isRunning {
                        Button("Stop", role: .destructive) {
                            onStop()
                        }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                        .accessibilityLabel("Stop forwarder \(rule.name)")
                        .accessibilityIdentifier("stop-forwarder-\(rule.id)")
                    } else {
                        Button("Start") {
                            onStart()
                        }
                        .buttonStyle(.borderedProminent)
                        .controlSize(.small)
                        .accessibilityLabel("Start forwarder \(rule.name)")
                        .accessibilityIdentifier("start-forwarder-\(rule.id)")
                    }
                }
                .padding(.top, 2)
            }
        }
        .padding(.vertical, 4)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("forwarding-rule-row-\(rule.id)")
    }

    private var effectiveStatus: ForwardingStatus {
        liveState?.status ?? .stopped
    }

    private var isRunning: Bool {
        effectiveStatus == .active || effectiveStatus == .starting
    }

    private func trafficString(sent: Int64, recv: Int64) -> String {
        let sentStr = ByteCountFormatter.string(fromByteCount: sent, countStyle: .file)
        let recvStr = ByteCountFormatter.string(fromByteCount: recv, countStyle: .file)
        return "\(sentStr) sent / \(recvStr) recv"
    }
}

// MARK: - Port Forwarding Main Sheet

struct PortForwardingSheet: View {
    @EnvironmentObject private var container: AppContainer
    @Environment(\.dismiss) private var dismiss

    @State private var showingAddRule = false
    @State private var ruleToEdit: PortForwardingRule? = nil
    @State private var pendingNonLoopbackApprovalRule: PortForwardingRule? = nil

    private var isConnected: Bool {
        container.activeSession?.state == .connected
    }

    private var configuredRules: [PortForwardingRule] {
        container.activeHost?.forwardingRules ?? []
    }

    // Combine configured rules and rules that might be running dynamically
    var allRules: [PortForwardingRule] {
        var result = configuredRules
        for session in container.forwardingSessions where session.status == .active || session.status == .starting {
            if !result.contains(where: { $0.id == session.ruleID }) {
                result.append(session.rule)
            }
        }
        return result
    }

    var body: some View {
        NavigationStack {
            Group {
                if allRules.isEmpty {
                    ContentUnavailableView(
                        "No Port Forwarders",
                        systemImage: "arrow.triangle.swap",
                        description: Text("Add a port forwarding rule to securely tunnel local or remote TCP traffic through this SSH connection.")
                    )
                } else {
                    List {
                        if let error = container.forwardingErrorMessage {
                            Section {
                                HStack(spacing: 8) {
                                    Image(systemName: "exclamationmark.triangle.fill")
                                        .foregroundStyle(.red)
                                    Text(error)
                                        .font(.caption)
                                        .foregroundStyle(.red)
                                    Spacer()
                                    Button {
                                        container.forwardingErrorMessage = nil
                                    } label: {
                                        Image(systemName: "xmark.circle.fill")
                                            .foregroundStyle(.secondary)
                                    }
                                    .buttonStyle(.borderless)
                                }
                                .accessibilityElement(children: .combine)
                                .accessibilityLabel("Forwarding error: \(error)")
                                .accessibilityIdentifier("forwarding-error-banner")
                            }
                        }

                        Section(header: Text("Tunnels (\(allRules.count))")) {
                            ForEach(allRules) { rule in
                                let liveState = container.forwardingSessions.first(where: { $0.ruleID == rule.id })
                                PortForwardingRuleRow(
                                    rule: rule,
                                    liveState: liveState,
                                    isConnected: isConnected,
                                    onStart: {
                                        requestStart(rule: rule)
                                    },
                                    onStop: {
                                        Task { await container.stopForwarding(ruleID: rule.id) }
                                    }
                                )
                                .contextMenu {
                                    Button("Edit") {
                                        ruleToEdit = rule
                                    }
                                    if let host = container.activeHost {
                                        Button("Delete Rule", role: .destructive) {
                                            Task {
                                                try? await container.removeForwardingRule(ruleID: rule.id, for: host)
                                            }
                                        }
                                    }
                                }
                            }
                            .onDelete(perform: deleteRules)
                        }
                    }
                    .listStyle(.insetGrouped)
                }
            }
            .navigationTitle("Port Forwarding")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Done") { dismiss() }
                        .accessibilityIdentifier("port-forwarding-done-button")
                }
                ToolbarItemGroup(placement: .primaryAction) {
                    if container.activeForwardersCount > 0 {
                        Button("Stop All", role: .destructive) {
                            Task { await container.stopAllForwarding() }
                        }
                        .foregroundStyle(.red)
                        .accessibilityLabel("Stop all active port forwarders")
                        .accessibilityIdentifier("port-forwarding-stop-all-button")
                    }

                    Button {
                        showingAddRule = true
                    } label: {
                        Image(systemName: "plus")
                    }
                    .accessibilityLabel("Add forwarding rule")
                    .accessibilityIdentifier("port-forwarding-add-rule-button")
                }
            }
            .sheet(isPresented: $showingAddRule) {
                PortForwardingRuleEditorSheet { newRule in
                    handleSaveRule(newRule)
                }
            }
            .sheet(item: $ruleToEdit) { rule in
                PortForwardingRuleEditorSheet(existingRule: rule) { updatedRule in
                    handleSaveRule(updatedRule)
                }
            }
            .confirmationDialog(
                "Expose Port to Local Network?",
                isPresented: Binding(
                    get: { pendingNonLoopbackApprovalRule != nil },
                    set: { if !$0 { pendingNonLoopbackApprovalRule = nil } }
                ),
                titleVisibility: .visible
            ) {
                Button("Approve and Start") {
                    if let rule = pendingNonLoopbackApprovalRule {
                        Task { try? await container.startForwarding(rule: rule) }
                    }
                    pendingNonLoopbackApprovalRule = nil
                }
                Button("Cancel", role: .cancel) {
                    pendingNonLoopbackApprovalRule = nil
                }
            } message: {
                if let rule = pendingNonLoopbackApprovalRule {
                    Text("Binding to \(rule.localHost) will allow other devices on your local network to connect through this tunnel.")
                }
            }
        }
        .editorSheetPresentation()
    }

    private func requestStart(rule: PortForwardingRule) {
        if rule.requiresNonLoopbackApproval {
            pendingNonLoopbackApprovalRule = rule
        } else {
            Task {
                try? await container.startForwarding(rule: rule)
            }
        }
    }

    private func handleSaveRule(_ rule: PortForwardingRule) {
        guard let host = container.activeHost else { return }
        if isConnected && rule.enabled && rule.requiresNonLoopbackApproval {
            Task {
                try? await container.addForwardingRule(rule, for: host, autoStartIfConnected: false)
                pendingNonLoopbackApprovalRule = rule
            }
        } else {
            Task {
                try? await container.addForwardingRule(rule, for: host, autoStartIfConnected: isConnected)
            }
        }
    }

    private func deleteRules(at offsets: IndexSet) {
        guard let host = container.activeHost else { return }
        let rulesToDelete = offsets.map { allRules[$0] }
        Task {
            for rule in rulesToDelete {
                try? await container.removeForwardingRule(ruleID: rule.id, for: host)
            }
        }
    }
}
