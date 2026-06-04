import ArgumentParser
import Foundation

/// Dump the assembled context without running inference.
///
/// Runs the full context assembly pipeline (system prompt, summaries, messages)
/// and prints the result. Useful for inspecting what the model would see.
///
/// Does not require API credentials — uses a dummy credential since no
/// inference is performed.
struct DumpContextSubcommand: AsyncParsableCommand {
    nonisolated static let configuration = CommandConfiguration(
        commandName: "dump-context",
        abstract: "Dump the assembled context (no inference).",
    )

    func run() async throws {
        // Use a dummy credential — dump-context never calls the API.
        let dummyCredential: ClaudeCredential = .apiKey("dump-context-no-api-call")

        let configStore = ConfigStore(storagePath: SharedConfig.defaultConfigPath)
        let provider = AnthropicProvider(credential: dummyCredential)

        // Determine credential kind from what's actually stored (for prompt formatting)
        let credentialKind: CredentialKind = if let resolved = CredentialStore.resolve(service: .anthropic) {
            resolved.type == .oauth ? .oauth : .apiKey
        } else {
            .oauth
        }

        let gateway = try await CIMSGateway(
            databasePath: SharedConfig.defaultDatabasePath,
            modelProvider: provider,
            systemPrompt: AozoraDaemon.loadSystemPrompt(),
            credentialKind: credentialKind,
            configStore: configStore,
        )

        let dumpTool = ContextDumpTool(
            coordinator: gateway.coordinator,
            memoryStore: gateway.memoryStore,
        )
        let result = try await dumpTool.execute(parameters: [:], workingDirectory: "")
        print(result.content)
    }
}
