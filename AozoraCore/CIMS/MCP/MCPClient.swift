import Foundation

/// Manages a single MCP (Model Context Protocol) server process.
///
/// Spawns the server as a child process communicating over stdin/stdout using
/// line-delimited JSON-RPC 2.0. Handles the MCP lifecycle: initialization handshake,
/// tool discovery via `tools/list`, and tool invocation via `tools/call`.
///
/// The actor isolates all mutable state — pending request continuations, the process
/// handle, and cached tool definitions. A detached reader task handles blocking I/O
/// on stdout without blocking the actor's executor.
public actor MCPClient {
    /// Display name for this server (from the config key).
    public let name: String

    /// The executable command to spawn (e.g., "npx", "node", "/usr/local/bin/server").
    private let command: String

    /// Arguments to pass to the command.
    private let args: [String]

    /// Additional environment variables for the server process.
    private let env: [String: String]

    /// The running server process, if started.
    private var process: Process?

    /// Write end of the process's stdin pipe.
    private var stdinHandle: FileHandle?

    /// Continuations waiting for JSON-RPC responses, keyed by request ID.
    private var pendingRequests: [Int: CheckedContinuation<Data, any Error>] = [:]

    /// Monotonically increasing request ID counter.
    private var nextRequestId: Int = 1

    /// Cached tool definitions from the last `tools/list` call.
    private var tools: [MCPToolDefinition] = []

    /// Whether the server process has been started and initialized.
    private var isRunning: Bool = false

    /// Background task running the stdout reader loop.
    private var readerTask: Task<Void, Never>?

    /// Create an MCP client for a server configuration.
    ///
    /// Does not start the process — call ``start()`` to spawn and initialize.
    ///
    /// - Parameters:
    ///   - name: Display name for logging (the config key).
    ///   - command: The executable to spawn.
    ///   - args: Command-line arguments.
    ///   - env: Additional environment variables merged with the current process environment.
    public init(name: String, command: String, args: [String], env: [String: String] = [:]) {
        self.name = name
        self.command = command
        self.args = args
        self.env = env
    }

    // MARK: - Lifecycle

    /// Spawn the server process, perform the MCP initialization handshake, and discover tools.
    ///
    /// After this method returns, tools are available via ``listTools()`` and ``callTool(name:arguments:)``.
    ///
    /// - Throws: If the process fails to launch, or the `initialize` / `tools/list` requests fail.
    public func start() async throws {
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        proc.arguments = [command] + args

        var environment = ProcessInfo.processInfo.environment
        for (key, value) in env {
            environment[key] = value
        }
        proc.environment = environment

        let stdinPipe = Pipe()
        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()
        proc.standardInput = stdinPipe
        proc.standardOutput = stdoutPipe
        proc.standardError = stderrPipe

        do {
            try proc.run()
        } catch {
            throw MCPError(code: -1, message: "Failed to launch MCP server '\(name)': \(error.localizedDescription)")
        }

        process = proc
        stdinHandle = stdinPipe.fileHandleForWriting
        isRunning = true

        startReadLoop(stdout: stdoutPipe.fileHandleForReading)

        let initResult = try await sendRequest(method: "initialize", params: [
            "protocolVersion": "2024-11-05",
            "capabilities": [String: Any](),
            "clientInfo": ["name": "aozora", "version": "0.1.0"],
        ])

        sendNotification(method: "notifications/initialized", params: [:])

        let toolsResult = try await sendRequest(method: "tools/list", params: [:])
        if let toolsArray = toolsResult["tools"] as? [[String: Any]] {
            tools = toolsArray.compactMap { MCPToolDefinition(from: $0) }
        }

        _ = initResult

        print("[MCP] \(name): \(tools.count) tools loaded")
    }

    /// Stop the server process and clean up resources.
    ///
    /// Cancels the reader task, terminates the process, and fails any pending requests.
    public func stop() {
        isRunning = false
        readerTask?.cancel()
        readerTask = nil

        stdinHandle?.closeFile()
        stdinHandle = nil

        if let proc = process, proc.isRunning {
            proc.terminate()
        }
        process = nil

        let pending = pendingRequests
        pendingRequests.removeAll()
        for (_, continuation) in pending {
            continuation.resume(throwing: MCPError(code: -1, message: "MCP server '\(name)' stopped"))
        }
    }

    // MARK: - Tool Access

    /// Get the cached tool definitions discovered during ``start()``.
    ///
    /// - Returns: All tools the server reported via `tools/list`.
    public func listTools() -> [MCPToolDefinition] {
        tools
    }

    /// Call a tool on the MCP server and return the text result.
    ///
    /// Sends a `tools/call` JSON-RPC request, waits for the response, and extracts
    /// text content blocks from the result.
    ///
    /// - Parameters:
    ///   - name: The tool name to invoke.
    ///   - arguments: Key-value arguments matching the tool's input schema.
    /// - Returns: Concatenated text content from the response.
    /// - Throws: ``MCPError`` if the server returns an error response, or if the request times out.
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

    // MARK: - JSON-RPC Transport

    /// Send a JSON-RPC request and wait for the matching response.
    ///
    /// Assigns a unique ID, serializes the request as JSON, writes it to stdin with
    /// a trailing newline, and suspends until the reader task delivers the response.
    ///
    /// - Parameters:
    ///   - method: The JSON-RPC method name.
    ///   - params: The request parameters.
    /// - Returns: The `result` dictionary from the JSON-RPC response.
    /// - Throws: ``MCPError`` if the response contains an `error` field, or serialization fails.
    private func sendRequest(method: String, params: [String: Any]) async throws -> [String: Any] {
        let id = nextRequestId
        nextRequestId += 1

        let request: [String: Any] = [
            "jsonrpc": "2.0",
            "id": id,
            "method": method,
            "params": params,
        ]

        guard let jsonData = try? JSONSerialization.data(withJSONObject: request) else {
            throw MCPError(code: -1, message: "Failed to serialize JSON-RPC request")
        }

        let responseData: Data = try await withCheckedThrowingContinuation { continuation in
            pendingRequests[id] = continuation
            var line = jsonData
            line.append(0x0A)
            stdinHandle?.write(line)
        }

        guard let json = try? JSONSerialization.jsonObject(with: responseData) as? [String: Any] else {
            throw MCPError(code: -1, message: "Invalid JSON in response")
        }

        if let error = json["error"] as? [String: Any] {
            throw MCPError(
                code: error["code"] as? Int ?? -1,
                message: error["message"] as? String ?? "Unknown MCP error",
            )
        }

        return json["result"] as? [String: Any] ?? [:]
    }

    /// Send a JSON-RPC notification (no `id`, no response expected).
    ///
    /// Used for the `notifications/initialized` message after the handshake.
    ///
    /// - Parameters:
    ///   - method: The notification method name.
    ///   - params: The notification parameters.
    private func sendNotification(method: String, params: [String: Any]) {
        let notification: [String: Any] = [
            "jsonrpc": "2.0",
            "method": method,
            "params": params,
        ]

        guard let jsonData = try? JSONSerialization.data(withJSONObject: notification) else { return }
        var line = jsonData
        line.append(0x0A)
        stdinHandle?.write(line)
    }

    // MARK: - Reader Loop

    /// Start the background stdout reader task.
    ///
    /// Runs in a detached task since it performs blocking I/O. Reads bytes from the
    /// server's stdout, buffers them, and splits on newlines. Each complete line is
    /// parsed as JSON — if it contains an `id` field, the corresponding pending
    /// continuation is resumed with the raw data.
    ///
    /// Follows the same pattern as ``IPCClient/readLoop(fd:continuation:)``.
    ///
    /// - Parameter stdout: The read end of the server process's stdout pipe.
    private func startReadLoop(stdout: FileHandle) {
        readerTask = Task.detached { [weak self] in
            var buffer = Data()
            let readBuf = UnsafeMutablePointer<UInt8>.allocate(capacity: 4_096)
            defer { readBuf.deallocate() }

            let fd = stdout.fileDescriptor

            while !Task.isCancelled {
                let bytesRead = Darwin.read(fd, readBuf, 4_096)
                if bytesRead <= 0 { break }

                buffer.append(readBuf, count: bytesRead)

                while let newlineIndex = buffer.firstIndex(of: 0x0A) {
                    let lineData = Data(buffer[buffer.startIndex ..< newlineIndex])
                    buffer = Data(buffer[buffer.index(after: newlineIndex)...])

                    guard let json = try? JSONSerialization.jsonObject(with: lineData) as? [String: Any],
                          let id = json["id"] as? Int
                    else {
                        continue
                    }

                    await self?.resumePending(id: id, data: lineData)
                }
            }

            await self?.handleProcessExit()
        }
    }

    /// Resume a pending request continuation with the response data.
    ///
    /// Called from the reader loop when a JSON-RPC response with a matching `id` arrives.
    ///
    /// - Parameters:
    ///   - id: The request ID from the response.
    ///   - data: The raw JSON response data.
    private func resumePending(id: Int, data: Data) {
        guard let continuation = pendingRequests.removeValue(forKey: id) else { return }
        continuation.resume(returning: data)
    }

    /// Handle unexpected process exit by failing all pending requests.
    private func handleProcessExit() {
        isRunning = false
        let pending = pendingRequests
        pendingRequests.removeAll()
        for (_, continuation) in pending {
            continuation.resume(throwing: MCPError(code: -1, message: "MCP server '\(name)' exited unexpectedly"))
        }
    }
}
