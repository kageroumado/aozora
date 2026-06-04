import Foundation

// MARK: - Command System

/// Routes slash commands from any source (Discord, internal, future CLI) to CIMS subsystems.
///
/// Commands are the control plane — how the agent and its user configure, inspect, and steer the
/// cognitive architecture. They bypass the executive model's inference and execute directly
/// against stores and actors.
///
/// Sources:
/// - **External**: Discord slash commands, forwarded by the messaging channel plugin.
/// - **Internal**: The narrator (coordinator) can invoke commands as tool calls.
/// - **Future**: CLI, HTTP API, Aozora UI.
///
/// Commands never modify the conversation DAG directly — they're control plane, not data plane.
/// Results are returned as ``CommandResult`` for the caller to format appropriately.
public actor CommandRouter {
    private let memoryStore: any MemoryStoring
    private let identityStore: any IdentityStoring
    private let config: ConfigStore

    /// Optional closure providing live daemon status (event loop state, pending messages).
    /// Set by the daemon after creating the EventLoop.
    private var daemonStatusProvider: (@Sendable () async -> String)?

    /// Heartbeat control callbacks, set by the daemon after creating HeartbeatScheduler/Engine.
    private var heartbeatStopHandler: (@Sendable () async -> Void)?
    private var heartbeatStartHandler: (@Sendable () async -> Void)?
    private var heartbeatStatusHandler: (@Sendable () async -> String)?

    /// Registered command handlers, keyed by command name.
    private var handlers: [String: CommandHandler] = [:]

    public init(
        memoryStore: any MemoryStoring,
        identityStore: any IdentityStoring,
        config: ConfigStore,
    ) async {
        self.memoryStore = memoryStore
        self.identityStore = identityStore
        self.config = config
        registerBuiltinCommands()
    }

    /// Set the daemon status provider (called after EventLoop is created).
    public func setDaemonStatusProvider(_ provider: @escaping @Sendable () async -> String) {
        daemonStatusProvider = provider
    }

    /// Set heartbeat control handlers (called after HeartbeatScheduler/Engine are created).
    public func setHeartbeatHandlers(
        stop: @escaping @Sendable () async -> Void,
        start: @escaping @Sendable () async -> Void,
        status: @escaping @Sendable () async -> String,
    ) {
        heartbeatStopHandler = stop
        heartbeatStartHandler = start
        heartbeatStatusHandler = status
    }

    /// Parse and execute a command string.
    ///
    /// Accepts both slash-prefixed (`/status`) and bare (`status`) forms.
    /// Arguments are space-separated; quoted strings are treated as single arguments.
    ///
    /// - Parameter input: The raw command string (e.g., "/memory search consciousness").
    /// - Returns: The command result, or an error result if parsing/execution fails.
    public func execute(_ input: String) async -> CommandResult {
        let parsed = CommandParser.parse(input)

        guard let handler = handlers[parsed.name] else {
            let available = handlers.keys.sorted().joined(separator: ", ")
            return .error("Unknown command: \(parsed.name). Available: \(available)")
        }

        do {
            return try await handler.execute(parsed.arguments, parsed.flags)
        } catch {
            return .error("\(parsed.name) failed: \(error)")
        }
    }

    /// Register a custom command handler (for plugins to extend the command set).
    public func register(_ name: String, handler: CommandHandler) {
        handlers[name] = handler
    }

    // MARK: - Built-in Commands

    private func registerBuiltinCommands() {
        // ── Status ──────────────────────────────────────────────────────
        handlers["status"] = BlockHandler { [config, weak self] _, _ in
            var lines: [String] = []
            lines.append("## Aozora Status")
            lines.append("")

            // Daemon state (event loop)
            if let provider = await self?.daemonStatusProvider {
                let daemonStatus = await provider()
                lines.append(daemonStatus)
                lines.append("")
            }

            let contextBudget = await config.get(.contextBudget)
            let heartbeatInterval = await config.get(.heartbeatIntervalMinutes)
            let model = await config.get(.executiveModel)
            let effort = await config.get(.providerEffort)
            let thinking = await config.get(.providerThinking)
            lines.append("**Model**: \(model)")
            lines.append("**Effort**: \(effort) | **Thinking**: \(thinking)")
            lines.append("**Context budget**: \(contextBudget) tokens")
            lines.append("**Heartbeat**: every \(heartbeatInterval) min")

            return .text(lines.joined(separator: "\n"))
        }

        // ── Memory ─────────────────────────────────────────────────────
        handlers["memory"] = BlockHandler { [memoryStore] args, _ in
            guard let subcommand = args.first else {
                return .text("""
                Usage: /memory <subcommand>
                  search <query>   — FTS5 search across all conversations
                  grep <pattern>   — Regex search across node content
                  describe <id>    — Full description of a DAG node
                  expand <id...>   — Expand compressed nodes
                  stats            — Memory statistics
                """)
            }

            switch subcommand {
            case "search", "grep":
                let query = args.dropFirst().joined(separator: " ")
                guard !query.isEmpty else {
                    return .error("Usage: /memory \(subcommand) <query>")
                }
                let mode: GrepMode = subcommand == "grep" ? .regex : .fullText
                let matches = await memoryStore.grep(pattern: query, mode: mode, scope: .all)
                if matches.isEmpty {
                    return .text("No matches for: \(query)")
                }
                let lines = matches.prefix(10).map { m in
                    "**\(m.nodeId)** (score: \(String(format: "%.2f", m.score)))\n\(m.excerpt.prefix(200))"
                }
                return .text(lines.joined(separator: "\n\n"))

            case "describe":
                guard let nodeId = args.dropFirst().first else {
                    return .error("Usage: /memory describe <nodeId>")
                }
                let desc = await memoryStore.describe(id: nodeId)
                return .text("""
                **\(desc.nodeId)** [\(desc.kind.rawValue), depth \(desc.depth)]
                Tokens: \(desc.tokenCount)
                Time: \(desc.earliestAt) → \(desc.latestAt)
                Children: \(desc.childIds.count)
                \(desc.summaryText ?? desc.canonicalText ?? "(cold)")
                """)

            case "expand":
                let nodeIds = Array(args.dropFirst())
                guard !nodeIds.isEmpty else {
                    return .error("Usage: /memory expand <nodeId> [nodeId...]")
                }
                let result = await memoryStore.expand(nodeIds: nodeIds, tokenBudget: 8_000)
                let lines = result.nodes.map { n in
                    "### \(n.nodeId)\n\(n.text)"
                }
                var output = lines.joined(separator: "\n\n")
                if result.truncated {
                    output += "\n\n⚠️ Truncated (\(result.totalTokens) tokens)"
                }
                return .text(output)

            default:
                return .error("Unknown memory subcommand: \(subcommand)")
            }
        }

        // ── Identity ───────────────────────────────────────────────────
        handlers["identity"] = BlockHandler { [identityStore] args, _ in
            let subcommand = args.first ?? "show"

            switch subcommand {
            case "show":
                let block = await identityStore.currentIdentity()
                if block.claims.isEmpty {
                    return .text("No identity claims yet.")
                }
                let lines = block.claims.map { c in
                    "**\(c.claimKey)**: \(c.value) [\(c.epistemicStatus.rawValue), conf: \(String(format: "%.2f", c.confidence))]"
                }
                return .text("## Identity (v\(block.versionId))\n\n" + lines.joined(separator: "\n"))

            case "rollback":
                guard let versionStr = args.dropFirst().first,
                      let versionId = Int64(versionStr)
                else {
                    return .error("Usage: /identity rollback <versionId>")
                }
                await identityStore.rollbackIdentity(to: versionId)
                return .text("Rolled back identity to version \(versionId).")

            default:
                return .error("Unknown identity subcommand: \(subcommand). Use: show, rollback")
            }
        }

        // ── Mirror ─────────────────────────────────────────────────────
        handlers["mirror"] = BlockHandler { [identityStore] args, _ in
            let userKey = args.first ?? "user"
            let block = await identityStore.currentMirror(for: userKey)
            if block.claims.isEmpty {
                return .text("No mirror claims for user '\(userKey)'.")
            }
            let lines = block.claims.map { c in
                "**\(c.claimKey)**: \(c.value) [\(c.epistemicStatus.rawValue), conf: \(String(format: "%.2f", c.confidence))]"
            }
            return .text("## Mirror: \(userKey) (v\(block.versionId))\n\n" + lines.joined(separator: "\n"))
        }

        // ── Config ─────────────────────────────────────────────────────
        handlers["config"] = BlockHandler { [config] args, _ in
            guard let subcommand = args.first else {
                return .text("""
                Usage: /config <subcommand>
                  show             — Show all configuration
                  get <key>        — Get a specific value
                  set <key> <val>  — Set a value (persisted)
                  reset <key>      — Reset to default
                  keys             — List all config keys
                """)
            }

            switch subcommand {
            case "show":
                let all = await config.all()
                let lines = all.sorted(by: { $0.key < $1.key }).map { k, v in
                    "**\(k)**: \(v)"
                }
                return .text("## Configuration\n\n" + lines.joined(separator: "\n"))

            case "get":
                guard let key = args.dropFirst().first else {
                    return .error("Usage: /config get <key>")
                }
                if let value = await config.getRaw(key) {
                    return .text("**\(key)** = \(value)")
                } else {
                    return .error("Unknown config key: \(key)")
                }

            case "set":
                let remaining = Array(args.dropFirst())
                guard remaining.count >= 2 else {
                    return .error("Usage: /config set <key> <value>")
                }
                let key = remaining[0]
                let value = remaining.dropFirst().joined(separator: " ")
                do {
                    try await config.setRaw(key, value: value)
                    return .text("Set **\(key)** = \(value)")
                } catch {
                    return .error("Failed to set \(key): \(error)")
                }

            case "reset":
                guard let key = args.dropFirst().first else {
                    return .error("Usage: /config reset <key>")
                }
                await config.reset(key)
                return .text("Reset **\(key)** to default.")

            case "keys":
                let keys = ConfigKey.allCases.map { "  \($0.rawValue) — \($0.description)" }
                return .text("## Config Keys\n\n" + keys.joined(separator: "\n"))

            default:
                return .error("Unknown config subcommand: \(subcommand)")
            }
        }

        // ── Help ───────────────────────────────────────────────────────
        // ── Restart ────────────────────────────────────────────────────
        // ── Heartbeat ─────────────────────────────────────────────────
        handlers["heartbeat"] = BlockHandler { [weak self] args, _ in
            guard let self else { return .error("Router unavailable") }
            let sub = args.first ?? "status"
            switch sub {
            case "stop":
                if let stop = await heartbeatStopHandler {
                    await stop()
                    return .text("Heartbeats stopped.")
                }
                return .error("Heartbeat control not available")
            case "start":
                if let start = await heartbeatStartHandler {
                    await start()
                    return .text("Heartbeats restarted.")
                }
                return .error("Heartbeat control not available")
            case "status":
                if let status = await heartbeatStatusHandler {
                    return await .text(status())
                }
                return .error("Heartbeat control not available")
            default:
                return .text("Usage: /heartbeat [start|stop|status]")
            }
        }

        handlers["restart"] = BlockHandler { _, _ in
            let plistPath = NSHomeDirectory() + "/Library/LaunchAgents/ai.aozora.daemon.plist"
            Task.detached {
                try? await Task.sleep(for: .seconds(1))
                let unload = Process()
                unload.executableURL = URL(fileURLWithPath: "/bin/launchctl")
                unload.arguments = ["unload", plistPath]
                try? unload.run()
                unload.waitUntilExit()

                try? await Task.sleep(for: .seconds(1))

                let load = Process()
                load.executableURL = URL(fileURLWithPath: "/bin/launchctl")
                load.arguments = ["load", plistPath]
                try? load.run()
            }
            return .text("Restarting in 1 second...")
        }

        // ── Help ──────────────────────────────────────────────────────
        handlers["help"] = BlockHandler { _, _ in
            let commands = [
                "/status — Daemon status and active tool output",
                "/heartbeat [start|stop|status] — Control heartbeat timer",
                "/restart — Restart the daemon",
                "/memory — Search, describe, expand conversation memory",
                "/identity — View identity claims",
                "/mirror [user] — View mirror claims",
                "/config — View/set/reset configuration",
                "/help — This message",
            ]
            return .text("## Commands\n\n" + commands.joined(separator: "\n"))
        }
    }
}

