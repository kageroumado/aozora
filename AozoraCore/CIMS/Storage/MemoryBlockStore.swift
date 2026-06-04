import Foundation

/// Persistent named text blocks for agent self-knowledge.
///
/// Stores named text blocks (self, user, narrative, projects, active, world) in a JSON file
/// at `~/.aozora/memory-blocks.json`. Each block has a maximum character limit to prevent
/// unbounded growth. The agent can read, replace, append, and rewrite blocks via the
/// ``MemoryBlockTool``.
///
/// This is a simpler, more direct alternative to the epistemic claim system in
/// ``IdentityStore`` — designed for free-form text that the agent manages explicitly,
/// rather than structured claims that are merged through consolidation.
public actor MemoryBlockStore {
    /// Block definitions with maximum character limits and descriptions.
    ///
    /// These define the available block names, their size budgets, and what each block
    /// is intended to contain. The descriptions are surfaced in the tool definition
    /// so the model knows what each block is for.
    public static let blockDefinitions: [(name: String, maxChars: Int, description: String)] = [
        ("self", 12_000, "Your self-knowledge: personality, traits, values, capabilities, origin story"),
        ("user", 12_000, "What you know about your primary user: preferences, communication style, projects, context"),
        ("narrative", 8_000, "The ongoing story of your interactions: key moments, evolution, relationship"),
        ("projects", 8_000, "Active projects and their status"),
        ("active", 4_000, "Current session focus: what you're working on right now"),
        ("world", 4_000, "External facts: dates, events, environment context"),
    ]

    /// The in-memory block contents keyed by block name.
    private var blocks: [String: String] = [:]

    /// Absolute path to the JSON persistence file.
    private let storagePath: String

    /// Creates a memory block store backed by the given file path.
    ///
    /// Loads existing blocks from disk synchronously during initialization.
    /// If the file doesn't exist or can't be parsed, starts with empty blocks.
    ///
    /// - Parameter storagePath: Absolute path to the JSON file. Defaults to `~/.aozora/memory-blocks.json`.
    public init(storagePath: String = NSHomeDirectory() + "/.aozora/memory-blocks.json") {
        self.storagePath = storagePath

        // Synchronous file read in init is fine — the file is small (< 30KB max)
        // and we need the data before any actor methods can be called.
        let url = URL(fileURLWithPath: storagePath)
        if FileManager.default.fileExists(atPath: storagePath),
           let data = try? Data(contentsOf: url),
           let dict = try? JSONDecoder().decode([String: String].self, from: data) {
            // Only load blocks that match known definitions
            let knownNames = Set(Self.blockDefinitions.map(\.name))
            for (key, value) in dict where knownNames.contains(key) {
                self.blocks[key] = value
            }
        }
    }

    // MARK: - Read

    /// Read a single block by name.
    ///
    /// - Parameter name: The block name (e.g., "self", "user").
    /// - Returns: The block content, or `nil` if the block has never been written.
    public func get(_ name: String) -> String? {
        blocks[name]
    }

    /// Get all blocks as a dictionary.
    public func all() -> [String: String] {
        blocks
    }

    // MARK: - Write

    /// Replace a block's content entirely.
    ///
    /// Validates that the block name is known and the content fits within the
    /// character limit. Persists to disk immediately on success.
    ///
    /// - Parameters:
    ///   - name: The block name.
    ///   - content: The new content.
    /// - Throws: ``MemoryBlockError/unknownBlock(_:)`` or ``MemoryBlockError/exceedsLimit(_:_:_:)``.
    public func replace(_ name: String, content: String) throws {
        guard let def = Self.blockDefinitions.first(where: { $0.name == name }) else {
            throw MemoryBlockError.unknownBlock(name)
        }
        guard content.count <= def.maxChars else {
            throw MemoryBlockError.exceedsLimit(name, content.count, def.maxChars)
        }
        blocks[name] = content
        saveToDisk()
    }

    /// Append text to a block, joining with a newline if the block is non-empty.
    ///
    /// The combined result must still fit within the block's character limit.
    ///
    /// - Parameters:
    ///   - name: The block name.
    ///   - content: The text to append.
    /// - Throws: ``MemoryBlockError/unknownBlock(_:)`` or ``MemoryBlockError/exceedsLimit(_:_:_:)``.
    public func append(_ name: String, content: String) throws {
        let existing = blocks[name] ?? ""
        let newContent = existing.isEmpty ? content : existing + "\n" + content
        try replace(name, content: newContent)
    }

    // MARK: - Context Rendering

    /// Render all blocks as XML for injection into the model's context window.
    ///
    /// Each block is wrapped in a named XML element with a `chars` attribute showing
    /// current usage versus the maximum. Empty blocks show "(empty)".
    ///
    /// Example output:
    /// ```xml
    /// <core_memory>
    /// <self chars="1234/8000">
    /// I am ...
    /// </self>
    /// ...
    /// </core_memory>
    /// ```
    public func renderForContext() -> String {
        var parts: [String] = []
        parts.append("<core_memory>")
        for (name, maxChars, _) in Self.blockDefinitions {
            let content = blocks[name] ?? "(empty)"
            let charCount = (blocks[name] ?? "").count
            parts.append("<\(name) chars=\"\(charCount)/\(maxChars)\">")
            parts.append(content)
            parts.append("</\(name)>")
        }
        parts.append("</core_memory>")
        return parts.joined(separator: "\n")
    }

    // MARK: - Persistence

    /// Write the current block state to disk as JSON.
    ///
    /// Creates the parent directory if it doesn't exist. Errors are silently
    /// ignored — the in-memory state is authoritative during the process lifetime.
    private func saveToDisk() {
        let url = URL(fileURLWithPath: storagePath)
        let dir = url.deletingLastPathComponent()
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        if let data = try? JSONEncoder().encode(blocks) {
            try? data.write(to: url)
        }
    }
}

// MARK: - Errors

/// Errors from memory block operations.
public nonisolated enum MemoryBlockError: Error, Sendable, CustomStringConvertible {
    /// The requested block name is not in ``MemoryBlockStore/blockDefinitions``.
    case unknownBlock(String)

    /// The content exceeds the block's character limit.
    /// Parameters: block name, actual character count, maximum allowed.
    case exceedsLimit(String, Int, Int)

    public var description: String {
        switch self {
        case let .unknownBlock(name):
            "Unknown memory block '\(name)'. Valid blocks: \(MemoryBlockStore.blockDefinitions.map(\.name).joined(separator: ", "))"
        case let .exceedsLimit(name, actual, max):
            "Block '\(name)' content (\(actual) chars) exceeds limit (\(max) chars)"
        }
    }
}
