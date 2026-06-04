import Foundation
import Testing
@testable import Aozora

struct CacheStabilityTests {
    // MARK: - Heartbeat Prefix Stability

    @Test
    func `Heartbeat prompts from same snapshot have identical prefix`() throws {
        let system = [
            SystemBlock(text: "You are Claude Code", cacheControl: nil),
            SystemBlock(text: "SOUL.md content here", cacheControl: .ephemeral),
        ]
        let messages = [
            APIMessage(role: .user, content: .text("Hello")),
            APIMessage(role: .assistant, content: .text("Hi there")),
        ]

        let snapshot = PromptSnapshot(system: system, tools: [], frozenMessages: messages)
        let builder = PromptBuilder()
        let prompt1 = builder.buildHeartbeatPrompt(from: snapshot, temporal: .init(heartbeatCount: 1, now: Date(), idleDuration: .seconds(240), sinceLastTurn: .seconds(240)))
        let prompt2 = builder.buildHeartbeatPrompt(from: snapshot, temporal: .init(heartbeatCount: 2, now: Date(), idleDuration: .seconds(480), sinceLastTurn: .seconds(480)))

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]

        // System blocks identical
        let sys1 = try encoder.encode(prompt1.system)
        let sys2 = try encoder.encode(prompt2.system)
        #expect(sys1 == sys2, "System blocks must match between heartbeats")

        // All messages except the last are identical
        let prefix1 = try encoder.encode(Array(prompt1.messages.dropLast()))
        let prefix2 = try encoder.encode(Array(prompt2.messages.dropLast()))
        #expect(prefix1 == prefix2, "Message prefix must match between heartbeats")

        // Last messages differ (different heartbeat counts)
        let last1 = try encoder.encode(#require(prompt1.messages.last))
        let last2 = try encoder.encode(#require(prompt2.messages.last))
        #expect(last1 != last2, "Heartbeat messages should differ (different counts)")
    }

    @Test
    func `Multiple heartbeats produce identical prefixes`() throws {
        let system = [SystemBlock(text: "system", cacheControl: .ephemeral)]
        let messages = [
            APIMessage(role: .user, content: .text("context")),
            APIMessage(role: .assistant, content: .text("response")),
        ]
        let snapshot = PromptSnapshot(system: system, tools: [], frozenMessages: messages)
        let builder = PromptBuilder()
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]

        var previousPrefix: Data?
        for i in 1 ... 10 {
            let temporal = PromptBuilder.HeartbeatTemporalState(
                heartbeatCount: i, now: Date(), idleDuration: .seconds(i * 240), sinceLastTurn: .seconds(i * 240),
            )
            let prompt = builder.buildHeartbeatPrompt(from: snapshot, temporal: temporal)
            let prefix = try encoder.encode(Array(prompt.messages.dropLast()))
            if let prev = previousPrefix {
                #expect(prefix == prev, "Heartbeat \(i) prefix must match heartbeat \(i - 1)")
            }
            previousPrefix = prefix
        }
    }

    @Test
    func `Frozen prefix matches original turn's messages`() throws {
        let builder = PromptBuilder()

        let sections = [
            ContextSection(kind: .systemPrompt, content: "# SOUL.md\nI am an assistant.", tokenEstimate: 10),
            ContextSection(kind: .identity, content: "identity claims", tokenEstimate: 5),
            ContextSection(kind: .cognitiveState, content: "[Allostasis: active]", tokenEstimate: 5),
            ContextSection(kind: .chronoception, content: "session info", tokenEstimate: 5),
            ContextSection(kind: .temporalGrounding, content: "<now>2026-03-24</now>", tokenEstimate: 5),
        ]
        var tail: [StoredMessage] = []
        for i in 0 ..< 10 {
            tail.append(makeStoredMessage(role: .user, content: "msg \(i)"))
            tail.append(makeStoredMessage(role: .assistant, content: "reply \(i)"))
        }
        let ctx = AssembledContext(
            sections: sections, totalTokens: 500,
            freshTailMessages: tail, currentMessageText: "Hello",
        )

        let result = builder.build(context: ctx, credential: .oauth, tools: [])
        let snapshot = PromptSnapshot.capture(from: result, assistantResponse: "Hi there!")

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]

        // System blocks must be identical between turn and snapshot
        let sysReal = try encoder.encode(result.prompt.system)
        let sysSnap = try encoder.encode(snapshot.system)
        #expect(sysReal == sysSnap, "System blocks must match")

