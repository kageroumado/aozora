import DequeModule

/// Generic async FIFO queue backed by `Deque` from swift-collections.
///
/// Producers call `enqueue` (non-blocking, always succeeds). The single consumer calls
/// `dequeue` which suspends on an empty queue and resumes when an item arrives.
///
/// Unlike `AsyncStream`, there is no `finish()` to forget — the queue exists for the
/// lifetime of the actor. This eliminates the class of bugs where a missed `finish()`
/// permanently blocks stream consumers.
///
/// **Single-consumer only.** Multiple concurrent `dequeue()` calls will trap.
public actor AsyncQueue<T: Sendable> {
    private var buffer: Deque<T> = []
    private var waiter: CheckedContinuation<T, Never>?
    private let maxCapacity: Int

    /// - Parameter maxCapacity: Maximum items before oldest are dropped. 0 = unlimited.
    public init(maxCapacity: Int = 0) {
        self.maxCapacity = maxCapacity
    }

    /// Add an item to the back of the queue (non-blocking, always succeeds).
    public func enqueue(_ item: T) {
        if let waiter {
            self.waiter = nil
            waiter.resume(returning: item)
        } else {
            if maxCapacity > 0, buffer.count >= maxCapacity {
                buffer.removeFirst()
            }
            buffer.append(item)
        }
    }

    /// Remove and return the first item, suspending if empty.
    public func dequeue() async -> T {
        if let item = buffer.popFirst() {
            return item
        }
        return await withCheckedContinuation { continuation in
            precondition(waiter == nil, "AsyncQueue: only one consumer allowed")
            waiter = continuation
        }
    }

    /// Current number of buffered items.
    public var count: Int {
        buffer.count
    }
}
