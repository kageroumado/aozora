import Foundation
import GRDB
import Testing
@testable import Aozora

struct ColdStorageTests {
    private static let secondsPerDay: TimeInterval = 86_400

    /// A date guaranteed to be past the cold storage age threshold.
    private var expiredDate: Date {
        Date().addingTimeInterval(-Double(CIMSDefaults.coldStorageAgeDays + 1) * Self.secondsPerDay)
    }

    /// Create a fresh in-memory database and cold storage manager for each test.
    private func makeColdStorage() throws -> (ColdStorage, CIMSDatabase) {
        let db = try CIMSDatabase.inMemory()
        let cold = ColdStorage(database: db)
        return (cold, db)
    }

    /// Helper to insert a raw_turn node with specified hotness and last accessed date.
    private func insertNode(
        db: CIMSDatabase,
        nodeId: String,
        hotness: Double,
        lastAccessedAt: Date,
        canonicalText: String = "Some content for this node",
    ) async throws {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let now = f.string(from: Date())
        let lastAccess = f.string(from: lastAccessedAt)

        try await db.dbPool.write { dbConn in
            var conversation = ConversationRecord(
                sessionKey: "session-\(nodeId)",
                userKey: "user1",
                startedAt: now,
                lastMessageAt: now,
                messageCount: 0,
            )
            if try ConversationRecord.fetchOne(dbConn, key: 1) == nil {
                try conversation.insert(dbConn)
            }

            let conversationId = try ConversationRecord.fetchOne(dbConn)!.id!

            let node = LCMNodeRecord(
                nodeId: nodeId,
                conversationId: conversationId,
                depth: 0,
                kind: NodeKind.rawTurn.rawValue,
                tokenCount: canonicalText.utf8.count / 4,
                checksum: nil,
                salienceScore: 0.5,
                hotness: hotness,
                isCold: 0,
                canonicalText: canonicalText,
                summaryText: nil,
                expandFooter: nil,
                earliestAt: now,
                latestAt: now,
                lastAccessedAt: lastAccess,
                version: 1,
                createdAt: now,
            )
            try node.insert(dbConn)
        }
    }

    // MARK: - Compression Roundtrip

    @Test
    func `Compression and decompression produce identical bytes`() {
        let original = "This is a test string that should survive compression roundtrip intact. " +
            "Adding more content to make compression worthwhile: Lorem ipsum dolor sit amet, " +
            "consectetur adipiscing elit, sed do eiusmod tempor incididunt ut labore et dolore magna aliqua."
        let data = Data(original.utf8)

        let compressed = ColdStorage.compress(data)
        let decompressed = ColdStorage.decompress(compressed, originalSize: data.count)

        #expect(decompressed == data, "Decompressed data must match original exactly")

        let restored = String(data: decompressed, encoding: .utf8)
        #expect(restored == original)
    }

    @Test
    func `Empty data survives compression roundtrip`() {
        let data = Data()
        let compressed = ColdStorage.compress(data)
        let decompressed = ColdStorage.decompress(compressed, originalSize: 0)
        #expect(decompressed == data)
    }

    // MARK: - Demotion

    @Test
    func `Demote eligible nodes compresses and nulls canonical text`() async throws {
        let (cold, db) = try makeColdStorage()
        let oldDate = expiredDate

        try await insertNode(
            db: db,
            nodeId: "node_cold1",
            hotness: 0.05,
            lastAccessedAt: oldDate,
            canonicalText: "This node should be demoted to cold storage",
        )

        let demoted = try await cold.demoteEligibleNodes()
        #expect(demoted == 1)

        let node = try await db.dbPool.read { dbConn in
            try LCMNodeRecord.fetchOne(dbConn, key: "node_cold1")
        }
        #expect(node?.isCold == 1)
        #expect(node?.canonicalText == nil)

        let payload = try await db.dbPool.read { dbConn in
            try ColdPayloadRecord.fetchOne(dbConn, key: "node_cold1")
        }
        #expect(payload != nil)
        #expect(try #require(payload?.originalBytes) > 0)
    }

    @Test
    func `Demotion skips nodes with high hotness`() async throws {
        let (cold, db) = try makeColdStorage()
        let oldDate = expiredDate

        try await insertNode(
            db: db,
            nodeId: "node_hot1",
            hotness: 0.5,
            lastAccessedAt: oldDate,
        )

        let demoted = try await cold.demoteEligibleNodes()
        #expect(demoted == 0)
    }

    @Test
    func `Demotion skips recently accessed nodes`() async throws {
        let (cold, db) = try makeColdStorage()

        try await insertNode(
            db: db,
            nodeId: "node_recent1",
            hotness: 0.05,
            lastAccessedAt: Date(),
        )

        let demoted = try await cold.demoteEligibleNodes()
        #expect(demoted == 0)
    }

    @Test
    func `Demotion skips already cold nodes`() async throws {
        let (cold, db) = try makeColdStorage()
        let oldDate = expiredDate

        try await insertNode(
            db: db,
            nodeId: "node_alreadycold",
            hotness: 0.05,
            lastAccessedAt: oldDate,
        )

        let first = try await cold.demoteEligibleNodes()
        #expect(first == 1)

        let second = try await cold.demoteEligibleNodes()
        #expect(second == 0)
    }

    // MARK: - Promotion

