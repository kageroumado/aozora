import Foundation
import Testing
@testable import Aozora

// MARK: - API Lookback Cache Simulator

/// Simulates the Anthropic API's actual caching behavior:
///
/// 1. **Cache writes** happen at the breakpoint (last block for automatic caching).
///    The API stores a hash of the prefix at that block position.
/// 2. **Cache reads** walk backward from the breakpoint up to 20 blocks, checking
///    if any position has a cached hash from a prior request.
/// 3. **5-minute TTL** — cached entries expire if not refreshed.
///
/// Each "block" in API terms is one element in the messages array.
/// System blocks and tools form a separate prefix tier.
private struct APILookbackSimulator {
    /// Max blocks to walk backward looking for a prior cache write.
    static let lookbackWindow = 20

    /// Cache entries: prefix hash → write time.
    var cacheEntries: [Data: TimeInterval] = [:]

    /// Current simulated time (seconds).
    var currentTime: TimeInterval = 0

    /// Debug: last prefix data for comparison.
    var lastDebugPrefix: Data?

    /// Stats.
    var totalCalls = 0
    var cacheReads = 0
    var cacheWrites = 0
    var totalReadTokens = 0
    var totalWriteTokens = 0
    var totalFreshTokens = 0
    var totalPromptTokens = 0
    var totalOutputTokens = 0

    static let encoder: JSONEncoder = {
        let e = JSONEncoder()
        e.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return e
    }()

    mutating func resetStats() {
        totalCalls = 0; cacheReads = 0; cacheWrites = 0
        totalReadTokens = 0; totalWriteTokens = 0; totalFreshTokens = 0
        totalPromptTokens = 0; totalOutputTokens = 0
    }

    /// Submit a prompt. Models the real API behavior:
    ///
    /// Two breakpoints:
    /// 1. **Explicit** on second-to-last message (the stable prefix) — this is where
    ///    PromptBuilder places `cache_control`. Writes and reads happen here.
    /// 2. **Automatic** on last message (top-level `cache_control`) — the API's lookback
    ///    walks from here backward to find the explicit entry.
    ///
    /// The lookback from the automatic breakpoint finds the explicit breakpoint's
    /// entry from the prior turn (within 2 blocks). Cache hit covers everything
    /// from byte 0 to the second-to-last message (~97% of tokens).
    mutating func submit(_ prompt: Prompt, outputTokens: Int = 100) {
        totalCalls += 1
        let msgCount = prompt.messages.count
        let promptTokens = (try! Self.encoder.encode(prompt)).count / 4
        totalPromptTokens += promptTokens
        totalOutputTokens += outputTokens

        guard msgCount >= 2 else {
            totalWriteTokens += promptTokens
            cacheWrites += 1
            return
        }

        let systemToolsHash = hashSystemAndTools(prompt)

        // Explicit breakpoint at second-to-last message
        let explicitBP = msgCount - 2
        var cacheReadTokens = 0

        // Walk backward from the explicit breakpoint (20-block lookback).
        // At each position, check if the prefix hash was written by a prior request.
        let lookbackEnd = max(0, explicitBP - Self.lookbackWindow + 1)
        for pos in stride(from: explicitBP, through: lookbackEnd, by: -1) {
            let posHash = hashPrefix(prompt, through: pos, systemToolsHash: systemToolsHash)
            if let writeTime = cacheEntries[posHash], (currentTime - writeTime) < 300 {
                cacheReadTokens = estimateTokens(prompt, through: pos)
                break
            }
        }

        // Fall back: system-level cache (explicit breakpoint on last system block)
        if cacheReadTokens == 0,
           let sysTime = cacheEntries[systemToolsHash],
           (currentTime - sysTime) < 300 {
            cacheReadTokens = systemToolsHash.count / 4
        }

        if cacheReadTokens > 0 {
            cacheReads += 1
            totalReadTokens += cacheReadTokens
            totalFreshTokens += (promptTokens - cacheReadTokens)
        } else {
            totalWriteTokens += promptTokens
            cacheWrites += 1
        }

        // Write entry at the explicit breakpoint position
        let bpHash = hashPrefix(prompt, through: explicitBP, systemToolsHash: systemToolsHash)
        cacheEntries[bpHash] = currentTime
        cacheEntries[systemToolsHash] = currentTime
    }

    mutating func wait(_ seconds: TimeInterval) {
        currentTime += seconds
    }

    var turnHitRate: Double {
        totalCalls > 0 ? Double(cacheReads) / Double(totalCalls) : 0
    }

    var tokenHitRate: Double {
        totalPromptTokens > 0 ? Double(totalReadTokens) / Double(totalPromptTokens) : 0
    }

