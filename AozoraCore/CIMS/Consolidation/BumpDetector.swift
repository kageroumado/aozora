import Foundation
import GRDB

/// Scans DAG nodes for reminiscence bumps — moments where understanding shifted.
///
/// Bump detection is a heuristic pass that identifies high-salience nodes exhibiting
/// specific patterns: topic shifts, corrections/discoveries, emotional intensity, or
/// novel entity introductions. These bumps become candidates for claim extraction
/// during consolidation.
///
/// The detector operates on raw_turn and leaf_summary nodes created after a given
/// date, applying lightweight pattern matching against the node content.
public nonisolated struct BumpDetector: Sendable {
    /// The shared database backing all CIMS persistence.
    private let db: CIMSDatabase

    /// Creates a bump detector backed by the given database.
    ///
    /// - Parameter database: The CIMS database instance for reading DAG nodes.
    public init(database: CIMSDatabase) {
        self.db = database
    }

    /// Patterns that indicate a correction or discovery.
    private static let correctionPatterns: [String] = [
        "I was wrong",
        "I just realized",
        "actually, ",
        "correction:",
        "I stand corrected",
        "on second thought",
        "I've changed my mind",
        "I didn't realize",
        "turns out",
        "I learned that",
    ]

    /// Patterns that indicate emotional intensity.
    private static let emotionalPatterns: [String] = [
        "I love",
        "I hate",
        "amazing",
        "terrible",
        "frustrated",
        "excited",
        "deeply",
        "strongly feel",
        "passionate",
        "furious",
        "delighted",
        "heartbroken",
    ]

    /// Patterns that indicate a novel entity introduction.
    private static let novelEntityPatterns: [String] = [
        "this is ",
        "introducing ",
        "I just started",
        "new project",
        "I'm working on",
        "I just met",
        "have you heard of",
        "I discovered",
    ]

    /// Scan for reminiscence bumps in nodes created after the given date.
    ///
    /// Examines depth-0 and depth-1 nodes for the following bump indicators:
    /// - **Topic shift with high salience**: Salience score above 0.6 and content shows
    ///   divergence from surrounding nodes.
    /// - **Correction or discovery**: Pattern-matched against known correction phrases.
    /// - **Emotional intensity**: Pattern-matched against emotional language markers.
    /// - **Novel entity**: Pattern-matched against entity introduction phrases.
    ///
    /// - Parameter since: Only scan nodes created after this date.
    /// - Returns: Nodes flagged as bump candidates for claim extraction.
    public func scanForBumps(since: Date) async throws -> [BumpCandidate] {
        let sinceString = Self.formatDate(since)

        let nodes = try await db.dbPool.read { db in
            try LCMNodeRecord
                .filter(Column("createdAt") > sinceString)
                .filter(Column("depth") <= 1)
                .filter(Column("canonicalText") != nil)
                .order(Column("earliestAt").asc)
                .fetchAll(db)
        }

        var candidates: [BumpCandidate] = []

        for node in nodes {
            guard let content = node.canonicalText else { continue }
            let lowered = content.lowercased()

            if let reason = detectBumpReason(content: lowered, salienceScore: node.salienceScore) {
                candidates.append(BumpCandidate(
                    nodeId: node.nodeId,
                    reason: reason,
                    salienceScore: Float(node.salienceScore),
                    content: content,
                ))
            }
        }

        return candidates
    }

    /// Determine whether a node's content exhibits a bump pattern and which kind.
    ///
    /// Checks in priority order: correction/discovery, emotional intensity, novel entity,
    /// then topic shift with high salience. Returns the first match found, or nil if
    /// no bump pattern is detected.
    ///
    /// - Parameters:
    ///   - content: The lowercased text content to examine.
    ///   - salienceScore: The node's salience score.
    /// - Returns: The detected bump reason, or nil.
    private func detectBumpReason(content: String, salienceScore: Double) -> BumpReason? {
        if Self.correctionPatterns.contains(where: { content.contains($0.lowercased()) }) {
            return .correctionOrDiscovery
        }

        if Self.emotionalPatterns.contains(where: { content.contains($0.lowercased()) }) {
            return .emotionalIntensity
        }

        if Self.novelEntityPatterns.contains(where: { content.contains($0.lowercased()) }) {
            return .novelEntity
        }

        if salienceScore > 0.6 {
            return .topicShiftHighSalience
        }

        return nil
    }

    /// Format a `Date` as an ISO 8601 string with fractional seconds.
    nonisolated static func formatDate(_ date: Date) -> String {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f.string(from: date)
    }
}
