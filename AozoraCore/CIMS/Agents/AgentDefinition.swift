import Foundation

/// A named agent configuration with distinct personality, model, and tool access.
///
/// Agents share the same daemon infrastructure (database, MCP, Discord) but can have
/// different system prompts, models, identity blocks, and tool restrictions.
/// This enables running specialized "characters" (research agent, coding agent, etc.)
/// through a single daemon instance.
///
/// Agent definitions are loaded from JSON files in `~/.aozora/agents/`.
public struct AgentDefinition: Sendable, Codable, Equatable {
    /// Unique name for this agent (e.g., "assistant", "researcher").
    public let name: String

    /// Human-readable description.
    public let description: String

    /// Model to use for this agent's inference. Overrides the executive model config.
    public let model: String?

    /// Path to the system prompt markdown file.
    public let systemPromptPath: String?

    /// Identity block key. `"default"` uses the main identity store.
    public let identityBlock: String

    /// Allowed tool names. `["*"]` means all tools. Empty means no tools.
    public let tools: [String]

    /// Channel routing patterns. `"discord:*"` routes all Discord messages.
    /// `"command:<name>"` routes `/agent <name>` commands.
    public let channels: [String]
}
