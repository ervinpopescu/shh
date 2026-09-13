#if canImport(FileProvider)
import Foundation
import FileProvider
import ShhCore

/// Errors raised during File Provider domain management and shared catalog operations.
public enum FileProviderManagerError: LocalizedError, Equatable {
    case unsupportedMoshHost(String)
    case containerUnavailable(String)
    case domainRegistrationFailed(domain: String, reason: String)
    case domainRemovalFailed(domain: String, reason: String)
    case missingEntitlementOrSigning(String)

    public var errorDescription: String? {
        switch self {
        case .unsupportedMoshHost(let hostName):
            return "Host '\(hostName)' uses Mosh-only transport. File Provider requires SSH/SFTP and does not support Mosh."
        case .containerUnavailable(let group):
            return "Shared App Group container '\(group)' is unavailable. Check App Group entitlements and code signing."
        case .domainRegistrationFailed(let domain, let reason):
            return "Failed to register Files domain '\(domain)': \(reason)"
        case .domainRemovalFailed(let domain, let reason):
            return "Failed to remove Files domain '\(domain)': \(reason)"
        case .missingEntitlementOrSigning(let details):
            return "File Provider entitlement or code signing issue: \(details)"
        }
    }
}

/// Helper for managing File Provider domains and shared catalog persistence from the main app.
public final class FileProviderManagerHelper: Sendable {
    public static let shared = FileProviderManagerHelper()

    public let appGroupIdentifier: String
    public let customContainerURL: URL?

    public typealias DomainAdder = @Sendable (NSFileProviderDomain) async throws -> Void
    public typealias DomainRemover = @Sendable (NSFileProviderDomain) async throws -> Void
    public typealias DomainLister = @Sendable () async throws -> [NSFileProviderDomain]

    private let customDomainAdder: DomainAdder?
    private let customDomainRemover: DomainRemover?
    private let customDomainLister: DomainLister?

    public init(
        appGroupIdentifier: String = "group.com.ervinpopescu.shh",
        containerURL: URL? = nil,
        domainAdder: DomainAdder? = nil,
        domainRemover: DomainRemover? = nil,
        domainLister: DomainLister? = nil
    ) {
        self.appGroupIdentifier = appGroupIdentifier
        self.customContainerURL = containerURL
        self.customDomainAdder = domainAdder
        self.customDomainRemover = domainRemover
        self.customDomainLister = domainLister
    }

