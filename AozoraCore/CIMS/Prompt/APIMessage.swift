/// A single message in the API conversation.
///
/// Maps directly to the Anthropic Messages API message object.
/// `content` is `var` to allow cache control injection at the stubbing boundary.
public struct APIMessage: Sendable, Encodable {
    /// The role of this message's author.
    public let role: APIRole
    /// The message content — either a plain string or a structured block array.
    public var content: MessageContent

    /// Create an API message.
    ///
    /// - Parameters:
    ///   - role: Whether this message is from the user or assistant.
    ///   - content: The message content.
    public init(role: APIRole, content: MessageContent) {
        self.role = role
        self.content = content
    }
}

// MARK: - APIRole

/// Message role in the Anthropic API.
public enum APIRole: String, Sendable, Encodable {
    /// A user turn — human input or tool results.
    case user
    /// An assistant turn — model-generated text or tool invocations.
    case assistant
}

// MARK: - MessageContent

/// Message content — either a plain string or an array of content blocks.
///
/// Matches the Anthropic API's two content representations.
/// Custom `Encodable`: `.text` encodes as a bare JSON string,
/// `.blocks` encodes as a JSON array of content block objects.
public enum MessageContent: Sendable, Encodable, Equatable {
    /// Plain string content. Encodes as a bare JSON string value.
    case text(String)
    /// Structured content blocks. Encodes as a JSON array.
    case blocks([ContentBlock])

    public func encode(to encoder: any Encoder) throws {
        switch self {
        case let .text(string):
            var container = encoder.singleValueContainer()
            try container.encode(string)
        case let .blocks(blocks):
            var container = encoder.unkeyedContainer()
            for block in blocks {
                try container.encode(block)
            }
        }
    }

    /// Add `cache_control` to the last content block.
    ///
    /// Used at the stubbing boundary to mark the trailing turn for prompt caching.
    /// Converts `.text` to `.blocks` if needed. Only wraps `.text` blocks with cache
    /// control; other block types at the tail position are left unchanged.
    public mutating func addCacheControl() {
        switch self {
        case let .text(s):
            self = .blocks([.cacheableText(CacheableTextBlock(text: s, cacheControl: .ephemeral))])
        case var .blocks(blocks):
            if let lastIdx = blocks.indices.last {
                if case let .text(t) = blocks[lastIdx] {
                    blocks[lastIdx] = .cacheableText(CacheableTextBlock(text: t, cacheControl: .ephemeral))
                }
            }
            self = .blocks(blocks)
        }
    }

    public static func == (lhs: MessageContent, rhs: MessageContent) -> Bool {
        switch (lhs, rhs) {
        case let (.text(l), .text(r)):
            l == r
        case let (.blocks(l), .blocks(r)):
            l == r
        default:
            false
        }
    }
}
