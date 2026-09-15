import Foundation
#if canImport(FileProvider)
import FileProvider
#endif
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
            return "Shared App Group container '\(group)' is unavailable. Hosts remain available from local storage. Check App Group entitlements and code signing."
        case .domainRegistrationFailed(let domain, let reason):
            return "Failed to register Files domain '\(domain)': \(reason)"
        case .domainRemovalFailed(let domain, let reason):
            return "Failed to remove Files domain '\(domain)': \(reason)"
        case .missingEntitlementOrSigning(let details):
            return "File Provider entitlement or code signing issue: \(details)"
        }
    }
}

/// Result of a non-destructive catalog read. A failed shared read must not be
/// interpreted as an empty catalog.
public enum CatalogPersistenceReadState: Equatable, Sendable {
    case valid
    case notFound
    case unavailable
    case invalid
}

public struct CatalogPersistenceReadResult: Sendable {
    public let state: CatalogPersistenceReadState
    public let snapshot: CatalogSnapshot?

    public init(state: CatalogPersistenceReadState, snapshot: CatalogSnapshot? = nil) {
        self.state = state
        self.snapshot = snapshot
    }
}

/// Helper for managing File Provider domains and catalog persistence.
///
/// The App Group is preferred, but Application Support is always maintained as
/// a local fallback. This is important for simulator and unsigned builds where
/// the security-scoped group URL can be unavailable.
public final class FileProviderManagerHelper: @unchecked Sendable {
    public static let shared = FileProviderManagerHelper()

    public let appGroupIdentifier: String
    public let customContainerURL: URL?
    public let customLocalContainerURL: URL?
    public typealias ContainerURLResolver = @Sendable (String) -> URL?

    private let containerURLResolver: ContainerURLResolver

    #if canImport(FileProvider)
    public typealias DomainAdder = @Sendable (NSFileProviderDomain) async throws -> Void
    public typealias DomainRemover = @Sendable (NSFileProviderDomain) async throws -> Void
    public typealias DomainLister = @Sendable () async throws -> [NSFileProviderDomain]
    #else
    public typealias DomainAdder = @Sendable (Any) async throws -> Void
    public typealias DomainRemover = @Sendable (Any) async throws -> Void
    public typealias DomainLister = @Sendable () async throws -> [Any]
    #endif

    private let customDomainAdder: DomainAdder?
    private let customDomainRemover: DomainRemover?
    private let customDomainLister: DomainLister?

