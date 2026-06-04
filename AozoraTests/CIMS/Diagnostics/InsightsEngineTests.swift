import Foundation
import GRDB
import Testing
@testable import Aozora

@Suite("InsightsEngine")
struct InsightsEngineTests {
    /// Create a fresh in-memory database and insights engine for each test.
    private func makeEngine() throws -> (InsightsEngine, CIMSDatabase) {
        let db = try CIMSDatabase.inMemory()
        let engine = InsightsEngine(db: db)
        return (engine, db)
    }

    /// Format a date as ISO 8601 with fractional seconds, matching CIMS store format.
    private func iso8601(_ date: Date) -> String {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f.string(from: date)
    }

    /// Insert a conversation record and return its assigned ID.
    private func insertConversation(
        db: CIMSDatabase,
        sessionKey: String = "session-1",
        userKey: String = "user-1",
        messageCount: Int = 0,
    ) throws -> Int64 {
        let now = iso8601(Date())
        var record = ConversationRecord(
            id: nil,
            sessionKey: sessionKey,
            userKey: userKey,
            startedAt: now,
            lastMessageAt: now,
            messageCount: messageCount,
        )
        try db.dbPool.write { dbConn in
            try record.insert(dbConn)
        }
        return record.id!
    }

    /// Insert a message record and return its assigned ID.
    @discardableResult
    private func insertMessage(
        db: CIMSDatabase,
        conversationId: Int64,
        role: String = "user",
        content: String = "test message",
        tokenEstimate: Int = 100,
        createdAt: Date = Date(),
    ) throws -> Int64 {
        let dateString = iso8601(createdAt)
        var record = MessageRecord(
            id: nil,
            conversationId: conversationId,
            role: role,
            content: content,
            tokenEstimate: tokenEstimate,
            salienceScore: nil,
            createdAt: dateString,
        )
        try db.dbPool.write { dbConn in
            try record.insert(dbConn)
        }
        return record.id!
    }

    /// Insert a DAG node record.
    @discardableResult
    private func insertNode(
        db: CIMSDatabase,
        conversationId: Int64,
        nodeId: String,
        depth: Int = 0,
        kind: NodeKind = .rawTurn,
        tokenCount: Int = 200,
        hotness: Double = 1.0,
        isCold: Int = 0,
    ) throws -> String {
        let now = iso8601(Date())
        let record = LCMNodeRecord(
            nodeId: nodeId,
            conversationId: conversationId,
            depth: depth,
            kind: kind.rawValue,
            tokenCount: tokenCount,
            checksum: nil,
            salienceScore: 0.5,
            hotness: hotness,
            isCold: isCold,
            canonicalText: "test content for \(nodeId)",
            summaryText: depth > 0 ? "summary for \(nodeId)" : nil,
            expandFooter: nil,
            earliestAt: now,
            latestAt: now,
            lastAccessedAt: now,
            version: 1,
            createdAt: now,
        )
        try db.dbPool.write { dbConn in
            try record.insert(dbConn)
        }
        return nodeId
    }

    /// Insert a consolidation job record.
    private func insertConsolidationJob(
        db: CIMSDatabase,
        jobId: String = "job-1",
        trigger: String = "manual",
        status: String = "completed",
    ) throws {
        let now = iso8601(Date())
        let job = ConsolidationJobRecord(
            jobId: jobId,
            trigger: trigger,
            status: status,
            startedAt: now,
            completedAt: now,
            bumpsDetected: 0,
            claimsExtracted: 0,
            nodesCompacted: 0,
            nodesDecayed: 0,
            error: nil,
            createdAt: now,
        )
        try db.dbPool.write { dbConn in
            try job.insert(dbConn)
        }
    }

    /// Insert a frontier entry.
    private func insertFrontierEntry(
        db: CIMSDatabase,
        conversationId: Int64,
        nodeId: String,
        ordinal: Int,
    ) throws {
        let record = LCMFrontierRecord(
            conversationId: conversationId,
            nodeId: nodeId,
            ordinal: ordinal,
        )
        try db.dbPool.write { dbConn in
            try record.insert(dbConn)
        }
    }

    // MARK: - Empty Database

    @Test("Empty database returns zero counts")
    func emptyDatabaseInsights() async throws {
        let (engine, _) = try makeEngine()
        let insights = try await engine.computeInsights()

        #expect(insights.totalTurns == 0)
        #expect(insights.totalMessages == 0)
        #expect(insights.totalTokensEstimated == 0)
        #expect(insights.averageTokensPerTurn == 0)
        #expect(insights.totalConversations == 0)
        #expect(insights.dagNodeCount == 0)
        #expect(insights.summaryNodeCount == 0)
        #expect(insights.coldNodeCount == 0)
        #expect(insights.identityClaimCount == 0)
        #expect(insights.mirrorClaimCount == 0)
        #expect(insights.consolidationJobCount == 0)
        #expect(insights.oldestMessageDate == nil)
        #expect(insights.newestMessageDate == nil)
    }

