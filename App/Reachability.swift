import Foundation
import Network
import ShhCore

public protocol ReachabilityMonitoring: AnyObject, Sendable {
    var isReachable: Bool { get }
    var currentInterfaceType: NetworkInterfaceType { get }
    func start()
    func stop()
    var onReachabilityChange: (@Sendable (Bool) -> Void)? { get set }
    var onInterfaceChange: (@Sendable (NetworkInterfaceType, NetworkRoamingState) -> Void)? { get set }
}

public extension ReachabilityMonitoring {
    var currentInterfaceType: NetworkInterfaceType { .unknown }
    var onInterfaceChange: (@Sendable (NetworkInterfaceType, NetworkRoamingState) -> Void)? {
        get { nil }
        set {}
    }
}

public final class NetworkPathReachabilityMonitor: ReachabilityMonitoring, @unchecked Sendable {
    private let monitor: NWPathMonitor
    private let queue: DispatchQueue
    private let lock = NSLock()
    private var _isReachable: Bool = false
    private var _currentInterfaceType: NetworkInterfaceType = .unknown
    private var _onReachabilityChange: (@Sendable (Bool) -> Void)?
    private var _onInterfaceChange: (@Sendable (NetworkInterfaceType, NetworkRoamingState) -> Void)?

    public init(queue: DispatchQueue = DispatchQueue(label: "com.ervinpopescu.shh.reachability", qos: .utility)) {
        self.monitor = NWPathMonitor()
        self.queue = queue
    }

    public var isReachable: Bool {
        lock.withLock { _isReachable }
    }

    public var currentInterfaceType: NetworkInterfaceType {
        lock.withLock { _currentInterfaceType }
    }

    public var onReachabilityChange: (@Sendable (Bool) -> Void)? {
        get { lock.withLock { _onReachabilityChange } }
        set { lock.withLock { _onReachabilityChange = newValue } }
    }

    public var onInterfaceChange: (@Sendable (NetworkInterfaceType, NetworkRoamingState) -> Void)? {
        get { lock.withLock { _onInterfaceChange } }
        set { lock.withLock { _onInterfaceChange = newValue } }
    }

    public func start() {
        monitor.pathUpdateHandler = { [weak self] path in
            guard let self else { return }
            let reachable = (path.status == .satisfied)
            let interfaceType: NetworkInterfaceType
            if path.usesInterfaceType(.wifi) {
                interfaceType = .wifi
            } else if path.usesInterfaceType(.cellular) {
                interfaceType = .cellular
            } else if path.usesInterfaceType(.wiredEthernet) {
                interfaceType = .wired
            } else if path.usesInterfaceType(.loopback) {
                interfaceType = .loopback
            } else if path.usesInterfaceType(.other) {
                interfaceType = .other
            } else {
                interfaceType = .unknown
            }

            let isExpensive = path.isExpensive
            let isConstrained = path.isConstrained

            let (reachabilityChanged, interfaceChanged, oldInterface) = self.lock.withLock { () -> (Bool, Bool, NetworkInterfaceType) in
                let wasReachable = self._isReachable
                let oldInterface = self._currentInterfaceType
                self._isReachable = reachable
                self._currentInterfaceType = interfaceType
                let iChanged = (oldInterface != .unknown && oldInterface != interfaceType)
                return (wasReachable != reachable, iChanged, oldInterface)
            }

            if reachabilityChanged {
                self.onReachabilityChange?(reachable)
            }

            if interfaceChanged {
                let roamingState = NetworkRoamingState(
                    previousInterface: oldInterface,
                    currentInterface: interfaceType,
                    isExpensive: isExpensive,
                    isConstrained: isConstrained
                )
                self.onInterfaceChange?(interfaceType, roamingState)
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
    private var _currentInterfaceType: NetworkInterfaceType
    private var _onReachabilityChange: (@Sendable (Bool) -> Void)?
    private var _onInterfaceChange: (@Sendable (NetworkInterfaceType, NetworkRoamingState) -> Void)?

    public init(isReachable: Bool = true, initialInterface: NetworkInterfaceType = .wifi) {
        self._isReachable = isReachable
        self._currentInterfaceType = initialInterface
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

    public var currentInterfaceType: NetworkInterfaceType {
        get { lock.withLock { _currentInterfaceType } }
        set {
            transitionInterface(to: newValue)
        }
    }

    public var onReachabilityChange: (@Sendable (Bool) -> Void)? {
        get { lock.withLock { _onReachabilityChange } }
        set { lock.withLock { _onReachabilityChange = newValue } }
    }

    public var onInterfaceChange: (@Sendable (NetworkInterfaceType, NetworkRoamingState) -> Void)? {
        get { lock.withLock { _onInterfaceChange } }
        set { lock.withLock { _onInterfaceChange = newValue } }
    }

    public func start() {}
    public func stop() {}

    public func setReachable(_ reachable: Bool) {
        self.isReachable = reachable
    }

    public func transitionInterface(
        to newInterface: NetworkInterfaceType,
        isExpensive: Bool = false,
        isConstrained: Bool = false,
        remoteAddress: String? = nil,
        remotePort: UInt16? = nil
    ) {
        let (changed, oldInterface) = lock.withLock { () -> (Bool, NetworkInterfaceType) in
            let old = _currentInterfaceType
            _currentInterfaceType = newInterface
            return (old != newInterface, old)
        }
        if changed {
            let roamingState = NetworkRoamingState(
                previousInterface: oldInterface,
                currentInterface: newInterface,
                isExpensive: isExpensive,
                isConstrained: isConstrained,
                remoteAddress: remoteAddress,
                remotePort: remotePort
            )
            let handler = onInterfaceChange
            handler?(newInterface, roamingState)
        }
    }
}
