import Foundation
@testable import Aozora

/// Minimal mock implementing ``MemoryStoring`` for coordinator and gateway tests.
///
/// Tracks call counts and allows configuring return values. Thread-safe via actor isolation.
actor MockMemoryStore: MemoryStoring {
    /// Number of times ``ingest(_:response:)`` or ``ingestTurn(...)`` was called.
    private(set) var ingestCallCount = 0

    /// Number of times ``retrieve(query:salienceBoost:limit:)`` was called.
    private(set) var retrieveCallCount = 0

    /// Configurable retrieval result (defaults to empty).
    var stubbedRetrievalResult = MemoryRetrievalResult(summaries: [], freshTail: [], totalTokens: 0)

    /// Configurable fresh tail (defaults to empty).
    var stubbedFreshTail: [StoredMessage] = []

    func ingest(_: InboundMessage, response _: AssistantResponse) async {
        ingestCallCount += 1
    }

    func ingestTurn(
        userMessage _: InboundMessage,
        toolHistory _: [ToolTurnRecord],
        finalResponse _: AssistantResponse,
        sessionKey _: String,
        userKey _: String,
    ) async {
        ingestCallCount += 1
    }

    func ingestBatch(_: [StoredMessage]) async {}

    func retrieve(query _: String, salienceBoost _: SalienceEnvelope, limit _: Int) async -> MemoryRetrievalResult {
        retrieveCallCount += 1
        return stubbedRetrievalResult
    }

    func grep(pattern _: String, mode _: GrepMode, scope _: GrepScope) async -> [GrepMatch] {
        []
    }

    func describe(id: NodeOrFileID) async -> NodeDescription {
        NodeDescription(
            nodeId: id,
            kind: .rawTurn,
            depth: 0,
            tokenCount: 0,
            canonicalText: nil,
            summaryText: nil,
            expandFooter: nil,
            earliestAt: Date(),
            latestAt: Date(),
            childIds: [],
        )
    }

    func expand(nodeIds _: [NodeID], tokenBudget _: Int) async -> ExpansionResult {
        ExpansionResult(nodes: [], totalTokens: 0, truncated: false)
    }

    func createDelegationGrant(scope _: DelegationScope) async -> DelegationGrant {
        DelegationGrant(
            grantId: UUID().uuidString,
            conversationScope: .all,
            tokenCap: CIMSDefaults.workerDefaultBudget,
            tokensUsed: 0,
            operations: [.grep, .describe, .expand],
            createdAt: Date(),
            expiresAt: Date().addingTimeInterval(300),
            revokedAt: nil,
            workerRunId: nil,
        )
    }

    func revokeDelegationGrant(_: GrantID) async {}

    func retrieveLargeFile(id _: String) async throws -> String? {
        nil
    }

    func retrieveFrontier() async -> MemoryRetrievalResult {
        stubbedRetrievalResult
    }

    func compactIfNeeded() async {}
    func compactFull() async {}
    func decayHotness() async {}
    func demoteColdNodes() async {}
    func scanForBumps(since _: Date) async -> [BumpCandidate] {
        []
    }

    func freshTail(count _: Int, for _: ConversationID) async -> [StoredMessage] {
        stubbedFreshTail
    }
    func summaries(for _: ConversationID, tokenBudget _: Int) async -> [SummaryNode] {
        []
    }
}
