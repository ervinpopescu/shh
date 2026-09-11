import Foundation
import Network

public protocol ReachabilityMonitoring: AnyObject, Sendable {
    var isReachable: Bool { get }
    func start()
    func stop()
    var onReachabilityChange: (@Sendable (Bool) -> Void)? { get set }
}

public final class NetworkPathReachabilityMonitor: ReachabilityMonitoring, @unchecked Sendable {
    private let monitor: NWPathMonitor
    private let queue: DispatchQueue
    private let lock = NSLock()
    private var _isReachable: Bool = false
    private var _onReachabilityChange: (@Sendable (Bool) -> Void)?

    public init(queue: DispatchQueue = DispatchQueue(label: "com.ervinpopescu.shh.reachability", qos: .utility)) {
        self.monitor = NWPathMonitor()
        self.queue = queue
    }

    public var isReachable: Bool {
        lock.withLock { _isReachable }
    }

    public var onReachabilityChange: (@Sendable (Bool) -> Void)? {
        get { lock.withLock { _onReachabilityChange } }
        set { lock.withLock { _onReachabilityChange = newValue } }
    }

    public func start() {
        monitor.pathUpdateHandler = { [weak self] path in
            guard let self else { return }
            let reachable = (path.status == .satisfied)
            let changed: Bool = self.lock.withLock {
                let wasReachable = self._isReachable
                self._isReachable = reachable
                return wasReachable != reachable
            }
            if changed {
                let handler = self.onReachabilityChange
                handler?(reachable)
            }
        }
        monitor.start(queue: queue)
    }

    public func stop() {
        monitor.cancel()
    }
}

public final class MockReachabilityMonitor: ReachabilityMonitoring, @unchecked Sendable {
    private let lock = NSLock()
    private var _isReachable: Bool
    private var _onReachabilityChange: (@Sendable (Bool) -> Void)?

    public init(isReachable: Bool = true) {
        self._isReachable = isReachable
    }

    public var isReachable: Bool {
        get { lock.withLock { _isReachable } }
        set {
            let changed = lock.withLock { () -> Bool in
                let old = _isReachable
                _isReachable = newValue
                return old != newValue
            }
            if changed {
                let handler = onReachabilityChange
                handler?(newValue)
            }
        }
    }

    public var onReachabilityChange: (@Sendable (Bool) -> Void)? {
        get { lock.withLock { _onReachabilityChange } }
        set { lock.withLock { _onReachabilityChange = newValue } }
    }

    public func start() {}
    public func stop() {}

    public func setReachable(_ reachable: Bool) {
        self.isReachable = reachable
    }
}
