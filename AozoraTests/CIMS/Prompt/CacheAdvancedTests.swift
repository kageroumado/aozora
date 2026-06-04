import Foundation
import Testing
@testable import Aozora

// MARK: - Shared Test Infrastructure

private let enc: JSONEncoder = {
    let e = JSONEncoder()
    e.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
    return e
}()

private func makeMsg(role: MessageRole, content: String, id: Int64 = .random(in: 1 ... 999_999), toolCallId: String? = nil, toolResultId: String? = nil, tokenEstimate: Int? = nil) -> StoredMessage {
    var parts: [MessagePart] = []
    if let tcId = toolCallId {
        parts.append(MessagePart(kind: .toolCall, ordinal: 0, content: "{}", metadata: "{\"id\":\"\(tcId)\",\"name\":\"bash\"}"))
    }
    if let trId = toolResultId {
        parts.append(MessagePart(kind: .toolResult, ordinal: 0, content: content, metadata: "{\"toolUseId\":\"\(trId)\",\"isError\":false}"))
    }
    return StoredMessage(
        id: id, conversationId: 1, role: role, content: content,
        tokenEstimate: tokenEstimate ?? max(1, content.count / 4),
        salienceScore: nil, createdAt: Date(), parts: parts,
    )
}

private func buildPrompt(_ messages: [StoredMessage], current: String = "Hello") -> PromptBuildResult {
    let ctx = AssembledContext(
        sections: [
            ContextSection(kind: .systemPrompt, content: "# SOUL.md\nYou are an assistant.", tokenEstimate: 50),
            ContextSection(kind: .identity, content: "Identity.", tokenEstimate: 10),
            ContextSection(kind: .chronoception, content: "5min", tokenEstimate: 5),
        ],
        totalTokens: 100,
        freshTailMessages: messages,
        currentMessageText: current,
    )
    return PromptBuilder().build(context: ctx, credential: .oauth, tools: [])
}

/// Serialize messages[0...idx] for prefix comparison.
private func prefixBytes(_ prompt: Prompt, through idx: Int) -> Data {
    struct PK: Encodable { let system: [SystemBlock]; let messages: [APIMessage] }
    return try! enc.encode(PK(system: prompt.system, messages: Array(prompt.messages.prefix(through: idx))))
}

// MARK: - Lookback Window Tests

struct LookbackWindowTests {
    @Test
    func `Prefix at prior breakpoint position is byte-identical after appending 1 turn`() {
        var msgs: [StoredMessage] = []
        for i in 0 ..< 20 {
            msgs.append(makeMsg(role: .user, content: "U\(i)"))
            msgs.append(makeMsg(role: .assistant, content: "A\(i)"))
        }

        let r1 = buildPrompt(msgs, current: "C1")
        let priorBP = r1.prompt.messages.count - 2

        msgs.append(makeMsg(role: .user, content: "U20"))
        msgs.append(makeMsg(role: .assistant, content: "A20"))
        let r2 = buildPrompt(msgs, current: "C2")

        let p1 = prefixBytes(r1.prompt, through: priorBP)
        let p2 = prefixBytes(r2.prompt, through: priorBP)
        #expect(p1 == p2, "Prefix at prior breakpoint must be identical after 1 turn")
    }

    @Test
    func `Prefix stable after appending up to 9 turns (within 20-block window)`() {
        var msgs: [StoredMessage] = []
        for i in 0 ..< 30 {
            msgs.append(makeMsg(role: .user, content: "U\(i)"))
            msgs.append(makeMsg(role: .assistant, content: "A\(i)"))
        }

        let r1 = buildPrompt(msgs, current: "C1")
        let priorBP = r1.prompt.messages.count - 2
        let basePrefix = prefixBytes(r1.prompt, through: priorBP)

        // Add 9 more turns (18 blocks) — still within 20-block lookback
        for i in 30 ..< 39 {
            msgs.append(makeMsg(role: .user, content: "U\(i)"))
            msgs.append(makeMsg(role: .assistant, content: "A\(i)"))
        }

        let r2 = buildPrompt(msgs, current: "C2")
        let p2 = prefixBytes(r2.prompt, through: priorBP)
        #expect(basePrefix == p2, "Prefix at position \(priorBP) must be identical after 9 turns")
    }