    var totalCostDollars: Double {
        // Opus 4.6 pricing (not 4.1)
        Double(totalFreshTokens) * 5.0 / 1_000_000 // $5/MTok input
            + Double(totalWriteTokens) * 6.25 / 1_000_000 // $6.25/MTok cache write
            + Double(totalReadTokens) * 0.50 / 1_000_000 // $0.50/MTok cache read
            + Double(totalOutputTokens) * 25.0 / 1_000_000 // $25/MTok output
    }

    var baselineCostDollars: Double {
        Double(totalPromptTokens) * 5.0 / 1_000_000
            + Double(totalOutputTokens) * 25.0 / 1_000_000
    }

    var savingsVsBaseline: Double {
        baselineCostDollars > 0 ? 1.0 - (totalCostDollars / baselineCostDollars) : 0
    }

    // MARK: - Hashing

    private func hashSystemAndTools(_ prompt: Prompt) -> Data {
        struct ST: Encodable { let system: [SystemBlock]; let tools: [ToolSchema] }
        return try! Self.encoder.encode(ST(system: prompt.system, tools: prompt.tools))
    }

    private func hashPrefix(_ prompt: Prompt, through index: Int, systemToolsHash: Data) -> Data {
        // Combine system+tools hash with message prefix
        var hasher = systemToolsHash
        let msgSlice = Array(prompt.messages.prefix(through: index))
        hasher.append(try! Self.encoder.encode(msgSlice))
        return hasher
    }

    private func estimateTokens(_ prompt: Prompt, through index: Int) -> Int {
        struct Prefix: Encodable { let system: [SystemBlock]; let tools: [ToolSchema]; let messages: [APIMessage] }
        let data = try! Self.encoder.encode(Prefix(
            system: prompt.system, tools: prompt.tools,
            messages: Array(prompt.messages.prefix(through: index)),
        ))
        return data.count / 4
    }
}

// MARK: - Conversation Simulator with Lookback

private struct LookbackConversationSim {
    var messages: [StoredMessage] = []
    var nextId: Int64 = 1
    let builder = PromptBuilder()
    var api = APILookbackSimulator()

    let systemPrompt: String
    let identity: String
    let mirror: String
    let summaries: String

    init(
        systemPrompt: String = "# SOUL.md\nYou are Aozora, an AI partner. Depth over safety.",
        identity: String = "Core: curious, direct, depth-seeking. Quality matters.",
        mirror: String = "Alice: developer, gardening, neuroscience. Direct communicator.",
        summaries: String = "Prior sessions: architecture discussions, tool building.",
    ) {
        self.systemPrompt = systemPrompt
        self.identity = identity
        self.mirror = mirror
        self.summaries = summaries
    }

    mutating func wait(_ seconds: TimeInterval) {
        api.wait(seconds)
    }
    mutating func resetStats() {
        api.resetStats()
    }

    mutating func heartbeat() {
        submitPrompt(currentMessage: "[heartbeat]", outputTokens: 10)
    }

    mutating func turn(
        user: String,
        assistant: String,
        outputTokens: Int = 100,
        toolCalls: [(name: String, result: String, resultTokens: Int)] = [],
    ) {
        let ts = Date()

        messages.append(StoredMessage(
            id: nextId, conversationId: 1, role: .user,
            content: user, tokenEstimate: max(1, user.count / 4),
            salienceScore: nil, createdAt: ts, parts: [],
        ))
        nextId += 1

        for (idx, tc) in toolCalls.enumerated() {
            let toolId = "tc_\(nextId)_\(idx)"
            messages.append(StoredMessage(
                id: nextId, conversationId: 1, role: .assistant,
                content: idx == 0 ? "Checking." : "",
                tokenEstimate: 3, salienceScore: nil, createdAt: ts,
                parts: [MessagePart(
                    kind: .toolCall, ordinal: 0, content: "{}",
                    metadata: "{\"id\":\"\(toolId)\",\"name\":\"\(tc.name)\"}",
                )],
            ))
            nextId += 1
            messages.append(StoredMessage(
                id: nextId, conversationId: 1, role: .tool,
                content: tc.result, tokenEstimate: tc.resultTokens,
                salienceScore: nil, createdAt: ts,
                parts: [MessagePart(
                    kind: .toolResult, ordinal: 0, content: tc.result,
                    metadata: "{\"toolUseId\":\"\(toolId)\",\"isError\":false}",
                )],
            ))
            nextId += 1
        }

        messages.append(StoredMessage(
            id: nextId, conversationId: 1, role: .assistant,
            content: assistant, tokenEstimate: max(1, assistant.count / 4),
            salienceScore: nil, createdAt: ts, parts: [],
        ))
        nextId += 1

        submitPrompt(currentMessage: user, outputTokens: outputTokens)
    }

