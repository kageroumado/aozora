import Foundation

// MARK: - Lifecycle Hook Types

/// Decision returned by a plugin's ``beforeToolCall`` hook.
///
/// Determines whether a tool call proceeds, is modified, or is blocked.
/// The first non-proceed decision from any plugin in registration order wins.
public enum ToolCallDecision: Sendable {
    /// Allow the tool call to proceed unchanged.
    case proceed
    /// Modify the tool call's arguments before execution.
    case modify(arguments: String)
    /// Block the tool call entirely with a reason.
    case block(reason: String)
}

/// Event describing a tool call for lifecycle hooks.
///
/// Passed to ``CIMSPlugin/beforeToolCall(_:)`` and ``CIMSPlugin/afterToolCall(_:result:)``
/// hooks so plugins can inspect or modify tool invocations.
public struct ToolCallEvent: Sendable {
    /// The tool name being called.
    public let toolName: String
    /// The JSON-encoded arguments.
    public let arguments: String
    /// The turn ID this tool call belongs to.
    public let turnID: TurnID

    /// Create a tool call event.
    ///
    /// - Parameters:
    ///   - toolName: The tool name being called.
    ///   - arguments: The JSON-encoded arguments.
    ///   - turnID: The turn ID this tool call belongs to.
    public init(toolName: String, arguments: String, turnID: TurnID) {
        self.toolName = toolName
        self.arguments = arguments
        self.turnID = turnID
    }
}

/// Information about a session for lifecycle hooks.
///
/// Provided to ``CIMSPlugin/onSessionStart(_:)`` and ``CIMSPlugin/onSessionEnd(_:)``
/// hooks so plugins can perform setup/teardown per conversation session.
public struct SessionInfo: Sendable {
    /// The session key identifying the conversation.
    public let sessionKey: SessionKey
    /// The user key identifying the participant.
    public let userKey: UserKey
    /// When the session started.
    public let startedAt: Date

    /// Create session info.
    ///
    /// - Parameters:
    ///   - sessionKey: The session key identifying the conversation.
    ///   - userKey: The user key identifying the participant.
    ///   - startedAt: When the session started. Defaults to the current date.
    public init(sessionKey: SessionKey, userKey: UserKey, startedAt: Date = Date()) {
        self.sessionKey = sessionKey
        self.userKey = userKey
        self.startedAt = startedAt
    }
}

// MARK: - Plugin Protocol

/// Core protocol for all CIMS plugins.
///
/// A plugin is a self-contained extension point that can provide tools, messaging channels,
/// or other capabilities to the CIMS coordinator. Plugins are registered with ``PluginRegistry``
/// and activated/deactivated as a group.
///
/// Plugins must be `Sendable` (typically actors) since they're accessed from the coordinator
/// and potentially multiple concurrent turns.
public nonisolated protocol CIMSPlugin: Sendable {
    /// Unique identifier for this plugin instance.
    var id: String { get }

    /// Human-readable name for display and logging.
    var name: String { get }

    /// Activate the plugin, connecting to any external services.
    ///
    /// Called by ``PluginRegistry/activateAll()`` during CIMS startup. Plugins should
    /// establish connections, start listeners, etc. Failures are non-fatal — a plugin
    /// that fails to activate is logged and skipped.
    ///
    /// - Parameter context: Shared plugin context with access to CIMS subsystems.
    func activate(context: PluginContext) async throws

    /// Deactivate the plugin, releasing any external resources.
    ///
    /// Called during CIMS shutdown or when a plugin is unregistered. Plugins should
    /// close connections, cancel background tasks, etc.
    func deactivate() async

    // MARK: - Lifecycle Hooks

    /// Called before a tool is executed.
    ///
    /// Plugins can inspect the tool call and return a ``ToolCallDecision`` to proceed,
    /// modify arguments, or block the call entirely. The first non-proceed decision
    /// from any plugin in registration order wins.
    ///
    /// - Parameter event: The tool call event describing the invocation.
    /// - Returns: A decision to proceed, modify, or block the tool call.
    func beforeToolCall(_ event: ToolCallEvent) async -> ToolCallDecision

    /// Called after a tool has been executed with its result.
    ///
    /// Plugins can use this hook for logging, metrics, auditing, or other
    /// post-execution side effects. The result cannot be modified.
    ///
    /// - Parameters:
    ///   - event: The tool call event describing the invocation.
    ///   - result: The result of the tool execution.
    func afterToolCall(_ event: ToolCallEvent, result: ToolResult) async

    /// Called before sending a prompt to the model for inference.
    ///
    /// Plugins can modify the prompt (e.g., inject system messages, filter tools,
    /// add context). Modifications chain: each plugin receives the prompt as modified
    /// by the previous plugin.
    ///
    /// - Parameter prompt: The assembled prompt about to be sent.
    /// - Returns: The (potentially modified) prompt to send.
    func beforeInference(_ prompt: Prompt) async -> Prompt

    /// Called after receiving a response from the model.
    ///
    /// Plugins can use this hook for logging, metrics, response analysis, or
    /// other post-inference side effects. The response cannot be modified.
    ///
    /// - Parameter response: The model's response.
    func afterInference(_ response: ModelResponse) async

    /// Called when a new session starts.
    ///
    /// Plugins can use this hook to initialize per-session state, open resources,
    /// or emit analytics events.
    ///
    /// - Parameter session: Information about the starting session.
    func onSessionStart(_ session: SessionInfo) async

    /// Called when a session ends.
    ///
    /// Plugins can use this hook to clean up per-session state, flush buffers,
    /// or emit analytics events.
    ///
    /// - Parameter session: Information about the ending session.
    func onSessionEnd(_ session: SessionInfo) async
}

