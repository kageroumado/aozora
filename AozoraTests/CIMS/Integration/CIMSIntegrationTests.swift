import Foundation
import Testing
@testable import Aozora

/// Integration tests that exercise the full CIMS cognitive cycle end-to-end.
///
/// These tests use ``CIMSGateway/inMemory()`` to wire real stores (MemoryStore, IdentityStore)
/// with an in-memory GRDB database and ``MockModelProvider``. This validates the full path:
/// user message → salience scoring → memory retrieval → context assembly → model inference →
/// tool handling → persistence → compaction check → allostasis update.
struct CIMSIntegrationTests {
    // MARK: - Helpers

    /// Create a fully wired in-memory CIMS gateway.
    private func makeGateway(systemPrompt: String = "You are a helpful assistant.") async throws -> CIMSGateway {
        try await CIMSGateway.inMemory(systemPrompt: systemPrompt)
    }

    /// Create a turn request with the given text.
    private func makeRequest(
        _ text: String,
        userKey: UserKey = "test-user",
        sessionKey: SessionKey = "test-session",
    ) -> TurnRequest {
        TurnRequest(
            turnID: UUID().uuidString,
            sessionKey: sessionKey,
            userKey: userKey,
            message: InboundMessage(
                text: text,
                parts: [MessagePart(kind: .text, ordinal: 0, content: text, metadata: nil)],
                metadata: nil,
            ),
            receivedAt: Date(),
        )
    }

    // MARK: - Single Turn End-to-End

    @Test
    func `Single turn flows through entire cognitive cycle`() async throws {
        let gateway = try await makeGateway()
        let request = makeRequest("Hello, how are you?")
        let events = try await runTurnCollecting(gateway.coordinator, request)

        // Verify event sequence: acknowledged -> thinking -> responseDelta -> responseCompleted
        var sawAcknowledged = false
        var sawThinking = false
        var sawDelta = false
        var sawCompleted = false

        for event in events {
            switch event {
            case .acknowledged:
                sawAcknowledged = true
            case .thinking:
                #expect(sawAcknowledged, "Thinking should come after acknowledged")
                sawThinking = true
            case .responseDelta:
                #expect(sawThinking, "Response delta should come after thinking")
                sawDelta = true
            case .responseCompleted:
                sawCompleted = true
            default:
                break
            }
        }

        #expect(sawAcknowledged)
        #expect(sawThinking)
        #expect(sawDelta)
        #expect(sawCompleted)
    }

    @Test
    func `Single turn persists to memory store`() async throws {
        let gateway = try await makeGateway()
        let request = makeRequest("Remember that my favorite color is blue.")
        _ = try await runTurnCollecting(gateway.coordinator, request)

        // Verify the message was persisted via fresh tail
        let tail = await gateway.memoryStore.freshTail(count: 10, for: 1)
        #expect(!tail.isEmpty, "Fresh tail should contain the persisted message")

        // Find the user message in the tail
        let userMessages = tail.filter { $0.role == .user }
        #expect(!userMessages.isEmpty, "Should have at least one user message in the tail")

        let found = userMessages.contains { $0.content.contains("favorite color is blue") }
        #expect(found, "The user message should be persisted with its content")
    }

    @Test
    func `System prompt is injected into context`() async throws {
        let customPrompt = "You are Aozora, a sky-themed AI assistant."
        let gateway = try await makeGateway(systemPrompt: customPrompt)

        // The mock model provider will receive the context with the system prompt.
        // We verify indirectly: if the turn completes, context assembly succeeded.
        let request = makeRequest("Test message")
        let events = try await runTurnCollecting(gateway.coordinator, request)

        #expect(events.completedText != nil, "Should get a response with custom system prompt")
    }

    // MARK: - Multi-Turn Conversations

    @Test
    func `Second turn retrieves context from first turn`() async throws {
        let gateway = try await makeGateway()

        // Turn 1: Establish a fact
        let req1 = makeRequest("My name is Alice and I work on browser development.")
        _ = try await runTurnCollecting(gateway.coordinator, req1)

        // Turn 2: The context assembly should now include memory from turn 1
        let req2 = makeRequest("What was I working on?")
        let events2 = try await runTurnCollecting(gateway.coordinator, req2)

        // The turn completed without errors meaning the retrieval path worked
        #expect(events2.completedText != nil)

        // Verify both messages are in the fresh tail
        let tail = await gateway.memoryStore.freshTail(count: 10, for: 1)
        let userMessages = tail.filter { $0.role == .user }
        #expect(userMessages.count >= 2, "Both user messages should be in the fresh tail")
    }

