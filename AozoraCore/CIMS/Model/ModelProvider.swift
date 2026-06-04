import Foundation

/// Queue-based mock model provider for testing the cognitive cycle without real LLM calls.
///
/// ``MockModelProvider`` is an actor conforming to ``ModelProviding`` that returns
/// pre-enqueued responses in order. When the queue is empty, it falls back to a
/// configurable default response. This enables deterministic testing of the coordinator,
/// context assembler, and turn state machine.
///
/// Responses are enqueued via ``enqueueText(_:)`` and ``enqueueToolCall(name:arguments:followUp:)``.
/// Each `complete` or `stream` call dequeues the next response. Streaming calls emit the
/// response content character-by-character as deltas.
public actor MockModelProvider: ModelProviding {
    /// The response queue — dequeued in FIFO order.
    private var responseQueue: [QueuedResponse] = []

    /// Default response text when the queue is empty.
    private let defaultResponseText: String

    /// Default latency to simulate for each inference call.
    private let simulatedLatency: Duration

    /// A pre-configured response to be returned from inference.
    private enum QueuedResponse {
        /// A pure text response.
        case text(String)

        /// A tool call response with optional follow-up text.
        case toolCall(name: String, arguments: String, followUp: String?)

        /// An error to throw instead of returning a response.
        case error(CIMSError)
    }

    /// Creates a mock model provider with configurable defaults.
    ///
    /// - Parameters:
    ///   - defaultResponse: Text to return when the queue is empty. Defaults to a placeholder.
    ///   - simulatedLatency: Latency to report for each inference call.
    public init(
        defaultResponse: String = "Mock response.",
        simulatedLatency: Duration = .milliseconds(100),
    ) {
        self.defaultResponseText = defaultResponse
        self.simulatedLatency = simulatedLatency
    }

    // MARK: - Queue Management

    /// Enqueue a text response to be returned on the next inference call.
    ///
    /// - Parameter text: The response text to return.
    public func enqueueText(_ text: String) {
        responseQueue.append(.text(text))
    }

    /// Enqueue a tool call response to be returned on the next inference call.
    ///
    /// - Parameters:
    ///   - name: The tool name to call.
    ///   - arguments: JSON-encoded arguments for the tool.
    ///   - followUp: Optional follow-up text after the tool call.
    public func enqueueToolCall(name: String, arguments: String, followUp: String? = nil) {
        responseQueue.append(.toolCall(name: name, arguments: arguments, followUp: followUp))
    }

    /// Enqueue an error to be thrown on the next inference call.
    ///
    /// - Parameter error: The ``CIMSError`` to throw.
    public func enqueueError(_ error: CIMSError) {
        responseQueue.append(.error(error))
    }

    /// The number of responses remaining in the queue.
    public var queueCount: Int {
        responseQueue.count
    }

    // MARK: - ModelProviding Conformance

    /// Run a complete inference call, returning the next queued response.
    ///
    /// Dequeues the next response from the queue. If the queue is empty, returns
    /// the default response. If the next queued entry is an error, it is thrown.
    /// The reported token usage is estimated from the prompt's message count.
    ///
    /// - Parameters:
    ///   - prompt: The pre-built prompt (used only for token usage estimation).
    ///   - tier: Ignored in the mock — all tiers return the same behavior.
    /// - Returns: The dequeued or default model response.
    /// - Throws: ``CIMSError`` if the next queued entry is an error.
    public nonisolated func complete(_ prompt: Prompt, tier _: ModelTier) async throws -> ModelResponse {
        let response = try await dequeueNext()
        let content = response.content
        let toolCalls = response.toolCalls

        let inputTokens = prompt.messages.count * 100
        let outputTokens = max(1, content.utf8.count / 4)
        let stopReason = toolCalls.isEmpty ? "end_turn" : "tool_use"

        return await ModelResponse(
            content: content,
            toolCalls: toolCalls,
            tokenUsage: TokenUsage(inputTokens: inputTokens, outputTokens: outputTokens),
            latency: getLatency(),
            stopReason: stopReason,
        )
    }

    /// Run a streaming inference call, returning the next queued response as deltas.
    ///
    /// Emits one delta per character of the response content. Tool calls are emitted
    /// as a single delta after the text content.
    ///
    /// - Parameters:
    ///   - prompt: The pre-built prompt (unused in mock).
    ///   - tier: Ignored in the mock.
    /// - Returns: An async stream of model deltas.
    public nonisolated func stream(
        _: Prompt, tier _: ModelTier,
    ) async throws -> AsyncThrowingStream<ModelDelta, any Error> {
        let response = try await dequeueNext()
        let content = response.content
        let toolCalls = response.toolCalls

        return AsyncThrowingStream { continuation in
            for char in content {
                continuation.yield(ModelDelta(text: String(char), toolCall: nil))
            }
            for toolCall in toolCalls {
                continuation.yield(ModelDelta(text: nil, toolCall: toolCall))
            }
            continuation.finish()
        }
    }

    // MARK: - Internal

    /// Dequeue the next response, or return the default.
    ///
    /// - Throws: ``CIMSError`` if the next queued entry is an error.
    private func dequeueNext() throws -> (content: String, toolCalls: [ToolCall]) {
        guard !responseQueue.isEmpty else {
            return (defaultResponseText, [])
        }

        let queued = responseQueue.removeFirst()

        switch queued {
        case let .text(text):
            return (text, [])
        case let .toolCall(name, arguments, followUp):
            let call = ToolCall(id: "mock_\(UUID().uuidString)", name: name, arguments: arguments)
            return (followUp ?? "", [call])
        case let .error(error):
            throw error
        }
    }

    /// Get the simulated latency.
    private func getLatency() -> Duration {
        simulatedLatency
    }
}