        // Snapshot's frozen messages should start with the turn's messages
        let realMsgs = try encoder.encode(result.prompt.messages)
        let snapPrefix = try encoder.encode(Array(snapshot.frozenMessages.dropLast()))
        #expect(realMsgs == snapPrefix, "Snapshot prefix must match turn's messages")
    }

    // MARK: - Boundary Validity

    @Test
    func `Boundary index is always valid for adversarial message sequences`() {
        let builder = PromptBuilder()

        let sequences: [[StoredMessage]] = [
            [],
            (0 ..< 5).map { makeStoredMessage(role: .user, content: "u\($0)") },
            {
                var msgs: [StoredMessage] = []
                for i in 0 ..< 100 {
                    msgs.append(makeStoredMessage(role: .user, content: "u\(i)"))
                    let toolId = "t\(i)"
                    msgs.append(makeAssistantWithToolCalls(text: "", toolIds: [toolId]))
                    msgs.append(makeToolResult(toolUseId: toolId, content: "result"))
                    msgs.append(makeStoredMessage(role: .assistant, content: "done \(i)"))
                }
                return msgs
            }(),
            (0 ..< 200).map { makeStoredMessage(role: .user, content: "u\($0)") },
        ]

        for (idx, tail) in sequences.enumerated() {
            let ctx = makeContextWithTail(tail, currentMessage: "current")
            let result = builder.build(context: ctx, credential: .apiKey, tools: [])

            if let boundary = result.boundaryMessageIndex {
                #expect(boundary >= 0, "Boundary >= 0 for sequence \(idx)")
                #expect(boundary < result.prompt.messages.count, "Boundary < count for sequence \(idx)")
            }
            for i in 1 ..< result.prompt.messages.count {
                #expect(
                    result.prompt.messages[i].role != result.prompt.messages[i - 1].role,
                    "Messages must alternate at index \(i) for sequence \(idx)",
                )
            }
        }
    }

    // MARK: - Cache Health

    @Test
    func `Cache integrity failure fires when cacheReadTokens is 0 without compaction`() {
        let usage = TokenUsage(inputTokens: 50_000, outputTokens: 100, cacheReadTokens: 0, cacheCreationTokens: 50_000)
        let result = HeartbeatEngine.checkCacheHealth(usage: usage, compactionSinceSnapshot: false)
        #expect(result == .fatal)
    }

    @Test
    func `Cache miss after compaction is warning only`() {
        let usage = TokenUsage(inputTokens: 50_000, outputTokens: 100, cacheReadTokens: 0, cacheCreationTokens: 50_000)
        let result = HeartbeatEngine.checkCacheHealth(usage: usage, compactionSinceSnapshot: true)
        #expect(result == .warning)
    }

    @Test
    func `Healthy cache read is OK`() {
        let usage = TokenUsage(inputTokens: 1_000, outputTokens: 100, cacheReadTokens: 80_000, cacheCreationTokens: 0)
        let result = HeartbeatEngine.checkCacheHealth(usage: usage, compactionSinceSnapshot: false)
        #expect(result == .ok)
    }

    @Test
    func `Low input tokens skip cache assertion`() {
        let usage = TokenUsage(inputTokens: 100, outputTokens: 50, cacheReadTokens: 0, cacheCreationTokens: 0)
        let result = HeartbeatEngine.checkCacheHealth(usage: usage, compactionSinceSnapshot: false)
        #expect(result == .ok)
    }
}

// MARK: - Helpers

private func makeStoredMessage(role: MessageRole, content: String) -> StoredMessage {
    StoredMessage(
        id: Int64.random(in: 1 ... 999_999),
        conversationId: 1,
        role: role,
        content: content,
        tokenEstimate: content.count / 4,
        salienceScore: nil,
        createdAt: Date(),
        parts: [],
    )
}

private func makeAssistantWithToolCalls(text: String, toolIds: [String]) -> StoredMessage {
    let parts = toolIds.enumerated().map { idx, id in
        MessagePart(
            kind: .toolCall,
            ordinal: idx,
            content: "{}",
            metadata: "{\"id\":\"\(id)\",\"name\":\"read_file\"}",
        )
    }
    return StoredMessage(
        id: Int64.random(in: 1 ... 999_999),
        conversationId: 1,
        role: .assistant,
        content: text,
        tokenEstimate: text.count / 4,
        salienceScore: nil,
        createdAt: Date(),
        parts: parts,
    )
}

private func makeToolResult(toolUseId: String, content: String) -> StoredMessage {
    let part = MessagePart(
        kind: .toolResult,
        ordinal: 0,
        content: content,
        metadata: "{\"toolUseId\":\"\(toolUseId)\",\"isError\":false}",
    )
    return StoredMessage(
        id: Int64.random(in: 1 ... 999_999),
        conversationId: 1,
        role: .tool,
        content: content,
        tokenEstimate: content.count / 4,
        salienceScore: nil,
        createdAt: Date(),
        parts: [part],
    )
}

private func makeContextWithTail(
    _ messages: [StoredMessage],
    currentMessage: String? = "Hello",
) -> AssembledContext {
    AssembledContext(
        sections: [ContextSection(kind: .systemPrompt, content: "prompt", tokenEstimate: 10)],
        totalTokens: 100,
        freshTailMessages: messages,
        currentMessageText: currentMessage,
    )
}

// NOTE: ElasticCacheBoundaryTests and APICacheIntegrationTests were removed —
// they tested the old elastic boundary snapping which was replaced by automatic
// caching (top-level cache_control). The new caching model is tested by:
// - CacheAdvancedTests (LookbackWindow, TTL, Aging, Runtime, MultiTurn)
// - CacheMonteCarloTests (full API lookback simulation with TTL)
// - CacheCostModelTests (cost optimization across scenarios)