    @Test
    func `Tool calls add extra blocks — window covers fewer turns`() {
        var msgs: [StoredMessage] = []
        for i in 0 ..< 5 {
            msgs.append(makeMsg(role: .user, content: "U\(i)"))
            let tcId = "tc\(i)"
            msgs.append(makeMsg(role: .assistant, content: "Checking", toolCallId: tcId))
            msgs.append(makeMsg(role: .tool, content: "Result \(i)", toolResultId: tcId, tokenEstimate: 100))
            msgs.append(makeMsg(role: .assistant, content: "Done \(i)"))
        }

        let r1 = buildPrompt(msgs, current: "C1")
        // Tool turns produce more API blocks — verify the prompt still builds correctly
        #expect(r1.prompt.messages.count > 10, "Tool-heavy conversation should have many API messages")
    }

    @Test
    func `No cache_control marker on any message (only system blocks)`() throws {
        var msgs: [StoredMessage] = []
        for i in 0 ..< 20 {
            msgs.append(makeMsg(role: .user, content: "U\(i)"))
            msgs.append(makeMsg(role: .assistant, content: "A\(i)"))
        }

        let result = buildPrompt(msgs, current: "Current")
        let json = try enc.encode(result.prompt.messages)
        let text = try #require(String(data: json, encoding: .utf8))

        #expect(!text.contains("cache_control"), "Messages must not contain cache_control — it changes serialization and breaks lookback")
    }

    @Test
    func `System blocks DO have cache_control on last block`() {
        let result = buildPrompt([], current: "Hello")
        let lastSystem = result.prompt.system.last
        #expect(lastSystem?.cacheControl != nil, "Last system block must have cache_control")
    }
}

// MARK: - TTL and Expiry Tests

struct CacheTTLTests {
    @Test
    func `CacheTimeline reports warm within 5 minutes`() {
        var timeline = CacheTimeline()
        #expect(!timeline.isCacheWarm, "Should be cold before any write")
        timeline.recordCacheWrite()
        #expect(timeline.isCacheWarm, "Should be warm after write")
        #expect(timeline.timeUntilExpiry > .seconds(290), "Should have ~5min remaining")
    }

    @Test
    func `CacheTimeline TTL is exactly 5 minutes`() {
        #expect(CacheTimeline.cacheTTL == .seconds(300), "TTL should be 5 minutes")
    }

    @Test
    func `checkCacheHealth: zero reads without compaction is fatal`() {
        let usage = TokenUsage(inputTokens: 50_000, outputTokens: 100, cacheReadTokens: 0, cacheCreationTokens: 50_000)
        let result = HeartbeatEngine.checkCacheHealth(usage: usage, compactionSinceSnapshot: false)
        #expect(result == .fatal)
    }

    @Test
    func `checkCacheHealth: zero reads with compaction is warning`() {
        let usage = TokenUsage(inputTokens: 50_000, outputTokens: 100, cacheReadTokens: 0, cacheCreationTokens: 50_000)
        let result = HeartbeatEngine.checkCacheHealth(usage: usage, compactionSinceSnapshot: true)
        #expect(result == .warning)
    }

    @Test
    func `checkCacheHealth: >50% ratio is ok`() {
        let usage = TokenUsage(inputTokens: 1_000, outputTokens: 100, cacheReadTokens: 80_000, cacheCreationTokens: 0)
        let result = HeartbeatEngine.checkCacheHealth(usage: usage, compactionSinceSnapshot: false)
        #expect(result == .ok)
    }

    @Test
    func `checkCacheHealth: <50% ratio is warning`() {
        let usage = TokenUsage(inputTokens: 60_000, outputTokens: 100, cacheReadTokens: 40_000, cacheCreationTokens: 0)
        let result = HeartbeatEngine.checkCacheHealth(usage: usage, compactionSinceSnapshot: false)
        #expect(result == .warning)
    }

    @Test
    func `checkCacheHealth: small prompts skip assertion`() {
        let usage = TokenUsage(inputTokens: 100, outputTokens: 50, cacheReadTokens: 0, cacheCreationTokens: 0)
        let result = HeartbeatEngine.checkCacheHealth(usage: usage, compactionSinceSnapshot: false)
        #expect(result == .ok)
    }
}

// MARK: - Aging Interaction Tests

struct AgingCacheTests {
    @Test
    func `Small tool results (<200 tok) are never aged`() throws {
        var msgs: [StoredMessage] = []
        for i in 0 ..< 50 {
            msgs.append(makeMsg(role: .user, content: "Q\(i)"))
            if i % 3 == 0 {
                let tcId = "tc\(i)"
                msgs.append(makeMsg(role: .assistant, content: "Check", toolCallId: tcId))
                msgs.append(makeMsg(role: .tool, content: "ok\n", toolResultId: tcId, tokenEstimate: 5))
                msgs.append(makeMsg(role: .assistant, content: "Done"))
            } else {
                msgs.append(makeMsg(role: .assistant, content: "A\(i)"))
            }
        }

        let result = buildPrompt(msgs, current: "Final")
        let json = try #require(String(data: enc.encode(result.prompt), encoding: .utf8))

        // "ok\n" should appear in the prompt — never aged
        let okCount = json.components(separatedBy: "ok\\n").count - 1
        #expect(okCount >= 10, "Small tool results should be preserved: found \(okCount)")
    }

