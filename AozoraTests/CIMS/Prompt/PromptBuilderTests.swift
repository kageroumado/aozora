import Foundation
import Testing
@testable import Aozora

struct PromptBuilderTests {
    let builder = PromptBuilder()

    // MARK: - OAuth / Credential Tests

    @Test
    func `OAuth credential prepends identity prefix without cache_control`() throws {
        let context = makeMinimalContext(systemPrompt: "# SOUL.md\nSystem prompt")
        let prompt = builder.build(context: context, credential: .oauth, tools: []).prompt
        let firstBlock = try #require(prompt.system.first)
        #expect(firstBlock.text == "You are Claude Code, Anthropic's official CLI for Claude.")
        #expect(firstBlock.cacheControl == nil)
    }

    @Test
    func `API key credential does not prepend identity prefix`() throws {
        let context = makeMinimalContext(systemPrompt: "# SOUL.md\nSystem prompt")
        let prompt = builder.build(context: context, credential: .apiKey, tools: []).prompt
        #expect(try !#require(prompt.system.first?.text.contains("Claude Code")))
    }

    // MARK: - Preamble Extraction

    @Test
    func `INTRO.md is extracted as preamble before summaries`() {
        let systemPrompt = "# Context Introduction\nThis is the intro.\n# SOUL.md\nThis is the soul."
        let context = makeMinimalContext(systemPrompt: systemPrompt)
        let prompt = builder.build(context: context, credential: .apiKey, tools: []).prompt
        let texts = prompt.system.map(\.text)
        #expect(texts.contains(where: { $0.contains("Context Introduction") }))
        #expect(texts.contains(where: { $0.hasPrefix("# SOUL.md") }))
    }

    @Test
    func `Preamble block has no cache_control`() {
        let systemPrompt = "# Context Introduction\nIntro text\n# SOUL.md\nSoul"
        let context = makeMinimalContext(systemPrompt: systemPrompt)
        let prompt = builder.build(context: context, credential: .apiKey, tools: []).prompt
        let preambleBlock = prompt.system.first(where: { $0.text.contains("Context Introduction") })
        #expect(preambleBlock?.cacheControl == nil)
    }

    @Test
    func `System prompt without INTRO marker emits full text as block 2`() {
        let systemPrompt = "# SOUL.md\nJust the soul content."
        let context = makeMinimalContext(systemPrompt: systemPrompt)
        let prompt = builder.build(context: context, credential: .apiKey, tools: []).prompt
        let texts = prompt.system.map(\.text)
        #expect(texts.contains(where: { $0.contains("soul content") }))
        #expect(!texts.contains(where: { $0.contains("Context Introduction") }))
    }

    // MARK: - Cache Control

    @Test
    func `Last system block gets cache_control`() {
        let context = makeContextWithSections([
            ContextSection(kind: .systemPrompt, content: "prompt", tokenEstimate: 10),
            ContextSection(kind: .stableSummaries, content: "Condensed old history", tokenEstimate: 100),
        ])
        let prompt = builder.build(context: context, credential: .apiKey, tools: []).prompt
        #expect(prompt.system.last?.cacheControl != nil)
        let stableBlock = prompt.system.first(where: { $0.text.contains("Condensed old history") })
        #expect(stableBlock != nil)
    }

    @Test
    func `System prompt block (block 2) gets cache_control`() {
        let context = makeMinimalContext(systemPrompt: "# SOUL.md\nSystem content")
        let prompt = builder.build(context: context, credential: .apiKey, tools: []).prompt
        let soulBlock = prompt.system.first(where: { $0.text.contains("System content") })
        #expect(soulBlock?.cacheControl != nil)
    }

    @Test
    func `Last system block always gets cache_control`() {
        let context = makeContextWithSections([
            ContextSection(kind: .systemPrompt, content: "prompt", tokenEstimate: 10),
            ContextSection(kind: .recentSummaries, content: "Recent history", tokenEstimate: 50),
        ])
        let prompt = builder.build(context: context, credential: .apiKey, tools: []).prompt
        #expect(prompt.system.last?.cacheControl == .ephemeral)
    }

