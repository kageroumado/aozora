import Foundation

// MARK: - Daemon → App Messages

/// Messages broadcast from the daemon to connected app clients via Unix domain socket.
///
/// Each message is JSON-encoded and newline-delimited on the wire. The app's ``IPCClient``
/// decodes these and surfaces them to managers (``ChatManager``, ``InspectorManager``)
/// for UI display.
public enum IPCOutbound: Codable, Sendable {
    /// A complete chat message (user or assistant).
    case message(IPCChatMessage)

    /// Incremental text during response streaming.
    case streamDelta(text: String)

    /// Signals the end of a streaming response.
    case streamEnd

    /// A tool invocation by the model.
    case toolCall(IPCToolCall)

    /// The result of a tool invocation.
    case toolResult(IPCToolResult)

    /// Inspector telemetry snapshot (response to ``IPCInbound/pollInspector``).
    case inspector(IPCInspectorData)

    /// Daemon status update.
    case status(IPCStatusData)

    /// Paginated message history response.
    case history(messages: [IPCHistoryMessage], hasMore: Bool)
}

/// A chat message relayed over IPC.
public struct IPCChatMessage: Codable, Sendable {
    /// `"user"`, `"assistant"`, or `"system"`.
    public var role: String

    /// The message text content.
    public var content: String

    /// Transport channel (e.g., `"discord"`, `"ipc"`).
    public var channel: String?

    /// Display name of the message author.
    public var author: String?

    /// Unix timestamp (seconds since epoch).
    public var timestamp: Double
}

/// A tool call relayed over IPC.
public struct IPCToolCall: Codable, Sendable {
    /// Tool name (e.g., `"bash"`, `"dispatch_worker"`).
    public var name: String

    /// JSON-encoded tool arguments.
    public var arguments: String

    /// Unique identifier for correlating with ``IPCToolResult``.
    public var id: String
}

/// The result of a tool invocation relayed over IPC.
public struct IPCToolResult: Codable, Sendable {
    /// Correlates with the originating ``IPCToolCall/id``.
    public var id: String

    /// Tool output text.
    public var output: String

    /// Whether the tool returned an error.
    public var isError: Bool
}

/// Inspector telemetry snapshot sent in response to ``IPCInbound/pollInspector``.
///
/// Mirrors the fields exposed by ``InspectorManager`` for the inspector panel.
public struct IPCInspectorData: Codable, Sendable {
    public var temporalMode: String
    public var allostasisMode: String
    public var pressure: Float
    public var contextBudgetUsed: Int
    public var contextBudgetTotal: Int
    public var queueDepth: Int
    public var identityClaimCount: Int
    public var dagNodeCount: Int
    public var messageCount: Int
    public var sessionKey: String
}

/// Daemon status information.
public struct IPCStatusData: Codable, Sendable {
    public var connected: Bool
    public var discord: String
    public var uptime: Double
    public var version: String
}

/// Image data transported over IPC for vision API support.
public struct IPCImageData: Codable, Sendable {
    /// Raw image data (base64-encoded on the wire by Codable).
    public var data: Data

    /// MIME type: `"image/jpeg"`, `"image/png"`, `"image/gif"`, or `"image/webp"`.
    public var mediaType: String

    /// Original filename, if available.
    public var filename: String?

    public init(data: Data, mediaType: String, filename: String? = nil) {
        self.data = data
        self.mediaType = mediaType
        self.filename = filename
    }
}

/// A persisted message returned in history responses.
public struct IPCHistoryMessage: Codable, Sendable {
    /// Database row ID (used as pagination cursor).
    public var id: Int64

    /// Message role: `"user"`, `"assistant"`, `"tool"`, or `"system"`.
    public var role: String

    /// The message text content.
    public var content: String

    /// Unix timestamp (seconds since epoch).
    public var timestamp: Double

    /// The session this message belongs to.
    public var sessionKey: String

    /// Display name of the message author, if available.
    public var author: String?

    /// Tool call parts attached to this assistant message, if any.
    public var toolCalls: [IPCToolCallPart]?

    /// Tool result parts attached to this tool message, if any.
    public var toolResults: [IPCToolResultPart]?

    public init(
        id: Int64,
        role: String,
        content: String,
        timestamp: Double,
        sessionKey: String,
        author: String?,
        toolCalls: [IPCToolCallPart]? = nil,
        toolResults: [IPCToolResultPart]? = nil,
    ) {
        self.id = id
        self.role = role
        self.content = content
        self.timestamp = timestamp
        self.sessionKey = sessionKey
        self.author = author
        self.toolCalls = toolCalls
        self.toolResults = toolResults
    }
}

/// A tool call part from a persisted assistant message.
public struct IPCToolCallPart: Codable, Sendable {
    /// The tool_use block ID.
    public var id: String

    /// Tool name (e.g., `"bash"`, `"read"`).
    public var name: String

    /// JSON-encoded tool arguments.
    public var arguments: String

    public init(id: String, name: String, arguments: String) {
        self.id = id
        self.name = name
        self.arguments = arguments
    }
}

/// A tool result part from a persisted tool message.
public struct IPCToolResultPart: Codable, Sendable {
    /// Correlates with the originating tool call ID.
    public var toolUseId: String

    /// Tool output text.
    public var content: String

    /// Whether the tool returned an error.
    public var isError: Bool

    public init(toolUseId: String, content: String, isError: Bool) {
        self.toolUseId = toolUseId
        self.content = content
        self.isError = isError
    }
}

// MARK: - App → Daemon Messages

/// Messages sent from the app to the daemon via Unix domain socket.
///
/// Each message is JSON-encoded and newline-delimited on the wire. The daemon's
/// ``DaemonIPC`` decodes these and dispatches to the appropriate handler.
public enum IPCInbound: Codable, Sendable {
    /// Request an inspector telemetry snapshot.
    case pollInspector

    /// Request paginated message history.
    ///
    /// - Parameters:
    ///   - sessionKey: Session to fetch from, or `nil` for all conversations.
    ///   - limit: Maximum messages to return (clamped to 1–100 by daemon).
    ///   - beforeId: Cursor for pagination — fetch messages with `id < beforeId`. `nil` = most recent.
    case getHistory(sessionKey: String?, limit: Int, beforeId: Int64?)

    /// Send a message through the daemon, optionally with image attachments.
    case sendMessage(sessionKey: String, text: String, images: [IPCImageData]?)

    /// Request the full assembled context for a session.
    case getContext(sessionKey: String)

    /// Trigger context compaction on specific nodes.
    case compact(sessionKey: String, nodeIds: [String])
}

// MARK: - IPC Errors

/// Errors that can occur during IPC operations.
public enum IPCError: Error, Sendable {
    /// Failed to create the Unix domain socket.
    case socketCreation

    /// Failed to bind the socket to the filesystem path.
    case bindFailed(String)

    /// Failed to connect to the daemon socket.
    case connectionFailed(String)

    /// The IPC connection was lost.
    case disconnected
}