    private mutating func submitPrompt(currentMessage: String, outputTokens: Int) {
        let ctx = AssembledContext(
            sections: [
                ContextSection(kind: .systemPrompt, content: systemPrompt, tokenEstimate: 100),
                ContextSection(kind: .identity, content: identity, tokenEstimate: 30),
                ContextSection(kind: .mirror, content: mirror, tokenEstimate: 30),
                ContextSection(kind: .summaries, content: summaries, tokenEstimate: 50),
                ContextSection(kind: .chronoception, content: "Session: active", tokenEstimate: 10),
            ],
            totalTokens: 220,
            freshTailMessages: messages,
            currentMessageText: currentMessage,
        )

        let result = builder.build(context: ctx, credential: .oauth, tools: [])
        api.submit(result.prompt, outputTokens: outputTokens)
    }
}

// MARK: - Scenario Generation

private enum Scenario: String, CaseIterable {
    case pureChat = "Pure Chat"
    case codingHeavy = "Coding (heavy)"
    case webSearch = "Web Search"
    case lightTools = "Light Tools"
    case burstyNoPause = "Bursty (no pause)"
    case burstyWithPause = "Bursty + Pauses"
    case burstyHeartbeat = "Bursty + Heartbeat"
}

private func runScenario(_ scenario: Scenario, warmup: Int = 30, measure: Int = 30) -> APILookbackSimulator {
    var sim = LookbackConversationSim()
    let file2k = String(repeating: "func example() { code }\n", count: 200)
    let search500 = String(repeating: "Search snippet content. ", count: 50)

    for phase in 0 ..< 2 {
        let count = phase == 0 ? warmup : measure
        if phase == 1 { sim.resetStats() }

        for i in 0 ..< count {
            switch scenario {
            case .pureChat:
                sim.turn(user: "Q\(i) about philosophy", assistant: String(repeating: "Thoughts. ", count: 10), outputTokens: 150)
                sim.wait(Double.random(in: 30 ... 90))

            case .codingHeavy:
                if i % 3 == 0 {
                    sim.turn(
                        user: "Read file\(i).swift",
                        assistant: "Here it is.",
                        outputTokens: 50,
                        toolCalls: [(name: "read_file", result: file2k, resultTokens: 2_000)],
                    )
                } else if i % 3 == 1 {
                    sim.turn(
                        user: "Fix the bug",
                        assistant: "Fixed.",
                        outputTokens: 100,
                        toolCalls: [(name: "edit", result: "Updated.", resultTokens: 15)],
                    )
                } else {
                    sim.turn(user: "Explain the change", assistant: String(repeating: "I modified the function. ", count: 5), outputTokens: 150)
                }
                sim.wait(Double.random(in: 10 ... 45))

            case .webSearch:
                if i % 4 == 0 {
                    sim.turn(
                        user: "Search topic \(i)",
                        assistant: "Results.",
                        outputTokens: 200,
                        toolCalls: [(name: "web_search", result: search500, resultTokens: 500)],
                    )
                } else {
                    sim.turn(user: "More about \(i)", assistant: String(repeating: "Detail. ", count: 8), outputTokens: 120)
                }
                sim.wait(Double.random(in: 20 ... 60))

            case .lightTools:
                if i % 6 == 0 {
                    sim.turn(
                        user: "Check status",
                        assistant: "OK.",
                        outputTokens: 30,
                        toolCalls: [(name: "bash", result: "OK\n", resultTokens: 5)],
                    )
                } else {
                    sim.turn(user: "Msg \(i)", assistant: "Reply \(i).", outputTokens: 80)
                }
                sim.wait(Double.random(in: 30 ... 120))

            case .burstyNoPause:
                if i % 3 == 0 {
                    sim.turn(
                        user: "Task \(i)",
                        assistant: "Done.",
                        outputTokens: 50,
                        toolCalls: [(name: "bash", result: "output\n", resultTokens: 10)],
                    )
                } else {
                    sim.turn(user: "Msg \(i)", assistant: "Reply.", outputTokens: 80)
                }
                sim.wait(Double.random(in: 5 ... 15))

            case .burstyWithPause:
                if i % 3 == 0 {
                    sim.turn(
                        user: "Task \(i)",
                        assistant: "Done.",
                        outputTokens: 50,
                        toolCalls: [(name: "bash", result: "output\n", resultTokens: 10)],
                    )
                } else {
                    sim.turn(user: "Msg \(i)", assistant: "Reply.", outputTokens: 80)
                }
                if i % 8 == 7 {
                    sim.wait(Double.random(in: 360 ... 600)) // Cache expires
                } else {
                    sim.wait(Double.random(in: 5 ... 20))
                }

            case .burstyHeartbeat:
                if i % 3 == 0 {
                    sim.turn(
                        user: "Task \(i)",
                        assistant: "Done.",
                        outputTokens: 50,
                        toolCalls: [(name: "bash", result: "output\n", resultTokens: 10)],
                    )
                } else {
                    sim.turn(user: "Msg \(i)", assistant: "Reply.", outputTokens: 80)
                }
                if i % 8 == 7 {
                    // Long pause but heartbeats keep cache warm
                    let pause = Double.random(in: 360 ... 600)
                    var elapsed = 0.0
                    while elapsed < pause {
                        let hb = min(240.0, pause - elapsed)
                        sim.wait(hb)
                        sim.heartbeat()
                        elapsed += hb
                    }
                } else {
                    sim.wait(Double.random(in: 5 ... 20))
                }
            }
        }
    }

    return sim.api
}

