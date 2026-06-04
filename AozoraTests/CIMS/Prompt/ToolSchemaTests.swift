import Foundation
import Testing
@testable import Aozora

struct ToolSchemaTests {
    @Test
    func `Converts ToolDefinition with required string param`() throws {
        let def = ToolDefinition(
            name: "read_file",
            description: "Read a file",
            parameters: [
                ToolParameter(name: "path", type: .string, description: "File path"),
            ],
        )
        let schema = ToolSchema(from: def)
        #expect(schema.name == "read_file")
        #expect(schema.description == "Read a file")

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let data = try encoder.encode(schema)
        let parsed = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        let inputSchema = try #require(parsed["input_schema"] as? [String: Any])
        #expect(inputSchema["type"] as? String == "object")
        let props = try #require(inputSchema["properties"] as? [String: Any])
        let pathProp = try #require(props["path"] as? [String: Any])
        #expect(pathProp["type"] as? String == "string")
        let required = try #require(inputSchema["required"] as? [String])
        #expect(required == ["path"])
    }

    @Test
    func `Optional parameters not in required array`() throws {
        let def = ToolDefinition(
            name: "test",
            description: "Test",
            parameters: [
                ToolParameter(name: "a", type: .string, description: "required"),
                ToolParameter(name: "b", type: .integer, description: "optional", optional: true),
            ],
        )
        let schema = ToolSchema(from: def)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let data = try encoder.encode(schema)
        let parsed = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        let inputSchema = try #require(parsed["input_schema"] as? [String: Any])
        let required = try #require(inputSchema["required"] as? [String])
        #expect(required == ["a"])
    }

    @Test
    func `Handles enum and array parameter types`() throws {
        let def = ToolDefinition(
            name: "test",
            description: "Test",
            parameters: [
                ToolParameter(name: "mode", type: .enum(["fast", "slow"]), description: "Mode"),
                ToolParameter(name: "tags", type: .array(.string), description: "Tags"),
            ],
        )
        let schema = ToolSchema(from: def)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let data = try encoder.encode(schema)
        let parsed = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        let props = (parsed["input_schema"] as! [String: Any])["properties"] as! [String: Any]
        let mode = try #require(props["mode"] as? [String: Any])
        #expect(mode["type"] as? String == "string")
        #expect(mode["enum"] as? [String] == ["fast", "slow"])
        let tags = try #require(props["tags"] as? [String: Any])
        #expect(tags["type"] as? String == "array")
    }

    @Test
    func `No parameters produces empty properties and no required`() throws {
        let def = ToolDefinition(name: "noop", description: "No-op", parameters: [])
        let schema = ToolSchema(from: def)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let data = try encoder.encode(schema)
        let parsed = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        let inputSchema = try #require(parsed["input_schema"] as? [String: Any])
        #expect(inputSchema["required"] == nil)
    }
}