    @Test("Empty database returns empty conversation breakdown")
    func emptyConversationBreakdown() async throws {
        let (engine, _) = try makeEngine()
        let breakdown = try await engine.conversationBreakdown()
        #expect(breakdown.isEmpty)
    }

    @Test("Empty database returns zero DAG health")
    func emptyDAGHealth() async throws {
        let (engine, _) = try makeEngine()
        let health = try await engine.dagHealth()

        #expect(health.totalNodes == 0)
        #expect(health.nodesByDepth.isEmpty)
        #expect(health.nodesByKind.isEmpty)
        #expect(health.averageHotness == 0.0)
        #expect(health.coldNodePercentage == 0.0)
        #expect(health.frontierSize == 0)
    }

    // MARK: - Usage Insights With Data

    @Test("Insights reflect ingested messages")
    func insightsWithMessages() async throws {
        let (engine, db) = try makeEngine()

        let convId = try insertConversation(db: db, messageCount: 3)
        try insertMessage(db: db, conversationId: convId, role: "user", tokenEstimate: 50)
        try insertMessage(db: db, conversationId: convId, role: "assistant", tokenEstimate: 150)
        try insertMessage(db: db, conversationId: convId, role: "user", tokenEstimate: 75)

        let insights = try await engine.computeInsights()

        #expect(insights.totalConversations == 1)
        #expect(insights.totalMessages == 3)
        #expect(insights.totalTokensEstimated == 275)
    }

    @Test("Insights count DAG nodes correctly")
    func insightsDagNodes() async throws {
        let (engine, db) = try makeEngine()

        let convId = try insertConversation(db: db)
        try insertNode(
            db: db, conversationId: convId, nodeId: "node_raw_1",
            depth: 0, kind: .rawTurn, tokenCount: 100,
        )
        try insertNode(
            db: db, conversationId: convId, nodeId: "node_raw_2",
            depth: 0, kind: .rawTurn, tokenCount: 200,
        )
        try insertNode(
            db: db, conversationId: convId, nodeId: "node_leaf_1",
            depth: 1, kind: .leafSummary, tokenCount: 300,
        )

        let insights = try await engine.computeInsights()

        #expect(insights.dagNodeCount == 3)
        #expect(insights.totalTurns == 2)
        #expect(insights.summaryNodeCount == 1)
        #expect(insights.averageTokensPerTurn == 150)
    }

    @Test("Insights count cold nodes")
    func insightsColdNodes() async throws {
        let (engine, db) = try makeEngine()

        let convId = try insertConversation(db: db)
        try insertNode(db: db, conversationId: convId, nodeId: "node_hot", isCold: 0)
        try insertNode(db: db, conversationId: convId, nodeId: "node_cold_1", isCold: 1)
        try insertNode(db: db, conversationId: convId, nodeId: "node_cold_2", isCold: 1)

        let insights = try await engine.computeInsights()

        #expect(insights.coldNodeCount == 2)
    }

    @Test("Insights count consolidation jobs")
    func insightsConsolidationJobs() async throws {
        let (engine, db) = try makeEngine()

        try insertConsolidationJob(db: db)

        let insights = try await engine.computeInsights()
        #expect(insights.consolidationJobCount == 1)
    }

    @Test("Message dates are parsed correctly")
    func insightsMessageDates() async throws {
        let (engine, db) = try makeEngine()

        let convId = try insertConversation(db: db, messageCount: 2)

        let oldDate = Date(timeIntervalSince1970: 1_700_000_000)
        let newDate = Date(timeIntervalSince1970: 1_700_100_000)

        try insertMessage(
            db: db, conversationId: convId, content: "old",
            tokenEstimate: 10, createdAt: oldDate,
        )
        try insertMessage(
            db: db, conversationId: convId, content: "new",
            tokenEstimate: 10, createdAt: newDate,
        )

        let insights = try await engine.computeInsights()

        #expect(insights.oldestMessageDate != nil)
        #expect(insights.newestMessageDate != nil)
        #expect(try #require(insights.oldestMessageDate) < insights.newestMessageDate!)
    }

    // MARK: - Conversation Breakdown

    @Test("Conversation breakdown returns correct per-conversation stats")
    func conversationBreakdownStats() async throws {
        let (engine, db) = try makeEngine()

        let conv1 = try insertConversation(db: db, sessionKey: "session-1", messageCount: 2)
        try insertMessage(db: db, conversationId: conv1, tokenEstimate: 100)
        try insertMessage(db: db, conversationId: conv1, tokenEstimate: 200)

        let conv2 = try insertConversation(db: db, sessionKey: "session-2", messageCount: 1)
        try insertMessage(db: db, conversationId: conv2, tokenEstimate: 50)

        let breakdown = try await engine.conversationBreakdown()

        #expect(breakdown.count == 2)

        let stats1 = breakdown.first { $0.sessionKey == "session-1" }
        let stats2 = breakdown.first { $0.sessionKey == "session-2" }

        #expect(stats1 != nil)
        #expect(stats1?.messageCount == 2)
        #expect(stats1?.totalTokens == 300)

        #expect(stats2 != nil)
        #expect(stats2?.messageCount == 1)
        #expect(stats2?.totalTokens == 50)
    }

