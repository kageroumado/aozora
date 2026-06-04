import Foundation
import GRDB
import Testing
@testable import Aozora

struct MemoryStoreTests {
    /// Create a fresh in-memory database and memory store for each test.
    private func makeStore() async throws -> (MemoryStore, CIMSDatabase) {
        let db = try CIMSDatabase.inMemory()
        let store = MemoryStore(database: db)
        return (store, db)
    }

    /// Helper to create a minimal inbound message.
    private func makeMessage(_ text: String) -> InboundMessage {
        InboundMessage(
            text: text,
            parts: [MessagePart(kind: .text, ordinal: 0, content: text, metadata: nil)],
            metadata: nil,
        )
    }

    /// Helper to create a minimal assistant response.
    private func makeResponse(_ text: String) -> AssistantResponse {
        AssistantResponse(
            content: text,
            parts: [MessagePart(kind: .text, ordinal: 0, content: text, metadata: nil)],
            toolCalls: [],
            tokenUsage: TokenUsage(inputTokens: 10, outputTokens: 10),
            latency: .seconds(1),
        )
    }

    // MARK: - Ingest Roundtrip

    @Test
    func `Ingest creates conversation, messages, DAG node, FTS entry, and frontier`() async throws {
        let (store, db) = try await makeStore()

        await store.ingest(
            makeMessage("Hello, how are you?"),
            response: makeResponse("I'm doing well, thanks!"),
        )

        let conversations = try await db.dbPool.read { db in
            try ConversationRecord.fetchAll(db)
        }
        #expect(conversations.count == 1)
        #expect(conversations[0].messageCount == 2)

        let messages = try await db.dbPool.read { db in
            try MessageRecord.fetchAll(db)
        }
        #expect(messages.count == 2)
        #expect(messages[0].role == "user")
        #expect(messages[1].role == "assistant")

        let parts = try await db.dbPool.read { db in
            try MessagePartRecord.fetchAll(db)
        }
        #expect(parts.count == 2)

        let nodes = try await db.dbPool.read { db in
            try LCMNodeRecord.fetchAll(db)
        }
        #expect(nodes.count == 1)
        #expect(nodes[0].depth == 0)
        #expect(nodes[0].kind == NodeKind.rawTurn.rawValue)
        #expect(nodes[0].canonicalText?.contains("Hello, how are you?") == true)
        #expect(nodes[0].canonicalText?.contains("I'm doing well, thanks!") == true)

        let ftsCount = try await db.dbPool.read { db in
            try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM lcm_fts")
        }
        #expect(ftsCount == 1)

        let frontier = try await db.dbPool.read { db in
            try LCMFrontierRecord.fetchAll(db)
        }
        #expect(frontier.count == 1)
        #expect(frontier[0].ordinal == 0)
    }

    @Test
    func `Multiple ingests increment frontier ordinals`() async throws {
        let (store, db) = try await makeStore()

        await store.ingest(
            makeMessage("First message"),
            response: makeResponse("First response"),
        )
        await store.ingest(
            makeMessage("Second message"),
            response: makeResponse("Second response"),
        )

        let frontier = try await db.dbPool.read { db in
            try LCMFrontierRecord
                .order(Column("ordinal").asc)
                .fetchAll(db)
        }
        #expect(frontier.count == 2)
        #expect(frontier[0].ordinal == 0)
        #expect(frontier[1].ordinal == 1)

        let conversation = try await db.dbPool.read { db in
            try ConversationRecord.fetchOne(db)
        }
        #expect(conversation?.messageCount == 4)
    }

    // MARK: - Node ID Determinism

    @Test
    func `Node IDs are deterministic based on canonical text`() {
        let text = "User: hello\nAssistant: world"
        let id1 = MemoryStore.makeNodeId(from: text)
        let id2 = MemoryStore.makeNodeId(from: text)
        #expect(id1 == id2)
        #expect(id1.hasPrefix("node_"))
        #expect(id1.count == "node_".count + 16)

        let id3 = MemoryStore.makeNodeId(from: "different text")
        #expect(id1 != id3)
    }

    // MARK: - FTS5 Search