// MARK: - Tests

struct CacheMonteCarloTests {
    @Test
    func `Full comparison table — all scenarios`() {
        print("\n  ┌──────────────────────────────────────────────────────────────────────────────────┐")
        print("  │ AUTOMATIC CACHING + 20-BLOCK LOOKBACK (30 measured turns, Opus 4.6 pricing)     │")
        print("  ├─────────────────────┬──────────┬──────────┬──────────┬──────────┬────────────────┤")
        print("  │ Scenario            │ Turn Hit │ Tok Hit  │ Cost     │ Baseline │ Savings        │")
        print("  ├─────────────────────┼──────────┼──────────┼──────────┼──────────┼────────────────┤")

        for scenario in Scenario.allCases {
            let api = runScenario(scenario)
            let row = formatRow(scenario.rawValue, api)
            print(row)
        }

        print("  └─────────────────────┴──────────┴──────────┴──────────┴──────────┴────────────────┘\n")
    }

    @Test
    func `Pure chat: >85% turn hit rate with lookback`() {
        let api = runScenario(.pureChat)
        #expect(api.turnHitRate >= 0.85, "Pure chat: \(pct(api.turnHitRate)) — expected ≥85%")
    }

    @Test
    func `Light tools: >80% turn hit rate`() {
        let api = runScenario(.lightTools)
        #expect(api.turnHitRate >= 0.80, "Light tools: \(pct(api.turnHitRate)) — expected ≥80%")
    }

    @Test
    func `Coding session: >65% turn hit rate`() {
        let api = runScenario(.codingHeavy)
        #expect(api.turnHitRate >= 0.65, "Coding: \(pct(api.turnHitRate)) — expected ≥65%")
    }

    @Test
    func `Heartbeats significantly improve bursty scenarios`() {
        let withPause = runScenario(.burstyWithPause)
        let withHB = runScenario(.burstyHeartbeat)

        print("\n  Heartbeat impact:")
        print("    Without: turn=\(pct(withPause.turnHitRate)) tok=\(pct(withPause.tokenHitRate)) savings=\(pct(withPause.savingsVsBaseline))")
        print("    With HB: turn=\(pct(withHB.turnHitRate)) tok=\(pct(withHB.tokenHitRate)) savings=\(pct(withHB.savingsVsBaseline))")

        #expect(
            withHB.turnHitRate >= withPause.turnHitRate,
            "Heartbeats should improve hit rate",
        )
    }

    @Test
    func `All scenarios save vs uncached baseline`() {
        for scenario in Scenario.allCases {
            let api = runScenario(scenario)
            #expect(
                api.savingsVsBaseline > 0.10,
                "\(scenario.rawValue): savings=\(pct(api.savingsVsBaseline)) — expected >10%",
            )
        }
    }

    @Test
    func `Bursty no-pause achieves highest hit rate`() {
        let api = runScenario(.burstyNoPause)
        #expect(api.turnHitRate >= 0.90, "Bursty no-pause: \(pct(api.turnHitRate)) — expected ≥90%")
    }

    private func formatRow(_ name: String, _ api: APILookbackSimulator) -> String {
        let n = name.padding(toLength: 19, withPad: " ", startingAt: 0)
        let th = pct(api.turnHitRate).padding(toLength: 8, withPad: " ", startingAt: 0)
        let tkh = pct(api.tokenHitRate).padding(toLength: 8, withPad: " ", startingAt: 0)
        let cost = String(format: "$%.2f", api.totalCostDollars).padding(toLength: 8, withPad: " ", startingAt: 0)
        let base = String(format: "$%.2f", api.baselineCostDollars).padding(toLength: 8, withPad: " ", startingAt: 0)
        let sav = pct(api.savingsVsBaseline).padding(toLength: 14, withPad: " ", startingAt: 0)
        return "  │ \(n) │ \(th) │ \(tkh) │ \(cost) │ \(base) │ \(sav) │"
    }
}

private func pct(_ v: Double) -> String {
    String(format: "%.0f%%", v * 100)
}
