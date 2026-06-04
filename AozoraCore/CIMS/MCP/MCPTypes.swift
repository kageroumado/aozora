import Foundation

// MARK: - Tool Definition

/// A tool definition received from an MCP server's `tools/list` response.
///
/// Parsed from the JSON schema format that MCP servers expose. The ``inputSchema``
/// is converted to ``ToolParameter`` arrays for integration with the ``ToolRegistry``.
public struct MCPToolDefinition: Sendable {
    /// The tool name as declared by the MCP server.
    public let name: String

    /// Human-readable description of what the tool does.
    public let description: String

    /// Parsed parameter definitions from the tool's `inputSchema`.
    public let parameters: [ToolParameter]

    /// Parse a tool definition from the MCP `tools/list` response JSON.
    ///
    /// - Parameter json: A dictionary representing a single tool object from the response.
    /// - Returns: `nil` if the required `name` field is missing.
    init?(from json: [String: Any]) {
        guard let name = json["name"] as? String else { return nil }
        self.name = name
        self.description = json["description"] as? String ?? ""

        var params: [ToolParameter] = []
        if let schema = json["inputSchema"] as? [String: Any],
           let properties = schema["properties"] as? [String: [String: Any]] {
            let required = Set(schema["required"] as? [String] ?? [])
            for (propName, propSchema) in properties {
                let typeStr = propSchema["type"] as? String ?? "string"
                let desc = propSchema["description"] as? String ?? ""
                let paramType: ToolParameterType = switch typeStr {
                case "integer", "number": .integer
                case "array": .array(.string)
                default: .string
                }
                params.append(ToolParameter(
                    name: propName,
                    type: paramType,
                    description: desc,
                    optional: !required.contains(propName),
                ))
            }
        }
        self.parameters = params
    }
}

// MARK: - Error

/// An error returned by an MCP server in a JSON-RPC error response.
public struct MCPError: Error, Sendable {
    /// The JSON-RPC error code.
    public let code: Int

    /// Human-readable error message from the server.
    public let message: String
}
