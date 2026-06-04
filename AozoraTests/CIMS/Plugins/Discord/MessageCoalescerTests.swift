import Foundation
import Synchronization
import Testing
@testable import Aozora

/// Tests for ``MessageCoalescer`` — debouncing and merging rapid inbound messages.
///
/// Uses short debounce windows (100-300ms) to keep tests fast while still exercising
/// the timer-based coalescing logic.
///
/// Serialized because debounce-based tests depend on timing and fail under
/// concurrent executor contention from parallel test suites.
@Suite(.serialized)
struct MessageCoalescerTests {
    // MARK: - Helpers

    /// Thread-safe collector for flushed messages.
    private final class Collector: Sendable {
        private let storage = Mutex<[InboundMessage]>([])

        func append(_ message: InboundMessage) {
            storage.withLock { $0.append(message) }
        }

        var messages: [InboundMessage] {
            storage.withLock { Array($0) }
        }

        var count: Int {
            storage.withLock { $0.count }
        }
    }

    /// Poll until a condition is met, with a generous timeout.
    ///
    /// Immune to executor contention — polls every 50ms and gives up to `timeout`.
    private func waitUntil(
        count expected: Int,
        from collector: Collector,
        timeout: Duration = .seconds(5),
    ) async throws {
        let deadline = ContinuousClock.now + timeout
        while ContinuousClock.now < deadline {
            if collector.count >= expected { return }
            try await Task.sleep(for: .milliseconds(50))
        }
    }

    /// Shorthand for creating a test message via TestFixtures.
    private func makeMessage(
        _ text: String,
        images: [ImageAttachment] = [],
    ) -> InboundMessage {
        TestFixtures.inboundMessage(text: text, channelId: "ch-1", authorId: "author-1", images: images)
    }

    // MARK: - Tests

    @Test
    func `Single message passes through after debounce`() async throws {
        let collector = Collector()
        let coalescer = MessageCoalescer(
            config: .init(debounceWindow: .milliseconds(100)),
        ) { message in
            collector.append(message)
        }

        await coalescer.submit(makeMessage("hello"))

        try await waitUntil(count: 1, from: collector)

        #expect(collector.count == 1)
        #expect(collector.messages[0].text == "hello")
    }

    @Test
    func `Rapid messages coalesced into one`() async throws {
        let collector = Collector()
        let coalescer = MessageCoalescer(
            config: .init(debounceWindow: .milliseconds(200)),
        ) { message in
            collector.append(message)
        }

        await coalescer.submit(makeMessage("one"))
        await coalescer.submit(makeMessage("two"))
        await coalescer.submit(makeMessage("three"))

        try await waitUntil(count: 1, from: collector)

        #expect(collector.count == 1)
        #expect(collector.messages[0].text == "one\n---\ntwo\n---\nthree")
        #expect(collector.messages[0].text.contains("one"))
        #expect(collector.messages[0].text.contains("two"))
        #expect(collector.messages[0].text.contains("three"))
        #expect(collector.messages[0].text.contains("---"))
    }

    @Test
    func `Debounce window resets on each new message`() async throws {
        let collector = Collector()
        let coalescer = MessageCoalescer(
            config: .init(debounceWindow: .milliseconds(200)),
        ) { message in
            collector.append(message)
        }

        // Submit first message at t=0
        await coalescer.submit(makeMessage("first"))

        // Submit second at t=100ms (within 200ms window)
        try await Task.sleep(for: .milliseconds(100))
        await coalescer.submit(makeMessage("second"))

        // At t=200ms: only 100ms since second message, window not expired yet
        try await Task.sleep(for: .milliseconds(100))
        #expect(collector.count == 0)

        // Window should expire ~200ms after second message
        try await waitUntil(count: 1, from: collector)
        #expect(collector.count == 1)
        #expect(collector.messages[0].text.contains("first"))
        #expect(collector.messages[0].text.contains("second"))
    }

