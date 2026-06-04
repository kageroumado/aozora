import Foundation
import GRDB
import Testing
@testable import Aozora

/// Integration tests for the DAG compaction pipeline.
///
/// These tests validate the full compaction round-trip: ingest raw messages,
/// compact them into summaries, and verify that summaries are retrievable
/// while the fresh tail remains untouched.
struct CompactionIntegrationTests {
    // MARK: - Helpers

    private func makeGateway() async throws -> CIMSGateway {
        try await CIMSGateway.inMemory()
    }

    private func makeRequest(_ text: String) -> TurnRequest {
        TurnRequest(
            turnID: UUID().uuidString,
            sessionKey: "test-session",
            userKey: "test-user",
            message: InboundMessage(
                text: text,
                parts: [MessagePart(kind: .text, ordinal: 0, content: text, metadata: nil)],
                metadata: nil,
            ),
            receivedAt: Date(),
        )
    }

    // MARK: - Fresh Tail Invariant

    @Test
    func `Fresh tail messages are never compacted`() async throws {
        let gateway = try await makeGateway()

        // Ingest messages up to fresh tail count
        let freshTailCount = CIMSDefaults.protectedTailCount
        for i in 0 ..< freshTailCount {
            let request = makeRequest("Fresh tail message \(i)")
            _ = try await runTurnCollecting(gateway.coordinator, request)
        }

        // Compact
        await gateway.memoryStore.compactFull()

        // Fresh tail should still have all raw messages
        let tail = await gateway.memoryStore.freshTail(count: freshTailCount * 2, for: 1)
        let userMessages = tail.filter { $0.role == .user }

        // All messages should still be in the tail since we only ingested freshTailCount
        #expect(
            userMessages.count == freshTailCount,
            "All \(freshTailCount) messages should remain in the fresh tail",
        )
    }

    // MARK: - Compaction Idempotency

    @Test
    func `Running compaction twice produces same result`() async throws {
        let gateway = try await makeGateway()

        // Ingest more messages than the fresh tail to trigger compaction
        let messageCount = CIMSDefaults.protectedTailCount + 10
        for i in 0 ..< messageCount {
            let request = makeRequest("Compaction test message \(i) with enough content to matter")
            _ = try await runTurnCollecting(gateway.coordinator, request)
        }

        // First compaction
        await gateway.memoryStore.compactFull()

        // Get state after first compaction
        let summaries1 = await gateway.memoryStore.summaries(for: 1, tokenBudget: 100_000)
        let tail1 = await gateway.memoryStore.freshTail(count: CIMSDefaults.protectedTailCount, for: 1)

        // Second compaction (should be a no-op)
        await gateway.memoryStore.compactFull()

        // Get state after second compaction
        let summaries2 = await gateway.memoryStore.summaries(for: 1, tokenBudget: 100_000)
        let tail2 = await gateway.memoryStore.freshTail(count: CIMSDefaults.protectedTailCount, for: 1)

        // Results should be the same
        #expect(summaries1.count == summaries2.count, "Compaction should be idempotent for summaries")
        #expect(tail1.count == tail2.count, "Fresh tail should be unchanged by second compaction")
    }

    // MARK: - Cold Storage Round-trip

    @Test
    func `Cold storage demotion and promotion preserves content`() async throws {
        let db = try CIMSDatabase.inMemory()
        let coldStorage = ColdStorage(database: db)
        let originalContent = "This is test content for cold storage round-trip validation."
        let now = ColdStorage.formatDate(Date())
        let oldDate = ColdStorage.formatDate(Date().addingTimeInterval(-3_600 * 24 * 60))

        // Create a conversation and a node with low hotness and old access date
        try await db.dbPool.write { dbConn in
            var conversation = ConversationRecord(
                sessionKey: "test",
                userKey: "test",
                startedAt: now,
                lastMessageAt: nil,
                messageCount: 0,
            )
            try conversation.insert(dbConn)

            let node = LCMNodeRecord(
                nodeId: "node_testcold123",
                conversationId: 1,
                depth: 0,
                kind: "rawTurn",
                tokenCount: 12,
                checksum: nil,
                salienceScore: 0.01,
                hotness: 0.05,
                isCold: 0,
                canonicalText: originalContent,
                summaryText: nil,
                expandFooter: nil,
                earliestAt: oldDate,
                latestAt: oldDate,
                lastAccessedAt: oldDate,
                version: 1,
                createdAt: oldDate,
            )
            try node.insert(dbConn)
        }

        // Demote eligible nodes (our node qualifies: low hotness + old access)
        let demoted = try await coldStorage.demoteEligibleNodes()
        #expect(demoted == 1, "Should demote one node")

        // Verify the node is cold
        let coldNode = try await db.dbPool.read { dbConn in
            try LCMNodeRecord.filter(Column("nodeId") == "node_testcold123").fetchOne(dbConn)
        }
        #expect(coldNode?.isCold == 1, "Node should be marked as cold after demotion")
        #expect(coldNode?.canonicalText == nil, "Canonical text should be nil after demotion")

        // Promote back from cold storage
        try await coldStorage.promote(nodeId: "node_testcold123")

        // Verify the node is restored
        let warmNode = try await db.dbPool.read { dbConn in
            try LCMNodeRecord.filter(Column("nodeId") == "node_testcold123").fetchOne(dbConn)
        }
        #expect(warmNode?.isCold == 0, "Node should be warm after promotion")
        #expect(warmNode?.canonicalText == originalContent, "Canonical text should be restored exactly")
    }

    // MARK: - Full Consolidation Pipeline

    @Test
    func `Full consolidation pipeline completes without errors`() async throws {
        let gateway = try await makeGateway()

        // Ingest several turns to give the consolidation pipeline something to work with
        let messages = [
            "I realized I was wrong about the architecture. We should use actors, not classes.",
            "This is so exciting! The new design is much cleaner.",
            "Let me introduce ProjectAlpha, our new initiative.",
            "The performance numbers are incredible after the refactor.",
            "I should mention that I prefer functional patterns over OOP.",
        ]

        for message in messages {
            let request = makeRequest(message)
            _ = try await runTurnCollecting(gateway.coordinator, request)
        }

        // Run full consolidation
        await gateway.consolidationEngine.consolidate(trigger: .manual)

        // Verify memory is still accessible after consolidation
        let tail = await gateway.memoryStore.freshTail(count: 20, for: 1)
        #expect(!tail.isEmpty, "Memory should still be accessible after consolidation")
    }

    // MARK: - Hebbian Decay

    @Test
    func `Hebbian decay does not crash on fresh database`() async throws {
        let gateway = try await makeGateway()
        await gateway.identityStore.decayClaims()
        // No crash = success
    }

    @Test
    func `Hotness decay runs without errors`() async throws {
        let gateway = try await makeGateway()

        // Ingest some data first
        let request = makeRequest("Test content for hotness decay")
        _ = try await runTurnCollecting(gateway.coordinator, request)

        await gateway.memoryStore.decayHotness()
        // No crash = success
    }
}
