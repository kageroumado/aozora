import Foundation

/// A condition under which a skill should be automatically loaded.
///
/// Skills declare activation conditions in their YAML frontmatter as a `when` field.
/// Conditions are evaluated against the current turn's context to determine
/// which skills are relevant.
///
/// Supported frontmatter syntax:
/// - `when: "*.swift"` — file pattern glob
/// - `when: keyword("deploy")` — keyword trigger
/// - `when: [*.swift, keyword(test)]` — array of mixed conditions
public enum ActivationCondition: Sendable, Equatable {
    /// Match when the turn involves a file matching this glob pattern.
    case filePattern(String)

    /// Match when the turn message contains this keyword (case-insensitive).
    case keyword(String)
}

/// Manages discovery, loading, and creation of markdown-based skill definitions.
///
/// Skills are directories on disk, each containing a `SKILL.md` file with YAML frontmatter
/// describing the skill's metadata (name, description, tags, version) and a markdown body
/// providing the actual skill instructions.
///
/// `SkillManager` scans a list of search paths to discover skills, parsing their frontmatter
/// without loading the full body unless requested. This enables efficient enumeration of
/// many skills with minimal I/O.
///
/// Skill directories are organized as:
/// ```
/// ~/.aozora/skills/
///   my-skill/
///     SKILL.md     ← required
///     helper.md    ← optional additional files
/// ```
public nonisolated struct SkillManager: Sendable {
    /// Metadata parsed from a skill's YAML frontmatter.
    public struct SkillInfo: Sendable {
        /// The unique name of the skill, matching the frontmatter `name` field.
        public let name: String

        /// A short description of what the skill does, from the `description` field.
        public let description: String

        /// Tags for categorizing and filtering skills.
        public let tags: [String]

        /// Optional semantic version string (e.g., "1.0.0").
        public let version: String?

        /// Absolute path to the directory containing this skill's `SKILL.md`.
        public let path: String

        /// Activation conditions — when this skill should auto-load.
        ///
        /// Supports file pattern globs (e.g., `"*.swift"`) and keyword triggers.
        /// An empty array means the skill never auto-loads (manual only).
        public let when: [ActivationCondition]
    }

    /// Ordered list of directories to scan for skill subdirectories.
    let searchPaths: [String]

    /// Creates a skill manager with the given search paths.
    ///
    /// - Parameter searchPaths: Directories to scan. Defaults to `~/.aozora/skills`.
    public init(searchPaths: [String]? = nil) {
        self.searchPaths = searchPaths ?? [NSHomeDirectory() + "/.aozora/skills"]
    }

    // MARK: - Skill Entry

    /// A discovered skill directory with its parsed frontmatter and raw content.
    private struct SkillEntry {
        /// The directory name on disk.
        let directoryName: String

        /// Absolute path to the skill directory.
        let directoryPath: String

        /// The skill name from frontmatter, falling back to the directory name.
        let name: String

        /// Parsed YAML frontmatter metadata.
        let metadata: [String: Any]

        /// Raw contents of `SKILL.md`.
        let rawContent: String
    }

    // MARK: - Discovery

    /// Scan all search paths and return metadata for every discovered skill.
    ///
    /// Iterates each search path, treating each immediate subdirectory that contains
    /// a `SKILL.md` file as a skill. Parses the frontmatter for metadata without
    /// loading the full body.
    ///
    /// - Returns: Array of ``SkillInfo`` sorted by name, deduplicated by name (first path wins).
    public func listSkills() -> [SkillInfo] {
        var seen: Set<String> = []
        var results: [SkillInfo] = []

        for entry in allSkillEntries() {
            guard !seen.contains(entry.name) else { continue }
            seen.insert(entry.name)

            results.append(SkillInfo(
                name: entry.name,
                description: entry.metadata["description"] as? String ?? "",
                tags: entry.metadata["tags"] as? [String] ?? [],
                version: entry.metadata["version"] as? String,
                path: entry.directoryPath,
                when: Self.parseWhenConditions(entry.metadata["when"]),
            ))
        }

        return results.sorted { $0.name < $1.name }
    }

    // MARK: - Loading

    /// Load the full contents of a skill's `SKILL.md` by name.
    ///
    /// Searches all configured paths and returns the raw file contents (including frontmatter)
    /// for the first skill whose `name` frontmatter field matches, or whose directory name matches.
    ///
    /// - Parameter name: The skill name to look up.
    /// - Returns: The raw `SKILL.md` contents, or `nil` if no matching skill was found.
    public func viewSkill(name: String) -> String? {
        findSkillEntry(named: name)?.rawContent
    }

    /// Load a specific file within a skill's directory.
    ///
    /// Prevents path traversal — `..` components in `filePath` are rejected.
    ///
    /// - Parameters:
    ///   - name: The skill name whose directory to load from.
    ///   - filePath: Relative path within the skill directory (e.g., `"helper.md"`).
    /// - Returns: File contents, or `nil` if the skill or file doesn't exist.
    public func viewSkillFile(name: String, filePath: String) -> String? {
        guard !filePath.contains("..") else { return nil }
        guard let entry = findSkillEntry(named: name) else { return nil }
        let targetPath = entry.directoryPath + "/" + filePath
        return try? String(contentsOfFile: targetPath, encoding: .utf8)
    }

    // MARK: - Creation & Deletion

    /// Create a new skill in the first configured search path.
    ///
    /// Creates a directory named after the skill and writes the provided content as `SKILL.md`.
    /// If no frontmatter is present in `content`, it is written as-is.
    ///
    /// - Parameters:
    ///   - name: Directory name (and default skill name) to create.
    ///   - content: Full `SKILL.md` content including YAML frontmatter.
    /// - Throws: `CocoaError` or `URLError` if directory/file creation fails.
    public func createSkill(name: String, content: String) throws {
        guard let basePath = searchPaths.first else { return }
        let expanded = expandTilde(basePath)
        let skillDir = expanded + "/" + name
        let skillFile = skillDir + "/SKILL.md"

        try FileManager.default.createDirectory(
            atPath: skillDir,
            withIntermediateDirectories: true,
        )
        try content.write(toFile: skillFile, atomically: true, encoding: .utf8)
    }

    /// Move a skill's directory to the Trash.
    ///
    /// Uses `FileManager.trashItem(at:resultingItemURL:)` so the skill is recoverable.
    /// Searches all configured paths to locate the skill directory by name.
    ///
    /// - Parameter name: The skill name to delete.
    /// - Throws: `CocoaError` if the item can't be trashed, or a generic error if not found.
    public func deleteSkill(name: String) throws {
        guard let entry = findSkillEntry(named: name) else {
            throw SkillError.notFound(name)
        }
        let url = URL(fileURLWithPath: entry.directoryPath)
        try FileManager.default.trashItem(at: url, resultingItemURL: nil)
    }

    // MARK: - Matching

    /// Check if a skill's activation conditions match the given context.
    ///
    /// Returns `true` if ANY condition matches (OR logic). An empty conditions
    /// list means the skill never auto-loads (manual only).
    ///
    /// - Parameters:
    ///   - skill: The skill whose conditions to evaluate.
    ///   - message: The current turn's user message text.
    ///   - filePaths: File paths mentioned or involved in the current turn.
    /// - Returns: Whether any activation condition matched.
    public func matches(skill: SkillInfo, message: String, filePaths: [String]) -> Bool {
        guard !skill.when.isEmpty else { return false }

        let lowercasedMessage = message.lowercased()

        for condition in skill.when {
            switch condition {
            case let .filePattern(pattern):
                for filePath in filePaths {
                    let fileName = (filePath as NSString).lastPathComponent
                    if Self.matchesGlob(fileName: fileName, pattern: pattern) {
                        return true
                    }
                }
            case let .keyword(word):
                if lowercasedMessage.contains(word.lowercased()) {
                    return true
                }
            }
        }

        return false
    }

    // MARK: - Improvement

    /// Update an existing skill's `SKILL.md` with new content.
    ///
    /// Locates the skill by name across all search paths and overwrites
    /// the `SKILL.md` file with the provided content.
    ///
    /// - Parameters:
    ///   - name: The skill name to update.
    ///   - newContent: The replacement `SKILL.md` content (including frontmatter).
    /// - Throws: ``SkillError/notFound(_:)`` if no skill with this name exists.
    public func improveSkill(name: String, newContent: String) throws {
        for searchPath in searchPaths {
            let expanded = expandTilde(searchPath)
            guard let contents = try? FileManager.default.contentsOfDirectory(atPath: expanded) else {
                continue
            }

            for entry in contents {
                let skillDir = expanded + "/" + entry
                let skillFile = skillDir + "/SKILL.md"

                var isDir: ObjCBool = false
                guard FileManager.default.fileExists(atPath: skillDir, isDirectory: &isDir),
                      isDir.boolValue,
                      FileManager.default.fileExists(atPath: skillFile)
                else {
                    continue
                }

                let rawContent = (try? String(contentsOfFile: skillFile, encoding: .utf8)) ?? ""
                let (meta, _) = Self.parseFrontmatter(rawContent)
                let skillName = meta["name"] as? String ?? entry

                if skillName == name || entry == name {
                    try newContent.write(toFile: skillFile, atomically: true, encoding: .utf8)
                    return
                }
            }
        }

        throw SkillError.notFound(name)
    }

    // MARK: - Frontmatter Parsing

    /// Parse YAML frontmatter and body from a markdown document.
    ///
    /// Splits on `---` delimiters. If the document starts with `---`, everything between
    /// the opening and closing `---` is treated as YAML frontmatter. Everything after the
    /// closing delimiter is the body.
    ///
    /// Supported YAML types:
    /// - Strings: `key: value`
    /// - Arrays: `key: [a, b, c]` (inline bracket syntax only)
    ///
    /// - Parameter content: Raw file contents.
    /// - Returns: A tuple of `(metadata dictionary, body string)`.
    public static func parseFrontmatter(_ content: String) -> ([String: Any], String) {
        let lines = content.components(separatedBy: "\n")

        guard lines.first?.trimmingCharacters(in: .whitespaces) == "---" else {
            return ([:], content)
        }

        var closingIndex: Int?
        for i in 1 ..< lines.count {
            if lines[i].trimmingCharacters(in: .whitespaces) == "---" {
                closingIndex = i
                break
            }
        }

        guard let closing = closingIndex else {
            return ([:], content)
        }

        let frontmatterLines = Array(lines[1 ..< closing])
        let bodyLines = Array(lines[(closing + 1)...])
        let body = bodyLines.joined(separator: "\n")

        var meta: [String: Any] = [:]
        for line in frontmatterLines {
            guard let colonIdx = line.firstIndex(of: ":") else { continue }
            let key = String(line[line.startIndex ..< colonIdx]).trimmingCharacters(in: .whitespaces)
            let rawValue = String(line[line.index(after: colonIdx)...]).trimmingCharacters(in: .whitespaces)

            if rawValue.hasPrefix("["), rawValue.hasSuffix("]") {
                let inner = String(rawValue.dropFirst().dropLast())
                let items = inner.components(separatedBy: ",")
                    .map { $0.trimmingCharacters(in: .whitespaces) }
                    .filter { !$0.isEmpty }
                meta[key] = items
            } else {
                meta[key] = rawValue
            }
        }

        return (meta, body)
    }

    // MARK: - Skill Lookup Helpers

    /// Find the first skill entry matching a name (by frontmatter name or directory name).
    ///
    /// - Parameter name: The skill name to match.
    /// - Returns: The matching ``SkillEntry``, or `nil` if not found.
    private func findSkillEntry(named name: String) -> SkillEntry? {
        allSkillEntries().first { $0.name == name || $0.directoryName == name }
    }

    /// Enumerate all valid skill entries across all search paths.
    ///
    /// Iterates each search path, reading each subdirectory's `SKILL.md` and parsing
    /// its frontmatter. Entries are returned in directory-sorted order within each path,
    /// with earlier search paths appearing first.
    ///
    /// - Returns: All discovered skill entries (may contain duplicate names across paths).
    private func allSkillEntries() -> [SkillEntry] {
        var entries: [SkillEntry] = []

        for searchPath in searchPaths {
            let expanded = expandTilde(searchPath)
            guard let contents = try? FileManager.default.contentsOfDirectory(atPath: expanded) else {
                continue
            }

            for dirName in contents.sorted() {
                let skillDir = expanded + "/" + dirName
                let skillFile = skillDir + "/SKILL.md"

                var isDir: ObjCBool = false
                guard FileManager.default.fileExists(atPath: skillDir, isDirectory: &isDir),
                      isDir.boolValue,
                      FileManager.default.fileExists(atPath: skillFile),
                      let rawContent = try? String(contentsOfFile: skillFile, encoding: .utf8)
                else {
                    continue
                }

                let (meta, _) = Self.parseFrontmatter(rawContent)
                entries.append(SkillEntry(
                    directoryName: dirName,
                    directoryPath: skillDir,
                    name: meta["name"] as? String ?? dirName,
                    metadata: meta,
                    rawContent: rawContent,
                ))
            }
        }

        return entries
    }

    // MARK: - Helpers

    /// Expand a leading `~` to the home directory.
    private func expandTilde(_ path: String) -> String {
        if path.hasPrefix("~/") {
            return NSHomeDirectory() + String(path.dropFirst())
        } else if path == "~" {
            return NSHomeDirectory()
        }
        return path
    }

    /// Parse the `when` frontmatter value into activation conditions.
    ///
    /// Handles three forms:
    /// - Single string: `"*.swift"` → `[.filePattern("*.swift")]`
    /// - Keyword string: `keyword("deploy")` → `[.keyword("deploy")]`
    /// - Array: `["*.swift", "keyword(test)"]` → `[.filePattern("*.swift"), .keyword("test")]`
    /// - `nil` → `[]`
    ///
    /// - Parameter value: The raw frontmatter value (String or [String]).
    /// - Returns: Parsed activation conditions.
    static func parseWhenConditions(_ value: Any?) -> [ActivationCondition] {
        guard let value else { return [] }

        if let single = value as? String {
            return [parseSingleCondition(single)]
        }

        if let array = value as? [String] {
            return array.map { parseSingleCondition($0) }
        }

        return []
    }

    /// Parse a single condition string into an ``ActivationCondition``.
    ///
    /// Recognizes `keyword(...)` syntax; everything else is treated as a file pattern glob.
    ///
    /// - Parameter raw: The raw condition string.
    /// - Returns: The parsed condition.
    private static func parseSingleCondition(_ raw: String) -> ActivationCondition {
        let trimmed = raw.trimmingCharacters(in: .whitespaces)

        if trimmed.hasPrefix("keyword("), trimmed.hasSuffix(")") {
            let inner = String(trimmed.dropFirst("keyword(".count).dropLast())
                .trimmingCharacters(in: CharacterSet(charactersIn: "\"' "))
            return .keyword(inner)
        }

        return .filePattern(trimmed)
    }

    /// Test if a filename matches a simple glob pattern.
    ///
    /// Supports `*` as a wildcard that matches any sequence of characters.
    /// The match is performed against the filename only (not the full path).
    ///
    /// - Parameters:
    ///   - fileName: The filename to test (e.g., `"MyView.swift"`).
    ///   - pattern: The glob pattern (e.g., `"*.swift"`).
    /// - Returns: Whether the filename matches the pattern.
    static func matchesGlob(fileName: String, pattern: String) -> Bool {
        let regexPattern = "^"
            + pattern
            .replacingOccurrences(of: ".", with: "\\.")
            .replacingOccurrences(of: "*", with: ".*")
            + "$"

        return fileName.range(of: regexPattern, options: .regularExpression, range: nil, locale: nil) != nil
    }
}

// MARK: - Errors

/// Errors thrown by ``SkillManager`` operations.
public enum SkillError: Error, Sendable, CustomStringConvertible {
    /// No skill with the given name was found in any search path.
    case notFound(String)

    public var description: String {
        switch self {
        case let .notFound(name):
            "Skill '\(name)' not found"
        }
    }
}
