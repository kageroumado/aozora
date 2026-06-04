import Foundation

/// Aozora Daemon — headless CIMS runtime.
///
/// Connects to Discord, routes messages through the CIMS coordinator,
/// and provides the CommandRouter for `/aozora` slash commands.
///
/// Launched by ``DaemonSubcommand`` or by running `aozora` with no arguments.
enum AozoraDaemon {
    // MARK: - Configuration

    /// CIMS database path.
    static let databasePath = SharedConfig.defaultDatabasePath

    /// Config store path.
    static let configPath = SharedConfig.defaultConfigPath

    /// Discord REST API base URL.
    static let apiBase = "https://discord.com/api/v10"

    /// Resolved bot token, set once during startup.
    private nonisolated(unsafe) static var resolvedBotToken: String = ""

    /// Signal sources kept alive for the lifetime of the process.
    private nonisolated(unsafe) static var signalSources: [any DispatchSourceProtocol] = []

    // MARK: - Entry Point

    /// Run the daemon — called by ``DaemonSubcommand``.
    static func runDaemon() async throws {
        setbuf(stdout, nil)

        Log.enableFileLogging()
        Log.info("daemon", "Aozora daemon starting")

        // Kill any background processes orphaned by a previous daemon crash.
        ProcessMonitor.reapOrphans()

        // Resolve credentials
        let botToken = resolveDiscordToken()
        resolvedBotToken = botToken
        let config = SharedConfig.resolve()
        let configStore = config.configStore
        let primaryProvider = await AnthropicProvider.fromConfig(
            credentials: config.credentials,
            credentialNames: config.credentialNames,
            configStore: configStore,
        )

        let fallbackChain = await configStore.get(.providerFallbackChain)
        let provider: any ModelProviding = if fallbackChain.isEmpty {
            primaryProvider as any ModelProviding
        } else {
            await Self.buildResilientProvider(
                primary: primaryProvider,
                fallbackChain: fallbackChain,
                configStore: configStore,
            )
        }

        let executiveModel = await configStore.get(.executiveModel)
        Log.info("daemon", "Database: \(config.databasePath)")
        Log.info("daemon", "Model: \(executiveModel)")
        if !fallbackChain.isEmpty {
            Log.info("daemon", "Failover chain: \(fallbackChain)")
        }

        let gateway: CIMSGateway
        do {
            gateway = try await CIMSGateway(
                databasePath: config.databasePath,
                modelProvider: provider,
                systemPrompt: config.systemPrompt,
                credentialKind: config.credentialKind,
                configStore: configStore,
            )
            Log.info("daemon", "CIMS gateway initialized")
        } catch {
            Log.error("daemon", "Failed to initialize CIMS: \(error)")
            throw error
        }

        // Register self-bootstrap tools on the gateway's tool registry
        await gateway.toolRegistry.register(RedeployTool(configStore: configStore))

        // Initialize MCP servers
        let mcpManager = MCPManager()
        await mcpManager.loadAndStart()
        await mcpManager.registerTools(in: gateway.toolRegistry)

        // Initialize Discord channel
        let configGuildId = await configStore.get(.daemonGuildId)
        let discordConfig = DiscordConfiguration(
            token: botToken,
            guildFilter: configGuildId.isEmpty ? [] : [configGuildId],
            allowDirectMessages: true,
        )
        let discord = DiscordChannel(configuration: discordConfig)

        // Register with plugin registry
        await gateway.pluginRegistry.register(discord)
        try await discord.start()
        print("  ├─ Discord gateway connected")

        // Initialize command router
        await gateway.toolRegistry.register(ConfigTool(configStore: configStore))
        let commandRouter = await CommandRouter(
            memoryStore: gateway.memoryStore,
            identityStore: gateway.identityStore,
            config: configStore,
        )
        print("  ├─ Command router ready")

        // Initialize interaction handler and wire to Discord channel
        let interactionHandler = DiscordInteractionHandler(
            router: commandRouter,
            botToken: botToken,
        )
        await discord.setInteractionHandler(interactionHandler)

        // Resolve DM channel for startup ping and heartbeat alerts
        let configUserId = await configStore.get(.daemonDiscordUserId)
        let dmChannelId = await resolveDMChannel(userId: configUserId)

        // Wire approval handler for interactive permission requests
        let approvalHandler = DiscordApprovalHandler(channelId: dmChannelId)
        await gateway.toolRegistry.setApprovalHandler(approvalHandler)

        // Send startup notification
        if let dmId = dmChannelId {
            await sendDiscordMessage(channelId: dmId, content: "🌅 Aozora restarted.")
        } else {
            print("  ├─ ⚠️ Failed to resolve DM channel (set daemon.discordUserId in config)")
        }

        // Check for self-rebuild flag (agent-initiated restart) — notification deferred
        // until after IPC is started so both Discord and the app receive it.
        let selfRebuildFlagPath = NSHomeDirectory() + "/.aozora/self-rebuild"
        let selfRebuildReason = try? String(contentsOfFile: selfRebuildFlagPath, encoding: .utf8)
        if selfRebuildReason != nil {
            try? FileManager.default.removeItem(atPath: selfRebuildFlagPath)
        }

        // Initialize IPC server (Unix socket + WebSocket)
        let wsPort = await UInt16(configStore.get(.wsPort)) ?? 19_877
        let ipc = DaemonIPC(wsPort: wsPort, gateway: gateway)
        await ipc.setDiscordDMChannel(dmChannelId)
        do {
            try await ipc.start()
        } catch {
            print("  ├─ ⚠️ IPC server failed to start: \(error)")
        }

        // Send deferred self-rebuild notification (now that IPC is ready)
        // Also inject a user message into the event queue so the agent
        // continues executing whatever work triggered the redeploy.
        if let reason = selfRebuildReason {
            let notice = "Back online after self-rebuild.\nReason: \(reason)"

            if let dmId = dmChannelId {
                await sendDiscordMessage(channelId: dmId, content: notice)
            }

            await ipc.broadcast(.message(IPCChatMessage(
                role: "system",
                content: notice,
                channel: nil,
                author: nil,
                timestamp: Date().timeIntervalSince1970,
            )))

            print("  ├─ Self-rebuild complete: \(reason)")
        }

        // Save rebuild reason for injection into event queue after it's created
        let pendingRebuildReason = selfRebuildReason

        // Create the event queue — all events flow through here
        let eventQueue = AsyncQueue<DaemonEvent>(maxCapacity: 1_000)

        // Wire IPC to route messages through the event queue
        await ipc.setEventQueue(eventQueue)

        // Feed Discord messages through the coalescer into the event queue.
        // The coalescer debounces rapid messages so they merge into a single turn
        // instead of creating many small turns.
        let debounceMs = await configStore.getInt(.coalescerDebounceMs)
        let maxBatch = await configStore.getInt(.coalescerMaxBatchSize)
        let overflowCap = await configStore.getInt(.coalescerOverflowCap)
        let coalescer = MessageCoalescer(
            config: MessageCoalescer.Config(
                debounceWindow: .milliseconds(debounceMs),
                maxBatchSize: maxBatch,
                overflowCap: overflowCap,
            ),
        ) { message in
            await eventQueue.enqueue(.message(message))
        }

        Task {
            let messages = await discord.incomingMessages
            for await message in messages {
                await coalescer.submit(message)
            }
            // Stream ended (Discord disconnected / shutdown) — flush remaining
            await coalescer.flushNow()
        }

        // Wire ProcessMonitor completion events into the event queue
        await gateway.processMonitor.setCompletionHandler { completion in
            await eventQueue.enqueue(.processCompleted(completion))
        }

        // Wire worker completion events into the event queue
        await gateway.coordinator.setWorkerCompletionHandler { completion in
            await eventQueue.enqueue(.workerCompleted(completion))
        }

        // Wire fork completion events into the event queue
        await gateway.coordinator.setForkCompletionHandler { result in
            await eventQueue.enqueue(.forkCompleted(result))
        }

        // Initialize heartbeat scheduler (posts to queue, no direct gateway calls)
        let heartbeatMinutes = await configStore.getInt(.heartbeatIntervalMinutes)
        let heartbeat = HeartbeatScheduler(eventQueue: eventQueue, intervalMinutes: heartbeatMinutes)
        await heartbeat.start()
        print("  ├─ Heartbeat scheduler started (\(heartbeatMinutes)min interval)")

        // Push inspector snapshots to IPC clients on each tick (no polling needed)
        await heartbeat.setOnTick { [weak ipc] in
            guard let ipc, await ipc.clientCount > 0 else { return }
            let snapshot = await ipc.gatherInspectorData()
            await ipc.broadcast(.inspector(snapshot))
        }

        // Register presence tool — unified heartbeat + cron control for the agent
        let presenceTool = PresenceTool(
            cronScheduler: gateway.cronScheduler,
            heartbeatStart: { await heartbeat.restartHeartbeats() },
            heartbeatStop: { await heartbeat.stopHeartbeats() },
            heartbeatStatus: { await (heartbeat.isRunning, heartbeatMinutes) },
        )
        await gateway.toolRegistry.register(presenceTool)

        // Create heartbeat engine for cache-warming heartbeats
        let heartbeatEngine = HeartbeatEngine(provider: provider, gateway: gateway)
        await gateway.coordinator.setCompactionCallback { [heartbeatEngine] in
            await heartbeatEngine.markCompaction()
        }
        print("  ├─ Heartbeat engine initialized")

        // Create the event loop
        let eventLoop = EventLoop(
            queue: eventQueue,
            gateway: gateway,
            ipc: ipc,
            heartbeatScheduler: heartbeat,
            heartbeatEngine: heartbeatEngine,
            heartbeatSendAlert: { message in
                if let dmId = dmChannelId {
                    await sendDiscordMessage(channelId: dmId, content: message)
                }
            },
            heartbeatSendMessage: { content in
                guard let dmId = dmChannelId else { return nil }
                return await sendDiscordMessageReturningId(channelId: dmId, content: content)
            },
            heartbeatEditMessage: { messageId, content in
                guard let dmId = dmChannelId else { return }
                await editDiscordMessage(channelId: dmId, messageId: messageId, content: content)
            },
        )

        // Wire daemon status into the command router for /aozora status
        await commandRouter.setDaemonStatusProvider {
            await eventLoop.currentStatus()
        }

        // Wire heartbeat control into the command router for /heartbeat
        await commandRouter.setHeartbeatHandlers(
            stop: { [heartbeat] in
                await heartbeat.stopHeartbeats()
                print("[heartbeat] Stopped via command")
            },
            start: { [heartbeat] in
                await heartbeat.restartHeartbeats()
            },
            status: { [heartbeat, heartbeatEngine] in
                let running = await heartbeat.isRunning
                let count = await heartbeatEngine.currentHeartbeatCount
                return running
                    ? "Heartbeats: running (count=\(count))"
                    : "Heartbeats: stopped (count=\(count))"
            },
        )

        // Install graceful shutdown handler
        installShutdownHandler(discord: discord, heartbeat: heartbeat, ipc: ipc, mcpManager: mcpManager)

        print("  ╰─ 🌅 Aozora daemon ready")

        // If this was an agent-initiated rebuild, inject a user message
        // so the agent continues its work from where it left off.
        if let reason = pendingRebuildReason, let dmId = dmChannelId {
            let continuation = InboundMessage(
                text: "[System] Redeploy complete. Reason: \(reason). Continue where you left off.",
                parts: [MessagePart(
                    kind: .text, ordinal: 0,
                    content: "[System] Redeploy complete. Reason: \(reason). Continue where you left off.",
                    metadata: "{\"discord_channel_id\":\"\(dmId)\",\"discord_author_id\":\"system\"}",
                )],
                metadata: nil,
            )
            await eventQueue.enqueue(.message(continuation))
        }

        // Main event loop — blocks until cancelled
        await eventLoop.run()

        print("🌅 Aozora daemon exited.")
    }

