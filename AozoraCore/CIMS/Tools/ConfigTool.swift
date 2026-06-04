import Foundation

/// Read and modify Aozora runtime settings via ``ConfigStore``.
///
/// Supports three actions:
/// - `list` — show all settings with current values, defaults, and descriptions.
/// - `get <key>` — read a single setting.
/// - `set <key> <value>` — write a setting (validated by ``ConfigStore``).
///
/// The tool requires a ``ConfigStore`` instance, which is injected at registration
/// time by the daemon (since the daemon owns the config lifecycle).
public nonisolated struct ConfigTool: ToolExecutable {
    public let name = "config"

    private let configStore: ConfigStore

    public var definition: ToolDefinition {
        ToolDefinition(
            name: "config",
            description: """
            Read or modify Aozora runtime settings. \
            Actions: "list" shows all settings, "get <key>" reads one, "set <key> <value>" writes one.
            """,
            parameters: [
                ToolParameter(
                    name: "action",
                    type: .enum(["list", "get", "set"]),
                    description: "The action to perform",
                ),
                ToolParameter(
                    name: "key",
                    type: .string,
                    description: "Setting key (e.g., 'heartbeat.intervalMinutes')",
                    optional: true,
                ),
                ToolParameter(
                    name: "value",
                    type: .string,
                    description: "New value for the setting (required for 'set')",
                    optional: true,
                ),
            ],
        )
    }

    public init(configStore: ConfigStore) {
        self.configStore = configStore
    }

    public func execute(parameters: sending [String: Any], workingDirectory _: String) async throws -> ToolResult {
        let action = try requireString("action", from: parameters)

        switch action {
        case "list":
            return await listAll()

        case "get":
            let keyStr = try requireString("key", from: parameters)
            return await getValue(keyStr)

        case "set":
            let keyStr = try requireString("key", from: parameters)
            let value = try requireString("value", from: parameters)
            return await setValue(keyStr, value: value)

        default:
            return .failure("Unknown action '\(action)'. Use 'list', 'get', or 'set'.")
        }
    }

    // MARK: - Actions

    private func listAll() async -> ToolResult {
        var lines = ["Settings:"]
        for key in ConfigKey.allCases {
            let current = await configStore.get(key)
            let isDefault = current == key.defaultValue
            let marker = isDefault ? "" : " (custom)"
            lines.append("  \(key.rawValue) = \(current)\(marker)")
            lines.append("    \(key.description)")
        }
        return .success(lines.joined(separator: "\n"))
    }

    private func getValue(_ keyStr: String) async -> ToolResult {
        guard let key = ConfigKey(rawValue: keyStr) else {
            let available = ConfigKey.allCases.map(\.rawValue).joined(separator: ", ")
            return .failure("Unknown key '\(keyStr)'. Available: \(available)")
        }
        let value = await configStore.get(key)
        return .success("\(key.rawValue) = \(value)\nDescription: \(key.description)\nDefault: \(key.defaultValue)")
    }

    private func setValue(_ keyStr: String, value: String) async -> ToolResult {
        guard let key = ConfigKey(rawValue: keyStr) else {
            let available = ConfigKey.allCases.map(\.rawValue).joined(separator: ", ")
            return .failure("Unknown key '\(keyStr)'. Available: \(available)")
        }
        do {
            try await configStore.set(key, value: value)
            return .success("Set \(key.rawValue) = \(value)")
        } catch {
            return .failure("Failed to set \(key.rawValue): \(error)")
        }
    }
}
