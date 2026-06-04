import Foundation
import Testing
@testable import Aozora
@testable import GRDB

/// Behavioral benchmarks for the CIMS memory system under realistic load.
///
/// These tests simulate conversations that saturate token budgets, then verify
/// that the memory system can still retrieve specific strings and replies. Unlike
/// unit tests that check individual operations, these exercise the full ingestion →
/// retrieval → assembly pipeline under pressure:
///
/// - **Needle-in-haystack**: Can we find a specific phrase buried under thousands of tokens?
/// - **Budget compliance**: Does context assembly stay within bounds as memory grows?
/// - **Fresh tail invariant**: Are the most recent messages always available, no matter how
///   much history exists?
/// - **Retrieval recall**: Do all planted keywords remain discoverable via FTS5 and grep?
/// - **Multi-session isolation**: Do separate conversations maintain independent memory?
///
/// All tests use ``MockModelProvider`` — no real LLM calls.
struct MemoryBenchmarkTests {
    // MARK: - Helpers

    /// Create a fresh in-memory memory store.
    private func makeStore() async throws -> (MemoryStore, CIMSDatabase) {
        let db = try CIMSDatabase.inMemory()
        let store = MemoryStore(database: db)
        return (store, db)
    }

    /// Create a minimal inbound message.
    private func makeMessage(_ text: String) -> InboundMessage {
        InboundMessage(
            text: text,
            parts: [MessagePart(kind: .text, ordinal: 0, content: text, metadata: nil)],
            metadata: nil,
        )
    }

    /// Create a minimal assistant response.
    private func makeResponse(_ text: String) -> AssistantResponse {
        AssistantResponse(
            content: text,
            parts: [MessagePart(kind: .text, ordinal: 0, content: text, metadata: nil)],
            toolCalls: [],
            tokenUsage: TokenUsage(inputTokens: 10, outputTokens: 10),
            latency: .seconds(1),
        )
    }

    /// Estimate tokens for a text string (matches ContextAssembler's formula).
    private func estimateTokens(_ text: String) -> Int {
        max(1, text.utf8.count / 4)
    }

    /// Create a fully wired in-memory gateway.
    private func makeGateway(systemPrompt: String = "You are a helpful assistant.") async throws -> CIMSGateway {
        try await CIMSGateway.inMemory(systemPrompt: systemPrompt)
    }

    /// Create a turn request.
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

    // MARK: - Needle in Haystack

    @Test
    func `Retrieve a specific phrase buried under 10k tokens of history`() async throws {
        let (store, _) = try await makeStore()

        // Plant the needle early in the conversation
        let needle = "XYLOPHONE_QUANTUM_NEBULA_42"
        await store.ingest(
            makeMessage("Important fact: the secret code is \(needle) and must not be forgotten."),
            response: makeResponse("I'll remember that code for you."),
        )

        // Bury it under ~10k tokens of filler conversation
        var totalTokens = 0
        var turnCount = 0
        while totalTokens < 10_000 {
            let userText = "Turn \(turnCount): " + String(repeating: "The weather today is pleasant and the project is going well. ", count: 5)
            let assistantText = "Response \(turnCount): " + String(repeating: "That sounds great, let me help you with that task. ", count: 5)
            await store.ingest(makeMessage(userText), response: makeResponse(assistantText))
            totalTokens += estimateTokens(userText) + estimateTokens(assistantText)
            turnCount += 1
        }

        // Verify the needle is still discoverable via FTS5
        let matches = await store.grep(pattern: needle, mode: .fullText, scope: .all)
        #expect(!matches.isEmpty, "FTS5 should find the needle phrase after \(totalTokens) tokens of history")
        #expect(matches.first?.excerpt.contains(needle) == true)

        // Also verify via regex grep
        let regexMatches = await store.grep(pattern: "XYLOPHONE.*42", mode: .regex, scope: .all)
        #expect(!regexMatches.isEmpty, "Regex grep should find the needle")
    }

