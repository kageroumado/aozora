import Foundation

/// Reverts file changes by restoring previously captured versions.
///
/// Works in tandem with ``FileVersionStore``, which captures file content before
/// each mutation by ``EditTool`` and ``WriteTool``. Supports two modes:
/// - `"last"` (default): Undo the most recent change.
/// - `"all"`: Revert to the original state before any mutations in the conversation.
public nonisolated struct UndoTool: ToolExecutable {
    public let name = "undo"

    /// The file version store that holds captured versions.
    private let versionStore: FileVersionStore

    /// The conversation ID used for scoping version lookups.
    private let conversationId: Int64

    /// Create an undo tool backed by the given version store.
    ///
    /// - Parameters:
    ///   - versionStore: The store holding file version snapshots.
    ///   - conversationId: The conversation scope for version lookups.
    public init(versionStore: FileVersionStore, conversationId: Int64 = 0) {
        self.versionStore = versionStore
        self.conversationId = conversationId
    }

    public var definition: ToolDefinition {
        ToolDefinition(
            name: "undo",
            description: """
            Revert a file to a previous version. Use mode "last" to undo the most recent \
            change, or "all" to revert to the original state before any edits in this conversation.
            """,
            parameters: [
                ToolParameter(
                    name: "file_path",
                    type: .string,
                    description: "Absolute or relative path of the file to revert",
                ),
                ToolParameter(
                    name: "mode",
                    type: .enum(["last", "all"]),
                    description: "Undo mode: \"last\" reverts one step, \"all\" reverts to original",
                    optional: true,
                ),
            ],
        )
    }

    public func execute(parameters: sending [String: Any], workingDirectory: String) async throws -> ToolResult {
        guard let filePath = parameters["file_path"] as? String else {
            throw ToolError.invalidParameters("'file_path' parameter is required and must be a string")
        }

        let mode = (parameters["mode"] as? String) ?? "last"

        guard mode == "last" || mode == "all" else {
            throw ToolError.invalidParameters("'mode' must be \"last\" or \"all\"")
        }

        let resolvedPath = resolvePath(filePath, workingDirectory: workingDirectory)

        let result: UndoResult? = if mode == "all" {
            await versionStore.undoAll(conversationId: conversationId, filePath: resolvedPath)
        } else {
            await versionStore.undoLast(conversationId: conversationId, filePath: resolvedPath)
        }

        guard let result else {
            return .success("No version history found for \(resolvedPath). Nothing to undo.")
        }

        return .success(
            "Undone \(result.versionsReverted) version(s) for \(result.restoredPath). \(result.diffSummary)",
        )
    }

    /// Resolve a path relative to the working directory if it's not absolute.
    private func resolvePath(_ path: String, workingDirectory: String) -> String {
        if path.hasPrefix("/") { return path }
        return (workingDirectory as NSString).appendingPathComponent(path)
    }
}
