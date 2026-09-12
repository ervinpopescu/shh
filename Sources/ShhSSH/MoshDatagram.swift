import Foundation
import Network
import ShhCore

// MARK: - Mosh Datagram

public struct MoshDatagram: Equatable, Sendable {
    public enum Kind: UInt8, Sendable {
        case data = 0x01
        case keepalive = 0x02
        case resize = 0x03
        case roamingProbe = 0x04
        case teardown = 0x05
    }

    public var kind: Kind
    public var sequenceNumber: UInt64
    public var timestamp: UInt64
    public var payload: Data

    public init(
        kind: Kind = .data,
        sequenceNumber: UInt64,
        timestamp: UInt64 = UInt64(Date().timeIntervalSince1970 * 1000),
        payload: Data = Data()
    ) {
        self.kind = kind
        self.sequenceNumber = sequenceNumber
        self.timestamp = timestamp
        self.payload = payload
    }

    public func encode() -> Data {
        var data = Data()
        data.append(kind.rawValue)
        var seq = sequenceNumber.bigEndian
        withUnsafeBytes(of: &seq) { data.append(contentsOf: $0) }
        var ts = timestamp.bigEndian
        withUnsafeBytes(of: &ts) { data.append(contentsOf: $0) }
        data.append(payload)
        return data
    }

    public static func decode(from data: Data) -> MoshDatagram? {
        guard data.count >= 17 else { return nil }
        guard let kind = Kind(rawValue: data[0]) else { return nil }
        let seq = data.subdata(in: 1..<9).withUnsafeBytes { $0.load(as: UInt64.self).bigEndian }
        let ts = data.subdata(in: 9..<17).withUnsafeBytes { $0.load(as: UInt64.self).bigEndian }
        let payload = data.count > 17 ? data.subdata(in: 17..<data.count) : Data()
        return MoshDatagram(kind: kind, sequenceNumber: seq, timestamp: ts, payload: payload)
    }
}

// MARK: - Datagram Channel Protocol

public protocol MoshDatagramChannel: Sendable {
    func start() async throws
    func send(datagram: Data) async throws
    func incomingDatagrams() -> AsyncThrowingStream<Data, Error>
    func updateEndpoint(host: String, port: UInt16) async throws
    func close() async
}

// MARK: - Mock Datagram Channel

public final class MockMoshDatagramChannel: MoshDatagramChannel, @unchecked Sendable {
    private let lock = NSLock()
    private var _sentDatagrams: [Data] = []
    private var _currentHost: String
    private var _currentPort: UInt16
    private var _isStarted: Bool = false
    private var _isClosed: Bool = false
    private var streamContinuation: AsyncThrowingStream<Data, Error>.Continuation?

    public init(remoteHost: String = "127.0.0.1", remotePort: UInt16 = 60001) {
        self._currentHost = remoteHost
        self._currentPort = remotePort
    }

    public var sentDatagrams: [Data] {
        lock.withLock { _sentDatagrams }
    }

    public var currentHost: String {
        lock.withLock { _currentHost }
    }

    public var currentPort: UInt16 {
        lock.withLock { _currentPort }
    }

    public var isStarted: Bool {
        lock.withLock { _isStarted }
    }

    public var isClosed: Bool {
        lock.withLock { _isClosed }
    }

    public func start() async throws {
        lock.withLock { _isStarted = true }
    }

    public func send(datagram: Data) async throws {
        lock.withLock {
            guard !_isClosed else { return }
            _sentDatagrams.append(datagram)
        }
    }

    public func incomingDatagrams() -> AsyncThrowingStream<Data, Error> {
        AsyncThrowingStream { continuation in
            self.lock.withLock {
                self.streamContinuation = continuation
            }
        }
    }

    public func simulateInboundDatagram(_ data: Data) {
        _ = lock.withLock {
            streamContinuation?.yield(data)
        }
    }

    public func updateEndpoint(host: String, port: UInt16) async throws {
        lock.withLock {
            self._currentHost = host
            self._currentPort = port
        }
    }

    public func close() async {
        lock.withLock {
            guard !_isClosed else { return }
            _isClosed = true
            streamContinuation?.finish()
            streamContinuation = nil
        }
    }
}

// MARK: - Live Mosh Datagram Channel

private final class ContinuationResumeGuard: @unchecked Sendable {
    private let lock = NSLock()
    private var didResume = false

