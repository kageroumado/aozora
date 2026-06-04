import Foundation

/// Apply unified diff patches to one or more files.
///
/// Wraps `/usr/bin/patch` with `-p1 --batch --fuzz=0` semantics. Multi-file and
/// multi-hunk patches are handled transparently by the underlying `patch` binary.
/// The tool writes the patch content to a temporary file, invokes `patch`, and
/// reports which files were modified (extracted from `+++ b/` headers in the diff).
///
/// The `working_directory` passed at execution time becomes the current directory
/// for the `patch` invocation, so relative paths in the diff are resolved there.
public nonisolated struct PatchTool: ToolExecutable {
    /// The unique tool name used in model tool calls.
    public let name = "patch"

    public var definition: ToolDefinition {
        ToolDefinition(
            name: "patch",
            description: """
            Apply a unified diff patch to one or more files. Supports multi-file and \
            multi-hunk patches. The patch must be in unified diff format (as produced by \
            `git diff` or `diff -u`). Uses /usr/bin/patch with -p1 strip, strict context \
            matching (--fuzz=0), and no interactive prompts (--batch).
            """,
            parameters: [
                ToolParameter(
                    name: "patch",
                    type: .string,
                    description: "Unified diff patch content to apply",
                ),
            ],
        )
    }

    public func execute(parameters: sending [String: Any], workingDirectory: String) async throws -> ToolResult {
        let patchContent = try requireString("patch", from: parameters)

        // Write patch to a temporary file; cleaned up on scope exit.
        // BSD patch requires the diff file to end with a newline — append one if missing.
        let normalizedPatch = patchContent.hasSuffix("\n") ? patchContent : patchContent + "\n"
        let tmpPath = NSTemporaryDirectory() + "aozora-patch-\(UUID().uuidString).diff"
        defer { try? FileManager.default.removeItem(atPath: tmpPath) }

        do {
            try normalizedPatch.write(toFile: tmpPath, atomically: true, encoding: .utf8)
        } catch {
            throw ToolError.executionFailed("Failed to write temporary patch file: \(error.localizedDescription)")
        }

        // Run /usr/bin/patch with strict options:
        //   -p1           strip one leading path component (a/ and b/ prefixes)
        //   --batch       never prompt; fail on ambiguity
        //   --fuzz=0      disallow context fuzzing (exact match required)
        //   -i <file>     read from file rather than stdin
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/patch")
        process.arguments = ["-p1", "--batch", "--fuzz=0", "-i", tmpPath]
        process.currentDirectoryURL = URL(fileURLWithPath: workingDirectory)

        let outPipe = Pipe()
        let errPipe = Pipe()
        process.standardOutput = outPipe
        process.standardError = errPipe

        do {
            try process.run()
        } catch {
            throw ToolError.executionFailed("Failed to launch /usr/bin/patch: \(error.localizedDescription)")
        }

        process.waitUntilExit()

        let stdoutData = outPipe.fileHandleForReading.readDataToEndOfFile()
        let stderrData = errPipe.fileHandleForReading.readDataToEndOfFile()
        let stdout = String(data: stdoutData, encoding: .utf8) ?? ""
        let stderr = String(data: stderrData, encoding: .utf8) ?? ""

        let exitCode = process.terminationStatus

        if exitCode != 0 {
            let combined = [stdout, stderr].filter { !$0.isEmpty }.joined(separator: "\n")
            return .failure("patch failed (exit \(exitCode)):\n\(combined)")
        }

        // Extract file paths from `+++ b/<path>` headers for a human-readable summary.
        let patchedFiles = extractPatchedFiles(from: patchContent)
        let summary = if patchedFiles.isEmpty {
            "Patch applied successfully."
        } else {
            "Patched \(patchedFiles.count) file(s): \(patchedFiles.joined(separator: ", "))"
        }

        return .success(summary)
    }

    /// Extract destination file paths from `+++ b/<path>` lines in the patch.
    ///
    /// - Parameter patch: The raw unified diff content.
    /// - Returns: An array of destination file paths, deduplicated and in order of appearance.
    private func extractPatchedFiles(from patch: String) -> [String] {
        var seen = Set<String>()
        var result: [String] = []

        for line in patch.components(separatedBy: "\n") {
            guard line.hasPrefix("+++ ") else { continue }
            var path = String(line.dropFirst(4))
            // Strip the `b/` prefix that git-style diffs add.
            if path.hasPrefix("b/") { path = String(path.dropFirst(2)) }
            // Skip /dev/null (new-file patches report /dev/null on the --- line, not +++).
            guard path != "/dev/null", !path.isEmpty else { continue }
            if seen.insert(path).inserted {
                result.append(path)
            }
        }

        return result
    }
}
