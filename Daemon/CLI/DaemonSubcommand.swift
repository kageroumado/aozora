import ArgumentParser

/// Launch the Aozora daemon — connects to Discord and runs the CIMS coordinator.
///
/// This is the default subcommand: running `aozora` with no arguments launches the daemon.
struct DaemonSubcommand: AsyncParsableCommand {
    nonisolated static let configuration = CommandConfiguration(
        commandName: "daemon",
        abstract: "Start the Aozora daemon.",
    )

    func run() async throws {
        try await AozoraDaemon.runDaemon()
    }
}
