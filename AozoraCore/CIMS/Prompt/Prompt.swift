/// The logical content of an API request — system, messages, and tools.
///
/// Immutable value type. Once built, guaranteed valid: messages alternate correctly,
/// every tool_use has a tool_result, content blocks have the right shape.
/// Inspectable: print it, serialize to JSON for debugging, compare across turns.
///
/// **Caching contract:** The `system` array must be completely stable between turns.
/// The API hashes the entire system array as one unit — any byte change invalidates
/// all system-level caches. Volatile state (identity, timestamps) lives in `messages`,
/// not `system`. See ``PromptBuilder`` for the full cache architecture.
public struct Prompt: Sendable, Encodable {
    /// Ordered system blocks with optional cache_control breakpoints.
    public let system: [SystemBlock]
    /// Conversation messages in strict user/assistant alternation.
    public let messages: [APIMessage]
    /// Tool definitions in Anthropic JSON Schema format.
    public let tools: [ToolSchema]

    /// Create a prompt.
    ///
    /// - Parameters:
    ///   - system: Ordered system blocks with optional cache_control breakpoints.
    ///   - messages: Conversation messages in strict user/assistant alternation.
    ///   - tools: Tool definitions in Anthropic JSON Schema format.
    public init(system: [SystemBlock], messages: [APIMessage], tools: [ToolSchema]) {
        self.system = system
        self.messages = messages
        self.tools = tools
    }
}

/// Discriminant for credential type — tells the builder whether to prepend
/// the OAuth identity prefix without exposing actual credentials.
public enum CredentialKind: Sendable {
    /// Standard API key credential.
    case apiKey
    /// OAuth token credential — requires the Claude Code identity prefix in the system prompt.
    case oauth
}
