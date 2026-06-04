/// Pairs tool_use blocks with their corresponding tool_result blocks.
///
/// Orphaned tool calls are structurally impossible — every `tool_use` has
/// exactly one `tool_result` because they come from the same exchange.
///
/// Each exchange expands to exactly two API messages:
/// - `assistant`: optional text block + tool_use blocks
/// - `user`: tool_result blocks + text blocks for injections
public struct ToolExchange: Sendable {
    /// The assistant's text content for this iteration (may be empty).
    public let assistantText: String
    /// The tool calls the assistant made.
    public let calls: [ToolUseBlock]
    /// The results from executing each tool call (1:1 with calls by toolUseId).
    public let results: [ToolResultBlock]
    /// Injected text blocks: interjections, background task completions, system warnings.
    public let injections: [String]

    /// Create a tool exchange.
    ///
    /// - Parameters:
    ///   - assistantText: The assistant's text content for this iteration (may be empty).
    ///   - calls: The tool calls the assistant made.
    ///   - results: The results from executing each tool call (1:1 with calls by toolUseId).
    ///   - injections: Injected text blocks appended to the user turn.
    public init(assistantText: String, calls: [ToolUseBlock], results: [ToolResultBlock], injections: [String]) {
        self.assistantText = assistantText
        self.calls = calls
        self.results = results
        self.injections = injections
    }

    /// Expand this exchange into two API messages (assistant + user).
    ///
    /// The assistant message contains the optional text block followed by all tool_use blocks.
    /// The user message contains all tool_result blocks followed by any injection text blocks.
    /// Messages are omitted entirely when their block list would be empty.
    ///
    /// - Returns: An array of zero, one, or two `APIMessage` values.
    public func toMessages() -> [APIMessage] {
        // Assistant message: text (if non-empty) + tool_use blocks
        var assistantBlocks: [ContentBlock] = []
        if !assistantText.isEmpty {
            assistantBlocks.append(.text(assistantText))
        }
        for call in calls {
            assistantBlocks.append(.toolUse(call))
        }

        // User message: tool_result blocks + injection text blocks
        var userBlocks: [ContentBlock] = []
        for result in results {
            userBlocks.append(.toolResult(result))
        }
        for injection in injections {
            userBlocks.append(.text(injection))
        }

        var messages: [APIMessage] = []
        if !assistantBlocks.isEmpty {
            messages.append(APIMessage(role: .assistant, content: .blocks(assistantBlocks)))
        }
        if !userBlocks.isEmpty {
            messages.append(APIMessage(role: .user, content: .blocks(userBlocks)))
        }
        return messages
    }
}
