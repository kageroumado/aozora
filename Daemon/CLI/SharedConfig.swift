import Foundation

/// Shared credential and configuration resolution for CLI subcommands and the daemon.
///
/// Owns the credential resolution logic. All CLI entry points and the daemon call
/// ``resolve()`` for consistent credential handling.
///
/// Resolution order for Anthropic credentials:
/// 1. `ANTHROPIC_API_KEY` environment variable (override)
/// 2. macOS Keychain credentials sorted by priority (via ``CredentialStore``)
struct SharedConfig {
    /// All available Anthropic credentials, sorted by priority.
    ///
    /// The first credential is the active one; subsequent entries are fallbacks
    /// for rate-limit rotation in ``AnthropicProvider``.
    let credentials: [ClaudeCredential]

    /// Human-readable names for each credential (parallel to ``credentials``).
    let credentialNames: [String]

    /// The primary (active) Anthropic credential.
    var credential: ClaudeCredential {
        credentials[0]
    }

    /// Credential discriminant for ``PromptBuilder``.
    let credentialKind: CredentialKind

    /// Assembled system prompt from workspace files.
    let systemPrompt: String

    /// Path to the CIMS database.
    let databasePath: String

    /// Runtime configuration store.
    let configStore: ConfigStore

    /// Standard database path.
    static let defaultDatabasePath = NSHomeDirectory() + "/.aozora/cims.db"

    /// Standard config file path.
    static let defaultConfigPath = NSHomeDirectory() + "/.aozora/config.json"

    /// Resolve credentials and config from standard locations.
    ///
    /// Uses environment variable → Keychain (by priority) for Anthropic credentials.
    /// Migrates legacy ``ClaudeCredentialStore`` keychain entries on first run.
    /// Workspace files for system prompt. `~/.aozora/cims.db` for database.
    static func resolve() -> SharedConfig {
        // Migrate legacy keychain on first run
        CredentialStore.migrateFromLegacy()

        let resolved = resolveAnthropicRaw()

        let credKind: CredentialKind = switch resolved[0].type {
        case .oauth: .oauth
        case .apiKey, .botToken: .apiKey
        }

        let configStore = ConfigStore(storagePath: defaultConfigPath)

        return SharedConfig(
            credentials: resolved.map { toClaudeCredential($0) },
            credentialNames: resolved.map(\.name),
            credentialKind: credKind,
            systemPrompt: AozoraDaemon.loadSystemPrompt(),
            databasePath: defaultDatabasePath,
            configStore: configStore,
        )
    }

    /// Resolve all Anthropic credentials from environment and Keychain.
    ///
    /// Resolution order:
    /// 1. `ANTHROPIC_API_KEY` environment variable (if set)
    /// 2. Keychain credentials sorted by priority (via ``CredentialStore``)
    /// 3. Fatal error if none found
    private static func resolveAnthropicRaw() -> [CredentialStore.Credential] {
        let resolved = CredentialStore.resolveAll(service: .anthropic)

        guard !resolved.isEmpty else {
            fatalError(
                "No Anthropic API key found. Add one with:\n"
                    + "  aozora credential add anthropic <name>\n"
                    + "Or set the ANTHROPIC_API_KEY environment variable.",
            )
        }

        // Log what we found
        let primary = resolved[0]
        let source = primary.isEnvironment ? "environment" : "keychain:\(primary.name)"
        print("  ├─ API key: \(source) (\(primary.type.rawValue))")
        if resolved.count > 1 {
            let names = resolved.dropFirst().map(\.name).joined(separator: ", ")
            print("  ├─ Fallbacks: \(names)")
        }

        return resolved
    }

    /// Convert a ``CredentialStore/Credential`` to the ``ClaudeCredential`` enum
    /// expected by ``AnthropicProvider``.
    private static func toClaudeCredential(_ cred: CredentialStore.Credential) -> ClaudeCredential {
        switch cred.type {
        case .oauth:
            .oauthToken(cred.secret, refresh: "", expiresAt: .distantFuture)
        case .apiKey, .botToken:
            .apiKey(cred.secret)
        }
    }
}
