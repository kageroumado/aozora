import Foundation

/// Agent-facing tool for Language Server Protocol code intelligence operations.
///
/// Provides hover information, go-to-definition, find-references, and document symbol
/// listing by delegating to the appropriate language server via ``LspServerRegistry``.
///
/// Line and character coordinates are 1-indexed in the tool interface (matching what
/// users and editors display) and converted to 0-indexed for the LSP protocol internally.
///
/// Supported operations:
/// - `hover` — Type information and documentation at a position.
/// - `definition` — Jump to the definition of a symbol.
/// - `references` — Find all references to a symbol.
/// - `symbols` — List all symbols in a document.
public nonisolated struct LspTool: ToolExecutable {
    /// The tool name used in tool registration and model invocations.
    public let name = "lsp"

    /// The server registry that manages language server lifecycles.
    let registry: LspServerRegistry

    /// Create an LSP tool backed by the given server registry.
    ///
    /// - Parameter registry: The shared ``LspServerRegistry`` for managing server processes.
    public init(registry: LspServerRegistry) {
        self.registry = registry
    }

    public var definition: ToolDefinition {
        ToolDefinition(
            name: "lsp",
            description: """
            Language Server Protocol code intelligence. Provides hover info, go-to-definition, \
            find-references, and document symbols. Line and character are 1-indexed.
            """,
            parameters: [
                ToolParameter(
                    name: "operation",
                    type: .enum(["hover", "definition", "references", "symbols"]),
                    description: "The LSP operation to perform",
                ),
                ToolParameter(
                    name: "file",
                    type: .string,
                    description: "Absolute path to the file to query",
                ),
                ToolParameter(
                    name: "line",
                    type: .integer,
                    description: "Line number (1-indexed). Required for hover, definition, and references.",
                    optional: true,
                ),
                ToolParameter(
                    name: "character",
                    type: .integer,
                    description: "Character offset (1-indexed). Required for hover, definition, and references.",
                    optional: true,
                ),
            ],
        )
    }

    public func execute(parameters: sending [String: Any], workingDirectory: String) async throws -> ToolResult {
        let operation = try requireString("operation", from: parameters)
        let file = try requireString("file", from: parameters)

        let resolvedFile = resolvePath(file, workingDirectory: workingDirectory)

        // Determine workspace root — walk up from file to find common project markers
        let rootDir = findWorkspaceRoot(from: resolvedFile) ?? workingDirectory

        // Get the LSP client
        let client: LspClient
        do {
            guard let c = try await registry.getClient(for: resolvedFile, rootDir: rootDir) else {
                let ext = (resolvedFile as NSString).pathExtension
                if ext.isEmpty {
                    return .failure("No language server configured for files without an extension.")
                }
                return .failure("No language server available for .\(ext) files. The server may not be installed.")
            }
            client = c
        } catch {
            await registry.removeClient(for: resolvedFile, rootDir: rootDir)
            return .failure("Failed to start language server: \(error)")
        }

        do {
            switch operation {
            case "hover":
                return try await executeHover(client: client, file: resolvedFile, parameters: parameters)
            case "definition":
                return try await executeDefinition(client: client, file: resolvedFile, parameters: parameters)
            case "references":
                return try await executeReferences(client: client, file: resolvedFile, parameters: parameters)
            case "symbols":
                return try await executeSymbols(client: client, file: resolvedFile)
            default:
                throw ToolError.invalidParameters("Unknown operation '\(operation)'. Use: hover, definition, references, symbols")
            }
        } catch let error as LspError {
            // On server crash, remove the cached client so retries get a fresh one
            if case .serverCrashed = error {
                await registry.removeClient(for: resolvedFile, rootDir: rootDir)
            }
            return .failure("LSP error: \(error)")
        }
    }

    // MARK: - Operation Handlers

    /// Execute a hover request and format the result.
    private func executeHover(
        client: LspClient,
        file: String,
        parameters: [String: Any],
    ) async throws -> ToolResult {
        let (line, character) = try extractPosition(from: parameters)

        let result = try await client.hover(file: file, line: line, character: character)
        return .success(result ?? "No hover information available at this position.")
    }

    /// Execute a definition request and format the result.
    private func executeDefinition(
        client: LspClient,
        file: String,
        parameters: [String: Any],
    ) async throws -> ToolResult {
        let (line, character) = try extractPosition(from: parameters)

        let locations = try await client.definition(file: file, line: line, character: character)

        if locations.isEmpty {
            return .success("No definition found at this position.")
        }

        return .success(formatLocations(locations))
    }

    /// Execute a references request and format the result.
    private func executeReferences(
        client: LspClient,
        file: String,
        parameters: [String: Any],
    ) async throws -> ToolResult {
        let (line, character) = try extractPosition(from: parameters)

        let locations = try await client.references(file: file, line: line, character: character)

        if locations.isEmpty {
            return .success("No references found at this position.")
        }

        let header = "\(locations.count) reference\(locations.count == 1 ? "" : "s") found:\n"
        return .success(header + formatLocations(locations))
    }

    /// Execute a document symbols request and format the result.
    private func executeSymbols(
        client: LspClient,
        file: String,
    ) async throws -> ToolResult {
        let symbols = try await client.documentSymbols(file: file)

        if symbols.isEmpty {
            return .success("No symbols found in this file.")
        }

        return .success(formatSymbols(symbols, indent: 0))
    }

    // MARK: - Formatting

    /// Format an array of ``LspLocation`` values as human-readable text.
    ///
    /// Each location is shown as `path:line:character` with the `file://` prefix stripped
    /// and positions converted back to 1-indexed.
    ///
    /// - Parameter locations: The locations to format.
    /// - Returns: Newline-separated location strings.
    private func formatLocations(_ locations: [LspLocation]) -> String {
        locations.map { loc in
            let path = loc.uri.hasPrefix("file://") ? String(loc.uri.dropFirst(7)) : loc.uri
            let line = loc.range.start.line + 1
            let char = loc.range.start.character + 1
            return "\(path):\(line):\(char)"
        }.joined(separator: "\n")
    }

    /// Format an array of ``DocumentSymbol`` values as an indented outline.
    ///
    /// Children are recursively indented with two spaces per level.
    ///
    /// - Parameters:
    ///   - symbols: The symbols to format.
    ///   - indent: Current indentation level (0 for top-level).
    /// - Returns: Multi-line formatted symbol tree.
    private func formatSymbols(_ symbols: [DocumentSymbol], indent: Int) -> String {
        let prefix = String(repeating: "  ", count: indent)
        return symbols.map { sym in
            let kindName = SymbolKindName.name(for: sym.kind)
            let line = sym.selectionRange.start.line + 1
            var result = "\(prefix)\(kindName) \(sym.name) (line \(line))"
            if let children = sym.children, !children.isEmpty {
                result += "\n" + formatSymbols(children, indent: indent + 1)
            }
            return result
        }.joined(separator: "\n")
    }

    // MARK: - Helpers

    /// Extract and validate 1-indexed line/character from parameters, converting to 0-indexed.
    ///
    /// - Parameter parameters: The tool call parameters.
    /// - Returns: A tuple of (0-indexed line, 0-indexed character).
    /// - Throws: ``ToolError/invalidParameters(_:)`` if line or character is missing.
    private func extractPosition(from parameters: [String: Any]) throws -> (Int, Int) {
        guard let line = parameters["line"] as? Int else {
            throw ToolError.invalidParameters("'line' parameter is required for this operation")
        }
        guard let character = parameters["character"] as? Int else {
            throw ToolError.invalidParameters("'character' parameter is required for this operation")
        }
        // Convert from 1-indexed (user-facing) to 0-indexed (LSP protocol)
        return (line - 1, character - 1)
    }

    /// Walk up the directory tree from a file to find the workspace root.
    ///
    /// Looks for common project markers (`.git`, `Package.swift`, `*.xcodeproj`,
    /// `package.json`, `Cargo.toml`, `go.mod`, `pyproject.toml`).
    ///
    /// - Parameter filePath: Absolute path to a source file.
    /// - Returns: The workspace root directory, or `nil` if no marker is found.
    private func findWorkspaceRoot(from filePath: String) -> String? {
        let markers = [
            ".git", "Package.swift", "package.json", "Cargo.toml",
            "go.mod", "pyproject.toml", "setup.py", "CMakeLists.txt",
        ]
        let xcodeprojGlob = ".xcodeproj"

        var dir = (filePath as NSString).deletingLastPathComponent
        let fm = FileManager.default

        while dir != "/", !dir.isEmpty {
            for marker in markers {
                let candidate = (dir as NSString).appendingPathComponent(marker)
                if fm.fileExists(atPath: candidate) {
                    return dir
                }
            }

            // Check for *.xcodeproj directories
            if let contents = try? fm.contentsOfDirectory(atPath: dir) {
                if contents.contains(where: { $0.hasSuffix(xcodeprojGlob) }) {
                    return dir
                }
            }

            dir = (dir as NSString).deletingLastPathComponent
        }

        return nil
    }
}