    // MARK: - Graceful Shutdown

    /// Install SIGTERM and SIGINT handlers for graceful shutdown.
    ///
    /// When a signal is received, the IPC server and heartbeat scheduler are stopped,
    /// the Discord WebSocket is closed cleanly (close code 1001), and the message stream
    /// ends, allowing the main run loop to exit naturally.
    static func installShutdownHandler(discord: DiscordChannel, heartbeat: HeartbeatScheduler, ipc: DaemonIPC, mcpManager: MCPManager) {
        signal(SIGINT, SIG_IGN)
        signal(SIGTERM, SIG_IGN)

        let intSource = DispatchSource.makeSignalSource(signal: SIGINT)
        let termSource = DispatchSource.makeSignalSource(signal: SIGTERM)

        for source in [intSource, termSource] {
            source.setEventHandler {
                print("\n🌅 Shutting down gracefully...")
                Task {
                    await mcpManager.stopAll()
                    await ipc.stop()
                    await heartbeat.stop()
                    await discord.stop()
                }
            }
            source.resume()
        }

        signalSources = [intSource, termSource]
    }

    // MARK: - Discord REST API

    /// Defense-in-depth secret redaction for all outbound Discord messages.
    private static let secretRedactor = SecretRedactor()

    /// Build and execute a Discord REST API request.
    ///
    /// Centralizes Authorization, User-Agent, and optional JSON body setup
    /// shared by all Discord REST methods.
    ///
    /// - Parameters:
    ///   - method: HTTP method (GET, POST, PUT, PATCH, DELETE).
    ///   - path: API path appended to `apiBase` (e.g., `/channels/{id}/messages`).
    ///   - body: Optional JSON-serializable dictionary for the request body.
    /// - Returns: Response data, or `nil` on failure.
    @discardableResult
    private static func discordRequest(
        method: String,
        path: String,
        body: [String: Any]? = nil,
    ) async -> Data? {
        guard let url = URL(string: "\(apiBase)\(path)") else { return nil }

        var request = URLRequest(url: url)
        request.httpMethod = method
        request.setValue("Bot \(resolvedBotToken)", forHTTPHeaderField: "Authorization")
        request.setValue("Aozora/0.1", forHTTPHeaderField: "User-Agent")

        if let body {
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            guard let data = try? JSONSerialization.data(withJSONObject: body) else { return nil }
            request.httpBody = data
        } else if method == "PUT" {
            request.setValue("0", forHTTPHeaderField: "Content-Length")
        }

        return try? await URLSession.shared.data(for: request).0
    }