    @Test
    func `Promotion restores exact original text from compressed payload`() async throws {
        let (cold, db) = try makeColdStorage()
        let oldDate = expiredDate
        let originalText = "This specific text must survive the demotion-promotion roundtrip exactly."

        try await insertNode(
            db: db,
            nodeId: "node_roundtrip",
            hotness: 0.05,
            lastAccessedAt: oldDate,
            canonicalText: originalText,
        )

        try await cold.demoteEligibleNodes()

        let demotedNode = try await db.dbPool.read { dbConn in
            try LCMNodeRecord.fetchOne(dbConn, key: "node_roundtrip")
        }
        #expect(demotedNode?.canonicalText == nil)
        #expect(demotedNode?.isCold == 1)

        try await cold.promote(nodeId: "node_roundtrip")

        let promotedNode = try await db.dbPool.read { dbConn in
            try LCMNodeRecord.fetchOne(dbConn, key: "node_roundtrip")
        }
        #expect(promotedNode?.canonicalText == originalText)
        #expect(promotedNode?.isCold == 0)
        #expect(try #require(promotedNode?.hotness) >= 0.2)

        let payload = try await db.dbPool.read { dbConn in
            try ColdPayloadRecord.fetchOne(dbConn, key: "node_roundtrip")
        }
        #expect(payload == nil, "Cold payload should be deleted after promotion")
    }

    @Test
    func `Promoting a non-existent node throws coldStorageError`() async throws {
        let (cold, _) = try makeColdStorage()

        do {
            try await cold.promote(nodeId: "node_nonexistent")
            Issue.record("Expected promote to throw for missing payload")
        } catch let error as CIMSError {
            if case let .coldStorageError(nodeId, _) = error {
                #expect(nodeId == "node_nonexistent")
            } else {
                Issue.record("Expected coldStorageError, got \(error)")
            }
        }
    }

    // MARK: - Conjunction Verification (Plan 0.2.1)

    /// Verifies that a node meeting BOTH demotion conditions is demoted:
    /// `hotness < 0.1` (spec: 0.05) AND `lastAccessedAt > 30 days` (spec: 45 days ago).
    @Test
    func `Conjunction: low hotness AND old access → demoted (hotness=0.05, 45d old)`() async throws {
        let (cold, db) = try makeColdStorage()
        let fortyFiveDaysAgo = Date().addingTimeInterval(-45 * Self.secondsPerDay)

        try await insertNode(
            db: db,
            nodeId: "node_conj_both",
            hotness: 0.05,
            lastAccessedAt: fortyFiveDaysAgo,
            canonicalText: "Both conditions met — should be demoted",
        )

        let demoted = try await cold.demoteEligibleNodes()
        #expect(demoted == 1)

        let node = try await db.dbPool.read { dbConn in
            try LCMNodeRecord.fetchOne(dbConn, key: "node_conj_both")
        }
        #expect(node?.isCold == 1)
        #expect(node?.canonicalText == nil)
    }

    /// Verifies that low hotness alone is NOT sufficient for demotion when the node
    /// was recently accessed (`lastAccessedAt` 5 days ago, well within the 30-day window).
    @Test
    func `Conjunction: low hotness but recent access → NOT demoted (hotness=0.05, 5d old)`() async throws {
        let (cold, db) = try makeColdStorage()
        let fiveDaysAgo = Date().addingTimeInterval(-5 * Self.secondsPerDay)

        try await insertNode(
            db: db,
            nodeId: "node_conj_recent",
            hotness: 0.05,
            lastAccessedAt: fiveDaysAgo,
            canonicalText: "Low hotness but recent access — should NOT be demoted",
        )

        let demoted = try await cold.demoteEligibleNodes()
        #expect(demoted == 0)

        let node = try await db.dbPool.read { dbConn in
            try LCMNodeRecord.fetchOne(dbConn, key: "node_conj_recent")
        }
        #expect(node?.isCold == 0)
        #expect(node?.canonicalText != nil)
    }

    /// Verifies that old access time alone is NOT sufficient for demotion when the node
    /// has high hotness (0.5, well above the 0.1 threshold).
    @Test
    func `Conjunction: high hotness but old access → NOT demoted (hotness=0.5, 45d old)`() async throws {
        let (cold, db) = try makeColdStorage()
        let fortyFiveDaysAgo = Date().addingTimeInterval(-45 * Self.secondsPerDay)

        try await insertNode(
            db: db,
            nodeId: "node_conj_hot",
            hotness: 0.5,
            lastAccessedAt: fortyFiveDaysAgo,
            canonicalText: "High hotness but old access — should NOT be demoted",
        )

        let demoted = try await cold.demoteEligibleNodes()
        #expect(demoted == 0)

        let node = try await db.dbPool.read { dbConn in
            try LCMNodeRecord.fetchOne(dbConn, key: "node_conj_hot")
        }
        #expect(node?.isCold == 0)
        #expect(node?.canonicalText != nil)
    }

    // MARK: - Demotion is Idempotent

    @Test
    func `Running demotion twice on the same eligible set demotes only once`() async throws {
        let (cold, db) = try makeColdStorage()
        let oldDate = expiredDate

        try await insertNode(db: db, nodeId: "node_idem1", hotness: 0.01, lastAccessedAt: oldDate)

        let first = try await cold.demoteEligibleNodes()
        let second = try await cold.demoteEligibleNodes()

        #expect(first == 1)
        #expect(second == 0)
    }
}
