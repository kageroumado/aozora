import Testing
@testable import Aozora

struct MessageTranslatorTests {
    let translator = MessageTranslator()

    // MARK: - Message Translation

    @Test
    func `Translates plain text user message`() {
        let prompt = Prompt(
            system: [],
            messages: [APIMessage(role: .user, content: .text("Hello"))],
            tools: [],
        )
        let messages = translator.translateMessages(from: prompt)

        #expect(messages.count == 1)
        #expect(messages[0]["role"] as? String == "user")
        #expect(messages[0]["content"] as? String == "Hello")
    }

    @Test
    func `Translates plain text assistant message`() {
        let prompt = Prompt(
            system: [],
            messages: [APIMessage(role: .assistant, content: .text("Hi there"))],
            tools: [],
        )
        let messages = translator.translateMessages(from: prompt)

        #expect(messages.count == 1)
        #expect(messages[0]["role"] as? String == "assistant")
        #expect(messages[0]["content"] as? String == "Hi there")
    }

    @Test
    func `System blocks become a single system message`() {
        let prompt = Prompt(
            system: [
                SystemBlock(text: "You are helpful.", cacheControl: nil),
                SystemBlock(text: "Be concise.", cacheControl: nil),
            ],
            messages: [APIMessage(role: .user, content: .text("Hi"))],
            tools: [],
        )
        let messages = translator.translateMessages(from: prompt)

        #expect(messages.count == 2)
        #expect(messages[0]["role"] as? String == "system")
        let systemContent = messages[0]["content"] as? String ?? ""
        #expect(systemContent.contains("You are helpful."))
        #expect(systemContent.contains("Be concise."))
    }

    @Test
    func `Empty system blocks produce no system message`() {
        let prompt = Prompt(
            system: [],
            messages: [APIMessage(role: .user, content: .text("Hi"))],
            tools: [],
        )
        let messages = translator.translateMessages(from: prompt)

        #expect(messages.count == 1)
        #expect(messages[0]["role"] as? String == "user")
    }

    @Test
    func `Tool use blocks become assistant message with tool_calls`() {
        let toolUse = ToolUseBlock(
            id: "call_123",
            name: "bash",
            input: .object([("command", .string("ls -la"))]),
        )
        let prompt = Prompt(
            system: [],
            messages: [
                APIMessage(role: .assistant, content: .blocks([
                    .text("Let me check."),
                    .toolUse(toolUse),
                ])),
            ],
            tools: [],
        )
        let messages = translator.translateMessages(from: prompt)

        #expect(messages.count == 1)
        let msg = messages[0]
        #expect(msg["role"] as? String == "assistant")
        #expect(msg["content"] as? String == "Let me check.")

        let toolCalls = msg["tool_calls"] as? [[String: Any]] ?? []
        #expect(toolCalls.count == 1)
        #expect(toolCalls[0]["id"] as? String == "call_123")
        #expect(toolCalls[0]["type"] as? String == "function")

        let fn = toolCalls[0]["function"] as? [String: Any] ?? [:]
        #expect(fn["name"] as? String == "bash")
    }

    @Test
    func `Tool result blocks become tool role messages`() {
        let result = ToolResultBlock(toolUseId: "call_123", content: "file.txt", isError: false)
        let prompt = Prompt(
            system: [],
            messages: [
                APIMessage(role: .user, content: .blocks([.toolResult(result)])),
            ],
            tools: [],
        )
        let messages = translator.translateMessages(from: prompt)

        #expect(messages.count == 1)
        let msg = messages[0]
        #expect(msg["role"] as? String == "tool")
        #expect(msg["tool_call_id"] as? String == "call_123")
        #expect(msg["content"] as? String == "file.txt")
    }

    @Test
    func `Mixed text and tool results in user message produce separate messages`() {
        let result = ToolResultBlock(toolUseId: "call_1", content: "output", isError: false)
        let prompt = Prompt(
            system: [],
            messages: [
                APIMessage(role: .user, content: .blocks([
                    .text("Here are the results:"),
                    .toolResult(result),
                ])),
            ],
            tools: [],
        )
        let messages = translator.translateMessages(from: prompt)

        #expect(messages.count == 2)
        #expect(messages[0]["role"] as? String == "user")
        #expect(messages[0]["content"] as? String == "Here are the results:")
        #expect(messages[1]["role"] as? String == "tool")
    }

