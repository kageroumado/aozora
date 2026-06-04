import Foundation
import GRDB
import Testing
@testable import Aozora

// MARK: - Shared Test Helpers

/// Mock observer that captures every event forwarded to it.
final class MockObserver: TurnObserver, @unchecked Sendable {
    var events: [TurnEvent] = []

    func handleEvent(_ event: TurnEvent) async {
        events.append(event)
    }
}

// MARK: - PersistingObserver

struct PersistingObserverTests {
    /// Minimal inbound message helper.
    private func makeMessage(_ text: String) -> InboundMessage {
        InboundMessage(
            text: text,
            parts: [MessagePart(kind: .text, ordinal: 0, content: text, metadata: nil)],
            metadata: nil,
        )
    }

    /// Minimal assistant response helper.
    private func makeResponse(_ text: String) -> AssistantResponse {
        AssistantResponse(
            content: text,
            parts: [MessagePart(kind: .text, ordinal: 0, content: text, metadata: nil)],
            toolCalls: [],
            tokenUsage: TokenUsage(inputTokens: 10, outputTokens: 10),
            latency: .seconds(1),
        )
    }

    // MARK: - Event Forwarding

    @Test
    func `Non-toolResult events are forwarded to inner observer`() async throws {
        let gateway = try await CIMSGateway.inMemory()
        let inner = MockObserver()
        let observer = PersistingObserver(
            inner: inner,
            memoryStore: gateway.memoryStore,
            sessionKey: "test-session",
        )

        await observer.handleEvent(.thinking)
        await observer.handleEvent(.responseDelta("hello"))
        await observer.handleEvent(.responseCompleted("hello"))

        #expect(inner.events.count == 3)

        if case .thinking = inner.events[0] {} else {
            Issue.record("Expected .thinking at index 0, got \(inner.events[0])")
        }
        if case let .responseDelta(text) = inner.events[1] {
            #expect(text == "hello")
        } else {
            Issue.record("Expected .responseDelta at index 1, got \(inner.events[1])")
        }
        if case let .responseCompleted(text) = inner.events[2] {
            #expect(text == "hello")
        } else {
            Issue.record("Expected .responseCompleted at index 2, got \(inner.events[2])")
        }
    }

    @Test
    func `toolResult events are forwarded to inner observer`() async throws {
        let gateway = try await CIMSGateway.inMemory()
        let inner = MockObserver()
        let observer = PersistingObserver(
            inner: inner,
            memoryStore: gateway.memoryStore,
            sessionKey: "test-session",
        )

        let result = ToolCallResult(toolUseId: "tool-123", content: "result content", isError: false)
        await observer.handleEvent(.toolResult(result))

        #expect(inner.events.count == 1)
        if case let .toolResult(forwarded) = inner.events[0] {
            #expect(forwarded.toolUseId == "tool-123")
            #expect(forwarded.content == "result content")
        } else {
            Issue.record("Expected .toolResult, got \(inner.events[0])")
        }
    }

    // MARK: - Incremental Persistence

    @Test
    func `toolResult event triggers persistToolResult on the memory store`() async throws {
        let gateway = try await CIMSGateway.inMemory()
        let sessionKey = "persist-test-session"

        // Create a conversation so persistToolResult has a target to write into.
        await gateway.memoryStore.ingestTurn(
            userMessage: makeMessage("hello"),
            toolHistory: [],
            finalResponse: makeResponse("world"),
            sessionKey: sessionKey,
            userKey: "test-user",
        )

        let inner = MockObserver()
        let observer = PersistingObserver(
            inner: inner,
            memoryStore: gateway.memoryStore,
            sessionKey: sessionKey,
        )

        let result = ToolCallResult(
            toolUseId: "tool-abc",
            content: "tool output here",
            isError: false,
        )
        await observer.handleEvent(.toolResult(result))

        // Verify that a tool-role message was written to the database.
        let toolMessages = try await gateway.database.dbPool.read { db in
            try MessageRecord
                .filter(Column("role") == "tool")
                .fetchAll(db)
        }
        #expect(toolMessages.count == 1)
        #expect(toolMessages[0].content == "tool output here")
    }

    @Test
    func `toolResult with isError flag persists correctly`() async throws {
        let gateway = try await CIMSGateway.inMemory()
        let sessionKey = "error-session"

        await gateway.memoryStore.ingestTurn(
            userMessage: makeMessage("run something"),
            toolHistory: [],
            finalResponse: makeResponse("done"),
            sessionKey: sessionKey,
            userKey: "test-user",
        )

        let inner = MockObserver()
        let observer = PersistingObserver(
            inner: inner,
            memoryStore: gateway.memoryStore,
            sessionKey: sessionKey,
        )

        let errorResult = ToolCallResult(
            toolUseId: "tool-err",
            content: "something went wrong",
            isError: true,
        )
        await observer.handleEvent(.toolResult(errorResult))

        let toolMessages = try await gateway.database.dbPool.read { db in
            try MessageRecord
                .filter(Column("role") == "tool")
                .fetchAll(db)
        }
        #expect(toolMessages.count == 1)
        #expect(toolMessages[0].content == "something went wrong")

        // Verify the metadata records isError: true.
        let parts = try await gateway.database.dbPool.read { db in
            try MessagePartRecord
                .filter(Column("messageId") == toolMessages[0].id!)
                .fetchAll(db)
        }
        #expect(parts.count == 1)
        #expect(parts[0].metadata?.contains("true") == true)
    }