    @Test
    func `Volatile state is injected into messages not system blocks`() {
        let context = makeContextWithSections([
            ContextSection(kind: .systemPrompt, content: "prompt", tokenEstimate: 10),
            ContextSection(kind: .identity, content: "Identity claims", tokenEstimate: 50),
        ])
        let prompt = builder.build(context: context, credential: .apiKey, tools: []).prompt
        #expect(prompt.system.allSatisfy { !$0.text.contains("Identity claims") })
        let firstUserMsg = prompt.messages.first(where: { $0.role == .user })
        #expect(firstUserMsg != nil)
    }

    // MARK: - Block Ordering

    @Test
    func `System blocks ordered: prefix, preamble, stable, recent, system prompt (last)`() throws {
        let context = makeContextWithSections([
            ContextSection(kind: .stableSummaries, content: "Stable content", tokenEstimate: 100),
            ContextSection(
                kind: .systemPrompt,
                content: "# Context Introduction\nIntro\n# SOUL.md\nSoul content",
                tokenEstimate: 50,
            ),
            ContextSection(kind: .recentSummaries, content: "Recent content", tokenEstimate: 50),
            ContextSection(kind: .identity, content: "Identity content", tokenEstimate: 30),
        ])
        let prompt = builder.build(context: context, credential: .oauth, tools: []).prompt
        let texts = prompt.system.map(\.text)
        let oauthIdx = try #require(texts.firstIndex(where: { $0.contains("Claude Code") }))
        let preambleIdx = try #require(texts.firstIndex(where: { $0.contains("Intro") }))
        let stableIdx = try #require(texts.firstIndex(where: { $0.contains("Stable content") }))
        let recentIdx = try #require(texts.firstIndex(where: { $0.contains("Recent content") }))
        let soulIdx = try #require(texts.firstIndex(where: { $0.contains("Soul content") }))
        #expect(oauthIdx < preambleIdx)
        #expect(preambleIdx < stableIdx)
        #expect(stableIdx < recentIdx)
        #expect(recentIdx < soulIdx)
        // System prompt is last — most important content closest to conversation
        #expect(soulIdx == texts.count - 1)
        // Volatile content (identity) is in messages, not system blocks
        #expect(!texts.contains(where: { $0.contains("Identity content") }))
    }

    // MARK: - Empty Content Skipping

    @Test
    func `Empty sections are skipped`() {
        let context = makeContextWithSections([
            ContextSection(kind: .systemPrompt, content: "# SOUL.md\nSoul", tokenEstimate: 10),
            ContextSection(kind: .stableSummaries, content: "", tokenEstimate: 0),
            ContextSection(kind: .identity, content: "", tokenEstimate: 0),
        ])
        let prompt = builder.build(context: context, credential: .apiKey, tools: []).prompt
        #expect(prompt.system.count == 1)
    }

    // MARK: - Multiple Sections of Same Kind

