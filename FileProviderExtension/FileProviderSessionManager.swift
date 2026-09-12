#if canImport(FileProvider)
import Foundation
import FileProvider
import ShhCore
import ShhSSH

/// Operation-scoped repository provider contract.
/// Invariant: Never keeps an unrestricted SSH/SFTP session alive indefinitely.
public protocol FileProviderRepositoryProvider: Sendable {
    func withRepository<T: Sendable>(
        hostID: UUID,
        timeoutSeconds: Double,
        operation: @escaping @Sendable (SFTPRepository) async throws -> T
    ) async throws -> T
}

/// Fallback or demo provider for testing and offline environments.
public struct DemoFileProviderRepositoryProvider: FileProviderRepositoryProvider {
    private let repository: DemoSFTPRepository

    public init(repository: DemoSFTPRepository = DemoSFTPRepository()) {
        self.repository = repository
    }

    public func withRepository<T: Sendable>(
        hostID: UUID,
        timeoutSeconds: Double,
        operation: @escaping @Sendable (SFTPRepository) async throws -> T
    ) async throws -> T {
        try await operation(repository)
    }
}

/// Production repository provider establishing short-lived, operation-scoped SFTP connections.
public final class LiveFileProviderRepositoryProvider: FileProviderRepositoryProvider, @unchecked Sendable {
    private let appGroupIdentifier: String
    private let keychainAccessGroup: String

    public init(
        appGroupIdentifier: String = "group.com.ervinpopescu.shh",
        keychainAccessGroup: String? = nil
    ) {
        self.appGroupIdentifier = appGroupIdentifier
        self.keychainAccessGroup = keychainAccessGroup ?? KeychainCredentialStore.defaultSharedAccessGroup ?? "group.com.ervinpopescu.shh"
    }

    public func withRepository<T: Sendable>(
        hostID: UUID,
        timeoutSeconds: Double,
        operation: @escaping @Sendable (SFTPRepository) async throws -> T
    ) async throws -> T {
        // Load host record from shared App Group catalog
        let host = try loadHost(hostID: hostID)
        let identity = try? loadIdentity(identityID: host.identityID ?? UUID())
        let credentialStore = KeychainCredentialStore(accessGroup: keychainAccessGroup)
        let trustRecords = loadSharedTrustRecords()
        let trustEvaluator = InMemoryTrustStore(records: trustRecords)

        var sshOptions = SSHOptions()
        if case .ssh(let opts) = host.connection {
            sshOptions = opts
        }

        // Connect with bounded operation timeout
        return try await withThrowingTaskGroup(of: T.self) { group in
            group.addTask {
                let repo = try await LiveSFTPRepository.connect(
                    host: host,
                    identity: identity,
                    trustEvaluator: trustEvaluator,
                    credentialStore: credentialStore,
                    options: sshOptions
                )
                do {
                    let result = try await operation(repo)
                    await repo.close()
                    return result
                } catch {
                    await repo.close()
                    throw error
                }
            }

            group.addTask {
                try await Task.sleep(nanoseconds: UInt64(timeoutSeconds * 1_000_000_000))
                throw SFTPRepositoryError.connectionClosed
            }

            guard let result = try await group.next() else {
                throw SFTPRepositoryError.connectionClosed
            }
            group.cancelAll()
            return result
        }
    }

    private func loadHost(hostID: UUID) throws -> Host {
        let snapshot = try loadSharedCatalogSnapshot()
        guard let host = snapshot.hosts.first(where: { $0.id == hostID }) else {
            throw SFTPRepositoryError.notFound(path: "Host \(hostID)")
        }
        return host
    }

    private func loadIdentity(identityID: UUID) throws -> IdentityDescriptor? {
        let snapshot = try loadSharedCatalogSnapshot()
        return snapshot.identities.first(where: { $0.id == identityID })
    }

    private func loadSharedTrustRecords() -> [TrustRecord] {
        guard let containerURL = FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: appGroupIdentifier) else {
            return []
        }
        let knownHostsURL = containerURL.appendingPathComponent("catalogs/known_hosts.json")
        guard let data = try? Data(contentsOf: knownHostsURL) else {
            return []
        }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return (try? decoder.decode([TrustRecord].self, from: data)) ?? []
    }

    private func loadSharedCatalogSnapshot() throws -> CatalogSnapshot {
        guard let containerURL = FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: appGroupIdentifier) else {
            return CatalogSnapshot()
        }
        let catalogURL = containerURL.appendingPathComponent("catalogs/snapshot.json")
        guard let data = try? Data(contentsOf: catalogURL) else {
            return CatalogSnapshot()
        }
        let decoder = JSONDecoder()
        return (try? decoder.decode(CatalogSnapshot.self, from: data)) ?? CatalogSnapshot()
    }
}

/// Helper managing shared App Group storage and temporary staging for File Provider.
public final class FileProviderStorageManager: @unchecked Sendable {
    public static let shared = FileProviderStorageManager()

    public let appGroupIdentifier: String
    private let fallbackBaseURL: URL

    public init(appGroupIdentifier: String = "group.com.ervinpopescu.shh") {
        self.appGroupIdentifier = appGroupIdentifier
        self.fallbackBaseURL = FileManager.default.temporaryDirectory.appendingPathComponent("ShhFileProviderFallback", isDirectory: true)
        try? FileManager.default.createDirectory(at: fallbackBaseURL, withIntermediateDirectories: true)
    }

    public var containerURL: URL {
        FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: appGroupIdentifier) ?? fallbackBaseURL
    }

    public var stagingURL: URL {
        let url = containerURL.appendingPathComponent("Staging", isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    public func temporaryFileURL(prefix: String = "fp-stage") -> URL {
        stagingURL.appendingPathComponent("\(prefix)-\(UUID().uuidString)")
    }

    public func cleanupStagingDirectory() {
        try? FileManager.default.removeItem(at: stagingURL)
    }
}
#endif
