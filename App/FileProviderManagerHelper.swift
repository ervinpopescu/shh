#if canImport(FileProvider)
import Foundation
import FileProvider
import ShhCore

/// Helper for managing File Provider domains and shared catalog persistence from the main app.
public final class FileProviderManagerHelper: Sendable {
    public static let shared = FileProviderManagerHelper()

    public let appGroupIdentifier: String

    public init(appGroupIdentifier: String = "group.com.ervinpopescu.shh") {
        self.appGroupIdentifier = appGroupIdentifier
    }

    /// Exports the current catalog snapshot into the shared App Group directory.
    public func exportCatalogToSharedContainer(snapshot: CatalogSnapshot, trustRecords: [TrustRecord] = []) throws {
        guard let containerURL = FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: appGroupIdentifier) else {
            return
        }

        let catalogsDirectory = containerURL.appendingPathComponent("catalogs", isDirectory: true)
        try FileManager.default.createDirectory(at: catalogsDirectory, withIntermediateDirectories: true)

        let targetURL = catalogsDirectory.appendingPathComponent("snapshot.json")
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(snapshot)
        try data.write(to: targetURL, options: .atomic)

        if !trustRecords.isEmpty {
            try exportTrustedHostKeysToSharedContainer(records: trustRecords)
        }
    }

    /// Exports trusted host keys into the shared App Group directory.
    public func exportTrustedHostKeysToSharedContainer(records: [TrustRecord]) throws {
        guard let containerURL = FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: appGroupIdentifier) else {
            return
        }

        let catalogsDirectory = containerURL.appendingPathComponent("catalogs", isDirectory: true)
        try FileManager.default.createDirectory(at: catalogsDirectory, withIntermediateDirectories: true)

        let targetURL = catalogsDirectory.appendingPathComponent("known_hosts.json")
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(records)
        try data.write(to: targetURL, options: .atomic)
    }

    /// Registers an NSFileProviderDomain for a configured SSH Host.
    public func registerDomain(for host: Host) async throws {
        let domain = NSFileProviderDomain(
            identifier: NSFileProviderDomainIdentifier(host.id.uuidString),
            displayName: host.name
        )
        try await NSFileProviderManager.add(domain)
    }

    /// Removes an NSFileProviderDomain for a host when deleted or disabled.
    public func unregisterDomain(for host: Host) async throws {
        let domain = NSFileProviderDomain(
            identifier: NSFileProviderDomainIdentifier(host.id.uuidString),
            displayName: host.name
        )
        try await NSFileProviderManager.remove(domain)
    }
}
#endif
