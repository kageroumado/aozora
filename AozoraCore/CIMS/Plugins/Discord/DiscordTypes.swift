import Foundation

// MARK: - Configuration

/// Configuration for a Discord bot channel plugin.
///
/// Contains the bot token, which guilds/channels to monitor, and connection settings.
/// The bot token must have the MESSAGE_CONTENT privileged intent enabled in the
/// Discord Developer Portal.
public nonisolated struct DiscordConfiguration: Sendable {
    /// The bot authentication token from the Discord Developer Portal.
    public let token: String

    /// Guild (server) IDs to listen in. Empty means all guilds the bot is a member of.
    public let guildFilter: Set<String>

    /// Channel IDs to listen in. Empty means all channels the bot has access to.
    public let channelFilter: Set<String>

    /// Whether to respond to DMs (direct messages).
    public let allowDirectMessages: Bool

    /// Maximum message length before splitting into multiple messages.
    /// Discord's limit is 2000 characters.
    public let maxMessageLength: Int

    /// Gateway API version.
    public let apiVersion: Int

    /// Base URL for the Discord REST API.
    public let restBaseURL: String

    public init(
        token: String,
        guildFilter: Set<String> = [],
        channelFilter: Set<String> = [],
        allowDirectMessages: Bool = true,
        maxMessageLength: Int = 2_000,
        apiVersion: Int = 10,
        restBaseURL: String = "https://discord.com/api/v10",
    ) {
        self.token = token
        self.guildFilter = guildFilter
        self.channelFilter = channelFilter
        self.allowDirectMessages = allowDirectMessages
        self.maxMessageLength = maxMessageLength
        self.apiVersion = apiVersion
        self.restBaseURL = restBaseURL
    }
}

// MARK: - Gateway Opcodes

/// Discord Gateway opcodes for WebSocket communication.
///
/// The Gateway uses integer opcodes to identify payload types. The client sends
/// Identify, Heartbeat, and Resume; the server sends Hello, HeartbeatAck, Dispatch,
/// Reconnect, and InvalidSession.
///
/// Reference: https://discord.com/developers/docs/events/gateway-events
public nonisolated enum GatewayOpcode: Int, Codable, Sendable {
    /// Server → Client: Dispatched event (includes event name and data).
    case dispatch = 0

    /// Bidirectional: Heartbeat — client sends to keep connection alive.
    case heartbeat = 1

    /// Client → Server: Identify — authenticate and declare intents.
    case identify = 2

    /// Client → Server: Update presence (status, activity).
    case presenceUpdate = 3

    /// Client → Server: Voice state update.
    case voiceStateUpdate = 4

    /// Client → Server: Resume a disconnected session.
    case resume = 6

    /// Server → Client: Reconnect — client should disconnect and resume.
    case reconnect = 7

    /// Client → Server: Request guild members (large guilds).
    case requestGuildMembers = 8

    /// Server → Client: Invalid session — may or may not be resumable.
    case invalidSession = 9

    /// Server → Client: Hello — sent on connect with heartbeat interval.
    case hello = 10

    /// Server → Client: Heartbeat acknowledged.
    case heartbeatAck = 11
}

// MARK: - Gateway Intents

/// Discord Gateway intents as a bitmask.
///
/// Intents control which events the bot receives. MESSAGE_CONTENT is a privileged
/// intent that must be enabled in the Developer Portal. Without it, message content
/// fields are empty strings.
public nonisolated struct GatewayIntents: OptionSet, Sendable {
    public let rawValue: Int

    public init(rawValue: Int) {
        self.rawValue = rawValue
    }

    /// Events about guild (server) membership changes.
    public static let guilds = GatewayIntents(rawValue: 1 << 0)

    /// Events about guild members joining/leaving/updating.
    public static let guildMembers = GatewayIntents(rawValue: 1 << 1)

    /// Events about messages in guild text channels.
    public static let guildMessages = GatewayIntents(rawValue: 1 << 9)

    /// Events about reactions on guild messages.
    public static let guildMessageReactions = GatewayIntents(rawValue: 1 << 10)

    /// Events about messages in DM channels.
    public static let directMessages = GatewayIntents(rawValue: 1 << 12)

    /// Privileged: Access to message content, attachments, embeds, components.
    public static let messageContent = GatewayIntents(rawValue: 1 << 15)

    /// Standard intents for a message-processing bot.
    public static let messageBot: GatewayIntents = [
        .guilds,
        .guildMessages,
        .directMessages,
        .messageContent,
    ]
}

