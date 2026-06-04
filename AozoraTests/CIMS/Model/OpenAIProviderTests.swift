import Testing
@testable import Aozora

struct OpenAIProviderTests {
    // MARK: - Request Body

    @Test
    func `Request body includes model, messages, max_tokens`() {
        let provider = OpenAIProvider(apiKey: "test-key", maxTokens: 4_096)
        let prompt = Prompt(
            system: [SystemBlock(text: "Be helpful.", cacheControl: nil)],
            messages: [APIMessage(role: .user, content: .text("Hello"))],
            tools: [],
        )
        let body = provider.buildRequestBody(prompt: prompt, model: "gpt-4o", stream: false)

        #expect(body["model"] as? String == "gpt-4o")
        #expect(body["max_tokens"] as? Int == 4_096)
        #expect(body["stream"] as? Bool == false)

        let messages = body["messages"] as? [[String: Any]] ?? []
        #expect(messages.count == 2)
        #expect(messages[0]["role"] as? String == "system")
    }

    @Test
    func `Streaming request includes stream_options`() {
        let provider = OpenAIProvider(apiKey: "test-key")
        let prompt = Prompt(system: [], messages: [], tools: [])
        let body = provider.buildRequestBody(prompt: prompt, model: "gpt-4o", stream: true)

        #expect(body["stream"] as? Bool == true)
        let streamOpts = body["stream_options"] as? [String: Any] ?? [:]
        #expect(streamOpts["include_usage"] as? Bool == true)
    }

    @Test
    func `Tools omitted when empty`() {
        let provider = OpenAIProvider(apiKey: "test-key")
        let prompt = Prompt(system: [], messages: [], tools: [])
        let body = provider.buildRequestBody(prompt: prompt, model: "gpt-4o", stream: false)

        #expect(body["tools"] == nil)
    }

    @Test
    func `Tools included when present`() {
        let provider = OpenAIProvider(apiKey: "test-key")
        let tool = ToolSchema(
            from: ToolDefinition(
                name: "test",
                description: "A test tool",
                parameters: [],
            ),
        )
        let prompt = Prompt(system: [], messages: [], tools: [tool])
        let body = provider.buildRequestBody(prompt: prompt, model: "gpt-4o", stream: false)

        let tools = body["tools"] as? [[String: Any]] ?? []
        #expect(tools.count == 1)
    }

    // MARK: - Model Resolution

    @Test
    func `Default tier mapping`() {
        let provider = OpenAIProvider(apiKey: "test-key")

        #expect(provider.resolveModel(for: .executive) == "gpt-4o")
        #expect(provider.resolveModel(for: .workerDefault) == "gpt-4o-mini")
        #expect(provider.resolveModel(for: .workerLight) == "gpt-4o-mini")
    }

    @Test
    func `Model overrides take precedence`() {
        let provider = OpenAIProvider(
            apiKey: "test-key",
            modelOverrides: [.executive: "o3", .workerDefault: "gpt-4o"],
        )

        #expect(provider.resolveModel(for: .executive) == "o3")
        #expect(provider.resolveModel(for: .workerDefault) == "gpt-4o")
        #expect(provider.resolveModel(for: .workerLight) == "gpt-4o-mini")
    }

    // MARK: - Error Classification

    @Test
    func `429 classified as rateLimited`() {
        let provider = OpenAIProvider(apiKey: "test-key")
        let error = provider.classifyHTTPError(statusCode: 429, message: "too many requests")

        if case .rateLimited = error {
            // expected
        } else {
            Issue.record("Expected rateLimited, got \(error)")
        }
    }

    @Test
    func `401 classified as modelError with auth message`() {
        let provider = OpenAIProvider(apiKey: "test-key")
        let error = provider.classifyHTTPError(statusCode: 401, message: "invalid key")

        if case let .modelError(msg) = error {
            #expect(msg.contains("Authentication failed"))
        } else {
            Issue.record("Expected modelError, got \(error)")
        }
    }

    @Test
    func `413 classified as contextOverflow`() {
        let provider = OpenAIProvider(apiKey: "test-key")
        let error = provider.classifyHTTPError(statusCode: 413, message: "too large")

        if case .contextOverflow = error {
            // expected
        } else {
            Issue.record("Expected contextOverflow, got \(error)")
        }
    }

    @Test
    func `500 classified as server error`() {
        let provider = OpenAIProvider(apiKey: "test-key")
        let error = provider.classifyHTTPError(statusCode: 500, message: "internal")

        if case let .modelError(msg) = error {
            #expect(msg.contains("Server error"))
        } else {
            Issue.record("Expected modelError, got \(error)")
        }
    }

    // MARK: - Factory

    @Test
    func `forEndpoint creates correct base URLs`() {
        let openai = OpenAIProvider.forEndpoint("openai", apiKey: "k")
        #expect(openai.baseURL.host == "api.openai.com")

        let openrouter = OpenAIProvider.forEndpoint("openrouter", apiKey: "k")
        #expect(openrouter.baseURL.host == "openrouter.ai")
        #expect(openrouter.extraHeaders["X-Title"] == "Aozora")

        let ollama = OpenAIProvider.forEndpoint("ollama", apiKey: "k")
        #expect(ollama.baseURL.host == "localhost")
        #expect(ollama.baseURL.port == 11_434)

        let groq = OpenAIProvider.forEndpoint("groq", apiKey: "k")
        #expect(groq.baseURL.host == "api.groq.com")

        let deepseek = OpenAIProvider.forEndpoint("deepseek", apiKey: "k")
        #expect(deepseek.baseURL.host == "api.deepseek.com")
    }

    @Test
    func `Custom URL endpoint passes through`() {
        let custom = OpenAIProvider.forEndpoint("https://my-proxy.example.com", apiKey: "k")
        #expect(custom.baseURL.host == "my-proxy.example.com")
    }
}
