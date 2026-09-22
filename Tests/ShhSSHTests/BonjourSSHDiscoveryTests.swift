#if canImport(XCTest)
import XCTest
import Foundation
import Combine
#if canImport(Network)
import Network
#endif
@testable import ShhSSH

#if canImport(Network)
final class MockBonjourResolver: BonjourServiceResolving, @unchecked Sendable {
    private let result: BonjourServiceResolution?
    private let waitsForCancellation: Bool
    private let lock = NSLock()
    private(set) var cancelCallCount = 0
    private(set) var resolveCallCount = 0

    init(result: BonjourServiceResolution?, waitsForCancellation: Bool = false) {
        self.result = result
        self.waitsForCancellation = waitsForCancellation
    }

    func resolve() async -> BonjourServiceResolution? {
        lock.withLock {
            resolveCallCount += 1
        }
        guard waitsForCancellation else { return result }
        try? await Task.sleep(nanoseconds: 10_000_000_000)
        return nil
    }

    func cancel() {
        lock.withLock {
            cancelCallCount += 1
        }
    }
}

final class MockBonjourBrowser: BonjourServiceBrowsing, @unchecked Sendable {
    private let lock = NSLock()
    private var resultsHandler: (@Sendable ([NWEndpoint]) -> Void)?
    private var stateHandler: (@Sendable (NWBrowser.State) -> Void)?
    private(set) var startCallCount = 0
    private(set) var cancelCallCount = 0

    func start(
        queue: DispatchQueue,
        onResultsChanged: @escaping @Sendable ([NWEndpoint]) -> Void,
        onStateChanged: @escaping @Sendable (NWBrowser.State) -> Void
    ) {
        lock.withLock {
            startCallCount += 1
            resultsHandler = onResultsChanged
            stateHandler = onStateChanged
        }
    }

    func cancel() {
        lock.withLock {
            cancelCallCount += 1
        }
    }

    func simulateResults(_ endpoints: [NWEndpoint]) {
        let handler = lock.withLock { resultsHandler }
        handler?(endpoints)
    }

    func simulateState(_ state: NWBrowser.State) {
        let handler = lock.withLock { stateHandler }
        handler?(state)
    }
}

final class MockBonjourBrowserStore: @unchecked Sendable {
    var browsers: [MockBonjourBrowser] = []
}
#endif

final class BonjourSSHDiscoveryTests: XCTestCase {

    func testDiscoveredSSHServiceModelCreation() throws {
        // Basic init with defaults
        let pi = DiscoveredSSHService(name: "raspberrypi")
        XCTAssertEqual(pi.id, "raspberrypi")
        XCTAssertEqual(pi.name, "raspberrypi")
        XCTAssertEqual(pi.hostname, "raspberrypi.local")
        XCTAssertEqual(pi.port, 22)
        XCTAssertEqual(pi.domain, "local.")

        // Custom ID and port
        let server = DiscoveredSSHService(
            id: "server-custom-id",
            name: "ubuntu-server",
            hostname: "ubuntu-server.internal",
            port: 2222,
            domain: "internal."
        )
        XCTAssertEqual(server.id, "server-custom-id")
        XCTAssertEqual(server.name, "ubuntu-server")
        XCTAssertEqual(server.hostname, "ubuntu-server.internal")
        XCTAssertEqual(server.port, 2222)
        XCTAssertEqual(server.domain, "internal.")

        // Name with spaces sanitized for default hostname
        let mac = DiscoveredSSHService(name: "Mac mini")
        XCTAssertEqual(mac.name, "Mac mini")
        XCTAssertEqual(mac.hostname, "Mac-mini.local")
        XCTAssertEqual(mac.port, 22)

        // Domain normalization without trailing dot
        let dom = DiscoveredSSHService(name: "homelab", domain: "local")
        XCTAssertEqual(dom.domain, "local.")
        XCTAssertEqual(dom.hostname, "homelab.local")

        // Name already containing .local suffix
        let alreadyLocal = DiscoveredSSHService(name: "node.local")
        XCTAssertEqual(alreadyLocal.hostname, "node.local")

        // Codable roundtrip
        let encoder = JSONEncoder()
        let data = try encoder.encode(server)
        let decoder = JSONDecoder()
        let decoded = try decoder.decode(DiscoveredSSHService.self, from: data)
        XCTAssertEqual(decoded, server)
        XCTAssertEqual(decoded.hashValue, server.hashValue)
    }