    @Test
    func `Cacheable text blocks treated as plain text`() {
        let cached = CacheableTextBlock(text: "Cached content", cacheControl: .ephemeral)
        let prompt = Prompt(
            system: [],
            messages: [
                APIMessage(role: .user, content: .blocks([.cacheableText(cached)])),
            ],
            tools: [],
        )
        let messages = translator.translateMessages(from: prompt)

        #expect(messages.count == 1)
        #expect(messages[0]["content"] as? String == "Cached content")
    }

    @Test
    func `Image blocks produce placeholder text`() {
        let image = ImageBlock(mediaType: "image/png", base64Data: "abc123")
        let prompt = Prompt(
            system: [],
            messages: [
                APIMessage(role: .user, content: .blocks([.image(image)])),
            ],
            tools: [],
        )
        let messages = translator.translateMessages(from: prompt)

        #expect(messages.count == 1)
        let content = messages[0]["content"] as? String ?? ""
        #expect(content.contains("image/png"))
    }

    @Test
    func `Full conversation roundtrip with multiple turns`() {
        let prompt = Prompt(
            system: [SystemBlock(text: "You are an assistant.", cacheControl: nil)],
            messages: [
                APIMessage(role: .user, content: .text("Hello")),
                APIMessage(role: .assistant, content: .text("Hi! How can I help?")),
                APIMessage(role: .user, content: .text("What's 2+2?")),
                APIMessage(role: .assistant, content: .text("4")),
            ],
            tools: [],
        )
        let messages = translator.translateMessages(from: prompt)

        #expect(messages.count == 5)
        #expect(messages[0]["role"] as? String == "system")
        #expect(messages[1]["role"] as? String == "user")
        #expect(messages[2]["role"] as? String == "assistant")
        #expect(messages[3]["role"] as? String == "user")
        #expect(messages[4]["role"] as? String == "assistant")
    }

    // MARK: - Tool Schema Translation

    @Test
    func `Translates tool schemas to OpenAI function format`() {
        let tool = ToolSchema(
            from: ToolDefinition(
                name: "read_file",
                description: "Read a file from disk",
                parameters: [
                    ToolParameter(name: "path", type: .string, description: "File path", optional: false),
                    ToolParameter(name: "offset", type: .integer, description: "Line offset", optional: true),
                ],
            ),
        )
        let translated = translator.translateTools(from: [tool])

        #expect(translated.count == 1)
        let t = translated[0]
        #expect(t["type"] as? String == "function")

        let fn = t["function"] as? [String: Any] ?? [:]
        #expect(fn["name"] as? String == "read_file")
        #expect(fn["description"] as? String == "Read a file from disk")

        let params = fn["parameters"] as? [String: Any] ?? [:]
        #expect(params["type"] as? String == "object")

        let props = params["properties"] as? [String: Any] ?? [:]
        #expect(props.keys.contains("path"))
        #expect(props.keys.contains("offset"))

        let required = params["required"] as? [String] ?? []
        #expect(required.contains("path"))
        #expect(!required.contains("offset"))
    }

    @Test
    func `Empty tools array produces empty result`() {
        let translated = translator.translateTools(from: [])
        #expect(translated.isEmpty)
    }

    @Test
    func `Multiple tool use blocks in one assistant message`() {
        let toolUse1 = ToolUseBlock(id: "call_1", name: "read", input: .object([("path", .string("/a"))]))
        let toolUse2 = ToolUseBlock(id: "call_2", name: "read", input: .object([("path", .string("/b"))]))

        let prompt = Prompt(
            system: [],
            messages: [
                APIMessage(role: .assistant, content: .blocks([
                    .text("Reading both files."),
                    .toolUse(toolUse1),
                    .toolUse(toolUse2),
                ])),
            ],
            tools: [],
        )
        let messages = translator.translateMessages(from: prompt)

        #expect(messages.count == 1)
        let toolCalls = messages[0]["tool_calls"] as? [[String: Any]] ?? []
        #expect(toolCalls.count == 2)
    }

    @Test
    func `Multiple tool results in one user message become separate tool messages`() {
        let r1 = ToolResultBlock(toolUseId: "call_1", content: "content A", isError: false)
        let r2 = ToolResultBlock(toolUseId: "call_2", content: "content B", isError: false)

        let prompt = Prompt(
            system: [],
            messages: [
                APIMessage(role: .user, content: .blocks([.toolResult(r1), .toolResult(r2)])),
            ],
            tools: [],
        )
        let messages = translator.translateMessages(from: prompt)

        #expect(messages.count == 2)
        #expect(messages[0]["tool_call_id"] as? String == "call_1")
        #expect(messages[1]["tool_call_id"] as? String == "call_2")
    }
}
