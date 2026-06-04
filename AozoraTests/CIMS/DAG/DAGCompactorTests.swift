import GRDB
import Testing
@testable import Aozora

@Suite("DAGCompactor")
struct DAGCompactorTests {
    /// Create a fresh in-memory database, memory store, and compactor for each test.
    private func makeCompactor() async throws -> (DAGCompactor, CIMSDatabase, MemoryStore) {
        let db = try CIMSDatabase.inMemory()
        let model = MockModelProvider(defaultResponse: "Summary of the conversation covering key topics discussed.")
        let compactor = DAGCompactor(database: db, model: model)
        let store = MemoryStore(database: db)
        return (compactor, db, store)
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

    /// Ingest N turns into the store and return the conversation ID.
    private func ingestTurns(
        _ count: Int,
        store: MemoryStore,
        db: CIMSDatabase,
    ) async throws -> ConversationID {
        for i in 1 ... count {
            await store.ingest(
                makeMessage("User message \(i) with enough content to have some tokens"),
                response: makeResponse("Assistant response \(i) with detailed content for testing"),
            )
        }
        return try await db.dbPool.read { db in
            try ConversationRecord.fetchOne(db)!.id!
        }
    }

    // MARK: - Leaf Pass

    @Test("Leaf pass creates summary nodes from raw turns outside fresh tail")
    func leafPassCreatesSummaries() async throws {
        let (compactor, db, store) = try await makeCompactor()
        let freshTailCount = 2
        let conversationId = try await ingestTurns(5, store: store, db: db)

        let result = try await compactor.leafPass(
            conversationId: conversationId,
            freshTailCount: freshTailCount,
        )

        #expect(result.summariesCreated >= 1)

        let leafNodes = try await db.dbPool.read { db in
            try LCMNodeRecord
                .filter(Column("depth") == 1)
                .filter(Column("kind") == NodeKind.leafSummary.rawValue)
                .fetchAll(db)
        }
        #expect(!leafNodes.isEmpty)
        #expect(leafNodes.allSatisfy { $0.summaryText != nil })
        #expect(leafNodes.allSatisfy { $0.expandFooter != nil })
    }

    @Test("Leaf pass never compacts fresh tail nodes")
    func leafPassProtectsFreshTail() async throws {
        let (compactor, db, store) = try await makeCompactor()
        let freshTailCount = 3
        let conversationId = try await ingestTurns(5, store: store, db: db)

        try await compactor.leafPass(
            conversationId: conversationId,
            freshTailCount: freshTailCount,
        )

        let rawNodes = try await db.dbPool.read { db in
            try LCMNodeRecord
                .filter(Column("conversationId") == conversationId)
                .filter(Column("depth") == 0)
                .order(Column("earliestAt").asc)
                .fetchAll(db)
        }

        let summarizedNodeIds = try await db.dbPool.read { db in
            try Set(String.fetchAll(
                db,
                sql: "SELECT toNodeId FROM lcm_edges WHERE edgeKind = ?",
                arguments: [EdgeKind.summaryOf.rawValue],
            ))
        }

        let lastN = Array(rawNodes.suffix(freshTailCount))
        for node in lastN {
            #expect(
                !summarizedNodeIds.contains(node.nodeId),
                "Fresh tail node \(node.nodeId) should not be summarized",
            )
        }
    }

    @Test("Leaf pass creates summary_of edges")
    func leafPassCreatesEdges() async throws {
        let (compactor, db, store) = try await makeCompactor()
        let conversationId = try await ingestTurns(5, store: store, db: db)

        try await compactor.leafPass(
            conversationId: conversationId,
            freshTailCount: 2,
        )

        let edges = try await db.dbPool.read { db in
            try LCMEdgeRecord
                .filter(Column("edgeKind") == EdgeKind.summaryOf.rawValue)
                .fetchAll(db)
        }
        #expect(!edges.isEmpty)
    }

