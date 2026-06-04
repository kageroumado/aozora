import Foundation

/// View-layer message type for the chat UI.
///
/// Not persisted — CIMS MemoryStore handles persistence internally.
/// This type is optimized for SwiftUI binding with mutable status and
/// ordered content blocks that grow during streaming.
@Observable
final class ChatMessage: Identifiable {
    /// Unique message identifier.
    let id: String

    /// The role of the message sender.
    let role: MessageRole

    /// When the message was created.
    let timestamp: Date

    /// Current delivery/streaming status.
    var status: MessageStatus

    /// Ordered content blocks — text and tool calls interleaved in arrival order.
    var blocks: [ContentBlock] = []

    /// Hold message from the coordinator (e.g., "Reducing context window...").
    var holdMessage: String?

    /// Creates a new chat message.
    ///
    /// - Parameters:
    ///   - id: Unique identifier. Defaults to a new UUID string.
    ///   - role: Message sender role.
    ///   - text: Initial message text. A text block is created if non-empty.
    ///   - timestamp: Creation time. Defaults to now.
    ///   - status: Initial status. Defaults to `.sending`.
    init(
        id: String = UUID().uuidString,
        role: MessageRole,
        text: String,
        timestamp: Date = .now,
        status: MessageStatus = .sending,
    ) {
        self.id = id
        self.role = role
        self.timestamp = timestamp
        self.status = status
        if !text.isEmpty {
            blocks.append(ContentBlock(text: text))
        }
    }

    // MARK: - Convenience Accessors

    /// Combined text from all text blocks.
    var textContent: String {
        blocks.compactMap { $0.kind == .text ? $0.text : nil }
            .joined(separator: "\n\n")
    }

    /// All tool calls across blocks, in order.
    var toolCalls: [ToolCallInfo] {
        blocks.compactMap(\.toolCall)
    }

    // MARK: - Block Mutation

    /// Append text to the last text block, or create a new one.
    ///
    /// This naturally handles interleaving: after a tool call block,
    /// a new text block is created for post-tool response text.
    func appendText(_ newText: String) {
        if let lastBlock = blocks.last, lastBlock.kind == .text {
            lastBlock.text += newText
        } else {
            blocks.append(ContentBlock(text: newText))
        }
    }

    /// Append a tool call as a new block.
    func appendToolCall(_ tool: ToolCallInfo) {
        blocks.append(ContentBlock(toolCall: tool))
    }

    /// Append an image as a new block.
    ///
    /// - Parameters:
    ///   - data: Raw image data (PNG, JPEG, etc.).
    ///   - mediaType: MIME type of the image (e.g., `"image/png"`).
    func appendImage(data: Data, mediaType: String) {
        blocks.append(ContentBlock(imageData: data, mediaType: mediaType))
    }

    // MARK: - Content Block

    /// A single content block within a message — either text or a tool call.
    @Observable
    final class ContentBlock: Identifiable {
        let id: String
        let kind: BlockKind

        /// Text content (for `.text` blocks). Grows during streaming.
        var text: String

        /// Tool call info (for `.toolCall` blocks).
        var toolCall: ToolCallInfo?

        /// Raw image data (for `.image` blocks).
        var imageData: Data?

        /// MIME type of the image (e.g., `"image/png"`, `"image/jpeg"`).
        var imageMediaType: String?

        enum BlockKind {
            case text
            case toolCall
            case image
        }

        init(text: String) {
            self.id = UUID().uuidString
            self.kind = .text
            self.text = text
            self.toolCall = nil
        }

        init(toolCall: ToolCallInfo) {
            self.id = toolCall.id
            self.kind = .toolCall
            self.text = ""
            self.toolCall = toolCall
        }

        init(imageData: Data, mediaType: String) {
            self.id = UUID().uuidString
            self.kind = .image
            self.text = ""
            self.toolCall = nil
            self.imageData = imageData
            self.imageMediaType = mediaType
        }
    }

    /// The role of a message participant.
    nonisolated enum MessageRole {
        case user
        case assistant
        case system
    }

    /// Delivery status of a message.
    nonisolated enum MessageStatus {
        /// Message is being sent to the model.
        case sending
        /// Response is actively streaming.
        case streaming
        /// Message is complete.
        case complete
        /// Message failed with an error description.
        case error(String)
    }
}

/// Tool call indicator for display in assistant message bubbles.
///
/// Shows tool invocations with their status and result previews.
/// Displayed as collapsible pills in the chat UI.
@Observable
final class ToolCallInfo: Identifiable {
    /// Unique tool call identifier.
    let id: String

    /// Internal tool name (e.g., `bash`, `read`, `edit`).
    let name: String

    /// Human-readable display name for the UI (e.g., "bash(ls -la)").
    var displayName: String

    /// Current execution status.
    var status: ToolStatus

    /// The full tool arguments JSON string.
    var arguments: String?

    /// The full tool result content.
    var resultContent: String?

    /// Whether the tool returned an error.
    var isError: Bool = false

    init(
        id: String = UUID().uuidString,
        name: String,
        displayName: String? = nil,
        status: ToolStatus = .running,
        arguments: String? = nil,
        resultContent: String? = nil,
        isError: Bool = false,
    ) {
        self.id = id
        self.name = name
        self.displayName = displayName ?? name
        self.status = status
        self.arguments = arguments
        self.resultContent = resultContent
        self.isError = isError
    }

    /// Short description for the collapsed pill (e.g., "bash(ls -la)").
    var shortDescription: String {
        guard let arguments, let data = arguments.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return name }

        if let cmd = json["command"] as? String {
            return "\(name)(\(cmd.prefix(50)))"
        } else if let path = json["file_path"] as? String {
            return "\(name)(\(path.prefix(50)))"
        } else if let pattern = json["pattern"] as? String {
            return "\(name)(\(pattern.prefix(40)))"
        }
        return name
    }

    /// Execution status of a tool call.
    nonisolated enum ToolStatus {
        /// Tool is currently executing.
        case running
        /// Tool completed successfully.
        case success
        /// Tool execution failed.
        case error
        /// Tool was moved to the background after exceeding its timeout.
        case backgrounded
    }
}
