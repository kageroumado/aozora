import ArgumentParser
import Foundation

/// Test and diagnose prompt cache behavior.
///
/// Provides tools for verifying that the Anthropic API's prompt caching
/// is working correctly. Use `check` for a quick health check, `send`
/// for iterative testing with an isolated DB, and `reset` to clean up.
struct TestCacheSubcommand: AsyncParsableCommand {
    nonisolated static let configuration = CommandConfiguration(
        commandName: "test-cache",
        abstract: "Test and diagnose prompt cache behavior.",
        discussion: """
        Diagnose prompt caching issues without going through Discord.
        
        Examples:
          aozora test-cache check              # Quick cache health check
          aozora test-cache send "hello"       # Send a test message
          aozora test-cache send "follow up"   # Test cache on second turn
          aozora test-cache reset              # Clean up test DB
        """,
        subcommands: [
            CheckSubcommand.self,
            SendSubcommand.self,
            ResetSubcommand.self,
        ],
    )
}

// MARK: - Check

extension TestCacheSubcommand {
    /// Send two identical requests and verify cache hit.
    ///
    /// Assembles context from the production DB, builds a prompt, and sends it
    /// twice with `max_tokens=1`. If the second request gets a cache hit, the
    /// cache is healthy. If not, shows which system blocks or tools changed.
    struct CheckSubcommand: AsyncParsableCommand {
        nonisolated static let configuration = CommandConfiguration(
            commandName: "check",
            abstract: "Send two identical requests and verify cache hit.",
            discussion: """
            Assembles context from the production DB, builds a prompt, and sends it
            twice with max_tokens=1. If the second request gets a cache hit, the cache
            is healthy. If not, shows which system blocks or tools changed.
            
            Cost: ~2 output tokens. Input charged at cache-write + cache-read rates.
            """,
        )

        @Flag(name: .long, help: "Show only the verdict, not detailed diagnostics.")
        var quiet = false

        @Flag(name: .long, help: "Write the full prompt JSON to ~/.aozora/debug-test-prompt.json.")
        var dumpPrompt = false

        @Flag(name: .long, help: "Assemble the prompt but skip the API calls.")
        var noSend = false

        func run() async throws {
            setbuf(stdout, nil)
            print("Resolving config...")
            let config = SharedConfig.resolve()

            print("Opening gateway (DB: \(config.databasePath))...")
            let gateway = try await CIMSGateway(
                databasePath: config.databasePath,
                systemPrompt: config.systemPrompt,
                credentialKind: config.credentialKind,
                configStore: config.configStore,
            )

            print("Assembling context...")
            let context = await gateway.coordinator.assembleForEstimate()
            print("Building prompt...")
            let promptBuilder = PromptBuilder()
            let tools = CIMSCoordinator.builtInTools
            var prompt = promptBuilder.build(context: context, credential: config.credentialKind, tools: tools).prompt

            // assembleForEstimate() has no current user message, so the messages
            // may end with an assistant turn. The API requires a trailing user message.
            if prompt.messages.last?.role != .user {
                prompt = Prompt(
                    system: prompt.system,
                    messages: prompt.messages + [APIMessage(role: .user, content: .text("Continue."))],
                    tools: prompt.tools,
                )
            }

            if dumpPrompt {
                let encoder = JSONEncoder()
                encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes, .prettyPrinted]
                if let data = try? encoder.encode(prompt) {
                    let path = NSHomeDirectory() + "/.aozora/debug-test-prompt.json"
                    try? data.write(to: URL(fileURLWithPath: path))
                    print("Prompt written to \(path)")
                }
            }

            guard !noSend else {
                let usage = TokenUsage(inputTokens: 0, outputTokens: 0, cacheReadTokens: 0, cacheCreationTokens: 0)
                let report = CacheDiagnostics.report(
                    prompt: prompt, usage: usage, boundaryIndex: nil,
                    previousSystemHash: nil, previousBlockHashes: nil,
                )
                if !quiet { print(CacheDiagnostics.format(report)) }
                print("\n--no-send: skipped API calls")
                return
            }

            let provider = AnthropicProvider(
                credential: config.credential,
                maxTokens: 1,
                thinking: .disabled,
                effort: .low,
            )

            print("Cache Health Check")
            print("━━━━━━━━━━━━━━━━━")

            let r1 = try await provider.complete(prompt, tier: .executive)
            let report1 = CacheDiagnostics.report(
                prompt: prompt, usage: r1.tokenUsage, boundaryIndex: nil,
                previousSystemHash: nil, previousBlockHashes: nil,
            )
            print("Request 1: cache_read=\(r1.tokenUsage.cacheReadTokens)  cache_create=\(r1.tokenUsage.cacheCreationTokens)  (cold start)")

            let r2 = try await provider.complete(prompt, tier: .executive)
            let report2 = CacheDiagnostics.report(
                prompt: prompt, usage: r2.tokenUsage, boundaryIndex: nil,
                previousSystemHash: report1.systemHash, previousBlockHashes: report1.blocks.map(\.contentHash),
            )
            let hit = r2.tokenUsage.cacheReadTokens > 0
            print("Request 2: cache_read=\(r2.tokenUsage.cacheReadTokens)  cache_create=\(r2.tokenUsage.cacheCreationTokens)  (\(hit ? "hit ✓" : "miss ✗"))")
            print()

