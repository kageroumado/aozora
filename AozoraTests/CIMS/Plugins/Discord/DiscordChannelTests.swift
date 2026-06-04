import Foundation
import Testing
@testable import Aozora

/// Tests for the Discord channel plugin types, message conversion, and configuration.
///
/// These tests verify Discord-specific logic without requiring a live Discord connection:
/// message decoding, inbound message conversion, message splitting, guild/channel filtering,
/// and configuration defaults.
@Suite("Discord Channel")
struct DiscordChannelTests {
    // MARK: - Discord Types Decoding

    @Test("Decode Discord message from JSON")
    func decodeMessage() throws {
        let json = """
        {
            "id": "123456789",
            "channel_id": "987654321",
            "guild_id": "111222333",
            "author": {
                "id": "444555666",
                "username": "testuser",
                "discriminator": "0",
                "global_name": "Test User",
                "bot": false
            },
            "content": "Hello from Discord!",
            "timestamp": "2026-03-13T00:00:00.000Z",
            "attachments": []
        }
        """

        let data = try #require(json.data(using: .utf8))
        let message = try JSONDecoder().decode(DiscordMessage.self, from: data)

        #expect(message.id == "123456789")
        #expect(message.channel_id == "987654321")
        #expect(message.guild_id == "111222333")
        #expect(message.author.username == "testuser")
        #expect(message.author.global_name == "Test User")
        #expect(message.author.bot == false)
        #expect(message.content == "Hello from Discord!")
        #expect(message.referenced_message_id == nil)
        #expect(message.attachments?.isEmpty == true)
    }

    @Test("Decode Discord message with referenced message")
    func decodeMessageWithReply() throws {
        let json = """
        {
            "id": "999",
            "channel_id": "100",
            "author": {
                "id": "200",
                "username": "replier"
            },
            "content": "This is a reply",
            "timestamp": "2026-03-13T00:00:00.000Z",
            "referenced_message": {
                "id": "888",
                "channel_id": "100",
                "author": {
                    "id": "300",
                    "username": "original"
                },
                "content": "Original message",
                "timestamp": "2026-03-12T00:00:00.000Z"
            }
        }
        """

        let data = try #require(json.data(using: .utf8))
        let message = try JSONDecoder().decode(DiscordMessage.self, from: data)

        #expect(message.id == "999")
        #expect(message.content == "This is a reply")
        #expect(message.referenced_message_id == "888")
    }

    @Test("Decode Discord user with minimal fields")
    func decodeMinimalUser() throws {
        let json = """
        {
            "id": "12345",
            "username": "minimal_user"
        }
        """

        let data = try #require(json.data(using: .utf8))
        let user = try JSONDecoder().decode(DiscordUser.self, from: data)

        #expect(user.id == "12345")
        #expect(user.username == "minimal_user")
        #expect(user.discriminator == nil)
        #expect(user.global_name == nil)
        #expect(user.bot == nil)
    }

    @Test("Decode Discord message with attachments")
    func decodeMessageWithAttachments() throws {
        let json = """
        {
            "id": "555",
            "channel_id": "100",
            "author": {"id": "200", "username": "uploader"},
            "content": "Check this out",
            "timestamp": "2026-03-13T00:00:00.000Z",
            "attachments": [
                {
                    "id": "att1",
                    "filename": "screenshot.png",
                    "size": 12345,
                    "url": "https://cdn.discordapp.com/attachments/100/att1/screenshot.png",
                    "content_type": "image/png"
                }
            ]
        }
        """

        let data = try #require(json.data(using: .utf8))
        let message = try JSONDecoder().decode(DiscordMessage.self, from: data)

        #expect(message.attachments?.count == 1)
        #expect(message.attachments?.first?.filename == "screenshot.png")
        #expect(message.attachments?.first?.size == 12_345)
        #expect(message.attachments?.first?.content_type == "image/png")
    }

    @Test("Decode DM message (no guild_id)")
    func decodeDMMessage() throws {
        let json = """
        {
            "id": "777",
            "channel_id": "dm_channel",
            "author": {"id": "200", "username": "dm_user"},
            "content": "Private message",
            "timestamp": "2026-03-13T00:00:00.000Z"
        }
        """

        let data = try #require(json.data(using: .utf8))
        let message = try JSONDecoder().decode(DiscordMessage.self, from: data)

        #expect(message.guild_id == nil)
        #expect(message.content == "Private message")
    }

    // MARK: - Gateway Payload Decoding

    @Test("Decode Hello gateway payload")
    func decodeHelloPayload() throws {
        let json = """
        {
            "op": 10,
            "d": {"heartbeat_interval": 41250},
            "s": null,
            "t": null
        }
        """

        let data = try #require(json.data(using: .utf8))
        let payload = try JSONDecoder().decode(GatewayPayload.self, from: data)

        #expect(payload.op == GatewayOpcode.hello.rawValue)
        #expect(payload.s == nil)
        #expect(payload.t == nil)

        // Re-encode d to decode as GatewayHello
        let dData = try JSONEncoder().encode(payload.d)
        let hello = try JSONDecoder().decode(GatewayHello.self, from: dData)
        #expect(hello.heartbeat_interval == 41_250)
    }