    @Test
    func `Per-turn sections go in last message, slow-changing in first`() throws {
        // Need at least one exchange so first and last user messages are distinct
        let tail = [
            makeStoredMessage(role: .user, content: "Earlier message"),
            makeStoredMessage(role: .assistant, content: "Earlier reply"),
        ]
        let sections = [
            ContextSection(kind: .systemPrompt, content: "prompt", tokenEstimate: 10),
            ContextSection(kind: .identity, content: "Identity claims", tokenEstimate: 20),
            ContextSection(kind: .cognitiveState, content: "Cognitive info", tokenEstimate: 20),
            ContextSection(kind: .chronoception, content: "Time info", tokenEstimate: 20),
            ContextSection(kind: .temporalGrounding, content: "Grounding info", tokenEstimate: 20),
        ]
        let context = AssembledContext(
            sections: sections, totalTokens: 100,
            freshTailMessages: tail, currentMessageText: "Hello",
        )
        let prompt = builder.build(context: context, credential: .apiKey, tools: []).prompt

        // Slow-changing (identity) in first user message
        let firstMsg = try #require(prompt.messages.first)
        #expect(firstMsg.role == .user)
        if case let .text(t) = firstMsg.content {
            #expect(t.contains("Identity claims"))
            #expect(!t.contains("Cognitive info"), "Cognitive state must not be in first message")
        }

        // Per-turn (cognitive, chrono, temporal) in last user message
        let lastMsg = try #require(prompt.messages.last)
        #expect(lastMsg.role == .user)
        if case let .text(t) = lastMsg.content {
            #expect(t.contains("Cognitive info"))
            #expect(t.contains("Time info"))
            #expect(t.contains("Grounding info"))
        }
    }

    // MARK: - Tools

    @Test
    func `Tools are converted to ToolSchema`() {
        let tools = [ToolDefinition(name: "test", description: "A test", parameters: [])]
        let context = makeMinimalContext(systemPrompt: "prompt")
        let prompt = builder.build(context: context, credential: .apiKey, tools: tools).prompt
        #expect(prompt.tools.count == 1)
        #expect(prompt.tools.first?.name == "test")
    }

    // MARK: - Current Message

    @Test
    func `Current message text becomes final user message`() {
        let context = makeMinimalContext(systemPrompt: "prompt", currentMessage: "Hello world")
        let prompt = builder.build(context: context, credential: .apiKey, tools: []).prompt
        let lastMsg = prompt.messages.last
        #expect(lastMsg?.role == .user)
        if case let .text(t) = lastMsg?.content {
            #expect(t.contains("Hello world"))
        }
    }

    @Test
    func `No current message and no history produces Continue placeholder`() {
        let context = AssembledContext(
            sections: [ContextSection(kind: .systemPrompt, content: "prompt", tokenEstimate: 10)],
            totalTokens: 10,
            currentMessageText: nil,
        )
        let prompt = builder.build(context: context, credential: .apiKey, tools: []).prompt
        #expect(prompt.messages.count == 1)
        #expect(prompt.messages.first?.role == .user)
    }

    // MARK: - Message Reconstruction

    @Test
    func `Plain user messages become APIMessage.user with text content`() {
        let tail = [
            makeStoredMessage(role: .user, content: "Hi there"),
            makeStoredMessage(role: .assistant, content: "Hello!"),
        ]
        let context = makeContextWithTail(tail)
        let prompt = builder.build(context: context, credential: .apiKey, tools: []).prompt
        #expect(prompt.messages.first?.role == .user)
        #expect(prompt.messages.first?.content == .text("Hi there"))
    }

    @Test
    func `Assistant message with stubbed tool results emits text only`() {
        let assistant = makeAssistantWithToolCalls(text: "Let me read that.", toolIds: ["toolu_1"])
        let toolResult = makeToolResult(
            toolUseId: "toolu_1",
            content: "[Tool output omitted for brevity]",
        )
        let tail = [
            makeStoredMessage(role: .user, content: "Read file.txt"),
            assistant,
            toolResult,
        ]
        let context = makeContextWithTail(tail)
        let prompt = builder.build(context: context, credential: .apiKey, tools: []).prompt
        let assistantMsg = prompt.messages.first(where: { $0.role == .assistant })
        #expect(assistantMsg?.content == .text("Let me read that."))
    }

