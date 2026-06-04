import Foundation

/// Registry that manages language server processes, mapping file extensions to server
/// commands and caching running instances per (language, workspace) pair.
///
/// Language servers are lazily started on first request for a given file type within a
/// workspace. If a server is not installed (the executable is not found on `PATH`), the
/// registry returns `nil` rather than failing — the caller can surface a user-friendly
/// message.
///
/// Each server process is owned by a single ``LspClient`` actor. The registry caches
/// clients by a composite key of file extension and workspace root, so multiple files
/// of the same language within the same project share one server instance.
public actor LspServerRegistry {
    /// Known language server definitions keyed by file extension.
    ///
    /// Each entry maps a file extension (without the dot) to the server binary name
    /// and its command-line arguments for stdio mode.
    private static let serverDefinitions: [String: (command: String, args: [String])] = [
        "swift": ("sourcekit-lsp", []),
        "py": ("pyright-langserver", ["--stdio"]),
        "ts": ("typescript-language-server", ["--stdio"]),
        "tsx": ("typescript-language-server", ["--stdio"]),
        "js": ("typescript-language-server", ["--stdio"]),
        "jsx": ("typescript-language-server", ["--stdio"]),
        "go": ("gopls", ["serve"]),
        "rs": ("rust-analyzer", []),
        "c": ("clangd", []),
        "cpp": ("clangd", []),
        "h": ("clangd", []),
    ]

    /// Cached running clients keyed by `"extension:rootDir"`.
    private var clients: [String: LspClient] = [:]

    /// Create an empty server registry.
    public init() {}

    /// Get or create an LSP client for the given file.
    ///
    /// Determines the appropriate language server from the file extension, checks the cache,
    /// and either returns an existing client or launches a new server process.
    ///
    /// - Parameters:
    ///   - file: Absolute path to the file being queried.
    ///   - rootDir: The workspace root directory (used as the LSP `rootUri`).
    /// - Returns: An initialized ``LspClient``, or `nil` if no server is configured for
    ///   the file's language or the server executable is not installed.
    /// - Throws: ``LspError`` if server launch or initialization fails.
    public func getClient(for file: String, rootDir: String) async throws -> LspClient? {
        let ext = (file as NSString).pathExtension.lowercased()

        guard let definition = Self.serverDefinitions[ext] else {
            return nil
        }

        let cacheKey = "\(ext):\(rootDir)"

        // Return cached client if available
        if let existing = clients[cacheKey] {
            return existing
        }

        // Find the executable
        guard let execPath = findExecutable(definition.command) else {
            return nil
        }

        // Create and start a new client
        let client = LspClient(
            command: execPath,
            arguments: definition.args,
            workingDirectory: rootDir,
        )

        do {
            try await client.start(rootUri: "file://" + rootDir)
            clients[cacheKey] = client
            return client
        } catch {
            // Server failed to start — don't cache the broken client
            throw error
        }
    }

    /// Remove a cached client, typically after a server crash.
    ///
    /// The next call to ``getClient(for:rootDir:)`` for the same language/workspace
    /// will attempt to launch a fresh server process.
    ///
    /// - Parameters:
    ///   - file: Absolute path used to determine the file extension.
    ///   - rootDir: The workspace root directory.
    public func removeClient(for file: String, rootDir: String) {
        let ext = (file as NSString).pathExtension.lowercased()
        let cacheKey = "\(ext):\(rootDir)"
        clients.removeValue(forKey: cacheKey)
    }

    /// Shut down all cached language server processes.
    ///
    /// Called during application teardown to cleanly terminate all running servers.
    public func shutdown() async {
        for (_, client) in clients {
            await client.shutdown()
        }
        clients.removeAll()
    }

    /// The set of file extensions that have configured language servers.
    ///
    /// Useful for checking whether LSP support is available for a given file type
    /// without attempting to launch a server.
    public static var supportedExtensions: Set<String> {
        Set(serverDefinitions.keys)
    }

    // MARK: - Private

    /// Locate an executable by name using `/usr/bin/which`.
    ///
    /// - Parameter command: The executable name (e.g., `"sourcekit-lsp"`).
    /// - Returns: The absolute path to the executable, or `nil` if not found.
    private func findExecutable(_ command: String) -> String? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/which")
        process.arguments = [command]

        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice

        do {
            try process.run()
        } catch {
            return nil
        }

        process.waitUntilExit()

        guard process.terminationStatus == 0 else { return nil }

        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        let path = String(data: data, encoding: .utf8)?
            .trimmingCharacters(in: .whitespacesAndNewlines)

        guard let path, !path.isEmpty else { return nil }
        return path
    }
}
