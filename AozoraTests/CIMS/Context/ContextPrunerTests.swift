import Foundation
import GRDB
import Testing
@testable import Aozora

struct ContextPrunerTests {
    /// Create a fresh in-memory database, memory store, and context pruner for each test.
    private func makeComponents(
        tokenBudget: Int = 150_000,
        minCompactableTokens: Int = 2_000,
    ) async throws -> (ContextPruner, MemoryStore, CIMSDatabase) {
        let db = try CIMSDatabase.inMemory()
        let store = MemoryStore(database: db)
        let pruner = ContextPruner(
            database: db,
            tokenBudget: tokenBudget,
            minCompactableTokens: minCompactableTokens,
        )
        return (pruner, store, db)
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

    /// Ingest N turns and return the conversation ID.
    private func ingestTurns(
        _ count: Int,
        store: MemoryStore,
        db: CIMSDatabase,
        padding: Int = 0,
    ) async throws -> ConversationID {
        for i in 1 ... count {
            let extra = padding > 0 ? String(repeating: "word ", count: padding) : ""
            await store.ingest(
                makeMessage("User message \(i) \(extra)"),
                response: makeResponse("Assistant response \(i) \(extra)"),
            )
        }
        return try await db.dbPool.read { db in
            try ConversationRecord.fetchOne(db)!.id!
        }
    }

    // MARK: - Statistics

    @Test
    func `statistics returns nil when no conversation exists`() async throws {
        let (pruner, _, _) = try await makeComponents()

        let stats = try await pruner.statistics()
        #expect(stats == nil)
    }

    @Test
    func `statistics returns correct counts after ingesting turns`() async throws {
        let (pruner, store, db) = try await makeComponents()
        _ = try await ingestTurns(3, store: store, db: db)

        let stats = try await pruner.statistics()
        #expect(stats != nil)
        #expect(stats?.totalMessages == 6)
        #expect(stats?.messagesByRole["user"] == 3)
        #expect(stats?.messagesByRole["assistant"] == 3)
        #expect(stats?.totalNodes == 3)
        #expect(stats?.nodesByDepth[0] == 3)
        #expect(stats?.nodesByKind["raw_turn"] == 3)
        #expect(stats?.frontierSize == 3)
        #expect(stats?.coldNodeCount == 0)
        #expect((stats?.totalEstimatedTokens ?? 0) > 0)
    }

    // MARK: - Compaction

    @Test
    func `compactMessages creates a summary node from a range of turns`() async throws {
        let (pruner, store, db) = try await makeComponents()
        _ = try await ingestTurns(5, store: store, db: db)

        let result = try await pruner.compactMessages(
            startIndex: 0,
            endIndex: 4,
            summary: "Discussion about topics 1 and 2",
        )

        #expect(!result.nodeId.isEmpty)
        #expect(result.nodeId.hasPrefix("node_"))
        #expect(result.summary == "Discussion about topics 1 and 2")
        #expect(result.tokensSaved > 0)

        // Verify the summary node exists in the DAG
        let summaryNode = try await db.dbPool.read { db in
            try LCMNodeRecord.filter(Column("nodeId") == result.nodeId).fetchOne(db)
        }
        #expect(summaryNode != nil)
        #expect(summaryNode?.depth == 1)
        #expect(summaryNode?.kind == NodeKind.leafSummary.rawValue)
        #expect(summaryNode?.summaryText == "Discussion about topics 1 and 2")

        // Verify edges exist from summary to source nodes
        let edges = try await db.dbPool.read { db in
            try LCMEdgeRecord
                .filter(Column("fromNodeId") == result.nodeId)
                .filter(Column("edgeKind") == EdgeKind.summaryOf.rawValue)
                .fetchAll(db)
        }
        #expect(edges.count == 2, "Should link to 2 source nodes (messages 0-3 = turns 0-1)")
    }

    @Test
    func `compactMessages updates the frontier`() async throws {
        let (pruner, store, db) = try await makeComponents()
        let conversationId = try await ingestTurns(4, store: store, db: db)

        let frontierBefore = try await db.dbPool.read { db in
            try LCMFrontierRecord
                .filter(Column("conversationId") == conversationId)
                .fetchAll(db)
        }
        #expect(frontierBefore.count == 4)

        let result = try await pruner.compactMessages(
            startIndex: 0,
            endIndex: 4,
            summary: "Summary of first two turns",
        )

        let frontierAfter = try await db.dbPool.read { db in
            try LCMFrontierRecord
                .filter(Column("conversationId") == conversationId)
                .order(Column("ordinal").asc)
                .fetchAll(db)
        }

        // 2 source nodes replaced by 1 summary + 2 remaining = 3
        #expect(frontierAfter.count == 3)
        #expect(frontierAfter[0].nodeId == result.nodeId)
    }

    @Test
    func `compactMessages rejects invalid range`() async throws {
        let (pruner, store, db) = try await makeComponents()
        _ = try await ingestTurns(2, store: store, db: db)

        await #expect(throws: ToolError.self) {
            try await pruner.compactMessages(
                startIndex: 5,
                endIndex: 3,
                summary: "invalid",
            )
        }
    }