    @Test
    func `FTS5 search via grep returns matching nodes`() async throws {
        let (store, _) = try await makeStore()

        await store.ingest(
            makeMessage("Swift concurrency is important"),
            response: makeResponse("Yes, actors and async/await are key features"),
        )
        await store.ingest(
            makeMessage("What about Python?"),
            response: makeResponse("Python is also popular"),
        )

        let results = await store.grep(pattern: "concurrency", mode: .fullText, scope: .all)
        #expect(results.count >= 1)
        #expect(results[0].nodeId.hasPrefix("node_"))
    }

    @Test
    func `FTS5 search handles special characters safely`() async throws {
        let (store, _) = try await makeStore()

        await store.ingest(
            makeMessage("Testing C++ and C# code"),
            response: makeResponse("Both are compiled languages"),
        )

        let results = await store.grep(pattern: "C++ code", mode: .fullText, scope: .all)
        #expect(results.count >= 0)
    }

    @Test
    func `Regex grep matches patterns in canonical text`() async throws {
        let (store, _) = try await makeStore()

        await store.ingest(
            makeMessage("Error code 42 occurred at line 100"),
            response: makeResponse("That error means timeout"),
        )

        let results = await store.grep(pattern: "code \\d+", mode: .regex, scope: .all)
        #expect(results.count == 1)
        #expect(results[0].excerpt == "code 42")
    }

    // MARK: - Fresh Tail

    @Test
    func `freshTail returns messages ordered oldest first`() async throws {
        let (store, db) = try await makeStore()

        await store.ingest(
            makeMessage("First"),
            response: makeResponse("Response 1"),
        )
        await store.ingest(
            makeMessage("Second"),
            response: makeResponse("Response 2"),
        )
        await store.ingest(
            makeMessage("Third"),
            response: makeResponse("Response 3"),
        )

        let conversationId = try await db.dbPool.read { db in
            try ConversationRecord.fetchOne(db)!.id!
        }

        let tail = await store.freshTail(count: 4, for: conversationId)
        #expect(tail.count == 4)
        // Last 4 of 6 messages: Second, Response 2, Third, Response 3
        #expect(tail[0].content == "Second")
        #expect(tail[1].content == "Response 2")
        #expect(tail[2].content == "Third")
        #expect(tail[3].content == "Response 3")
    }

    @Test
    func `freshTail respects count limit`() async throws {
        let (store, db) = try await makeStore()

        for i in 1 ... 5 {
            await store.ingest(
                makeMessage("Message \(i)"),
                response: makeResponse("Response \(i)"),
            )
        }

        let conversationId = try await db.dbPool.read { db in
            try ConversationRecord.fetchOne(db)!.id!
        }

        let tail = await store.freshTail(count: 3, for: conversationId)
        #expect(tail.count == 3)
        #expect(tail.last?.content == "Response 5")
    }

    // MARK: - Delegation Grant Lifecycle

    @Test
    func `Delegation grant creation and revocation`() async throws {
        let (store, db) = try await makeStore()

        let scope = DelegationScope(
            conversationScope: .all,
            operations: [.grep, .expand],
            tokenCap: 10_000,
        )

        let grant = await store.createDelegationGrant(scope: scope)
        let grantId = grant.grantId
        #expect(!grantId.isEmpty)
        #expect(grant.tokenCap == 10_000)
        #expect(grant.tokensUsed == 0)
        #expect(grant.revokedAt == nil)

        let record = try await db.dbPool.read { db in
            try DelegationGrantRecord.fetchOne(db, key: grantId)
        }
        #expect(record != nil)
        #expect(record?.revokedAt == nil)

        await store.revokeDelegationGrant(grantId)

        let revokedRecord = try await db.dbPool.read { db in
            try DelegationGrantRecord.fetchOne(db, key: grantId)
        }
        #expect(revokedRecord?.revokedAt != nil)
    }

    // MARK: - Expand

    @Test
    func `Expand retrieves canonical text for nodes within budget`() async throws {
        let (store, db) = try await makeStore()

        await store.ingest(
            makeMessage("Short message"),
            response: makeResponse("Short reply"),
        )

        let nodeId = try await db.dbPool.read { db in
            try LCMNodeRecord.fetchOne(db)!.nodeId
        }

        let result = await store.expand(nodeIds: [nodeId], tokenBudget: 100_000)
        #expect(result.nodes.count == 1)
        #expect(result.nodes[0].text.contains("Short message"))
        #expect(!result.truncated)
    }