// MARK: - Gateway Payloads

/// The top-level envelope for all Gateway WebSocket messages.
///
/// Every Gateway message has an opcode. Dispatch events (opcode 0) additionally
/// carry a sequence number, event name, and event data.
public nonisolated struct GatewayPayload: Codable, Sendable {
    /// The opcode identifying this payload type.
    public let op: Int

    /// Event data — structure varies by opcode and event name.
    public let d: AnyCodable?

    /// Sequence number for ordering and resuming (dispatch events only).
    public let s: Int?

    /// Event name (dispatch events only, e.g., "MESSAGE_CREATE", "READY").
    public let t: String?
}

/// Type-erased Codable wrapper for dynamic JSON payloads.
///
/// Discord Gateway payloads have varying structure depending on the opcode and event.
/// This wrapper allows decoding the top-level envelope without knowing the inner type,
/// then re-encoding the `d` field for specific event parsing.
public nonisolated struct AnyCodable: Codable, Sendable {
    /// The raw JSON value stored as Foundation types.
    public let value: any Sendable

    public init(_ value: any Sendable) {
        self.value = value
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.singleValueContainer()

        if container.decodeNil() {
            self.value = NSNull()
        } else if let bool = try? container.decode(Bool.self) {
            self.value = bool
        } else if let int = try? container.decode(Int.self) {
            self.value = int
        } else if let double = try? container.decode(Double.self) {
            self.value = double
        } else if let string = try? container.decode(String.self) {
            self.value = string
        } else if let array = try? container.decode([AnyCodable].self) {
            self.value = array.map(\.value)
        } else if let dict = try? container.decode([String: AnyCodable].self) {
            self.value = dict.mapValues(\.value)
        } else {
            throw DecodingError.dataCorruptedError(in: container, debugDescription: "Unsupported JSON type")
        }
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.singleValueContainer()

        switch value {
        case is NSNull:
            try container.encodeNil()
        case let bool as Bool:
            try container.encode(bool)
        case let int as Int:
            try container.encode(int)
        case let double as Double:
            try container.encode(double)
        case let string as String:
            try container.encode(string)
        case let array as [any Sendable]:
            try container.encode(array.map { AnyCodable($0) })
        case let dict as [String: any Sendable]:
            try container.encode(dict.mapValues { AnyCodable($0) })
        default:
            throw EncodingError.invalidValue(
                value,
                EncodingError.Context(codingPath: encoder.codingPath, debugDescription: "Unsupported type"),
            )
        }
    }
}

// MARK: - Gateway Event Data

/// Hello event data (opcode 10), received on initial connection.
public nonisolated struct GatewayHello: Codable, Sendable {
    /// Interval in milliseconds between heartbeats.
    public let heartbeat_interval: Int
}

/// Ready event data, received after successful Identify.
public nonisolated struct GatewayReady: Codable, Sendable {
    /// Gateway version.
    public let v: Int

    /// The bot user object.
    public let user: DiscordUser

    /// Session ID for resuming.
    public let session_id: String

    /// Gateway URL for resuming connections.
    public let resume_gateway_url: String
}

// MARK: - Discord Data Types

/// A Discord user object.
public nonisolated struct DiscordUser: Codable, Sendable {
    public let id: String
    public let username: String
    public let discriminator: String?
    public let global_name: String?
    public let bot: Bool?
}