    @Test
    func `Multiple toolResult events each trigger persistence`() async throws {
        let gateway = try await CIMSGateway.inMemory()
        let sessionKey = "multi-session"

        await gateway.memoryStore.ingestTurn(
            userMessage: makeMessage("go"),
            toolHistory: [],
            finalResponse: makeResponse("done"),
            sessionKey: sessionKey,
            userKey: "test-user",
        )

        let inner = MockObserver()
        let observer = PersistingObserver(
            inner: inner,
            memoryStore: gateway.memoryStore,
            sessionKey: sessionKey,
        )

        for i in 1 ... 3 {
            let result = ToolCallResult(
                toolUseId: "tool-\(i)",
                content: "output \(i)",
                isError: false,
            )
            await observer.handleEvent(.toolResult(result))
        }

        let toolMessages = try await gateway.database.dbPool.read { db in
            try MessageRecord
                .filter(Column("role") == "tool")
                .order(Column("id").asc)
                .fetchAll(db)
        }
        #expect(toolMessages.count == 3)
        #expect(toolMessages[0].content == "output 1")
        #expect(toolMessages[1].content == "output 2")
        #expect(toolMessages[2].content == "output 3")

        // All events should also be forwarded.
        #expect(inner.events.count == 3)
    }

    @Test
    func `toolResult with no matching session is silently skipped (no crash)`() async throws {
        let gateway = try await CIMSGateway.inMemory()
        let inner = MockObserver()
        let observer = PersistingObserver(
            inner: inner,
            memoryStore: gateway.memoryStore,
            sessionKey: "nonexistent-session",
        )

        let result = ToolCallResult(toolUseId: "tool-xyz", content: "output", isError: false)
        // Should not crash even though there is no conversation for this session.
        await observer.handleEvent(.toolResult(result))

        // The event was still forwarded to the inner observer.
        #expect(inner.events.count == 1)

        // No tool messages written (session doesn't exist).
        let toolMessages = try await gateway.database.dbPool.read { db in
            try MessageRecord.filter(Column("role") == "tool").fetchAll(db)
        }
        #expect(toolMessages.isEmpty)
    }
}

// MARK: - CollectingForkObserver

struct CollectingForkObserverTests {
    @Test
    func `responseCompleted sets responseText`() async {
        let observer = CollectingForkObserver()
        await observer.handleEvent(.responseCompleted("final answer"))
        #expect(observer.responseText == "final answer")
    }

    @Test
    func `responseCompleted overwrites accumulated responseDelta`() async {
        let observer = CollectingForkObserver()
        await observer.handleEvent(.responseDelta("partial "))
        await observer.handleEvent(.responseDelta("text"))
        await observer.handleEvent(.responseCompleted("full response"))
        #expect(observer.responseText == "full response")
    }

    @Test
    func `toolResult events increment toolCallCount`() async {
        let observer = CollectingForkObserver()
        let result1 = ToolCallResult(toolUseId: "t1", content: "out1", isError: false)
        let result2 = ToolCallResult(toolUseId: "t2", content: "out2", isError: false)
        await observer.handleEvent(.toolResult(result1))
        await observer.handleEvent(.toolResult(result2))
        #expect(observer.toolCallCount == 2)
    }

    @Test
    func `responseDelta events accumulate when no responseCompleted has fired`() async {
        let observer = CollectingForkObserver()
        await observer.handleEvent(.responseDelta("hello "))
        await observer.handleEvent(.responseDelta("world"))
        #expect(observer.responseText == "hello world")
    }

    @Test
    func `Unrelated events do not affect responseText or toolCallCount`() async {
        let observer = CollectingForkObserver()
        await observer.handleEvent(.thinking)
        await observer.handleEvent(.acknowledged("turn-1"))
        #expect(observer.responseText.isEmpty)
        #expect(observer.toolCallCount == 0)
    }

    @Test
    func `Mixed event sequence produces correct final state`() async {
        let observer = CollectingForkObserver()
        await observer.handleEvent(.responseDelta("partial "))
        await observer.handleEvent(.toolResult(ToolCallResult(toolUseId: "t1", content: "r1", isError: false)))
        await observer.handleEvent(.responseDelta("text "))
        await observer.handleEvent(.toolResult(ToolCallResult(toolUseId: "t2", content: "r2", isError: false)))
        await observer.handleEvent(.responseCompleted("definitive answer"))

        #expect(observer.responseText == "definitive answer")
        #expect(observer.toolCallCount == 2)
    }
}

// MARK: - TurnRequest Continuation Depth

struct TurnRequestContinuationDepthTests {
    private func makeRequest(continuationDepth: Int = 0) -> TurnRequest {
        TurnRequest(
            turnID: "turn-test",
            sessionKey: "session-test",
            userKey: "user-test",
            message: InboundMessage(
                text: "hello",
                parts: [MessagePart(kind: .text, ordinal: 0, content: "hello", metadata: nil)],
                metadata: nil,
            ),
            receivedAt: Date(),
            continuationDepth: continuationDepth,
        )
    }

    @Test
    func `continuationDepth defaults to 0`() {
        let request = TurnRequest(
            turnID: "t",
            sessionKey: "s",
            userKey: "u",
            message: InboundMessage(
                text: "hi",
                parts: [],
                metadata: nil,
            ),
            receivedAt: Date(),
        )
        #expect(request.continuationDepth == 0)
    }

    @Test
    func `continuationDepth can be set to non-zero values`() {
        let request = makeRequest(continuationDepth: 3)
        #expect(request.continuationDepth == 3)
    }

    @Test
    func `continuationDepth of 1 represents a first-level continuation`() {
        let request = makeRequest(continuationDepth: 1)
        #expect(request.continuationDepth == 1)
    }

    @Test
    func `continuationDepth is preserved as-is (no clamping)`() {
        let depth = 42
        let request = makeRequest(continuationDepth: depth)
        #expect(request.continuationDepth == depth)
    }
}