    public init(
        appGroupIdentifier: String = "group.com.ervinpopescu.shh",
        containerURL: URL? = nil,
        localContainerURL: URL? = nil,
        containerURLResolver: ContainerURLResolver? = nil,
        domainAdder: DomainAdder? = nil,
        domainRemover: DomainRemover? = nil,
        domainLister: DomainLister? = nil
    ) {
        self.appGroupIdentifier = appGroupIdentifier
        self.customContainerURL = containerURL
        self.customLocalContainerURL = localContainerURL
        self.containerURLResolver = containerURLResolver ?? { identifier in
            FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: identifier)
        }
        self.customDomainAdder = domainAdder
        self.customDomainRemover = domainRemover
        self.customDomainLister = domainLister
    }

    /// Resolved base container URL for App Group storage.
    public var containerURL: URL? {
        customContainerURL ?? containerURLResolver(appGroupIdentifier)
    }

    /// Whether the signed process can currently access the shared App Group.
    public var isSharedContainerAvailable: Bool { containerURL != nil }

    /// Local Application Support storage used whenever the App Group is absent.
    public var localContainerURL: URL {
        if let customLocalContainerURL { return customLocalContainerURL }
        if let customContainerURL { return customContainerURL }
        let applicationSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        return applicationSupport.appendingPathComponent("Shh", isDirectory: true)
    }

    private var encoder: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return encoder
    }

    private var decoder: JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }

    private func catalogURL(in base: URL) -> URL {
        base.appendingPathComponent("catalogs/snapshot.json")
    }

    private func trustURL(in base: URL) -> URL {
        base.appendingPathComponent("catalogs/known_hosts.json")
    }

    private func readSnapshot(in base: URL) -> CatalogPersistenceReadResult {
        let url = catalogURL(in: base)
        guard FileManager.default.fileExists(atPath: url.path) else {
            return CatalogPersistenceReadResult(state: .notFound)
        }
        guard let data = try? Data(contentsOf: url),
              let snapshot = try? decoder.decode(CatalogSnapshot.self, from: data) else {
            return CatalogPersistenceReadResult(state: .invalid)
        }
        return CatalogPersistenceReadResult(state: .valid, snapshot: snapshot)
    }

    /// Reads the shared snapshot first, then falls back to local storage.
    /// Decode and access failures are reported without manufacturing an empty snapshot.
    public func loadCatalogSnapshot() -> CatalogPersistenceReadResult {
        if let shared = containerURL {
            let sharedResult = readSnapshot(in: shared)
            if sharedResult.state == .valid { return sharedResult }
            let localResult = readSnapshot(in: localContainerURL)
            if localResult.state == .valid { return localResult }
            if sharedResult.state == .invalid || localResult.state == .invalid {
                return CatalogPersistenceReadResult(state: .invalid)
            }
            return CatalogPersistenceReadResult(state: .notFound)
        }

        let localResult = readSnapshot(in: localContainerURL)
        if localResult.state == .valid { return localResult }
        if localResult.state == .invalid {
            return localResult
        }
        return CatalogPersistenceReadResult(state: .unavailable)
    }

    /// Synchronizes catalog snapshot and known hosts atomically into local and,
    /// when available, shared storage. No data is removed on access failure.
    @discardableResult
    public func syncSharedState(snapshot: CatalogSnapshot, trustRecords: [TrustRecord] = []) throws -> Bool {
        let snapshotData = try encoder.encode(snapshot)
        let trustData = try encoder.encode(trustRecords)
        var didWrite = false
        var failures: [Error] = []
        do {
            try write(snapshotData: snapshotData, trustData: trustData, in: localContainerURL)
            didWrite = true
        } catch { failures.append(error) }
        if let shared = containerURL, shared != localContainerURL {
            do {
                try write(snapshotData: snapshotData, trustData: trustData, in: shared)
                didWrite = true
            } catch { failures.append(error) }
        }
        if !didWrite, let failure = failures.first { throw failure }
        return didWrite
    }

    /// Writes only the local fallback. Used after a shared decode/access error
    /// so an explicit user edit cannot overwrite an unreadable existing catalog.
    @discardableResult
    public func syncLocalState(snapshot: CatalogSnapshot, trustRecords: [TrustRecord] = []) throws -> Bool {
        let snapshotData = try encoder.encode(snapshot)
        let trustData = try encoder.encode(trustRecords)
        try write(snapshotData: snapshotData, trustData: trustData, in: localContainerURL)
        return true
    }

    private func write(snapshotData: Data, trustData: Data, in base: URL) throws {
        let catalogsDirectory = base.appendingPathComponent("catalogs", isDirectory: true)
        try FileManager.default.createDirectory(at: catalogsDirectory, withIntermediateDirectories: true)
        try snapshotData.write(to: catalogsDirectory.appendingPathComponent("snapshot.json"), options: .atomic)
        try trustData.write(to: catalogsDirectory.appendingPathComponent("known_hosts.json"), options: .atomic)
    }

    /// Returns true if either persistence location contains a snapshot file.
    public var hasPersistedSnapshot: Bool {
        if let shared = containerURL, FileManager.default.fileExists(atPath: catalogURL(in: shared).path) {
            return true
        }
        return FileManager.default.fileExists(atPath: catalogURL(in: localContainerURL).path)
    }

    /// Loads the catalog snapshot from shared App Group storage, then local fallback.
    public func loadSharedSnapshot() -> CatalogSnapshot? {
        loadCatalogSnapshot().snapshot
    }

    /// Loads trusted host keys from shared storage, then local fallback.
    public func loadSharedTrustRecords() -> [TrustRecord]? {
        if let shared = containerURL,
           let records = readTrustRecords(in: shared) {
            return records
        }
        return readTrustRecords(in: localContainerURL)
    }

    private func readTrustRecords(in base: URL) -> [TrustRecord]? {
        guard let data = try? Data(contentsOf: trustURL(in: base)) else { return nil }
        return try? decoder.decode([TrustRecord].self, from: data)
    }

    public func exportCatalogToSharedContainer(snapshot: CatalogSnapshot, trustRecords: [TrustRecord] = []) throws {
        _ = try syncSharedState(snapshot: snapshot, trustRecords: trustRecords)
    }

    public func exportTrustedHostKeysToSharedContainer(records: [TrustRecord]) throws {
        let snapshot = loadCatalogSnapshot().snapshot ?? CatalogSnapshot()
        try syncSharedState(snapshot: snapshot, trustRecords: records)
    }

    #if canImport(FileProvider)
    /// Registers an NSFileProviderDomain for a configured SSH Host.
    public func registerDomain(for host: ShhCore.Host) async throws {
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
            if lower.contains("entitlement") || lower.contains("code signing") ||
                lower.contains("provisioning") || lower.contains("not permitted") ||
                (nsError.domain == NSCocoaErrorDomain && (nsError.code == 4097 || nsError.code == 4099)) ||
                errorText.contains("com.apple.developer.fileprovider") {
                throw FileProviderManagerError.missingEntitlementOrSigning(
                    "Missing File Provider entitlement or valid provisioning profile: \(errorText)"
                )
            }
            throw FileProviderManagerError.domainRegistrationFailed(domain: host.name, reason: errorText)
        }
    }

    public func unregisterDomain(for host: ShhCore.Host) async throws {
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

    public func registeredDomains() async throws -> [NSFileProviderDomain] {
        if let customDomainLister { return try await customDomainLister() }
        return try await NSFileProviderManager.domains()
    }

    public func isDomainRegistered(for host: ShhCore.Host) async -> Bool {
        guard let domains = try? await registeredDomains() else { return false }
        let targetID = NSFileProviderDomainIdentifier(host.id.uuidString)
        return domains.contains { $0.identifier == targetID }
    }
    #else
    public func registerDomain(for host: ShhCore.Host) async throws {}
    public func unregisterDomain(for host: ShhCore.Host) async throws {}
    public func isDomainRegistered(for host: ShhCore.Host) async -> Bool { false }
    #endif
}
