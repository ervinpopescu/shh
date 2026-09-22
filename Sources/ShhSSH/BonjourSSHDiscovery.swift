import Foundation
#if canImport(Network)
import Network
#endif

/// Represents an SSH service discovered on the local network via Bonjour.
public struct DiscoveredSSHService: Identifiable, Hashable, Sendable, Codable {
    public let id: String
    public let name: String
    public let hostname: String
    public let port: Int
    public let domain: String

    public init(
        id: String? = nil,
        name: String,
        hostname: String? = nil,
        port: Int = 22,
        domain: String = "local."
    ) {
        let normalizedDomain: String
        if domain.isEmpty {
            normalizedDomain = "local."
        } else if domain.hasSuffix(".") {
            normalizedDomain = domain
        } else {
            normalizedDomain = domain + "."
        }

        let domainTrimmed = normalizedDomain.trimmingCharacters(in: CharacterSet(charactersIn: "."))
        let effectiveDomain = domainTrimmed.isEmpty ? "local" : domainTrimmed

        let resolvedHostname: String
        if let hostname {
            let normalizedHostname = Self.normalizedHostname(hostname)
            if !normalizedHostname.isEmpty {
                resolvedHostname = normalizedHostname
            } else {
                resolvedHostname = Self.fallbackHostname(name: name, domain: effectiveDomain)
            }
        } else {
            resolvedHostname = Self.fallbackHostname(name: name, domain: effectiveDomain)
        }

        self.name = name
        self.hostname = resolvedHostname
        self.port = port
        self.domain = normalizedDomain
        self.id = id ?? name
    }

    /// Strips leading and trailing whitespace and FQDN root dots from advertised
    /// mDNS hostnames (e.g., "server.local." -> "server.local").
    public static func normalizedHostname(_ hostname: String) -> String {
        hostname
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .trimmingCharacters(in: CharacterSet(charactersIn: "."))
    }

    private static func fallbackHostname(name: String, domain: String) -> String {
        let normalizedName = normalizedHostname(name)
        if normalizedName.lowercased().hasSuffix(".\(domain.lowercased())") ||
            normalizedName.lowercased().hasSuffix(".local") {
            return normalizedName
        }

        let sanitized = normalizedName
            .components(separatedBy: .whitespaces)
            .filter { !$0.isEmpty }
            .joined(separator: "-")
        return sanitized.isEmpty ? domain : "\(sanitized).\(domain)"
    }

    #if canImport(Network)
    public init?(endpoint: NWEndpoint) {
        switch endpoint {
        case let .service(name, _, domain, _):
            let domainStr = domain.isEmpty ? "local." : domain
            self.init(
                id: endpoint.debugDescription,
                name: name,
                port: 22,
                domain: domainStr
            )
        case let .hostPort(host, port):
            let hostStr: String
            switch host {
            case let .name(name, _):
                hostStr = name
            case let .ipv4(addr):
                hostStr = "\(addr)"
            case let .ipv6(addr):
                hostStr = "\(addr)"
            @unknown default:
                hostStr = "\(host)"
            }
            self.init(
                id: endpoint.debugDescription,
                name: hostStr,
                hostname: hostStr,
                port: Int(port.rawValue),
                domain: "local."
            )
        default:
            return nil
        }
    }
    #endif
}

extension DiscoveredSSHService {
    public static func deduplicate(_ services: [DiscoveredSSHService]) -> [DiscoveredSSHService] {
        var seenKeys = Set<String>()
        var result: [DiscoveredSSHService] = []

        for service in services {
            let key = "\(service.name.lowercased())@\(service.hostname.lowercased()):\(service.port)"
            if seenKeys.insert(key).inserted {
                result.append(service)
            }
        }

        return result.sorted {
            $0.name.localizedStandardCompare($1.name) == .orderedAscending
        }
    }
}

#if canImport(Network)
/// The resolved network endpoint information for an advertised Bonjour SSH service.
public struct BonjourServiceResolution: Equatable, Sendable {
    /// The resolved advertised mDNS hostname without trailing dots.
    public let hostname: String?
    /// The resolved port number.
    public let port: Int?

