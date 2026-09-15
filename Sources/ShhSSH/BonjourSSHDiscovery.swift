import Foundation
#if canImport(Network)
import Network
#endif

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
        if let hostname, !hostname.isEmpty {
            resolvedHostname = hostname
        } else if name.lowercased().hasSuffix(".\(effectiveDomain.lowercased())") || name.lowercased().hasSuffix(".local") {
            resolvedHostname = name
        } else {
            let sanitized = name
                .trimmingCharacters(in: .whitespacesAndNewlines)
                .components(separatedBy: .whitespaces)
                .filter { !$0.isEmpty }
                .joined(separator: "-")
            resolvedHostname = "\(sanitized).\(effectiveDomain)"
        }

        self.name = name
        self.hostname = resolvedHostname
        self.port = port
        self.domain = normalizedDomain
        self.id = id ?? name
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
        self.browser = NWBrowser(for: .bonjour(type: type, domain: domain), using: .tcp)
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

@MainActor
public final class BonjourSSHDiscovery: ObservableObject {
    @Published public private(set) var discoveredServices: [DiscoveredSSHService] = []
    @Published public private(set) var isSearching: Bool = false

    #if canImport(Network)
    private var browser: (any BonjourServiceBrowsing)?
    private let browserFactory: @Sendable () -> any BonjourServiceBrowsing
    private let queue: DispatchQueue

    public init(
        browserFactory: (@Sendable () -> any BonjourServiceBrowsing)? = nil,
        queue: DispatchQueue = DispatchQueue(label: "com.ervinpopescu.shh.bonjour-discovery", qos: .utility)
    ) {
        self.browserFactory = browserFactory ?? { LiveBonjourServiceBrowser() }
        self.queue = queue
    }

    public func startDiscovery() {
        guard !isSearching else { return }
        isSearching = true

        let browser = browserFactory()
        self.browser = browser

        browser.start(queue: queue) { [weak self] endpoints in
            let services = endpoints.compactMap { DiscoveredSSHService(endpoint: $0) }
            let deduplicated = DiscoveredSSHService.deduplicate(services)
            Task { @MainActor [weak self] in
                guard let self, self.isSearching else { return }
                self.discoveredServices = deduplicated
            }
        } onStateChanged: { [weak self] state in
            Task { @MainActor [weak self] in
                guard let self else { return }
                switch state {
                case .cancelled:
                    self.isSearching = false
                case .failed:
                    self.isSearching = false
                default:
                    break
                }
            }
        }
    }

    public func stopDiscovery() {
        guard isSearching || browser != nil else { return }
        isSearching = false
        browser?.cancel()
        browser = nil
    }

    public func updateDiscoveredServices(_ services: [DiscoveredSSHService]) {
        self.discoveredServices = DiscoveredSSHService.deduplicate(services)
    }

    #else

    public init() {}
    public func startDiscovery() { isSearching = true }
    public func stopDiscovery() { isSearching = false }
    public func updateDiscoveredServices(_ services: [DiscoveredSSHService]) {
        self.discoveredServices = DiscoveredSSHService.deduplicate(services)
    }

    #endif

    deinit {
        #if canImport(Network)
        browser?.cancel()
        #endif
    }
}
