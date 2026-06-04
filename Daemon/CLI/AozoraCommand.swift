import ArgumentParser

/// Root CLI entry point for the Aozora daemon and tools.
///
/// Running `aozora` with no subcommand launches the daemon (default).
/// Other subcommands provide utilities for testing, configuration, and diagnostics.
@main
struct AozoraCommand: AsyncParsableCommand {
    nonisolated static let configuration = CommandConfiguration(
        commandName: "aozora",
        abstract: "Aozora CIMS daemon and tools.",
        subcommands: [
            DaemonSubcommand.self,
            StatusSubcommand.self,
            TestAPISubcommand.self,
            TestCacheSubcommand.self,
            ConfigSubcommand.self,
            DumpContextSubcommand.self,
            AuthSubcommand.self,
            CredentialSubcommand.self,
        ],
        defaultSubcommand: DaemonSubcommand.self,
    )
}