    @Test
    func `Retrieve a specific phrase buried under 50k tokens of history`() async throws {
        let (store, _) = try await makeStore()

        // Plant the needle
        let needle = "CRYSTALLINE_ARCHITECTURE_SIGMA_99"
        await store.ingest(
            makeMessage("The project codename is \(needle), please remember this."),
            response: makeResponse("Noted, I've stored the project codename."),
        )

        // Bury under ~50k tokens
        var totalTokens = 0
        var turnCount = 0
        while totalTokens < 50_000 {
            let topic = ["machine learning", "database design", "UI development", "networking", "testing"][turnCount % 5]
            let userText = "Turn \(turnCount) about \(topic): " + String(repeating: "Let's discuss the implementation details of this feature in depth. ", count: 8)
            let assistantText = "Analysis of \(topic): " + String(repeating: "Here's my detailed analysis of the architecture and implementation. ", count: 8)
            await store.ingest(makeMessage(userText), response: makeResponse(assistantText))
            totalTokens += estimateTokens(userText) + estimateTokens(assistantText)
            turnCount += 1
        }

        // FTS5 should still find it
        let matches = await store.grep(pattern: "CRYSTALLINE_ARCHITECTURE_SIGMA_99", mode: .fullText, scope: .all)
        #expect(!matches.isEmpty, "FTS5 should find needle after \(totalTokens) tokens (\(turnCount) turns)")

        // Verify the node can be expanded
        if let match = matches.first {
            let expansion = await store.expand(nodeIds: [match.nodeId], tokenBudget: 10_000)
            #expect(!expansion.nodes.isEmpty, "Expansion should return the node with the needle")
            let containsNeedle = expansion.nodes.contains { $0.text.contains(needle) }
            #expect(containsNeedle, "Expanded text should contain the needle phrase")
        }
    }

    @Test
    func `Multiple needles at different depths are all retrievable`() async throws {
        let (store, _) = try await makeStore()

        let needles = [
            "AURORA_BOREALIS_ALPHA",
            "COSMIC_RADIATION_BETA",
            "STELLAR_FUSION_GAMMA",
            "QUANTUM_ENTANGLE_DELTA",
            "NEBULA_COLLAPSE_EPSILON",
        ]

        // Plant needles interleaved with filler, each ~2k tokens apart
        for (i, needle) in needles.enumerated() {
            await store.ingest(
                makeMessage("Checkpoint \(i): remember \(needle) for later reference."),
                response: makeResponse("Stored checkpoint \(i): \(needle)"),
            )

            // Add filler between needles
            for j in 0 ..< 5 {
                let filler = "Filler turn \(i)-\(j): " + String(repeating: "Processing data batch number \(i * 5 + j). ", count: 10)
                await store.ingest(makeMessage(filler), response: makeResponse("Acknowledged batch \(i * 5 + j)."))
            }
        }

        // Every needle should be independently discoverable
        for needle in needles {
            let matches = await store.grep(pattern: needle, mode: .fullText, scope: .all)
            #expect(!matches.isEmpty, "FTS5 should find needle: \(needle)")
        }
    }

    // MARK: - Fresh Tail Invariant Under Volume

    @Test
    func `Fresh tail always contains the last N messages regardless of history size`() async throws {
        let (store, db) = try await makeStore()
        let targetTurns = 100

        for i in 0 ..< targetTurns {
            await store.ingest(
                makeMessage("User message \(i)"),
                response: makeResponse("Assistant response \(i)"),
            )
        }

        let conversationId = try await db.dbPool.read { db in
            try ConversationRecord.fetchOne(db)!.id!
        }

        // Fresh tail should return exactly `count` messages (the most recent ones)
        let tailSize = CIMSDefaults.protectedTailCount
        let tail = await store.freshTail(count: tailSize, for: conversationId)

        #expect(tail.count == tailSize, "Fresh tail should have exactly \(tailSize) messages")

        // The last message in the tail should be the most recent assistant response
        #expect(tail.last?.content == "Assistant response \(targetTurns - 1)")

        // The first message in the tail should be the oldest of the last N
        let expectedFirstIndex = targetTurns - (tailSize / 2)
        #expect(tail.first?.content == "User message \(expectedFirstIndex)")

        // All messages should be in chronological order
        for i in 1 ..< tail.count {
            #expect(tail[i].createdAt >= tail[i - 1].createdAt, "Tail messages should be chronologically ordered")
        }
    }

