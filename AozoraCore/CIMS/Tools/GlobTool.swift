import Foundation

/// Fast file discovery with `.gitignore` awareness.
///
/// In git repositories, delegates to `git ls-files --cached --others --exclude-standard`
/// to naturally respect `.gitignore` rules. Outside git, falls back to `find` with
/// `-name` filtering. Results are sorted by modification time (newest first) and
/// truncated to ``maxResults``.
///
/// Supports both flat (`*.swift`) and recursive (`**/*.swift`) glob patterns.
/// The `path` parameter anchors the search root; defaults to the working directory.
public nonisolated struct GlobTool: ToolExecutable {
    public let name = "glob"

    /// Maximum number of paths returned in a single call.
    private static let maxResults = 200

    public var definition: ToolDefinition {
        ToolDefinition(
            name: "glob",
            description: "Find files matching a glob pattern. Returns up to 200 results sorted by modification time (newest first). Respects .gitignore in git repositories.",
            parameters: [
                ToolParameter(
                    name: "pattern",
                    type: .string,
                    description: "Glob pattern to match (e.g. '*.swift', '**/*.json')",
                ),
                ToolParameter(
                    name: "path",
                    type: .string,
                    description: "Directory to search in. Defaults to the working directory.",
                    optional: true,
                ),
            ],
        )
    }

    public func execute(parameters: sending [String: Any], workingDirectory: String) async throws -> ToolResult {
        let pattern = try requireString("pattern", from: parameters)

        let searchPath: String = if let pathParam = parameters["path"] as? String {
            resolvePath(pathParam, workingDirectory: workingDirectory)
        } else {
            workingDirectory
        }

        let isRecursive = pattern.contains("**/")
        let namePattern = (pattern as NSString).lastPathComponent

        let command = buildCommand(
            pattern: pattern,
            namePattern: namePattern,
            searchPath: searchPath,
            isRecursive: isRecursive,
        )

        let rawOutput = runShell(command: command, workingDirectory: searchPath)
        let paths = rawOutput
            .components(separatedBy: "\n")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }

        let sorted = sortByMtime(paths: paths, baseDirectory: searchPath)
        let truncated = Array(sorted.prefix(Self.maxResults))

        let suffix = sorted.count > Self.maxResults
            ? "\n(\(sorted.count - Self.maxResults) more results not shown)"
            : ""

        return .success(truncated.joined(separator: "\n") + suffix)
    }

    /// Build the shell command to list matching files, preferring git when available.
    ///
    /// - Parameters:
    ///   - pattern: The raw glob pattern from the caller.
    ///   - namePattern: The filename portion of the pattern (last path component).
    ///   - searchPath: The absolute directory to search.
    ///   - isRecursive: Whether the pattern spans multiple directory levels.
    /// - Returns: A `/bin/zsh -c` compatible command string.
    private func buildCommand(
        pattern: String,
        namePattern: String,
        searchPath: String,
        isRecursive: Bool,
    ) -> String {
        let escapedPath = shellEscape(searchPath)

        let gitCheck = "git -C \(escapedPath) rev-parse --git-dir > /dev/null 2>&1"

        if isRecursive {
            let gitCommand = "git -C \(escapedPath) ls-files --cached --others --exclude-standard | grep -E '\(globToRegex(pattern))'"
            let findCommand = "find \(escapedPath) -name \(shellEscape(namePattern)) -type f"
            return "\(gitCheck) && \(gitCommand) || \(findCommand)"
        } else {
            let escapedName = shellEscape(namePattern)
            let gitCommand = "git -C \(escapedPath) ls-files --cached --others --exclude-standard | xargs -I{} basename {} | grep -Fx \(escapedName) | xargs -I{} find \(escapedPath) -maxdepth 1 -name {} -type f"
            let findCommand = "find \(escapedPath) -maxdepth 1 -name \(escapedName) -type f"
            return "\(gitCheck) && \(gitCommand) || \(findCommand)"
        }
    }

    /// Run a shell command synchronously via `/bin/zsh -c` and return stdout.
    ///
    /// - Parameters:
    ///   - command: The shell command to execute.
    ///   - workingDirectory: The directory to set as the process current directory.
    /// - Returns: Raw stdout string from the command.
    private func runShell(command: String, workingDirectory: String) -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/zsh")
        process.arguments = ["-c", command]
        process.currentDirectoryURL = URL(fileURLWithPath: workingDirectory)

        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = Pipe()

        do {
            try process.run()
        } catch {
            return ""
        }

        process.waitUntilExit()

        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        return String(data: data, encoding: .utf8) ?? ""
    }

    /// Sort a list of paths by modification time, newest first.
    ///
    /// Paths that are relative are resolved against `baseDirectory` for the attribute
    /// lookup but returned in their original form.
    ///
    /// - Parameters:
    ///   - paths: File paths to sort.
    ///   - baseDirectory: Prefix for resolving relative paths.
    /// - Returns: Paths sorted descending by mtime.
    private func sortByMtime(paths: [String], baseDirectory: String) -> [String] {
        let fileManager = FileManager.default

        let dated: [(path: String, mtime: Date)] = paths.map { path in
            let resolved = path.hasPrefix("/") ? path : (baseDirectory as NSString).appendingPathComponent(path)
            let attrs = try? fileManager.attributesOfItem(atPath: resolved)
            let mtime = attrs?[.modificationDate] as? Date ?? Date.distantPast
            return (path: path, mtime: mtime)
        }

        return dated
            .sorted { $0.mtime > $1.mtime }
            .map(\.path)
    }

    /// Shell-escape a path by wrapping in single quotes and escaping interior single quotes.
    ///
    /// - Parameter path: The path to escape.
    /// - Returns: A single-quoted shell-safe string.
    private func shellEscape(_ path: String) -> String {
        "'" + path.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    /// Convert a glob pattern's `**` portion to a basic regex for `grep -E` filtering.
    ///
    /// This is a best-effort conversion used to filter `git ls-files` output against
    /// recursive glob patterns. It handles `**/` (any depth prefix), `*.ext` suffixes,
    /// and literal path segments.
    ///
    /// - Parameter pattern: The glob pattern (e.g., `**/*.swift`).
    /// - Returns: An ERE pattern suitable for `grep -E`.
    private func globToRegex(_ pattern: String) -> String {
        var result = ""
        var i = pattern.startIndex

        while i < pattern.endIndex {
            let c = pattern[i]
            switch c {
            case "*":
                let next = pattern.index(after: i)
                if next < pattern.endIndex, pattern[next] == "*" {
                    let afterStar = pattern.index(after: next)
                    if afterStar < pattern.endIndex, pattern[afterStar] == "/" {
                        result += ".*"
                        i = afterStar
                    } else {
                        result += ".*"
                        i = next
                    }
                } else {
                    result += "[^/]*"
                }
            case "?":
                result += "[^/]"
            case ".", "+", "^", "$", "{", "}", "(", ")", "[", "]", "|", "\\":
                result += "\\\(c)"
            default:
                result.append(c)
            }
            i = pattern.index(after: i)
        }

        return result + "$"
    }
}