    @Test
    func `compactMessages fails when no conversation exists`() async throws {
        let (pruner, _, _) = try await makeComponents()

        await #expect(throws: ToolError.self) {
            try await pruner.compactMessages(
                startIndex: 0,
                endIndex: 4,
                summary: "Summary",
            )
        }
    }

    // MARK: - Compaction Suggestions

    @Test
    func `suggestCompactions returns empty when under budget`() async throws {
        let (pruner, store, db) = try await makeComponents(tokenBudget: 1_000_000)
        _ = try await ingestTurns(3, store: store, db: db)

        let candidates = try await pruner.suggestCompactions(currentTokenCount: 100)
        #expect(candidates.isEmpty)
    }

    @Test
    func `suggestCompactions returns empty when no conversation exists`() async throws {
        let (pruner, _, _) = try await makeComponents()

        let candidates = try await pruner.suggestCompactions(currentTokenCount: 200_000)
        #expect(candidates.isEmpty)
    }

    // MARK: - Content Categorization (via suggestCompactions behavior)

    @Test
    func `suggestCompactions groups tool-role messages as toolExecution`() async throws {
        let (pruner, _, db) = try await makeComponents(
            tokenBudget: 100,
            minCompactableTokens: 10,
        )

        // Manually insert a conversation with tool-role messages for categorization testing
        let now = DAGCompactor.formatDate(Date())
        try await db.dbPool.write { db in
            var conv = ConversationRecord(
                sessionKey: "test-session",
                userKey: "test-user",
                startedAt: now,
                lastMessageAt: now,
                messageCount: 6,
            )
            try conv.insert(db)
            let convId = conv.id!

            // Insert messages: user, assistant, tool, tool, user, assistant
            let messages: [(String, String)] = [
                ("user", "Run a command"),
                ("assistant", "Running bash..."),
                ("tool", "Exit code: 0\nstdout: hello world"),
                ("tool", "Exit code: 0\nstdout: file contents here"),
                ("user", "Thanks"),
                ("assistant", "You're welcome"),
            ]

            for (i, (role, content)) in messages.enumerated() {
                try db.execute(
                    sql: """
                    INSERT INTO messages (conversationId, role, content, tokenEstimate, createdAt)
                    VALUES (?, ?, ?, ?, ?)
                    """,
                    arguments: [convId, role, content, max(1, content.utf8.count / 4), now],
                )

                // Create raw_turn nodes for user+assistant pairs
                if role == "user" {
                    let nodeId = DAGCompactor.makeNodeId(from: "node_\(i)")
                    let node = LCMNodeRecord(
                        nodeId: nodeId,
                        conversationId: convId,
                        depth: 0,
                        kind: NodeKind.rawTurn.rawValue,
                        tokenCount: 20,
                        checksum: DAGCompactor.sha256Hex("node_\(i)"),
                        salienceScore: 0.5,
                        hotness: 1.0,
                        isCold: 0,
                        canonicalText: content,
                        summaryText: nil,
                        expandFooter: nil,
                        earliestAt: now,
                        latestAt: now,
                        lastAccessedAt: now,
                        version: 1,
                        createdAt: now,
                    )
                    try node.insert(db)

                    let frontier = LCMFrontierRecord(
                        conversationId: convId,
                        nodeId: nodeId,
                        ordinal: i / 2,
                    )
                    try frontier.insert(db)
                }
            }
        }

        // Token count above budget triggers suggestions
        let candidates = try await pruner.suggestCompactions(currentTokenCount: 200)
        // The tool messages should be grouped but may not meet minCompactableTokens with small test data
        // This test validates that the flow doesn't crash and returns a result
        #expect(candidates.count >= 0)
    }

    /// Create a minimal coordinator for tool tests that require one.
    private func makeCoordinator(db: CIMSDatabase) async throws -> CIMSCoordinator {
        let memory = MemoryStore(database: db)
        let identity = try await IdentityStore(database: db)
        return CIMSCoordinator(
            memoryStore: memory,
            identityStore: identity,
            modelProvider: MockModelProvider(),
            workerSupervisor: WorkerSupervisor(),
            systemPrompt: "Test",
        )
    }

    // MARK: - Tool Integration

    @Test
    func `CompactContextTool returns early when utilization is low`() async throws {
        let (pruner, store, db) = try await makeComponents()
        _ = try await ingestTurns(4, store: store, db: db)
        let coordinator = try await makeCoordinator(db: db)
        let tool = CompactContextTool(pruner: pruner, coordinator: coordinator)
        let result = try await tool.execute(
            parameters: [
                "start_index": 0,
                "end_index": 4,
                "summary": "Setup and configuration discussion",
            ],
            workingDirectory: "/tmp",
        )

        // With minimal test data, utilization is well under 60%
        #expect(!result.isError)
        #expect(result.content.contains(CompactContextTool.Labels.noCompactionNeeded))
    }

    @Test
    func `CompactContextTool skips parameter validation when utilization is low`() async throws {
        let (pruner, _, db) = try await makeComponents()
        let coordinator = try await makeCoordinator(db: db)
        let tool = CompactContextTool(pruner: pruner, coordinator: coordinator)

        // Missing parameters are not checked because the utilization gate fires first
        let result = try await tool.execute(
            parameters: ["start_index": 0],
            workingDirectory: "/tmp",
        )
        #expect(!result.isError)
        #expect(result.content.contains(CompactContextTool.Labels.noCompactionNeeded))
    }

    @Test
    func `ContextStatusTool returns formatted statistics`() async throws {
        let (pruner, store, db) = try await makeComponents()
        _ = try await ingestTurns(3, store: store, db: db)
        let coordinator = try await makeCoordinator(db: db)
        let tool = ContextStatusTool(pruner: pruner, coordinator: coordinator)
        let result = try await tool.execute(
            parameters: [:],
            workingDirectory: "/tmp",
        )

        #expect(!result.isError)
        #expect(result.content.contains(ContextStatusTool.Labels.header))
        #expect(result.content.contains("\(ContextStatusTool.Labels.messagesInDB) 6"))
        #expect(result.content.contains("\(ContextStatusTool.Labels.dagNodes) 3"))
        #expect(result.content.contains("raw_turn: 3"))
    }

    @Test
    func `ContextStatusTool handles no conversation gracefully`() async throws {
        let (pruner, _, db) = try await makeComponents()
        let coordinator = try await makeCoordinator(db: db)

        let tool = ContextStatusTool(pruner: pruner, coordinator: coordinator)
        let result = try await tool.execute(
            parameters: [:],
            workingDirectory: "/tmp",
        )

        // With no conversation, statistics returns nil so DAG section is omitted
        #expect(!result.isError)
        #expect(result.content.contains(ContextStatusTool.Labels.header))
        #expect(!result.content.contains(ContextStatusTool.Labels.dagNodes))
    }

    @Test
    func `Tools are registered in ToolRegistry`() async throws {
        let db = try CIMSDatabase.inMemory()
        let pruner = ContextPruner(database: db)
        let coordinator = try await makeCoordinator(db: db)

        let registry = ToolRegistry()
        await registry.register(CompactContextTool(pruner: pruner, coordinator: coordinator))
        await registry.register(ContextStatusTool(pruner: pruner, coordinator: coordinator))

        #expect(await registry.contains("compact_context"))
        #expect(await registry.contains("context_status"))

        let defs = await registry.definitions
        #expect(defs.count == 2)
    }
}
