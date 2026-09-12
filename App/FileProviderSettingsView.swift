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
    @State private var isPerformingOperation = false

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
            await reload()
        }
        .refreshable {
            await reload()
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

            HStack {
                if isMosh {
                    Text("Mosh-only hosts do not support File Provider.")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                } else if isRegistered {
                    Button(role: .destructive) {
                        Task {
                            await unregisterDomain(for: host)
                        }
                    } label: {
                        Label("Remove Domain", systemImage: "trash")
                            .font(.subheadline)
                    }
                    .disabled(isPerformingOperation)
                    .accessibilityIdentifier("fileprovider-remove-button-\(host.id)")
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

        #if canImport(FileProvider)
        do {
            try await container.registerFileProviderDomain(for: host)
            await reload()
        } catch {
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

        #if canImport(FileProvider)
        do {
            try await container.unregisterFileProviderDomain(for: host)
            await reload()
        } catch {
            errorMessage = error.localizedDescription
        }
        #else
        errorMessage = "File Provider is unavailable on this platform."
        #endif

        isPerformingOperation = false
    }
}
