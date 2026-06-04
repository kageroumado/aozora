import Foundation
import GRDB

/// Queries the CIMS database for usage statistics, conversation breakdowns, and DAG health metrics.
///
/// ``InsightsEngine`` is a read-only diagnostic component that aggregates data across the entire
/// CIMS database to provide operational visibility into the system's state. It uses SQL aggregations
/// for efficiency — no full table scans or in-memory post-processing.
///
/// All methods are read-only (`dbPool.read`) and safe to call concurrently with writes.
/// The engine holds no mutable state.
public nonisolated struct InsightsEngine: Sendable {
    /// The CIMS database to query.
    public let db: CIMSDatabase

    // MARK: - Usage Insights

    /// Aggregate usage statistics across the entire CIMS database.
    ///
    /// Computes counts, token estimates, and date ranges from the conversations, messages,
    /// DAG nodes, identity/mirror claims, and consolidation jobs tables.
    public struct UsageInsights: Sendable {
        /// Total number of cognitive turns (raw_turn DAG nodes).
        public let totalTurns: Int

        /// Total number of persisted messages across all conversations.
        public let totalMessages: Int

        /// Sum of all message token estimates.
        public let totalTokensEstimated: Int

        /// Average token estimate per raw turn (0 if no turns).
        public let averageTokensPerTurn: Int

        /// Number of distinct conversations.
        public let totalConversations: Int

        /// Total number of DAG nodes at all depths.
        public let dagNodeCount: Int

        /// Number of summary nodes (depth > 0).
        public let summaryNodeCount: Int

        /// Number of nodes demoted to cold storage.
        public let coldNodeCount: Int

        /// Number of active identity claims in the current version.
        public let identityClaimCount: Int

        /// Number of active mirror claims across all users.
        public let mirrorClaimCount: Int

        /// Total number of consolidation job records.
        public let consolidationJobCount: Int

        /// Timestamp of the earliest message, or `nil` if no messages exist.
        public let oldestMessageDate: Date?

        /// Timestamp of the newest message, or `nil` if no messages exist.
        public let newestMessageDate: Date?
    }

    /// Compute aggregate usage insights from the database.
    ///
    /// Executes multiple SQL aggregations in a single read transaction for consistency.
    ///
    /// - Returns: A ``UsageInsights`` snapshot of the current database state.
    /// - Throws: Database errors if the read transaction fails.
    public func computeInsights() async throws -> UsageInsights {
        try await db.dbPool.read { db in
            let totalConversations = try Int.fetchOne(
                db, sql: "SELECT COUNT(*) FROM conversations",
            ) ?? 0

            let totalMessages = try Int.fetchOne(
                db, sql: "SELECT COUNT(*) FROM messages",
            ) ?? 0

            let totalTokensEstimated = try Int.fetchOne(
                db, sql: "SELECT COALESCE(SUM(tokenEstimate), 0) FROM messages",
            ) ?? 0

            let dagNodeCount = try Int.fetchOne(
                db, sql: "SELECT COUNT(*) FROM lcm_nodes",
            ) ?? 0

            let totalTurns = try Int.fetchOne(
                db, sql: "SELECT COUNT(*) FROM lcm_nodes WHERE kind = ?",
                arguments: [NodeKind.rawTurn.rawValue],
            ) ?? 0

            let summaryNodeCount = try Int.fetchOne(
                db, sql: "SELECT COUNT(*) FROM lcm_nodes WHERE depth > 0",
            ) ?? 0

            let coldNodeCount = try Int.fetchOne(
                db, sql: "SELECT COUNT(*) FROM lcm_nodes WHERE isCold = 1",
            ) ?? 0

            let averageTokensPerTurn: Int
            if totalTurns > 0 {
                let totalTurnTokens = try Int.fetchOne(
                    db,
                    sql: "SELECT COALESCE(SUM(tokenCount), 0) FROM lcm_nodes WHERE kind = ?",
                    arguments: [NodeKind.rawTurn.rawValue],
                ) ?? 0
                averageTokensPerTurn = totalTurnTokens / totalTurns
            } else {
                averageTokensPerTurn = 0
            }

            let identityClaimCount = try Int.fetchOne(
                db,
                sql: """
                SELECT COUNT(*) FROM identity_claims ic
                JOIN identity_versions iv ON ic.versionId = iv.versionId
                WHERE iv.isActive = 1
                """,
            ) ?? 0

            let mirrorClaimCount = try Int.fetchOne(
                db,
                sql: """
                SELECT COUNT(*) FROM mirror_claims mc
                JOIN mirror_versions mv ON mc.versionId = mv.versionId
                WHERE mv.isActive = 1
                """,
            ) ?? 0

            let consolidationJobCount = try Int.fetchOne(
                db, sql: "SELECT COUNT(*) FROM consolidation_jobs",
            ) ?? 0

            let oldestDateString = try String.fetchOne(
                db, sql: "SELECT MIN(createdAt) FROM messages",
            )
            let newestDateString = try String.fetchOne(
                db, sql: "SELECT MAX(createdAt) FROM messages",
            )

            let formatter = ISO8601DateFormatter()
            formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]

            let oldestMessageDate = oldestDateString.flatMap { formatter.date(from: $0) }
            let newestMessageDate = newestDateString.flatMap { formatter.date(from: $0) }

            return UsageInsights(
                totalTurns: totalTurns,
                totalMessages: totalMessages,
                totalTokensEstimated: totalTokensEstimated,
                averageTokensPerTurn: averageTokensPerTurn,
                totalConversations: totalConversations,
                dagNodeCount: dagNodeCount,
                summaryNodeCount: summaryNodeCount,
                coldNodeCount: coldNodeCount,
                identityClaimCount: identityClaimCount,
                mirrorClaimCount: mirrorClaimCount,
                consolidationJobCount: consolidationJobCount,
                oldestMessageDate: oldestMessageDate,
                newestMessageDate: newestMessageDate,
            )
        }
    }

    // MARK: - Conversation Breakdown

    /// Per-conversation usage statistics.
    public struct ConversationStats: Sendable {
        /// Database row ID of the conversation.
        public let conversationId: Int64

        /// Session key identifying this conversation.
        public let sessionKey: String

        /// Number of messages in this conversation.
        public let messageCount: Int

        /// Sum of token estimates for all messages in this conversation.
        public let totalTokens: Int

        /// When this conversation started (parsed from ISO 8601).
        public let startedAt: Date

        /// When the last message was sent, or `nil` if no messages.
        public let lastMessageAt: Date?
    }

    /// Compute per-conversation usage statistics.
    ///
    /// Returns one ``ConversationStats`` entry per conversation, ordered by start time descending
    /// (most recent first). Token counts are aggregated from the messages table.
    ///
    /// - Returns: An array of per-conversation statistics.
    /// - Throws: Database errors if the read transaction fails.
    public func conversationBreakdown() async throws -> [ConversationStats] {
        try await db.dbPool.read { db in
            let rows = try Row.fetchAll(db, sql: """
            SELECT
                c.id AS conversationId,
                c.sessionKey,
                c.messageCount,
                COALESCE(SUM(m.tokenEstimate), 0) AS totalTokens,
                c.startedAt,
                c.lastMessageAt
            FROM conversations c
            LEFT JOIN messages m ON m.conversationId = c.id
            GROUP BY c.id
            ORDER BY c.startedAt DESC
            """)

            let formatter = ISO8601DateFormatter()
            formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]

            return rows.compactMap { row -> ConversationStats? in
                guard let conversationId = row["conversationId"] as Int64?,
                      let sessionKey = row["sessionKey"] as String?,
                      let messageCount = row["messageCount"] as Int?,
                      let totalTokens = row["totalTokens"] as Int?,
                      let startedAtString = row["startedAt"] as String?,
                      let startedAt = formatter.date(from: startedAtString)
                else { return nil }

                let lastMessageAtString = row["lastMessageAt"] as String?
                let lastMessageAt = lastMessageAtString.flatMap { formatter.date(from: $0) }

                return ConversationStats(
                    conversationId: conversationId,
                    sessionKey: sessionKey,
                    messageCount: messageCount,
                    totalTokens: totalTokens,
                    startedAt: startedAt,
                    lastMessageAt: lastMessageAt,
                )
            }
        }
    }

    // MARK: - DAG Health

    /// Health metrics for the LCM DAG (Directed Acyclic Graph).
    public struct DAGHealth: Sendable {
        /// Total number of DAG nodes across all depths and conversations.
        public let totalNodes: Int

        /// Distribution of nodes by depth level (depth -> count).
        public let nodesByDepth: [Int: Int]

        /// Distribution of nodes by kind (kind rawValue -> count).
        public let nodesByKind: [String: Int]

        /// Mean hotness value across all nodes.
        public let averageHotness: Float

        /// Percentage of nodes in cold storage (0.0-100.0).
        public let coldNodePercentage: Float

        /// Number of nodes currently in the frontier (across all conversations).
        public let frontierSize: Int
    }

    /// Compute health metrics for the LCM DAG.
    ///
    /// Provides depth distribution, kind distribution, hotness statistics, cold storage
    /// percentage, and frontier size. All computed via SQL aggregations.
    ///
    /// - Returns: A ``DAGHealth`` snapshot of the current DAG state.
    /// - Throws: Database errors if the read transaction fails.
    public func dagHealth() async throws -> DAGHealth {
        try await db.dbPool.read { db in
            let totalNodes = try Int.fetchOne(
                db, sql: "SELECT COUNT(*) FROM lcm_nodes",
            ) ?? 0

            let depthRows = try Row.fetchAll(
                db, sql: "SELECT depth, COUNT(*) AS cnt FROM lcm_nodes GROUP BY depth",
            )
            var nodesByDepth: [Int: Int] = [:]
            for row in depthRows {
                if let depth = row["depth"] as Int?,
                   let count = row["cnt"] as Int? {
                    nodesByDepth[depth] = count
                }
            }

            let kindRows = try Row.fetchAll(
                db, sql: "SELECT kind, COUNT(*) AS cnt FROM lcm_nodes GROUP BY kind",
            )
            var nodesByKind: [String: Int] = [:]
            for row in kindRows {
                if let kind = row["kind"] as String?,
                   let count = row["cnt"] as Int? {
                    nodesByKind[kind] = count
                }
            }

            let averageHotness: Float
            if totalNodes > 0 {
                let avgDouble = try Double.fetchOne(
                    db, sql: "SELECT AVG(hotness) FROM lcm_nodes",
                ) ?? 0.0
                averageHotness = Float(avgDouble)
            } else {
                averageHotness = 0.0
            }

            let coldCount = try Int.fetchOne(
                db, sql: "SELECT COUNT(*) FROM lcm_nodes WHERE isCold = 1",
            ) ?? 0
            let coldNodePercentage: Float = totalNodes > 0
                ? Float(coldCount) / Float(totalNodes) * 100.0
                : 0.0

            let frontierSize = try Int.fetchOne(
                db, sql: "SELECT COUNT(*) FROM lcm_frontier",
            ) ?? 0

            return DAGHealth(
                totalNodes: totalNodes,
                nodesByDepth: nodesByDepth,
                nodesByKind: nodesByKind,
                averageHotness: averageHotness,
                coldNodePercentage: coldNodePercentage,
                frontierSize: frontierSize,
            )
        }
    }
}
