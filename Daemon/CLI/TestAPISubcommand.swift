import ArgumentParser
import Foundation

/// Send a minimal API request to verify credentials and connectivity.
///
/// Bypasses the full daemon stack — no database, no Discord, no CIMS.
/// Useful for diagnosing authentication, overload, or network issues.
struct TestAPISubcommand: AsyncParsableCommand {
    nonisolated static let configuration = CommandConfiguration(
        commandName: "test-api",
        abstract: "Send a test request to the Anthropic API.",
    )

    @Option(name: .long, help: "Model to test.")
    var model: String = "claude-sonnet-4-6"

    @Option(name: .long, help: "Prompt to send.")
    var prompt: String = "Say hello in exactly 3 words."

    @Option(name: .long, help: "Max output tokens.")
    var maxTokens: Int = 1_024

    @Flag(name: .long, help: "Enable extended thinking (adaptive).")
    var thinking: Bool = false

    func run() async throws {
        let config = SharedConfig.resolve()
        let credential = config.credential

        let thinkingMode: AnthropicProvider.ThinkingMode = thinking ? .adaptive : .disabled
        let provider = AnthropicProvider(
            credential: credential,
            modelOverrides: [.executive: model],
            maxTokens: maxTokens,
            thinking: thinkingMode,
        )

        print("Testing API...")
        print("  Model: \(model)")
        print("  Prompt: \(prompt)")
        print("  Max tokens: \(maxTokens)")
        print("  Thinking: \(thinking ? "adaptive" : "disabled")")
        print()

        let testPrompt = Prompt(
            system: [SystemBlock(text: "You are a helpful assistant.", cacheControl: nil)],
            messages: [APIMessage(role: .user, content: .text(prompt))],
            tools: [],
        )

        let start = ContinuousClock.now
        do {
            let response = try await provider.complete(
                testPrompt,
                tier: .executive,
            )
            let elapsed = ContinuousClock.now - start

            print("Response: \(response.content)")
            print()
            print("Stats:")
            print("  Input tokens:  \(response.tokenUsage.inputTokens)")
            print("  Output tokens: \(response.tokenUsage.outputTokens)")
            print("  Cache read:    \(response.tokenUsage.cacheReadTokens)")
            print("  Cache create:  \(response.tokenUsage.cacheCreationTokens)")
            print("  Latency:       \(elapsed)")
            print("  Stop reason:   \(response.stopReason)")
        } catch {
            let elapsed = ContinuousClock.now - start
            print("Error (\(elapsed)): \(error)")
            throw ExitCode.failure
        }
    }
}
