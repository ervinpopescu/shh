import Foundation
import ShhCore

public final class ResizeDebouncer: @unchecked Sendable {
    public let delay: TimeInterval
    private let queue: DispatchQueue
    private let action: (TerminalSize) -> Void
    private var pendingItem: DispatchWorkItem?
    private var pendingSize: TerminalSize?
    private var lastDeliveredSize: TerminalSize?
    private let lock = NSLock()

    public init(
        delay: TimeInterval = 0.150,
        queue: DispatchQueue = .main,
        action: @escaping (TerminalSize) -> Void
    ) {
        self.delay = delay
        self.queue = queue
        self.action = action
    }

    public func receive(columns: Int, rows: Int) {
        receive(size: TerminalSize(columns: columns, rows: rows))
    }

    public func receive(size: TerminalSize) {
        lock.lock()
        defer { lock.unlock() }

        pendingItem?.cancel()
        pendingSize = size

        var item: DispatchWorkItem?
        item = DispatchWorkItem { [weak self] in
            guard let self else { return }
            var sizeToDeliver: TerminalSize?
            self.lock.lock()
            if let item, !item.isCancelled {
                sizeToDeliver = self.pendingSize
                self.pendingItem = nil
                self.pendingSize = nil
                self.lastDeliveredSize = sizeToDeliver
            }
            self.lock.unlock()

            if let sizeToDeliver {
                self.action(sizeToDeliver)
            }
        }
        pendingItem = item
        if let item {
            queue.asyncAfter(deadline: .now() + delay, execute: item)
        }
    }

    public func flush() {
        lock.lock()
        pendingItem?.cancel()
        pendingItem = nil
        let sizeToDeliver = pendingSize
        pendingSize = nil
        if let sizeToDeliver {
            lastDeliveredSize = sizeToDeliver
        }
        lock.unlock()

        if let sizeToDeliver {
            action(sizeToDeliver)
        }
    }

    public func cancel() {
        lock.lock()
        pendingItem?.cancel()
        pendingItem = nil
        pendingSize = nil
        lock.unlock()
    }

    public var hasPendingResize: Bool {
        lock.lock()
        defer { lock.unlock() }
        return pendingItem != nil && pendingSize != nil
    }

    public var latestPendingSize: TerminalSize? {
        lock.lock()
        defer { lock.unlock() }
        return pendingSize
    }

    public var latestDeliveredSize: TerminalSize? {
        lock.lock()
        defer { lock.unlock() }
        return lastDeliveredSize
    }
}