    @Test
    func `Fresh tail with fewer messages than count returns all available`() async throws {
        let (store, db) = try await makeStore()

        // Only 3 turns = 6 messages, but requesting 32
        for i in 0 ..< 3 {
            await store.ingest(
                makeMessage("Short conversation message \(i)"),
                response: makeResponse("Short response \(i)"),
            )
        }

        let conversationId = try await db.dbPool.read { db in
            try ConversationRecord.fetchOne(db)!.id!
        }

        let tail = await store.freshTail(count: CIMSDefaults.protectedTailCount, for: conversationId)
        #expect(tail.count == 6, "Should return all 6 messages when fewer than fresh tail count")
    }

    // MARK: - Context Assembly Under Budget Pressure

    @Test
    func `Context assembly respects a tight 4k token budget`() {
        let assembler = ContextAssembler()

        // Create inputs that would naturally exceed 4k tokens
        let longIdentity = String(repeating: "I am a helpful AI assistant with extensive knowledge. ", count: 20)
        let longMirror = String(repeating: "The user prefers detailed technical explanations. ", count: 20)

        // Create some summary nodes
        var summaries: [SummaryNode] = []
        for i in 0 ..< 10 {
            let text = "Summary \(i): " + String(repeating: "Discussion about this topic. ", count: 10)
            let earliest = Date().addingTimeInterval(Double(-3_600 * (10 - i)))
            let latest = Date().addingTimeInterval(Double(-3_600 * (10 - i) + 1_800))
            summaries.append(SummaryNode(
                nodeId: "summary_\(i)",
                kind: .leafSummary,
                depth: 1,
                tokenCount: 200,
                summaryText: text,
                expandFooter: "Expand for topic \(i) details",
                earliestAt: earliest,
                latestAt: latest,
                salienceScore: 0.3 + Float(i) * 0.05,
                descendantCount: 3,
                parentIds: [],
            ))
        }

        // Create fresh tail messages
        var freshTail: [StoredMessage] = []
        for i in 0 ..< 10 {
            let role: MessageRole = i % 2 == 0 ? .user : .assistant
            let content = "Fresh tail message \(i): " + String(repeating: "Context content. ", count: 5)
            freshTail.append(StoredMessage(
                id: Int64(i),
                conversationId: 1,
                role: role,
                content: content,
                tokenEstimate: 30,
                salienceScore: nil,
                createdAt: Date().addingTimeInterval(Double(-60 * (10 - i))),
                parts: [],
            ))
        }

        let inputs = ContextAssembler.AssemblyInputs(
            systemPrompt: "You are a helpful assistant.",
            identityText: longIdentity,
            mirrorText: longMirror,
            summaries: summaries,
            cognitiveStateText: "<cognitive_state>balanced, 20% pressure</cognitive_state>",
            chronoText: "<chronoception>continuation session</chronoception>",
            freshTail: freshTail,
            tokenBudget: 4_000,
        )

        let assembled = assembler.assemble(inputs)

        let totalTokens = assembled.totalTokens
        #expect(totalTokens <= 4_000, "Assembled context must fit within 4k budget, got \(totalTokens)")
        #expect(assembled.sections.count == 8, "All 8 section kinds should be present")

        // System prompt should always be included
        let systemSection = assembled.sections.first { $0.kind == ContextSectionKind.systemPrompt }
        #expect(systemSection != nil, "System prompt must be present")
        #expect(systemSection?.content == "You are a helpful assistant.")
    }

