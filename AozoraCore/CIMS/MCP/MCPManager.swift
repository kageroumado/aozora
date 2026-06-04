import Foundation

/// Manages all MCP (Model Context Protocol) server connections.
///
/// Reads the server configuration from `~/.aozora/mcp.json`, starts each configured
/// server (via stdio or HTTP transport), performs initialization handshakes, and
/// registers discovered tools into the ``ToolRegistry``.
///
/// The config file format supports two transport types:
/// ```json
/// {
///   "mcpServers": {
///     "stdio-server": {
///       "command": "npx",
///       "args": ["-y", "@some/mcp-server"],
///       "env": { "API_KEY": "..." }
///     },
///     "http-server": {
///       "url": "https://mcp.example.com/mcp",
///       "headers": { "Authorization": "Bearer ..." }
///     }
///   }
/// }
/// ```
///
/// When `url` is present, the server uses HTTP transport (``MCPHTTPClient``).
/// When `command` is present, the server uses stdio transport (``MCPClient``).
///
/// Servers that fail to start are logged and skipped — partial availability is better
/// than total failure.
public actor MCPManager {
    /// Active stdio MCP clients keyed by server name.
    private var stdioClients: [String: MCPClient] = [:]

    /// Active HTTP MCP clients keyed by server name.
    private var httpClients: [String: MCPHTTPClient] = [:]

    /// Default config file path.
    static let defaultConfigPath = NSHomeDirectory() + "/.aozora/mcp.json"

    public init() {}

    /// Load the MCP config and start all configured servers.
    ///
    /// Creates the config directory and a default empty config if none exists.
    /// Detects transport type from the config: `url` → HTTP, `command` → stdio.
    /// Servers that fail to start are logged and skipped.
    ///
    /// - Parameter configPath: Path to the MCP config file. Defaults to `~/.aozora/mcp.json`.
    func loadAndStart(configPath: String = MCPManager.defaultConfigPath) async {
        ensureDefaultConfig(at: configPath)

        guard let data = FileManager.default.contents(atPath: configPath),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let servers = json["mcpServers"] as? [String: [String: Any]]
        else {
            print("[MCP] No servers configured in \(configPath)")
            return
        }

        if servers.isEmpty {
            print("[MCP] No servers configured")
            return
        }

        for (name, config) in servers {
            if let urlStr = config["url"] as? String, let url = URL(string: urlStr) {
                var headers = config["headers"] as? [String: String] ?? [:]

                // OAuth: use OAuthTokenStore for persistent, rotation-aware token management
                if let oauth = config["oauth"] as? [String: Any],
                   let clientId = oauth["clientId"] as? String,
                   let tokenURL = oauth["tokenURL"] as? String {
                    let token = await resolveOAuthToken(
                        name: name,
                        clientId: clientId,
                        tokenURL: tokenURL,
                        configRefreshToken: oauth["refreshToken"] as? String,
                        scope: oauth["scope"] as? String,
                    )
                    if let token {
                        headers["Authorization"] = "Bearer \(token)"
                    }
                }

                let client = MCPHTTPClient(name: name, url: url, headers: headers)
                do {
                    try await client.start()
                    httpClients[name] = client
                } catch {
                    print("[MCP] Failed to start HTTP server '\(name)': \(error)")
                }
            } else if let command = config["command"] as? String {
                let args = config["args"] as? [String] ?? []
                let env = config["env"] as? [String: String] ?? [:]
                let client = MCPClient(name: name, command: command, args: args, env: env)
                do {
                    try await client.start()
                    stdioClients[name] = client
                } catch {
                    print("[MCP] Failed to start stdio server '\(name)': \(error)")
                }
            } else {
                print("[MCP] Server '\(name)' has neither 'url' nor 'command', skipping")
            }
        }
    }

    /// Register all tools from all connected MCP servers in the given registry.
    ///
    /// Each tool is wrapped in an ``MCPToolBridge`` that prefixes the tool name with
    /// the server name to avoid collisions. Works with both stdio and HTTP clients.
    ///
    /// - Parameter registry: The tool registry to register MCP tools into.
    public func registerTools(in registry: ToolRegistry) async {
        for (serverName, client) in stdioClients {
            let tools = await client.listTools()
            for tool in tools {
                let bridge = MCPToolBridge(client: client, mcpTool: tool, serverName: serverName)
                await registry.register(bridge)
            }
        }

        for (serverName, client) in httpClients {
            let tools = await client.listTools()
            for tool in tools {
                let bridge = MCPToolBridge(httpClient: client, mcpTool: tool, serverName: serverName)
                await registry.register(bridge)
            }
        }
    }

    /// Stop all running MCP servers.
    ///
    /// Terminates stdio server processes and clears both client maps.
    public func stopAll() async {
        for (_, client) in stdioClients {
            await client.stop()
        }
        for (_, client) in httpClients {
            await client.stop()
        }
        stdioClients.removeAll()
        httpClients.removeAll()
    }

    // MARK: - OAuth Token Management

    /// Resolve a valid OAuth access token, using persistent storage with rotation.
    ///
    /// Tries, in order:
    /// 1. A cached token from ``OAuthTokenStore`` (may already be valid)
    /// 2. Refresh via ``OAuthClient`` (handles rotation — new refresh tokens are persisted)
    /// 3. The seed refresh token from `mcp.json` (first-run bootstrap)
    ///
    /// On success the token (and any rotated refresh token) is persisted for future
    /// daemon restarts. On failure, logs a clear message.
    private func resolveOAuthToken(
        name: String,
        clientId: String,
        tokenURL: String,
        configRefreshToken: String?,
        scope: String?,
    ) async -> String? {
        let store = OAuthTokenStore(service: name)
        let client = OAuthClient(config: OAuthClient.ServiceConfig(
            name: name,
            authorizeURL: "", // not needed for refresh-only flow
            tokenURL: tokenURL,
            clientID: clientId,
            scopes: scope ?? "",
        ))

        // 1. Try the persisted token (may still be valid or refreshable)
        do {
            if let token = try await store.validAccessToken(client: client) {
                print("[MCP/OAuth] \(name): using persisted token")
                return token
            }
        } catch {
            print("[MCP/OAuth] \(name): persisted token refresh failed — \(error)")
        }

        // 2. Seed from config refresh token (first run or after store was cleared)
        guard let seedRefresh = configRefreshToken else {
            print("[MCP/OAuth] \(name): no token available — re-authenticate with `aozora auth \(name)`")
            return nil
        }

        do {
            let response = try await client.refreshAccessToken(seedRefresh)
            try store.save(from: response)
            print("[MCP/OAuth] \(name): bootstrapped from config refresh token")
            return response.access_token
        } catch {
            print("[MCP/OAuth] \(name): config refresh token is invalid — re-authenticate with `aozora auth \(name)`")
            return nil
        }
    }

    // MARK: - Config Management

    /// Create a default empty config file if none exists.
    ///
    /// Ensures the `~/.aozora/` directory exists and writes a minimal config
    /// with an empty `mcpServers` object.
    ///
    /// - Parameter path: The config file path.
    private func ensureDefaultConfig(at path: String) {
        let dir = (path as NSString).deletingLastPathComponent
        try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)

        guard !FileManager.default.fileExists(atPath: path) else { return }

        let defaultConfig = """
        {
          "mcpServers": {}
        }
        """
        try? defaultConfig.write(toFile: path, atomically: true, encoding: .utf8)
        print("[MCP] Created default config at \(path)")
    }
}
