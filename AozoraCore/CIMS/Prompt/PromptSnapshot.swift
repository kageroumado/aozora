import Foundation

/// Immutable snapshot of a completed turn's prompt, used for heartbeat replay.
///
/// Captured after each real turn completes (with the assistant's response appended).
/// Heartbeats replay this snapshot verbatim — only the heartbeat message changes.
/// This guarantees byte-identical prefixes for cache hits.
///
/// The snapshot includes a third cache breakpoint on the last frozen message
/// (the assistant's response). Combined with the system breakpoint and the
/// stubbing boundary breakpoint, this means heartbeats only pay for the
/// heartbeat message itself (~30 tokens).
public struct PromptSnapshot: Sendable {
    /// System blocks with cache_control on the last block.
    public let system: [SystemBlock]

    /// Tool definitions (frozen between turns).
    public let tools: [ToolSchema]

    /// All messages through the assistant's final response, with cache breakpoints:
    /// - Stubbing boundary message has cache_control (breakpoint 2)
    /// - Last message (assistant response) has cache_control (breakpoint 3)
    public let frozenMessages: [APIMessage]

    /// Creates a snapshot from pre-built components.
    ///
    /// - Parameters:
    ///   - system: The system blocks from the turn's prompt.
    ///   - tools: The tool definitions from the turn's prompt.
    ///   - frozenMessages: All messages including the assistant's final response.
    public init(system: [SystemBlock], tools: [ToolSchema], frozenMessages: [APIMessage]) {
        self.system = system
        self.tools = tools
        self.frozenMessages = frozenMessages
    }

    /// Capture a snapshot from a completed turn's prompt and the model's response.
    ///
    /// Appends the assistant's response as the final message (with cache_control
    /// breakpoint 3), producing a frozen prefix for heartbeat replay.
    ///
    /// - Parameters:
    ///   - buildResult: The prompt build result from the turn.
    ///   - assistantResponse: The model's final response text.
    /// - Returns: A frozen snapshot ready for heartbeat use.
    public static func capture(from buildResult: PromptBuildResult, assistantResponse: String) -> PromptSnapshot {
        var messages = buildResult.prompt.messages
        // Append assistant response with cache_control (breakpoint 3)
        var assistantMsg = APIMessage(role: .assistant, content: .text(assistantResponse))
        assistantMsg.content.addCacheControl()
        messages.append(assistantMsg)

        return PromptSnapshot(
            system: buildResult.prompt.system,
            tools: buildResult.prompt.tools,
            frozenMessages: messages,
        )
    }
}
