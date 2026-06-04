import CryptoKit
import Foundation
import GRDB

/// Manages selective context pruning for the coordinator.
///
/// When context grows large, the pruner identifies low-salience message groups
/// (tool calls, utility tasks, config changes) and compacts them into summary
/// nodes that can be expanded on demand via the `expand_memory` tool.
///
/// The pruner operates as a suggestion system — the model decides when to compact.
/// It queries the DAG for statistics and creates summary nodes using the same
/// storage format as ``DAGCompactor``, so expansion works identically.
public actor ContextPruner {
    /// The shared database for querying DAG state and writing summary nodes.
    private let db: CIMSDatabase

    /// Token budget — when context exceeds this, pruning is recommended.
    public let tokenBudget: Int

    /// Minimum tokens a group must have to be worth compacting.
    public let minCompactableTokens: Int

    /// Creates a context pruner backed by the given database.
    ///
    /// - Parameters:
    ///   - database: The CIMS database instance for DAG queries and writes.
    ///   - tokenBudget: Threshold above which pruning is recommended (default: 150,000).
    ///   - minCompactableTokens: Minimum tokens for a group to be worth compacting (default: 2,000).
    public init(
        database: CIMSDatabase,
        tokenBudget: Int = 150_000,
        minCompactableTokens: Int = 2_000,
    ) {
        self.db = database
        self.tokenBudget = tokenBudget
        self.minCompactableTokens = minCompactableTokens
    }

    // MARK: - Content Categorization

    /// Categories of content that are candidates for compaction.
    ///
    /// Lower semantic value categories (tool execution, config changes, research)
    /// are compacted first, while conversation content is preserved longest.
    public enum ContentCategory: String, Sendable, CaseIterable {
        /// Bash output, file reads, tool results.
        case toolExecution = "tool_execution"

        /// Gateway config, system admin operations.
        case configChange = "config_change"

        /// Web searches, fetches, documentation lookups.
        case research

        /// User messages and assistant responses.
        case conversation
    }

    // MARK: - Statistics

    /// Snapshot of context window usage for the model's decision-making.
    public struct ContextStatistics: Sendable {
        /// Total number of messages in the conversation.
        public let totalMessages: Int

        /// Message count broken down by role (user, assistant, tool, system).
        public let messagesByRole: [String: Int]

        /// Total DAG nodes in the conversation.
        public let totalNodes: Int

        /// Node count broken down by depth level.
        public let nodesByDepth: [Int: Int]

        /// Node count broken down by kind (raw_turn, leaf_summary, condensed).
        public let nodesByKind: [String: Int]

        /// Total estimated tokens across all non-cold nodes.
        public let totalEstimatedTokens: Int

        /// Number of nodes in the active frontier.
        public let frontierSize: Int

        /// Number of nodes demoted to cold storage.
        public let coldNodeCount: Int

        public init(totalMessages: Int, messagesByRole: [String: Int], totalNodes: Int, nodesByDepth: [Int: Int], nodesByKind: [String: Int], totalEstimatedTokens: Int, frontierSize: Int, coldNodeCount: Int) {
            self.totalMessages = totalMessages
            self.messagesByRole = messagesByRole
            self.totalNodes = totalNodes
            self.nodesByDepth = nodesByDepth
            self.nodesByKind = nodesByKind
            self.totalEstimatedTokens = totalEstimatedTokens
            self.frontierSize = frontierSize
            self.coldNodeCount = coldNodeCount
        }
    }

    /// Compute context statistics across all conversations.
    ///
    /// Queries messages and nodes globally (not scoped to a single conversation)
    /// so the totals reflect the full database. Frontier and cold counts are
    /// aggregated across all conversations as well.
    ///
    /// - Returns: A ``ContextStatistics`` snapshot, or `nil` if no conversations exist.
    public func statistics() async throws -> ContextStatistics? {
        try await db.dbPool.read { db in
            // Verify at least one conversation exists
            guard try ConversationRecord.fetchCount(db) > 0 else { return nil }

            // Global message counts across ALL conversations
            let totalMessages = try Int.fetchOne(
                db,
                sql: "SELECT COUNT(*) FROM messages",
            ) ?? 0

            let roleRows = try Row.fetchAll(
                db,
                sql: "SELECT role, COUNT(*) as cnt FROM messages GROUP BY role",
            )
            var messagesByRole: [String: Int] = [:]
            for row in roleRows {
                let role: String = row["role"]
                let count: Int = row["cnt"]
                messagesByRole[role] = count
            }

            // Global node counts across ALL conversations
            let totalNodes = try Int.fetchOne(
                db,
                sql: "SELECT COUNT(*) FROM lcm_nodes",
            ) ?? 0

            let depthRows = try Row.fetchAll(
                db,
                sql: "SELECT depth, COUNT(*) as cnt FROM lcm_nodes GROUP BY depth",
            )
            var nodesByDepth: [Int: Int] = [:]
            for row in depthRows {
                let depth: Int = row["depth"]
                let count: Int = row["cnt"]
                nodesByDepth[depth] = count
            }

            let kindRows = try Row.fetchAll(
                db,
                sql: "SELECT kind, COUNT(*) as cnt FROM lcm_nodes GROUP BY kind",
            )
            var nodesByKind: [String: Int] = [:]
            for row in kindRows {
                let kind: String = row["kind"]
                let count: Int = row["cnt"]
                nodesByKind[kind] = count
            }

            let totalTokens = try Int.fetchOne(
                db,
                sql: "SELECT COALESCE(SUM(tokenCount), 0) FROM lcm_nodes WHERE isCold = 0",
            ) ?? 0

            // Frontier and cold across all conversations
            let frontierSize = try Int.fetchOne(
                db,
                sql: "SELECT COUNT(*) FROM lcm_frontier",
            ) ?? 0

            let coldCount = try Int.fetchOne(
                db,
                sql: "SELECT COUNT(*) FROM lcm_nodes WHERE isCold = 1",
            ) ?? 0

            return ContextStatistics(
                totalMessages: totalMessages,
                messagesByRole: messagesByRole,
                totalNodes: totalNodes,
                nodesByDepth: nodesByDepth,
                nodesByKind: nodesByKind,
                totalEstimatedTokens: totalTokens,
                frontierSize: frontierSize,
                coldNodeCount: coldCount,
            )
        }
    }

    // MARK: - Compaction

    /// Result of compacting a range of messages into a summary node.
    public struct CompactionResult: Sendable {
        /// The DAG node ID of the new summary node.
        public let nodeId: String

        /// The summary text stored in the node.
        public let summary: String

        /// Approximate tokens freed by the compaction.
        public let tokensSaved: Int

        public init(nodeId: String, summary: String, tokensSaved: Int) {
            self.nodeId = nodeId
            self.summary = summary
            self.tokensSaved = tokensSaved
        }
    }

    /// Compact a range of messages into a summary node.
    ///
    /// Finds the DAG nodes corresponding to messages in the given range,
    /// creates a new leaf_summary node with the provided summary text,
    /// links the source nodes as children, and updates the frontier.
    ///
    /// - Parameters:
    ///   - startIndex: Start message index (0-based) in the conversation.
    ///   - endIndex: End message index (exclusive).
    ///   - summary: Brief summary text provided by the model.
    /// - Returns: A ``CompactionResult`` with the new node ID and tokens saved.
    /// - Throws: ``ToolError/invalidParameters(_:)`` if no conversation exists or range is invalid.
    public func compactMessages(
        startIndex: Int,
        endIndex: Int,
        summary: String,
    ) async throws -> CompactionResult {
        guard startIndex >= 0, endIndex > startIndex else {
            throw ToolError.invalidParameters("Invalid range: start_index must be >= 0 and end_index must be > start_index")
        }

        let conversationId = try await db.dbPool.read { db in
            try ConversationRecord
                .order(Column("lastMessageAt").desc)
                .fetchOne(db)?.id
        }

        guard let conversationId else {
            throw ToolError.executionFailed("No active conversation found")
        }

        // Find the raw_turn nodes in the message range.
        // Each raw_turn node covers 2 messages (user + assistant), so convert message indices to node indices.
        let nodeStartIndex = startIndex / 2
        let nodeEndIndex = (endIndex + 1) / 2

        let sourceNodes = try await db.dbPool.read { db in
            try LCMNodeRecord
                .filter(Column("conversationId") == conversationId)
                .filter(Column("depth") == 0)
                .filter(Column("kind") == NodeKind.rawTurn.rawValue)
                .order(Column("earliestAt").asc)
                .fetchAll(db)
        }

        let rangeEnd = min(nodeEndIndex, sourceNodes.count)
        let rangeStart = min(nodeStartIndex, rangeEnd)
        guard rangeStart < rangeEnd else {
            throw ToolError.invalidParameters("Message range maps to no DAG nodes (conversation has \(sourceNodes.count * 2) messages)")
        }

        let targetNodes = Array(sourceNodes[rangeStart ..< rangeEnd])
        let tokensFreed = targetNodes.reduce(0) { $0 + $1.tokenCount }

        let nodeId = DAGCompactor.makeNodeId(from: summary)
        let tokenCount = max(1, summary.utf8.count / 4)
        let now = DAGCompactor.formatDate(Date())

        let earliestAt = targetNodes.map(\.earliestAt).min() ?? now
        let latestAt = targetNodes.map(\.latestAt).max() ?? now
        let avgSalience = targetNodes.map(\.salienceScore).reduce(0, +) / Double(max(1, targetNodes.count))

        let footer = "[Compacted: \(summary). Use expand_memory(node_ids: ['\(nodeId)']) for details.]"

        try await db.dbPool.write { db in
            let summaryNode = LCMNodeRecord(
                nodeId: nodeId,
                conversationId: conversationId,
                depth: 1,
                kind: NodeKind.leafSummary.rawValue,
                tokenCount: tokenCount,
                checksum: DAGCompactor.sha256Hex(summary),
                salienceScore: avgSalience,
                hotness: 1.0,
                isCold: 0,
                canonicalText: summary,
                summaryText: summary,
                expandFooter: footer,
                earliestAt: earliestAt,
                latestAt: latestAt,
                lastAccessedAt: now,
                version: 1,
                createdAt: now,
            )
            try summaryNode.insert(db)

            let ftsRecord = LCMFTSRecord(
                content: summary,
                nodeId: nodeId,
                conversationId: conversationId,
                depth: 1,
                kind: NodeKind.leafSummary.rawValue,
            )
            try ftsRecord.insert(db)

            for sourceNode in targetNodes {
                let edge = LCMEdgeRecord(
                    fromNodeId: nodeId,
                    toNodeId: sourceNode.nodeId,
                    edgeKind: EdgeKind.summaryOf.rawValue,
                )
                try edge.insert(db)
            }

            // Update frontier: replace source nodes with the new summary
            let currentFrontier = try LCMFrontierRecord
                .filter(Column("conversationId") == conversationId)
                .order(Column("ordinal").asc)
                .fetchAll(db)

            let replacingIds = Set(targetNodes.map(\.nodeId))

            try db.execute(
                sql: "DELETE FROM lcm_frontier WHERE conversationId = ?",
                arguments: [conversationId],
            )

            var newFrontier: [String] = []
            var inserted = false
            for entry in currentFrontier {
                if replacingIds.contains(entry.nodeId) {
                    if !inserted {
                        newFrontier.append(nodeId)
                        inserted = true
                    }
                } else {
                    newFrontier.append(entry.nodeId)
                }
            }

            if !inserted {
                newFrontier.append(nodeId)
            }

            for (ordinal, nid) in newFrontier.enumerated() {
                let record = LCMFrontierRecord(
                    conversationId: conversationId,
                    nodeId: nid,
                    ordinal: ordinal,
                )
                try record.insert(db)
            }
        }

        return CompactionResult(
            nodeId: nodeId,
            summary: summary,
            tokensSaved: max(0, tokensFreed - tokenCount),
        )
    }

    // MARK: - Compaction Suggestions

    /// A candidate range of messages that could be compacted.
    public struct CompactionCandidate: Sendable {
        /// The message range (0-based indices).
        public let messageRange: Range<Int>

        /// The content category of this group.
        public let category: ContentCategory

        /// Estimated token count for this group.
        public let estimatedTokens: Int

        /// Brief description for the model.
        public let summary: String

        public init(messageRange: Range<Int>, category: ContentCategory, estimatedTokens: Int, summary: String) {
            self.messageRange = messageRange
            self.category = category
            self.estimatedTokens = estimatedTokens
            self.summary = summary
        }
    }

    /// Suggest compaction candidates based on the current conversation state.
    ///
    /// Groups consecutive tool-result and utility messages, scores each group
    /// by token count and semantic importance, and returns candidates sorted
    /// by "most compactable first".
    ///
    /// - Parameter currentTokenCount: The current total token count for the context.
    /// - Returns: Compaction candidates sorted by highest token savings first.
    public func suggestCompactions(currentTokenCount: Int) async throws -> [CompactionCandidate] {
        guard currentTokenCount > tokenBudget else { return [] }

        let conversationId = try await db.dbPool.read { db in
            try ConversationRecord
                .order(Column("lastMessageAt").desc)
                .fetchOne(db)?.id
        }

        guard let conversationId else { return [] }

        let messages = try db.dbPool.read { db in
            try Row.fetchAll(
                db,
                sql: """
                SELECT id, role, content, tokenEstimate
                FROM messages
                WHERE conversationId = ?
                ORDER BY id ASC
                """,
                arguments: [conversationId],
            )
        }

        // Protect the fresh tail from compaction suggestions
        let protectedCount = CIMSDefaults.protectedTailCount
        let compactableMessages = Array(messages.dropLast(min(protectedCount, messages.count)))
        guard !compactableMessages.isEmpty else { return [] }

        var candidates: [CompactionCandidate] = []
        var groupStart: Int?
        var groupTokens = 0
        var groupCategory: ContentCategory?

        for (index, row) in compactableMessages.enumerated() {
            let role: String = row["role"]
            let content: String = row["content"]
            let tokens: Int = row["tokenEstimate"]

            let category = categorize(role: role, content: content)

            if category != .conversation {
                if groupCategory == nil || groupCategory == category {
                    if groupStart == nil { groupStart = index }
                    groupTokens += tokens
                    groupCategory = category
                } else {
                    // Different non-conversation category — flush current group
                    if let start = groupStart, groupTokens >= minCompactableTokens, let cat = groupCategory {
                        candidates.append(CompactionCandidate(
                            messageRange: start ..< index,
                            category: cat,
                            estimatedTokens: groupTokens,
                            summary: "\(cat.rawValue) block (\(index - start) messages, ~\(groupTokens) tokens)",
                        ))
                    }
                    groupStart = index
                    groupTokens = tokens
                    groupCategory = category
                }
            } else {
                // Conversation message — flush any pending group
                if let start = groupStart, groupTokens >= minCompactableTokens, let cat = groupCategory {
                    candidates.append(CompactionCandidate(
                        messageRange: start ..< index,
                        category: cat,
                        estimatedTokens: groupTokens,
                        summary: "\(cat.rawValue) block (\(index - start) messages, ~\(groupTokens) tokens)",
                    ))
                }
                groupStart = nil
                groupTokens = 0
                groupCategory = nil
            }
        }

        // Flush trailing group
        if let start = groupStart, groupTokens >= minCompactableTokens, let cat = groupCategory {
            candidates.append(CompactionCandidate(
                messageRange: start ..< compactableMessages.count,
                category: cat,
                estimatedTokens: groupTokens,
                summary: "\(cat.rawValue) block (\(compactableMessages.count - start) messages, ~\(groupTokens) tokens)",
            ))
        }

        return candidates.sorted { $0.estimatedTokens > $1.estimatedTokens }
    }

    // MARK: - Categorization

    /// Classify a message's content category using rule-based heuristics.
    ///
    /// Detects tool results (bash output, file reads), config changes,
    /// and research content based on role and content patterns.
    ///
    /// - Parameters:
    ///   - role: The message role (user, assistant, tool, system).
    ///   - content: The message text.
    /// - Returns: The inferred content category.
    private func categorize(role: String, content: String) -> ContentCategory {
        if role == "tool" {
            let lower = content.lowercased()
            if lower.contains("exit code:") || lower.contains("$ ") || lower.contains("stdout") {
                return .toolExecution
            }
            if lower.contains("config") || lower.contains("setting") || lower.contains("gateway") {
                return .configChange
            }
            return .toolExecution
        }

        if role == "system" {
            return .configChange
        }

        let lower = content.lowercased()
        if lower.contains("search result") || lower.contains("web fetch") || lower.contains("documentation") {
            return .research
        }

        return .conversation
    }
}
