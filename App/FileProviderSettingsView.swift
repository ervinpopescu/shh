import SwiftUI
import ShhCore
#if canImport(FileProvider)
import FileProvider
#endif

/// Settings view for managing File Provider domains for configured SSH hosts.
struct FileProviderSettingsView: View {
    @EnvironmentObject private var container: AppContainer
    @State private var hosts: [Host] = []
    @State private var errorMessage: String? = nil
    @State private var hostErrors: [UUID: String] = [:]
    @State private var isPerformingOperation = false
    @State private var hostPendingRemoval: Host? = nil

    var body: some View {
        Form {
            Section {
                Text("File Provider domains allow you to browse remote files on your configured SSH hosts directly inside the iOS Files app. Domains sync catalog and known-host records atomically.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            } header: {
                Text("About File Provider")
            }

            if let error = errorMessage ?? container.fileProviderDomainError {
                Section {
                    VStack(alignment: .leading, spacing: 6) {
                        Label("File Provider Error", systemImage: "exclamationmark.triangle.fill")
                            .foregroundStyle(.red)
                            .font(.headline)
                        Text(error)
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    }
                    .accessibilityIdentifier("fileprovider-error-banner")
                }
            }

            Section {
                if hosts.isEmpty {
                    Text("No hosts configured yet.")
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(hosts) { host in
                        hostDomainRow(for: host)
                    }
                }
            } header: {
                Text("Configured Hosts")
            } footer: {
                Text("Mosh-only hosts cannot be registered as File Provider domains because Mosh does not support the SFTP subsystem.")
            }
        }
        .navigationTitle("File Provider Domains")
        .task {
            container.fileProviderDomainError = nil
            errorMessage = nil
            await reload()
        }
        .onDisappear {
            container.fileProviderDomainError = nil
            errorMessage = nil
        }
        .refreshable {
            await reload()
        }
        .confirmationDialog(
            "Remove Files Domain",
            isPresented: Binding(
                get: { hostPendingRemoval != nil },
                set: { if !$0 { hostPendingRemoval = nil } }
            ),
            presenting: hostPendingRemoval
        ) { host in
            Button("Remove Domain for \(host.name)", role: .destructive) {
                Task {
                    await unregisterDomain(for: host)
                }
            }
            Button("Cancel", role: .cancel) {
                hostPendingRemoval = nil
            }
        } message: { host in
            Text("Removing the domain for '\(host.name)' will unmount this host from the iOS Files app and disconnect active file operations.")
        }
    }

    @ViewBuilder
    private func hostDomainRow(for host: Host) -> some View {
        let isMosh = isMoshHost(host)
        #if canImport(FileProvider)
        let isRegistered = container.registeredFileProviderDomainIDs.contains(host.id.uuidString)
        #else
        let isRegistered = false
        #endif
        let hostError = hostErrors[host.id]

        VStack(alignment: .leading, spacing: 8) {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text(host.name)
                        .font(.headline)
                    Text("\(host.username)@\(host.hostname):\(host.port)")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Spacer()

                if isMosh {
                    Text("Unsupported (Mosh)")
                        .font(.caption2.bold())
                        .padding(.horizontal, 8)
                        .padding(.vertical, 4)
                        .background(Color.orange.opacity(0.15))
                        .foregroundStyle(.orange)
                        .clipShape(Capsule())
                        .accessibilityIdentifier("fileprovider-status-mosh-\(host.id)")
                } else if hostError != nil {
                    Text("Error")
                        .font(.caption2.bold())
                        .padding(.horizontal, 8)
                        .padding(.vertical, 4)
                        .background(Color.red.opacity(0.15))
                        .foregroundStyle(.red)
                        .clipShape(Capsule())
                        .accessibilityIdentifier("fileprovider-status-error-\(host.id)")
                } else if isRegistered {
                    Text("Active in Files")
                        .font(.caption2.bold())
                        .padding(.horizontal, 8)
                        .padding(.vertical, 4)
                        .background(Color.green.opacity(0.15))
                        .foregroundStyle(.green)
                        .clipShape(Capsule())
                        .accessibilityIdentifier("fileprovider-status-active-\(host.id)")
                } else {
                    Text("Not registered")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .accessibilityIdentifier("fileprovider-status-inactive-\(host.id)")
                }
            }

            if let hostError {
                Text(hostError)
                    .font(.caption)
                    .foregroundStyle(.red)
                    .accessibilityIdentifier("fileprovider-error-text-\(host.id)")
            }

            HStack {
                if isMosh {
                    Text("Mosh-only hosts do not support File Provider.")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                } else if isRegistered {
                    Button {
                        Task {
                            await reregisterDomain(for: host)
                        }
                    } label: {
                        Label("Re-register Domain", systemImage: "arrow.clockwise")
                            .font(.subheadline)
                    }
                    .disabled(isPerformingOperation)
                    .accessibilityLabel("Re-register domain for \(host.name)")
                    .accessibilityIdentifier("fileprovider-reregister-button-\(host.id)")

                    Spacer()

                    Button(role: .destructive) {
                        hostPendingRemoval = host
                    } label: {
                        Label("Remove Domain", systemImage: "trash")
                            .font(.subheadline)
                    }
                    .disabled(isPerformingOperation)
                    .accessibilityLabel("Remove domain for \(host.name)")
                    .accessibilityIdentifier("fileprovider-remove-button-\(host.id)")
                } else if hostError != nil {
                    Button {
                        Task {
                            await reregisterDomain(for: host)
                        }
                    } label: {
                        Label("Re-register Domain", systemImage: "arrow.clockwise")
                            .font(.subheadline)
                    }
                    .disabled(isPerformingOperation)
                    .accessibilityLabel("Re-register domain for \(host.name)")
                    .accessibilityIdentifier("fileprovider-reregister-button-\(host.id)")
                } else {
                    Button {
                        Task {
                            await registerDomain(for: host)
                        }
                    } label: {
                        Label("Register Domain", systemImage: "folder.badge.plus")
                            .font(.subheadline)
                    }
                    .disabled(isPerformingOperation)
                    .accessibilityLabel("Register domain for \(host.name)")
                    .accessibilityIdentifier("fileprovider-register-button-\(host.id)")
                }
            }
        }
        .padding(.vertical, 4)
    }