            if !quiet {
                print("System: \(report1.blockCount) blocks, hash=\(report1.systemHash) (\(report2.systemHashChanged ? "CHANGED" : "stable"))")
                print("Tools:  \(report1.toolCount) tools, hash=\(report1.toolsHash)")
                print("Msgs:   \(report1.messageCount), boundary=\(report1.boundaryIndex.map(String.init) ?? "null")")
                print()

                if report2.systemHashChanged {
                    print("System blocks DIFFER:")
                    for i in report2.changedBlockIndices {
                        if i < report2.blocks.count {
                            let b = report2.blocks[i]
                            print("  block[\(i)]: hash \(report1.blocks[i].contentHash) → \(b.contentHash)")
                        }
                    }
                    print()
                }
            }

            let verdict = hit ? "HEALTHY" : "BROKEN — second identical request got 0% cache hit"
            print("Verdict: \(verdict)")
        }
    }
}

// MARK: - Send

extension TestCacheSubcommand {
    /// Run a full CIMS turn with an isolated test DB.
    ///
    /// Messages accumulate in a separate DB at `~/.aozora/test-cache.db` across
    /// invocations, simulating a real conversation for cache testing.
    struct SendSubcommand: AsyncParsableCommand {
        nonisolated static let configuration = CommandConfiguration(
            commandName: "send",
            abstract: "Run a full CIMS turn with an isolated test DB.",
            discussion: """
            Sends a message through the full CIMS pipeline using a separate test DB
            at ~/.aozora/test-cache.db. Messages accumulate across invocations.
            
            Use `aozora test-cache reset` to start fresh.
            """,
        )

        @Argument(help: "The message to send.")
        var message: String

        @Flag(name: .long, help: "Show only the response, not diagnostics.")
        var quiet = false

        @Flag(name: .long, help: "Write the full prompt JSON to ~/.aozora/debug-test-prompt.json.")
        var dumpPrompt = false

        @Flag(name: .long, help: "Assemble the prompt but skip the API call.")
        var noSend = false

        func run() async throws {
            let config = SharedConfig.resolve()
            let testDBPath = NSHomeDirectory() + "/.aozora/test-cache.db"

            let provider: any ModelProviding = if noSend {
                MockModelProvider()
            } else {
                await AnthropicProvider.fromConfig(
                    credential: config.credential,
                    configStore: config.configStore,
                )
            }

            let gateway = try await CIMSGateway(
                databasePath: testDBPath,
                modelProvider: provider,
                systemPrompt: config.systemPrompt,
                credentialKind: config.credentialKind,
                configStore: config.configStore,
            )

            if dumpPrompt {
                let context = await gateway.coordinator.assembleForEstimate()
                let promptBuilder = PromptBuilder()
                let tools = CIMSCoordinator.builtInTools
                let prompt = promptBuilder.build(context: context, credential: config.credentialKind, tools: tools).prompt
                let encoder = JSONEncoder()
                encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes, .prettyPrinted]
                if let data = try? encoder.encode(prompt) {
                    let path = NSHomeDirectory() + "/.aozora/debug-test-prompt.json"
                    try? data.write(to: URL(fileURLWithPath: path))
                    print("Prompt written to \(path)")
                }
            }

            guard !noSend else {
                print("--no-send: skipped inference")
                return
            }

            let inbound = InboundMessage(
                text: message,
                parts: [MessagePart(kind: .text, ordinal: 0, content: message, metadata: nil)],
                metadata: nil,
            )

            let request = TurnRequest(
                turnID: UUID().uuidString,
                sessionKey: "test-cache",
                userKey: "cli",
                message: inbound,
                receivedAt: Date(),
            )

            let observer = CLITurnObserver()
            try await gateway.runTurn(request, observer: observer)

            let response = await observer.responseText
            print("[response] \(response)")
        }
    }
}

// MARK: - Reset

extension TestCacheSubcommand {
    /// Delete the test cache DB.
    ///
    /// Moves `~/.aozora/test-cache.db` (and WAL/SHM files) to Trash.
    struct ResetSubcommand: AsyncParsableCommand {
        nonisolated static let configuration = CommandConfiguration(
            commandName: "reset",
            abstract: "Delete the test cache DB.",
            discussion: "Moves ~/.aozora/test-cache.db to Trash so you can start fresh.",
        )

        func run() throws {
            let testDBPath = NSHomeDirectory() + "/.aozora/test-cache.db"
            let url = URL(fileURLWithPath: testDBPath)

            guard FileManager.default.fileExists(atPath: testDBPath) else {
                print("No test cache DB found at \(testDBPath)")
                return
            }

            var trashedURL: NSURL?
            try FileManager.default.trashItem(at: url, resultingItemURL: &trashedURL)
            print("Moved test cache DB to Trash")

            for suffix in ["-wal", "-shm"] {
                let path = testDBPath + suffix
                if FileManager.default.fileExists(atPath: path) {
                    try? FileManager.default.trashItem(at: URL(fileURLWithPath: path), resultingItemURL: nil)
                }
            }
        }
    }
}