    @Test
    func `Separate flushes for messages outside debounce window`() async throws {
        let collector = Collector()
        let coalescer = MessageCoalescer(
            config: .init(debounceWindow: .milliseconds(100)),
        ) { message in
            collector.append(message)
        }

        await coalescer.submit(makeMessage("first"))

        try await waitUntil(count: 1, from: collector)
        #expect(collector.count == 1)

        await coalescer.submit(makeMessage("second"))

        try await waitUntil(count: 2, from: collector)
        #expect(collector.count == 2)
        #expect(collector.messages[0].text == "first")
        #expect(collector.messages[1].text == "second")
    }

    @Test
    func `Max batch size triggers immediate flush`() async throws {
        let collector = Collector()
        let coalescer = MessageCoalescer(
            config: .init(debounceWindow: .milliseconds(5_000), maxBatchSize: 3),
        ) { message in
            collector.append(message)
        }

        // Submit 5 messages rapidly — should flush at 3, then 2 remains buffered
        for i in 1 ... 5 {
            await coalescer.submit(makeMessage("msg\(i)"))
        }

        // The first batch of 3 should have flushed immediately
        // Give a small window for the async Task to complete
        try await Task.sleep(for: .milliseconds(50))
        #expect(collector.count == 1)

        let first = collector.messages[0]
        #expect(first.text.contains("msg1"))
        #expect(first.text.contains("msg2"))
        #expect(first.text.contains("msg3"))

        // The remaining 2 are still in the buffer (debounce is 5s)
        // Force flush to check them
        await coalescer.flushNow()
        #expect(collector.count == 2)

        let second = collector.messages[1]
        #expect(second.text.contains("msg4"))
        #expect(second.text.contains("msg5"))
    }

    @Test
    func `Empty buffer produces no flush`() async throws {
        let collector = Collector()
        let coalescer = MessageCoalescer(
            config: .init(debounceWindow: .milliseconds(50)),
        ) { message in
            collector.append(message)
        }

        // Wait longer than debounce window
        try await Task.sleep(for: .milliseconds(150))

        #expect(collector.count == 0)

        // Also test flushNow on empty buffer
        await coalescer.flushNow()
        #expect(collector.count == 0)
    }

    @Test
    func `Image attachments preserved during coalescing`() async throws {
        let collector = Collector()
        let coalescer = MessageCoalescer(
            config: .init(debounceWindow: .milliseconds(100)),
        ) { message in
            collector.append(message)
        }

        let img1 = ImageAttachment(data: Data([0xFF, 0xD8]), mediaType: "image/jpeg", filename: "a.jpg")
        let img2 = ImageAttachment(data: Data([0x89, 0x50]), mediaType: "image/png", filename: "b.png")
        let img3 = ImageAttachment(data: Data([0x47, 0x49]), mediaType: "image/gif", filename: "c.gif")

        await coalescer.submit(makeMessage("with image 1", images: [img1]))
        await coalescer.submit(makeMessage("with images 2", images: [img2, img3]))

        try await waitUntil(count: 1, from: collector)

        #expect(collector.count == 1)
        let result = collector.messages[0]
        #expect(result.images.count == 3)
        #expect(result.images[0].filename == "a.jpg")
        #expect(result.images[1].filename == "b.png")
        #expect(result.images[2].filename == "c.gif")
    }

    @Test
    func `Metadata from first message preserved`() async throws {
        let collector = Collector()
        let coalescer = MessageCoalescer(
            config: .init(debounceWindow: .milliseconds(100)),
        ) { message in
            collector.append(message)
        }

        let meta1 = MessageMetadata(replyToMessageId: 42, attachments: ["att-1"])
        let msg1 = InboundMessage(
            text: "first",
            parts: [MessagePart(kind: .text, ordinal: 0, content: "first", metadata: nil)],
            metadata: meta1,
        )
        let meta2 = MessageMetadata(replyToMessageId: 99, attachments: ["att-2"])
        let msg2 = InboundMessage(
            text: "second",
            parts: [MessagePart(kind: .text, ordinal: 0, content: "second", metadata: nil)],
            metadata: meta2,
        )

        await coalescer.submit(msg1)
        await coalescer.submit(msg2)

        try await waitUntil(count: 1, from: collector)

        #expect(collector.count == 1)
        let result = collector.messages[0]
        #expect(result.metadata?.replyToMessageId == 42)
        #expect(result.metadata?.attachments == ["att-1"])
    }