    #if canImport(Network)
    func testEndpointModelCreation() {
        let serviceEndpoint = NWEndpoint.service(
            name: "nas-box",
            type: "_ssh._tcp",
            domain: "local.",
            interface: nil
        )
        let serviceModel = DiscoveredSSHService(endpoint: serviceEndpoint)
        XCTAssertNotNil(serviceModel)
        XCTAssertEqual(serviceModel?.name, "nas-box")
        XCTAssertEqual(serviceModel?.hostname, "nas-box.local")
        XCTAssertEqual(serviceModel?.port, 22)
        XCTAssertEqual(serviceModel?.domain, "local.")

        let hostPortEndpoint = NWEndpoint.hostPort(
            host: NWEndpoint.Host("server.local"),
            port: NWEndpoint.Port(integerLiteral: 2200)
        )
        let hostPortModel = DiscoveredSSHService(endpoint: hostPortEndpoint)
        XCTAssertNotNil(hostPortModel)
        XCTAssertEqual(hostPortModel?.name, "server.local")
        XCTAssertEqual(hostPortModel?.hostname, "server.local")
        XCTAssertEqual(hostPortModel?.port, 2200)
        XCTAssertEqual(
            DiscoveredSSHService(name: "schweiz", hostname: "schweiz.local.").hostname,
            "schweiz.local"
        )
    }

    @MainActor
    func testBonjourResolutionUsesAdvertisedHostnameAndPort() async throws {
        let browser = MockBonjourBrowser()
        let resolver = MockBonjourResolver(
            result: BonjourServiceResolution(hostname: "schweiz.local.", port: 2201)
        )
        let discovery = BonjourSSHDiscovery(
            browserFactory: { browser },
            resolverFactory: { _, _, _ in resolver }
        )
        let resolutionApplied = expectation(description: "Bonjour resolution is applied")
        let observation = discovery.$discoveredServices.sink { services in
            guard let service = services.first,
                  service.hostname == "schweiz.local",
                  service.port == 2201 else { return }
            resolutionApplied.fulfill()
        }
        defer { observation.cancel() }

        discovery.startDiscovery()
        browser.simulateResults([
            NWEndpoint.service(name: "schweiz", type: "_ssh._tcp", domain: "local.", interface: nil)
        ])
        await fulfillment(of: [resolutionApplied], timeout: 1.0)

        XCTAssertEqual(discovery.discoveredServices.count, 1)
        XCTAssertEqual(discovery.discoveredServices[0].hostname, "schweiz.local")
        XCTAssertEqual(discovery.discoveredServices[0].port, 2201)
    }

    @MainActor
    func testStoppingDiscoveryCancelsBonjourResolution() async throws {
        let browser = MockBonjourBrowser()
        let resolver = MockBonjourResolver(result: nil, waitsForCancellation: true)
        let discovery = BonjourSSHDiscovery(
            browserFactory: { browser },
            resolverFactory: { _, _, _ in resolver }
        )

        discovery.startDiscovery()
        browser.simulateResults([
            NWEndpoint.service(name: "nas", type: "_ssh._tcp", domain: "local.", interface: nil)
        ])
        try await Task.sleep(nanoseconds: 50_000_000)
        discovery.stopDiscovery()

        XCTAssertEqual(resolver.cancelCallCount, 1)
    }

    @MainActor
    func testBrowserUpdatePreservesResolvedHostnameWithoutReResolving() async throws {
        let browser = MockBonjourBrowser()
        let resolver = MockBonjourResolver(
            result: BonjourServiceResolution(hostname: "schweiz.local.", port: 2201)
        )
        let discovery = BonjourSSHDiscovery(
            browserFactory: { browser },
            resolverFactory: { _, _, _ in resolver }
        )

        discovery.startDiscovery()
        browser.simulateResults([
            NWEndpoint.service(name: "schweiz", type: "_ssh._tcp", domain: "local.", interface: nil)
        ])
        try await Task.sleep(nanoseconds: 50_000_000)

        XCTAssertEqual(discovery.discoveredServices.count, 1)
        XCTAssertEqual(discovery.discoveredServices[0].hostname, "schweiz.local")
        XCTAssertEqual(discovery.discoveredServices[0].port, 2201)

        browser.simulateResults([
            NWEndpoint.service(name: "schweiz", type: "_ssh._tcp", domain: "local.", interface: nil),
            NWEndpoint.service(name: "another", type: "_ssh._tcp", domain: "local.", interface: nil)
        ])
        try await Task.sleep(nanoseconds: 50_000_000)

        let schweiz = discovery.discoveredServices.first(where: { $0.name == "schweiz" })
        XCTAssertEqual(schweiz?.hostname, "schweiz.local")
        XCTAssertEqual(schweiz?.port, 2201)
    }

