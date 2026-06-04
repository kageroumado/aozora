import Foundation

/// Content search backed by ripgrep, with a graceful fallback to `grep -rn`.
///
/// Prefers `rg` (ripgrep) when installed because it respects `.gitignore`, handles
/// binary files gracefully, and is substantially faster on large trees. Falls back to
/// `/usr/bin/grep -rn` when ripgrep is not found.
///
/// Results are truncated at ``maxResults`` lines to prevent context bloat.
/// Paths in the output have the search root stripped for readability.
///
/// Supported parameters:
/// - `pattern` (required): The regex pattern to search for.
/// - `path` (optional): Directory or file to search. Defaults to the working directory.
/// - `include` (optional): Glob pattern to restrict which files are searched (e.g. `*.swift`).
/// - `context` (optional): Number of lines to show before and after each match.
///
/// Exit code semantics follow grep convention: 0 = matches found, 1 = no matches (not an
/// error), 2 = actual error.
public nonisolated struct GrepTool: ToolExecutable {
    public let name = "grep"

    /// Maximum number of output lines returned in a single call.
    private static let maxResults = 200

    /// Known ripgrep installation locations, checked in order.
    private static let rgCandidates = [
        "/opt/homebrew/bin/rg",
        "/usr/local/bin/rg",
        "/usr/bin/rg",
    ]

    public var definition: ToolDefinition {
        ToolDefinition(
            name: "grep",
            description: "Search file contents using ripgrep (falls back to grep). Returns up to 200 matching lines with file paths and line numbers.",
            parameters: [
                ToolParameter(
                    name: "pattern",
                    type: .string,
                    description: "Regular expression pattern to search for",
                ),
                ToolParameter(
                    name: "path",
                    type: .string,
                    description: "File or directory to search. Defaults to the working directory.",
                    optional: true,
                ),
                ToolParameter(
                    name: "include",
                    type: .string,
                    description: "Glob pattern to restrict which files are searched (e.g. '*.swift')",
                    optional: true,
                ),
                ToolParameter(
                    name: "context",
                    type: .integer,
                    description: "Number of lines of context to show before and after each match",
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

        let include = parameters["include"] as? String
        let context = parameters["context"] as? Int

        let (output, exitCode) = runSearch(
            pattern: pattern,
            path: searchPath,
            include: include,
            context: context,
        )

        if exitCode == 2 {
            return .failure("Error: grep/rg returned an error:\n\(output)")
        }

        if exitCode == 1 || output.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return .success("No matches found for pattern: \(pattern)")
        }

        let lines = output
            .components(separatedBy: "\n")
            .filter { !$0.isEmpty }

        let truncated = Array(lines.prefix(Self.maxResults))
        let suffix = lines.count > Self.maxResults
            ? "\n(\(lines.count - Self.maxResults) more lines not shown)"
            : ""

        let stripped = truncated
            .map { stripPathPrefix($0, prefix: searchPath) }
            .joined(separator: "\n")

        return .success(stripped + suffix)
    }

    /// Run the search command, preferring ripgrep, and return stdout + exit code.
    ///
    /// - Parameters:
    ///   - pattern: The regex pattern to search for.
    ///   - path: The file or directory to search.
    ///   - include: Optional glob filter for file names.
    ///   - context: Optional number of context lines.
    /// - Returns: A tuple of (stdout, exit code).
    private func runSearch(
        pattern: String,
        path: String,
        include: String?,
        context: Int?,
    ) -> (String, Int32) {
        if let rg = findRipgrep() {
            runRipgrep(rg, pattern: pattern, path: path, include: include, context: context)
        } else {
            runGrep(pattern: pattern, path: path, include: include, context: context)
        }
    }

    /// Find the first available ripgrep binary.
    ///
    /// - Returns: The absolute path to `rg`, or `nil` if not installed.
    private func findRipgrep() -> String? {
        Self.rgCandidates.first { FileManager.default.fileExists(atPath: $0) }
    }

    /// Run ripgrep with the given options.
    ///
    /// - Parameters:
    ///   - rgPath: Absolute path to the `rg` binary.
    ///   - pattern: The regex pattern to search for.
    ///   - path: The file or directory to search.
    ///   - include: Optional glob filter passed as `--glob`.
    ///   - context: Optional context line count passed as `-C`.
    /// - Returns: A tuple of (stdout, exit code).
    private func runRipgrep(
        _ rgPath: String,
        pattern: String,
        path: String,
        include: String?,
        context: Int?,
    ) -> (String, Int32) {
        var args: [String] = [
            "--line-number",
            "--no-heading",
            "--color=never",
            "--max-count=200",
        ]

        if let include {
            args += ["--glob", include]
        }

        if let context {
            args += ["-C", "\(context)"]
        }

        args += [pattern, path]

        return runProcess(executableURL: URL(fileURLWithPath: rgPath), arguments: args, workingDirectory: path)
    }

    /// Run `/usr/bin/grep -rn` as a fallback when ripgrep is not available.
    ///
    /// - Parameters:
    ///   - pattern: The regex pattern to search for.
    ///   - path: The file or directory to search.
    ///   - include: Optional glob filter passed as `--include`.
    ///   - context: Optional context line count passed as `-C`.
    /// - Returns: A tuple of (stdout, exit code).
    private func runGrep(
        pattern: String,
        path: String,
        include: String?,
        context: Int?,
    ) -> (String, Int32) {
        var args: [String] = ["-Ern", "--color=never"]

        if let include {
            args += ["--include=\(include)"]
        }

        if let context {
            args += ["-C", "\(context)"]
        }

        args += [pattern, path]

        return runProcess(executableURL: URL(fileURLWithPath: "/usr/bin/grep"), arguments: args, workingDirectory: path)
    }

    /// Launch a process synchronously and capture its stdout and exit code.
    ///
    /// - Parameters:
    ///   - executableURL: The binary to run.
    ///   - arguments: Command-line arguments.
    ///   - workingDirectory: Directory to set as the process's cwd.
    /// - Returns: A tuple of (stdout, exit code). Exit code 127 is returned on launch failure.
    private func runProcess(
        executableURL: URL,
        arguments: [String],
        workingDirectory: String,
    ) -> (String, Int32) {
        let process = Process()
        process.executableURL = executableURL
        process.arguments = arguments
        process.currentDirectoryURL = URL(fileURLWithPath: workingDirectory)

        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe

        do {
            try process.run()
        } catch {
            return ("", 127)
        }

        process.waitUntilExit()

        let stdoutData = stdoutPipe.fileHandleForReading.readDataToEndOfFile()
        let stderr = stderrPipe.fileHandleForReading.readDataToEndOfFile()
        let stdout = String(data: stdoutData, encoding: .utf8) ?? ""
        let stderrStr = String(data: stderr, encoding: .utf8) ?? ""

        let combined = stdout + (stderrStr.isEmpty ? "" : "\n" + stderrStr)
        return (combined, process.terminationStatus)
    }

    /// Strip a path prefix from a grep output line for cleaner presentation.
    ///
    /// Both `rg --no-heading` and `grep -rn` produce lines of the form:
    /// `path/to/file:line:content` (or `path/to/file-line-content` for context lines).
    /// When the path starts with the search root, the prefix (plus a `/` separator)
    /// is removed so only the relative path is shown.
    ///
    /// - Parameters:
    ///   - line: A raw output line from grep/rg.
    ///   - prefix: The search root path to strip.
    /// - Returns: The line with the prefix removed, or the original line if it doesn't match.
    private func stripPathPrefix(_ line: String, prefix: String) -> String {
        let normalized = prefix.hasSuffix("/") ? prefix : prefix + "/"
        if line.hasPrefix(normalized) {
            return String(line.dropFirst(normalized.count))
        }
        return line
    }
}
