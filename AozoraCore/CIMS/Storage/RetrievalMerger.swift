/// Merges retrieval results from multiple strategies, deduplicating by node ID
/// and boosting nodes confirmed by multiple independent signals.
///
/// The merge formula follows the CombSUM principle from metasearch research
/// (Fox & Shaw, 1994) — scores from different retrieval strategies are
/// combined additively, with a dampening factor to prevent runaway scores
/// from strategy count alone.
///
/// Score formula: `mergedScore = maxScore + α × (strategyCount - 1)`
/// where `α = 0.1` (tunable, low to avoid over-weighting breadth over depth).
///
/// This is a pure, stateless value type used by ``MemoryStore`` to combine
/// FTS5 keyword hits, claim token matches, and temporal adjacency results
/// before returning the final ranked candidate list to ``CIMSCoordinator``.
public struct RetrievalMerger: Sendable {
    // MARK: - Nested Types

    /// A retrieval result produced by one strategy for one node.
    public struct StrategyResult: Sendable {
        /// The node this result refers to.
        public let nodeId: NodeID
        /// Relevance score in the range [0.0, 1.0] as assigned by the strategy.
        public let score: Float
        /// The retrieval strategy that produced this result.
        public let strategy: Strategy

        /// Creates a strategy result.
        ///
        /// - Parameters:
        ///   - nodeId: The node this result refers to.
        ///   - score: Relevance score in [0.0, 1.0].
        ///   - strategy: The strategy that produced this result.
        public init(nodeId: NodeID, score: Float, strategy: Strategy) {
            self.nodeId = nodeId
            self.score = score
            self.strategy = strategy
        }
    }

    /// A retrieval strategy that can contribute results to a merge.
    public enum Strategy: String, Sendable, Hashable {
        /// FTS5 keyword matching with BM25 ranking.
        case keyword
        /// Claim key/value token overlap matching.
        case claim
        /// Temporal adjacency within detected time windows.
        case temporal
    }

    // MARK: - Constants

    /// Dampening factor applied per additional confirming strategy beyond the first.
    ///
    /// Kept small (0.1) so that strategy breadth never outweighs a single high-quality
    /// deep hit — a lone score of 0.95 still beats a triple-confirmed score of 0.3 + 0.2.
    static let alpha: Float = 0.1

    // MARK: - Merge

    /// Merges a flat array of per-strategy results into a deduplicated, ranked list.
    ///
    /// For each unique node ID, the merger takes the maximum score across all strategies
    /// and adds `α × (confirming strategy count - 1)` as a multi-signal confirmation bonus.
    /// The returned list is sorted by merged score descending so callers can truncate at any
    /// `k` without additional sorting.
    ///
    /// - Parameter results: All results from all strategies, in any order.
    /// - Returns: One entry per unique node ID, sorted by merged score descending.
    public static func merge(
        _ results: [StrategyResult],
    ) -> [(nodeId: NodeID, score: Float, strategies: Set<Strategy>)] {
        var byNode: [NodeID: (maxScore: Float, count: Int, strategies: Set<Strategy>)] = [:]

        for r in results {
            if var entry = byNode[r.nodeId] {
                entry.maxScore = max(entry.maxScore, r.score)
                entry.count += 1
                entry.strategies.insert(r.strategy)
                byNode[r.nodeId] = entry
            } else {
                byNode[r.nodeId] = (maxScore: r.score, count: 1, strategies: [r.strategy])
            }
        }

        return byNode
            .map { nodeId, entry in
                let merged = entry.maxScore + alpha * Float(entry.count - 1)
                return (nodeId: nodeId, score: merged, strategies: entry.strategies)
            }
            .sorted { $0.score > $1.score }
    }
}