    @Test("Conversation breakdown has valid dates")
    func conversationBreakdownDates() async throws {
        let (engine, db) = try makeEngine()

        _ = try insertConversation(db: db, sessionKey: "session-dates")

        let breakdown = try await engine.conversationBreakdown()

        #expect(breakdown.count == 1)
        #expect(breakdown[0].startedAt.timeIntervalSince1970 > 0)
    }

    // MARK: - DAG Health

    @Test("DAG health shows correct depth distribution")
    func dagHealthDepthDistribution() async throws {
        let (engine, db) = try makeEngine()

        let convId = try insertConversation(db: db)
        try insertNode(db: db, conversationId: convId, nodeId: "n0a", depth: 0, kind: .rawTurn)
        try insertNode(db: db, conversationId: convId, nodeId: "n0b", depth: 0, kind: .rawTurn)
        try insertNode(db: db, conversationId: convId, nodeId: "n0c", depth: 0, kind: .rawTurn)
        try insertNode(db: db, conversationId: convId, nodeId: "n1a", depth: 1, kind: .leafSummary)
        try insertNode(db: db, conversationId: convId, nodeId: "n2a", depth: 2, kind: .condensed)

        let health = try await engine.dagHealth()

        #expect(health.totalNodes == 5)
        #expect(health.nodesByDepth[0] == 3)
        #expect(health.nodesByDepth[1] == 1)
        #expect(health.nodesByDepth[2] == 1)
    }

    @Test("DAG health shows correct kind distribution")
    func dagHealthKindDistribution() async throws {
        let (engine, db) = try makeEngine()

        let convId = try insertConversation(db: db)
        try insertNode(db: db, conversationId: convId, nodeId: "nr1", depth: 0, kind: .rawTurn)
        try insertNode(db: db, conversationId: convId, nodeId: "nr2", depth: 0, kind: .rawTurn)
        try insertNode(db: db, conversationId: convId, nodeId: "nl1", depth: 1, kind: .leafSummary)
        try insertNode(db: db, conversationId: convId, nodeId: "nc1", depth: 2, kind: .condensed)

        let health = try await engine.dagHealth()

        #expect(health.nodesByKind[NodeKind.rawTurn.rawValue] == 2)
        #expect(health.nodesByKind[NodeKind.leafSummary.rawValue] == 1)
        #expect(health.nodesByKind[NodeKind.condensed.rawValue] == 1)
    }

    @Test("DAG health computes average hotness")
    func dagHealthAverageHotness() async throws {
        let (engine, db) = try makeEngine()

        let convId = try insertConversation(db: db)
        try insertNode(db: db, conversationId: convId, nodeId: "nh1", hotness: 1.0)
        try insertNode(db: db, conversationId: convId, nodeId: "nh2", hotness: 0.5)
        try insertNode(db: db, conversationId: convId, nodeId: "nh3", hotness: 0.0)

        let health = try await engine.dagHealth()

        #expect(abs(health.averageHotness - 0.5) < 0.01)
    }

    @Test("DAG health computes cold node percentage")
    func dagHealthColdPercentage() async throws {
        let (engine, db) = try makeEngine()

        let convId = try insertConversation(db: db)
        try insertNode(db: db, conversationId: convId, nodeId: "ncp1", isCold: 0)
        try insertNode(db: db, conversationId: convId, nodeId: "ncp2", isCold: 1)
        try insertNode(db: db, conversationId: convId, nodeId: "ncp3", isCold: 0)
        try insertNode(db: db, conversationId: convId, nodeId: "ncp4", isCold: 1)

        let health = try await engine.dagHealth()

        #expect(abs(health.coldNodePercentage - 50.0) < 0.01)
    }

    @Test("DAG health counts frontier size")
    func dagHealthFrontierSize() async throws {
        let (engine, db) = try makeEngine()

        let convId = try insertConversation(db: db)
        let nid1 = try insertNode(db: db, conversationId: convId, nodeId: "nf1")
        let nid2 = try insertNode(db: db, conversationId: convId, nodeId: "nf2")
        let nid3 = try insertNode(db: db, conversationId: convId, nodeId: "nf3")

        try insertFrontierEntry(db: db, conversationId: convId, nodeId: nid1, ordinal: 0)
        try insertFrontierEntry(db: db, conversationId: convId, nodeId: nid2, ordinal: 1)
        try insertFrontierEntry(db: db, conversationId: convId, nodeId: nid3, ordinal: 2)

        let health = try await engine.dagHealth()

        #expect(health.frontierSize == 3)
    }
}