    @MainActor
    func testMultiInterfaceEndpointsResolveWithoutLeaking() async throws {
        let browser = MockBonjourBrowser()
        let resolver = MockBonjourResolver(
            result: BonjourServiceResolution(hostname: "nas.local.", port: 2222)
        )
        let discovery = BonjourSSHDiscovery(
            browserFactory: { browser },
            resolverFactory: { _, _, _ in resolver }
        )

        discovery.startDiscovery()
        let ep1 = NWEndpoint.service(name: "nas", type: "_ssh._tcp", domain: "local.", interface: nil)
        let ep2 = NWEndpoint.service(name: "nas", type: "_ssh._tcp", domain: "local.", interface: nil)
        browser.simulateResults([ep1, ep2])
        try await Task.sleep(nanoseconds: 50_000_000)

        XCTAssertEqual(discovery.discoveredServices.count, 1)
        XCTAssertEqual(discovery.discoveredServices[0].hostname, "nas.local")
        XCTAssertEqual(discovery.discoveredServices[0].port, 2222)
    }
    #endif

    func testDeduplication() {
        let s1 = DiscoveredSSHService(id: "s1@en0", name: "raspberrypi", hostname: "raspberrypi.local", port: 22)
        let s2 = DiscoveredSSHService(id: "s1@en1", name: "raspberrypi", hostname: "raspberrypi.local", port: 22)
        let s3 = DiscoveredSSHService(name: "macbook", hostname: "macbook.local", port: 22)
        let s4 = DiscoveredSSHService(name: "raspberrypi", hostname: "raspberrypi.local", port: 2222) // Different port

        let deduplicated = DiscoveredSSHService.deduplicate([s1, s2, s3, s4])

        // s1 and s2 should collapse into one, while s3 and s4 remain.
        XCTAssertEqual(deduplicated.count, 3)

        // Result should be sorted alphabetically by name: macbook first, then raspberrypi (22), raspberrypi (2222)
        XCTAssertEqual(deduplicated[0].name, "macbook")
        XCTAssertEqual(deduplicated[1].name, "raspberrypi")
        XCTAssertEqual(deduplicated[2].name, "raspberrypi")
        let ports = Set(deduplicated.map { $0.port })
        XCTAssertTrue(ports.contains(22))
        XCTAssertTrue(ports.contains(2222))
    }

    #if canImport(Network)
    @MainActor
    func testStateTransitionsUseReferenceCounting() {
        let browser = MockBonjourBrowser()
        let discovery = BonjourSSHDiscovery(browserFactory: { browser })
        XCTAssertFalse(discovery.isSearching)
        XCTAssertEqual(discovery.state, .idle)
        XCTAssertTrue(discovery.discoveredServices.isEmpty)

        discovery.startDiscovery()
        discovery.startDiscovery()
        XCTAssertTrue(discovery.isSearching)
        XCTAssertEqual(browser.startCallCount, 1)

        // The first lifecycle owner can stop without cancelling the shared browser.
        discovery.stopDiscovery()
        XCTAssertTrue(discovery.isSearching)
        XCTAssertEqual(browser.cancelCallCount, 0)

        discovery.stopDiscovery()
        XCTAssertFalse(discovery.isSearching)
        XCTAssertEqual(discovery.state, .idle)
        XCTAssertEqual(browser.cancelCallCount, 1)

        // Extra releases remain harmless.
        discovery.stopDiscovery()
        XCTAssertEqual(browser.cancelCallCount, 1)
    }