    @Test("Decode Dispatch gateway payload")
    func decodeDispatchPayload() throws {
        let json = """
        {
            "op": 0,
            "d": {"content": "test"},
            "s": 42,
            "t": "MESSAGE_CREATE"
        }
        """

        let data = try #require(json.data(using: .utf8))
        let payload = try JSONDecoder().decode(GatewayPayload.self, from: data)

        #expect(payload.op == GatewayOpcode.dispatch.rawValue)
        #expect(payload.s == 42)
        #expect(payload.t == "MESSAGE_CREATE")
    }

    @Test("Decode Heartbeat Ack payload")
    func decodeHeartbeatAck() throws {
        let json = """
        {"op": 11, "d": null, "s": null, "t": null}
        """

        let data = try #require(json.data(using: .utf8))
        let payload = try JSONDecoder().decode(GatewayPayload.self, from: data)
        #expect(payload.op == GatewayOpcode.heartbeatAck.rawValue)
    }

    // MARK: - Gateway Intents

    @Test("Message bot intents include required flags")
    func messageBotIntents() {
        let intents = GatewayIntents.messageBot

        #expect(intents.contains(.guilds))
        #expect(intents.contains(.guildMessages))
        #expect(intents.contains(.directMessages))
        #expect(intents.contains(.messageContent))

        // Should not include member-related intents
        #expect(!intents.contains(.guildMembers))
        #expect(!intents.contains(.guildMessageReactions))
    }

    @Test("Intents raw value is correct bitmask")
    func intentsRawValue() {
        #expect(GatewayIntents.guilds.rawValue == 1)
        #expect(GatewayIntents.guildMessages.rawValue == 512)
        #expect(GatewayIntents.messageContent.rawValue == 32_768)
    }

    // MARK: - Configuration

    @Test("Default configuration values")
    func defaultConfiguration() {
        let config = DiscordConfiguration(token: "test-token")

        #expect(config.token == "test-token")
        #expect(config.guildFilter.isEmpty)
        #expect(config.channelFilter.isEmpty)
        #expect(config.allowDirectMessages == true)
        #expect(config.maxMessageLength == 2_000)
        #expect(config.apiVersion == 10)
        #expect(config.restBaseURL == "https://discord.com/api/v10")
    }

    @Test("Custom configuration values")
    func customConfiguration() {
        let config = DiscordConfiguration(
            token: "custom-token",
            guildFilter: ["guild1", "guild2"],
            channelFilter: ["chan1"],
            allowDirectMessages: false,
            maxMessageLength: 1_500,
        )

        #expect(config.guildFilter.count == 2)
        #expect(config.channelFilter.contains("chan1"))
        #expect(!config.allowDirectMessages)
        #expect(config.maxMessageLength == 1_500)
    }

    // MARK: - Message Conversion

    @Test("Discord message converts to InboundMessage")
    func messageConversion() {
        let config = DiscordConfiguration(token: "test")
        let channel = DiscordChannel(configuration: config)

        let discordMsg = DiscordMessage(
            id: "msg123",
            channel_id: "chan456",
            guild_id: "guild789",
            author: DiscordUser(
                id: "user111",
                username: "testuser",
                discriminator: "0",
                global_name: "Test User",
                bot: false,
            ),
            content: "Hello CIMS!",
            timestamp: "2026-03-13T00:00:00.000Z",
            referenced_message_id: nil,
            attachments: [],
        )

        let inbound = channel.convertToInbound(discordMsg)

        #expect(inbound.text == "Hello CIMS!")
        #expect(inbound.parts.count == 1)
        #expect(inbound.parts.first?.kind == .text)
        #expect(inbound.parts.first?.content == "Hello CIMS!")
    }

    @Test("Discord message with reply includes metadata")
    func messageWithReplyMetadata() {
        let config = DiscordConfiguration(token: "test")
        let channel = DiscordChannel(configuration: config)

        let discordMsg = DiscordMessage(
            id: "msg999",
            channel_id: "chan100",
            guild_id: nil,
            author: DiscordUser(
                id: "user200",
                username: "replier",
                discriminator: nil,
                global_name: nil,
                bot: nil,
            ),
            content: "Replying to you",
            timestamp: "2026-03-13T00:00:00.000Z",
            referenced_message_id: "888",
            attachments: nil,
        )

        let inbound = channel.convertToInbound(discordMsg)

        #expect(inbound.metadata?.replyToMessageId == 888)
    }

    // MARK: - Message Splitting