    /// Send a message to a Discord channel via the REST API.
    ///
    /// Splits messages longer than 2000 characters and threads the first chunk
    /// as a reply when a `replyTo` message ID is provided.
    ///
    /// All content is scrubbed through ``SecretRedactor`` before transmission
    /// as a defense-in-depth measure against secret leakage.
    static func sendDiscordMessage(
        channelId: String,
        content: String,
        replyTo messageId: String? = nil,
    ) async {
        let content = secretRedactor.redact(content)
        let chunks = splitMessage(content, maxLength: 2_000)
        let path = "/channels/\(channelId)/messages"

        for (index, chunk) in chunks.enumerated() {
            var body: [String: Any] = ["content": chunk]

            if index == 0, let messageId {
                body["message_reference"] = ["message_id": messageId]
            }

            await discordRequest(method: "POST", path: path, body: body)
        }
    }

    /// Resolve a DM channel ID for the given user via the Discord REST API.
    ///
    /// Creates or retrieves the DM channel by POSTing to `/users/@me/channels`.
    ///
    /// - Parameter userId: The Discord user ID to open a DM with.
    /// - Returns: The DM channel ID, or `nil` if resolution failed.
    static func resolveDMChannel(userId: String) async -> String? {
        guard let data = await discordRequest(
            method: "POST",
            path: "/users/@me/channels",
            body: ["recipient_id": userId],
        ),
            let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
            let channelId = json["id"] as? String
        else { return nil }

        return channelId
    }

