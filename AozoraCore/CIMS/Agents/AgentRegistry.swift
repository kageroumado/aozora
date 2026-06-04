import Foundation

/// Discovers and resolves named agent configurations.
///
/// Loads agent definitions from JSON files in the configured agents directory
/// (`~/.aozora/agents/` by default). Resolves which agent handles an inbound
/// message based on channel pattern matching.
///
/// Falls back to `nil` if no agent's channel patterns match the input channel.
public nonisolated struct AgentRegistry: Sendable {
    /// The loaded agent definitions.
    private let agents: [AgentDefinition]

    /// Create a registry from an array of pre-built definitions.
    ///
    /// - Parameter agents: The agent definitions to register.
    public init(agents: [AgentDefinition]) {
        self.agents = agents
    }

    /// Load agent definitions from a directory of JSON files.
    ///
    /// Each file should contain a single ``AgentDefinition`` JSON object.
    /// Files that fail to parse are skipped with a warning.
    ///
    /// - Parameter directory: Absolute path to the directory containing agent JSON files.
    public init(directory: String) {
        var defs: [AgentDefinition] = []
        let fm = FileManager.default
        guard let files = try? fm.contentsOfDirectory(atPath: directory) else {
            self.agents = []
            return
        }
        for file in files where file.hasSuffix(".json") {
            let path = (directory as NSString).appendingPathComponent(file)
            guard let data = fm.contents(atPath: path),
                  let def = try? JSONDecoder().decode(AgentDefinition.self, from: data) else {
                continue
            }
            defs.append(def)
        }
        self.agents = defs
    }

    /// Resolve which agent handles a given channel.
    ///
    /// Channel patterns support:
    /// - Exact match: `"command:researcher"` matches only `"command:researcher"`
    /// - Wildcard suffix: `"discord:*"` matches any channel starting with `"discord:"`
    ///
    /// Returns the first matching agent, or `nil` if no patterns match.
    ///
    /// - Parameter channel: The channel identifier to match against agent patterns.
    /// - Returns: The first agent whose channel patterns match, or `nil`.
    public func resolve(channel: String) -> AgentDefinition? {
        for agent in agents {
            for pattern in agent.channels {
                if pattern == channel { return agent }
                if pattern.hasSuffix("*") {
                    let prefix = String(pattern.dropLast())
                    if channel.hasPrefix(prefix) { return agent }
                }
            }
        }
        return nil
    }

    /// All registered agent definitions.
    public var allAgents: [AgentDefinition] {
        agents
    }

    /// Look up an agent by name.
    ///
    /// - Parameter name: The unique agent name to search for.
    /// - Returns: The matching agent definition, or `nil` if not found.
    public func agent(named name: String) -> AgentDefinition? {
        agents.first { $0.name == name }
    }
}
