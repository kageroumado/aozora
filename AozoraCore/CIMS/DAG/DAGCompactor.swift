import CryptoKit
import Foundation
import GRDB

/// Compacts the LCM DAG by summarizing raw turns into leaf summaries and merging
/// same-depth summaries into higher-depth condensed nodes.
///
/// The compactor operates in two passes:
/// - **Leaf pass**: Groups depth-0 raw_turn nodes (excluding the fresh tail) into ~20k token
///   chunks and summarizes each chunk into a ~1200 token leaf_summary node.
/// - **Condensed pass**: Merges same-depth summaries into higher-depth condensed nodes.
///
/// Both passes use a three-tier escalation strategy to guarantee progress:
/// 1. Normal summarization (temperature 0.2, target tokens)
/// 2. Aggressive summarization (temperature 0.1, halved target)
/// 3. Deterministic truncation (~512 tokens) — no LLM call, just prefix truncation
///
/// Before summarizing each chunk during a leaf pass, the compactor optionally runs
/// **pre-compression claim extraction** via ``ClaimExtractor``. High-salience nodes
/// (salience >= 0.6) are analyzed for identity/mirror claims before their detail is
/// lost to summarization, giving the LLM a chance to save important memories
/// before compression.
///
/// **HARD INVARIANT**: The last `freshTailCount` (32) raw messages are NEVER compacted.
public nonisolated struct DAGCompactor: Sendable {
    /// The shared database backing all CIMS persistence.
    private let db: CIMSDatabase

    /// The model provider used for generating summaries.
    private let model: any ModelProviding

    /// Optional claim extractor for pre-compression identity/mirror claim extraction.
    /// When present, high-salience nodes are analyzed for claims before their content
    /// is compressed into summaries.
    private let claimExtractor: ClaimExtractor?

    /// Minimum salience score for a node to be eligible for pre-compression claim extraction.
    /// Nodes below this threshold are unlikely to contain identity-relevant content worth
    /// preserving as discrete claims.
    private static let preCompressionSalienceThreshold: Double = 0.6

    /// Creates a DAG compactor backed by the given database and model provider.
    ///
    /// - Parameters:
    ///   - database: The CIMS database instance for reading and writing DAG nodes.
    ///   - model: The model provider to use for summarization inference.
    ///   - claimExtractor: Optional claim extractor for pre-compression claim extraction.
    ///     When `nil`, no claim extraction occurs before compaction (backward compatible).
    public init(database: CIMSDatabase, model: any ModelProviding, claimExtractor: ClaimExtractor? = nil) {
        self.db = database
        self.model = model
        self.claimExtractor = claimExtractor
    }

    // MARK: - Leaf Pass

    /// Result of a leaf compaction pass, including both the summary count and any
    /// identity/mirror claims extracted from high-salience content before compression.
    public struct LeafPassResult: Sendable {
        /// Number of leaf_summary nodes created during this pass.
        public let summariesCreated: Int

        /// Consolidation proposals extracted from high-salience nodes before their
        /// content was compressed. Empty if no ``ClaimExtractor`` was provided or
        /// if no nodes exceeded the salience threshold.
        public let preCompressionProposals: [ConsolidationProposal]
    }

    /// Summarize raw_turn nodes outside the fresh tail into leaf_summary nodes.
    ///
    /// Groups eligible depth-0 nodes into chunks of approximately ``CIMSDefaults/leafChunkTokens``
    /// tokens, then summarizes each chunk into a ~1200 token leaf_summary. Creates `summary_of`
    /// edges from the new summary to each source node and updates the conversation frontier.
    ///
    /// Before summarizing each chunk, runs pre-compression claim extraction on any nodes
    /// with salience >= 0.6 (if a ``ClaimExtractor`` was provided). This preserves identity
    /// and mirror claims from high-salience content that would otherwise lose detail during
    /// summarization.
    ///
    /// The last `freshTailCount` raw messages are excluded from compaction (hard invariant).
    /// Uses three-tier escalation to guarantee that every chunk produces a summary.
    ///
    /// - Parameters:
    ///   - conversationId: The conversation to compact.
    ///   - freshTailCount: Number of most-recent raw nodes to protect from compaction.
    /// - Returns: A ``LeafPassResult`` containing the number of summaries created and any
    ///   pre-compression consolidation proposals.
    @discardableResult
    public func leafPass(conversationId: ConversationID, freshTailCount: Int = CIMSDefaults.protectedTailCount) async throws -> LeafPassResult {
        let eligibleNodes = try await db.dbPool.read { db in
            let allRawNodes = try LCMNodeRecord
                .filter(Column("conversationId") == conversationId)
                .filter(Column("depth") == 0)
                .filter(Column("kind") == NodeKind.rawTurn.rawValue)
                .order(Column("earliestAt").asc)
                .fetchAll(db)

            guard allRawNodes.count > freshTailCount else { return [LCMNodeRecord]() }
            return Array(allRawNodes.dropLast(freshTailCount))
        }

        guard !eligibleNodes.isEmpty else { return LeafPassResult(summariesCreated: 0, preCompressionProposals: []) }

        let alreadySummarized = try await db.dbPool.read { db in
            try Set(
                String.fetchAll(
                    db,
                    sql: """
                    SELECT DISTINCT toNodeId FROM lcm_edges
                    WHERE edgeKind = ? AND fromNodeId IN (
                        SELECT nodeId FROM lcm_nodes WHERE conversationId = ? AND depth = 1
                    )
                    """,
                    arguments: [EdgeKind.summaryOf.rawValue, conversationId],
                ),
            )
        }

        let unsummarized = eligibleNodes.filter { !alreadySummarized.contains($0.nodeId) }
        guard !unsummarized.isEmpty else { return LeafPassResult(summariesCreated: 0, preCompressionProposals: []) }

        let inputTokens = unsummarized.reduce(0) { $0 + $1.tokenCount }
        let chunks = chunkNodes(unsummarized, targetTokens: CIMSDefaults.leafChunkTokens)
        Log.info("compaction", "Leaf pass: \(unsummarized.count) nodes (\(inputTokens) tok) → \(chunks.count) chunks")
        let leafStart = ContinuousClock.now
        var summariesCreated = 0
        var preCompressionProposals: [ConsolidationProposal] = []

        for chunk in chunks {
            // Pre-compression claim extraction: extract identity/mirror claims from
            // high-salience content before summarization loses detail.
            if let proposal = try await extractClaimsBeforeCompaction(nodes: chunk) {
                if !proposal.nothingSignificant {
                    preCompressionProposals.append(proposal)
                }
            }

            let summaryText = try await summarizeWithEscalation(
                nodes: chunk,
                targetTokens: CIMSDefaults.leafTargetTokensMax,
            )

            let footer = buildExpandFooter(for: chunk)
            let nodeId = Self.makeNodeId(from: summaryText)
            let tokenCount = summaryText.utf8.count / 4
            let now = Self.formatDate(Date())

            let earliestAt = chunk.map(\.earliestAt).min() ?? now
            let latestAt = chunk.map(\.latestAt).max() ?? now
            let avgSalience = chunk.map(\.salienceScore).reduce(0, +) / Double(max(1, chunk.count))

            try await db.dbPool.write { db in
                let summaryNode = LCMNodeRecord(
                    nodeId: nodeId,
                    conversationId: conversationId,
                    depth: 1,
                    kind: NodeKind.leafSummary.rawValue,
                    tokenCount: tokenCount,
                    checksum: Self.sha256Hex(summaryText),
                    salienceScore: avgSalience,
                    hotness: 1.0,
                    isCold: 0,
                    canonicalText: summaryText,
                    summaryText: summaryText,
                    expandFooter: footer,
                    earliestAt: earliestAt,
                    latestAt: latestAt,
                    lastAccessedAt: now,
                    version: 1,
                    createdAt: now,
                )
                try summaryNode.insert(db, onConflict: .ignore)

                let ftsRecord = LCMFTSRecord(
                    content: summaryText,
                    nodeId: nodeId,
                    conversationId: conversationId,
                    depth: 1,
                    kind: NodeKind.leafSummary.rawValue,
                )
                try ftsRecord.insert(db, onConflict: .ignore)

                for sourceNode in chunk {
                    let edge = LCMEdgeRecord(
                        fromNodeId: nodeId,
                        toNodeId: sourceNode.nodeId,
                        edgeKind: EdgeKind.summaryOf.rawValue,
                    )
                    try edge.insert(db, onConflict: .ignore)
                }

                try Self.updateFrontier(
                    db: db,
                    conversationId: conversationId,
                    replacingNodeIds: Set(chunk.map(\.nodeId)),
                    withNodeId: nodeId,
                )
            }

            summariesCreated += 1
        }

        let leafSecs = ContinuousClock.now - leafStart
        let leafMs = Int(leafSecs.components.seconds) * 1_000
        Log.info("compaction", "Leaf pass done: \(summariesCreated) summaries, \(preCompressionProposals.count) proposals (\(leafMs)ms)")
        return LeafPassResult(summariesCreated: summariesCreated, preCompressionProposals: preCompressionProposals)
    }

    // MARK: - Condensed Pass

    /// Merge same-depth summary nodes into higher-depth condensed nodes.
    ///
    /// Finds depth-1+ nodes that can be grouped (3+ nodes at the same depth) and merges
    /// them into a single condensed node at depth+1. Creates `summary_of` edges and
    /// updates the frontier.
    ///
    /// - Parameter conversationId: The conversation to compact.
    /// - Returns: The number of condensed nodes created.
    @discardableResult
    public func condensedPass(conversationId: ConversationID) async throws -> Int {
        var totalCreated = 0
        var currentDepth = 1

        while currentDepth < 10 {
            let depth = currentDepth
            let nodesAtDepth = try await db.dbPool.read { db in
                try LCMNodeRecord
                    .filter(Column("conversationId") == conversationId)
                    .filter(Column("depth") == depth)
                    .order(Column("earliestAt").asc)
                    .fetchAll(db)
            }

            guard nodesAtDepth.count >= 3 else { break }

            let nextDepth = currentDepth + 1
            let alreadyCondensed = try await db.dbPool.read { db in
                try Set(
                    String.fetchAll(
                        db,
                        sql: """
                        SELECT DISTINCT toNodeId FROM lcm_edges
                        WHERE edgeKind = ? AND fromNodeId IN (
                            SELECT nodeId FROM lcm_nodes WHERE conversationId = ? AND depth = ?
                        )
                        """,
                        arguments: [EdgeKind.summaryOf.rawValue, conversationId, nextDepth],
                    ),
                )
            }

            let uncondensed = nodesAtDepth.filter { !alreadyCondensed.contains($0.nodeId) }
            guard uncondensed.count >= 3 else {
                currentDepth += 1
                continue
            }

            let chunks = chunkNodes(uncondensed, targetTokens: CIMSDefaults.leafChunkTokens)
            for chunk in chunks where chunk.count >= 2 {
                let summaryText = try await summarizeWithEscalation(
                    nodes: chunk,
                    targetTokens: CIMSDefaults.condensedTargetTokens,
                )

                let footer = buildExpandFooter(for: chunk)
                let nodeId = Self.makeNodeId(from: summaryText)
                let tokenCount = summaryText.utf8.count / 4
                let now = Self.formatDate(Date())

                let earliestAt = chunk.map(\.earliestAt).min() ?? now
                let latestAt = chunk.map(\.latestAt).max() ?? now
                let avgSalience = chunk.map(\.salienceScore).reduce(0, +) / Double(max(1, chunk.count))
                let newDepth = currentDepth + 1

                try await db.dbPool.write { db in
                    let condensedNode = LCMNodeRecord(
                        nodeId: nodeId,
                        conversationId: conversationId,
                        depth: newDepth,
                        kind: NodeKind.condensed.rawValue,
                        tokenCount: tokenCount,
                        checksum: Self.sha256Hex(summaryText),
                        salienceScore: avgSalience,
                        hotness: 1.0,
                        isCold: 0,
                        canonicalText: summaryText,
                        summaryText: summaryText,
                        expandFooter: footer,
                        earliestAt: earliestAt,
                        latestAt: latestAt,
                        lastAccessedAt: now,
                        version: 1,
                        createdAt: now,
                    )
                    try condensedNode.insert(db, onConflict: .ignore)

                    let ftsRecord = LCMFTSRecord(
                        content: summaryText,
                        nodeId: nodeId,
                        conversationId: conversationId,
                        depth: newDepth,
                        kind: NodeKind.condensed.rawValue,
                    )
                    try ftsRecord.insert(db, onConflict: .ignore)

                    for sourceNode in chunk {
                        let edge = LCMEdgeRecord(
                            fromNodeId: nodeId,
                            toNodeId: sourceNode.nodeId,
                            edgeKind: EdgeKind.summaryOf.rawValue,
                        )
                        try edge.insert(db, onConflict: .ignore)
                    }

                    try Self.updateFrontier(
                        db: db,
                        conversationId: conversationId,
                        replacingNodeIds: Set(chunk.map(\.nodeId)),
                        withNodeId: nodeId,
                    )
                }

                totalCreated += 1
            }

            currentDepth += 1
        }

        return totalCreated
    }

    // MARK: - Condensed Pass (Single Depth)

    /// Run a condensed pass at exactly one depth level.
    ///
    /// Unlike ``condensedPass(conversationId:)`` which iterates all depths internally,
    /// this method operates on a single depth, enabling pressure-gated compaction where
    /// token pressure is checked between each depth level.
    ///
    /// Excludes `raw_turn` nodes — only `leaf`, `leaf_summary`, and `condensed` nodes
    /// are eligible for condensation.
    ///
    /// - Parameters:
    ///   - conversationId: The conversation to compact.
    ///   - depth: The depth level to condense (nodes at this depth are merged into depth+1).
    /// - Returns: The number of condensed nodes created at depth+1.
    @discardableResult
    public func condensedPassAtDepth(
        conversationId: ConversationID,
        depth: Int,
    ) async throws -> Int {
        let nodesAtDepth = try await db.dbPool.read { db in
            try LCMNodeRecord
                .filter(Column("conversationId") == conversationId)
                .filter(Column("depth") == depth)
                .filter(Column("kind") != NodeKind.rawTurn.rawValue)
                .order(Column("earliestAt").asc)
                .fetchAll(db)
        }

        guard nodesAtDepth.count >= 3 else { return 0 }

        let nextDepth = depth + 1
        let alreadyCondensed = try await db.dbPool.read { db in
            try Set(
                String.fetchAll(
                    db,
                    sql: """
                    SELECT DISTINCT toNodeId FROM lcm_edges
                    WHERE edgeKind = ? AND fromNodeId IN (
                        SELECT nodeId FROM lcm_nodes WHERE conversationId = ? AND depth = ?
                    )
                    """,
                    arguments: [EdgeKind.summaryOf.rawValue, conversationId, nextDepth],
                ),
            )
        }

        let uncondensed = nodesAtDepth.filter { !alreadyCondensed.contains($0.nodeId) }
        guard uncondensed.count >= 3 else { return 0 }

        let chunks = chunkNodes(uncondensed, targetTokens: CIMSDefaults.leafChunkTokens)
        var totalCreated = 0

        for chunk in chunks where chunk.count >= 2 {
            let summaryText = try await summarizeWithEscalation(
                nodes: chunk,
                targetTokens: CIMSDefaults.condensedTargetTokens,
            )

            let footer = buildExpandFooter(for: chunk)
            let nodeId = Self.makeNodeId(from: summaryText)
            let tokenCount = summaryText.utf8.count / 4
            let now = Self.formatDate(Date())

            let earliestAt = chunk.map(\.earliestAt).min() ?? now
            let latestAt = chunk.map(\.latestAt).max() ?? now
            let avgSalience = chunk.map(\.salienceScore).reduce(0, +) / Double(max(1, chunk.count))

            try await db.dbPool.write { db in
                let condensedNode = LCMNodeRecord(
                    nodeId: nodeId,
                    conversationId: conversationId,
                    depth: nextDepth,
                    kind: NodeKind.condensed.rawValue,
                    tokenCount: tokenCount,
                    checksum: Self.sha256Hex(summaryText),
                    salienceScore: avgSalience,
                    hotness: 1.0,
                    isCold: 0,
                    canonicalText: summaryText,
                    summaryText: summaryText,
                    expandFooter: footer,
                    earliestAt: earliestAt,
                    latestAt: latestAt,
                    lastAccessedAt: now,
                    version: 1,
                    createdAt: now,
                )
                try condensedNode.insert(db, onConflict: .ignore)

                let ftsRecord = LCMFTSRecord(
                    content: summaryText,
                    nodeId: nodeId,
                    conversationId: conversationId,
                    depth: nextDepth,
                    kind: NodeKind.condensed.rawValue,
                )
                try ftsRecord.insert(db, onConflict: .ignore)

                for sourceNode in chunk {
                    let edge = LCMEdgeRecord(
                        fromNodeId: nodeId,
                        toNodeId: sourceNode.nodeId,
                        edgeKind: EdgeKind.summaryOf.rawValue,
                    )
                    try edge.insert(db, onConflict: .ignore)
                }

                try Self.updateFrontier(
                    db: db,
                    conversationId: conversationId,
                    replacingNodeIds: Set(chunk.map(\.nodeId)),
                    withNodeId: nodeId,
                )
            }

            totalCreated += 1
        }

        return totalCreated
    }

    // MARK: - Frontier Token Count

    /// Query the total token count of all frontier nodes for a conversation.
    ///
    /// Used by pressure-gated compaction to determine whether additional condensation
    /// passes are needed to bring the frontier below a target threshold.
    ///
    /// - Parameter conversationId: The conversation to query.
    /// - Returns: The sum of `tokenCount` across all frontier nodes.
    public func frontierTokenCount(conversationId: ConversationID) async throws -> Int {
        try await db.dbPool.read { db in
            try Int.fetchOne(
                db,
                sql: """
                SELECT COALESCE(SUM(n.tokenCount), 0)
                FROM lcm_frontier f
                JOIN lcm_nodes n ON n.nodeId = f.nodeId
                WHERE f.conversationId = ?
                """,
                arguments: [conversationId],
            ) ?? 0
        }
    }

    // MARK: - Pressure-Gated Compaction

    /// Unified compaction loop that runs leaf + condensed passes while above a target token threshold.
    ///
    /// Phase 1 runs a leaf pass (always, counts as 1 pass). Phase 2 runs condensed passes
    /// one depth at a time, checking frontier token pressure between each depth. Stops when
    /// the frontier is below `targetTokens` or `maxPasses` is exhausted.
    ///
    /// Used by both soft-threshold (async, after turn) and hard-threshold (blocking, before inference)
    /// compaction paths.
    ///
    /// - Parameters:
    ///   - conversationId: The conversation to compact.
    ///   - targetTokens: Target frontier token count to reach.
    ///   - protectedTailCount: Number of most-recent raw nodes to protect from leaf compaction.
    ///   - maxPasses: Maximum total passes (leaf + condensed) to prevent cascade.
    /// - Returns: A tuple of the leaf pass result and the total number of condensed nodes created.
    public func pressureGatedCompaction(
        conversationId: ConversationID,
        targetTokens: Int,
        protectedTailCount: Int = CIMSDefaults.protectedTailCount,
        maxPasses: Int = 5,
    ) async throws -> (leafResult: LeafPassResult, condensedCreated: Int) {
        let startTokens = try await frontierTokenCount(conversationId: conversationId)
        Log.info("compaction", "Pressure-gated: frontier=\(startTokens) target=\(targetTokens) maxPasses=\(maxPasses)")
        let compactionStart = ContinuousClock.now

        var passesUsed = 1
        let leafResult = try await leafPass(
            conversationId: conversationId,
            freshTailCount: protectedTailCount,
        )

        var condensedCreated = 0
        for depth in 0 ..< 10 {
            if passesUsed >= maxPasses { break }

            let currentTokens = try await frontierTokenCount(conversationId: conversationId)
            if currentTokens <= targetTokens { break }

            let created = try await condensedPassAtDepth(
                conversationId: conversationId,
                depth: depth,
            )
            passesUsed += 1
            condensedCreated += created
            if created == 0 { continue }
        }

        let endTokens = try await frontierTokenCount(conversationId: conversationId)
        let elapsed = ContinuousClock.now - compactionStart
        let secs = String(format: "%.1f", Double(elapsed.components.seconds) + Double(elapsed.components.attoseconds) / 1e18)
        Log.info("compaction", "Pressure-gated done: \(startTokens)→\(endTokens) tok (\(passesUsed) passes, \(leafResult.summariesCreated) leaf, \(condensedCreated) condensed, \(secs)s)")
        return (leafResult, condensedCreated)
    }

    // MARK: - Pre-Compression Claim Extraction

    /// Extract identity and mirror claims from high-salience nodes before their content
    /// is compressed into a summary.
    ///
    /// Filters the given nodes to those with ``salienceScore`` >= 0.6, converts them into
    /// ``BumpCandidate``s, and feeds them to the ``ClaimExtractor``. This preserves
    /// identity-relevant details that would otherwise be lost during summarization.
    ///
    /// Returns `nil` if no claim extractor is available, or if no nodes in the chunk
    /// meet the salience threshold.
    ///
    /// - Parameter nodes: The chunk of DAG nodes about to be summarized.
    /// - Returns: A ``ConsolidationProposal`` with extracted claims, or `nil` if
    ///   extraction was skipped.
    private func extractClaimsBeforeCompaction(nodes: [LCMNodeRecord]) async throws -> ConsolidationProposal? {
        guard let claimExtractor else { return nil }

        let highSalienceNodes = nodes.filter { $0.salienceScore >= Self.preCompressionSalienceThreshold }
        guard !highSalienceNodes.isEmpty else { return nil }

        let candidates = highSalienceNodes.compactMap { node -> BumpCandidate? in
            guard let text = node.canonicalText else { return nil }
            return BumpCandidate(
                nodeId: node.nodeId,
                reason: .topicShiftHighSalience,
                salienceScore: Float(node.salienceScore),
                content: text,
            )
        }

        guard !candidates.isEmpty else { return nil }

        return try await claimExtractor.extractClaims(from: candidates)
    }

    // MARK: - Three-Tier Escalation

    /// Summarize a chunk of nodes using three-tier escalation to guarantee progress.
    ///
    /// 1. **Normal**: Standard summarization at temperature 0.2.
    /// 2. **Aggressive**: Tighter prompt, halved target tokens, temperature 0.1.
    /// 3. **Deterministic truncation**: No LLM call, prefix truncation to ~512 tokens.
    ///
    /// - Parameters:
    ///   - nodes: The source nodes to summarize.
    ///   - targetTokens: Target token count for the summary.
    /// - Returns: The summary text (always succeeds — tier 3 is deterministic).
    private func summarizeWithEscalation(
        nodes: [LCMNodeRecord],
        targetTokens: Int,
    ) async throws -> String {
        let sourceText = nodes.compactMap(\.canonicalText).joined(separator: "\n\n---\n\n")

        if let result = try? await callSummarizer(
            text: sourceText,
            targetTokens: targetTokens,
            aggressive: false,
        ) {
            return result
        }

        if let result = try? await callSummarizer(
            text: sourceText,
            targetTokens: targetTokens / 2,
            aggressive: true,
        ) {
            return result
        }

        return deterministicTruncation(sourceText, tokenLimit: CIMSDefaults.deterministicTruncationTokens)
    }

    /// Call the model to produce a summary of the given text.
    ///
    /// The prompt adapts output length based on content density: routine heartbeats
    /// and status checks get compressed to ~1500 tokens, while substantive conversations
    /// with emotional weight or key decisions can use up to `targetTokens`.
    ///
    /// - Parameters:
    ///   - text: The source text to summarize.
    ///   - targetTokens: Desired summary length in tokens.
    ///   - aggressive: Whether to use aggressive summarization mode.
    /// - Returns: The summary text.
    private func callSummarizer(
        text: String,
        targetTokens: Int,
        aggressive: Bool,
    ) async throws -> String {
        let prompt = if aggressive {
            """
            Aggressively compress the following conversation into a dense summary of approximately \(targetTokens) tokens.
            Focus only on key decisions, outcomes, and novel information. Omit all pleasantries and routine exchanges.
            
            \(text)
            """
        } else {
            """
            Summarize the following conversation segment.
            
            Guidelines:
            - Adapt summary length based on content: 1500 tokens for routine/repetitive \
            exchanges (heartbeats, status checks), up to \(targetTokens) tokens for substantive \
            conversations with emotional weight, key decisions, or important phrasing.
            - Preserve exact words and phrasing for emotionally significant or \
            identity-relevant statements — texture matters more than compression ratio.
            - Preserve key facts, decisions, technical details, and emotional tone.
            - For tool-heavy segments: summarize the intent and outcome, not the raw tool output.
            - Content marked with [preserve] MUST be quoted verbatim in the summary, \
            including the surrounding context that gives it meaning.
            - End with: "Expand for details about: ..." listing the main topics covered.
            
            \(text)
            """
        }

        let apiPrompt = PromptBuilder().buildWorkerPrompt(
            systemPrompt: prompt,
            goal: "Summarize the content above according to the instructions.",
            tools: [],
        )

        let response = try await model.complete(apiPrompt, tier: .consolidation)
        return response.content
    }

    /// Deterministic truncation fallback: take the first ~N tokens worth of text.
    ///
    /// Guarantees progress when LLM summarization fails. Truncates at a sentence boundary
    /// if possible, otherwise at the character limit.
    ///
    /// - Parameters:
    ///   - text: The source text to truncate.
    ///   - tokenLimit: Approximate target token count.
    /// - Returns: The truncated text with an appended truncation notice.
    private func deterministicTruncation(_ text: String, tokenLimit: Int) -> String {
        let charLimit = tokenLimit * 4
        guard text.count > charLimit else { return text }

        let prefix = String(text.prefix(charLimit))

        if let lastPeriod = prefix.lastIndex(of: ".") {
            let truncated = String(prefix[prefix.startIndex ... lastPeriod])
            return truncated + "\n\n[Truncated — deterministic fallback]"
        }

        return prefix + "\n\n[Truncated — deterministic fallback]"
    }

    // MARK: - Chunking

    /// Group nodes into chunks of approximately `targetTokens` total tokens.
    ///
    /// Each chunk contains enough nodes to reach the target, ensuring no chunk
    /// is unreasonably small (at least 1 node per chunk).
    ///
    /// - Parameters:
    ///   - nodes: Nodes to group, in chronological order.
    ///   - targetTokens: Approximate token count per chunk.
    /// - Returns: Array of node chunks.
    private func chunkNodes(_ nodes: [LCMNodeRecord], targetTokens: Int) -> [[LCMNodeRecord]] {
        var chunks: [[LCMNodeRecord]] = []
        var current: [LCMNodeRecord] = []
        var currentTokens = 0

        for node in nodes {
            current.append(node)
            currentTokens += node.tokenCount

            if currentTokens >= targetTokens {
                chunks.append(current)
                current = []
                currentTokens = 0
            }
        }

        if !current.isEmpty {
            if chunks.isEmpty {
                chunks.append(current)
            } else {
                chunks[chunks.count - 1].append(contentsOf: current)
            }
        }

        return chunks
    }

    // MARK: - Footer

    /// Build an "Expand for details about: ..." footer from source nodes.
    ///
    /// Extracts topic keywords from node content to create a human-readable
    /// list of what can be expanded.
    ///
    /// - Parameter nodes: The source nodes being summarized.
    /// - Returns: A footer string listing expandable topics.
    private func buildExpandFooter(for nodes: [LCMNodeRecord]) -> String {
        let topics = nodes.compactMap { node -> String? in
            guard let text = node.canonicalText ?? node.summaryText else { return nil }
            let words = text.split(separator: " ").prefix(8).joined(separator: " ")
            return words.isEmpty ? nil : words
        }
        .prefix(5)

        guard !topics.isEmpty else { return "Expand for details." }
        return "Expand for details about: \(topics.joined(separator: "; "))"
    }

    // MARK: - Frontier Management

    /// Update the conversation frontier by replacing source node entries with a new summary node.
    ///
    /// Removes frontier entries for the replaced nodes, inserts the new summary node at the
    /// position of the first replaced node, then renumbers ordinals to maintain continuity.
    ///
    /// - Parameters:
    ///   - db: The GRDB database connection.
    ///   - conversationId: The conversation whose frontier to update.
    ///   - replacingNodeIds: Node IDs being replaced by the summary.
    ///   - withNodeId: The new summary node ID to insert.
    private static func updateFrontier(
        db: Database,
        conversationId: ConversationID,
        replacingNodeIds: Set<String>,
        withNodeId: String,
    ) throws {
        let currentFrontier = try LCMFrontierRecord
            .filter(Column("conversationId") == conversationId)
            .order(Column("ordinal").asc)
            .fetchAll(db)

        try db.execute(
            sql: "DELETE FROM lcm_frontier WHERE conversationId = ?",
            arguments: [conversationId],
        )

        var newFrontier: [String] = []
        var inserted = false
        for entry in currentFrontier {
            if replacingNodeIds.contains(entry.nodeId) {
                if !inserted {
                    newFrontier.append(withNodeId)
                    inserted = true
                }
            } else {
                newFrontier.append(entry.nodeId)
            }
        }

        if !inserted {
            newFrontier.append(withNodeId)
        }

        for (ordinal, nodeId) in newFrontier.enumerated() {
            let record = LCMFrontierRecord(
                conversationId: conversationId,
                nodeId: nodeId,
                ordinal: ordinal,
            )
            try record.insert(db, onConflict: .ignore)
        }
    }

    // MARK: - Hashing Helpers

    /// Generate a deterministic node ID from text content.
    ///
    /// Format: `"node_" + SHA-256(text).prefix(16)`.
    ///
    /// - Parameter text: The text to hash.
    /// - Returns: A deterministic node ID string.
    public nonisolated static func makeNodeId(from text: String) -> NodeID {
        let data = Data(text.utf8)
        let digest = SHA256.hash(data: data)
        let hexPrefix = digest.prefix(8).map { unsafe String(format: "%02x", $0) }.joined()
        return "node_\(hexPrefix)"
    }

    /// Compute the full SHA-256 hex string of the given text.
    public nonisolated static func sha256Hex(_ text: String) -> String {
        let data = Data(text.utf8)
        let digest = SHA256.hash(data: data)
        return digest.map { unsafe String(format: "%02x", $0) }.joined()
    }

    /// Format a `Date` as an ISO 8601 string with fractional seconds.
    public nonisolated static func formatDate(_ date: Date) -> String {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f.string(from: date)
    }
}