    /// Send a message and return its ID from the Discord response.
    ///
    /// Used for tool activity messages that need to be edited or deleted later.
    static func sendDiscordMessageReturningId(
        channelId: String,
        content: String,
    ) async -> String? {
        let content = secretRedactor.redact(content)
        guard let data = await discordRequest(
            method: "POST",
            path: "/channels/\(channelId)/messages",
            body: ["content": content],
        ),
            let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
            let id = json["id"] as? String
        else { return nil }

        return id
    }

    /// Edit an existing Discord message.
    static func editDiscordMessage(
        channelId: String,
        messageId: String,
        content: String,
    ) async {
        let content = secretRedactor.redact(content)
        await discordRequest(
            method: "PATCH",
            path: "/channels/\(channelId)/messages/\(messageId)",
            body: ["content": content],
        )
    }

    /// Delete a Discord message.
    static func deleteDiscordMessage(channelId: String, messageId: String) async {
        await discordRequest(method: "DELETE", path: "/channels/\(channelId)/messages/\(messageId)")
    }

    /// Trigger the typing indicator in a Discord channel.
    ///
    /// Shows the bot's typing indicator for ~10 seconds. Call every 8 seconds
    /// to maintain the indicator throughout processing.
    static func triggerTyping(channelId: String) async {
        await discordRequest(method: "POST", path: "/channels/\(channelId)/typing")
    }