    @Test
    func `Context assembly with minimal 1k budget still produces valid output`() {
        let assembler = ContextAssembler()

        var freshTailMessages: [StoredMessage] = []
        for i in 0 ..< 20 {
            let role: MessageRole = i % 2 == 0 ? .user : .assistant
            freshTailMessages.append(StoredMessage(
                id: Int64(i),
                conversationId: 1,
                role: role,
                content: "Message \(i) with some content here.",
                tokenEstimate: 10,
                salienceScore: nil,
                createdAt: Date(),
                parts: [],
            ))
        }

        let inputs = ContextAssembler.AssemblyInputs(
            systemPrompt: "You are an AI.",
            identityText: String(repeating: "Identity claim data. ", count: 50),
            mirrorText: String(repeating: "Mirror claim data. ", count: 50),
            summaries: [],
            cognitiveStateText: "<state>ok</state>",
            chronoText: "<chrono>new</chrono>",
            freshTail: freshTailMessages,
            tokenBudget: 1_000,
        )

        let assembled = assembler.assemble(inputs)

        let minBudgetTotal = assembled.totalTokens
        // Allow 5% overshoot — small mandatory sections (identity, mirror, chrono, cognitive)
        // are included in full even under extreme budget pressure.
        #expect(minBudgetTotal <= 1_050, "Must roughly respect 1k budget, got \(minBudgetTotal)")
        #expect(assembled.sections.count == 8, "All sections present even under extreme pressure")
    }

    @Test
    func `Context assembly with 128k budget uses available space`() {
        let assembler = ContextAssembler()

        var summaries: [SummaryNode] = []
        for i in 0 ..< 20 {
            let text = "Summary content for topic \(i). " + String(repeating: "Details about this topic. ", count: 24)
            let earliest = Date().addingTimeInterval(Double(-86_400 * (20 - i)))
            let latest = Date().addingTimeInterval(Double(-86_400 * (20 - i) + 43_200))
            summaries.append(SummaryNode(
                nodeId: "node_\(i)",
                kind: .leafSummary,
                depth: 1,
                tokenCount: 500,
                summaryText: text,
                expandFooter: nil,
                earliestAt: earliest,
                latestAt: latest,
                salienceScore: 0.5,
                descendantCount: 5,
                parentIds: [],
            ))
        }

        let inputs = ContextAssembler.AssemblyInputs(
            systemPrompt: "System prompt.",
            identityText: "I am a test identity.",
            mirrorText: "User is a developer.",
            summaries: summaries,
            cognitiveStateText: "<state>ok</state>",
            chronoText: "<chrono>continuation</chrono>",
            freshTail: [],
            tokenBudget: 128_000,
        )

        let assembled = assembler.assemble(inputs)

        // With 128k budget and 20 summaries of 500 tokens each, summaries should be included
        let summarySection = assembled.sections.first { $0.kind == ContextSectionKind.summaries }
        #expect(summarySection != nil, "Summary section should be present")
        if let section = summarySection {
            #expect(section.tokenEstimate > 0, "Summaries should be included with large budget")
        }
    }

    // MARK: - Retrieval Recall Benchmark

