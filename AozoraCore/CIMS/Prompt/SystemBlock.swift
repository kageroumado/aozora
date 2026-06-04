/// A single block in the system prompt parameter.
///
/// Encodes as `{"type":"text","text":"..."}` with an optional `cache_control` field.
/// Used to build the `system` array sent to the Anthropic API.
///
/// **Cache invariant:** The API hashes the entire `system` array as one unit.
/// ALL system blocks must be stable between turns — even blocks without `cache_control`.
/// Only the last block should carry `cache_control: .ephemeral` to cache the full prefix.
/// Volatile content (timestamps, per-turn state) must go in messages, not system blocks.
public struct SystemBlock: Sendable, Encodable {
    /// The text content of this system block.
    public let text: String

    /// Optional cache control directive. When non-nil, adds a `cache_control` field to the output.
    public let cacheControl: CacheControl?

    /// Create a system block with optional prompt-caching annotation.
    ///
    /// - Parameters:
    ///   - text: The system prompt text for this block.
    ///   - cacheControl: Cache directive, or `nil` for no caching annotation.
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
        try container.encode("text", forKey: .type)
        try container.encode(text, forKey: .text)
        if let cacheControl {
            try container.encode(cacheControl, forKey: .cacheControl)
        }
    }
}

/// Cache control directive for Anthropic prompt caching.
///
/// Marks a position in the request where the API should create a KV cache checkpoint.
/// Used in two places:
/// 1. **Last system block** — caches the entire stable system prefix (~95K tokens)
/// 2. **Stubbing boundary message** — caches system + tools + stable message history
///
/// Currently only `ephemeral` (5-minute TTL) is supported by the API.
public struct CacheControl: Sendable, Encodable, Equatable {
    /// The cache control type string sent to the API.
    public let type: String

    /// Ephemeral cache control — the only type currently supported by the Anthropic API.
    public static let ephemeral = CacheControl(type: "ephemeral")

    /// Create a cache control directive with the given type string.
    ///
    /// - Parameter type: The cache control type. Use `.ephemeral` in practice.
    public init(type: String) {
        self.type = type
    }
}
