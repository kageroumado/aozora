import Foundation

/// JSON-RPC 2.0 client for communicating with Language Server Protocol servers over stdio.
///
/// Manages the lifecycle of a language server process, sending requests and notifications
/// through stdin and reading responses from stdout using the LSP base protocol framing
/// (`Content-Length` headers).
///
/// Each client instance owns exactly one server process. Multiple files of the same language
/// within a workspace share a single client via ``LspServerRegistry``.
///
/// The read loop runs as a detached background task, parsing incoming messages and resuming
/// pending request continuations by matching on the JSON-RPC `id` field.
public actor LspClient {
    /// The underlying language server process.
    private let process: Process

    /// Pipe connected to the server's stdin (we write requests here).
    private let stdinPipe: Pipe

    /// Pipe connected to the server's stdout (we read responses here).
    private let stdoutPipe: Pipe

    /// Monotonically increasing request ID counter.
    private var nextId = 1

    /// Pending request continuations keyed by their JSON-RPC `id`.
    private var pendingRequests: [Int: CheckedContinuation<[String: Any], any Error>] = [:]

    /// Background task running the stdout read loop.
    private var readTask: Task<Void, Never>?

    /// Whether the client has been initialized and is ready for requests.
    private var isStarted = false

    /// The root URI of the workspace this client was initialized with.
    private var rootUri: String?

    /// Latest diagnostics per file URI, updated by `textDocument/publishDiagnostics` notifications.
    private var diagnosticsStore: [String: [LspDiagnostic]] = [:]

    /// Continuations waiting for diagnostics on a specific file URI, keyed by a unique waiter ID.
    private var diagnosticWaiters: [String: [Int: CheckedContinuation<[LspDiagnostic], Never>]] = [:]

    /// Monotonically increasing waiter ID counter.
    private var nextWaiterId = 0

    /// File URIs that have been opened via `textDocument/didOpen`.
    private var openDocuments: Set<String> = []

    /// Create an LSP client for the given server command.
    ///
    /// The process is configured but not started — call ``start(rootUri:)`` to launch the
    /// server and perform the LSP initialization handshake.
    ///
    /// - Parameters:
    ///   - command: Absolute path to the language server executable.
    ///   - arguments: Command-line arguments for the server.
    ///   - workingDirectory: Working directory for the server process.
    public init(command: String, arguments: [String], workingDirectory: String) {
        self.process = Process()
        self.stdinPipe = Pipe()
        self.stdoutPipe = Pipe()

        process.executableURL = URL(fileURLWithPath: command)
        process.arguments = arguments
        process.currentDirectoryURL = URL(fileURLWithPath: workingDirectory)
        process.standardInput = stdinPipe
        process.standardOutput = stdoutPipe
        process.standardError = FileHandle.nullDevice
    }

    /// Launch the server process and perform the LSP initialization handshake.
    ///
    /// Sends `initialize` with the given root URI, waits for the server's capabilities
    /// response, then sends the `initialized` notification. After this method returns,
    /// the client is ready to accept document queries.
    ///
    /// - Parameter rootUri: The workspace root URI (e.g., `file:///path/to/project`).
    /// - Throws: If the process fails to launch or the initialize handshake fails.
    public func start(rootUri: String) async throws {
        guard !isStarted else { return }

        self.rootUri = rootUri

        do {
            try process.run()
        } catch {
            throw LspError.serverLaunchFailed(String(describing: error))
        }

        // Start the background read loop
        let handle = stdoutPipe.fileHandleForReading
        readTask = Task.detached { [weak self] in
            await self?.readLoop(handle: handle)
        }

        // Send initialize request
        let initParams: [String: Any] = [
            "processId": ProcessInfo.processInfo.processIdentifier,
            "rootUri": rootUri,
            "capabilities": [String: Any](),
        ]

        _ = try await sendRequest(method: "initialize", params: initParams)

        // Send initialized notification
        sendNotification(method: "initialized", params: [:])

        isStarted = true
    }

    // MARK: - LSP Methods

    /// Query hover information at a position in a document.
    ///
    /// - Parameters:
    ///   - file: Absolute file path.
    ///   - line: Zero-indexed line number.
    ///   - character: Zero-indexed character offset.
    /// - Returns: The hover text, or `nil` if no hover info is available at that position.
    /// - Throws: ``LspError`` if the request fails or the server is not started.
    public func hover(file: String, line: Int, character: Int) async throws -> String? {
        try checkStarted()

        let params = positionParams(file: file, line: line, character: character)
        let result = try await sendRequest(method: "textDocument/hover", params: params)

        guard let resultObj = result["result"] else { return nil }
        if resultObj is NSNull { return nil }

        guard let hoverDict = resultObj as? [String: Any],
              let contents = hoverDict["contents"]
        else { return nil }

        if let hover = HoverContents.decode(from: contents) {
            return hover.displayText
        }

        return nil
    }

    /// Find the definition location(s) for a symbol at the given position.
    ///
    /// - Parameters:
    ///   - file: Absolute file path.
    ///   - line: Zero-indexed line number.
    ///   - character: Zero-indexed character offset.
    /// - Returns: An array of definition locations (usually one, but can be multiple for overloads).
    /// - Throws: ``LspError`` if the request fails or the server is not started.
    public func definition(file: String, line: Int, character: Int) async throws -> [LspLocation] {
        try checkStarted()

        let params = positionParams(file: file, line: line, character: character)
        let result = try await sendRequest(method: "textDocument/definition", params: params)

        return parseLocations(from: result["result"])
    }

    /// Find all references to the symbol at the given position.
    ///
    /// - Parameters:
    ///   - file: Absolute file path.
    ///   - line: Zero-indexed line number.
    ///   - character: Zero-indexed character offset.
    /// - Returns: An array of reference locations throughout the workspace.
    /// - Throws: ``LspError`` if the request fails or the server is not started.
    public func references(file: String, line: Int, character: Int) async throws -> [LspLocation] {
        try checkStarted()

        var params = positionParams(file: file, line: line, character: character)
        params["context"] = ["includeDeclaration": true] as [String: Any]
        let result = try await sendRequest(method: "textDocument/references", params: params)

        return parseLocations(from: result["result"])
    }

    /// Get the document symbols (outline) for a file.
    ///
    /// Returns either hierarchical ``DocumentSymbol`` entries (preferred by modern servers)
    /// or flat ``SymbolInformation`` entries converted to `DocumentSymbol`.
    ///
    /// - Parameter file: Absolute file path.
    /// - Returns: An array of document symbols.
    /// - Throws: ``LspError`` if the request fails or the server is not started.
    public func documentSymbols(file: String) async throws -> [DocumentSymbol] {
        try checkStarted()

        let params: [String: Any] = [
            "textDocument": ["uri": fileUri(file)] as [String: Any],
        ]
        let result = try await sendRequest(method: "textDocument/documentSymbol", params: params)

        guard let resultVal = result["result"] else { return [] }
        if resultVal is NSNull { return [] }

        guard let arr = resultVal as? [[String: Any]] else { return [] }

        // Try hierarchical DocumentSymbol first, fall back to SymbolInformation
        return arr.compactMap { parseDocumentSymbol($0) }
    }

    /// Gracefully shut down the language server.
    ///
    /// Sends the `shutdown` request, waits for acknowledgement, then sends `exit`.
    /// Terminates the process if it doesn't exit within a reasonable time.
    public func shutdown() async {
        guard isStarted else {
            process.terminate()
            return
        }

        isStarted = false

        // Send shutdown request (best-effort)
        do {
            _ = try await sendRequest(method: "shutdown", params: [:])
        } catch {
            // Server may have already crashed
        }

        // Send exit notification
        sendNotification(method: "exit", params: nil)

        // Give the process a moment to exit, then force-terminate
        readTask?.cancel()
        readTask = nil

        if process.isRunning {
            process.terminate()
        }

        // Resume any remaining pending requests with cancellation
        for (_, continuation) in pendingRequests {
            continuation.resume(throwing: LspError.serverShutdown)
        }
        pendingRequests.removeAll()
    }

    // MARK: - Document Synchronization

    /// Notify the server that a document has been opened.
    ///
    /// The server needs `didOpen` before it can track a document. If the document
    /// was already opened, this is a no-op.
    ///
    /// - Parameter file: Absolute path to the file.
    public func sendDidOpen(file: String) {
        let uri = fileUri(file)
        guard !openDocuments.contains(uri) else { return }

        guard let text = try? String(contentsOfFile: file, encoding: .utf8) else { return }

        let ext = (file as NSString).pathExtension.lowercased()
        let languageId = Self.languageIdForExtension(ext)

        openDocuments.insert(uri)
        sendNotification(method: "textDocument/didOpen", params: [
            "textDocument": [
                "uri": uri,
                "languageId": languageId,
                "version": 1,
                "text": text,
            ] as [String: Any],
        ])
    }

    /// Notify the server that a document has been saved.
    ///
    /// Clears any stale diagnostics for the file, then triggers the server to re-analyze
    /// and publish fresh diagnostics. Automatically sends `didOpen` first if the document
    /// hasn't been opened yet.
    ///
    /// - Parameter file: Absolute path to the saved file.
    public func sendDidSave(file: String) {
        let uri = fileUri(file)
        if !openDocuments.contains(uri) {
            sendDidOpen(file: file)
        }

        diagnosticsStore.removeValue(forKey: uri)

        let text = try? String(contentsOfFile: file, encoding: .utf8)
        var params: [String: Any] = [
            "textDocument": ["uri": uri] as [String: Any],
        ]
        if let text {
            params["text"] = text
        }
        sendNotification(method: "textDocument/didSave", params: params)
    }

    /// Wait for diagnostics for a specific file, with a timeout.
    ///
    /// If diagnostics are already available in the store (from a previous `publishDiagnostics`
    /// notification), they are returned immediately. Otherwise, this method suspends until
    /// the server publishes diagnostics for the file or the timeout expires.
    ///
    /// - Parameters:
    ///   - file: Absolute path to the file.
    ///   - timeout: Maximum time to wait for diagnostics, in seconds.
    /// - Returns: The diagnostics for the file, or an empty array on timeout.
    public func diagnostics(for file: String, timeout: TimeInterval = 5.0) async -> [LspDiagnostic] {
        let uri = fileUri(file)

        if let existing = diagnosticsStore[uri] {
            return existing
        }

        let waiterId = nextWaiterId
        nextWaiterId += 1

        return await withCheckedContinuation { continuation in
            diagnosticWaiters[uri, default: [:]][waiterId] = continuation

            Task.detached { [weak self] in
                try? await Task.sleep(for: .seconds(timeout))
                await self?.cancelDiagnosticWaiter(for: uri, waiterId: waiterId)
            }
        }
    }

    /// Cancel a diagnostic waiter that has timed out.
    ///
    /// Removes the continuation from the waiters dictionary and resumes it with an empty
    /// array if it's still pending.
    ///
    /// - Parameters:
    ///   - uri: The file URI the continuation was waiting on.
    ///   - waiterId: The unique ID of the waiter to cancel.
    private func cancelDiagnosticWaiter(for uri: String, waiterId: Int) {
        guard let continuation = diagnosticWaiters[uri]?.removeValue(forKey: waiterId) else { return }
        if diagnosticWaiters[uri]?.isEmpty == true {
            diagnosticWaiters.removeValue(forKey: uri)
        }
        continuation.resume(returning: [])
    }

    /// Map file extension to LSP language identifier.
    ///
    /// - Parameter ext: Lowercase file extension without the dot.
    /// - Returns: The LSP language identifier string.
    private static func languageIdForExtension(_ ext: String) -> String {
        switch ext {
        case "swift": "swift"
        case "py": "python"
        case "ts": "typescript"
        case "tsx": "typescriptreact"
        case "js": "javascript"
        case "jsx": "javascriptreact"
        case "go": "go"
        case "rs": "rust"
        case "c": "c"
        case "cpp": "cpp"
        case "h": "c"
        default: ext
        }
    }

    // MARK: - JSON-RPC Transport

    /// Send a JSON-RPC request and wait for the response.
    ///
    /// Assigns a unique `id`, writes the message with `Content-Length` framing to the
    /// server's stdin, and suspends until the read loop matches the response by `id`.
    ///
    /// - Parameters:
    ///   - method: The LSP method name (e.g., `"textDocument/hover"`).
    ///   - params: The request parameters as a JSON-compatible dictionary.
    /// - Returns: The full JSON-RPC response as a dictionary.
    /// - Throws: ``LspError`` if serialization fails or the server returns an error.
    private func sendRequest(method: String, params: [String: Any]) async throws -> [String: Any] {
        let id = nextId
        nextId += 1

        let message: [String: Any] = [
            "jsonrpc": "2.0",
            "id": id,
            "method": method,
            "params": params,
        ]

        let data = try encodeMessage(message)

        return try await withCheckedThrowingContinuation { continuation in
            pendingRequests[id] = continuation

            let handle = stdinPipe.fileHandleForWriting
            handle.write(data)
        }
    }

    /// Send a JSON-RPC notification (no `id`, no response expected).
    ///
    /// - Parameters:
    ///   - method: The LSP method name.
    ///   - params: Optional notification parameters.
    private func sendNotification(method: String, params: [String: Any]?) {
        var message: [String: Any] = [
            "jsonrpc": "2.0",
            "method": method,
        ]
        if let params {
            message["params"] = params
        }

        guard let data = try? encodeMessage(message) else { return }

        let handle = stdinPipe.fileHandleForWriting
        handle.write(data)
    }

    /// Encode a JSON-RPC message with `Content-Length` header framing.
    ///
    /// Format: `Content-Length: <N>\r\n\r\n<json-body>`
    ///
    /// - Parameter message: The JSON-RPC message as a dictionary.
    /// - Returns: The framed message data ready to write to the pipe.
    /// - Throws: If JSON serialization fails.
    private func encodeMessage(_ message: [String: Any]) throws -> Data {
        let json = try JSONSerialization.data(withJSONObject: message)
        let header = "Content-Length: \(json.count)\r\n\r\n"
        guard let headerData = header.data(using: .utf8) else {
            throw LspError.encodingFailed
        }
        return headerData + json
    }

    /// Background read loop that parses LSP-framed messages from the server's stdout.
    ///
    /// Reads `Content-Length` headers, then the corresponding JSON body. For responses
    /// (messages with an `id`), resumes the matching pending continuation. Notifications
    /// from the server are silently discarded.
    ///
    /// - Parameter handle: The file handle connected to the server's stdout.
    private func readLoop(handle: FileHandle) async {
        while !Task.isCancelled {
            do {
                // Read headers until empty line
                let contentLength = try readContentLength(from: handle)
                guard contentLength > 0 else { continue }

                // Read exactly contentLength bytes
                let bodyData = try readExactly(contentLength, from: handle)

                guard let response = try JSONSerialization.jsonObject(with: bodyData) as? [String: Any] else {
                    continue
                }

                if let id = response["id"] as? Int,
                   let continuation = pendingRequests.removeValue(forKey: id) {
                    if let errorDict = response["error"] as? [String: Any],
                       let error = JsonRpcError.decode(from: errorDict) {
                        continuation.resume(throwing: LspError.serverError(error.code, error.message))
                    } else {
                        // Re-serialize to create a fresh value that can be safely sent
                        // across isolation boundaries (JSONSerialization returns reference types).
                        let resultData = try JSONSerialization.data(withJSONObject: response)
                        let freshResponse = try JSONSerialization.jsonObject(with: resultData) as! [String: Any]
                        continuation.resume(returning: freshResponse)
                    }
                } else if let method = response["method"] as? String {
                    handleServerNotification(method: method, params: response["params"])
                }
            } catch {
                if Task.isCancelled { break }
                // If the pipe is broken (server crashed), break out
                break
            }
        }

        // Resume any remaining pending requests due to read loop exit
        for (_, continuation) in pendingRequests {
            continuation.resume(throwing: LspError.serverCrashed)
        }
        pendingRequests.removeAll()
    }

    /// Handle a server-initiated notification.
    ///
    /// Dispatches to specialized handlers based on the notification method.
    /// Currently supports `textDocument/publishDiagnostics`.
    ///
    /// - Parameters:
    ///   - method: The LSP notification method name.
    ///   - params: The notification parameters (raw JSON).
    private func handleServerNotification(method: String, params: Any?) {
        switch method {
        case "textDocument/publishDiagnostics":
            handlePublishDiagnostics(params: params)
        default:
            break
        }
    }

    /// Process a `textDocument/publishDiagnostics` notification.
    ///
    /// Stores the diagnostics and resumes any continuations waiting for diagnostics
    /// on the affected file.
    ///
    /// - Parameter params: The raw JSON params from the notification.
    private func handlePublishDiagnostics(params: Any?) {
        guard let dict = params as? [String: Any],
              let uri = dict["uri"] as? String,
              let rawDiagnostics = dict["diagnostics"] as? [[String: Any]]
        else { return }

        let parsed = rawDiagnostics.compactMap { LspDiagnostic.decode(from: $0) }
        diagnosticsStore[uri] = parsed

        if let waiters = diagnosticWaiters.removeValue(forKey: uri) {
            for (_, waiter) in waiters {
                waiter.resume(returning: parsed)
            }
        }
    }

    /// Read `Content-Length` from LSP header lines.
    ///
    /// Reads lines from the handle until an empty line (`\r\n`) is encountered,
    /// parsing the `Content-Length` header value.
    ///
    /// - Parameter handle: The file handle to read from.
    /// - Returns: The content length value.
    /// - Throws: ``LspError/invalidHeader`` if no valid Content-Length is found.
    private nonisolated func readContentLength(from handle: FileHandle) throws -> Int {
        var contentLength = 0
        var headerBuffer = Data()

        // Read byte-by-byte until we see \r\n\r\n
        while true {
            let byte = handle.readData(ofLength: 1)
            if byte.isEmpty {
                throw LspError.serverCrashed
            }
            headerBuffer.append(byte)

            // Check for \r\n\r\n end-of-headers marker
            if headerBuffer.count >= 4 {
                let tail = headerBuffer.suffix(4)
                if tail == Data([0x0D, 0x0A, 0x0D, 0x0A]) {
                    break
                }
            }
        }

        guard let headerString = String(data: headerBuffer, encoding: .utf8) else {
            throw LspError.invalidHeader
        }

        // Parse headers
        let lines = headerString.components(separatedBy: "\r\n")
        for line in lines {
            if line.lowercased().hasPrefix("content-length:") {
                let valueStr = line.dropFirst("content-length:".count).trimmingCharacters(in: .whitespaces)
                if let value = Int(valueStr) {
                    contentLength = value
                }
            }
        }

        if contentLength == 0 {
            throw LspError.invalidHeader
        }

        return contentLength
    }

    /// Read exactly `count` bytes from a file handle.
    ///
    /// - Parameters:
    ///   - count: The number of bytes to read.
    ///   - handle: The file handle to read from.
    /// - Returns: The read data.
    /// - Throws: ``LspError/serverCrashed`` if the handle returns fewer bytes than expected.
    private nonisolated func readExactly(_ count: Int, from handle: FileHandle) throws -> Data {
        var buffer = Data()
        buffer.reserveCapacity(count)

        while buffer.count < count {
            let chunk = handle.readData(ofLength: count - buffer.count)
            if chunk.isEmpty {
                throw LspError.serverCrashed
            }
            buffer.append(chunk)
        }

        return buffer
    }

    // MARK: - Helpers

    /// Verify the client is started before sending requests.
    ///
    /// - Throws: ``LspError/notStarted`` if ``start(rootUri:)`` has not been called.
    private func checkStarted() throws {
        guard isStarted else {
            throw LspError.notStarted
        }
    }

    /// Build `textDocument/position` params dictionary for a file and position.
    ///
    /// - Parameters:
    ///   - file: Absolute file path.
    ///   - line: Zero-indexed line number.
    ///   - character: Zero-indexed character offset.
    /// - Returns: JSON-compatible parameter dictionary.
    private func positionParams(file: String, line: Int, character: Int) -> [String: Any] {
        [
            "textDocument": ["uri": fileUri(file)] as [String: Any],
            "position": ["line": line, "character": character] as [String: Any],
        ]
    }

    /// Convert an absolute file path to a `file://` URI.
    ///
    /// - Parameter path: Absolute file path.
    /// - Returns: The `file://` URI string.
    private func fileUri(_ path: String) -> String {
        "file://" + path
    }

    /// Parse location(s) from a JSON-RPC result that may be a single location,
    /// an array of locations, or null.
    ///
    /// - Parameter result: The raw `result` field from the JSON-RPC response.
    /// - Returns: An array of ``LspLocation`` values.
    private func parseLocations(from result: Any?) -> [LspLocation] {
        guard let result, !(result is NSNull) else { return [] }

        // Single location
        if let dict = result as? [String: Any] {
            if let loc = parseLocation(dict) {
                return [loc]
            }
        }

        // Array of locations
        if let arr = result as? [[String: Any]] {
            return arr.compactMap { parseLocation($0) }
        }

        return []
    }

    /// Parse a single ``LspLocation`` from a JSON dictionary.
    ///
    /// - Parameter dict: Dictionary with `uri` and `range` keys.
    /// - Returns: The parsed location, or `nil` if required keys are missing.
    private func parseLocation(_ dict: [String: Any]) -> LspLocation? {
        guard let uri = dict["uri"] as? String,
              let rangeDict = dict["range"] as? [String: Any],
              let range = parseRange(rangeDict)
        else { return nil }
        return LspLocation(uri: uri, range: range)
    }

    /// Parse an ``LspRange`` from a JSON dictionary.
    ///
    /// - Parameter dict: Dictionary with `start` and `end` position objects.
    /// - Returns: The parsed range, or `nil` if required keys are missing.
    private func parseRange(_ dict: [String: Any]) -> LspRange? {
        guard let startDict = dict["start"] as? [String: Any],
              let endDict = dict["end"] as? [String: Any],
              let start = parsePosition(startDict),
              let end = parsePosition(endDict)
        else { return nil }
        return LspRange(start: start, end: end)
    }

    /// Parse an ``LspPosition`` from a JSON dictionary.
    ///
    /// - Parameter dict: Dictionary with `line` and `character` integer values.
    /// - Returns: The parsed position, or `nil` if required keys are missing.
    private func parsePosition(_ dict: [String: Any]) -> LspPosition? {
        guard let line = dict["line"] as? Int,
              let character = dict["character"] as? Int
        else { return nil }
        return LspPosition(line: line, character: character)
    }

    /// Parse a ``DocumentSymbol`` from a JSON dictionary.
    ///
    /// Handles both hierarchical `DocumentSymbol` and flat `SymbolInformation` shapes.
    /// For `SymbolInformation`, the location's range is used for both `range` and
    /// `selectionRange`.
    ///
    /// - Parameter dict: The raw symbol dictionary from the server.
    /// - Returns: A ``DocumentSymbol``, or `nil` if parsing fails.
    private func parseDocumentSymbol(_ dict: [String: Any]) -> DocumentSymbol? {
        guard let name = dict["name"] as? String,
              let kind = dict["kind"] as? Int
        else { return nil }

        // Try DocumentSymbol shape (has range + selectionRange)
        if let rangeDict = dict["range"] as? [String: Any],
           let selectionDict = dict["selectionRange"] as? [String: Any],
           let range = parseRange(rangeDict),
           let selectionRange = parseRange(selectionDict) {
            let children = (dict["children"] as? [[String: Any]])?.compactMap { parseDocumentSymbol($0) }
            return DocumentSymbol(
                name: name,
                kind: kind,
                range: range,
                selectionRange: selectionRange,
                children: children,
            )
        }

        // Fall back to SymbolInformation shape (has location)
        if let locationDict = dict["location"] as? [String: Any],
           let rangeDict = locationDict["range"] as? [String: Any],
           let range = parseRange(rangeDict) {
            return DocumentSymbol(
                name: name,
                kind: kind,
                range: range,
                selectionRange: range,
                children: nil,
            )
        }

        return nil
    }
}

// MARK: - Errors

/// Errors specific to LSP client operations.
public enum LspError: Error, Sendable {
    /// The language server process failed to launch.
    case serverLaunchFailed(String)

    /// The client has not been initialized via ``LspClient/start(rootUri:)``.
    case notStarted

    /// Failed to encode a JSON-RPC message.
    case encodingFailed

    /// The server returned a JSON-RPC error.
    case serverError(Int, String)

    /// The server process crashed unexpectedly.
    case serverCrashed

    /// The server was shut down.
    case serverShutdown

    /// Invalid or missing Content-Length header in server response.
    case invalidHeader

    /// The language server executable was not found on the system.
    case serverNotFound(String)
}