// MARK: - Default Lifecycle Hook Implementations

public extension CIMSPlugin {
    /// Default: allow all tool calls to proceed.
    func beforeToolCall(_: ToolCallEvent) async -> ToolCallDecision {
        .proceed
    }

    /// Default: no-op after tool call.
    func afterToolCall(_: ToolCallEvent, result _: ToolResult) async {}

    /// Default: pass through prompt unmodified.
    func beforeInference(_ prompt: Prompt) async -> Prompt {
        prompt
    }

    /// Default: no-op after inference.
    func afterInference(_: ModelResponse) async {}

    /// Default: no-op on session start.
    func onSessionStart(_: SessionInfo) async {}

    /// Default: no-op on session end.
    func onSessionEnd(_: SessionInfo) async {}
}

// MARK: - Tool Provider

/// A plugin that provides callable tools to the coordinator.
///
/// Tool provider plugins register ``ToolDefinition``s that the executive model can invoke
/// during a turn. When the model returns a tool call matching a registered tool, the
/// coordinator routes it to the owning plugin's ``execute(tool:arguments:context:)`` method.
public nonisolated protocol CIMSToolProvider: CIMSPlugin {
    /// Tool definitions this plugin provides.
    ///
    /// These are included in the context for executive inference, so the model knows
    /// what tools are available. Changes to this list take effect on the next turn.
    var tools: [ToolDefinition] { get async }

    /// Execute a tool call and return the result.
    ///
    /// - Parameters:
    ///   - tool: The tool name (matches a ``ToolDefinition/name``).
    ///   - arguments: JSON-encoded arguments from the model.
    ///   - context: Plugin context for accessing CIMS subsystems.
    /// - Returns: The tool execution result.
    /// - Throws: Any error — the coordinator wraps it in a tool failure response.
    func execute(tool: String, arguments: String, context: PluginContext) async throws -> ToolResult
}

// MARK: - Messaging Channel

/// A plugin that bridges CIMS to an external messaging platform.
///
/// Messaging channels handle bidirectional communication: receiving messages from
/// an external platform (Discord, Telegram, etc.) and sending responses back.
/// Each inbound message is converted to an ``InboundMessage`` and routed through
/// the coordinator as a turn.
public nonisolated protocol MessagingChannel: CIMSPlugin {
    /// Start receiving messages from the external platform.
    ///
    /// Called after ``activate(context:)`` when the channel is ready. The channel
    /// should begin polling or listening for inbound messages.
    func start() async throws

    /// Stop receiving messages from the external platform.
    ///
    /// Called before ``deactivate()`` or when the channel is temporarily paused.
    func stop() async

    /// Send a message to the external platform.
    ///
    /// - Parameter message: The outbound message to send.
    /// - Throws: Platform-specific errors (rate limits, auth failures, network errors).
    func send(_ message: OutboundMessage) async throws

    /// Stream of inbound messages from the external platform.
    ///
    /// The coordinator consumes this stream, creating a ``TurnRequest`` for each message
    /// and routing it through the cognitive cycle.
    var incomingMessages: AsyncStream<InboundMessage> { get async }
}

// MARK: - Plugin Context

/// Shared context provided to plugins during activation and tool execution.
///
/// Gives plugins scoped access to CIMS subsystems without exposing the full
/// coordinator internals. Plugins can read from memory, query identity, and
/// run turns through the coordinator.
public nonisolated struct PluginContext: Sendable {
    /// The coordinator for running cognitive turns.
    public let coordinator: any CIMSCoordinating

    /// Memory store for reading/searching conversation history.
    public let memoryStore: any MemoryStoring

    /// Identity store for reading identity and mirror blocks.
    public let identityStore: any IdentityStoring
}

// MARK: - Tool Result

/// The result of a tool execution.
///
/// Tool results are injected back into the model's context during multi-step
/// reasoning. The ``content`` is the primary output; ``isError`` indicates
/// whether the tool execution failed.
public nonisolated struct ToolResult: Sendable {
    /// The result content (text, JSON, etc.).
    public let content: String

    /// Whether this result represents an error.
    public let isError: Bool

    /// Create a successful tool result.
    public static func success(_ content: String) -> ToolResult {
        ToolResult(content: content, isError: false)
    }

    /// Create a failed tool result.
    public static func failure(_ error: String) -> ToolResult {
        ToolResult(content: error, isError: true)
    }
}

// MARK: - Outbound Message

/// A message to be sent to an external messaging platform.
///
/// Contains the response text and routing metadata so the messaging channel
/// knows where to deliver the response (which thread, which user, etc.).
public nonisolated struct OutboundMessage: Sendable {
    /// The response text content.
    public let text: String

    /// The session key identifying the conversation context.
    public let sessionKey: SessionKey

    /// The user key identifying the recipient.
    public let userKey: UserKey

    /// Optional platform-specific metadata (thread ID, reply-to ID, etc.).
    public let metadata: [String: String]

    public init(
        text: String,
        sessionKey: SessionKey,
        userKey: UserKey,
        metadata: [String: String] = [:],
    ) {
        self.text = text
        self.sessionKey = sessionKey
        self.userKey = userKey
        self.metadata = metadata
    }
}