    public init(hostname: String? = nil, port: Int? = nil) {
        self.hostname = hostname
        self.port = port
    }
}

/// A mechanism for resolving a Bonjour service to its advertised mDNS hostname and port.
public protocol BonjourServiceResolving: AnyObject, Sendable {
    /// Resolves the service, returning the advertised hostname and port, or `nil` if resolution fails or is cancelled.
    func resolve() async -> BonjourServiceResolution?
    /// Cancels any in-flight resolution.
    func cancel()
}

/// Resolves a Bonjour `_ssh._tcp` service via `NetService` on the main RunLoop to determine its advertised mDNS hostname.
private final class NetServiceBonjourResolver: NSObject, BonjourServiceResolving, NetServiceDelegate, @unchecked Sendable {
    private let service: NetService
    private let timeout: TimeInterval
    private let lock = NSLock()
    private var isCancelled = false
    private var continuation: CheckedContinuation<BonjourServiceResolution?, Never>?

    init(name: String, type: String, domain: String, timeout: TimeInterval = 5.0) {
        self.service = NetService(
            domain: domain,
            type: type.hasSuffix(".") ? type : type + ".",
            name: name
        )
        self.timeout = timeout
        super.init()
        self.service.delegate = self
    }

    func resolve() async -> BonjourServiceResolution? {
        await withTaskCancellationHandler {
            await withCheckedContinuation { (continuation: CheckedContinuation<BonjourServiceResolution?, Never>) in
                let shouldStart = lock.withLock {
                    guard !self.isCancelled && !Task.isCancelled && self.continuation == nil else { return false }
                    self.continuation = continuation
                    return true
                }
                guard shouldStart else {
                    continuation.resume(returning: nil)
                    return
                }
                // NetService performs its callbacks on the run loop where it is
                // scheduled. Always start resolution on the main run loop; the
                // browser callback itself arrives on the private Network queue.
                DispatchQueue.main.async { [weak self] in
                    guard let self else { return }
                    let shouldResolve = self.lock.withLock {
                        !self.isCancelled && self.continuation != nil
                    }
                    guard shouldResolve else { return }
                    self.service.schedule(in: .main, forMode: .default)
                    self.service.resolve(withTimeout: self.timeout)
                }
            }
        } onCancel: {
            cancel()
        }
    }

    func cancel() {
        let continuation = lock.withLock { () -> CheckedContinuation<BonjourServiceResolution?, Never>? in
            isCancelled = true
            defer { self.continuation = nil }
            return self.continuation
        }
        // NetService may synchronously deliver a delegate callback from stop().
        // Do not hold the resolver lock while stopping it or that callback can
        // deadlock while trying to finish the continuation.
        service.stop()
        continuation?.resume(returning: nil)
    }

    func netServiceDidResolveAddress(_ sender: NetService) {
        sender.stop()
        let hostname = sender.hostName.flatMap(DiscoveredSSHService.normalizedHostname)
        finish(BonjourServiceResolution(hostname: hostname, port: sender.port > 0 ? sender.port : nil))
    }

    func netService(_ sender: NetService, didNotResolve errorDict: [String: NSNumber]) {
        sender.stop()
        finish(nil)
    }

    private func finish(_ result: BonjourServiceResolution?) {
        let continuation = lock.withLock { () -> CheckedContinuation<BonjourServiceResolution?, Never>? in
            defer { self.continuation = nil }
            return self.continuation
        }
        continuation?.resume(returning: result)
    }

    deinit {
        service.stop()
        finish(nil)
    }
}

public protocol BonjourServiceBrowsing: AnyObject, Sendable {
    func start(
        queue: DispatchQueue,
        onResultsChanged: @escaping @Sendable ([NWEndpoint]) -> Void,
        onStateChanged: @escaping @Sendable (NWBrowser.State) -> Void
    )
    func cancel()
}

public final class LiveBonjourServiceBrowser: BonjourServiceBrowsing, @unchecked Sendable {
    private var browser: NWBrowser?

