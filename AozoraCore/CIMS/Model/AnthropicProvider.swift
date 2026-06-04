import Foundation

/// Real ``ModelProviding`` implementation using Anthropic's Messages API.
///
/// ``AnthropicProvider`` is responsible only for HTTP mechanics, response parsing,
/// retry logic, and transport config (model ID resolution, max tokens, auth headers).
/// All prompt construction (system blocks, messages, tools) is handled upstream by
/// ``PromptBuilder``, which produces a typed ``Prompt`` value.
///
/// **Production resilience features:**
/// - **Exponential backoff with retry** for transient errors (429, 500, 502, 503, 529).
///   Respects `Retry-After` headers on 429 responses.
/// - **Prompt caching** via the `prompt-caching-2024-07-31` beta header. Cache breakpoints
///   are placed by ``PromptBuilder``: one on the last system block (caches ~95K token system
///   prefix) and one at the stubbing boundary message (caches system + tools + message history).
///   The provider serializes the ``Prompt`` with a deterministic `JSONEncoder` (`.sortedKeys`)
///   to ensure byte-for-byte identical requests produce cache hits.
/// - **Context overflow detection** that classifies 413 and token-limit 400 errors
///   as ``CIMSError/contextOverflow(_:_:)`` for targeted fallback.
///
/// Authentication supports both API key and OAuth credentials via ``ClaudeCredential``:
/// - **API key** (`x-api-key` header) with the `prompt-caching-2024-07-31` beta.
/// - **OAuth token** (`Authorization: Bearer` header) with `oauth-2025-04-20,prompt-caching-2024-07-31` betas.
public actor AnthropicProvider: ModelProviding {
    // MARK: - Thinking & Effort Configuration

    /// Controls Claude's extended thinking — internal reasoning blocks before the response.
    ///
    /// When enabled, the model's response includes `thinking` content blocks that are
    /// streamed but not surfaced to the user. These blocks consume output tokens from the
    /// ``maxTokens`` budget.
    public enum ThinkingMode: Sendable {
        /// No extended thinking. Default for low-latency use cases.
        case disabled

        /// Model decides when and how much to think based on query complexity.
        /// Recommended by Anthropic over `.enabled` for most use cases.
        case adaptive

        /// Explicit thinking budget in tokens. Must be less than ``maxTokens``.
        case enabled(budgetTokens: Int)
    }

    /// Controls how much effort the model puts into its response, independent of thinking.
    ///
    /// Maps to the `output_config.effort` API parameter. Higher effort generally produces
    /// more thorough, detailed responses at the cost of increased latency and token usage.
    public enum Effort: String, Sendable {
        case low
        case medium
        case high
    }

    // MARK: - Properties

    /// Anthropic Messages API endpoint.
    private let baseURL: String

    /// All available credentials, sorted by priority. Index 0 is the primary.
    private let credentials: [ClaudeCredential]

    /// Human-readable names for each credential (parallel to ``credentials``).
    /// Used only for logging — e.g., `["claude-max", "ly-claude"]`.
    private let credentialNames: [String]

    /// Index of the currently active credential in ``credentials``.
    private var credentialIndex: Int = 0

    /// Per-credential rate-limit cooldown expiry times.
    private var rateLimitedUntil: [Int: ContinuousClock.Instant] = [:]

    /// The currently active credential, accounting for rate-limit rotation.
    ///
    /// Skips credentials whose rate-limit cooldown hasn't expired yet.
    /// Falls back to the primary credential if all are rate-limited.
    private var activeCredential: ClaudeCredential {
        let now = ContinuousClock.now
        // Try from current index forward, wrapping around
        for offset in 0 ..< credentials.count {
            let idx = (credentialIndex + offset) % credentials.count
            if let until = rateLimitedUntil[idx], now < until {
                continue
            }
            credentialIndex = idx
            return credentials[idx]
        }
        // All rate-limited — use primary anyway (it'll get retried with backoff)
        credentialIndex = 0
        return credentials[0]
    }

    /// API version string (Anthropic's required header).
    private let apiVersion = "2023-06-01"

    /// Model ID overrides per tier. `nil` entries use the default for that tier.
    private let modelOverrides: [ModelTier: String]

    /// Maximum tokens to generate per completion (includes thinking budget when enabled).
    private let maxTokens: Int

    /// Extended thinking configuration.
    private let thinking: ThinkingMode

    /// Model effort level.
    private let effort: Effort

    /// URL session used for HTTP requests. Injectable for testing.
    private let session: URLSession

    /// Maximum number of retry attempts for transient errors.
    private let maxRetries: Int

    /// Shared encoder with deterministic output for reproducible request bodies.
    private nonisolated static let deterministicEncoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return encoder
    }()

    /// Creates an Anthropic provider with multiple credentials for rate-limit fallback.
    ///
    /// When the active credential receives a 429, the provider marks it as rate-limited
    /// and rotates to the next available credential. If all credentials are rate-limited,
    /// falls back to the primary with exponential backoff.
    ///
    /// - Parameters:
    ///   - credentials: Authentication credentials sorted by priority (first = primary).
    ///   - baseURL: API endpoint. Defaults to Anthropic's production API.
    ///   - modelOverrides: Optional model ID overrides per tier.
    ///   - maxTokens: Maximum output tokens per completion. Defaults to 32000.
    ///   - thinking: Extended thinking mode. Defaults to `.adaptive`.
    ///   - effort: Model effort level. Defaults to `.high`.
    ///   - session: URL session for HTTP requests. Defaults to `.shared`.
    ///   - maxRetries: Maximum retry attempts for transient errors. Defaults to 5.
    public init(
        credentials: [ClaudeCredential],
        credentialNames: [String] = [],
        baseURL: String = "https://api.anthropic.com/v1/messages",
        modelOverrides: [ModelTier: String] = [:],
        maxTokens: Int = 32_000,
        thinking: ThinkingMode = .adaptive,
        effort: Effort = .high,
        session: URLSession = .shared,
        maxRetries: Int = 5,
    ) {
        precondition(!credentials.isEmpty, "At least one credential is required")
        self.credentials = credentials
        // Pad names to match credentials count, using masked token prefixes as fallback
        self.credentialNames = (0 ..< credentials.count).map { idx in
            if idx < credentialNames.count { return credentialNames[idx] }
            let t = credentials[idx].token
            return t.count > 8 ? String(t.prefix(8)) + "…" : "credential-\(idx)"
        }
        self.baseURL = baseURL
        self.modelOverrides = modelOverrides
        self.maxTokens = maxTokens
        self.thinking = thinking
        self.effort = effort
        self.session = session
        self.maxRetries = maxRetries
    }

    /// Creates an Anthropic provider with a single credential.
    ///
    /// Convenience initializer for CLI tools and tests that don't need multi-credential
    /// fallback. Wraps the credential in a single-element array.
    public init(
        credential: ClaudeCredential,
        baseURL: String = "https://api.anthropic.com/v1/messages",
        modelOverrides: [ModelTier: String] = [:],
        maxTokens: Int = 32_000,
        thinking: ThinkingMode = .adaptive,
        effort: Effort = .high,
        session: URLSession = .shared,
        maxRetries: Int = 5,
    ) {
        self.init(
            credentials: [credential],
            baseURL: baseURL,
            modelOverrides: modelOverrides,
            maxTokens: maxTokens,
            thinking: thinking,
            effort: effort,
            session: session,
            maxRetries: maxRetries,
        )
    }

    // MARK: - ModelProviding Conformance

    /// Run a complete inference call against the Anthropic Messages API.
    ///
    /// Sends the prompt as a non-streaming request with retry, then parses
    /// the JSON response. OAuth tokens require `stream: true` — the Anthropic API
    /// rejects non-streaming requests with OAuth auth. In that case, streaming is
    /// used internally and the response is collected into a single ``ModelResponse``.
    ///
    /// - Parameters:
    ///   - prompt: The pre-built prompt containing system blocks, messages, and tools.
    ///   - tier: The model tier, mapped to an Anthropic model ID.
    /// - Returns: The complete model response.
    /// - Throws: ``CIMSError/modelError(_:)`` on network or API errors,
    ///   ``CIMSError/contextOverflow(_:_:)`` when the request exceeds the model's context window.
    public nonisolated func complete(_ prompt: Prompt, tier: ModelTier) async throws -> ModelResponse {
        let credCount = credentials.count

        // With multiple credentials, fail fast on 429 and rotate immediately
        if credCount > 1 {
            for credentialAttempt in 0 ..< credCount {
                do {
                    return try await completeSingle(prompt: prompt, tier: tier, failFastOn429: true)
                } catch let error as CIMSError {
                    if case let .rateLimited(retryAfter, _) = error, credentialAttempt + 1 < credCount {
                        await markCurrentCredentialRateLimited(retryAfter: retryAfter)
                        continue
                    }
                    throw error
                }
            }
        }

        // Single credential or final attempt — use normal retry behavior
        return try await completeSingle(prompt: prompt, tier: tier, failFastOn429: false)
    }

    /// Execute a single completion attempt with the currently active credential.
    ///
    /// - Parameter failFastOn429: When `true`, throw `.rateLimited` on the first 429
    ///   instead of retrying — enables immediate credential rotation.
    private nonisolated func completeSingle(
        prompt: Prompt, tier: ModelTier, failFastOn429: Bool,
    ) async throws -> ModelResponse {
        let startTime = ContinuousClock.now
        let modelId = await resolveModel(for: tier)

        // OAuth tokens require stream:true — the Anthropic API rejects non-streaming
        // requests with OAuth auth (returns generic 400 "Error").
        let currentCredential = await activeCredential
        let forceStream = switch currentCredential {
        case .oauthToken: true
        case .apiKey: false
        }

        let request = await makeRequest(prompt: prompt, modelId: modelId, stream: forceStream)

        // Debug: dump the request body to a file for diagnosis
        if let body = request.httpBody {
            let debugPath = NSHomeDirectory() + "/.aozora/debug-last-request.json"
            try? body.write(to: URL(fileURLWithPath: debugPath))
        }

        if forceStream {
            return try await collectStreamingResponse(request: request, startTime: startTime)
        }

        // Non-streaming path (API key auth only)
        let (data, _) = try await performRequestWithRetry(request, failFastOn429: failFastOn429)

        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw CIMSError.modelError("Invalid JSON response")
        }

        let elapsed = ContinuousClock.now - startTime
        return Self.parseResponse(json: json, latency: elapsed)
    }

    /// Run a streaming inference call against the Anthropic Messages API.
    ///
    /// Makes a preflight `data(for:)` request to validate the request with retry,
    /// then issues the actual streaming `bytes(for:)` call. This ensures transient errors
    /// are retried before committing to a stream.
    ///
    /// - Parameters:
    ///   - prompt: The pre-built prompt containing system blocks, messages, and tools.
    ///   - tier: The model tier, mapped to an Anthropic model ID.
    /// - Returns: An async stream of model deltas.
    /// - Throws: ``CIMSError/modelError(_:)`` on network or API errors,
    ///   ``CIMSError/contextOverflow(_:_:)`` when the request exceeds the model's context window.
    public nonisolated func stream(
        _ prompt: Prompt, tier: ModelTier,
    ) async throws -> AsyncThrowingStream<ModelDelta, any Error> {
        let modelId = await resolveModel(for: tier)
        let streamRequest = await makeRequest(prompt: prompt, modelId: modelId, stream: true)
        let resolvedSession = session

        // Use the retry layer with a non-streaming probe first to handle transient errors.
        let probeRequest = await makeRequest(prompt: prompt, modelId: modelId, stream: false)
        _ = try await performRequestWithRetry(probeRequest)

        // Probe succeeded — now issue the real streaming request.
        let asyncBytes: URLSession.AsyncBytes
        let response: URLResponse

        do {
            (asyncBytes, response) = try await resolvedSession.bytes(for: streamRequest)
        } catch {
            throw CIMSError.modelError("Network error: \(error.localizedDescription)")
        }

        guard let httpResponse = response as? HTTPURLResponse else {
            throw CIMSError.modelError("Invalid response type")
        }

        if httpResponse.statusCode != 200 {
            let errorBody = await readErrorBody(asyncBytes)
            try classifyAndThrowError(statusCode: httpResponse.statusCode, body: errorBody)
        }

        return AsyncThrowingStream { continuation in
            Task {
                var toolAccum = ToolBlockAccumulator()
                var stopReason = "end_turn"

                do {
                    for try await line in asyncBytes.lines {
                        guard !Task.isCancelled else {
                            continuation.finish()
                            return
                        }

                        guard let (eventType, json) = Self.parseSSELine(line) else { continue }

                        switch eventType {
                        case "content_block_start":
                            toolAccum.handleBlockStart(json)

                        case "content_block_delta":
                            if let delta = json["delta"] as? [String: Any] {
                                if let text = delta["text"] as? String,
                                   delta["type"] as? String == "text_delta" {
                                    continuation.yield(ModelDelta(text: text, toolCall: nil))
                                }
                                toolAccum.handleDelta(delta)
                            }

                        case "content_block_stop":
                            if let call = toolAccum.handleBlockStop() {
                                continuation.yield(ModelDelta(text: nil, toolCall: call))
                            }

                        case "message_delta":
                            if let delta = json["delta"] as? [String: Any],
                               let sr = delta["stop_reason"] as? String {
                                stopReason = sr
                            }

                        default:
                            break
                        }
                    }
                } catch {
                    continuation.finish(throwing: CIMSError.modelError("Stream error: \(error.localizedDescription)"))
                    return
                }

                // Yield a sentinel delta carrying the stop reason for the coordinator
                continuation.yield(ModelDelta(text: nil, toolCall: nil, stopReason: stopReason))
                continuation.finish()
            }
        }
    }

    // MARK: - SSE Event Parsing

    /// Parse an SSE data line into a typed JSON event dictionary.
    ///
    /// Extracts the `data: ` payload, parses it as JSON, and returns both the
    /// event type string and the full JSON dictionary. Returns `nil` for non-data lines,
    /// `[DONE]` sentinels, and unparseable payloads.
    ///
    /// - Parameter line: A raw SSE line from the stream.
    /// - Returns: The event type and JSON dictionary, or `nil` if the line is not a valid event.
    private nonisolated static func parseSSELine(_ line: String) -> (type: String, json: [String: Any])? {
        guard line.hasPrefix("data: ") else { return nil }
        let data = String(line.dropFirst(6))
        if data == "[DONE]" { return nil }

        guard let eventData = data.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: eventData) as? [String: Any],
              let eventType = json["type"] as? String
        else { return nil }

        return (eventType, json)
    }

    /// Mutable state machine for accumulating a tool-use block across SSE events.
    ///
    /// Encapsulates the `content_block_start` / `content_block_delta` / `content_block_stop`
    /// lifecycle for tool-use blocks. Both `stream()` and `collectStreamingResponseOnce()`
    /// use this to avoid duplicating the tool accumulation logic.
    private struct ToolBlockAccumulator {
        /// Name of the tool currently being accumulated, or `nil` if no tool block is open.
        private var name: String?

        /// Tool use ID for the current block.
        private var id = ""

        /// Accumulated JSON input for the current block.
        private var inputJSON = ""

        /// Handle a `content_block_start` event.
        ///
        /// If the block is a `tool_use` type, initializes the accumulation state.
        mutating func handleBlockStart(_ json: [String: Any]) {
            guard let contentBlock = json["content_block"] as? [String: Any],
                  let blockType = contentBlock["type"] as? String,
                  blockType == "tool_use"
            else { return }

            name = contentBlock["name"] as? String
            id = contentBlock["id"] as? String ?? ""
            inputJSON = ""
        }

        /// Handle a `content_block_delta` event for tool input accumulation.
        ///
        /// Appends partial JSON to the current tool input buffer.
        ///
        /// - Parameter delta: The `delta` sub-dictionary from the event.
        mutating func handleDelta(_ delta: [String: Any]) {
            guard let deltaType = delta["type"] as? String,
                  deltaType == "input_json_delta",
                  let partial = delta["partial_json"] as? String
            else { return }

            inputJSON += partial
        }

        /// Handle a `content_block_stop` event, finalizing the tool call if one was open.
        ///
        /// - Returns: The completed ``ToolCall``, or `nil` if no tool block was open.
        mutating func handleBlockStop() -> ToolCall? {
            guard let toolName = name else { return nil }

            let call = ToolCall(id: id, name: toolName, arguments: inputJSON)
            name = nil
            id = ""
            inputJSON = ""
            return call
        }
    }

    // MARK: - Request Building

    /// The request body combining prompt content with transport config.
    ///
    /// This is the only place where model ID, max tokens, and streaming flag are serialized.
    /// The prompt's system blocks, messages, and tools are included by composition.
    private struct RequestBody: Encodable {
        let model: String
        let max_tokens: Int
        let stream: Bool
        let cache_control: CacheControl
        let system: [SystemBlock]
        let messages: [APIMessage]
        let tools: [ToolSchema]?

        /// Top-level automatic caching. The API places the breakpoint at the last
        /// cacheable block and walks backward up to 20 blocks to find a prior cache
        /// entry. This eliminates the need for manual boundary computation.
        struct CacheControl: Encodable {
            let type: String
        }

        func encode(to encoder: any Encoder) throws {
            var container = encoder.container(keyedBy: CodingKeys.self)
            try container.encode(model, forKey: .model)
            try container.encode(max_tokens, forKey: .max_tokens)
            try container.encode(stream, forKey: .stream)
            try container.encode(cache_control, forKey: .cache_control)
            try container.encode(system, forKey: .system)
            try container.encode(messages, forKey: .messages)
            if let tools, !tools.isEmpty {
                try container.encode(tools, forKey: .tools)
            }
        }

        private enum CodingKeys: String, CodingKey {
            case model
            case max_tokens
            case stream
            case cache_control
            case system
            case messages
            case tools
        }
    }

    /// Build a URLRequest from a ``Prompt`` and transport config.
    ///
    /// Encodes the prompt's system/messages/tools alongside provider-owned
    /// fields (model, max_tokens, stream) using the deterministic JSONEncoder
    /// with sorted keys.
    ///
    /// - Parameters:
    ///   - prompt: The typed prompt containing system blocks, messages, and tool schemas.
    ///   - modelId: The resolved Anthropic model ID string.
    ///   - stream: Whether to enable SSE streaming.
    /// - Returns: A configured URL request ready for execution.
    private func makeRequest(prompt: Prompt, modelId: String, stream: Bool) -> URLRequest {
        var request = URLRequest(url: URL(string: baseURL)!)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(apiVersion, forHTTPHeaderField: "anthropic-version")

        switch activeCredential {
        case let .apiKey(key):
            request.setValue(key, forHTTPHeaderField: "x-api-key")
            request.setValue("prompt-caching-2024-07-31", forHTTPHeaderField: "anthropic-beta")
        case let .oauthToken(token, _, _):
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
            request.setValue("claude-code-20250219,oauth-2025-04-20,prompt-caching-2024-07-31,interleaved-thinking-2025-05-14", forHTTPHeaderField: "anthropic-beta")
            request.setValue("true", forHTTPHeaderField: "anthropic-dangerous-direct-browser-access")
            request.setValue("Aozora/1.0", forHTTPHeaderField: "User-Agent")
        }

        let body = RequestBody(
            model: modelId,
            max_tokens: maxTokens,
            stream: stream,
            cache_control: .init(type: "ephemeral"),
            system: prompt.system,
            messages: prompt.messages,
            tools: prompt.tools.isEmpty ? nil : prompt.tools,
        )
        request.httpBody = try? Self.deterministicEncoder.encode(body)
        return request
    }

    // MARK: - Streaming Response Collection

    /// SSE-level errors that can occur inside an otherwise successful (200) stream.
    private enum StreamError: Error {
        case sseError(type: String, message: String)

        var isRetryable: Bool {
            switch self {
            case let .sseError(type, _):
                type == "overloaded_error" || type == "rate_limit_error" || type == "api_error"
            }
        }
    }

    /// Collect a streaming SSE response with retry for transient errors.
    ///
    /// Wraps `collectStreamingResponseOnce` with exponential backoff retry
    /// for overloaded_error and rate_limit_error SSE events that arrive
    /// inside an otherwise successful (HTTP 200) stream.
    private nonisolated func collectStreamingResponse(
        request: URLRequest,
        startTime: ContinuousClock.Instant,
    ) async throws -> ModelResponse {
        let maxRetries = 3
        for attempt in 0 ... maxRetries {
            do {
                return try await collectStreamingResponseOnce(request: request, startTime: startTime)
            } catch let error as CIMSError {
                // Let .rateLimited propagate immediately for credential rotation
                throw error
            } catch let error as StreamError where error.isRetryable && attempt < maxRetries {
                let delay = min(60.0, pow(2.0, Double(attempt)) + Double.random(in: 0 ... 1))
                print("[stream] Retryable SSE error (attempt \(attempt + 1)/\(maxRetries + 1)): \(error). Retrying in \(String(format: "%.0f", delay))s...")
                try? await Task.sleep(for: .seconds(delay))
                continue
            } catch let error as StreamError {
                switch error {
                case let .sseError(type, message):
                    throw CIMSError.modelError("Stream error: \(type) — \(message)")
                }
            }
        }
        throw CIMSError.modelError("Stream failed after \(maxRetries + 1) attempts")
    }

    /// Single attempt at collecting a streaming response.
    private nonisolated func collectStreamingResponseOnce(
        request: URLRequest,
        startTime: ContinuousClock.Instant,
    ) async throws -> ModelResponse {
        let resolvedSession = session
        let asyncBytes: URLSession.AsyncBytes
        let response: URLResponse

        do {
            (asyncBytes, response) = try await resolvedSession.bytes(for: request)
        } catch {
            throw CIMSError.modelError("Network error: \(error.localizedDescription)")
        }

        guard let httpResponse = response as? HTTPURLResponse else {
            throw CIMSError.modelError("Invalid response type")
        }

        if httpResponse.statusCode != 200 {
            let errorBody = await readErrorBody(asyncBytes)
            // Surface 429 as .rateLimited so credential rotation can catch it
            if httpResponse.statusCode == 429 {
                let retryAfter = Self.parseRetryAfter(httpResponse.value(forHTTPHeaderField: "Retry-After"))
                throw CIMSError.rateLimited(retryAfter: retryAfter, message: errorBody)
            }
            try classifyAndThrowError(statusCode: httpResponse.statusCode, body: errorBody)
        }

        var accumulatedText = ""
        var toolCalls: [ToolCall] = []
        var stopReason = "end_turn"
        var inputTokens = 0
        var outputTokens = 0
        var cacheReadTokens = 0
        var cacheCreationTokens = 0
        var toolAccum = ToolBlockAccumulator()

        var eventCount = 0
        var lastEventType = ""
        var lineCount = 0
        for try await line in asyncBytes.lines {
            lineCount += 1
            if lineCount <= 3 {
                print("[stream-debug] line \(lineCount): \(String(line.prefix(120)))")
            }

            guard let (eventType, json) = Self.parseSSELine(line) else { continue }

            eventCount += 1
            lastEventType = eventType

            switch eventType {
            case "message_start":
                if let message = json["message"] as? [String: Any],
                   let usage = message["usage"] as? [String: Any] {
                    inputTokens = usage["input_tokens"] as? Int ?? 0
                    cacheReadTokens = usage["cache_read_input_tokens"] as? Int ?? 0
                    cacheCreationTokens = usage["cache_creation_input_tokens"] as? Int ?? 0
                }
            case "content_block_start":
                toolAccum.handleBlockStart(json)
            case "content_block_delta":
                if let delta = json["delta"] as? [String: Any] {
                    if let text = delta["text"] as? String,
                       delta["type"] as? String == "text_delta" {
                        accumulatedText += text
                    }
                    toolAccum.handleDelta(delta)
                }
            case "content_block_stop":
                if let call = toolAccum.handleBlockStop() {
                    toolCalls.append(call)
                }
            case "message_delta":
                if let delta = json["delta"] as? [String: Any] {
                    if let sr = delta["stop_reason"] as? String { stopReason = sr }
                }
                if let usage = json["usage"] as? [String: Any] {
                    outputTokens = usage["output_tokens"] as? Int ?? outputTokens
                }
            case "error":
                let errorInfo = json["error"] as? [String: Any]
                let errorType = errorInfo?["type"] as? String ?? "unknown"
                let errorMessage = errorInfo?["message"] as? String ?? "Unknown error"
                print("[stream] SSE error event: \(errorType) — \(errorMessage)")
                throw StreamError.sseError(type: errorType, message: errorMessage)
            default:
                break
            }
        }

        print("[stream] lines=\(lineCount) events=\(eventCount) lastEvent=\(lastEventType) text=\(accumulatedText.count)chars tools=\(toolCalls.count) stop=\(stopReason)")

        let elapsed = ContinuousClock.now - startTime
        return ModelResponse(
            content: accumulatedText,
            toolCalls: toolCalls,
            tokenUsage: TokenUsage(
                inputTokens: inputTokens,
                outputTokens: outputTokens,
                cacheReadTokens: cacheReadTokens,
                cacheCreationTokens: cacheCreationTokens,
            ),
            latency: elapsed,
            stopReason: stopReason,
        )
    }

    // MARK: - Response Parsing

    /// Parse an Anthropic Messages API JSON response into a ``ModelResponse``.
    ///
    /// Extracts content blocks (text and tool_use), usage stats, and stop_reason.
    /// Tool use blocks include the `id` field for tool_result correlation.
    ///
    /// - Parameters:
    ///   - json: The parsed JSON response dictionary.
    ///   - latency: The measured request latency.
    /// - Returns: A complete ``ModelResponse``.
    nonisolated static func parseResponse(json: [String: Any], latency: Duration) -> ModelResponse {
        var accumulatedText = ""
        var toolCalls: [ToolCall] = []

        if let content = json["content"] as? [[String: Any]] {
            for block in content {
                guard let blockType = block["type"] as? String else { continue }
                if blockType == "text", let text = block["text"] as? String {
                    accumulatedText += text
                } else if blockType == "tool_use",
                          let name = block["name"] as? String {
                    let blockId = block["id"] as? String ?? ""
                    let inputJSON = if let input = block["input"] {
                        if let inputData = try? JSONSerialization.data(withJSONObject: input) {
                            String(data: inputData, encoding: .utf8) ?? "{}"
                        } else {
                            "{}"
                        }
                    } else {
                        "{}"
                    }
                    toolCalls.append(ToolCall(id: blockId, name: name, arguments: inputJSON))
                }
            }
        }

        var inputTokens = 0
        var outputTokens = 0
        var cacheReadTokens = 0
        var cacheCreationTokens = 0
        if let usage = json["usage"] as? [String: Any] {
            inputTokens = usage["input_tokens"] as? Int ?? 0
            outputTokens = usage["output_tokens"] as? Int ?? 0
            cacheReadTokens = usage["cache_read_input_tokens"] as? Int ?? 0
            cacheCreationTokens = usage["cache_creation_input_tokens"] as? Int ?? 0
        }

        let stopReason = json["stop_reason"] as? String ?? "end_turn"

        return ModelResponse(
            content: accumulatedText,
            toolCalls: toolCalls,
            tokenUsage: TokenUsage(
                inputTokens: inputTokens,
                outputTokens: outputTokens,
                cacheReadTokens: cacheReadTokens,
                cacheCreationTokens: cacheCreationTokens,
            ),
            latency: latency,
            stopReason: stopReason,
        )
    }

    // MARK: - Retry Logic

    /// HTTP status codes that are transient and safe to retry.
    private nonisolated static let retryableStatusCodes: Set<Int> = [429, 500, 502, 503, 529]

    /// HTTP status codes that indicate a permanent client error (never retry).
    private nonisolated static let nonRetryableStatusCodes: Set<Int> = [400, 401, 403, 404, 413]

    /// Execute an HTTP request with exponential backoff retry for transient errors.
    ///
    /// Uses `data(for:)` to get the full response body, enabling reliable status code
    /// checking and error body parsing during retry. Retries on status codes 429 (rate limit),
    /// 500, 502, 503, and 529 (overloaded). On 429, the `Retry-After` header is used as
    /// the minimum backoff if present.
    ///
    /// Backoff schedule: 1s, 2s, 4s, 8s, 16s with random jitter (0-25%).
    ///
    /// - Parameter request: The URL request to execute.
    /// - Returns: The response data and HTTP response from the successful attempt.
    /// - Throws: ``CIMSError/modelError(_:)`` if all retries are exhausted,
    ///   ``CIMSError/contextOverflow(_:_:)`` for context-length errors.
    /// - Parameter failFastOn429: When `true`, throw `.rateLimited` immediately
    ///   on the first 429 instead of retrying. Used when credential rotation is available.
    private nonisolated func performRequestWithRetry(
        _ request: URLRequest,
        failFastOn429: Bool = false,
    ) async throws -> (Data, HTTPURLResponse) {
        let resolvedSession = session
        let resolvedMaxRetries = maxRetries

        var lastError: (any Error)?
        var lastStatusCode = 0
        var lastBody = ""

        for attempt in 0 ... resolvedMaxRetries {
            do {
                let (data, response) = try await resolvedSession.data(for: request)

                guard let httpResponse = response as? HTTPURLResponse else {
                    throw CIMSError.modelError("Invalid response type")
                }

                let statusCode = httpResponse.statusCode
                lastStatusCode = statusCode

                if statusCode == 200 {
                    return (data, httpResponse)
                }

                if Self.nonRetryableStatusCodes.contains(statusCode) {
                    let body = String(data: data, encoding: .utf8) ?? ""
                    try classifyAndThrowError(statusCode: statusCode, body: body)
                }

                if Self.retryableStatusCodes.contains(statusCode) {
                    lastBody = String(data: data, encoding: .utf8) ?? ""

                    // On 429 with credential rotation available, fail immediately
                    // so the caller can switch credentials without wasting retries.
                    if statusCode == 429, failFastOn429 {
                        let retryAfter = Self.parseRetryAfter(httpResponse.value(forHTTPHeaderField: "Retry-After"))
                        throw CIMSError.rateLimited(retryAfter: retryAfter, message: lastBody)
                    }

                    if attempt < resolvedMaxRetries {
                        let backoff = Self.computeBackoff(
                            attempt: attempt,
                            retryAfterHeader: httpResponse.value(forHTTPHeaderField: "Retry-After"),
                        )
                        try await Task.sleep(for: backoff)
                        continue
                    }
                    if statusCode == 429 {
                        let retryAfter = Self.parseRetryAfter(httpResponse.value(forHTTPHeaderField: "Retry-After"))
                        throw CIMSError.rateLimited(retryAfter: retryAfter, message: lastBody)
                    }
                    throw CIMSError.modelError("API error (\(statusCode)) after \(resolvedMaxRetries + 1) attempts: \(lastBody)")
                }

                let body = String(data: data, encoding: .utf8) ?? ""
                throw CIMSError.modelError("API error (\(statusCode)): \(body)")

            } catch let error as CIMSError {
                throw error
            } catch is CancellationError {
                throw CIMSError.modelError("Request cancelled")
            } catch {
                lastError = error
                if attempt < resolvedMaxRetries {
                    let backoff = Self.computeBackoff(attempt: attempt, retryAfterHeader: nil)
                    try await Task.sleep(for: backoff)
                    continue
                }
            }
        }

        throw CIMSError.modelError(
            "Network error after \(resolvedMaxRetries + 1) attempts: \(lastError?.localizedDescription ?? "status \(lastStatusCode)")",
        )
    }

    /// Compute the backoff duration for a retry attempt with jitter.
    ///
    /// Uses exponential backoff: `2^attempt` seconds, starting at 1s.
    /// If a `Retry-After` header is present and specifies a longer delay, that value
    /// is used as the minimum. Random jitter of 0-25% is added to prevent thundering herd.
    ///
    /// - Parameters:
    ///   - attempt: Zero-based attempt index (0 = first retry).
    ///   - retryAfterHeader: The `Retry-After` header value, if present.
    /// - Returns: The computed backoff duration.
    nonisolated static func computeBackoff(attempt: Int, retryAfterHeader: String?) -> Duration {
        let baseSeconds = Double(1 << attempt)
        let jitter = Double.random(in: 0 ... 0.25) * baseSeconds
        var backoffSeconds = baseSeconds + jitter

        if let retryAfterValue = retryAfterHeader,
           let retryAfterSeconds = Double(retryAfterValue) {
            backoffSeconds = max(backoffSeconds, retryAfterSeconds)
        }

        return .milliseconds(Int(backoffSeconds * 1_000))
    }

    // MARK: - Credential Rotation

    /// Mark the currently active credential as rate-limited and advance to the next one.
    ///
    /// Uses the `Retry-After` value from the API response to set the cooldown.
    /// Defaults to 5 minutes if no value is provided.
    ///
    /// - Parameter retryAfter: Seconds until the credential should be retried.
    private func markCurrentCredentialRateLimited(retryAfter: TimeInterval = 300) {
        // Clamp to at least 30s (avoid thrashing) and at most 24h (sanity bound)
        let clamped = min(max(retryAfter, 30), 86_400)
        rateLimitedUntil[credentialIndex] = ContinuousClock.now + .seconds(clamped)
        let rateLimitedName = credentialNames[credentialIndex]
        // Advance to next non-rate-limited credential
        _ = activeCredential
        let nextName = credentialNames[credentialIndex]

        let hours = Int(clamped) / 3_600
        let minutes = (Int(clamped) % 3_600) / 60
        let cooldownStr = hours > 0 ? "\(hours)h\(minutes)m" : "\(minutes)m"
        Log.info("provider", "Rate limited: \(rateLimitedName) → \(nextName) (retry-after: \(cooldownStr), raw: \(Int(retryAfter))s)")
    }

    /// Parse a `Retry-After` header value into seconds.
    ///
    /// Returns a default of 300s (5 minutes) if the header is missing or unparseable.
    private nonisolated static func parseRetryAfter(_ header: String?) -> TimeInterval {
        guard let value = header, let seconds = TimeInterval(value) else {
            return 300
        }
        return seconds
    }

    // MARK: - Error Classification

    /// Classify an HTTP error response and throw the appropriate ``CIMSError``.
    ///
    /// Detects context overflow conditions from:
    /// - HTTP 413 (Request Entity Too Large)
    /// - HTTP 400 with body containing "context_length", "maximum context length", or "too many tokens"
    ///
    /// - Parameters:
    ///   - statusCode: The HTTP status code.
    ///   - body: The error response body text.
    /// - Throws: ``CIMSError/contextOverflow(_:_:)`` for token limit errors,
    ///   ``CIMSError/modelError(_:)`` for all other errors.
    private nonisolated func classifyAndThrowError(statusCode: Int, body: String) throws -> Never {
        if statusCode == 413 {
            let (actual, max) = Self.parseTokenCounts(from: body)
            throw CIMSError.contextOverflow(actual, max)
        }

        let bodyLower = body.lowercased()
        if statusCode == 400,
           bodyLower.contains("context_length")
           || bodyLower.contains("maximum context length")
           || bodyLower.contains("too many tokens") {
            let (actual, max) = Self.parseTokenCounts(from: body)
            throw CIMSError.contextOverflow(actual, max)
        }

        throw CIMSError.modelError("API error (\(statusCode)): \(body)")
    }

    /// Parse token counts from an Anthropic API error body.
    ///
    /// Attempts to extract the actual and maximum token counts from error messages.
    /// Falls back to zero if parsing fails.
    ///
    /// - Parameter body: The error response body text.
    /// - Returns: A tuple of (actual token count, maximum token count), defaulting to 0 if unparseable.
    nonisolated static func parseTokenCounts(from body: String) -> (actual: Int, max: Int) {
        let pattern = #"(\d[\d,]+)\s*tokens?\s*>?\s*(\d[\d,]+)\s*(maximum|limit|max)?"#
        guard let regex = try? NSRegularExpression(pattern: pattern, options: .caseInsensitive),
              let match = regex.firstMatch(in: body, range: NSRange(body.startIndex..., in: body)),
              match.numberOfRanges >= 3,
              let actualRange = Range(match.range(at: 1), in: body),
              let maxRange = Range(match.range(at: 2), in: body)
        else {
            return (0, 0)
        }

        let actualStr = body[actualRange].replacingOccurrences(of: ",", with: "")
        let maxStr = body[maxRange].replacingOccurrences(of: ",", with: "")

        return (Int(actualStr) ?? 0, Int(maxStr) ?? 0)
    }

    // MARK: - Model Resolution

    /// Resolve a ``ModelTier`` to an Anthropic model ID string.
    private func resolveModel(for tier: ModelTier) -> String {
        if let override = modelOverrides[tier] {
            return override
        }

        return switch tier {
        case .executive:
            "claude-opus-4-6"
        case .workerDefault, .consolidation:
            "claude-sonnet-4-6"
        case .workerLight, .salience:
            "claude-haiku-4-5-20251001"
        }
    }

    // MARK: - Factory

    /// Create a provider configured from the given ``ConfigStore``.
    ///
    /// Reads `provider.*` keys for maxTokens, thinking mode, effort level, and retry count.
    /// Model tier mappings are read from `model.*` keys. Falls back to ``ConfigKey`` defaults
    /// when values are not explicitly set.
    ///
    /// - Parameters:
    ///   - credentials: Authentication credentials sorted by priority.
    ///   - credentialNames: Human-readable names for logging (parallel to credentials).
    ///   - configStore: Config store to read provider settings from.
    /// - Returns: A configured provider instance.
    public static func fromConfig(
        credentials: [ClaudeCredential],
        credentialNames: [String] = [],
        configStore: ConfigStore,
    ) async -> AnthropicProvider {
        let maxTokens = await configStore.getInt(.providerMaxTokens)
        let maxRetries = await configStore.getInt(.providerMaxRetries)

        let thinkingStr = await configStore.get(.providerThinking)
        let thinking: ThinkingMode = switch thinkingStr {
        case "disabled": .disabled
        case "adaptive": .adaptive
        default:
            if let budget = Int(thinkingStr) {
                .enabled(budgetTokens: budget)
            } else {
                .adaptive
            }
        }

        let effortStr = await configStore.get(.providerEffort)
        let effort = Effort(rawValue: effortStr) ?? .high

        let executiveModel = await configStore.get(.executiveModel)
        let workerModel = await configStore.get(.workerModel)
        let consolidationModel = await configStore.get(.consolidationModel)

        return AnthropicProvider(
            credentials: credentials,
            credentialNames: credentialNames,
            modelOverrides: [
                .executive: executiveModel,
                .workerDefault: workerModel,
                .consolidation: consolidationModel,
            ],
            maxTokens: maxTokens,
            thinking: thinking,
            effort: effort,
            maxRetries: maxRetries,
        )
    }

    /// Convenience factory for a single credential.
    ///
    /// Wraps the credential in a single-element array. Use the multi-credential
    /// variant for daemon deployment with rate-limit fallback.
    public static func fromConfig(
        credential: ClaudeCredential,
        configStore: ConfigStore,
    ) async -> AnthropicProvider {
        await fromConfig(credentials: [credential], configStore: configStore)
    }

    // MARK: - Helpers

    /// Read error response body from async bytes stream.
    private nonisolated func readErrorBody(_ bytes: URLSession.AsyncBytes) async -> String {
        var body = ""
        do {
            for try await line in bytes.lines {
                body += line
                if body.count > 500 { break }
            }
        } catch {}
        return String(body.prefix(200))
    }
}