    @Test
    func `Parts renumbered sequentially in coalesced message`() async throws {
        let collector = Collector()
        let coalescer = MessageCoalescer(
            config: .init(debounceWindow: .milliseconds(100)),
        ) { message in
            collector.append(message)
        }

        let msg1 = InboundMessage(
            text: "one",
            parts: [
                MessagePart(kind: .text, ordinal: 0, content: "one-a", metadata: nil),
                MessagePart(kind: .text, ordinal: 1, content: "one-b", metadata: nil),
            ],
            metadata: nil,
        )
        let msg2 = InboundMessage(
            text: "two",
            parts: [
                MessagePart(kind: .text, ordinal: 0, content: "two-a", metadata: nil),
            ],
            metadata: nil,
        )

        await coalescer.submit(msg1)
        await coalescer.submit(msg2)

        try await waitUntil(count: 1, from: collector)

        #expect(collector.count == 1)
        let parts = collector.messages[0].parts
        #expect(parts.count == 3)
        #expect(parts[0].ordinal == 0)
        #expect(parts[0].content == "one-a")
        #expect(parts[1].ordinal == 1)
        #expect(parts[1].content == "one-b")
        #expect(parts[2].ordinal == 2)
        #expect(parts[2].content == "two-a")
    }

    @Test
    func `Multiple max-batch flushes from continuous stream`() async throws {
        let collector = Collector()
        let coalescer = MessageCoalescer(
            config: .init(debounceWindow: .milliseconds(5_000), maxBatchSize: 3),
        ) { message in
            collector.append(message)
        }

        // Submit 3 — hits maxBatchSize, immediate flush
        await coalescer.submit(makeMessage("msg1"))
        await coalescer.submit(makeMessage("msg2"))
        await coalescer.submit(makeMessage("msg3"))

        try await Task.sleep(for: .milliseconds(50))
        #expect(collector.count == 1)

        // Submit 5 more — next batch hits maxBatchSize at 3, then 2 remain
        for i in 4 ... 8 {
            await coalescer.submit(makeMessage("msg\(i)"))
        }

        try await Task.sleep(for: .milliseconds(50))
        #expect(collector.count == 2)

        // Flush the remaining 2
        await coalescer.flushNow()
        #expect(collector.count == 3)

        let third = collector.messages[2]
        #expect(third.text.contains("msg7"))
        #expect(third.text.contains("msg8"))
    }

    @Test
    func `Flush now drains buffer immediately without waiting for debounce`() async {
        let collector = Collector()
        let coalescer = MessageCoalescer(
            config: .init(debounceWindow: .milliseconds(5_000)),
        ) { message in
            collector.append(message)
        }

        await coalescer.submit(makeMessage("urgent1"))
        await coalescer.submit(makeMessage("urgent2"))

        // Without flushNow, these would wait 5 seconds
        #expect(collector.count == 0)

        await coalescer.flushNow()

        #expect(collector.count == 1)
        #expect(collector.messages[0].text.contains("urgent1"))
        #expect(collector.messages[0].text.contains("urgent2"))
    }

    @Test
    func `Coalesced text uses newline-dash-dash-dash-newline separator`() async throws {
        let collector = Collector()
        let coalescer = MessageCoalescer(
            config: .init(debounceWindow: .milliseconds(100)),
        ) { message in
            collector.append(message)
        }

        await coalescer.submit(makeMessage("alpha"))
        await coalescer.submit(makeMessage("beta"))

        try await waitUntil(count: 1, from: collector)

        #expect(collector.count == 1)
        #expect(collector.messages[0].text == "alpha\n---\nbeta")
    }
}
