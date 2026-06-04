import Foundation
#if canImport(FoundationNetworking)
    import FoundationNetworking
#endif

/// OpenAI-compatible model provider conforming to ``ModelProviding``.
///
/// Supports any provider with a `/v1/chat/completions` endpoint: OpenAI, OpenRouter,
/// Ollama, LM Studio, Groq, DeepSeek, Together, etc. Uses SSE streaming by default
/// with `data: [DONE]` termination.
///
/// Translates between Anthropic's internal prompt format and OpenAI's message format
/// using ``MessageTranslator``. Responses are normalized back into ``ModelResponse``
/// and ``ModelDelta`` values.
public struct OpenAIProvider: ModelProviding, Sendable {
    /// Base URL for the API (e.g., `https://api.openai.com`).
    public let baseURL: URL

    /// API key for authentication.
    public let apiKey: String

    /// Maximum output tokens to request.
    public let maxTokens: Int

    /// Per-tier model ID overrides.
    public let modelOverrides: [ModelTier: String]

    /// Additional HTTP headers to send with each request.
    public let extraHeaders: [String: String]

    /// Maximum number of retries for transient errors.
    public let maxRetries: Int

    /// The message format translator.
    private let translator = MessageTranslator()

    /// Create an OpenAI-compatible provider.
    ///
    /// - Parameters:
    ///   - baseURL: API base URL (default: OpenAI).
    ///   - apiKey: Bearer token for authentication.
    ///   - maxTokens: Maximum output tokens (default: 16384).
    ///   - modelOverrides: Per-tier model ID overrides.
    ///   - extraHeaders: Additional HTTP headers for the request.
    ///   - maxRetries: Maximum retries for transient errors (default: 3).
    public init(
        baseURL: URL = URL(string: "https://api.openai.com")!,
        apiKey: String,
        maxTokens: Int = 16_384,
        modelOverrides: [ModelTier: String] = [:],
        extraHeaders: [String: String] = [:],
        maxRetries: Int = 3,
    ) {
        self.baseURL = baseURL
        self.apiKey = apiKey
        self.maxTokens = maxTokens
        self.modelOverrides = modelOverrides
        self.extraHeaders = extraHeaders
        self.maxRetries = maxRetries
    }

    // MARK: - Model Resolution

    /// Resolve a model ID for the given tier.
    ///
    /// Checks ``modelOverrides`` first, then falls back to sensible defaults.
    /// The default mapping uses OpenAI's model lineup but can be overridden
    /// for any compatible provider.
    ///
    /// - Parameter tier: The model tier to resolve.
    /// - Returns: The model identifier string.
    public func resolveModel(for tier: ModelTier) -> String {
        if let override = modelOverrides[tier] { return override }
        switch tier {
        case .executive: return "gpt-4o"
        case .workerDefault: return "gpt-4o-mini"
        case .workerLight: return "gpt-4o-mini"
        case .consolidation: return "gpt-4o-mini"
        case .salience: return "gpt-4o-mini"
        }
    }

    // MARK: - ModelProviding

    public nonisolated func complete(
        _ prompt: Prompt, tier: ModelTier,
    ) async throws -> ModelResponse {
        let start = ContinuousClock.now
        let model = resolveModel(for: tier)
        let body = buildRequestBody(prompt: prompt, model: model, stream: false)

        let data = try await sendRequest(body: body, retryCount: 0)
        let json = try parseJSON(data)
        let elapsed = ContinuousClock.now - start

        return parseCompletionResponse(json, model: model, latency: elapsed)
    }