    public init(type: String = "_ssh._tcp", domain: String? = nil) {
        let parameters = NWParameters.tcp
        // Physical iPhones can expose reachable peers through the device-to-
        // device path even when the Wi-Fi interface is unavailable. Enabling
        // this does not replace normal LAN browsing and is supported by
        // Network.framework for Bonjour browsers.
        parameters.includePeerToPeer = true
        self.browser = NWBrowser(for: .bonjour(type: type, domain: domain), using: parameters)
    }

    public func start(
        queue: DispatchQueue,
        onResultsChanged: @escaping @Sendable ([NWEndpoint]) -> Void,
        onStateChanged: @escaping @Sendable (NWBrowser.State) -> Void
    ) {
        guard let browser = browser else { return }
        browser.browseResultsChangedHandler = { results, _ in
            let endpoints = results.map { $0.endpoint }
            onResultsChanged(endpoints)
        }
        browser.stateUpdateHandler = { state in
            onStateChanged(state)
        }
        browser.start(queue: queue)
    }

    public func cancel() {
        browser?.cancel()
        browser = nil
    }
}
#endif

/// The user-visible state of local-network Bonjour discovery.
public enum BonjourDiscoveryState: Equatable, Sendable {
    /// Discovery is stopped or has not yet started.
    case idle
    /// Discovery is starting and initializing the service browser.
    case starting
    /// The service browser is active and listening for local network services.
    case searching
    /// Discovery is waiting for network connectivity or authorization with user-facing guidance.
    case waiting(message: String)
    /// Discovery encountered an error or was stopped unexpectedly.
    case failed(message: String)

    /// The user-facing explanation if discovery is waiting or failed.
    public var message: String? {
        switch self {
        case .idle, .starting, .searching:
            return nil
        case .waiting(let message), .failed(let message):
            return message
        }
    }
}

/// Discovers SSH services on the local network using Bonjour (`_ssh._tcp`) and resolves advertised mDNS hostnames.
@MainActor
public final class BonjourSSHDiscovery: ObservableObject {
    @Published public private(set) var discoveredServices: [DiscoveredSSHService] = []
    @Published public private(set) var isSearching: Bool = false
    @Published public private(set) var state: BonjourDiscoveryState = .idle

    #if canImport(Network)
    private var browser: (any BonjourServiceBrowsing)?
    private let browserFactory: @Sendable () -> any BonjourServiceBrowsing
    private let resolverFactory: @Sendable (String, String, String) -> any BonjourServiceResolving
    private let queue: DispatchQueue
    private var resolutionTasks: [String: Task<Void, Never>] = [:]
    private var resolvers: [String: any BonjourServiceResolving] = [:]
    private var resolutions: [String: BonjourServiceResolution] = [:]
    private var discoveryReferenceCount = 0
    private var discoveryGeneration = 0

    /// Creates a discovery coordinator with optional custom browser and resolver factories for testing.
    public init(
        browserFactory: (@Sendable () -> any BonjourServiceBrowsing)? = nil,
        resolverFactory: (@Sendable (String, String, String) -> any BonjourServiceResolving)? = nil,
        queue: DispatchQueue = DispatchQueue(label: "com.ervinpopescu.shh.bonjour-discovery", qos: .utility)
    ) {
        self.browserFactory = browserFactory ?? { LiveBonjourServiceBrowser() }
        self.resolverFactory = resolverFactory ?? { name, type, domain in
            NetServiceBonjourResolver(name: name, type: type, domain: domain)
        }
        self.queue = queue
    }

    /// Retains a discovery client. Discovery stays alive until every client has
    /// released its reference, which prevents a sheet transition from stopping
    /// the browser owned by the host list.
    public func startDiscovery() {
        discoveryReferenceCount += 1
        if browser == nil {
            startBrowser()
        }
    }

    /// Releases one discovery client. Extra releases are harmless, which keeps
    /// SwiftUI lifecycle callbacks safe when views are recreated.
    public func stopDiscovery() {
        guard discoveryReferenceCount > 0 else { return }
        discoveryReferenceCount -= 1
        guard discoveryReferenceCount == 0 else { return }
        stopBrowser()
    }

