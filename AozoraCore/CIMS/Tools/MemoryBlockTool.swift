import Foundation

/// Tool for reading and modifying persistent core memory blocks.
///
/// Provides four actions:
/// - `view` — show a single block (by name) or all blocks
/// - `replace` — overwrite a block entirely
/// - `append` — add text to the end of a block
/// - `rewrite` — alias for replace (semantic clarity for the model)
///
/// Memory blocks survive across sessions and are injected into the context window
/// each turn, giving the agent persistent self-knowledge that it controls directly.
public nonisolated struct MemoryBlockTool: ToolExecutable {
    /// The memory block store to read from and write to.
    private let store: MemoryBlockStore

    public let name = "memory"

    public var definition: ToolDefinition {
        let blockList = MemoryBlockStore.blockDefinitions
            .map { "\($0.name) (\($0.maxChars) chars max): \($0.description)" }
            .joined(separator: "\n  - ")

        return ToolDefinition(
            name: "memory",
            description: """
            Manage your persistent core memory blocks. These survive across sessions \
            and are injected into your context every turn.
            Actions: "view" shows a block (or all if no block specified), "replace" overwrites \
            a block, "append" adds to a block, "rewrite" completely replaces a block.
            Available blocks:
              - \(blockList)
            """,
            parameters: [
                ToolParameter(
                    name: "action",
                    type: .enum(["view", "replace", "append", "rewrite"]),
                    description: "Action to perform",
                ),
                ToolParameter(
                    name: "block",
                    type: .string,
                    description: "Block name (self, user, narrative, projects, active, world)",
                    optional: true,
                ),
                ToolParameter(
                    name: "content",
                    type: .string,
                    description: "Content for replace/append/rewrite actions",
                    optional: true,
                ),
            ],
        )
    }

    /// Creates a memory block tool backed by the given store.
    ///
    /// - Parameter store: The ``MemoryBlockStore`` to read from and write to.
    public init(store: MemoryBlockStore) {
        self.store = store
    }

    public func execute(parameters: sending [String: Any], workingDirectory _: String) async throws -> ToolResult {
        let action = try requireString("action", from: parameters)

        switch action {
        case "view":
            return await viewBlock(parameters)

        case "replace", "rewrite":
            return await replaceBlock(parameters, action: action)

        case "append":
            return await appendToBlock(parameters)

        default:
            return .failure("Unknown action '\(action)'. Use view, replace, append, or rewrite.")
        }
    }

    // MARK: - Actions

    /// View a single block or all blocks.
    private func viewBlock(_ parameters: [String: Any]) async -> ToolResult {
        let blockName = parameters["block"] as? String

        if let name = blockName {
            guard let def = MemoryBlockStore.blockDefinitions.first(where: { $0.name == name }) else {
                let validNames = MemoryBlockStore.blockDefinitions.map(\.name).joined(separator: ", ")
                return .failure("Unknown block '\(name)'. Valid blocks: \(validNames)")
            }

            let content = await store.get(name) ?? "(empty)"
            let charCount = await (store.get(name))?.count ?? 0
            return .success("[\(name)] (\(charCount)/\(def.maxChars) chars):\n\(content)")
        } else {
            let rendered = await store.renderForContext()
            return .success(rendered)
        }
    }

    /// Replace or rewrite a block entirely.
    private func replaceBlock(_ parameters: [String: Any], action: String) async -> ToolResult {
        guard let name = parameters["block"] as? String else {
            return .failure("'block' is required for \(action)")
        }
        guard let content = parameters["content"] as? String else {
            return .failure("'content' is required for \(action)")
        }

        do {
            try await store.replace(name, content: content)
            let maxChars = MemoryBlockStore.blockDefinitions.first { $0.name == name }?.maxChars ?? 0
            return .success("Updated [\(name)] — \(content.count)/\(maxChars) chars")
        } catch {
            return .failure("Error: \(error)")
        }
    }

    /// Append text to a block.
    private func appendToBlock(_ parameters: [String: Any]) async -> ToolResult {
        guard let name = parameters["block"] as? String else {
            return .failure("'block' is required for append")
        }
        guard let content = parameters["content"] as? String else {
            return .failure("'content' is required for append")
        }

        do {
            try await store.append(name, content: content)
            let total = await (store.get(name))?.count ?? 0
            let maxChars = MemoryBlockStore.blockDefinitions.first { $0.name == name }?.maxChars ?? 0
            return .success("Appended to [\(name)] — now \(total)/\(maxChars) chars")
        } catch {
            return .failure("Error: \(error)")
        }
    }
}
