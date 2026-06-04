import Testing
@testable import Aozora

struct RetrievalMergerTests {
    @Test
    func `deduplicates by nodeId and boosts multi-strategy hits`() throws {
        let results: [RetrievalMerger.StrategyResult] = [
            .init(nodeId: "a", score: 0.8, strategy: .keyword),
            .init(nodeId: "a", score: 0.6, strategy: .claim),
            .init(nodeId: "b", score: 0.9, strategy: .keyword),
            .init(nodeId: "c", score: 0.5, strategy: .temporal),
        ]

        let merged = RetrievalMerger.merge(results)

        #expect(merged.count == 3)

        let nodeA = try #require(merged.first { $0.nodeId == "a" })
        #expect(nodeA.strategies.count == 2)
        #expect(abs(nodeA.score - 0.9) < 0.01) // 0.8 + 0.1

        let nodeB = try #require(merged.first { $0.nodeId == "b" })
        #expect(abs(nodeB.score - 0.9) < 0.01) // single strategy, no boost
    }

    @Test
    func `single-strategy results pass through unchanged`() {
        let results: [RetrievalMerger.StrategyResult] = [
            .init(nodeId: "x", score: 0.7, strategy: .keyword),
        ]
        let merged = RetrievalMerger.merge(results)
        #expect(merged.count == 1)
        #expect(abs(merged[0].score - 0.7) < 0.01)
    }

    @Test
    func `empty input returns empty output`() {
        let merged = RetrievalMerger.merge([])
        #expect(merged.isEmpty)
    }

    @Test
    func `triple-strategy boost applies correctly`() {
        let results: [RetrievalMerger.StrategyResult] = [
            .init(nodeId: "x", score: 0.5, strategy: .keyword),
            .init(nodeId: "x", score: 0.6, strategy: .claim),
            .init(nodeId: "x", score: 0.4, strategy: .temporal),
        ]
        let merged = RetrievalMerger.merge(results)
        #expect(merged.count == 1)
        // max(0.5, 0.6, 0.4) + 0.1 * (3-1) = 0.6 + 0.2 = 0.8
        #expect(abs(merged[0].score - 0.8) < 0.01)
        #expect(merged[0].strategies.count == 3)
    }

    @Test
    func `results sorted by merged score descending`() {
        let results: [RetrievalMerger.StrategyResult] = [
            .init(nodeId: "low", score: 0.2, strategy: .keyword),
            .init(nodeId: "high", score: 0.9, strategy: .keyword),
            .init(nodeId: "mid", score: 0.5, strategy: .keyword),
        ]
        let merged = RetrievalMerger.merge(results)
        #expect(merged[0].nodeId == "high")
        #expect(merged[1].nodeId == "mid")
        #expect(merged[2].nodeId == "low")
    }
}
