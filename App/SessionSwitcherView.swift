import ShhCore
import ShhTerminal
import SwiftUI

/// Horizontal multi-session switcher bar presenting active sessions as tabs.
struct SessionSwitcherBar: View {
    @EnvironmentObject private var container: AppContainer
    @State private var showingHostPicker = false

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(container.openSessions) { session in
                    SessionTabItem(
                        session: session,
                        isSelected: container.selectedSessionID == session.id,
                        onSelect: {
                            container.selectSession(id: session.id)
                        },
                        onClose: {
                            Task {
                                await container.closeSession(id: session.id)
                            }
                        }
                    )
                }

                Button(action: {
                    showingHostPicker = true
                }) {
                    Label("New Session", systemImage: "plus")
                        .font(.caption.weight(.medium))
                        .padding(.horizontal, 10)
                        .padding(.vertical, 6)
                        .background(Color(.secondarySystemFill))
                        .clipShape(Capsule())
                }
                .accessibilityLabel("Open new session")
                .accessibilityIdentifier("session-switcher-add-button")
                .disabled(container.openSessions.count >= AppContainer.maximumConcurrentSessions)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
        }
        .background(Color(.secondarySystemBackground))
        .sheet(isPresented: $showingHostPicker) {
            NewSessionHostPickerSheet()
                .environmentObject(container)
                .presentationDetents([.medium, .large])
        }
    }
}

/// A single interactive session tab pill in the switcher bar.
struct SessionTabItem: View {
    @EnvironmentObject private var container: AppContainer
    let session: TerminalSession
    let isSelected: Bool
    let onSelect: () -> Void
    let onClose: () -> Void

    private var hostName: String {
        container.host(for: session.id)?.name ?? "Terminal"
    }

    private var statusColor: Color {
        switch session.state {
        case .connected: return .green
        case .connecting: return .yellow
        case .failed, .disconnected: return .red
        }
    }

    private var statusText: String {
        switch session.state {
        case .connected: return "Connected"
        case .connecting: return "Connecting"
        case .failed: return "Failed"
        case .disconnected: return "Disconnected"
        }
    }

    var body: some View {
        HStack(spacing: 2) {
            Button(action: onSelect) {
                HStack(spacing: 6) {
                    Circle()
                        .fill(statusColor)
                        .frame(width: 7, height: 7)

                    Text(hostName)
                        .font(.caption.weight(isSelected ? .semibold : .regular))
                        .lineLimit(1)
                        .foregroundStyle(isSelected ? Color.primary : Color.secondary)
                }
                .padding(.leading, 10)
                .padding(.trailing, 4)
                .padding(.vertical, 8)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityElement(children: .combine)
            .accessibilityLabel(
                "Session \(hostName), \(statusText), \(isSelected ? "selected" : "not selected")"
            )
            .accessibilityHint("Double tap to switch to this session")
            .accessibilityIdentifier("session-tab-\(session.id)")
            .accessibilityAddTraits(isSelected ? [.isSelected, .isButton] : [.isButton])
            .accessibilityAction(named: "Close session \(hostName)") {
                onClose()
            }

            Button(action: onClose) {
                Image(systemName: "xmark.circle.fill")
                    .font(.caption)
                    .foregroundStyle(Color.secondary.opacity(0.8))
                    .frame(minWidth: 44, minHeight: 44)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Close session \(hostName)")
            .accessibilityHint("Closes this session")
            .accessibilityIdentifier("session-close-\(session.id)")
            .accessibilityAddTraits(.isButton)
        }
        .padding(.trailing, 2)
        .background(isSelected ? Color.accentColor.opacity(0.15) : Color(.tertiarySystemFill))
        .overlay(
            Capsule()
                .stroke(isSelected ? Color.accentColor : Color.clear, lineWidth: 1.5)
        )
        .clipShape(Capsule())
        .accessibilityElement(children: .contain)
    }
}

/// Sheet presenting catalog hosts to open a new direct SSH terminal session.
struct NewSessionHostPickerSheet: View {
    @EnvironmentObject private var container: AppContainer
    @Environment(\.dismiss) private var dismiss
    @State private var availableHosts: [Host] = []

    var body: some View {
        NavigationStack {
            List {
                Section {
                    ForEach(availableHosts) { host in
                        Button {
                            dismiss()
                            Task {
                                await container.connect(to: host)
                            }
                        } label: {
                            HStack {
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(host.name)
                                        .font(.body.weight(.medium))
                                        .foregroundStyle(.primary)
                                    Text("\(host.username)@\(host.hostname):\(host.port)")
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                }
                                Spacer()
                                Image(systemName: "chevron.right")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                        }
                        .accessibilityIdentifier("new-session-host-\(host.id)")
                    }
                } header: {
                    Text("Available Hosts")
                } footer: {
                    Text(
                        "Multi-session terminals run independently in memory. Auxiliary features (SFTP, port forwarding, multiplexer) operate on a single session at a time."
                    )
                }
            }
            .navigationTitle("New Session")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
            }
            .task {
                availableHosts = (try? await container.catalog.listHosts()) ?? []
            }
        }
        .accessibilityIdentifier("new-session-host-picker")
    }
}
