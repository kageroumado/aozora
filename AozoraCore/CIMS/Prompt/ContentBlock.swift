import Foundation

/// A single content block within an API message.
///
/// Custom `Encodable`: each case produces the Anthropic-expected JSON shape
/// with a `type` discriminator field.
///
/// Use `.cacheableText` only at the stubbing boundary via `MessageContent.addCacheControl()` —
/// it is not part of the public content-construction API.
public enum ContentBlock: Sendable, Encodable {
    /// A plain text block.
    case text(String)
    /// A tool invocation block produced by the assistant.
    case toolUse(ToolUseBlock)
    /// A tool execution result block sent by the user turn.
    case toolResult(ToolResultBlock)
    /// An image block carrying base64-encoded pixel data.
    case image(ImageBlock)
    /// Internal: text block with optional `cache_control`. Created only by `addCacheControl()`.
    case cacheableText(CacheableTextBlock)

    public func encode(to encoder: any Encoder) throws {
        switch self {
        case let .text(string):
            var container = encoder.container(keyedBy: TextCodingKeys.self)
            try container.encode("text", forKey: .type)
            try container.encode(string, forKey: .text)
        case let .toolUse(block):
            try block.encode(to: encoder)
        case let .toolResult(block):
            try block.encode(to: encoder)
        case let .image(block):
            try block.encode(to: encoder)
        case let .cacheableText(block):
            try block.encode(to: encoder)
        }
    }

    private enum TextCodingKeys: String, CodingKey {
        case type
        case text
    }
}

// MARK: - Equatable

extension ContentBlock: Equatable {
    public static func == (lhs: ContentBlock, rhs: ContentBlock) -> Bool {
        switch (lhs, rhs) {
        case let (.text(l), .text(r)):
            l == r
        case let (.toolUse(l), .toolUse(r)):
            l == r
        case let (.toolResult(l), .toolResult(r)):
            l == r
        case let (.image(l), .image(r)):
            l == r
        case let (.cacheableText(l), .cacheableText(r)):
            l == r
        default:
            false
        }
    }
}

// MARK: - ToolUseBlock

/// A tool invocation content block in an assistant message.
///
/// Encodes as `{"type":"tool_use","id":"...","name":"...","input":{...}}`.
public struct ToolUseBlock: Sendable, Encodable, Equatable {
    /// Unique identifier for this tool invocation, used to correlate with `ToolResultBlock`.
    public let id: String
    /// The name of the tool being invoked.
    public let name: String
    /// The structured arguments passed to the tool.
    public let input: JSONValue

    /// Create a tool use block.
    ///
    /// - Parameters:
    ///   - id: Unique invocation ID (e.g. `"toolu_01abc"`).
    ///   - name: Tool name as registered in the API request.
    ///   - input: Structured input arguments.
    public init(id: String, name: String, input: JSONValue) {
        self.id = id
        self.name = name
        self.input = input
    }

    private enum CodingKeys: String, CodingKey {
        case type
        case id
        case name
        case input
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode("tool_use", forKey: .type)
        try container.encode(id, forKey: .id)
        try container.encode(name, forKey: .name)
        try container.encode(input, forKey: .input)
    }
}

// MARK: - ToolResultBlock

/// A tool execution result content block in a user message.
///
/// Encodes as `{"type":"tool_result","tool_use_id":"...","content":"...","is_error":false}`.
public struct ToolResultBlock: Sendable, Encodable, Equatable {
    /// The ID of the `ToolUseBlock` this result corresponds to.
    public let toolUseId: String
    /// The output text from the tool execution.
    public let content: String
    /// Whether the tool execution failed. `true` signals an error to the model.
    public let isError: Bool

    /// Create a tool result block.
    ///
    /// - Parameters:
    ///   - toolUseId: Must match the `id` of the corresponding `ToolUseBlock`.
    ///   - content: The tool output, or an error description when `isError` is true.
    ///   - isError: Pass `true` when the tool execution failed.
    public init(toolUseId: String, content: String, isError: Bool) {
        self.toolUseId = toolUseId
        self.content = content
        self.isError = isError
    }

    private enum CodingKeys: String, CodingKey {
        case type
        case toolUseId = "tool_use_id"
        case content
        case isError = "is_error"
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode("tool_result", forKey: .type)
        try container.encode(toolUseId, forKey: .toolUseId)
        try container.encode(content, forKey: .content)
        try container.encode(isError, forKey: .isError)
    }
}

// MARK: - ImageBlock

/// An image content block with base64-encoded data.
///
/// Encodes as `{"type":"image","source":{"type":"base64","media_type":"...","data":"..."}}`.
public struct ImageBlock: Sendable, Encodable, Equatable {
    /// MIME type of the image (e.g. `"image/png"`, `"image/jpeg"`).
    public let mediaType: String
    /// Base64-encoded image data.
    public let base64Data: String

    /// Create an image block from raw image data (performs base64 encoding).
    ///
    /// - Parameters:
    ///   - mediaType: MIME type string (e.g. `"image/png"`).
    ///   - data: Raw image bytes to base64-encode.
    public init(mediaType: String, data: Data) {
        self.mediaType = mediaType
        self.base64Data = data.base64EncodedString()
    }

    /// Create an image block from pre-encoded base64 data.
    ///
    /// - Parameters:
    ///   - mediaType: MIME type string.
    ///   - base64Data: Already-encoded base64 string.
    public init(mediaType: String, base64Data: String) {
        self.mediaType = mediaType
        self.base64Data = base64Data
    }

    private enum OuterKeys: String, CodingKey {
        case type
        case source
    }

    private enum SourceKeys: String, CodingKey {
        case type
        case mediaType = "media_type"
        case data
    }

    public func encode(to encoder: any Encoder) throws {
        var outer = encoder.container(keyedBy: OuterKeys.self)
        try outer.encode("image", forKey: .type)
        var source = outer.nestedContainer(keyedBy: SourceKeys.self, forKey: .source)
        try source.encode("base64", forKey: .type)
        try source.encode(mediaType, forKey: .mediaType)
        try source.encode(base64Data, forKey: .data)
    }
}

// MARK: - CacheableTextBlock

/// Text block that can carry `cache_control` — used internally by `MessageContent.addCacheControl()`.
///
/// Not part of the public content-construction API. Created only when injecting cache
/// control at the stubbing boundary. Must be `public` because it is a payload of the
/// `public` `ContentBlock.cacheableText` case.
public struct CacheableTextBlock: Sendable, Encodable, Equatable {
    /// Fixed discriminator — always `"text"`.
    public let type = "text"
    /// The text content.
    public let text: String
    /// Optional cache directive. Omitted from JSON when `nil`.
    public let cacheControl: CacheControl?

    /// Create a cacheable text block.
    ///
    /// - Parameters:
    ///   - text: The text content.
    ///   - cacheControl: Cache directive, or `nil` for no annotation.
    public init(text: String, cacheControl: CacheControl?) {
        self.text = text
        self.cacheControl = cacheControl
    }

    private enum CodingKeys: String, CodingKey {
        case type
        case text
        case cacheControl = "cache_control"
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(type, forKey: .type)
        try container.encode(text, forKey: .text)
        if let cacheControl {
            try container.encode(cacheControl, forKey: .cacheControl)
        }
    }

    public static func == (lhs: CacheableTextBlock, rhs: CacheableTextBlock) -> Bool {
        lhs.text == rhs.text && lhs.cacheControl == rhs.cacheControl
    }
}