    @Test
    func `Expand truncates when budget exceeded`() async throws {
        let (store, db) = try await makeStore()

        await store.ingest(
            makeMessage("First turn with some content"),
            response: makeResponse("First response with content"),
        )
        await store.ingest(
            makeMessage("Second turn with more content"),
            response: makeResponse("Second response with content"),
        )

        let nodeIds = try await db.dbPool.read { db in
            try LCMNodeRecord.fetchAll(db).map(\.nodeId)
        }
        #expect(nodeIds.count == 2)

        let result = await store.expand(nodeIds: nodeIds, tokenBudget: 20)
        #expect(result.nodes.count == 1)
        #expect(result.truncated)
    }

    // MARK: - Retrieve

    @Test
    func `Retrieve returns fresh tail and empty summaries for depth-0 only data`() async throws {
        let (store, _) = try await makeStore()

        await store.ingest(
            makeMessage("Hello world"),
            response: makeResponse("Hi there"),
        )

        let result = await store.retrieve(
            query: "hello",
            salienceBoost: .default,
            limit: 10,
        )

        #expect(result.summaries.isEmpty)
        #expect(result.freshTail.count >= 1)
    }

    // MARK: - FTS5 Escaping

    @Test
    func `FTS5 query escaping wraps tokens in quotes`() {
        let escaped = MemoryStore.escapeFTS5Query("hello world")
        #expect(escaped == "\"hello\" \"world\"")

        let special = MemoryStore.escapeFTS5Query("C++ AND NOT")
        #expect(special == "\"C++\" \"AND\" \"NOT\"")

        let empty = MemoryStore.escapeFTS5Query("")
        #expect(empty == "")

        let quotes = MemoryStore.escapeFTS5Query("say \"hello\"")
        #expect(quotes == "\"say\" \"hello\"")
    }

    // MARK: - Offline Component Helpers

    /// Create a store with offline components (compactor, cold storage, bump detector) injected.
    private func makeStoreWithOfflineComponents() async throws -> (MemoryStore, CIMSDatabase) {
        let db = try CIMSDatabase.inMemory()
        let model = MockModelProvider(
            defaultResponse: "Summary of the conversation covering key topics discussed.",
        )
        let store = MemoryStore(database: db)
        await store.setOfflineComponents(
            compactor: DAGCompactor(database: db, model: model),
            coldStorage: ColdStorage(database: db),
            bumpDetector: BumpDetector(database: db),
        )
        return (store, db)
    }

    /// Ingest N turns into the store and return the conversation ID.
    private func ingestTurns(
        _ count: Int,
        store: MemoryStore,
        db: CIMSDatabase,
        tokenPadding: Int = 0,
    ) async throws -> ConversationID {
        for i in 1 ... count {
            let padding = tokenPadding > 0
                ? String(repeating: "word ", count: tokenPadding)
                : ""
            await store.ingest(
                makeMessage("User message \(i) \(padding)"),
                response: makeResponse("Assistant response \(i) \(padding)"),
            )
        }
        return try await db.dbPool.read { db in
            try ConversationRecord.fetchOne(db)!.id!
        }
    }

    // MARK: - compactIfNeeded

    @Test
    func `compactIfNeeded triggers leaf pass when raw tokens exceed threshold`() async throws {
        let (store, db) = try await makeStoreWithOfflineComponents()

        let wordsPerTurn = 2_500
        let turnsNeeded = (CIMSDefaults.leafChunkTokens / wordsPerTurn) + CIMSDefaults.protectedTailCount + 2
        _ = try await ingestTurns(turnsNeeded, store: store, db: db, tokenPadding: wordsPerTurn)

        await store.compactIfNeeded()

        let leafNodes = try await db.dbPool.read { db in
            try LCMNodeRecord
                .filter(Column("depth") == 1)
                .filter(Column("kind") == NodeKind.leafSummary.rawValue)
                .fetchAll(db)
        }
        #expect(!leafNodes.isEmpty, "Leaf pass should create summary nodes when above threshold")
    }

    @Test
    func `compactIfNeeded does nothing when raw tokens are under threshold`() async throws {
        let (store, db) = try await makeStoreWithOfflineComponents()

        _ = try await ingestTurns(3, store: store, db: db)

        await store.compactIfNeeded()

        let leafNodes = try await db.dbPool.read { db in
            try LCMNodeRecord
                .filter(Column("depth") == 1)
                .fetchAll(db)
        }
        #expect(leafNodes.isEmpty, "No compaction should happen under the token threshold")
    }