    public nonisolated func stream(
        _ prompt: Prompt, tier: ModelTier,
    ) async throws -> AsyncThrowingStream<ModelDelta, any Error> {
        let model = resolveModel(for: tier)
        let body = buildRequestBody(prompt: prompt, model: model, stream: true)

        let (bytes, response) = try await sendStreamingRequest(body: body)
        let httpResponse = response as! HTTPURLResponse

        guard (200 ... 299).contains(httpResponse.statusCode) else {
            let errorBody = try await collectBytes(bytes)
            let message = String(data: errorBody, encoding: .utf8) ?? "HTTP \(httpResponse.statusCode)"
            throw classifyHTTPError(statusCode: httpResponse.statusCode, message: message)
        }

        return AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    var buffer = ""
                    var toolCalls: [String: PendingToolCall] = [:]

                    for try await line in bytes.lines {
                        guard !Task.isCancelled else { break }

                        guard line.hasPrefix("data: ") else { continue }
                        let payload = String(line.dropFirst(6))

                        if payload == "[DONE]" {
                            for (_, pending) in toolCalls.sorted(by: { $0.value.index < $1.value.index }) {
                                let toolCall = ToolCall(
                                    id: pending.id,
                                    name: pending.name,
                                    arguments: pending.arguments,
                                )
                                continuation.yield(ModelDelta(text: nil, toolCall: toolCall))
                            }
                            let stopReason = toolCalls.isEmpty ? "end_turn" : "tool_use"
                            continuation.yield(ModelDelta(text: nil, toolCall: nil, stopReason: stopReason))
                            continuation.finish()
                            return
                        }

                        guard let chunkData = payload.data(using: .utf8),
                              let chunk = try? JSONSerialization.jsonObject(with: chunkData) as? [String: Any],
                              let choices = chunk["choices"] as? [[String: Any]],
                              let choice = choices.first else { continue }

                        if let delta = choice["delta"] as? [String: Any] {
                            if let content = delta["content"] as? String {
                                buffer += content
                                continuation.yield(ModelDelta(text: content, toolCall: nil))
                            }

                            if let calls = delta["tool_calls"] as? [[String: Any]] {
                                for call in calls {
                                    let index = call["index"] as? Int ?? 0
                                    let key = "\(index)"
                                    if let id = call["id"] as? String {
                                        toolCalls[key] = PendingToolCall(
                                            id: id, index: index, name: "", arguments: "",
                                        )
                                    }
                                    if let fn = call["function"] as? [String: Any] {
                                        if let name = fn["name"] as? String {
                                            toolCalls[key]?.name = name
                                        }
                                        if let args = fn["arguments"] as? String {
                                            toolCalls[key]?.arguments += args
                                        }
                                    }
                                }
                            }
                        }

                        if let finishReason = choice["finish_reason"] as? String,
                           !finishReason.isEmpty {
                            for (_, pending) in toolCalls.sorted(by: { $0.value.index < $1.value.index }) {
                                let toolCall = ToolCall(
                                    id: pending.id,
                                    name: pending.name,
                                    arguments: pending.arguments,
                                )
                                continuation.yield(ModelDelta(text: nil, toolCall: toolCall))
                            }
                            let stopReason = finishReason == "tool_calls" ? "tool_use" : "end_turn"
                            continuation.yield(ModelDelta(text: nil, toolCall: nil, stopReason: stopReason))
                            continuation.finish()
                            return
                        }
                    }

                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }

            continuation.onTermination = { _ in
                task.cancel()
            }
        }
    }

    // MARK: - Request Building

    /// Build the request body dictionary for the OpenAI chat completions API.
    func buildRequestBody(prompt: Prompt, model: String, stream: Bool) -> [String: Any] {
        var body: [String: Any] = [
            "model": model,
            "max_tokens": maxTokens,
            "stream": stream,
            "messages": translator.translateMessages(from: prompt),
        ]

        let tools = translator.translateTools(from: prompt.tools)
        if !tools.isEmpty {
            body["tools"] = tools
        }

        if stream {
            body["stream_options"] = ["include_usage": true]
        }

        return body
    }

    // MARK: - HTTP

    /// Send a non-streaming request and return the response data.
    private func sendRequest(body: [String: Any], retryCount: Int) async throws -> Data {
        let request = try buildHTTPRequest(body: body)

        let (data, response) = try await URLSession.shared.data(for: request)
        let httpResponse = response as! HTTPURLResponse

        if (200 ... 299).contains(httpResponse.statusCode) {
            return data
        }

        let message = String(data: data, encoding: .utf8) ?? "HTTP \(httpResponse.statusCode)"
        let error = classifyHTTPError(statusCode: httpResponse.statusCode, message: message)

        if isRetryable(statusCode: httpResponse.statusCode), retryCount < maxRetries {
            let delay = retryDelay(attempt: retryCount, response: httpResponse)
            try await Task.sleep(for: delay)
            return try await sendRequest(body: body, retryCount: retryCount + 1)
        }

        throw error
    }

    /// Send a streaming request and return the byte stream.
    private func sendStreamingRequest(
        body: [String: Any],
    ) async throws -> (URLSession.AsyncBytes, URLResponse) {
        let request = try buildHTTPRequest(body: body)
        return try await URLSession.shared.bytes(for: request)
    }

    /// Build the `URLRequest` with headers and JSON body.
    private func buildHTTPRequest(body: [String: Any]) throws -> URLRequest {
        let url = baseURL.appendingPathComponent("v1/chat/completions")
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")

        for (key, value) in extraHeaders {
            request.setValue(value, forHTTPHeaderField: key)
        }

        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        return request
    }

    // MARK: - Response Parsing

    /// Parse a non-streaming completion response into a ``ModelResponse``.
    private func parseCompletionResponse(
        _ json: [String: Any], model _: String, latency: Duration,
    ) -> ModelResponse {
        let choices = json["choices"] as? [[String: Any]] ?? []
        let choice = choices.first ?? [:]
        let message = choice["message"] as? [String: Any] ?? [:]

        let content = message["content"] as? String ?? ""
        let finishReason = choice["finish_reason"] as? String ?? "stop"

        var toolCalls: [ToolCall] = []
        if let calls = message["tool_calls"] as? [[String: Any]] {
            for call in calls {
                let id = call["id"] as? String ?? ""
                let fn = call["function"] as? [String: Any] ?? [:]
                let name = fn["name"] as? String ?? ""
                let args = fn["arguments"] as? String ?? ""
                toolCalls.append(ToolCall(id: id, name: name, arguments: args))
            }
        }

        let usage = json["usage"] as? [String: Any] ?? [:]
        let inputTokens = usage["prompt_tokens"] as? Int ?? 0
        let outputTokens = usage["completion_tokens"] as? Int ?? 0
        let cachedTokens = (usage["prompt_tokens_details"] as? [String: Any])?["cached_tokens"] as? Int ?? 0

        let stopReason = finishReason == "tool_calls" ? "tool_use" : "end_turn"

        return ModelResponse(
            content: content,
            toolCalls: toolCalls,
            tokenUsage: TokenUsage(
                inputTokens: inputTokens,
                outputTokens: outputTokens,
                cacheReadTokens: cachedTokens,
            ),
            latency: latency,
            stopReason: stopReason,
        )
    }

    /// Parse raw data into a JSON dictionary.
    private func parseJSON(_ data: Data) throws -> [String: Any] {
        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw CIMSError.modelError("Invalid JSON response from OpenAI-compatible API")
        }
        return json
    }

    /// Collect all bytes from an async stream into `Data`.
    private func collectBytes(_ bytes: URLSession.AsyncBytes) async throws -> Data {
        var result = Data()
        for try await byte in bytes {
            result.append(byte)
        }
        return result
    }

    // MARK: - Error Classification

    /// Classify an HTTP error status code into a ``CIMSError``.
    func classifyHTTPError(statusCode: Int, message: String) -> CIMSError {
        switch statusCode {
        case 429:
            .rateLimited(retryAfter: 30, message: message)
        case 401, 403:
            .modelError("Authentication failed: \(message)")
        case 400:
            .modelError("Bad request: \(message)")
        case 413:
            .contextOverflow(0, 0)
        case 500, 502, 503, 529:
            .modelError("Server error (\(statusCode)): \(message)")
        default:
            .modelError("HTTP \(statusCode): \(message)")
        }
    }

    /// Whether an HTTP status code is retryable.
    private func isRetryable(statusCode: Int) -> Bool {
        [429, 500, 502, 503, 529].contains(statusCode)
    }

    /// Calculate retry delay with exponential backoff and jitter.
    private func retryDelay(attempt: Int, response: HTTPURLResponse) -> Duration {
        if let retryAfter = response.value(forHTTPHeaderField: "Retry-After"),
           let seconds = Double(retryAfter) {
            return .seconds(seconds)
        }
        let base = pow(2.0, Double(attempt))
        let jitter = Double.random(in: 0 ... 0.5)
        return .seconds(base + jitter)
    }
}

// MARK: - PendingToolCall

/// Accumulator for streaming tool call chunks.
private struct PendingToolCall {
    let id: String
    let index: Int
    var name: String
    var arguments: String
}

// MARK: - Factory

extension OpenAIProvider {
    /// Create an OpenAI provider for a known endpoint.
    ///
    /// - Parameters:
    ///   - endpoint: The API endpoint identifier (e.g., "openai", "openrouter", "ollama").
    ///   - apiKey: The API key for authentication.
    ///   - modelOverrides: Per-tier model ID overrides.
    /// - Returns: A configured ``OpenAIProvider``.
    public static func forEndpoint(
        _ endpoint: String,
        apiKey: String,
        modelOverrides: [ModelTier: String] = [:],
    ) -> OpenAIProvider {
        let (url, headers) = endpointConfig(for: endpoint)
        return OpenAIProvider(
            baseURL: url,
            apiKey: apiKey,
            modelOverrides: modelOverrides,
            extraHeaders: headers,
        )
    }

    /// Resolve base URL and extra headers for known endpoint identifiers.
    private static func endpointConfig(for endpoint: String) -> (URL, [String: String]) {
        switch endpoint.lowercased() {
        case "openai":
            (URL(string: "https://api.openai.com")!, [:])
        case "openrouter":
            (URL(string: "https://openrouter.ai/api")!, [
                "HTTP-Referer": "https://aozora.ai",
                "X-Title": "Aozora",
            ])
        case "ollama":
            (URL(string: "http://localhost:11434")!, [:])
        case "lmstudio":
            (URL(string: "http://localhost:1234")!, [:])
        case "groq":
            (URL(string: "https://api.groq.com/openai")!, [:])
        case "deepseek":
            (URL(string: "https://api.deepseek.com")!, [:])
        case "together":
            (URL(string: "https://api.together.xyz")!, [:])
        default:
            (URL(string: endpoint)!, [:])
        }
    }
}