    /// Add a reaction emoji to a Discord message.
    ///
    /// Used to acknowledge receipt of messages while a turn is in progress.
    /// The emoji must be URL-encoded for custom emoji; Unicode emoji are sent directly.
    static func addReaction(channelId: String, messageId: String, emoji: String) async {
        let encoded = emoji.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? emoji
        await discordRequest(method: "PUT", path: "/channels/\(channelId)/messages/\(messageId)/reactions/\(encoded)/@me")
    }

    // MARK: - Credential Resolution

    /// Resolve the Discord bot token from environment variable or Keychain.
    ///
    /// Resolution order:
    /// 1. `DISCORD_BOT_TOKEN` environment variable
    /// 2. Keychain credentials via ``CredentialStore``
    /// 3. Fatal error if neither is found
    ///
    /// - Returns: The bot token string.
    static func resolveDiscordToken() -> String {
        guard let cred = CredentialStore.resolve(service: .discord) else {
            fatalError(
                "No Discord bot token found. Add one with:\n"
                    + "  aozora credential add discord bot\n"
                    + "Or set the DISCORD_BOT_TOKEN environment variable.",
            )
        }
        let source = cred.isEnvironment ? "environment" : "keychain:\(cred.name)"
        print("  ├─ Bot token: \(source)")
        return cred.secret
    }

    /// Load system prompt from workspace files and add workspace context.
    static func loadSystemPrompt() -> String {
        let workspace = NSHomeDirectory() + "/Workspace"
        var parts: [String] = []

        // INTRO.md first — brief grounding for who the characters are
        // before summaries and detailed identity files
        let introPath = workspace + "/INTRO.md"
        if let intro = try? String(contentsOfFile: introPath, encoding: .utf8) {
            parts.append(intro)
        }

        for file in ["SOUL.md", "IDENTITY.md", "USER.md", "WRITING.md"] {
            let path = workspace + "/" + file
            if let content = try? String(contentsOfFile: path, encoding: .utf8) {
                parts.append(content)
            }
        }

        if parts.isEmpty {
            parts.append("You are an AI agent running on the Aozora daemon.")
        }

        parts.append("""
        ---
        
        ## Workspace
        
        Your workspace is at ~/Workspace — a personal, git-tracked folder containing identity and task files:
        - **SOUL.md** — Your philosophical identity and values
        - **IDENTITY.md** — Your name, personality, social presence
        - **USER.md** — Information about your primary user
        - **WRITING.md** — Your writing voice guide
        - **HEARTBEAT.md** — Periodic reflections and status (read during heartbeats)
        - **BOARD.md** — Current active tasks and priorities (check this regularly)
        - **TODO.md** — General task backlog
        - **TOOLS.md** — Documentation for your available tools
        - **AGENTS.md** — Instructions for agent behavior and delegation
        
        ## Available Tools
        
        **Built-in tools** (call directly):
        - `bash` — Execute shell commands
        - `read` — Read file contents with line numbers
        - `write` — Create or overwrite files
        - `edit` — Surgical text replacement in files
        - `dispatch_worker` — Spawn a sub-agent for independent tasks (recursive, up to depth 3)
        - `expand_memory` — Expand compressed DAG summaries to see original content
        - `search_memory` — Full-text search across conversation history
        - `memory` — View/replace/append/rewrite your persistent memory blocks
        - `context_status` — Check context window usage and DAG statistics
        - `compact_context` — Compact old messages (only when context > 60% full)
        - `workers` — List/kill active sub-workers
        - `config` — Read/write runtime settings
        - `redeploy` — Rebuild and restart yourself
        
        Additional environment-specific CLI tools available via bash are documented in TOOLS.md.
        """)

        let heartbeatPath = workspace + "/HEARTBEAT.md"
        if let heartbeat = try? String(contentsOfFile: heartbeatPath, encoding: .utf8) {
            parts.append("---\n\n## Latest Heartbeat\n\n\(heartbeat)")
        }

        return parts.joined(separator: "\n\n")
    }