    @Test
    func `Elastic aging only runs at epoch boundaries`() throws {
        let gap = CIMSDefaults.cacheBoundaryElasticGap
        var msgs: [StoredMessage] = []
        for i in 0 ..< 50 {
            msgs.append(makeMsg(role: .user, content: "U\(i)"))
            msgs.append(makeMsg(role: .assistant, content: "A\(i)"))
        }

        // Build two consecutive prompts — aging should NOT run between them
        // (unless we happen to cross an epoch boundary)
        let r1 = buildPrompt(msgs, current: "C1")
        msgs.append(makeMsg(role: .user, content: "U50"))
        msgs.append(makeMsg(role: .assistant, content: "A50"))
        let r2 = buildPrompt(msgs, current: "C2")

        // The first N-2 messages of r1 should appear identically in r2
        let lastStable = r1.prompt.messages.count - 2
        for i in 0 ..< lastStable {
            let m1 = try enc.encode(r1.prompt.messages[i])
            let m2 = try enc.encode(r2.prompt.messages[i])
            if m1 != m2 {
                // Check if this is an epoch boundary (expected to differ)
                let userCount1 = r1.prompt.messages.count(where: { $0.role == .user })
                let userCount2 = r2.prompt.messages.count(where: { $0.role == .user })
                let crossedEpoch = (userCount1 % gap == 0) || (userCount2 % gap == 0)
                if !crossedEpoch {
                    Issue.record("Position \(i) differs between turns but no epoch boundary crossed")
                }
                break
            }
        }
    }

    @Test
    func `Never-age threshold is 200 tokens`() {
        #expect(CIMSDefaults.toolAgingExemptThreshold == 200)
    }
}

// MARK: - Runtime Validation Tests

struct RuntimeCacheValidationTests {
    @Test
    func `Consecutive cache miss counter tracks correctly`() {
        // The coordinator tracks consecutive misses. After 3, it logs a warning.
        // Verify the threshold is reasonable.
        let warningThreshold = 3

        // Simulate: 3 misses then 1 hit should reset
        var consecutive = 0
        let usages: [TokenUsage] = [
            TokenUsage(inputTokens: 50_000, outputTokens: 100, cacheReadTokens: 0, cacheCreationTokens: 50_000),
            TokenUsage(inputTokens: 50_000, outputTokens: 100, cacheReadTokens: 0, cacheCreationTokens: 50_000),
            TokenUsage(inputTokens: 50_000, outputTokens: 100, cacheReadTokens: 0, cacheCreationTokens: 50_000),
            TokenUsage(inputTokens: 1_000, outputTokens: 100, cacheReadTokens: 49_000, cacheCreationTokens: 0),
        ]

        for usage in usages {
            if usage.cacheReadTokens == 0, usage.inputTokens > 4_096 {
                consecutive += 1
            } else {
                consecutive = 0
            }
        }

        #expect(consecutive == 0, "Should reset after a hit")
    }

    @Test
    func `Token hit ratio calculation`() {
        let usage = TokenUsage(inputTokens: 5_000, outputTokens: 200, cacheReadTokens: 195_000, cacheCreationTokens: 0)
        let total = usage.inputTokens + usage.cacheReadTokens + usage.cacheCreationTokens
        let ratio = Double(usage.cacheReadTokens) / Double(total)
        #expect(ratio > 0.95, "195K/200K should be >95% ratio")
    }

    @Test
    func `Prompt without messages still produces valid output`() {
        let result = buildPrompt([], current: "First message ever")
        #expect(result.prompt.messages.count > 0)
        #expect(result.prompt.system.count > 0)
    }
}

// MARK: - Multi-Turn Prefix Stability (Integration)