    /// Restarts the active browser without changing lifecycle ownership.
    public func retryDiscovery() {
        guard discoveryReferenceCount > 0 else {
            startDiscovery()
            return
        }
        stopBrowser()
        startBrowser()
    }

    private func startBrowser() {
        discoveryGeneration += 1
        let generation = discoveryGeneration
        state = .starting
        isSearching = true

        let browser = browserFactory()
        self.browser = browser

        browser.start(queue: queue) { [weak self] endpoints in
            Task { @MainActor [weak self] in
                guard let self, self.discoveryGeneration == generation else { return }
                self.handleBrowserResults(endpoints)
            }
        } onStateChanged: { [weak self] browserState in
            Task { @MainActor [weak self] in
                guard let self, self.discoveryGeneration == generation else { return }
                self.handleBrowserState(browserState)
            }
        }
    }

    private func stopBrowser() {
        discoveryGeneration += 1
        isSearching = false
        browser?.cancel()
        browser = nil
        cancelResolutions()
        resolutions.removeAll()
        state = .idle
    }

    private func handleBrowserState(_ browserState: NWBrowser.State) {
        switch browserState {
        case .setup:
            state = .starting
        case .ready:
            isSearching = true
            state = .searching
        case let .waiting(error):
            // Waiting is recoverable. Keep the browser alive so Network.framework
            // can recover when Wi-Fi or local-network authorization returns.
            isSearching = true
            state = .waiting(message: message(for: error, waiting: true))
        case let .failed(error):
            isSearching = false
            state = .failed(message: message(for: error, waiting: false))
            cancelResolutions()
        case .cancelled:
            // Explicit cancellation already transitions to idle and increments
            // the generation. This branch handles an unexpected cancellation.
            isSearching = false
            state = .failed(message: "Local Network discovery stopped unexpectedly. Tap Retry to search again.")
            cancelResolutions()
        @unknown default:
            isSearching = false
            state = .failed(message: "Local Network discovery entered an unknown state. Tap Retry to search again.")
            cancelResolutions()
        }
    }

    private func message(for error: NWError, waiting: Bool) -> String {
        let description = error.localizedDescription
        let lowercased = description.lowercased()
        if lowercased.contains("denied") || lowercased.contains("not permitted") ||
            lowercased.contains("permission") || lowercased.contains("operation not permitted") {
            return "Local Network access is denied. Enable Shh in Settings > Privacy & Security > Local Network, then tap Retry."
        }
        if waiting {
            return "The local network is unavailable. Connect to Wi-Fi or enable Local Network access; Shh will keep waiting, or tap Retry."
        }
        return "Bonjour discovery failed: \(description). Check the network and tap Retry."
    }

    public func updateDiscoveredServices(_ services: [DiscoveredSSHService]) {
        self.discoveredServices = DiscoveredSSHService.deduplicate(services)
    }