    @MainActor
    func testBrowserStateTransitionsAreObservable() async throws {
        let browser = MockBonjourBrowser()
        let discovery = BonjourSSHDiscovery(browserFactory: { browser })

        discovery.startDiscovery()
        XCTAssertEqual(discovery.state, .starting)

        browser.simulateState(.setup)
        try await Task.sleep(nanoseconds: 10_000_000)
        XCTAssertEqual(discovery.state, .starting)

        browser.simulateState(.ready)
        try await Task.sleep(nanoseconds: 10_000_000)
        XCTAssertEqual(discovery.state, .searching)
        XCTAssertTrue(discovery.isSearching)

        browser.simulateState(.waiting(.posix(.ENETDOWN)))
        try await Task.sleep(nanoseconds: 10_000_000)
        if case let .waiting(message) = discovery.state {
            XCTAssertFalse(message.isEmpty)
        } else {
            XCTFail("Expected waiting state")
        }
        XCTAssertTrue(discovery.isSearching)

        browser.simulateState(.failed(.posix(.ECONNABORTED)))
        try await Task.sleep(nanoseconds: 10_000_000)
        if case let .failed(message) = discovery.state {
            XCTAssertFalse(message.isEmpty)
        } else {
            XCTFail("Expected failed state")
        }
        XCTAssertFalse(discovery.isSearching)

        browser.simulateState(.failed(.posix(.EPERM)))
        try await Task.sleep(nanoseconds: 10_000_000)
        if case let .failed(message) = discovery.state {
            XCTAssertTrue(message.contains("Local Network access is denied"))
        } else {
            XCTFail("Expected denied access state")
        }
    }

    @MainActor
    func testRetryStartsDiscoveryWithoutExistingOwner() {
        let browser = MockBonjourBrowser()
        let discovery = BonjourSSHDiscovery(browserFactory: { browser })

        discovery.retryDiscovery()

        XCTAssertTrue(discovery.isSearching)
        XCTAssertEqual(discovery.state, .starting)
        XCTAssertEqual(browser.startCallCount, 1)
        discovery.stopDiscovery()
    }

    @MainActor
    func testRetryRestartsAfterBrowserFailureWithoutReleasingOwner() async throws {
        let browserStore = MockBonjourBrowserStore()
        let discovery = BonjourSSHDiscovery(browserFactory: {
            let browser = MockBonjourBrowser()
            browserStore.browsers.append(browser)
            return browser
        })

        discovery.startDiscovery()
        XCTAssertEqual(browserStore.browsers.count, 1)
        browserStore.browsers[0].simulateState(.failed(.posix(.ECONNABORTED)))
        try await Task.sleep(nanoseconds: 10_000_000)

        discovery.retryDiscovery()
        XCTAssertEqual(browserStore.browsers.count, 2)
        XCTAssertEqual(browserStore.browsers[0].cancelCallCount, 1)
        XCTAssertTrue(discovery.isSearching)
        XCTAssertEqual(discovery.state, .starting)

        browserStore.browsers[1].simulateState(.ready)
        try await Task.sleep(nanoseconds: 10_000_000)
        XCTAssertEqual(discovery.state, .searching)
        discovery.stopDiscovery()
    }
    #endif

    #if canImport(Network)
    @MainActor
    func testMockBrowserDiscoveryWorkflow() async throws {
        var createdBrowsers: [MockBonjourBrowser] = []
        let factory: @Sendable () -> any BonjourServiceBrowsing = {
            let b = MockBonjourBrowser()
            Task { @MainActor in
                createdBrowsers.append(b)
            }
            return b
        }

        let discovery = BonjourSSHDiscovery(browserFactory: factory)
        XCTAssertFalse(discovery.isSearching)

        discovery.startDiscovery()
        XCTAssertTrue(discovery.isSearching)

        // Yield to allow browser creation on MainActor
        try await Task.sleep(nanoseconds: 50_000_000)
        XCTAssertEqual(createdBrowsers.count, 1)
        let mockBrowser = createdBrowsers[0]
        XCTAssertEqual(mockBrowser.startCallCount, 1)

        // Simulate discovering endpoints (including a duplicate across interfaces)
        let ep1 = NWEndpoint.service(name: "rpi", type: "_ssh._tcp", domain: "local.", interface: nil)
        let ep2 = NWEndpoint.service(name: "rpi", type: "_ssh._tcp", domain: "local.", interface: nil)
        let ep3 = NWEndpoint.service(name: "macmini", type: "_ssh._tcp", domain: "local.", interface: nil)

        mockBrowser.simulateResults([ep1, ep2, ep3])

        // Yield to allow Task dispatch to MainActor
        try await Task.sleep(nanoseconds: 50_000_000)

        XCTAssertEqual(discovery.discoveredServices.count, 2)
        XCTAssertEqual(discovery.discoveredServices.map { $0.name }, ["macmini", "rpi"])

        // Test browser cancellation via state update
        mockBrowser.simulateState(.cancelled)
        try await Task.sleep(nanoseconds: 50_000_000)
        XCTAssertFalse(discovery.isSearching)

        // Stop discovery explicitly
        discovery.stopDiscovery()
        XCTAssertFalse(discovery.isSearching)
        XCTAssertEqual(mockBrowser.cancelCallCount, 1)

        // Safe mock/stop calls: repeat stop
        discovery.stopDiscovery()
        XCTAssertEqual(mockBrowser.cancelCallCount, 1)

        // Restart creates second browser instance
        discovery.startDiscovery()
        XCTAssertTrue(discovery.isSearching)
        try await Task.sleep(nanoseconds: 50_000_000)
        XCTAssertEqual(createdBrowsers.count, 2)
        XCTAssertEqual(createdBrowsers[1].startCallCount, 1)

        discovery.stopDiscovery()
        XCTAssertFalse(discovery.isSearching)
        XCTAssertEqual(createdBrowsers[1].cancelCallCount, 1)
    }
    @MainActor
    func testDiscoveryStateMessagesExposeActionableFailures() {
        XCTAssertNil(BonjourDiscoveryState.idle.message)
        XCTAssertNil(BonjourDiscoveryState.starting.message)
        XCTAssertNil(BonjourDiscoveryState.searching.message)
        XCTAssertEqual(BonjourDiscoveryState.waiting(message: "waiting").message, "waiting")
        XCTAssertEqual(BonjourDiscoveryState.failed(message: "failed").message, "failed")
    }