    @Test
    func `Assistant with verbatim tool results emits tool_use blocks`() throws {
        let assistant = makeAssistantWithToolCalls(text: "Reading file.", toolIds: ["toolu_1"])
        let toolResult = makeToolResult(toolUseId: "toolu_1", content: "file contents here")
        let tail = [
            makeStoredMessage(role: .user, content: "Read file.txt"),
            assistant,
            toolResult,
        ]
        let context = makeContextWithTail(tail)
        let prompt = builder.build(context: context, credential: .apiKey, tools: []).prompt
        let assistantMsg = try #require(prompt.messages.first(where: { $0.role == .assistant }))
        guard case let .blocks(blocks) = assistantMsg.content else {
            Issue.record("Expected .blocks content")
            return
        }
        #expect(blocks.count == 2)
        #expect(blocks[0] == .text("Reading file."))
        if case let .toolUse(toolUse) = blocks[1] {
            #expect(toolUse.id == "toolu_1")
            #expect(toolUse.name == "read_file")
        } else {
            Issue.record("Expected .toolUse block")
        }
    }

    @Test
    func `Tool results batch into user message with tool_result blocks`() {
        let assistant = makeAssistantWithToolCalls(text: "Reading.", toolIds: ["toolu_1", "toolu_2"])
        let result1 = makeToolResult(toolUseId: "toolu_1", content: "content 1")
        let result2 = makeToolResult(toolUseId: "toolu_2", content: "content 2")
        let tail = [
            makeStoredMessage(role: .user, content: "Do it"),
            assistant,
            result1,
            result2,
        ]
        let context = makeContextWithTail(tail)
        let prompt = builder.build(context: context, credential: .apiKey, tools: []).prompt
        let userWithResults = prompt.messages.first(where: {
            if case .blocks = $0.content, $0.role == .user { return true }
            return false
        })
        guard case let .blocks(blocks) = userWithResults?.content else {
            Issue.record("Expected user message with blocks")
            return
        }
        let toolResultBlocks = blocks.filter {
            if case .toolResult = $0 { return true }
            return false
        }
        #expect(toolResultBlocks.count == 2)
    }

    @Test
    func `Orphaned tool results are dropped`() {
        let orphanResult = makeToolResult(toolUseId: "toolu_nonexistent", content: "orphan")
        let tail = [
            makeStoredMessage(role: .user, content: "Hello"),
            makeStoredMessage(role: .assistant, content: "Hi back"),
            orphanResult,
        ]
        let context = makeContextWithTail(tail)
        let prompt = builder.build(context: context, credential: .apiKey, tools: []).prompt
        let hasToolResult = prompt.messages.contains { msg in
            if case let .blocks(blocks) = msg.content {
                return blocks.contains {
                    if case .toolResult = $0 { return true }
                    return false
                }
            }
            return false
        }
        #expect(!hasToolResult)
    }

    @Test
    func `First message is always user role`() {
        let tail = [
            makeStoredMessage(role: .assistant, content: "I'm responding first"),
        ]
        let context = makeContextWithTail(tail)
        let prompt = builder.build(context: context, credential: .apiKey, tools: []).prompt
        #expect(prompt.messages.first?.role == .user)
        #expect(prompt.messages.first?.content == .text("(conversation context)"))
    }

    @Test
    func `Empty conversation gets user message placeholder`() {
        let context = makeContextWithTail([], currentMessage: nil)
        let prompt = builder.build(context: context, credential: .apiKey, tools: []).prompt
        #expect(prompt.messages.count == 1)
        #expect(prompt.messages.first?.role == .user)
    }

    @Test
    func `Image attachments produce image content blocks`() throws {
        let context = makeContextWithImages(
            text: "What's in this image?",
            images: [ImageAttachment(data: Data([0xFF, 0xD8]), mediaType: "image/jpeg")],
        )
        let prompt = builder.build(context: context, credential: .apiKey, tools: []).prompt
        let lastMsg = try #require(prompt.messages.last)
        #expect(lastMsg.role == .user)
        guard case let .blocks(blocks) = lastMsg.content else {
            Issue.record("Expected .blocks content for image message")
            return
        }
        let imageBlocks = blocks.filter {
            if case .image = $0 { return true }
            return false
        }
        #expect(imageBlocks.count == 1)
        #expect(blocks.last == .text("What's in this image?"))
    }

