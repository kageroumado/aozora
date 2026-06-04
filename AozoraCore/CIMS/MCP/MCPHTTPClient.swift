import Foundation

/// Manages a single MCP server over HTTP/SSE transport.
///
/// Communicates with the MCP server via HTTP POST requests using JSON-RPC 2.0.
/// Supports both regular JSON responses and SSE (Server-Sent Events) streaming
/// responses. Handles session tracking via the `Mcp-Session-Id` header.
///
/// This is the HTTP counterpart to ``MCPClient`` (which uses stdio transport).
/// Both expose the same logical interface: initialize, list tools, call tools.
public actor MCPHTTPClient {
    /// Display name for this server (from the config key).
    public let name: String

    /// The HTTP endpoint URL for the MCP server.
    private let url: URL

    /// Additional HTTP headers sent with every request.
    private let headers: [String: String]

    /// Cached tool definitions from the last `tools/list` call.
    private var tools: [MCPToolDefinition] = []

    /// Session ID returned by the server, sent back on subsequent requests.
    private var sessionId: String?

    /// Create an MCP HTTP client for a server configuration.
    ///
    /// Does not connect — call ``start()`` to perform initialization and tool discovery.
    ///
    /// - Parameters:
    ///   - name: Display name for logging (the config key).
    ///   - url: The MCP server's HTTP endpoint.
    ///   - headers: Additional HTTP headers (e.g., authorization tokens).
    public init(name: String, url: URL, headers: [String: String] = [:]) {
        self.name = name
        self.url = url
        self.headers = headers
    }

    // MARK: - Lifecycle

    /// Perform the MCP initialization handshake and discover tools.
    ///
    /// Sends `initialize`, `notifications/initialized`, and `tools/list` requests
    /// over HTTP. After this method returns, tools are available via ``listTools()``
    /// and ``callTool(name:arguments:)``.
    ///
    /// - Throws: ``MCPError`` if the server returns an error or the response is malformed.
    public func start() async throws {
        let initResult = try await sendRequest(method: "initialize", params: [
            "protocolVersion": "2024-11-05",
            "capabilities": [String: Any](),
            "clientInfo": ["name": "aozora", "version": "0.1.0"],
        ])
        _ = initResult

        _ = try? await sendNotification(method: "notifications/initialized", params: [:])

        let toolsResult = try await sendRequest(method: "tools/list", params: [:])
        if let toolsArray = toolsResult["tools"] as? [[String: Any]] {
            tools = toolsArray.compactMap { MCPToolDefinition(from: $0) }
        }

        print("[MCP/HTTP] \(name): \(tools.count) tools loaded")
    }

    /// No-op for HTTP transport — there is no persistent connection to tear down.
    public func stop() {}

    // MARK: - Tool Access

    /// Get the cached tool definitions discovered during ``start()``.
    ///
    /// - Returns: All tools the server reported via `tools/list`.
    public func listTools() -> [MCPToolDefinition] {
        tools
    }

    /// Call a tool on the MCP server and return the text result.
    ///
    /// Sends a `tools/call` JSON-RPC request over HTTP, waits for the response,
    /// and extracts text content blocks from the result.
    ///
    /// - Parameters:
    ///   - name: The tool name to invoke.
    ///   - arguments: Key-value arguments matching the tool's input schema.
    /// - Returns: Concatenated text content from the response.
    /// - Throws: ``MCPError`` if the server returns an error response.
    public func callTool(name: String, arguments: [String: Any]) async throws -> String {
        let result = try await sendRequest(method: "tools/call", params: [
            "name": name,
            "arguments": arguments,
        ])

        if let content = result["content"] as? [[String: Any]] {
            return content.compactMap { block in
                if block["type"] as? String == "text" { return block["text"] as? String }
                return nil
            }.joined(separator: "\n")
        }
        return ""
    }

    // MARK: - HTTP Transport

    /// Send a JSON-RPC request over HTTP POST and parse the response.
    ///
    /// Handles both regular JSON responses (`application/json`) and SSE responses
    /// (`text/event-stream`). For SSE, parses `data:` lines and extracts the last
    /// complete JSON-RPC response.
    ///
    /// Tracks session IDs via the `Mcp-Session-Id` response header — some servers
    /// use this for session affinity.
    ///
    /// - Parameters:
    ///   - method: The JSON-RPC method name.
    ///   - params: The request parameters.
    /// - Returns: The `result` dictionary from the JSON-RPC response.
    /// - Throws: ``MCPError`` if the response contains an `error` field, or the response is malformed.
    private func sendRequest(method: String, params: [String: Any]) async throws -> [String: Any] {
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json, text/event-stream", forHTTPHeaderField: "Accept")
        for (key, value) in headers {
            request.setValue(value, forHTTPHeaderField: key)
        }
        if let sessionId {
            request.setValue(sessionId, forHTTPHeaderField: "Mcp-Session-Id")
        }

        let body: [String: Any] = [
            "jsonrpc": "2.0",
            "id": UUID().uuidString,
            "method": method,
            "params": params,
        ]
        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (data, response) = try await URLSession.shared.data(for: request)

        if let httpResponse = response as? HTTPURLResponse,
           let newSessionId = httpResponse.value(forHTTPHeaderField: "Mcp-Session-Id") {
            sessionId = newSessionId
        }

        if let httpResponse = response as? HTTPURLResponse,
           let contentType = httpResponse.value(forHTTPHeaderField: "Content-Type"),
           contentType.contains("text/event-stream") {
            return try parseSSEResponse(data)
        }

        return try parseJSONResponse(data)
    }

    /// Send a JSON-RPC notification over HTTP POST.
    ///
    /// Notifications have no `id` and no response is expected beyond HTTP status.
    /// Used for `notifications/initialized` after the handshake.
    ///
    /// - Parameters:
    ///   - method: The notification method name.
    ///   - params: The notification parameters.
    private func sendNotification(method: String, params: [String: Any]) async throws {
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json, text/event-stream", forHTTPHeaderField: "Accept")
        for (key, value) in headers {
            request.setValue(value, forHTTPHeaderField: key)
        }
        if let sessionId {
            request.setValue(sessionId, forHTTPHeaderField: "Mcp-Session-Id")
        }

        let body: [String: Any] = [
            "jsonrpc": "2.0",
            "method": method,
            "params": params,
        ]
        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (_, response) = try await URLSession.shared.data(for: request)

        if let httpResponse = response as? HTTPURLResponse,
           let newSessionId = httpResponse.value(forHTTPHeaderField: "Mcp-Session-Id") {
            sessionId = newSessionId
        }
    }

    // MARK: - Response Parsing

    /// Parse an SSE (Server-Sent Events) response body.
    ///
    /// SSE format uses `data: ` prefixed lines separated by blank lines. We extract
    /// all `data:` lines, take the last complete JSON-RPC message, and return its
    /// `result` field.
    ///
    /// - Parameter data: The raw response body.
    /// - Returns: The `result` dictionary from the last JSON-RPC message.
    /// - Throws: ``MCPError`` if no valid JSON-RPC data is found, or the response contains an error.
    private func parseSSEResponse(_ data: Data) throws -> [String: Any] {
        let text = String(data: data, encoding: .utf8) ?? ""
        let dataLines = text.components(separatedBy: "\n")
            .filter { $0.hasPrefix("data: ") || $0.hasPrefix("data:") }
            .map { line -> String in
                if line.hasPrefix("data: ") {
                    return String(line.dropFirst(6))
                }
                return String(line.dropFirst(5))
            }

        if let lastData = dataLines.last,
           let jsonData = lastData.data(using: .utf8),
           let json = try? JSONSerialization.jsonObject(with: jsonData) as? [String: Any] {
            if let error = json["error"] as? [String: Any] {
                throw MCPError(
                    code: error["code"] as? Int ?? -1,
                    message: error["message"] as? String ?? "Unknown MCP error",
                )
            }
            return json["result"] as? [String: Any] ?? [:]
        }

        throw MCPError(code: -1, message: "No valid JSON-RPC data in SSE response")
    }

    /// Parse a regular JSON response body.
    ///
    /// - Parameter data: The raw response body.
    /// - Returns: The `result` dictionary from the JSON-RPC response.
    /// - Throws: ``MCPError`` if the JSON is invalid or the response contains an error.
    private func parseJSONResponse(_ data: Data) throws -> [String: Any] {
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw MCPError(code: -1, message: "Invalid JSON in HTTP response")
        }

        if let error = json["error"] as? [String: Any] {
            throw MCPError(
                code: error["code"] as? Int ?? -1,
                message: error["message"] as? String ?? "Unknown MCP error",
            )
        }

        return json["result"] as? [String: Any] ?? [:]
    }
}
