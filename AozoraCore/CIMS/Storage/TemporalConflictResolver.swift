import Foundation

/// A candidate node for temporal conflict detection.
///
/// Contains pre-tokenized content words and metadata needed for
/// Jaccard similarity and temporal distance computation.
public struct ConflictCandidate: Sendable {
    /// The DAG node identifier.
    public let nodeId: NodeID
    /// Content words with stop words removed (for Jaccard overlap).
    public let tokens: Set<String>
    /// When this node was created.
    public let timestamp: Date
    /// The retrieval score from the merger.
    public let score: Float

    public init(nodeId: NodeID, tokens: Set<String>, timestamp: Date, score: Float) {
        self.nodeId = nodeId
        self.tokens = tokens
        self.timestamp = timestamp
        self.score = score
    }
}

/// A cluster of nodes with temporal conflict.
public struct ConflictCluster: Sendable {
    /// The node IDs involved in the conflict.
    public let nodeIds: Set<NodeID>
    /// The highest score among conflicting nodes.
    public let maxScore: Float
}

/// Detects and resolves temporal conflicts in retrieval results.
///
/// Implements a lightweight variant of ASMR's agentic retrieval principle:
/// when keyword search returns contradictory information from different time periods,
/// use a single cheap LLM call to determine which is most current.
///
/// Activation is gated by three conditions (all required):
/// 1. Token overlap ratio > 0.3 between node pairs (Jaccard on content words)
/// 2. Temporal distance > 24h between overlapping nodes
/// 3. Query contains current-state markers
///
/// Cost: at most 1 worker-tier LLM call per turn, only when all conditions met.
public struct TemporalConflictResolver: Sendable {
    /// Minimum Jaccard similarity for overlap detection.
    static let overlapThreshold: Double = 0.3

    /// Minimum temporal distance (seconds) between nodes for conflict.
    static let temporalThreshold: TimeInterval = 24 * 3_600

    /// Standard English stop words filtered before Jaccard computation.
    static let stopWords: Set<String> = [
        "i", "me", "my", "myself", "we", "our", "ours", "ourselves", "you", "your",
        "yours", "yourself", "yourselves", "he", "him", "his", "himself", "she", "her",
        "hers", "herself", "it", "its", "itself", "they", "them", "their", "theirs",
        "themselves", "what", "which", "who", "whom", "this", "that", "these", "those",
        "am", "is", "are", "was", "were", "be", "been", "being", "have", "has", "had",
        "having", "do", "does", "did", "doing", "a", "an", "the", "and", "but", "if",
        "or", "because", "as", "until", "while", "of", "at", "by", "for", "with",
        "about", "against", "between", "through", "during", "before", "after", "above",
        "below", "to", "from", "up", "down", "in", "out", "on", "off", "over", "under",
        "again", "further", "then", "once", "here", "there", "when", "where", "why",
        "how", "all", "both", "each", "few", "more", "most", "other", "some", "such",
        "no", "nor", "not", "only", "own", "same", "so", "than", "too", "very", "s",
        "t", "can", "will", "just", "don", "should", "now", "d", "ll", "m", "o", "re",
        "ve", "y", "ain", "aren", "couldn", "didn", "doesn", "hadn", "hasn", "haven",
        "isn", "ma", "mightn", "mustn", "needn", "shan", "shouldn", "wasn", "weren",
        "won", "wouldn", "new",
    ]

    /// Tokenize text into content words (stop words removed, lowercased, 3+ chars).
    public static func contentTokens(_ text: String) -> Set<String> {
        let words = text.lowercased()
            .components(separatedBy: CharacterSet.alphanumerics.inverted)
            .filter { $0.count >= 3 && !stopWords.contains($0) }
        return Set(words)
    }

    /// Detect temporal conflict clusters among candidates.
    ///
    /// Two nodes conflict when their content word Jaccard similarity exceeds 0.3
    /// AND they are more than 24 hours apart.
    public static func detectConflicts(_ candidates: [ConflictCandidate]) -> [ConflictCluster] {
        guard candidates.count >= 2 else { return [] }

        var clusters: [ConflictCluster] = []
        var used: Set<NodeID> = []

        for i in 0 ..< candidates.count {
            guard !used.contains(candidates[i].nodeId) else { continue }
            var clusterIds: Set<NodeID> = []
            var maxScore: Float = candidates[i].score

            for j in (i + 1) ..< candidates.count {
                guard !used.contains(candidates[j].nodeId) else { continue }

                let a = candidates[i]
                let b = candidates[j]

                // Check temporal distance
                let timeDiff = abs(a.timestamp.timeIntervalSince(b.timestamp))
                guard timeDiff > temporalThreshold else { continue }

                // Check Jaccard overlap
                let intersection = a.tokens.intersection(b.tokens)
                let union = a.tokens.union(b.tokens)
                guard !union.isEmpty else { continue }
                let jaccard = Double(intersection.count) / Double(union.count)
                guard jaccard > overlapThreshold else { continue }

                clusterIds.insert(a.nodeId)
                clusterIds.insert(b.nodeId)
                maxScore = max(maxScore, b.score)
            }

            if clusterIds.count >= 2 {
                clusters.append(ConflictCluster(nodeIds: clusterIds, maxScore: maxScore))
                used.formUnion(clusterIds)
            }
        }

        return clusters
    }

    /// Check whether a query asks about current state (triggering conflict resolution).
    ///
    /// Looks for present-tense state markers: "what is", "where", "current", "now", "latest".
    public static func isCurrentStateQuery(_ query: String) -> Bool {
        let lower = query.lowercased()
        let markers = [
            "what is",
            "what's",
            "where do",
            "where is",
            "current",
            "currently",
            "now",
            "latest",
            "right now",
            "at the moment",
            "these days",
        ]
        return markers.contains { lower.contains($0) }
    }
}