    @Test
    func `Messages have no cache_control — automatic caching handles it`() throws {
        var tail: [StoredMessage] = []
        for i in 0 ..< 40 {
            tail.append(makeStoredMessage(role: .user, content: "User \(i)"))
            tail.append(makeStoredMessage(role: .assistant, content: "Reply \(i)"))
        }
        let context = makeContextWithTail(tail)
        let result = builder.build(context: context, credential: .apiKey, tools: [])

        // Boundary should be second-to-last
        #expect(result.boundaryMessageIndex == result.prompt.messages.count - 2)

        // No message should have cache_control — it changes serialization
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let json = try #require(String(data: encoder.encode(result.prompt.messages), encoding: .utf8))
        #expect(!json.contains("cache_control"), "Messages must not contain cache_control")
    }

    // MARK: - Follow-Up

    @Test
    func `buildFollowUp preserves system blocks byte-for-byte`() throws {
        let context = makeMinimalContext(systemPrompt: "# SOUL.md\nPrompt")
        let initial = builder.build(context: context, credential: .apiKey, tools: []).prompt

        let exchange = ToolExchange(
            assistantText: "Let me read that",
            calls: [ToolUseBlock(id: "tu_1", name: "read_file", input: .object([("path", .string("/tmp"))]))],
            results: [ToolResultBlock(toolUseId: "tu_1", content: "file contents", isError: false)],
            injections: [],
        )
        let followUp = builder.buildFollowUp(basePrompt: initial, exchanges: [exchange], tools: [])

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let initialSystem = try encoder.encode(initial.system)
        let followUpSystem = try encoder.encode(followUp.system)
        #expect(initialSystem == followUpSystem)
    }

    @Test
    func `buildFollowUp preserves message prefix`() throws {
        let context = makeContextWithTail([
            makeStoredMessage(role: .user, content: "Hello"),
            makeStoredMessage(role: .assistant, content: "Hi"),
        ], currentMessage: "Do something")
        let initial = builder.build(context: context, credential: .apiKey, tools: []).prompt

        let exchange = ToolExchange(
            assistantText: "On it",
            calls: [ToolUseBlock(id: "tu_1", name: "test", input: .object([]))],
            results: [ToolResultBlock(toolUseId: "tu_1", content: "done", isError: false)],
            injections: [],
        )
        let followUp = builder.buildFollowUp(basePrompt: initial, exchanges: [exchange], tools: [])

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        for i in 0 ..< initial.messages.count {
            let a = try encoder.encode(initial.messages[i])
            let b = try encoder.encode(followUp.messages[i])
            #expect(a == b, "Message at index \(i) differs")
        }
    }

    @Test
    func `buildFollowUp appends exchange as assistant+user pair`() {
        let context = makeContextWithTail([
            makeStoredMessage(role: .user, content: "Hello"),
        ], currentMessage: "Do something")
        let initial = builder.build(context: context, credential: .apiKey, tools: []).prompt
        let initialCount = initial.messages.count

        let exchange = ToolExchange(
            assistantText: "Working",
            calls: [ToolUseBlock(id: "tu_1", name: "test", input: .object([]))],
            results: [ToolResultBlock(toolUseId: "tu_1", content: "done", isError: false)],
            injections: [],
        )
        let followUp = builder.buildFollowUp(basePrompt: initial, exchanges: [exchange], tools: [])
        #expect(followUp.messages.count == initialCount + 2)
    }

