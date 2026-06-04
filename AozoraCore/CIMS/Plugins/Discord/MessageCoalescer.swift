import Foundation

/// Debounces and merges rapid inbound messages before they enter the event loop.
///
/// When messages arrive in rapid succession (e.g., a user sending multiple short messages),
/// the coalescer accumulates them within a configurable debounce window and emits a single
/// merged message. This prevents creating many small turns for what is conceptually one input.
///
/// Messages are merged by concatenating their text with `\n---\n` separators and combining
/// their image attachments. Parts are renumbered sequentially. Metadata is taken from the
/// first message in the batch.
///
/// The coalescer sits between the Discord channel's `AsyncStream<InboundMessage>` and the
/// daemon's event queue — only Discord messages pass through it (IPC messages bypass it).
public actor MessageCoalescer {
    /// Configuration for debounce and batching behavior.
    public struct Config: Sendable {
        /// Duration to wait for additional messages before flushing the buffer.
        ///
        /// After receiving a message, the coalescer waits this long for more messages.
        /// Each new message resets the timer. When the timer expires, all buffered
        /// messages are coalesced and emitted.
        public var debounceWindow: Duration

        /// Maximum messages to accumulate before force-flushing, regardless of debounce.
        ///
        /// Prevents unbounded buffering when a user sends many messages in a row.
        /// When this limit is hit, the buffer is flushed immediately.
        public var maxBatchSize: Int

        /// Maximum total messages to retain when the buffer overflows.
        ///
        /// If the buffer somehow grows past this cap (e.g., flush callback is slow),
        /// older messages are summarized with an overflow note. Must be >= `maxBatchSize`.
        public var overflowCap: Int

        public init(
            debounceWindow: Duration = .milliseconds(1_500),
            maxBatchSize: Int = 20,
            overflowCap: Int = 50,
        ) {
            self.debounceWindow = debounceWindow
            self.maxBatchSize = maxBatchSize
            self.overflowCap = max(overflowCap, maxBatchSize)
        }
    }

    /// The debounce/batch configuration.
    private let config: Config

    /// Buffered messages awaiting flush.
    private var buffer: [InboundMessage] = []

    /// The active debounce timer task, cancelled and recreated on each new message.
    private var debounceTask: Task<Void, Never>?

    /// Callback invoked with each coalesced message. Wired to the event queue by the daemon.
    private let onFlush: @Sendable (InboundMessage) async -> Void

    /// Create a coalescer with the given configuration and flush callback.
    ///
    /// - Parameters:
    ///   - config: Debounce window, batch size, and overflow settings.
    ///   - onFlush: Called with each coalesced message. Typically enqueues into the event queue.
    public init(
        config: Config = Config(),
        onFlush: @escaping @Sendable (InboundMessage) async -> Void,
    ) {
        self.config = config
        self.onFlush = onFlush
    }

    /// Submit a message for coalescing.
    ///
    /// The message is added to the buffer. If the buffer reaches `maxBatchSize`, the batch
    /// is flushed immediately (the caller suspends until the flush callback completes).
    /// Otherwise, the debounce timer is reset — the batch will flush after `debounceWindow`
    /// elapses with no further messages.
    ///
    /// - Parameter message: The inbound message to coalesce.
    public func submit(_ message: InboundMessage) async {
        buffer.append(message)

        // Force flush at max batch size
        if buffer.count >= config.maxBatchSize {
            debounceTask?.cancel()
            debounceTask = nil
            let batch = drainBuffer()
            await emit(batch)
            return
        }

        // Reset debounce timer
        debounceTask?.cancel()
        debounceTask = Task { [config] in
            try? await Task.sleep(for: config.debounceWindow)
            guard !Task.isCancelled else { return }
            await self.performFlush()
        }
    }

    /// Flush the buffer immediately, bypassing the debounce timer.
    ///
    /// Used during shutdown or when the system needs to process pending messages right away.
    /// No-op if the buffer is empty.
    public func flushNow() async {
        debounceTask?.cancel()
        debounceTask = nil
        guard !buffer.isEmpty else { return }
        let batch = drainBuffer()
        await emit(batch)
    }

    // MARK: - Private

    /// Remove all messages from the buffer and return them.
    private func drainBuffer() -> [InboundMessage] {
        let batch = buffer
        buffer = []
        return batch
    }

    /// Called when the debounce timer expires.
    private func performFlush() async {
        guard !buffer.isEmpty else { return }
        let batch = drainBuffer()
        await emit(batch)
    }

    /// Coalesce a batch and deliver it via the flush callback.
    private func emit(_ batch: [InboundMessage]) async {
        guard !batch.isEmpty else { return }
        let coalesced = coalesce(batch)
        await onFlush(coalesced)
    }

    /// Merge multiple messages into a single ``InboundMessage``.
    ///
    /// - Single message: returned as-is (no overhead).
    /// - Multiple messages: text joined with `\n---\n`, images concatenated,
    ///   parts renumbered sequentially, metadata from first message preserved.
    /// - Overflow (> `overflowCap`): oldest messages beyond the cap are replaced
    ///   with a summary note.
    ///
    /// - Parameter messages: The messages to merge. Must not be empty.
    /// - Returns: A single coalesced message.
    private func coalesce(_ messages: [InboundMessage]) -> InboundMessage {
        guard messages.count > 1 else { return messages[0] }

        let effective: [InboundMessage]
        var overflowPrefix: String?

        if messages.count > config.overflowCap {
            let overflowCount = messages.count - config.maxBatchSize
            effective = Array(messages.suffix(config.maxBatchSize))
            overflowPrefix = "[\(overflowCount) earlier messages omitted due to overflow]"
        } else {
            effective = messages
        }

        // Merge text
        var mergedText = effective.map(\.text).joined(separator: "\n---\n")
        if let prefix = overflowPrefix {
            mergedText = prefix + "\n---\n" + mergedText
        }

        // Merge parts with renumbered ordinals
        var mergedParts: [MessagePart] = []
        var ordinal = 0
        for message in effective {
            for part in message.parts {
                mergedParts.append(MessagePart(
                    kind: part.kind,
                    ordinal: ordinal,
                    content: part.content,
                    metadata: part.metadata,
                ))
                ordinal += 1
            }
        }

        // If there's an overflow prefix, prepend a synthetic text part
        if let prefix = overflowPrefix {
            mergedParts.insert(MessagePart(
                kind: .text,
                ordinal: 0,
                content: prefix,
                metadata: nil,
            ), at: 0)
            // Renumber everything after
            for i in 1 ..< mergedParts.count {
                let p = mergedParts[i]
                mergedParts[i] = MessagePart(
                    kind: p.kind,
                    ordinal: i,
                    content: p.content,
                    metadata: p.metadata,
                )
            }
        }

        // Merge images from all messages (including overflow, in case they had images)
        let allImages = messages.flatMap(\.images)

        return InboundMessage(
            text: mergedText,
            parts: mergedParts,
            metadata: effective[0].metadata,
            images: allImages,
        )
    }
}