    private func isMoshHost(_ host: Host) -> Bool {
        if case .mosh = host.connection {
            return true
        }
        return false
    }

    private func reload() async {
        hosts = (try? await container.catalog.listHosts()) ?? []
        #if canImport(FileProvider)
        do {
            try await container.syncSharedCatalogAndTrust()
        } catch {
            errorMessage = error.localizedDescription
        }
        await container.refreshRegisteredDomains()
        #endif
    }

    private func registerDomain(for host: Host) async {
        guard !isMoshHost(host) else {
            errorMessage = "Host '\(host.name)' uses Mosh-only transport. File Provider requires SSH/SFTP."
            return
        }

        isPerformingOperation = true
        errorMessage = nil
        hostErrors.removeValue(forKey: host.id)

        #if canImport(FileProvider)
        do {
            try await container.registerFileProviderDomain(for: host)
            await reload()
        } catch {
            hostErrors[host.id] = error.localizedDescription
            errorMessage = error.localizedDescription
        }
        #else
        errorMessage = "File Provider is unavailable on this platform."
        #endif

        isPerformingOperation = false
    }

    private func reregisterDomain(for host: Host) async {
        guard !isMoshHost(host) else {
            errorMessage = "Host '\(host.name)' uses Mosh-only transport. File Provider requires SSH/SFTP."
            return
        }

        isPerformingOperation = true
        errorMessage = nil
        hostErrors.removeValue(forKey: host.id)

        #if canImport(FileProvider)
        do {
            try? await container.unregisterFileProviderDomain(for: host)
            try await container.syncSharedCatalogAndTrust()
            try await container.registerFileProviderDomain(for: host)
            await reload()
        } catch {
            hostErrors[host.id] = error.localizedDescription
            errorMessage = error.localizedDescription
        }
        #else
        errorMessage = "File Provider is unavailable on this platform."
        #endif

        isPerformingOperation = false
    }

    private func unregisterDomain(for host: Host) async {
        isPerformingOperation = true
        errorMessage = nil
        hostErrors.removeValue(forKey: host.id)

        #if canImport(FileProvider)
        do {
            try await container.unregisterFileProviderDomain(for: host)
            await reload()
        } catch {
            hostErrors[host.id] = error.localizedDescription
            errorMessage = error.localizedDescription
        }
        #else
        errorMessage = "File Provider is unavailable on this platform."
        #endif

        isPerformingOperation = false
    }
}
