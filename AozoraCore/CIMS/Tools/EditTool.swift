import Foundation

/// Precise text replacement in files (surgical edits).
///
/// Finds an exact match of `old_string` in the file and replaces it with `new_string`.
/// Fails if the old string is not found or matches at multiple locations, ensuring
/// edits are unambiguous.
///
/// When a ``FileAccessTracker`` is provided, the tool validates that the target file
/// was previously read via ``ReadTool`` and hasn't been modified externally since.
///
/// When a ``FileVersionStore`` is provided, captures the file's content before writing
/// the replacement, enabling undo via ``UndoTool``.
///
/// When an ``LspServerRegistry`` is provided, the tool automatically queries the language
/// server for diagnostics after a successful edit and appends them to the result.
public nonisolated struct EditTool: ToolExecutable {
    public let name = "edit"

    /// Optional tracker for read-before-edit enforcement.
    private let tracker: FileAccessTracker?

    /// Optional version store for capturing pre-edit snapshots.
    private let versionStore: FileVersionStore?

    /// Conversation ID for scoping version captures.
    private let conversationId: Int64

    /// Optional LSP server registry for post-edit diagnostic injection.
    private let lspRegistry: LspServerRegistry?

    /// The diagnostic injector used to fetch and format LSP diagnostics.
    private let diagnosticInjector: DiagnosticInjector

    /// Create an edit tool with optional safety and observability features.
    ///
    /// - Parameters:
    ///   - tracker: If provided, edits are rejected unless the file was recently read
    ///     via ``ReadTool``. Pass `nil` to disable enforcement.
    ///   - versionStore: If provided, file content is captured before each edit.
    ///   - conversationId: The conversation scope for version captures.
    ///   - lspRegistry: If provided, LSP diagnostics are appended after successful edits.
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
            name: "edit",
            description: """
            Perform an exact text replacement in a file. The old_string must match exactly \
            (including whitespace and indentation). Fails if no match or multiple matches are found.
            """,
            parameters: [
                ToolParameter(name: "file_path", type: .string, description: "Absolute or relative path to edit"),
                ToolParameter(name: "old_string", type: .string, description: "Exact text to find and replace"),
                ToolParameter(name: "new_string", type: .string, description: "Replacement text"),
            ],
        )
    }

    public func execute(parameters: sending [String: Any], workingDirectory: String) async throws -> ToolResult {
        let filePath = try requireString("file_path", from: parameters)
        let oldString = try requireString("old_string", from: parameters)
        let newString = try requireString("new_string", from: parameters)

        let resolvedPath = resolvePath(filePath, workingDirectory: workingDirectory)

        guard FileManager.default.fileExists(atPath: resolvedPath) else {
            return .failure("Error: File not found: \(resolvedPath)")
        }

        if let tracker {
            if let error = await tracker.validateAccess(path: resolvedPath, fileExists: true) {
                return ToolResult(content: error, isError: true)
            }
        }

        let content: String
        do {
            content = try String(contentsOfFile: resolvedPath, encoding: .utf8)
        } catch {
            return .failure("Error reading file: \(error.localizedDescription)")
        }

        let occurrences = countOccurrences(of: oldString, in: content)

        if occurrences == 0 {
            return .failure("Error: old_string not found in \(resolvedPath)")
        }

        if occurrences > 1 {
            return .failure("Error: Found \(occurrences) matches of old_string in \(resolvedPath). The match must be unique.")
        }

        let newContent = content.replacingOccurrences(of: oldString, with: newString)

        if let versionStore {
            await versionStore.captureVersion(
                conversationId: conversationId,
                filePath: resolvedPath,
                mutationTool: "edit",
            )
        }

        do {
            try newContent.write(toFile: resolvedPath, atomically: true, encoding: .utf8)
        } catch {
            return .failure("Error writing file: \(error.localizedDescription)")
        }

        var resultContent = "Edited \(resolvedPath): replaced 1 occurrence"

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

    /// Count non-overlapping occurrences of a substring in a string.
    private func countOccurrences(of needle: String, in haystack: String) -> Int {
        guard !needle.isEmpty else { return 0 }
        var count = 0
        var searchRange = haystack.startIndex ..< haystack.endIndex

        while let range = haystack.range(of: needle, range: searchRange) {
            count += 1
            searchRange = range.upperBound ..< haystack.endIndex
        }

        return count
    }
}