/// A Discord message object from MESSAGE_CREATE events.
public nonisolated struct DiscordMessage: Codable, Sendable {
    /// Unique message snowflake ID.
    public let id: String

    /// Channel the message was sent in.
    public let channel_id: String

    /// Guild (server) the message belongs to. `nil` for DMs.
    public let guild_id: String?

    /// The author of the message.
    public let author: DiscordUser

    /// The text content of the message.
    public let content: String

    /// ISO 8601 timestamp.
    public let timestamp: String

    /// ID of the message being replied to, if any.
    /// Extracted from `referenced_message.id` during decoding.
    public let referenced_message_id: String?

    /// File attachments.
    public let attachments: [DiscordAttachment]?

    private enum CodingKeys: String, CodingKey {
        case id
        case channel_id
        case guild_id
        case author
        case content
        case timestamp
        case referenced_message
        case attachments
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.id = try container.decode(String.self, forKey: .id)
        self.channel_id = try container.decode(String.self, forKey: .channel_id)
        self.guild_id = try container.decodeIfPresent(String.self, forKey: .guild_id)
        self.author = try container.decode(DiscordUser.self, forKey: .author)
        self.content = try container.decode(String.self, forKey: .content)
        self.timestamp = try container.decode(String.self, forKey: .timestamp)
        self.attachments = try container.decodeIfPresent([DiscordAttachment].self, forKey: .attachments)

        // Extract just the ID from the referenced message to avoid recursive struct
        if let ref = try? container.nestedContainer(keyedBy: IDKey.self, forKey: .referenced_message) {
            self.referenced_message_id = try ref.decodeIfPresent(String.self, forKey: .id)
        } else {
            self.referenced_message_id = nil
        }
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(channel_id, forKey: .channel_id)
        try container.encodeIfPresent(guild_id, forKey: .guild_id)
        try container.encode(author, forKey: .author)
        try container.encode(content, forKey: .content)
        try container.encode(timestamp, forKey: .timestamp)
        try container.encodeIfPresent(attachments, forKey: .attachments)
    }

    /// Internal init for testing.
    public init(
        id: String,
        channel_id: String,
        guild_id: String?,
        author: DiscordUser,
        content: String,
        timestamp: String,
        referenced_message_id: String?,
        attachments: [DiscordAttachment]?,
    ) {
        self.id = id
        self.channel_id = channel_id
        self.guild_id = guild_id
        self.author = author
        self.content = content
        self.timestamp = timestamp
        self.referenced_message_id = referenced_message_id
        self.attachments = attachments
    }

    private enum IDKey: String, CodingKey {
        case id
    }
}

/// A Discord message attachment.
public nonisolated struct DiscordAttachment: Codable, Sendable {
    public let id: String
    public let filename: String
    public let size: Int
    public let url: String
    public let content_type: String?
}

// MARK: - REST API Types

/// Request body for sending a message via the Discord REST API.
public nonisolated struct CreateMessageRequest: Codable, Sendable {
    /// The message text content.
    public let content: String

    /// Message reference for replies.
    public let message_reference: MessageReference?
}

/// Reference to a message for reply threading.
public nonisolated struct MessageReference: Codable, Sendable {
    public let message_id: String
    public let channel_id: String?
    public let guild_id: String?
}

// MARK: - Identify Payload

/// The Identify payload sent after receiving Hello.
public nonisolated struct IdentifyPayload: Codable, Sendable {
    public let token: String
    public let intents: Int
    public let properties: ConnectionProperties
}

/// Client connection properties sent with Identify.
public nonisolated struct ConnectionProperties: Codable, Sendable {
    public let os: String
    public let browser: String
    public let device: String
}

/// The Resume payload for reconnecting with session state.
public nonisolated struct ResumePayload: Codable, Sendable {
    public let token: String
    public let session_id: String
    public let seq: Int
}
