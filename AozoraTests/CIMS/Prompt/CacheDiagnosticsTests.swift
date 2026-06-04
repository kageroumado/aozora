import Foundation
import Testing
@testable import Aozora

struct CacheDiagnosticsTests {
    private func makePrompt(blockTexts: [String]) -> Prompt {
        Prompt(
            system: blockTexts.map { SystemBlock(text: $0, cacheControl: nil) },
            messages: [APIMessage(role: .user, content: .text("test"))],
            tools: [],
        )
    }

    private let defaultUsage = TokenUsage(
        inputTokens: 100, outputTokens: 50, cacheReadTokens: 80, cacheCreationTokens: 20,
    )

    // MARK: - Hash Determinism

    @Test
    func `system hash is deterministic`() {
        let prompt = makePrompt(blockTexts: ["Hello world", "Second block"])
        let r1 = CacheDiagnostics.report(
            prompt: prompt, usage: defaultUsage,
            boundaryIndex: nil, previousSystemHash: nil, previousBlockHashes: nil,
        )
        let r2 = CacheDiagnostics.report(
            prompt: prompt, usage: defaultUsage,
            boundaryIndex: nil, previousSystemHash: nil, previousBlockHashes: nil,
        )
        #expect(r1.systemHash == r2.systemHash)
        #expect(r1.systemHash.count == 8)
    }

    @Test
    func `system hash changes when content changes`() {
        let r1 = CacheDiagnostics.report(
            prompt: makePrompt(blockTexts: ["alpha"]), usage: defaultUsage,
            boundaryIndex: nil, previousSystemHash: nil, previousBlockHashes: nil,
        )
        let r2 = CacheDiagnostics.report(
            prompt: makePrompt(blockTexts: ["beta"]), usage: defaultUsage,
            boundaryIndex: nil, previousSystemHash: nil, previousBlockHashes: nil,
        )
        #expect(r1.systemHash != r2.systemHash)
    }

    // MARK: - Tools Hash

    @Test
    func `tools hash uses sorted keys encoding`() {
        let tool = ToolSchema(from: ToolDefinition(
            name: "test_tool", description: "A test tool",
            parameters: [ToolParameter(name: "input", type: .string, description: "Input value")],
        ))
        let prompt = Prompt(
            system: [SystemBlock(text: "sys", cacheControl: nil)],
            messages: [APIMessage(role: .user, content: .text("test"))],
            tools: [tool],
        )
        let r1 = CacheDiagnostics.report(
            prompt: prompt, usage: defaultUsage,
            boundaryIndex: nil, previousSystemHash: nil, previousBlockHashes: nil,
        )
        let r2 = CacheDiagnostics.report(
            prompt: prompt, usage: defaultUsage,
            boundaryIndex: nil, previousSystemHash: nil, previousBlockHashes: nil,
        )
        #expect(r1.toolsHash == r2.toolsHash)
        #expect(r1.toolsHash.count == 8)
        #expect(r1.toolsHash != "00000000")
    }

    // MARK: - Change Detection

    @Test
    func `detects system hash change`() {
        let prompt = makePrompt(blockTexts: ["current content"])
        let r = CacheDiagnostics.report(
            prompt: prompt, usage: defaultUsage,
            boundaryIndex: nil, previousSystemHash: "aabbccdd", previousBlockHashes: nil,
        )
        #expect(r.systemHashChanged == true)
        #expect(r.previousSystemHash == "aabbccdd")
    }

    @Test
    func `no change when hash matches`() {
        let prompt = makePrompt(blockTexts: ["stable content"])
        let hash = CacheDiagnostics.report(
            prompt: prompt, usage: defaultUsage,
            boundaryIndex: nil, previousSystemHash: nil, previousBlockHashes: nil,
        ).systemHash
        let r = CacheDiagnostics.report(
            prompt: prompt, usage: defaultUsage,
            boundaryIndex: nil, previousSystemHash: hash, previousBlockHashes: nil,
        )
        #expect(r.systemHashChanged == false)
    }

    @Test
    func `detects which block changed`() {
        let prompt = makePrompt(blockTexts: ["unchanged", "modified block"])
        let oldHashes = CacheDiagnostics.report(
            prompt: makePrompt(blockTexts: ["unchanged", "original block"]),
            usage: defaultUsage,
            boundaryIndex: nil, previousSystemHash: nil, previousBlockHashes: nil,
        ).blocks.map(\.contentHash)

        let r = CacheDiagnostics.report(
            prompt: prompt, usage: defaultUsage,
            boundaryIndex: nil, previousSystemHash: nil, previousBlockHashes: oldHashes,
        )
        #expect(r.changedBlockIndices == [1])
    }

    // MARK: - Block Info

    @Test
    func `block info captures cache control`() {
        let prompt = Prompt(
            system: [
                SystemBlock(text: "no cache", cacheControl: nil),
                SystemBlock(text: "with cache", cacheControl: .ephemeral),
            ],
            messages: [APIMessage(role: .user, content: .text("test"))],
            tools: [],
        )
        let r = CacheDiagnostics.report(
            prompt: prompt, usage: defaultUsage,
            boundaryIndex: nil, previousSystemHash: nil, previousBlockHashes: nil,
        )
        #expect(r.blocks.count == 2)
        #expect(r.blocks[0].hasCacheControl == false)
        #expect(r.blocks[1].hasCacheControl == true)
    }

    // MARK: - Passthrough

    @Test
    func `boundary index is passed through`() {
        let r = CacheDiagnostics.report(
            prompt: makePrompt(blockTexts: ["sys"]), usage: defaultUsage,
            boundaryIndex: 42, previousSystemHash: nil, previousBlockHashes: nil,
        )
        #expect(r.boundaryIndex == 42)
    }

    // MARK: - Formatting

    @Test
    func `format produces expected lines`() {
        let r = CacheDiagnostics.report(
            prompt: makePrompt(blockTexts: ["hello"]), usage: defaultUsage,
            boundaryIndex: 3, previousSystemHash: nil, previousBlockHashes: nil,
        )
        let output = CacheDiagnostics.format(r)
        #expect(output.contains("in=100"))
        #expect(output.contains("out=50"))
        #expect(output.contains("cache_read=80"))
        #expect(output.contains("cache_create=20"))
        #expect(output.contains("boundary=3"))
        #expect(output.contains("hit=40%"))
    }

    @Test
    func `format includes change warning`() {
        let r = CacheDiagnostics.report(
            prompt: makePrompt(blockTexts: ["new content"]), usage: defaultUsage,
            boundaryIndex: nil, previousSystemHash: "oldolold", previousBlockHashes: nil,
        )
        let output = CacheDiagnostics.format(r)
        #expect(output.contains("WARNING"))
        #expect(output.contains("system_hash changed"))
        #expect(output.contains("oldolold"))
    }
}