    @MainActor
    func testLiveBonjourBrowserCanBeCancelled() {
        let browser = LiveBonjourServiceBrowser()
        browser.cancel()
    }

    @MainActor
    func testHostPortResultsBecomeDiscoveredServices() async throws {
        let browser = MockBonjourBrowser()
        let discovery = BonjourSSHDiscovery(browserFactory: { browser })
        discovery.startDiscovery()

        browser.simulateResults([
            NWEndpoint.hostPort(
                host: NWEndpoint.Host("server.local"),
                port: NWEndpoint.Port(integerLiteral: 2200)
            )
        ])
        try await Task.sleep(nanoseconds: 50_000_000)

        XCTAssertEqual(discovery.discoveredServices.count, 1)
        XCTAssertEqual(discovery.discoveredServices[0].hostname, "server.local")
        XCTAssertEqual(discovery.discoveredServices[0].port, 2200)
        discovery.stopDiscovery()
    }

    @MainActor
    func testRemovingEndpointCancelsObsoleteResolution() async throws {
        let browser = MockBonjourBrowser()
        let resolver = MockBonjourResolver(result: nil, waitsForCancellation: true)
        let discovery = BonjourSSHDiscovery(
            browserFactory: { browser },
            resolverFactory: { _, _, _ in resolver }
        )
        discovery.startDiscovery()
        browser.simulateResults([
            NWEndpoint.service(name: "nas", type: "_ssh._tcp", domain: "local.", interface: nil)
        ])
        try await Task.sleep(nanoseconds: 50_000_000)

        browser.simulateResults([])
        try await Task.sleep(nanoseconds: 50_000_000)

        XCTAssertEqual(resolver.cancelCallCount, 1)
        discovery.stopDiscovery()
    }

    @MainActor
    func testFailedResolutionIsRetriedForTheSameService() async throws {
        let browser = MockBonjourBrowser()
        let resolver = MockBonjourResolver(result: nil)
        let discovery = BonjourSSHDiscovery(
            browserFactory: { browser },
            resolverFactory: { _, _, _ in resolver }
        )
        let endpoint = NWEndpoint.service(
            name: "nas",
            type: "_ssh._tcp",
            domain: "local.",
            interface: nil
        )
        discovery.startDiscovery()
        browser.simulateResults([endpoint])
        try await Task.sleep(nanoseconds: 50_000_000)
        browser.simulateResults([endpoint])
        try await Task.sleep(nanoseconds: 50_000_000)

        XCTAssertEqual(resolver.resolveCallCount, 2)
        discovery.stopDiscovery()
    }
    #endif

    @MainActor
    func testManualServiceUpdate() {
        let discovery = BonjourSSHDiscovery()
        let services = [
            DiscoveredSSHService(name: "server1"),
            DiscoveredSSHService(name: "server1"), // duplicate
            DiscoveredSSHService(name: "alpha")
        ]

        discovery.updateDiscoveredServices(services)
        XCTAssertEqual(discovery.discoveredServices.count, 2)
        XCTAssertEqual(discovery.discoveredServices[0].name, "alpha")
        XCTAssertEqual(discovery.discoveredServices[1].name, "server1")
    }
}
#endif
