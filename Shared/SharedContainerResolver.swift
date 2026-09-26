import Foundation

/// The one App Group identifier shared by the application and File Provider.
public enum SharedAppGroupConfiguration {
    public static let identifier = "group.com.ervinpopescu.shh"
}

/// Describes where shared-state operations are being stored.
public enum SharedContainerLocation: Equatable, Sendable {
    case appGroup(URL)
    case simulatorFallback(URL)
    case unavailable

    public var url: URL? {
        switch self {
        case .appGroup(let url), .simulatorFallback(let url):
            return url
        case .unavailable:
            return nil
        }
    }

    public var isAppGroup: Bool {
        if case .appGroup = self { return true }
        return false
    }
}

/// Resolves the App Group once at the shared-container boundary.
///
/// Simulator fallback storage is intentionally enabled only for simulator
/// builds. It is isolated by the group identifier and process sandbox, and is
/// never used as a device fallback when the entitlement is unavailable.
public struct SharedContainerResolver: Sendable {
    public typealias URLResolver = @Sendable (String) -> URL?

    public let groupIdentifier: String
    private let urlResolver: URLResolver
    private let simulatorFallbackURL: URL?
    private let allowSimulatorFallback: Bool

    public init(
        groupIdentifier: String = SharedAppGroupConfiguration.identifier,
        urlResolver: URLResolver? = nil,
        simulatorFallbackURL: URL? = nil,
        allowSimulatorFallback: Bool? = nil
    ) {
        self.groupIdentifier = groupIdentifier
        self.urlResolver =
            urlResolver ?? { identifier in
                FileManager.default.containerURL(
                    forSecurityApplicationGroupIdentifier: identifier
                )
            }
        self.simulatorFallbackURL =
            simulatorFallbackURL ?? Self.defaultSimulatorFallbackURL(for: groupIdentifier)
        self.allowSimulatorFallback = allowSimulatorFallback ?? Self.defaultAllowSimulatorFallback
    }

    public var location: SharedContainerLocation {
        if let url = urlResolver(groupIdentifier) {
            return .appGroup(url)
        }
        if allowSimulatorFallback, let simulatorFallbackURL {
            return .simulatorFallback(simulatorFallbackURL)
        }
        return .unavailable
    }

    public var containerURL: URL? { location.url }
    public var appGroupURL: URL? { location.isAppGroup ? location.url : nil }
    public var isUsingSimulatorFallback: Bool {
        if case .simulatorFallback = location { return true }
        return false
    }

    private static var defaultAllowSimulatorFallback: Bool {
        #if targetEnvironment(simulator)
        return true
        #else
        return false
        #endif
    }

    private static func defaultSimulatorFallbackURL(for groupIdentifier: String) -> URL? {
        #if targetEnvironment(simulator)
        guard
            let applicationSupport = FileManager.default.urls(
                for: .applicationSupportDirectory,
                in: .userDomainMask
            ).first
        else {
            return nil
        }
        let safeIdentifier = groupIdentifier.replacingOccurrences(
            of: "/", with: "_"
        )
        return
            applicationSupport
            .appendingPathComponent(
                "Shh/SimulatorSharedContainers", isDirectory: true
            )
            .appendingPathComponent(
                safeIdentifier, isDirectory: true
            )
        #else
        return nil
        #endif
    }
}