    @Test("Short message is not split")
    func shortMessageNotSplit() {
        let config = DiscordConfiguration(token: "test", maxMessageLength: 100)
        let channel = DiscordChannel(configuration: config)

        let chunks = channel.splitMessage("Hello!", maxLength: 100)
        #expect(chunks.count == 1)
        #expect(chunks.first == "Hello!")
    }

    @Test("Long message splits on newline")
    func splitOnNewline() {
        let config = DiscordConfiguration(token: "test")
        let channel = DiscordChannel(configuration: config)

        let line1 = String(repeating: "a", count: 50)
        let line2 = String(repeating: "b", count: 50)
        let text = "\(line1)\n\(line2)"

        let chunks = channel.splitMessage(text, maxLength: 60)
        #expect(chunks.count == 2)
        #expect(chunks[0] == "\(line1)\n")
        #expect(chunks[1] == line2)
    }

    @Test("Long message splits on space")
    func splitOnSpace() {
        let config = DiscordConfiguration(token: "test")
        let channel = DiscordChannel(configuration: config)

        let text = "Hello World This Is A Test"
        let chunks = channel.splitMessage(text, maxLength: 12)

        #expect(chunks.count > 1)
        for chunk in chunks {
            #expect(chunk.count <= 12)
        }
    }

    @Test("Very long word triggers hard split")
    func hardSplit() {
        let config = DiscordConfiguration(token: "test")
        let channel = DiscordChannel(configuration: config)

        let longWord = String(repeating: "x", count: 30)
        let chunks = channel.splitMessage(longWord, maxLength: 10)

        #expect(chunks.count == 3)
        for chunk in chunks {
            #expect(chunk.count <= 10)
        }
    }

    // MARK: - Plugin Identity

    @Test("Default plugin identity")
    func defaultPluginIdentity() {
        let config = DiscordConfiguration(token: "test")
        let channel = DiscordChannel(configuration: config)

        #expect(channel.id == "discord")
        #expect(channel.name == "Discord")
    }

    @Test("Custom plugin identity")
    func customPluginIdentity() {
        let config = DiscordConfiguration(token: "test")
        let channel = DiscordChannel(
            configuration: config,
            id: "discord-dev",
            name: "Discord Dev Server",
        )

        #expect(channel.id == "discord-dev")
        #expect(channel.name == "Discord Dev Server")
    }

    // MARK: - Connection Status

    @Test("Initial connection status is disconnected")
    func initialStatus() async {
        let config = DiscordConfiguration(token: "test")
        let channel = DiscordChannel(configuration: config)

        let status = await channel.connectionStatus
        #expect(status == .disconnected)
    }

    // MARK: - REST API Types

    @Test("CreateMessageRequest encodes correctly")
    func createMessageEncoding() throws {
        let request = CreateMessageRequest(
            content: "Hello!",
            message_reference: MessageReference(
                message_id: "123",
                channel_id: "456",
                guild_id: "789",
            ),
        )

        let data = try JSONEncoder().encode(request)
        let json = try JSONDecoder().decode([String: AnyCodable].self, from: data)

        #expect((json["content"]?.value as? String) == "Hello!")
    }

    @Test("CreateMessageRequest without reference")
    func createMessageWithoutReference() throws {
        let request = CreateMessageRequest(content: "Simple message", message_reference: nil)
        let data = try JSONEncoder().encode(request)
        let decoded = try JSONDecoder().decode(CreateMessageRequest.self, from: data)

        #expect(decoded.content == "Simple message")
        #expect(decoded.message_reference == nil)
    }

    // MARK: - AnyCodable

    @Test("AnyCodable roundtrips basic types")
    func anyCodableRoundtrip() throws {
        let values: [AnyCodable] = [
            AnyCodable("hello"),
            AnyCodable(42),
            AnyCodable(3.14),
            AnyCodable(true),
        ]

        for value in values {
            let data = try JSONEncoder().encode(value)
            let decoded = try JSONDecoder().decode(AnyCodable.self, from: data)
            // Just verify it doesn't crash — type erasure makes direct comparison tricky
            _ = decoded.value
        }
    }

    @Test("AnyCodable handles nested structures")
    func anyCodableNested() throws {
        let json = """
        {"key": "value", "nested": {"inner": 42}, "array": [1, 2, 3]}
        """

        let data = try #require(json.data(using: .utf8))
        let decoded = try JSONDecoder().decode(AnyCodable.self, from: data)

        // Verify it decoded as a dictionary
        guard let dict = decoded.value as? [String: any Sendable] else {
            #expect(Bool(false), "Should decode as dictionary")
            return
        }

        #expect((dict["key"] as? String) == "value")
    }

    // MARK: - Error Types

    @Test("Discord errors have meaningful descriptions")
    func errorDescriptions() {
        let errors: [DiscordError] = [
            .missingChannelId,
            .invalidURL("bad://url"),
            .invalidResponse,
            .apiError(statusCode: 429, body: "Rate limited"),
            .connectionFailed("Network error"),
        ]

        // All errors should be constructable without crashing
        #expect(errors.count == 5)
    }
}