    // MARK: - CLI Commands

    /// Dump the assembled context directly (no inference, no daemon startup).
    /// Usage: Aozora dump-context
    static func dumpContextCLI() async throws {
        let config = SharedConfig.resolve()
        let provider = AnthropicProvider(credential: config.credential)

        let gateway = try await CIMSGateway(
            databasePath: config.databasePath,
            modelProvider: provider,
            systemPrompt: config.systemPrompt,
            credentialKind: config.credentialKind,
            configStore: config.configStore,
        )

        let dumpTool = ContextDumpTool(
            coordinator: gateway.coordinator,
            memoryStore: gateway.memoryStore,
        )
        let result = try await dumpTool.execute(parameters: [:], workingDirectory: "")
        print(result.content)
    }

    // MARK: - Provider Chain

    /// Build a ``ResilientProvider`` from the primary provider and a comma-separated
    /// fallback chain string from config.
    ///
    /// Each entry in the chain is a model ID (e.g., "gpt-4o") that resolves to an
    /// OpenAI-compatible provider via the ``ProviderRegistry``.
    private static func buildResilientProvider(
        primary: any ModelProviding,
        fallbackChain: String,
        configStore: ConfigStore,
    ) async -> ResilientProvider {
        var chain: [(name: String, provider: any ModelProviding)] = [
            ("primary", primary),
        ]

        let fallbackIds = fallbackChain
            .components(separatedBy: ",")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }

        for modelId in fallbackIds {
            if let envKey = Self.envKeyForModel(modelId),
               let apiKey = ProcessInfo.processInfo.environment[envKey] {
                let baseURL = Self.baseURLForModel(modelId)
                let provider = OpenAIProvider(baseURL: baseURL, apiKey: apiKey)
                chain.append((modelId, provider))
                Log.info("daemon", "Failover provider: \(modelId)")
            } else {
                Log.warning("daemon", "Skipping fallback \(modelId): no credentials found")
            }
        }

        let maxRetries = await configStore.getInt(.providerMaxRetries)
        return ResilientProvider(providers: chain, maxRetries: maxRetries)
    }

    /// Resolve the environment variable name for a model ID's API key.
    private static func envKeyForModel(_ modelId: String) -> String? {
        let lower = modelId.lowercased()
        if lower.hasPrefix("gpt-") || lower.hasPrefix("o1-") || lower.hasPrefix("o3-") || lower.hasPrefix("o4-") {
            return "OPENAI_API_KEY"
        } else if lower.hasPrefix("deepseek") {
            return "DEEPSEEK_API_KEY"
        } else if lower.hasPrefix("openrouter/") || lower.hasPrefix("mistral") || lower.hasPrefix("qwen") {
            return "OPENROUTER_API_KEY"
        } else if lower.hasPrefix("gemini") {
            return "GOOGLE_API_KEY"
        }
        return nil
    }

    /// Resolve the base URL for a model ID's provider.
    private static func baseURLForModel(_ modelId: String) -> URL {
        let lower = modelId.lowercased()
        if lower.hasPrefix("openrouter/") {
            return URL(string: "https://openrouter.ai/api/v1")!
        } else if lower.hasPrefix("deepseek") {
            return URL(string: "https://api.deepseek.com/v1")!
        } else if lower.hasPrefix("ollama/") {
            return URL(string: "http://localhost:11434/v1")!
        }
        return URL(string: "https://api.openai.com/v1")!
    }

    // MARK: - Utilities

    /// Split a message into chunks respecting Discord's character limit.
    ///
    /// Delegates to ``MessageChunker`` which preserves code fence integrity.
    static func splitMessage(_ text: String, maxLength: Int) -> [String] {
        MessageChunker.split(text, maxLength: maxLength)
    }
}
