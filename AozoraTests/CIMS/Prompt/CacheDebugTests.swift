import Foundation
import Testing
@testable import Aozora

private let encoder: JSONEncoder = {
    let e = JSONEncoder()
    e.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
    return e
}()

private struct PK: Encodable {
    let system: [SystemBlock]
    let tools: [ToolSchema]
    let messages: [APIMessage]
}

struct CacheDebugTests {
    @Test
    func `Messages at same position identical between turns`() throws {
        var stored: [StoredMessage] = []
        var nextId: Int64 = 1
        let builder = PromptBuilder()
        let enc = JSONEncoder()
        enc.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]

        for i in 0 ..< 10 {
            stored.append(StoredMessage(id: nextId, conversationId: 1, role: .user, content: "Q\(i)", tokenEstimate: 5, salienceScore: nil, createdAt: Date(), parts: []))
            nextId += 1
            stored.append(StoredMessage(id: nextId, conversationId: 1, role: .assistant, content: "A\(i)", tokenEstimate: 5, salienceScore: nil, createdAt: Date(), parts: []))
            nextId += 1
        }

        let ctx1 = AssembledContext(
            sections: [ContextSection(kind: .systemPrompt, content: "Sys.", tokenEstimate: 10)],
            totalTokens: 50, freshTailMessages: stored, currentMessageText: "Cur1",
        )
        let r1 = builder.build(context: ctx1, credential: .oauth, tools: [])

        stored.append(StoredMessage(id: nextId, conversationId: 1, role: .user, content: "Q10", tokenEstimate: 5, salienceScore: nil, createdAt: Date(), parts: []))
        nextId += 1
        stored.append(StoredMessage(id: nextId, conversationId: 1, role: .assistant, content: "A10", tokenEstimate: 5, salienceScore: nil, createdAt: Date(), parts: []))
        nextId += 1

        let ctx2 = AssembledContext(
            sections: [ContextSection(kind: .systemPrompt, content: "Sys.", tokenEstimate: 10)],
            totalTokens: 50, freshTailMessages: stored, currentMessageText: "Cur2",
        )
        let r2 = builder.build(context: ctx2, credential: .oauth, tools: [])

        let lastStable = r1.prompt.messages.count - 2
        print("  r1: \(r1.prompt.messages.count) msgs, r2: \(r2.prompt.messages.count) msgs, comparing 0...\(lastStable)")

        for i in 0 ... lastStable {
            let m1 = try enc.encode(r1.prompt.messages[i])
            let m2 = try enc.encode(r2.prompt.messages[i])
            if m1 != m2 {
                let s1 = try #require(String(data: m1.prefix(120), encoding: .utf8))
                let s2 = try #require(String(data: m2.prefix(120), encoding: .utf8))
                print("  DIFF at position \(i):\n    r1: \(s1)\n    r2: \(s2)")
            }
        }

        // The second-to-last message in r1 should equal the same position in r2
        let m1Last = try enc.encode(r1.prompt.messages[lastStable])
        let m2Same = try enc.encode(r2.prompt.messages[lastStable])
        #expect(m1Last == m2Same, "Position \(lastStable) should be identical between turns")
    }

    @Test
    func `Prefix at prior BP position matches across 12 turns`() throws {
        var messages: [StoredMessage] = []
        var nextId: Int64 = 1
        let builder = PromptBuilder()

        for i in 0 ..< 50 {
            messages.append(StoredMessage(id: nextId, conversationId: 1, role: .user, content: "Q\(i)", tokenEstimate: 5, salienceScore: nil, createdAt: Date(), parts: []))
            nextId += 1
            messages.append(StoredMessage(id: nextId, conversationId: 1, role: .assistant, content: "A\(i)", tokenEstimate: 5, salienceScore: nil, createdAt: Date(), parts: []))
            nextId += 1
        }

        var lastBP: Int?
        var lastPrefixAtBP: Data?
        var hits = 0
        var total = 0

        for i in 50 ..< 62 {
            messages.append(StoredMessage(id: nextId, conversationId: 1, role: .user, content: "Q\(i)", tokenEstimate: 5, salienceScore: nil, createdAt: Date(), parts: []))
            nextId += 1
            messages.append(StoredMessage(id: nextId, conversationId: 1, role: .assistant, content: "A\(i)", tokenEstimate: 5, salienceScore: nil, createdAt: Date(), parts: []))
            nextId += 1

            let ctx = AssembledContext(
                sections: [
                    ContextSection(kind: .systemPrompt, content: "System prompt.", tokenEstimate: 10),
                    ContextSection(kind: .identity, content: "Identity.", tokenEstimate: 5),
                    ContextSection(kind: .chronoception, content: "5min", tokenEstimate: 5),
                ],
                totalTokens: 100,
                freshTailMessages: messages,
                currentMessageText: "Current \(i)",
            )
            let r = builder.build(context: ctx, credential: .oauth, tools: [])
            let bp = r.prompt.messages.count - 2

            // Check: prefix at PRIOR turn's BP position should match
            if let prevBP = lastBP, let prevPrefix = lastPrefixAtBP {
                let currentAtPrev = try encoder.encode(PK(
                    system: r.prompt.system, tools: r.prompt.tools,
                    messages: Array(r.prompt.messages.prefix(through: prevBP)),
                ))
                if currentAtPrev == prevPrefix { hits += 1 }
                total += 1
            }

            lastBP = bp
            lastPrefixAtBP = try encoder.encode(PK(
                system: r.prompt.system, tools: r.prompt.tools,
                messages: Array(r.prompt.messages.prefix(through: bp)),
            ))
        }

        print("  TOTAL: \(hits)/\(total) lookback hits")
        #expect(hits == total, "All \(total) turns should match at prior BP position, got \(hits)")
    }
}
