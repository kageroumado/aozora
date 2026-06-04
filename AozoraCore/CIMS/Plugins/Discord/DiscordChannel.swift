import CoreGraphics
import Foundation
import ImageIO
#if canImport(FoundationNetworking)
    import FoundationNetworking
#endif

/// Discord messaging channel plugin for CIMS.
///
/// Connects to the Discord Gateway via WebSocket to receive messages, and uses the
/// REST API to send responses. Implements the full Gateway lifecycle: Hello → Identify →
/// heartbeat loop → dispatch event handling, with automatic reconnection on disconnects.
///
/// The channel converts Discord messages to ``InboundMessage`` and routes them through
/// the CIMS coordinator as cognitive turns. Responses are sent back to the originating
/// Discord channel.
///
/// **Required bot permissions:**
/// - Read Messages / View Channels
/// - Send Messages
/// - Message Content privileged intent (Developer Portal)
///
/// **Usage:**
/// ```swift
/// let config = DiscordConfiguration(token: "Bot MTIz...")
/// let discord = DiscordChannel(configuration: config)
/// await gateway.pluginRegistry.register(discord)
/// ```
public actor DiscordChannel: MessagingChannel {
    // MARK: - Plugin Identity

    public nonisolated let id: String
    public nonisolated let name: String

    // MARK: - Configuration

    private let configuration: DiscordConfiguration

    /// Interaction handler for slash commands. Set after initialization.
    private var interactionHandler: DiscordInteractionHandler?

    /// Set the interaction handler for slash command routing.
    public func setInteractionHandler(_ handler: DiscordInteractionHandler) {
        interactionHandler = handler
    }

    // MARK: - Gateway State

    /// The active WebSocket connection to the Discord Gateway.
    private var webSocketTask: URLSessionWebSocketTask?

    /// URLSession for WebSocket and REST API calls.
    private let urlSession: URLSession

    /// Session ID from the READY event, used for resuming.
    private var sessionId: String?

    /// Gateway URL for resuming connections.
    private var resumeGatewayURL: String?

    /// Last received sequence number for heartbeating and resuming.
    private var lastSequence: Int?

    /// The bot's own user ID (from READY), used to ignore self-messages.
    private var botUserId: String?

    /// Whether the gateway connection is active.
    private var isConnected = false

    /// Consecutive reconnection failures, used for exponential backoff
    /// and session reset after repeated failures.
    private var consecutiveFailures = 0

    /// Task handle for the heartbeat loop.
    private var heartbeatTask: Task<Void, Never>?

    /// Task handle for the message receive loop.
    private var receiveTask: Task<Void, Never>?

    /// Whether the channel has been started.
    private var isRunning = false

    // MARK: - Message Stream

    /// Continuation for the inbound message stream.
    private var messageContinuation: AsyncStream<InboundMessage>.Continuation?

    /// The inbound message stream consumed by the coordinator.
    private var messageStream: AsyncStream<InboundMessage>?

    /// Plugin context from activation.
    private var pluginContext: PluginContext?

    // MARK: - JSON Coders

    private nonisolated let jsonEncoder: JSONEncoder = .init()

    private nonisolated let jsonDecoder: JSONDecoder = .init()

    // MARK: - Security

    /// Defense-in-depth secret redaction for all outbound Discord messages.
    private nonisolated let secretRedactor = SecretRedactor()

    // MARK: - Initialization

    /// Create a Discord channel plugin with the given configuration.
    ///
    /// - Parameters:
    ///   - configuration: Discord bot configuration including token and filters.
    ///   - id: Unique plugin ID. Defaults to "discord".
    ///   - name: Display name. Defaults to "Discord".
    public init(
        configuration: DiscordConfiguration,
        id: String = "discord",
        name: String = "Discord",
    ) {
        self.configuration = configuration
        self.id = id
        self.name = name

        let sessionConfig = URLSessionConfiguration.default
        sessionConfig.timeoutIntervalForRequest = 30
        self.urlSession = URLSession(configuration: sessionConfig)
    }

    // MARK: - CIMSPlugin Conformance

    public nonisolated func activate(context: PluginContext) async throws {
        await storeContext(context)
    }

    public nonisolated func deactivate() async {
        await performStop()
    }

    private func storeContext(_ context: PluginContext) {
        pluginContext = context
    }

    // MARK: - MessagingChannel Conformance

    public nonisolated func start() async throws {
        try await performStart()
    }

    public nonisolated func stop() async {
        await performStop()
    }

    public nonisolated func send(_ message: OutboundMessage) async throws {
        try await performSend(message)
    }

    public nonisolated var incomingMessages: AsyncStream<InboundMessage> {
        get async {
            await getOrCreateStream()
        }
    }

    // MARK: - Internal Implementation

    private func getOrCreateStream() -> AsyncStream<InboundMessage> {
        if let existing = messageStream {
            return existing
        }

        let (stream, continuation) = AsyncStream<InboundMessage>.makeStream()
        messageStream = stream
        messageContinuation = continuation
        return stream
    }

    private func performStart() throws {
        guard !isRunning else { return }
        isRunning = true

        // Ensure the stream exists
        _ = getOrCreateStream()

        // Start the Gateway connection
        connectToGateway()
    }

    private func performStop() {
        isRunning = false
        isConnected = false

        heartbeatTask?.cancel()
        heartbeatTask = nil

        receiveTask?.cancel()
        receiveTask = nil

        webSocketTask?.cancel(with: .goingAway, reason: nil)
        webSocketTask = nil

        messageContinuation?.finish()
        messageContinuation = nil
        messageStream = nil
    }

    // MARK: - Gateway Connection

    /// Connect to the Discord Gateway WebSocket.
    private func connectToGateway() {
        let gatewayURL = if let resumeURL = resumeGatewayURL {
            "\(resumeURL)?v=\(configuration.apiVersion)&encoding=json"
        } else {
            "wss://gateway.discord.gg/?v=\(configuration.apiVersion)&encoding=json"
        }

        guard let url = URL(string: gatewayURL) else {
            print("[DiscordChannel] Invalid gateway URL: \(gatewayURL)")
            return
        }

        var request = URLRequest(url: url)
        request.timeoutInterval = 60

        let task = urlSession.webSocketTask(with: request)
        webSocketTask = task
        task.resume()

        // Start the receive loop
        receiveTask = Task { [weak self] in
            guard let self else { return }
            await receiveLoop()
        }
    }

    /// Main receive loop — reads WebSocket messages and dispatches them.
    private func receiveLoop() async {
        guard let task = webSocketTask else { return }

        while isRunning, !Task.isCancelled {
            do {
                let message = try await task.receive()
                switch message {
                case let .string(text):
                    await handleGatewayMessage(text)
                case let .data(data):
                    if let text = String(data: data, encoding: .utf8) {
                        await handleGatewayMessage(text)
                    }
                @unknown default:
                    break
                }
            } catch {
                if isRunning {
                    // Only log the first error and every 5th — prevents flooding
                    // the log file during sustained connectivity issues.
                    if consecutiveFailures == 0 || consecutiveFailures % 5 == 0 {
                        print("[DiscordChannel] WebSocket error (attempt \(consecutiveFailures + 1)): \(error.localizedDescription)")
                    }
                    await handleDisconnect()
                }
                break
            }
        }
    }

    /// Parse and dispatch a Gateway JSON message.
    private func handleGatewayMessage(_ text: String) async {
        guard let data = text.data(using: .utf8) else { return }

        do {
            let payload = try jsonDecoder.decode(GatewayPayload.self, from: data)

            // Update sequence number
            if let seq = payload.s {
                lastSequence = seq
            }

            guard let opcode = GatewayOpcode(rawValue: payload.op) else {
                print("[DiscordChannel] Unknown opcode: \(payload.op)")
                return
            }

            switch opcode {
            case .hello:
                await handleHello(payload)

            case .dispatch:
                await handleDispatch(payload)

            case .heartbeatAck:
                break // Heartbeat acknowledged

            case .reconnect:
                print("[DiscordChannel] Server requested reconnect")
                await handleDisconnect()

            case .invalidSession:
                let resumable = (payload.d?.value as? Bool) ?? false
                print("[DiscordChannel] Invalid session (resumable: \(resumable))")
                if !resumable {
                    sessionId = nil
                    resumeGatewayURL = nil
                    lastSequence = nil
                }
                // Route through handleDisconnect for proper backoff and failure tracking.
                // This prevents tight reconnect loops when the token is invalid.
                await handleDisconnect()

            default:
                break
            }
        } catch {
            print("[DiscordChannel] Failed to decode gateway message: \(error)")
        }
    }

    /// Handle the Hello event — start heartbeat and send Identify or Resume.
    private func handleHello(_ payload: GatewayPayload) async {
        // Extract heartbeat interval
        guard let dData = reencodeData(payload.d),
              let hello = try? jsonDecoder.decode(GatewayHello.self, from: dData)
        else {
            print("[DiscordChannel] Failed to decode Hello payload")
            return
        }

        let interval = hello.heartbeat_interval

        // Start heartbeat loop
        startHeartbeat(intervalMs: interval)

        // Send Identify or Resume
        if let sessionId, let lastSeq = lastSequence {
            await sendResume(sessionId: sessionId, sequence: lastSeq)
        } else {
            await sendIdentify()
        }
    }

    /// Handle a Dispatch event (opcode 0).
    private func handleDispatch(_ payload: GatewayPayload) async {
        guard let eventName = payload.t else { return }

        switch eventName {
        case "READY":
            await handleReady(payload)

        case "RESUMED":
            isConnected = true
            consecutiveFailures = 0
            print("[DiscordChannel] Session resumed")

        case "MESSAGE_CREATE":
            await handleMessageCreate(payload)

        case "INTERACTION_CREATE":
            if let data = reencodeData(payload.d),
               let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
                await interactionHandler?.handle(json)
            }

        default:
            break
        }
    }

    /// Handle the READY event — extract session info and bot user ID.
    private func handleReady(_ payload: GatewayPayload) async {
        guard let dData = reencodeData(payload.d),
              let ready = try? jsonDecoder.decode(GatewayReady.self, from: dData)
        else {
            print("[DiscordChannel] Failed to decode READY payload")
            return
        }

        sessionId = ready.session_id
        resumeGatewayURL = ready.resume_gateway_url
        botUserId = ready.user.id
        isConnected = true
        consecutiveFailures = 0

        print("[DiscordChannel] Connected as \(ready.user.username) (ID: \(ready.user.id))")
    }

    /// Handle a MESSAGE_CREATE event — convert to InboundMessage and yield to stream.
    private func handleMessageCreate(_ payload: GatewayPayload) async {
        guard let dData = reencodeData(payload.d),
              let discordMsg = try? jsonDecoder.decode(DiscordMessage.self, from: dData)
        else {
            return
        }

        // Ignore messages from the bot itself
        if discordMsg.author.id == botUserId { return }

        // Ignore bot messages
        if discordMsg.author.bot == true { return }

        // Check DM policy first (DMs have no guild_id)
        if discordMsg.guild_id == nil {
            if !configuration.allowDirectMessages { return }
            // DMs bypass guild and channel filters
        } else {
            // Apply guild filter
            if !configuration.guildFilter.isEmpty {
                guard let guildId = discordMsg.guild_id,
                      configuration.guildFilter.contains(guildId)
                else {
                    return
                }
            }

            // Apply channel filter
            if !configuration.channelFilter.isEmpty {
                guard configuration.channelFilter.contains(discordMsg.channel_id) else {
                    return
                }
            }
        }

        // Download image attachments
        var images: [ImageAttachment] = []
        if let attachments = discordMsg.attachments {
            for attachment in attachments {
                guard let contentType = attachment.content_type,
                      contentType.hasPrefix("image/")
                else { continue }

                guard let url = URL(string: attachment.url) else { continue }
                guard let (data, _) = try? await urlSession.data(from: url) else { continue }

                let (convertedData, convertedType) = Self.convertImageIfNeeded(data: data, mediaType: contentType)

                images.append(ImageAttachment(
                    data: convertedData,
                    mediaType: convertedType,
                    filename: attachment.filename,
                ))
            }
        }

        // Convert to InboundMessage
        let inbound = convertToInbound(discordMsg, images: images)
        let imageInfo = images.isEmpty ? "" : " [\(images.count) image(s)]"
        print("[DiscordChannel] Message from \(discordMsg.author.username): \(discordMsg.content.prefix(80))\(imageInfo)")
        messageContinuation?.yield(inbound)
    }

    /// Convert a Discord message to a CIMS InboundMessage.
    public nonisolated func convertToInbound(_ msg: DiscordMessage, images: [ImageAttachment] = []) -> InboundMessage {
        var metadata: MessageMetadata?

        // Build attachment list
        let attachmentIds = msg.attachments?.map(\.id) ?? []
        if !attachmentIds.isEmpty || msg.referenced_message_id != nil {
            metadata = MessageMetadata(
                replyToMessageId: msg.referenced_message_id.flatMap { Int64($0) },
                attachments: attachmentIds,
            )
        }

        return InboundMessage(
            text: msg.content,
            parts: [
                MessagePart(
                    kind: .text,
                    ordinal: 0,
                    content: msg.content,
                    metadata: buildPartMetadata(msg),
                ),
            ],
            metadata: metadata,
            images: images,
        )
    }

    /// Build part metadata JSON with Discord-specific routing info.
    private nonisolated func buildPartMetadata(_ msg: DiscordMessage) -> String? {
        var meta: [String: String] = [
            "discord_message_id": msg.id,
            "discord_channel_id": msg.channel_id,
            "discord_author_id": msg.author.id,
            "discord_author_name": msg.author.global_name ?? msg.author.username,
        ]

        if let guildId = msg.guild_id {
            meta["discord_guild_id"] = guildId
        }

        guard let data = try? JSONEncoder().encode(meta),
              let json = String(data: data, encoding: .utf8)
        else {
            return nil
        }

        return json
    }

    // MARK: - Sending Messages

    /// Send a response message to Discord via the REST API.
    ///
    /// All content is scrubbed through ``SecretRedactor`` before transmission
    /// as a defense-in-depth measure against secret leakage.
    private func performSend(_ message: OutboundMessage) throws {
        let channelId = message.metadata["discord_channel_id"]
            ?? message.metadata["channel_id"]
            ?? message.sessionKey

        guard !channelId.isEmpty else {
            throw DiscordError.missingChannelId
        }

        let replyToId = message.metadata["discord_message_id"]
            ?? message.metadata["reply_to_id"]

        // Redact secrets before sending (defense-in-depth)
        let redactedText = secretRedactor.redact(message.text)

        // Split long messages at Discord's 2000-char limit
        let chunks = splitMessage(redactedText, maxLength: configuration.maxMessageLength)

        for (index, chunk) in chunks.enumerated() {
            // Only the first chunk is a reply
            let reference: MessageReference? = (index == 0 && replyToId != nil)
                ? MessageReference(
                    message_id: replyToId!,
                    channel_id: channelId,
                    guild_id: message.metadata["discord_guild_id"],
                )
                : nil

            let body = CreateMessageRequest(content: chunk, message_reference: reference)

            Task {
                do {
                    try await sendRESTMessage(channelId: channelId, body: body)
                } catch {
                    print("[DiscordChannel] Failed to send message to \(channelId): \(error)")
                }
            }
        }
    }

    /// Send a message via the Discord REST API.
    private func sendRESTMessage(channelId: String, body: CreateMessageRequest) async throws {
        let urlString = "\(configuration.restBaseURL)/channels/\(channelId)/messages"
        guard let url = URL(string: urlString) else {
            throw DiscordError.invalidURL(urlString)
        }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("Bot \(configuration.token)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("DiscordBot (Aozora CIMS, 1.0)", forHTTPHeaderField: "User-Agent")

        request.httpBody = try jsonEncoder.encode(body)

        let (data, response) = try await urlSession.data(for: request)

        guard let httpResponse = response as? HTTPURLResponse else {
            throw DiscordError.invalidResponse
        }

        guard (200 ... 299).contains(httpResponse.statusCode) else {
            let body = String(data: data, encoding: .utf8) ?? "unknown"
            throw DiscordError.apiError(statusCode: httpResponse.statusCode, body: body)
        }
    }

    // MARK: - Gateway Protocol

    /// Send an Identify payload to the Gateway.
    private func sendIdentify() async {
        let intents = GatewayIntents.messageBot.rawValue
        let identify = IdentifyPayload(
            token: configuration.token,
            intents: intents,
            properties: ConnectionProperties(os: "macOS", browser: "Aozora", device: "Aozora"),
        )

        let payload = GatewayPayload(
            op: GatewayOpcode.identify.rawValue,
            d: AnyCodable(encodableToDict(identify)),
            s: nil,
            t: nil,
        )

        await sendGatewayPayload(payload)
    }

    /// Send a Resume payload to the Gateway.
    private func sendResume(sessionId: String, sequence: Int) async {
        let resume = ResumePayload(
            token: configuration.token,
            session_id: sessionId,
            seq: sequence,
        )

        let payload = GatewayPayload(
            op: GatewayOpcode.resume.rawValue,
            d: AnyCodable(encodableToDict(resume)),
            s: nil,
            t: nil,
        )

        await sendGatewayPayload(payload)
    }

    /// Send a heartbeat to the Gateway.
    private func sendHeartbeat() async {
        let payload = GatewayPayload(
            op: GatewayOpcode.heartbeat.rawValue,
            d: lastSequence.map { AnyCodable($0) },
            s: nil,
            t: nil,
        )

        await sendGatewayPayload(payload)
    }

    /// Start the heartbeat loop at the given interval.
    private func startHeartbeat(intervalMs: Int) {
        heartbeatTask?.cancel()

        let intervalSeconds = Double(intervalMs) / 1_000.0
        // Add jitter: first heartbeat at random fraction of interval
        let jitter = Double.random(in: 0 ..< intervalSeconds)

        heartbeatTask = Task { [weak self] in
            guard let self else { return }

            // Initial jitter
            try? await Task.sleep(for: .seconds(jitter))

            while !Task.isCancelled {
                await sendHeartbeat()
                try? await Task.sleep(for: .seconds(intervalSeconds))
            }
        }
    }

    /// Encode and send a payload over the Gateway WebSocket.
    private func sendGatewayPayload(_ payload: GatewayPayload) async {
        guard let task = webSocketTask else { return }

        do {
            let data = try jsonEncoder.encode(payload)
            guard let text = String(data: data, encoding: .utf8) else { return }
            try await task.send(.string(text))
        } catch {
            print("[DiscordChannel] Failed to send gateway payload: \(error)")
        }
    }

    // MARK: - Reconnection

    /// Handle a disconnection — attempt to resume the session.
    ///
    /// Uses exponential backoff (1s, 2s, 4s, 8s, ... up to 60s) with jitter.
    /// After 5 consecutive failures on a resume URL, resets the session and
    /// falls back to the default gateway. The failure counter continues to grow
    /// so the backoff keeps increasing — only a successful connection resets it.
    ///
    /// After 50 consecutive failures (~25 minutes at max backoff), the daemon stops
    /// reconnecting entirely. This prevents the 1000+ connection storm that triggers
    /// Discord's automatic token reset.
    private func handleDisconnect() async {
        isConnected = false

        heartbeatTask?.cancel()
        heartbeatTask = nil

        receiveTask?.cancel()
        receiveTask = nil

        webSocketTask?.cancel(with: .goingAway, reason: nil)
        webSocketTask = nil

        guard isRunning else { return }

        consecutiveFailures += 1

        // After 50 consecutive failures, give up. The token is likely invalid
        // or there's a persistent network issue. Prevents reconnect storms that
        // trigger Discord's automatic token reset (1000+ connections).
        if consecutiveFailures >= 50 {
            print("[DiscordChannel] \(consecutiveFailures) consecutive failures — giving up. Check bot token and network.")
            isRunning = false
            return
        }

        // After 5 consecutive failures, reset the session and fall back to
        // the default gateway. The resume URL may point to a dead endpoint.
        // NOTE: failure counter is NOT reset — backoff keeps growing.
        if consecutiveFailures == 5 {
            print("[DiscordChannel] \(consecutiveFailures) consecutive failures — resetting session, falling back to default gateway")
            sessionId = nil
            resumeGatewayURL = nil
            lastSequence = nil
        }

        // Exponential backoff: 2s, 4s, 8s, 16s, 32s, 60s max, with 25% jitter
        let baseDelay = min(60.0, pow(2.0, Double(consecutiveFailures)))
        let jitter = Double.random(in: 0 ... baseDelay * 0.25)
        let delay = baseDelay + jitter
        try? await Task.sleep(for: .seconds(delay))

        if isRunning {
            if consecutiveFailures <= 2 || consecutiveFailures % 5 == 0 {
                print("[DiscordChannel] Reconnecting (attempt \(consecutiveFailures), backoff \(String(format: "%.0f", delay))s)...")
            }
            connectToGateway()
        }
    }

    // MARK: - Utilities

    /// Re-encode an AnyCodable value to Data for typed decoding.
    private nonisolated func reencodeData(_ anyCodable: AnyCodable?) -> Data? {
        guard let anyCodable else { return nil }
        return try? jsonEncoder.encode(anyCodable)
    }

    /// Convert an Encodable to a dictionary for wrapping in AnyCodable.
    private nonisolated func encodableToDict(_ value: some Encodable) -> [String: any Sendable] {
        guard let data = try? jsonEncoder.encode(value),
              let dict = try? JSONSerialization.jsonObject(with: data) as? [String: any Sendable]
        else {
            return [:]
        }
        return dict
    }

    /// Split a message into chunks respecting Discord's character limit.
    ///
    /// Delegates to ``MessageChunker`` which preserves code fence integrity —
    /// if a split falls inside an open code fence, the fence is closed at the end
    /// of the current chunk and reopened at the start of the next.
    public nonisolated func splitMessage(_ text: String, maxLength: Int) -> [String] {
        MessageChunker.split(text, maxLength: maxLength)
    }

    // MARK: - Connection Status

    /// Whether the Gateway connection is currently active.
    var connectionStatus: DiscordConnectionStatus {
        if isConnected { return .connected }
        if isRunning { return .connecting }
        return .disconnected
    }

    // MARK: - Image Conversion

    /// Convert unsupported image formats (HEIC, AVIF, etc.) to JPEG for the Anthropic vision API.
    ///
    /// The API supports JPEG, PNG, GIF, and WebP. Any other format is re-encoded as JPEG
    /// at 85% quality using `ImageIO`. Falls back to the original data if conversion fails.
    ///
    /// - Parameters:
    ///   - data: Raw image data.
    ///   - mediaType: The original MIME type (e.g., `"image/heic"`).
    /// - Returns: A tuple of (possibly converted data, final media type).
    nonisolated static func convertImageIfNeeded(data: Data, mediaType: String) -> (Data, String) {
        // Detect actual format from magic bytes — Discord sometimes reports wrong content_type
        // (e.g., iOS sends HEIC data but Discord says image/jpeg).
        let actualType = detectImageType(data)
        let supportedTypes = ["image/jpeg", "image/png", "image/gif", "image/webp"]

        // If actual type matches a supported type, use it (regardless of what Discord claimed)
        if let actual = actualType, supportedTypes.contains(actual) {
            return (data, actual)
        }

        // If we can't detect or it's unsupported (HEIC, AVIF, etc.), convert to JPEG

        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              let cgImage = CGImageSourceCreateImageAtIndex(source, 0, nil)
        else {
            return (data, mediaType)
        }

        let mutableData = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(
            mutableData,
            "public.jpeg" as CFString,
            1,
            nil,
        ) else {
            return (data, mediaType)
        }

        CGImageDestinationAddImage(
            destination,
            cgImage,
            [kCGImageDestinationLossyCompressionQuality: 0.85] as CFDictionary,
        )
        CGImageDestinationFinalize(destination)

        return (mutableData as Data, "image/jpeg")
    }

    /// Detect image format from magic bytes in the data header.
    ///
    /// Returns the MIME type if recognized, nil otherwise.
    /// Handles: JPEG, PNG, GIF, WebP, HEIC/HEIF.
    private nonisolated static func detectImageType(_ data: Data) -> String? {
        guard data.count >= 12 else { return nil }
        let bytes = [UInt8](data.prefix(12))

        // JPEG: FF D8 FF
        if bytes[0] == 0xFF, bytes[1] == 0xD8, bytes[2] == 0xFF {
            return "image/jpeg"
        }
        // PNG: 89 50 4E 47
        if bytes[0] == 0x89, bytes[1] == 0x50, bytes[2] == 0x4E, bytes[3] == 0x47 {
            return "image/png"
        }
        // GIF: 47 49 46 38
        if bytes[0] == 0x47, bytes[1] == 0x49, bytes[2] == 0x46, bytes[3] == 0x38 {
            return "image/gif"
        }
        // WebP: RIFF....WEBP
        if bytes[0] == 0x52, bytes[1] == 0x49, bytes[2] == 0x46, bytes[3] == 0x46,
           bytes[8] == 0x57, bytes[9] == 0x45, bytes[10] == 0x42, bytes[11] == 0x50 {
            return "image/webp"
        }
        // HEIC/HEIF: ....ftyp at offset 4
        if bytes[4] == 0x66, bytes[5] == 0x74, bytes[6] == 0x79, bytes[7] == 0x70 {
            return "image/heic"
        }
        return nil
    }
}

// MARK: - Discord Errors

/// Errors specific to the Discord channel plugin.
public nonisolated enum DiscordError: Error, Sendable {
    /// No channel ID available for sending a message.
    case missingChannelId

    /// Invalid URL constructed from configuration.
    case invalidURL(String)

    /// Non-HTTP response received.
    case invalidResponse

    /// Discord API returned an error status code.
    case apiError(statusCode: Int, body: String)

    /// Gateway connection failed.
    case connectionFailed(String)
}

// MARK: - Connection Status

/// The current state of the Discord Gateway connection.
public nonisolated enum DiscordConnectionStatus: String, Sendable {
    case disconnected
    case connecting
    case connected
}