    @Test
    func `buildFollowUp includes injections as text blocks`() throws {
        let context = makeMinimalContext(systemPrompt: "prompt")
        let initial = builder.build(context: context, credential: .apiKey, tools: []).prompt

        let exchange = ToolExchange(
            assistantText: "",
            calls: [ToolUseBlock(id: "tu_1", name: "test", input: .object([]))],
            results: [ToolResultBlock(toolUseId: "tu_1", content: "done", isError: false)],
            injections: ["[Background task completed]"],
        )
        let followUp = builder.buildFollowUp(basePrompt: initial, exchanges: [exchange], tools: [])
        let lastMsg = try #require(followUp.messages.last)
        if case let .blocks(blocks) = lastMsg.content {
            let hasInjection = blocks.contains(where: {
                if case let .text(t) = $0 { t.contains("Background task completed") } else { false }
            })
            #expect(hasInjection)
        } else {
            Issue.record("Expected blocks content")
        }
    }

    // MARK: - Worker Prompt

    @Test
    func `buildWorkerPrompt creates minimal prompt`() {
        let prompt = builder.buildWorkerPrompt(
            systemPrompt: "You are a worker",
            goal: "Find the bug",
            tools: [ToolDefinition(name: "read", description: "Read file", parameters: [])],
        )
        #expect(prompt.system.count == 1)
        #expect(prompt.system[0].text == "You are a worker")
        #expect(prompt.messages.count == 1)
        #expect(prompt.messages[0].role == .user)
        #expect(prompt.messages[0].content == .text("Find the bug"))
        #expect(prompt.tools.count == 1)
    }

    @Test
    func `Consecutive same-role messages are merged`() throws {
        let tail = [
            makeStoredMessage(role: .user, content: "Part 1"),
            makeStoredMessage(role: .user, content: "Part 2"),
            makeStoredMessage(role: .assistant, content: "Response"),
        ]
        let context = makeContextWithTail(tail)
        let prompt = builder.build(context: context, credential: .apiKey, tools: []).prompt
        let roles = prompt.messages.map(\.role)
        for i in 1 ..< roles.count {
            #expect(roles[i] != roles[i - 1], "Consecutive messages should not have the same role")
        }
        let firstUser = try #require(prompt.messages.first(where: { $0.role == .user }))
        if case let .text(text) = firstUser.content {
            #expect(text.contains("Part 1"))
            #expect(text.contains("Part 2"))
        } else if case let .blocks(blocks) = firstUser.content {
            let texts = blocks.compactMap { block -> String? in
                if case let .text(t) = block { return t }
                return nil
            }
            #expect(texts.contains("Part 1"))
            #expect(texts.contains("Part 2"))
        }
    }
}

// MARK: - Test Helpers

/// Create a minimal ``AssembledContext`` with just a system prompt and current message.
private func makeMinimalContext(
    systemPrompt: String,
    currentMessage: String = "Hello",
) -> AssembledContext {
    AssembledContext(
        sections: [ContextSection(kind: .systemPrompt, content: systemPrompt, tokenEstimate: systemPrompt.count / 4)],
        totalTokens: systemPrompt.count / 4,
        currentMessageText: currentMessage,
    )
}

/// Create an ``AssembledContext`` with specific sections.
private func makeContextWithSections(
    _ sections: [ContextSection],
    currentMessage: String = "Hello",
) -> AssembledContext {
    let total = sections.reduce(0) { $0 + $1.tokenEstimate }
    return AssembledContext(
        sections: sections,
        totalTokens: total,
        currentMessageText: currentMessage,
    )
}

/// Create a ``StoredMessage`` with just text content (no parts).
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

/// Create an assistant ``StoredMessage`` with `.toolCall` parts.
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

/// Create a tool result ``StoredMessage`` with a `.toolResult` part.
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

/// Create an ``AssembledContext`` with fresh tail messages.
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

/// Create an ``AssembledContext`` with image attachments on the current message.
private func makeContextWithImages(text: String?, images: [ImageAttachment]) -> AssembledContext {
    AssembledContext(
        sections: [ContextSection(kind: .systemPrompt, content: "prompt", tokenEstimate: 10)],
        totalTokens: 100,
        currentMessageText: text,
        currentMessageImages: images,
    )
}