    func resumeOnce(using continuation: CheckedContinuation<Void, Error>, throwing error: Error? = nil) {
        lock.withLock {
            guard !didResume else { return }
            didResume = true
            if let error {
                continuation.resume(throwing: error)
            } else {
                continuation.resume()
            }
        }
    }
}

public final class LiveMoshDatagramChannel: MoshDatagramChannel, @unchecked Sendable {
    private var currentHost: String
    private var currentPort: UInt16
    private var connection: NWConnection?
    private let queue = DispatchQueue(label: "com.ervinpopescu.shh.mosh.udp", qos: .userInitiated)
    private var streamContinuation: AsyncThrowingStream<Data, Error>.Continuation?
    private var isCancelled: Bool = false
    private let lock = NSLock()

    public init(remoteHost: String, remotePort: UInt16) {
        self.currentHost = remoteHost
        self.currentPort = remotePort
    }

    public func start() async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            let resumeGuard = ContinuationResumeGuard()

            lock.withLock {
                let host = NWEndpoint.Host(currentHost)
                guard let port = NWEndpoint.Port(rawValue: currentPort) else {
                    resumeGuard.resumeOnce(using: continuation, throwing: TransportError.invalidConfiguration)
                    return
                }

                let nwConnection = NWConnection(host: host, port: port, using: .udp)
                self.connection = nwConnection

                nwConnection.stateUpdateHandler = { [weak self] state in
                    guard let self else { return }
                    switch state {
                    case .ready:
                        resumeGuard.resumeOnce(using: continuation)
                        self.receiveNext()
                    case .failed(let error):
                        resumeGuard.resumeOnce(using: continuation, throwing: error)
                        self.lock.withLock {
                            self.streamContinuation?.finish(throwing: error)
                        }
                    case .cancelled:
                        resumeGuard.resumeOnce(using: continuation, throwing: TransportError.cancelled)
                    default:
                        break
                    }
                }

                nwConnection.start(queue: queue)
            }
        }
    }

    private func receiveNext() {
        lock.withLock {
            guard !isCancelled, let conn = connection else { return }
            conn.receiveMessage { [weak self] content, _, _, error in
                guard let self else { return }
                if let data = content, !data.isEmpty {
                    _ = self.lock.withLock {
                        self.streamContinuation?.yield(data)
                    }
                }
                if let error {
                    self.lock.withLock {
                        self.streamContinuation?.finish(throwing: error)
                    }
                    return
                }
                self.receiveNext()
            }
        }
    }

    public func send(datagram: Data) async throws {
        let conn: NWConnection? = lock.withLock {
            guard !isCancelled else { return nil }
            return self.connection
        }

        guard let conn else {
            throw TransportError.networkUnavailable
        }

        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            conn.send(content: datagram, completion: .contentProcessed { error in
                if let error {
                    continuation.resume(throwing: error)
                } else {
                    continuation.resume()
                }
            })
        }
    }

    public func incomingDatagrams() -> AsyncThrowingStream<Data, Error> {
        AsyncThrowingStream { continuation in
            self.lock.withLock {
                self.streamContinuation = continuation
            }
        }
    }

    public func updateEndpoint(host: String, port: UInt16) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            let resumeGuard = ContinuationResumeGuard()

            lock.withLock {
                guard host != currentHost || port != currentPort else {
                    resumeGuard.resumeOnce(using: continuation)
                    return
                }

                self.currentHost = host
                self.currentPort = port

                // Re-bind connection to new endpoint
                self.connection?.cancel()

                let newHost = NWEndpoint.Host(host)
                guard let newPort = NWEndpoint.Port(rawValue: port) else {
                    resumeGuard.resumeOnce(using: continuation, throwing: TransportError.invalidConfiguration)
                    return
                }

                let nwConnection = NWConnection(host: newHost, port: newPort, using: .udp)
                self.connection = nwConnection

                nwConnection.stateUpdateHandler = { [weak self] state in
                    guard let self else { return }
                    switch state {
                    case .ready:
                        resumeGuard.resumeOnce(using: continuation)
                        self.receiveNext()
                    case .failed(let error):
                        resumeGuard.resumeOnce(using: continuation, throwing: error)
                    case .cancelled:
                        resumeGuard.resumeOnce(using: continuation, throwing: TransportError.cancelled)
                    default:
                        break
                    }
                }

                nwConnection.start(queue: queue)
            }
        }
    }

    public func close() async {
        lock.withLock {
            guard !isCancelled else { return }
            isCancelled = true
            connection?.cancel()
            connection = nil
            streamContinuation?.finish()
            streamContinuation = nil
        }
    }
}