    /// Resolved base container URL for App Group storage.
    public var containerURL: URL? {
        customContainerURL ?? FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: appGroupIdentifier)
    }

    /// Synchronizes catalog snapshot and known hosts atomically into the shared App Group directory.
    @discardableResult
    public func syncSharedState(snapshot: CatalogSnapshot, trustRecords: [TrustRecord] = []) throws -> Bool {
        guard let targetBase = containerURL else {
            return false
        }

        let catalogsDirectory = targetBase.appendingPathComponent("catalogs", isDirectory: true)
        try FileManager.default.createDirectory(at: catalogsDirectory, withIntermediateDirectories: true)

        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]

        let snapshotData = try encoder.encode(snapshot)
        let snapshotURL = catalogsDirectory.appendingPathComponent("snapshot.json")
        try snapshotData.write(to: snapshotURL, options: .atomic)

        let trustData = try encoder.encode(trustRecords)
        let trustURL = catalogsDirectory.appendingPathComponent("known_hosts.json")
        try trustData.write(to: trustURL, options: .atomic)

        return true
    }

    /// Returns true if a persisted catalog snapshot file exists on disk.
    public var hasPersistedSnapshot: Bool {
        guard let targetBase = containerURL else { return false }
        let snapshotURL = targetBase.appendingPathComponent("catalogs/snapshot.json")
        return FileManager.default.fileExists(atPath: snapshotURL.path)
    }

    /// Loads the catalog snapshot from shared App Group directory if available.
    public func loadSharedSnapshot() -> CatalogSnapshot? {
        guard let targetBase = containerURL else { return nil }
        let snapshotURL = targetBase.appendingPathComponent("catalogs/snapshot.json")
        guard let data = try? Data(contentsOf: snapshotURL) else { return nil }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try? decoder.decode(CatalogSnapshot.self, from: data)
    }

    /// Loads trusted host keys from shared App Group directory if available.
    public func loadSharedTrustRecords() -> [TrustRecord]? {
        guard let targetBase = containerURL else { return nil }
        let trustURL = targetBase.appendingPathComponent("catalogs/known_hosts.json")
        guard let data = try? Data(contentsOf: trustURL) else { return nil }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try? decoder.decode([TrustRecord].self, from: data)
    }

    /// Exports the current catalog snapshot into the shared App Group directory.
    public func exportCatalogToSharedContainer(snapshot: CatalogSnapshot, trustRecords: [TrustRecord] = []) throws {
        _ = try syncSharedState(snapshot: snapshot, trustRecords: trustRecords)
    }

    /// Exports trusted host keys into the shared App Group directory.
    public func exportTrustedHostKeysToSharedContainer(records: [TrustRecord]) throws {
        guard let targetBase = containerURL else {
            return
        }

        let catalogsDirectory = targetBase.appendingPathComponent("catalogs", isDirectory: true)
        try FileManager.default.createDirectory(at: catalogsDirectory, withIntermediateDirectories: true)

        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]

        let trustData = try encoder.encode(records)
        let trustURL = catalogsDirectory.appendingPathComponent("known_hosts.json")
        try trustData.write(to: trustURL, options: .atomic)
    }

    /// Registers an NSFileProviderDomain for a configured SSH Host.
    /// Rejects Mosh-only hosts with `FileProviderManagerError.unsupportedMoshHost`.
    public func registerDomain(for host: Host) async throws {
        if case .mosh = host.connection {
            throw FileProviderManagerError.unsupportedMoshHost(host.name)
        }

        let domain = NSFileProviderDomain(
            identifier: NSFileProviderDomainIdentifier(host.id.uuidString),
            displayName: host.name
        )

        do {
            if let customAdder = customDomainAdder {
                try await customAdder(domain)
            } else {
                try await NSFileProviderManager.add(domain)
            }
        } catch {
            let errorText = error.localizedDescription
            let nsError = error as NSError
            let lower = errorText.lowercased()
            if lower.contains("entitlement") ||
               lower.contains("code signing") ||
               lower.contains("provisioning") ||
               lower.contains("not permitted") ||
               (nsError.domain == NSCocoaErrorDomain && (nsError.code == 4097 || nsError.code == 4099)) ||
               errorText.contains("com.apple.developer.fileprovider") {
                throw FileProviderManagerError.missingEntitlementOrSigning(
                    "Missing File Provider entitlement or valid provisioning profile: \(errorText)"
                )
            }
            throw FileProviderManagerError.domainRegistrationFailed(domain: host.name, reason: errorText)
        }
    }

    /// Removes an NSFileProviderDomain for a host when deleted or disabled.
    public func unregisterDomain(for host: Host) async throws {
        let domain = NSFileProviderDomain(
            identifier: NSFileProviderDomainIdentifier(host.id.uuidString),
            displayName: host.name
        )

        do {
            if let customRemover = customDomainRemover {
                try await customRemover(domain)
            } else {
                try await NSFileProviderManager.remove(domain)
            }
        } catch {
            let errorText = error.localizedDescription
            let lower = errorText.lowercased()
            if lower.contains("entitlement") || lower.contains("code signing") || lower.contains("not permitted") {
                throw FileProviderManagerError.missingEntitlementOrSigning(
                    "Missing entitlement to remove domain '\(host.name)': \(errorText)"
                )
            }
            throw FileProviderManagerError.domainRemovalFailed(domain: host.name, reason: errorText)
        }
    }

    /// Queries the registered File Provider domains.
    public func registeredDomains() async throws -> [NSFileProviderDomain] {
        if let customLister = customDomainLister {
            return try await customLister()
        }
        return try await NSFileProviderManager.domains()
    }

    /// Checks whether a host has an actively registered File Provider domain.
    public func isDomainRegistered(for host: Host) async -> Bool {
        guard let domains = try? await registeredDomains() else { return false }
        let targetID = NSFileProviderDomainIdentifier(host.id.uuidString)
        return domains.contains { $0.identifier == targetID }
    }
}
#else
import Foundation
import ShhCore

public enum FileProviderManagerError: LocalizedError, Equatable {
    case unsupportedMoshHost(String)
    case containerUnavailable(String)
    case domainRegistrationFailed(domain: String, reason: String)
    case domainRemovalFailed(domain: String, reason: String)
    case missingEntitlementOrSigning(String)

    public var errorDescription: String? {
        switch self {
        case .unsupportedMoshHost(let hostName):
            return "Host '\(hostName)' uses Mosh-only transport. File Provider requires SSH/SFTP and does not support Mosh."
        case .containerUnavailable(let group):
            return "Shared App Group container '\(group)' is unavailable. Check App Group entitlements and code signing."
        case .domainRegistrationFailed(let domain, let reason):
            return "Failed to register Files domain '\(domain)': \(reason)"
        case .domainRemovalFailed(let domain, let reason):
            return "Failed to remove Files domain '\(domain)': \(reason)"
        case .missingEntitlementOrSigning(let details):
            return "File Provider entitlement or code signing issue: \(details)"
        }
    }
}

public final class FileProviderManagerHelper: Sendable {
    public static let shared = FileProviderManagerHelper()
    public let appGroupIdentifier: String
    public let customContainerURL: URL?
    public init(appGroupIdentifier: String = "group.com.ervinpopescu.shh", containerURL: URL? = nil) {
        self.appGroupIdentifier = appGroupIdentifier
        self.customContainerURL = containerURL
    }
    public func syncSharedState(snapshot: CatalogSnapshot, trustRecords: [TrustRecord] = []) throws -> Bool { false }
    public func loadSharedSnapshot() -> CatalogSnapshot? { nil }
    public func loadSharedTrustRecords() -> [TrustRecord]? { nil }
    public func exportCatalogToSharedContainer(snapshot: CatalogSnapshot, trustRecords: [TrustRecord] = []) throws {}
    public func exportTrustedHostKeysToSharedContainer(records: [TrustRecord]) throws {}
    public func registerDomain(for host: Host) async throws {}
    public func unregisterDomain(for host: Host) async throws {}
    public func isDomainRegistered(for host: Host) async -> Bool { false }
}
#endif