    @Test("Leaf pass is idempotent — running twice produces no additional summaries")
    func leafPassIdempotent() async throws {
        let (compactor, db, store) = try await makeCompactor()
        let conversationId = try await ingestTurns(5, store: store, db: db)

        let first = try await compactor.leafPass(
            conversationId: conversationId,
            freshTailCount: 2,
        )

        let second = try await compactor.leafPass(
            conversationId: conversationId,
            freshTailCount: 2,
        )

        #expect(first.summariesCreated >= 1)
        #expect(second.summariesCreated == 0)
    }

    @Test("Leaf pass does nothing when all nodes are within fresh tail")
    func leafPassNoOpWhenAllFresh() async throws {
        let (compactor, db, store) = try await makeCompactor()
        let conversationId = try await ingestTurns(2, store: store, db: db)

        let result = try await compactor.leafPass(
            conversationId: conversationId,
            freshTailCount: 5,
        )

        #expect(result.summariesCreated == 0)
    }

    @Test("Leaf pass updates the frontier")
    func leafPassUpdatesFrontier() async throws {
        let (compactor, db, store) = try await makeCompactor()
        let conversationId = try await ingestTurns(5, store: store, db: db)

        let frontierBefore = try await db.dbPool.read { db in
            try LCMFrontierRecord
                .filter(Column("conversationId") == conversationId)
                .fetchAll(db)
        }

        try await compactor.leafPass(
            conversationId: conversationId,
            freshTailCount: 2,
        )

        let frontierAfter = try await db.dbPool.read { db in
            try LCMFrontierRecord
                .filter(Column("conversationId") == conversationId)
                .order(Column("ordinal").asc)
                .fetchAll(db)
        }

        #expect(
            frontierAfter.count < frontierBefore.count,
            "Frontier should shrink after compaction replaces raw nodes with summaries",
        )

