import ArgumentParser
import Foundation

/// Inspect and modify CIMS configuration.
///
/// Settings are persisted to `~/.aozora/config.json` and take effect
/// on next daemon restart. Use `config show` to see all current values.
struct ConfigSubcommand: AsyncParsableCommand {
    nonisolated static let configuration = CommandConfiguration(
        commandName: "config",
        abstract: "Show or modify configuration.",
        subcommands: [Show.self, Set.self, Reset.self],
        defaultSubcommand: Show.self,
    )

    /// Display all configuration values with their defaults and overrides.
    struct Show: AsyncParsableCommand {
        nonisolated static let configuration = CommandConfiguration(abstract: "Show all config values.")

        @Argument(help: "Optional key to show a single value.")
        var key: String?

        func run() async throws {
            let store = ConfigStore(storagePath: AozoraDaemon.configPath)

            if let key {
                let value = await store.getRaw(key)
                print("\(key) = \(value ?? "(not set)")")
            } else {
                print("Configuration (~/.aozora/config.json):\n")
                let all = await store.all()
                for configKey in ConfigKey.allCases {
                    let value = all[configKey.rawValue] ?? configKey.defaultValue
                    let isDefault = value == configKey.defaultValue
                    let marker = isDefault ? "  " : "* "
                    print("  \(marker)\(configKey.rawValue) = \(value)")
                    print("      \(configKey.description)")
                }
            }
        }
    }

    /// Set a configuration value.
    struct Set: AsyncParsableCommand {
        nonisolated static let configuration = CommandConfiguration(abstract: "Set a config value.")

        @Argument(help: "Config key (e.g. context.budget).")
        var key: String

        @Argument(help: "Value to set.")
        var value: String

        func run() async throws {
            let store = ConfigStore(storagePath: AozoraDaemon.configPath)
            do {
                try await store.setRaw(key, value: value)
                print("Set \(key) = \(value)")
            } catch {
                print("Error: \(error)")
                throw ExitCode.failure
            }
        }
    }

    /// Reset a configuration value to its default.
    struct Reset: AsyncParsableCommand {
        nonisolated static let configuration = CommandConfiguration(abstract: "Reset a config value to default.")

        @Argument(help: "Config key to reset.")
        var key: String

        func run() async throws {
            let store = ConfigStore(storagePath: AozoraDaemon.configPath)
            await store.reset(key)
            if let configKey = ConfigKey(rawValue: key) {
                print("Reset \(key) to default: \(configKey.defaultValue)")
            } else {
                print("Removed \(key)")
            }
        }
    }
}
