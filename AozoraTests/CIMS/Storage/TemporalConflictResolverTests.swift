import Foundation
import Testing
@testable import Aozora

struct TemporalConflictResolverTests {
    @Test
    func `detects overlapping content across time periods`() {
        let nodeA = ConflictCandidate(
            nodeId: "a", tokens: Set(["moved", "tokyo", "job"]),
            timestamp: Date().addingTimeInterval(-60 * 86_400), score: 0.8,
        )
        let nodeB = ConflictCandidate(
            nodeId: "b", tokens: Set(["moved", "berlin", "tokyo", "didn't"]),
            timestamp: Date().addingTimeInterval(-20 * 86_400), score: 0.7,
        )

        let clusters = TemporalConflictResolver.detectConflicts([nodeA, nodeB])
        #expect(clusters.count == 1)
        #expect(clusters[0].nodeIds.count == 2)
    }

    @Test
    func `no overlap means no conflict`() {
        let nodeA = ConflictCandidate(
            nodeId: "a", tokens: Set(["swift", "concurrency", "actor"]),
            timestamp: Date().addingTimeInterval(-30 * 86_400), score: 0.8,
        )
        let nodeB = ConflictCandidate(
            nodeId: "b", tokens: Set(["recipe", "pasta", "dinner"]),
            timestamp: Date().addingTimeInterval(-5 * 86_400), score: 0.7,
        )

        let clusters = TemporalConflictResolver.detectConflicts([nodeA, nodeB])
        #expect(clusters.isEmpty)
    }

    @Test
    func `nodes within 24h are not conflicting`() {
        let nodeA = ConflictCandidate(
            nodeId: "a", tokens: Set(["moved", "tokyo"]),
            timestamp: Date().addingTimeInterval(-30 * 86_400), score: 0.8,
        )
        let nodeB = ConflictCandidate(
            nodeId: "b", tokens: Set(["moved", "tokyo", "apartment"]),
            timestamp: Date().addingTimeInterval(-30 * 86_400 + 3_600), score: 0.7,
        )

        let clusters = TemporalConflictResolver.detectConflicts([nodeA, nodeB])
        #expect(clusters.isEmpty)
    }

    @Test
    func `query with current-state markers triggers resolution`() {
        #expect(TemporalConflictResolver.isCurrentStateQuery("where do I live now?"))
        #expect(TemporalConflictResolver.isCurrentStateQuery("what is my current role?"))
        #expect(!TemporalConflictResolver.isCurrentStateQuery("tell me about the history of this project"))
    }

    @Test
    func `contentTokens filters stop words`() {
        let tokens = TemporalConflictResolver.contentTokens("I moved to Tokyo for the new job")
        #expect(tokens.contains("moved"))
        #expect(tokens.contains("tokyo"))
        #expect(tokens.contains("job"))
        #expect(!tokens.contains("the"))
        #expect(!tokens.contains("for"))
        #expect(!tokens.contains("to"))
    }

    @Test
    func `single node produces no conflicts`() {
        let node = ConflictCandidate(
            nodeId: "a", tokens: Set(["moved", "tokyo"]),
            timestamp: Date(), score: 0.8,
        )
        let clusters = TemporalConflictResolver.detectConflicts([node])
        #expect(clusters.isEmpty)
    }
}
