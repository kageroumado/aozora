import Foundation

/// Bridges an MCP server tool into the ``ToolRegistry`` as a ``ToolExecutable``.
///
/// Each MCP tool is registered with a prefixed name (`serverName_toolName`) to avoid
/// collisions when multiple MCP servers expose tools with the same name. The description
/// is also prefixed with the server name for clarity in tool listings.
///
/// Works with both stdio (``MCPClient``) and HTTP (``MCPHTTPClient``) transports.
public nonisolated struct MCPToolBridge: ToolExecutable {
    /// The registry-unique tool name: `"serverName_toolName"`.
    public let name: String

    /// The tool definition sent to the model during inference.
    public let definition: ToolDefinition

    /// The original tool name as declared by the MCP server (without prefix).
    private let mcpToolName: String

    /// The transport backing this bridge.
    private let transport: Transport

    /// Transport discriminator — either a stdio or HTTP client reference.
    private enum Transport {
        case stdio(MCPClient)
        case http(MCPHTTPClient)
    }

    /// Create a bridge for an MCP tool backed by a stdio client.
    ///
    /// - Parameters:
    ///   - client: The stdio MCP client that owns this tool's server process.
    ///   - mcpTool: The tool definition from the server's `tools/list` response.
    ///   - serverName: The config key name of the server (used as prefix).
    public init(client: MCPClient, mcpTool: MCPToolDefinition, serverName: String) {
        self.name = "\(serverName)_\(mcpTool.name)"
        self.mcpToolName = mcpTool.name
        self.transport = .stdio(client)
        self.definition = ToolDefinition(
            name: name,
            description: "[\(serverName)] \(mcpTool.description)",
            parameters: mcpTool.parameters,
        )
    }

    /// Create a bridge for an MCP tool backed by an HTTP client.
    ///
    /// - Parameters:
    ///   - httpClient: The HTTP MCP client for this tool's server.
    ///   - mcpTool: The tool definition from the server's `tools/list` response.
    ///   - serverName: The config key name of the server (used as prefix).
    public init(httpClient: MCPHTTPClient, mcpTool: MCPToolDefinition, serverName: String) {
        self.name = "\(serverName)_\(mcpTool.name)"
        self.mcpToolName = mcpTool.name
        self.transport = .http(httpClient)
        self.definition = ToolDefinition(
            name: name,
            description: "[\(serverName)] \(mcpTool.description)",
            parameters: mcpTool.parameters,
        )
    }

    /// Execute the MCP tool by forwarding the call through the appropriate transport.
    ///
    /// - Parameters:
    ///   - parameters: Parsed JSON arguments from the model's tool call.
    ///   - workingDirectory: Unused — MCP servers manage their own working directory.
    /// - Returns: A ``ToolResult`` containing the text output from the MCP server.
    public func execute(parameters: sending [String: Any], workingDirectory _: String) async throws -> ToolResult {
        do {
            let result: String = switch transport {
            case let .stdio(client):
                try await client.callTool(name: mcpToolName, arguments: parameters)
            case let .http(client):
                try await client.callTool(name: mcpToolName, arguments: parameters)
            }
            return ToolResult(content: result, isError: false)
        } catch {
            return ToolResult(content: "MCP error: \(error)", isError: true)
        }
    }
}