    // MARK: - demoteColdNodes

    @Test
    func `demoteColdNodes delegates to ColdStorage`() async throws {
        let (store, db) = try await makeStoreWithOfflineComponents()
        _ = try await ingestTurns(1, store: store, db: db)

        let oldDate = MemoryStore.formatDate(Date().addingTimeInterval(-86_400 * 60))
        try await db.dbPool.write { db in
            try db.execute(
                sql: """
                UPDATE lcm_nodes
                SET hotness = 0.01, lastAccessedAt = ?, isCold = 0
                """,
                arguments: [oldDate],
            )
        }

        await store.demoteColdNodes()

        let coldNodes = try await db.dbPool.read { db in
            try LCMNodeRecord.filter(Column("isCold") == 1).fetchAll(db)
        }
        #expect(!coldNodes.isEmpty, "Eligible nodes should be demoted to cold storage")

        let payloads = try await db.dbPool.read { db in
            try ColdPayloadRecord.fetchAll(db)
        }
        #expect(!payloads.isEmpty, "Cold payloads should exist after demotion")
    }

    // MARK: - scanForBumps

    @Test
    func `scanForBumps delegates to BumpDetector and returns candidates`() async throws {
        let (store, _) = try await makeStoreWithOfflineComponents()

        let past = Date().addingTimeInterval(-3_600)

        await store.ingest(
            makeMessage("I just realized I was wrong about the architecture"),
            response: makeResponse("That's an important correction, let's discuss."),
        )

        let candidates = await store.scanForBumps(since: past)
        #expect(!candidates.isEmpty, "Bump detector should find correction patterns")
        #expect(candidates[0].reason == BumpReason.correctionOrDiscovery)
    }

    @Test
    func `scanForBumps returns empty when no components injected`() async throws {
        let (store, _) = try await makeStore()

        await store.ingest(
            makeMessage("I just realized I was wrong"),
            response: makeResponse("Interesting correction"),
        )

        let candidates = await store.scanForBumps(since: Date().addingTimeInterval(-3_600))
        #expect(candidates.isEmpty, "Should return empty when bump detector is not injected")
    }

    // MARK: - decayHotness

    @Test
    func `decayHotness reduces hotness for nodes accessed more than 1 day ago`() async throws {
        let (store, db) = try await makeStoreWithOfflineComponents()
        _ = try await ingestTurns(1, store: store, db: db)

        let twoDaysAgo = MemoryStore.formatDate(Date().addingTimeInterval(-86_400 * 2))
        try await db.dbPool.write { db in
            try db.execute(
                sql: "UPDATE lcm_nodes SET hotness = 1.0, lastAccessedAt = ?",
                arguments: [twoDaysAgo],
            )
        }

        let hotnessBefore = try await db.dbPool.read { db in
            try Double.fetchOne(db, sql: "SELECT hotness FROM lcm_nodes LIMIT 1")
        }
        #expect(hotnessBefore == 1.0)

        await store.decayHotness()

        let hotnessAfter = try await db.dbPool.read { db in
            try Double.fetchOne(db, sql: "SELECT hotness FROM lcm_nodes LIMIT 1")
        }
        #expect(hotnessAfter != nil)
        #expect(try #require(hotnessAfter) < 1.0, "Hotness should decrease after decay")
        #expect(try abs(#require(hotnessAfter) - 0.95) < 0.01, "Hotness should be multiplied by 0.95")
    }

    @Test
    func `decayHotness does not affect recently accessed nodes`() async throws {
        let (store, db) = try await makeStoreWithOfflineComponents()
        _ = try await ingestTurns(1, store: store, db: db)

        let now = MemoryStore.formatDate(Date())
        try await db.dbPool.write { db in
            try db.execute(
                sql: "UPDATE lcm_nodes SET hotness = 1.0, lastAccessedAt = ?",
                arguments: [now],
            )
        }

        await store.decayHotness()

        let hotnessAfter = try await db.dbPool.read { db in
            try Double.fetchOne(db, sql: "SELECT hotness FROM lcm_nodes LIMIT 1")
        }
        #expect(try abs(#require(hotnessAfter) - 1.0) < 0.0001, "Recently accessed nodes should not be decayed")
    }
}
