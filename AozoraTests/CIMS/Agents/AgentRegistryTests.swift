import Foundation
import Testing
@testable import Aozora

struct AgentRegistryTests {
    @Test
    func `loads agent from definition`() {
        let def = AgentDefinition(
            name: "test",
            description: "Test agent",
            model: "claude-sonnet-4-6",
            systemPromptPath: nil,
            identityBlock: "default",
            tools: ["read", "grep"],
            channels: ["command:test"],
        )
        let registry = AgentRegistry(agents: [def])
        let agent = registry.resolve(channel: "command:test")
        #expect(agent?.name == "test")
    }

    @Test
    func `returns nil for unmatched channel`() {
        let registry = AgentRegistry(agents: [])
        let agent = registry.resolve(channel: "discord:12345")
        #expect(agent == nil)
    }

    @Test
    func `wildcard channel matches`() {
        let def = AgentDefinition(
            name: "main",
            description: "Main agent",
            model: nil,
            systemPromptPath: nil,
            identityBlock: "default",
            tools: ["*"],
            channels: ["discord:*"],
        )
        let registry = AgentRegistry(agents: [def])
        let agent = registry.resolve(channel: "discord:999")
        #expect(agent?.name == "main")
    }

    @Test
    func `looks up agent by name`() {
        let def = AgentDefinition(
            name: "researcher",
            description: "Research agent",
            model: "claude-sonnet-4-6",
            systemPromptPath: nil,
            identityBlock: "default",
            tools: ["read"],
            channels: ["command:researcher"],
        )
        let registry = AgentRegistry(agents: [def])
        #expect(registry.agent(named: "researcher")?.name == "researcher")
        #expect(registry.agent(named: "nonexistent") == nil)
    }

    @Test
    func `loads from directory of JSON files`() throws {
        let dir = NSTemporaryDirectory() + "agents-test-\(UUID().uuidString)"
        try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(atPath: dir) }

        let agentJSON = """
        {
            "name": "file-agent",
            "description": "Loaded from file",
            "model": "claude-sonnet-4-6",
            "systemPromptPath": null,
            "identityBlock": "default",
            "tools": ["*"],
            "channels": ["command:file-agent"]
        }
        """
        try agentJSON.write(toFile: dir + "/file-agent.json", atomically: true, encoding: .utf8)

        let registry = AgentRegistry(directory: dir)
        #expect(registry.allAgents.count == 1)
        #expect(registry.allAgents[0].name == "file-agent")
    }

    @Test
    func `AgentDefinition round-trips through JSON`() throws {
        let def = AgentDefinition(
            name: "test",
            description: "Test",
            model: "claude-opus-4-6",
            systemPromptPath: "~/.aozora/prompts/test.md",
            identityBlock: "default",
            tools: ["read", "write"],
            channels: ["discord:*", "command:test"],
        )
        let data = try JSONEncoder().encode(def)
        let decoded = try JSONDecoder().decode(AgentDefinition.self, from: data)
        #expect(decoded == def)
    }
}