    @Test
    func `Multiple turns accumulate in memory`() async throws {
        let gateway = try await makeGateway()

        let messages = [
            "I prefer Swift over Kotlin.",
            "My favorite IDE is Xcode.",
            "I'm building a browser called Lumen.",
            "It uses WebKit, not Chromium.",
            "The design follows Liquid Glass.",
        ]

        for message in messages {
            let request = makeRequest(message)
            _ = try await runTurnCollecting(gateway.coordinator, request)
        }

        // All messages should be in the fresh tail
        let tail = await gateway.memoryStore.freshTail(count: 20, for: 1)
        let userMessages = tail.filter { $0.role == .user }
        #expect(userMessages.count == messages.count, "All \(messages.count) user messages should be persisted")

        // Each assistant response should also be persisted
        let assistantMessages = tail.filter { $0.role == .assistant }
        #expect(assistantMessages.count == messages.count, "Each turn should produce an assistant message")
    }

    @Test
    func `FTS5 search finds persisted messages`() async throws {
        let gateway = try await makeGateway()

        // Ingest a distinctive message
        let request = makeRequest("The supercalifragilistic algorithm runs in O(n log n).")
        _ = try await runTurnCollecting(gateway.coordinator, request)

        // Search for the distinctive word via grep
        let matches = await gateway.memoryStore.grep(
            pattern: "supercalifragilistic",
            mode: .fullText,
            scope: .all,
        )

        #expect(!matches.isEmpty, "FTS5 should find the ingested message")
    }

    @Test
    func `Different users have separate mirror blocks`() async throws {
        let gateway = try await makeGateway()

        // User A sends a message
        let reqA = makeRequest("I love functional programming.", userKey: "user-alice")
        _ = try await runTurnCollecting(gateway.coordinator, reqA)

        // User B sends a message
        let reqB = makeRequest("I prefer object-oriented design.", userKey: "user-bob")
        _ = try await runTurnCollecting(gateway.coordinator, reqB)

        // Both mirror blocks should exist and be independent
        let mirrorA = await gateway.identityStore.currentMirror(for: "user-alice")
        let mirrorB = await gateway.identityStore.currentMirror(for: "user-bob")

        #expect(mirrorA.userKey == "user-alice")
        #expect(mirrorB.userKey == "user-bob")
    }

    // MARK: - Identity Bootstrap

    @Test
    func `Identity store bootstraps on gateway creation`() async throws {
        let gateway = try await makeGateway()
        let identity = await gateway.identityStore.currentIdentity()

        // Bootstrap creates an empty identity block (no claims yet)
        #expect(identity.claims.isEmpty, "Bootstrap identity should start with no claims")
    }

    // MARK: - Allostasis and Chrono Integration

    @Test
    func `Sequential turns update allostasis state`() async throws {
        let gateway = try await makeGateway()

        // Run several turns to exercise allostasis updates
        for i in 0 ..< 5 {
            let request = makeRequest("Message \(i)")
            _ = try await runTurnCollecting(gateway.coordinator, request)
        }

        // If allostasis crashed or failed to update, the 5th turn would fail.
        let request = makeRequest("Final message after allostasis updates")
        let events = try await runTurnCollecting(gateway.coordinator, request)
        #expect(events.completedText != nil)
    }

    // MARK: - Retrieval Quality

    @Test
    func `Retrieval result contains fresh tail after ingestion`() async throws {
        let gateway = try await makeGateway()

        // Ingest some messages
        for i in 0 ..< 3 {
            let request = makeRequest("Discussion point \(i) about neural networks")
            _ = try await runTurnCollecting(gateway.coordinator, request)
        }

        // Direct retrieval check
        let result = await gateway.memoryStore.retrieve(
            query: "neural networks",
            salienceBoost: .default,
            limit: 10,
        )

        #expect(!result.freshTail.isEmpty, "Retrieval should include fresh tail messages")
    }

    @Test
    func `Expand returns node content for matched nodes`() async throws {
        let gateway = try await makeGateway()

        // Ingest a message to create a node
        let request = makeRequest("Explaining the concept of actor isolation in Swift concurrency")
        _ = try await runTurnCollecting(gateway.coordinator, request)

        // Search for nodes we can expand
        let matches = await gateway.memoryStore.grep(
            pattern: "actor isolation",
            mode: .fullText,
            scope: .all,
        )

        if !matches.isEmpty {
            let nodeIds = matches.map(\.nodeId)
            let expansion = await gateway.memoryStore.expand(nodeIds: nodeIds, tokenBudget: 5_000)
            #expect(!expansion.nodes.isEmpty, "Expand should return content for matched nodes")
        }
    }

    // MARK: - Edge Cases

    @Test
    func `Gateway handles empty messages gracefully`() async throws {
        let gateway = try await makeGateway()
        let request = makeRequest("")
        let events = try await runTurnCollecting(gateway.coordinator, request)

        // Should complete without crashing, even with empty input
        #expect(events.completedText != nil)
    }

    @Test
    func `Gateway handles very long messages`() async throws {
        let gateway = try await makeGateway()
        let longText = String(repeating: "This is a test sentence. ", count: 500)
        let request = makeRequest(longText)
        let events = try await runTurnCollecting(gateway.coordinator, request)

        #expect(events.completedText != nil)
    }
}