    private func handleBrowserResults(_ endpoints: [NWEndpoint]) {
        guard isSearching else { return }

        var services: [DiscoveredSSHService] = []
        var targets: [(key: String, name: String, type: String, domain: String)] = []
        var seenTargetKeys = Set<String>()

        for endpoint in endpoints {
            switch endpoint {
            case let .service(name, type, domain, _):
                let targetType = Self.normalizedServiceType(type)
                let targetDomain = Self.normalizedDomain(domain)
                let key = Self.targetKey(name: name, type: targetType, domain: targetDomain)
                if seenTargetKeys.insert(key).inserted {
                    targets.append((key: key, name: name, type: targetType, domain: targetDomain))
                }

                if let resolution = resolutions[key] {
                    let resolvedHostname = resolution.hostname
                        .map(DiscoveredSSHService.normalizedHostname)
                        .flatMap { $0.isEmpty ? nil : $0 }
                    let resolvedPort = resolution.port.flatMap { $0 > 0 ? $0 : nil } ?? 22
                    services.append(DiscoveredSSHService(
                        id: endpoint.debugDescription,
                        name: name,
                        hostname: resolvedHostname,
                        port: resolvedPort,
                        domain: targetDomain
                    ))
                } else if let service = DiscoveredSSHService(endpoint: endpoint) {
                    services.append(service)
                }
            default:
                if let service = DiscoveredSSHService(endpoint: endpoint) {
                    services.append(service)
                }
            }
        }

        discoveredServices = DiscoveredSSHService.deduplicate(services)

        let activeKeys = Set(targets.map { $0.key })
        for key in resolutionTasks.keys where !activeKeys.contains(key) {
            resolvers[key]?.cancel()
            resolutionTasks[key]?.cancel()
            resolvers[key] = nil
            resolutionTasks[key] = nil
        }
        resolutions = resolutions.filter { activeKeys.contains($0.key) }

        for target in targets where resolutionTasks[target.key] == nil && resolutions[target.key] == nil {
            let resolver = resolverFactory(target.name, target.type, target.domain)
            resolvers[target.key] = resolver
            let task = Task { @MainActor [weak self] in
                let resolution = await resolver.resolve()
                guard !Task.isCancelled, let self else { return }
                if self.isSearching, let resolution {
                    self.apply(resolution, for: target.key, name: target.name, domain: target.domain)
                } else {
                    self.resolutionTasks[target.key] = nil
                    self.resolvers[target.key] = nil
                }
            }
            resolutionTasks[target.key] = task
        }
    }

    private func cancelResolutions() {
        for resolver in resolvers.values {
            resolver.cancel()
        }
        for task in resolutionTasks.values {
            task.cancel()
        }
        resolvers.removeAll()
        resolutionTasks.removeAll()
    }

    private static func normalizedServiceType(_ type: String) -> String {
        let trimmed = type.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.hasSuffix(".") ? String(trimmed.dropLast()) : trimmed
    }

    private static func normalizedDomain(_ domain: String) -> String {
        let trimmed = domain.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return "local." }
        return trimmed.hasSuffix(".") ? trimmed : trimmed + "."
    }

    private static func targetKey(name: String, type: String, domain: String) -> String {
        "\(name.lowercased())|\(type.lowercased())|\(domain.lowercased())"
    }

    private func apply(
        _ resolution: BonjourServiceResolution,
        for targetKey: String,
        name: String,
        domain: String
    ) {
        defer {
            resolutionTasks[targetKey] = nil
            resolvers[targetKey] = nil
        }
        resolutions[targetKey] = resolution

        let resolvedHostname = resolution.hostname
            .map(DiscoveredSSHService.normalizedHostname)
            .flatMap { $0.isEmpty ? nil : $0 }
        let resolvedPort = resolution.port.flatMap { $0 > 0 ? $0 : nil }

        let updated = discoveredServices.map { current -> DiscoveredSSHService in
            guard current.name == name && current.domain == domain else { return current }
            return DiscoveredSSHService(
                id: current.id,
                name: current.name,
                hostname: resolvedHostname ?? current.hostname,
                port: resolvedPort ?? current.port,
                domain: current.domain
            )
        }
        discoveredServices = DiscoveredSSHService.deduplicate(updated)
    }

    #else

    private var discoveryReferenceCount = 0

    public init() {}
    public func startDiscovery() {
        discoveryReferenceCount += 1
        isSearching = true
        state = .searching
    }
    public func stopDiscovery() {
        guard discoveryReferenceCount > 0 else { return }
        discoveryReferenceCount -= 1
        if discoveryReferenceCount == 0 {
            isSearching = false
            state = .idle
        }
    }
    public func retryDiscovery() {
        guard discoveryReferenceCount > 0 else {
            startDiscovery()
            return
        }
        isSearching = true
        state = .searching
    }
    public func updateDiscoveredServices(_ services: [DiscoveredSSHService]) {
        self.discoveredServices = DiscoveredSSHService.deduplicate(services)
    }

    #endif

    deinit {
        #if canImport(Network)
        browser?.cancel()
        for resolver in resolvers.values {
            resolver.cancel()
        }
        for task in resolutionTasks.values {
            task.cancel()
        }
        #endif
    }
}