// MARK: - Command Result

/// The result of executing a command.
public nonisolated enum CommandResult: Sendable {
    /// Plain text response (may contain markdown).
    case text(String)

    /// Structured data response (for programmatic consumers).
    case data([String: String])

    /// Command failed with an error message.
    case error(String)

    /// No output (command executed silently).
    case empty

    /// The display text for this result.
    public var displayText: String {
        switch self {
        case let .text(t): t
        case let .data(d): d.map { "\($0.key): \($0.value)" }.joined(separator: "\n")
        case let .error(e): "❌ \(e)"
        case .empty: ""
        }
    }

    /// Whether this result represents an error.
    public var isError: Bool {
        if case .error = self { return true }
        return false
    }
}

// MARK: - Command Handler Protocol

/// A handler that executes a specific command.
public nonisolated protocol CommandHandler: Sendable {
    /// Execute the command with the given arguments and flags.
    ///
    /// - Parameters:
    ///   - arguments: Positional arguments (excludes the command name).
    ///   - flags: Named flags (e.g., `--limit 10` → `["limit": "10"]`).
    /// - Returns: The command result.
    func execute(_ arguments: [String], _ flags: [String: String]) async throws -> CommandResult
}

/// A simple closure-based command handler.
public struct BlockHandler: CommandHandler, Sendable {
    public let block: @Sendable ([String], [String: String]) async throws -> CommandResult