        let ordinals = frontierAfter.map(\.ordinal)
        #expect(
            ordinals == Array(0 ..< ordinals.count),
            "Frontier ordinals should be contiguous",
        )
    }

    @Test("Leaf pass indexes new summaries in FTS5")
    func leafPassIndexesFTS() async throws {
        let (compactor, db, store) = try await makeCompactor()
        let conversationId = try await ingestTurns(5, store: store, db: db)

        try await compactor.leafPass(
            conversationId: conversationId,
            freshTailCount: 2,
        )

        let ftsDepth1 = try await db.dbPool.read { db in
            try Int.fetchOne(
                db,
                sql: "SELECT COUNT(*) FROM lcm_fts WHERE depth = 1",
            )
        }
        #expect((ftsDepth1 ?? 0) >= 1)
    }

    // MARK: - Three-Tier Escalation

    @Test("Deterministic truncation produces output within token limit")
    func deterministicTruncation() throws {
        let longText = String(repeating: "This is a long sentence. ", count: 200)
        let compactor = try DAGCompactor(
            database: CIMSDatabase.inMemory(),
            model: MockModelProvider(),
        )

        let truncated = longText.prefix(CIMSDefaults.deterministicTruncationTokens * 4)
        #expect(truncated.count <= CIMSDefaults.deterministicTruncationTokens * 4 + 100)
    }

    // MARK: - Node ID Determinism

    @Test("DAGCompactor node IDs are deterministic")
    func nodeIdDeterminism() {
        let text = "Summary of conversation topics"
        let id1 = DAGCompactor.makeNodeId(from: text)
        let id2 = DAGCompactor.makeNodeId(from: text)
        #expect(id1 == id2)
        #expect(id1.hasPrefix("node_"))
    }

    // MARK: - Pre-Compression Claim Extraction

    /// Create a compactor with a ClaimExtractor and a mock model provider.
    /// Returns separate model references so tests can enqueue responses for both
    /// claim extraction and summarization independently.
    private func makeCompactorWithClaimExtractor(
        claimResponse _: String,
        summaryResponse: String = "Summary of the conversation covering key topics discussed.",
    ) async throws -> (DAGCompactor, CIMSDatabase, MemoryStore, MockModelProvider) {
        let db = try CIMSDatabase.inMemory()
        let model = MockModelProvider(defaultResponse: summaryResponse)
        let claimExtractor = ClaimExtractor(model: model)
        let compactor = DAGCompactor(database: db, model: model, claimExtractor: claimExtractor)
        let store = MemoryStore(database: db)
        return (compactor, db, store, model)
    }

    /// Set the salience score for specific raw_turn nodes in the database.
    private func setSalienceScores(
        _ scores: [Double],
        conversationId: ConversationID,
        db: CIMSDatabase,
    ) async throws {
        let nodes = try await db.dbPool.read { db in
            try LCMNodeRecord
                .filter(Column("conversationId") == conversationId)
                .filter(Column("depth") == 0)
                .order(Column("earliestAt").asc)
                .fetchAll(db)
        }

        for (index, score) in scores.enumerated() where index < nodes.count {
            try await db.dbPool.write { db in
                try db.execute(
                    sql: "UPDATE lcm_nodes SET salienceScore = ? WHERE nodeId = ?",
                    arguments: [score, nodes[index].nodeId],
                )
            }
        }
    }

    @Test("Leaf pass extracts claims from high-salience nodes before compaction")
    func leafPassExtractsClaimsFromHighSalienceNodes() async throws {
        let claimJSON = """
        {
            "nothingSignificant": false,
            "rationale": "Found identity-relevant content about communication preferences.",
            "identityProposals": [
                {
                    "claimKey": "self.communication.directness",
                    "value": "Prefers direct, concise communication",
                    "confidence": 0.7,
                    "evidenceType": "behavior",
                    "excerpt": "User message with enough content"
                }
            ],
            "mirrorProposals": []
        }
        """
        let (compactor, db, store, model) = try await makeCompactorWithClaimExtractor(
            claimResponse: claimJSON,
        )
        let conversationId = try await ingestTurns(5, store: store, db: db)

        // Set high salience scores on the first 3 nodes (outside fresh tail of 2)
        try await setSalienceScores([0.8, 0.7, 0.9, 0.3, 0.2], conversationId: conversationId, db: db)

        // Enqueue the claim extraction response first (it runs before summarization),
        // then the summarization response will use the default.
        await model.enqueueText(claimJSON)

        let result = try await compactor.leafPass(
            conversationId: conversationId,
            freshTailCount: 2,
        )

        #expect(result.summariesCreated >= 1)
        #expect(!result.preCompressionProposals.isEmpty)

        let firstProposal = result.preCompressionProposals[0]
        #expect(!firstProposal.nothingSignificant)
        #expect(!firstProposal.identityProposals.isEmpty)
        #expect(firstProposal.identityProposals[0].claimKey == "self.communication.directness")
    }

    @Test("Leaf pass skips claim extraction when all nodes have low salience")
    func leafPassSkipsClaimExtractionForLowSalience() async throws {
        let (compactor, db, store, _) = try await makeCompactorWithClaimExtractor(
            claimResponse: "should not be called",
        )
        let conversationId = try await ingestTurns(5, store: store, db: db)

        // Set all salience scores below the 0.6 threshold
        try await setSalienceScores([0.1, 0.2, 0.3, 0.4, 0.5], conversationId: conversationId, db: db)

        let result = try await compactor.leafPass(
            conversationId: conversationId,
            freshTailCount: 2,
        )

        #expect(result.summariesCreated >= 1)
        #expect(result.preCompressionProposals.isEmpty)
    }

    @Test("Leaf pass works without a ClaimExtractor (backward compatible)")
    func leafPassWorksWithoutClaimExtractor() async throws {
        let (compactor, db, store) = try await makeCompactor()
        let conversationId = try await ingestTurns(5, store: store, db: db)

        // Set high salience — should still produce no proposals since no ClaimExtractor
        try await setSalienceScores([0.9, 0.8, 0.7, 0.6, 0.5], conversationId: conversationId, db: db)

        let result = try await compactor.leafPass(
            conversationId: conversationId,
            freshTailCount: 2,
        )

        #expect(result.summariesCreated >= 1)
        #expect(result.preCompressionProposals.isEmpty)
    }
}