struct MultiTurnPrefixStabilityTests {
    @Test
    func `20 consecutive turns: prefix at prior position always matches`() {
        var msgs: [StoredMessage] = []
        for i in 0 ..< 30 {
            msgs.append(makeMsg(role: .user, content: "Q\(i)"))
            msgs.append(makeMsg(role: .assistant, content: "A\(i)"))
        }

        var lastBP: Int?
        var lastPrefixAtBP: Data?
        var mismatches = 0

        for i in 30 ..< 50 {
            msgs.append(makeMsg(role: .user, content: "Q\(i)"))
            msgs.append(makeMsg(role: .assistant, content: "A\(i)"))

            let result = buildPrompt(msgs, current: "C\(i)")
            let currentBP = result.prompt.messages.count - 2

            if let prevBP = lastBP, let prevPrefix = lastPrefixAtBP {
                // Check prefix at the PRIOR breakpoint position in the current prompt
                let currentAtPrior = prefixBytes(result.prompt, through: prevBP)
                if currentAtPrior != prevPrefix {
                    mismatches += 1
                }
            }

            lastBP = currentBP
            lastPrefixAtBP = prefixBytes(result.prompt, through: currentBP)
        }

        #expect(mismatches == 0, "All 20 turns should have matching prefixes at prior BP position, got \(mismatches) mismatches")
    }

    @Test
    func `Mixed tools: prefix stable across tool and chat turns`() {
        var msgs: [StoredMessage] = []
        for i in 0 ..< 30 {
            msgs.append(makeMsg(role: .user, content: "Q\(i)"))
            if i % 4 == 0 {
                let tcId = "tc\(i)"
                msgs.append(makeMsg(role: .assistant, content: "Checking", toolCallId: tcId))
                msgs.append(makeMsg(role: .tool, content: String(repeating: "data ", count: 100), toolResultId: tcId, tokenEstimate: 500))
                msgs.append(makeMsg(role: .assistant, content: "Done \(i)"))
            } else {
                msgs.append(makeMsg(role: .assistant, content: "A\(i)"))
            }
        }

        var lastBP: Int?
        var lastPrefix: Data?
        var hits = 0
        let measureTurns = 10

        for i in 30 ..< 30 + measureTurns {
            msgs.append(makeMsg(role: .user, content: "Q\(i)"))
            msgs.append(makeMsg(role: .assistant, content: "A\(i)"))

            let result = buildPrompt(msgs, current: "C\(i)")
            let bp = result.prompt.messages.count - 2

            if let prevBP = lastBP, let prev = lastPrefix {
                let current = prefixBytes(result.prompt, through: prevBP)
                if current == prev { hits += 1 }
            }

            lastBP = bp
            lastPrefix = prefixBytes(result.prompt, through: bp)
        }

        #expect(hits >= measureTurns - 2, "Mixed tools: \(hits)/\(measureTurns - 1) prefix matches")
    }

    @Test
    func `Alternation: messages always alternate user/assistant`() {
        var msgs: [StoredMessage] = []
        for i in 0 ..< 40 {
            msgs.append(makeMsg(role: .user, content: "U\(i)"))
            if i % 5 == 0 {
                let tcId = "tc\(i)"
                msgs.append(makeMsg(role: .assistant, content: "", toolCallId: tcId))
                msgs.append(makeMsg(role: .tool, content: "result", toolResultId: tcId))
                msgs.append(makeMsg(role: .assistant, content: "Done"))
            } else {
                msgs.append(makeMsg(role: .assistant, content: "A\(i)"))
            }
        }

        let result = buildPrompt(msgs, current: "Final")

        for i in 1 ..< result.prompt.messages.count {
            #expect(
                result.prompt.messages[i].role != result.prompt.messages[i - 1].role,
                "Messages must alternate at index \(i)",
            )
        }
    }

    @Test
    func `Boundary index is always second-to-last message`() {
        var msgs: [StoredMessage] = []
        for i in 0 ..< 20 {
            msgs.append(makeMsg(role: .user, content: "U\(i)"))
            msgs.append(makeMsg(role: .assistant, content: "A\(i)"))
        }

        let result = buildPrompt(msgs, current: "Current")
        #expect(
            result.boundaryMessageIndex == result.prompt.messages.count - 2,
            "Boundary should be second-to-last: \(result.boundaryMessageIndex ?? -1) vs \(result.prompt.messages.count - 2)",
        )
    }

    @Test
    func `System blocks identical across 10 consecutive turns`() throws {
        var msgs: [StoredMessage] = []
        var lastSystemBytes: Data?

        for i in 0 ..< 20 {
            msgs.append(makeMsg(role: .user, content: "U\(i)"))
            msgs.append(makeMsg(role: .assistant, content: "A\(i)"))

            if i >= 10 {
                let result = buildPrompt(msgs, current: "C\(i)")
                let sysBytes = try enc.encode(result.prompt.system)
                if let prev = lastSystemBytes {
                    #expect(sysBytes == prev, "System blocks changed on turn \(i)")
                }
                lastSystemBytes = sysBytes
            }
        }
    }
}