    public init(_ block: @escaping @Sendable ([String], [String: String]) async throws -> CommandResult) {
        self.block = block
    }

    public func execute(_ arguments: [String], _ flags: [String: String]) async throws -> CommandResult {
        try await block(arguments, flags)
    }
}

// MARK: - Command Parser

/// Parses raw command input into structured components.
public nonisolated enum CommandParser {
    public struct ParsedCommand: Sendable {
        public let name: String
        public let arguments: [String]
        public let flags: [String: String]
    }

    /// Parse a raw command string.
    ///
    /// Handles:
    /// - Slash prefix: `/status` → name "status"
    /// - Quoted arguments: `/memory search "hello world"` → ["search", "hello world"]
    /// - Flags: `--limit 10 --format json` → ["limit": "10", "format": "json"]
    public static func parse(_ input: String) -> ParsedCommand {
        let trimmed = input.trimmingCharacters(in: .whitespaces)
        let withoutSlash = trimmed.hasPrefix("/") ? String(trimmed.dropFirst()) : trimmed

        let tokens = tokenize(withoutSlash)
        guard let first = tokens.first else {
            return ParsedCommand(name: "", arguments: [], flags: [:])
        }

        var arguments: [String] = []
        var flags: [String: String] = [:]

        var i = 1
        while i < tokens.count {
            let token = tokens[i]
            if token.hasPrefix("--") {
                let key = String(token.dropFirst(2))
                if i + 1 < tokens.count, !tokens[i + 1].hasPrefix("--") {
                    flags[key] = tokens[i + 1]
                    i += 2
                } else {
                    flags[key] = "true"
                    i += 1
                }
            } else {
                arguments.append(token)
                i += 1
            }
        }

        return ParsedCommand(name: first.lowercased(), arguments: arguments, flags: flags)
    }

    /// Tokenize respecting quoted strings.
    private static func tokenize(_ input: String) -> [String] {
        var tokens: [String] = []
        var current = ""
        var inQuote = false
        var quoteChar: Character = "\""

        for char in input {
            if inQuote {
                if char == quoteChar {
                    inQuote = false
                } else {
                    current.append(char)
                }
            } else if char == "\"" || char == "'" {
                inQuote = true
                quoteChar = char
            } else if char == " " {
                if !current.isEmpty {
                    tokens.append(current)
                    current = ""
                }
            } else {
                current.append(char)
            }
        }
        if !current.isEmpty {
            tokens.append(current)
        }
        return tokens
    }
}
