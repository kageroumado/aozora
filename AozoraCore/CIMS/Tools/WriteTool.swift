import Foundation

/// Create or overwrite files, automatically creating parent directories as needed.
///
/// Returns a confirmation with the byte count written. When a ``FileAccessTracker`` is
/// provided and the target file already exists, the tool validates that the file was
/// previously read via ``ReadTool``. New file creation (file doesn't exist) is exempt.
///
/// When a ``FileVersionStore`` is provided, captures the file's content before overwriting,
/// enabling undo via ``UndoTool``.
///
/// When an ``LspServerRegistry`` is provided, the tool automatically queries the language
/// server for diagnostics after a successful write and appends them to the result.
public nonisolated struct WriteTool: ToolExecutable {
    public let name = "write"

    /// Optional tracker for read-before-write enforcement on existing files.
    private let tracker: FileAccessTracker?

    /// Optional version store for capturing pre-write snapshots.
    private let versionStore: FileVersionStore?

    /// Conversation ID for scoping version captures.
    private let conversationId: Int64

    /// Optional LSP server registry for post-write diagnostic injection.
    private let lspRegistry: LspServerRegistry?

    /// The diagnostic injector used to fetch and format LSP diagnostics.
    private let diagnosticInjector: DiagnosticInjector

    /// Create a write tool with optional safety and observability features.
    ///
    /// - Parameters:
    ///   - tracker: If provided, overwrites of existing files are rejected unless the file
    ///     was recently read via ``ReadTool``. Pass `nil` to disable enforcement.
    ///   - versionStore: If provided, file content is captured before each overwrite.
    ///   - conversationId: The conversation scope for version captures.
    ///   - lspRegistry: If provided, LSP diagnostics are appended after successful writes.
    public init(
        tracker: FileAccessTracker? = nil,
        versionStore: FileVersionStore? = nil,
        conversationId: Int64 = 0,
        lspRegistry: LspServerRegistry? = nil,
    ) {
        self.tracker = tracker
        self.versionStore = versionStore
        self.conversationId = conversationId
        self.lspRegistry = lspRegistry
        self.diagnosticInjector = DiagnosticInjector()
    }

    public var definition: ToolDefinition {
        ToolDefinition(
            name: "write",
            description: "Create or overwrite a file with the given content. Creates parent directories automatically.",
            parameters: [
                ToolParameter(name: "file_path", type: .string, description: "Absolute or relative path to write"),
                ToolParameter(name: "content", type: .string, description: "The content to write to the file"),
            ],
        )
    }

    public func execute(parameters: sending [String: Any], workingDirectory: String) async throws -> ToolResult {
        let filePath = try requireString("file_path", from: parameters)
        let content = try requireString("content", from: parameters)

        let resolvedPath = resolvePath(filePath, workingDirectory: workingDirectory)

        let fileExists = FileManager.default.fileExists(atPath: resolvedPath)
        if let tracker, fileExists {
            if let error = await tracker.validateAccess(path: resolvedPath, fileExists: true) {
                return ToolResult(content: error, isError: true)
            }
        }

        let parentDir = (resolvedPath as NSString).deletingLastPathComponent
        if !FileManager.default.fileExists(atPath: parentDir) {
            do {
                try FileManager.default.createDirectory(atPath: parentDir, withIntermediateDirectories: true)
            } catch {
                return .failure("Error creating parent directories: \(error.localizedDescription)")
            }
        }

        guard let data = content.data(using: .utf8) else {
            return .failure("Error: Content could not be encoded as UTF-8")
        }

        if let versionStore, fileExists {
            await versionStore.captureVersion(
                conversationId: conversationId,
                filePath: resolvedPath,
                mutationTool: "write",
            )
        }

        do {
            try data.write(to: URL(fileURLWithPath: resolvedPath))
        } catch {
            return .failure("Error writing file: \(error.localizedDescription)")
        }

        var resultContent = "Wrote \(data.count) bytes to \(resolvedPath)"

        if let registry = lspRegistry {
            if let diagnosticBlock = await diagnosticInjector.fetchDiagnostics(
                for: resolvedPath,
                workingDirectory: workingDirectory,
                registry: registry,
            ) {
                resultContent += "\n\n" + diagnosticBlock
            }
        }

        return .success(resultContent)
    }
}