    @Test
    func `All 20 distinctive keywords planted across a conversation are retrievable`() async throws {
        let (store, _) = try await makeStore()

        let keywords = (0 ..< 20).map { i in
            "KEYWORD_\(String(format: "%04d", i))_\(["ALPHA", "BETA", "GAMMA", "DELTA", "EPSILON"][i % 5])"
        }

        // Ingest each keyword with surrounding filler
        for (i, keyword) in keywords.enumerated() {
            await store.ingest(
                makeMessage("Entry \(i): The identifier is \(keyword) for this record."),
                response: makeResponse("Recorded identifier \(keyword) at position \(i)."),
            )

            // Add some noise between entries
            if i % 3 == 0 {
                await store.ingest(
                    makeMessage("Just a regular conversation about programming."),
                    response: makeResponse("Sure, let's talk about that."),
                )
            }
        }

        // Verify every keyword is retrievable
        var found = 0
        for keyword in keywords {
            let matches = await store.grep(pattern: keyword, mode: .fullText, scope: .all)
            if !matches.isEmpty {
                found += 1
            }
        }

        #expect(found == keywords.count, "All \(keywords.count) keywords should be retrievable, found \(found)")
    }

    @Test
    func `Retrieval ranking favors exact matches over partial`() async throws {
        let (store, _) = try await makeStore()

        // Ingest a message with the exact target phrase
        await store.ingest(
            makeMessage("The quantum computing algorithm achieves polynomial speedup."),
            response: makeResponse("That's an impressive result for quantum computing."),
        )

        // Ingest messages with only partial overlap
        for i in 0 ..< 5 {
            await store.ingest(
                makeMessage("General computing discussion \(i) about classical algorithms."),
                response: makeResponse("Classical computing has its own strengths."),
            )
        }

        // Search for "quantum computing" — the exact match should rank first
        let matches = await store.grep(pattern: "quantum computing", mode: .fullText, scope: .all)
        #expect(!matches.isEmpty, "Should find quantum computing")

        if matches.count > 1 {
            // FTS5 BM25 should rank the exact match higher (lower rank = better)
            let firstExcerpt = matches[0].excerpt
            #expect(
                firstExcerpt.contains("quantum") && firstExcerpt.contains("computing"),
                "Top result should contain both search terms",
            )
        }
    }

    // MARK: - Token Budget Saturation

    @Test
    func `Memory system handles 200 turns without degradation`() async throws {
        let (store, db) = try await makeStore()

        let distinctivePhrase = "CANARY_PHRASE_FOR_RETRIEVAL_TEST"

        // Plant canary at turn 50
        for i in 0 ..< 200 {
            let userText: String
            let assistantText: String

            if i == 50 {
                userText = "Important: \(distinctivePhrase) — please track this."
                assistantText = "I've noted the \(distinctivePhrase) for tracking."
            } else {
                userText = "Turn \(i): Discussing topic \(i % 10) in detail with various considerations."
                assistantText = "Response \(i): Here's my analysis of topic \(i % 10) with recommendations."
            }

            await store.ingest(makeMessage(userText), response: makeResponse(assistantText))
        }

        // Verify total message count
        let messageCount = try await db.dbPool.read { db in
            try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM messages")
        }
        #expect(messageCount == 400, "Should have 400 messages (200 turns × 2)")

        // Verify canary is still retrievable
        let matches = await store.grep(pattern: distinctivePhrase, mode: .fullText, scope: .all)
        #expect(!matches.isEmpty, "Canary phrase should survive 200 turns")

        // Verify fresh tail has the most recent messages
        let conversationId = try await db.dbPool.read { db in
            try ConversationRecord.fetchOne(db)!.id!
        }

        let tail = await store.freshTail(count: 10, for: conversationId)
        #expect(tail.count == 10)
        #expect(tail.last?.content.contains("Response 199") == true, "Last message should be from turn 199")
    }

    @Test
    func `Retrieve returns sensible results with large fresh tail`() async throws {
        let (store, _) = try await makeStore()

        // Ingest enough to have a substantial fresh tail
        for i in 0 ..< 50 {
            await store.ingest(
                makeMessage("Turn \(i) discussing Swift concurrency and actor isolation"),
                response: makeResponse("Response \(i) about structured concurrency patterns"),
            )
        }

        let result = await store.retrieve(
            query: "Swift concurrency",
            salienceBoost: .default,
            limit: 10,
        )

        // Fresh tail should be populated
        #expect(!result.freshTail.isEmpty, "Retrieve should include fresh tail")
        #expect(result.freshTail.count <= CIMSDefaults.protectedTailCount, "Fresh tail should not exceed configured count")
    }

    // MARK: - Expand Budget Compliance

    @Test
    func `Expand respects token budget across many nodes`() async throws {
        let (store, db) = try await makeStore()

        // Create 20 turns, each with ~100 tokens of canonical text
        for i in 0 ..< 20 {
            let text = "Turn \(i): " + String(repeating: "word ", count: 50)
            await store.ingest(makeMessage(text), response: makeResponse("Response \(i)."))
        }

        let allNodeIds = try await db.dbPool.read { db in
            try LCMNodeRecord.fetchAll(db).map(\.nodeId)
        }
        #expect(allNodeIds.count == 20)

        // Expand with a small budget — should not include all nodes
        let smallBudget = 500
        let result = await store.expand(nodeIds: allNodeIds, tokenBudget: smallBudget)

        let expandedTokens = result.totalTokens
        #expect(expandedTokens <= smallBudget, "Expansion must respect budget")
        #expect(result.truncated, "Should be truncated when budget is smaller than total content")
        #expect(result.nodes.count < allNodeIds.count, "Should include fewer nodes than total when budget-constrained")
        #expect(result.nodes.count > 0, "Should include at least some nodes")
    }

    // MARK: - Multi-Conversation Isolation

    @Test
    func `Messages from different sessions are isolated in grep scope`() async throws {
        let (store, db) = try await makeStore()

        // Manually create two conversations by ingesting, then changing the session
        // Since MemoryStore uses "default" session, we'll work at the DB level for setup
        // then verify grep scoping

        // First: ingest messages (all go to conversation 1 via default session)
        await store.ingest(
            makeMessage("Conversation one: UNIQUE_PHRASE_ALPHA"),
            response: makeResponse("Noted ALPHA."),
        )

        let conv1Id = try await db.dbPool.read { db in
            try ConversationRecord.fetchOne(db)!.id!
        }

        // Create a second conversation manually and ingest via direct DB manipulation
        let now = MemoryStore.formatDate(Date())
        let conv2Id: Int64 = try await db.dbPool.write { db in
            var conv = ConversationRecord(
                sessionKey: "session-2",
                userKey: "user-2",
                startedAt: now,
                lastMessageAt: nil,
                messageCount: 2,
            )
            try conv.insert(db)
            let convId = conv.id!

            var userMsg = MessageRecord(
                conversationId: convId,
                role: "user",
                content: "Conversation two: UNIQUE_PHRASE_BETA",
                tokenEstimate: 10,
                salienceScore: nil,
                createdAt: now,
            )
            try userMsg.insert(db)

            var assistantMsg = MessageRecord(
                conversationId: convId,
                role: "assistant",
                content: "Noted BETA.",
                tokenEstimate: 5,
                salienceScore: nil,
                createdAt: now,
            )
            try assistantMsg.insert(db)

            // Create node + FTS entry
            let canonicalText = "User: Conversation two: UNIQUE_PHRASE_BETA\nAssistant: Noted BETA."
            let nodeId = MemoryStore.makeNodeId(from: canonicalText)
            let node = LCMNodeRecord(
                nodeId: nodeId,
                conversationId: convId,
                depth: 0,
                kind: NodeKind.rawTurn.rawValue,
                tokenCount: canonicalText.utf8.count / 4,
                checksum: MemoryStore.sha256Hex(canonicalText),
                salienceScore: 0,
                hotness: 1.0,
                isCold: 0,
                canonicalText: canonicalText,
                summaryText: nil,
                expandFooter: nil,
                earliestAt: now,
                latestAt: now,
                lastAccessedAt: now,
                version: 1,
                createdAt: now,
            )
            try node.insert(db)

            let fts = LCMFTSRecord(
                content: canonicalText,
                nodeId: nodeId,
                conversationId: convId,
                depth: 0,
                kind: NodeKind.rawTurn.rawValue,
            )
            try fts.insert(db)

            return convId
        }

        // Global search should find both
        let allAlpha = await store.grep(pattern: "UNIQUE_PHRASE_ALPHA", mode: .fullText, scope: .all)
        let allBeta = await store.grep(pattern: "UNIQUE_PHRASE_BETA", mode: .fullText, scope: .all)
        #expect(!allAlpha.isEmpty, "ALPHA should be globally findable")
        #expect(!allBeta.isEmpty, "BETA should be globally findable")

        // Scoped search should only find the right one
        let conv1Alpha = await store.grep(pattern: "UNIQUE_PHRASE_ALPHA", mode: .fullText, scope: .conversation(conv1Id))
        let conv1Beta = await store.grep(pattern: "UNIQUE_PHRASE_BETA", mode: .fullText, scope: .conversation(conv1Id))
        #expect(!conv1Alpha.isEmpty, "ALPHA should be in conversation 1")
        #expect(conv1Beta.isEmpty, "BETA should NOT be in conversation 1")

        let conv2Alpha = await store.grep(pattern: "UNIQUE_PHRASE_ALPHA", mode: .fullText, scope: .conversation(conv2Id))
        let conv2Beta = await store.grep(pattern: "UNIQUE_PHRASE_BETA", mode: .fullText, scope: .conversation(conv2Id))
        #expect(conv2Alpha.isEmpty, "ALPHA should NOT be in conversation 2")
        #expect(!conv2Beta.isEmpty, "BETA should be in conversation 2")
    }

    // MARK: - End-to-End Budget Saturation via Coordinator

    @Test
    func `Full cognitive cycle remains functional after 30 turns`() async throws {
        let gateway = try await makeGateway()

        // Run 30 turns through the full coordinator pipeline
        for i in 0 ..< 30 {
            let request = makeRequest("Turn \(i): discussing topic \(i % 5) with important context.")
            let events = try await runTurnCollecting(gateway.coordinator, request)

            // Every turn should complete successfully
            let completed = events.contains { event in
                if case .responseCompleted = event { return true }
                return false
            }
            #expect(completed, "Turn \(i) should complete")
        }

        // After 30 turns, verify memory is intact
        let tail = await gateway.memoryStore.freshTail(count: 10, for: 1)
        #expect(tail.count == 10, "Fresh tail should have 10 messages after 30 turns")

        // Retrieval should still work
        let result = await gateway.memoryStore.retrieve(
            query: "discussing topic",
            salienceBoost: .default,
            limit: 10,
        )
        #expect(!result.freshTail.isEmpty, "Retrieval should return results after 30 turns")
    }

    @Test
    func `Planted message survives full cognitive cycle and is retrievable`() async throws {
        let gateway = try await makeGateway()

        // Turn 1: Plant a distinctive message
        let plantedText = "My secret passphrase is VERDANT_PHOENIX_RISING_7734"
        let req1 = makeRequest(plantedText)
        _ = try await runTurnCollecting(gateway.coordinator, req1)

        // Turns 2-15: Add noise
        for i in 2 ... 15 {
            let req = makeRequest("Generic conversation turn \(i) about various topics.")
            _ = try await runTurnCollecting(gateway.coordinator, req)
        }

        // Verify the planted message is still in memory
        let matches = await gateway.memoryStore.grep(
            pattern: "VERDANT_PHOENIX_RISING_7734",
            mode: .fullText,
            scope: .all,
        )
        #expect(!matches.isEmpty, "Planted passphrase should survive 15 turns through full cognitive cycle")

        // Also check it's in the fresh tail (since 15 turns = 30 messages < 32 fresh tail count)
        let tail = await gateway.memoryStore.freshTail(count: CIMSDefaults.protectedTailCount, for: 1)
        let found = tail.contains { $0.content.contains("VERDANT_PHOENIX_RISING_7734") }
        #expect(found, "Planted message should be in fresh tail (30 messages < 32 threshold)")
    }

    // MARK: - DAG Node Integrity

    @Test
    func `Every ingested turn produces exactly one DAG node`() async throws {
        let (store, db) = try await makeStore()
        let turnCount = 50

        for i in 0 ..< turnCount {
            await store.ingest(
                makeMessage("Turn \(i) user message"),
                response: makeResponse("Turn \(i) assistant response"),
            )
        }

        let nodeCount = try await db.dbPool.read { db in
            try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM lcm_nodes WHERE depth = 0")
        } ?? 0
        #expect(nodeCount == turnCount, "Should have exactly \(turnCount) depth-0 nodes")

        // FTS index should also have one entry per node
        let ftsCount = try await db.dbPool.read { db in
            try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM lcm_fts")
        } ?? 0
        #expect(ftsCount == turnCount, "FTS index should have \(turnCount) entries")

        // Frontier should have one entry per node
        let frontierCount = try await db.dbPool.read { db in
            try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM lcm_frontier")
        } ?? 0
        #expect(frontierCount == turnCount, "Frontier should have \(turnCount) entries")
    }

    @Test
    func `Node IDs are unique even with similar content`() async throws {
        let (store, db) = try await makeStore()

        // Ingest messages with very similar but slightly different content
        for i in 0 ..< 10 {
            await store.ingest(
                makeMessage("The value is \(i)"),
                response: makeResponse("Acknowledged value \(i)"),
            )
        }

        let nodeIds = try await db.dbPool.read { db in
            try LCMNodeRecord.fetchAll(db).map(\.nodeId)
        }

        let uniqueIds = Set(nodeIds)
        #expect(uniqueIds.count == nodeIds.count, "All \(nodeIds.count) node IDs should be unique")
    }

    // MARK: - FTS5 Edge Cases

    @Test
    func `FTS5 handles special characters in queries without crashing`() async throws {
        let (store, _) = try await makeStore()

        await store.ingest(
            makeMessage("Testing C++ code with angle<brackets> and \"quotes\""),
            response: makeResponse("Those are common in programming."),
        )

        // These should not crash, even if they return empty results
        let queries = [
            "C++",
            "angle<brackets>",
            "\"quotes\"",
            "(parentheses)",
            "OR AND NOT",
            "*wildcard*",
            "col:on",
            "",
            "   ",
        ]

        for query in queries {
            let results = await store.grep(pattern: query, mode: .fullText, scope: .all)
            // We just verify no crash — results may or may not be empty depending on escaping
            _ = results
        }
    }

    @Test
    func `FTS5 finds multi-word phrases`() async throws {
        let (store, _) = try await makeStore()

        await store.ingest(
            makeMessage("Swift structured concurrency with async await patterns"),
            response: makeResponse("Actor isolation ensures thread safety"),
        )
        await store.ingest(
            makeMessage("Python asyncio event loop mechanisms"),
            response: makeResponse("GIL prevents true parallelism in Python"),
        )

        // "Swift concurrency" should match the first turn
        let swiftMatches = await store.grep(pattern: "Swift concurrency", mode: .fullText, scope: .all)
        #expect(!swiftMatches.isEmpty, "Should find 'Swift concurrency'")

        // "Python asyncio" should match the second turn
        let pythonMatches = await store.grep(pattern: "Python asyncio", mode: .fullText, scope: .all)
        #expect(!pythonMatches.isEmpty, "Should find 'Python asyncio'")

        // "Swift Python" should match nothing (they're in different nodes)
        // Note: FTS5 with quoted tokens searches for each term, so this may match both
        // The key behavior is that it doesn't crash
        let crossMatches = await store.grep(pattern: "Swift Python", mode: .fullText, scope: .all)
        _ = crossMatches // Just verify no crash
    }
}
