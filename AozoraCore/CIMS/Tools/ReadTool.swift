import Foundation

/// Read file contents with line numbers, supporting offset/limit pagination.
///
/// If the path points to a directory, lists its contents instead. Output is
/// truncated to 50 KB to prevent context bloat.
///
/// When a ``FileAccessTracker`` is provided, successful file reads are recorded so that
/// ``EditTool`` and ``WriteTool`` can verify the file was read before modification.
public nonisolated struct ReadTool: ToolExecutable {
    public let name = "read"

    /// Maximum output size in bytes before truncation.
    private static let maxOutputBytes = 50_000

    /// Default maximum lines to read.
    private static let defaultLimit = 2_000

    /// Optional tracker for read-before-edit enforcement.
    private let tracker: FileAccessTracker?

    /// Create a read tool, optionally wired to a file access tracker.
    ///
    /// - Parameter tracker: If provided, successful file reads are recorded for
    ///   read-before-edit enforcement. Pass `nil` to disable tracking.
    public init(tracker: FileAccessTracker? = nil) {
        self.tracker = tracker
    }

    public var definition: ToolDefinition {
        ToolDefinition(
            name: "read",
            description: "Read file contents with line numbers. If path is a directory, lists its contents.",
            parameters: [
                ToolParameter(name: "file_path", type: .string, description: "Absolute or relative path to read"),
                ToolParameter(
                    name: "offset",
                    type: .integer,
                    description: "1-indexed line number to start from",
                    optional: true,
                ),
                ToolParameter(
                    name: "limit",
                    type: .integer,
                    description: "Maximum lines to read (default: 2000)",
                    optional: true,
                ),
            ],
        )
    }

    public func execute(parameters: sending [String: Any], workingDirectory: String) async throws -> ToolResult {
        let filePath = try requireString("file_path", from: parameters)
        let resolvedPath = resolvePath(filePath, workingDirectory: workingDirectory)

        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: resolvedPath, isDirectory: &isDirectory) else {
            return .failure("Error: File not found: \(resolvedPath)")
        }

        if isDirectory.boolValue {
            return try listDirectory(at: resolvedPath)
        }

        let offset = max(1, (parameters["offset"] as? Int) ?? 1)
        let limit = (parameters["limit"] as? Int) ?? Self.defaultLimit

        let result = try readFile(at: resolvedPath, offset: offset, limit: limit)

        if !result.isError, let tracker {
            let attrs = try? FileManager.default.attributesOfItem(atPath: resolvedPath)
            if let modDate = attrs?[.modificationDate] as? Date {
                await tracker.recordRead(path: resolvedPath, modificationDate: modDate)
            }
        }

        return result
    }

    /// Read a file with offset/limit, producing numbered output.
    private func readFile(at path: String, offset: Int, limit: Int) throws -> ToolResult {
        let data: Data
        do {
            data = try Data(contentsOf: URL(fileURLWithPath: path))
        } catch {
            return .failure("Error reading file: \(error.localizedDescription)")
        }

        guard let content = String(data: data, encoding: .utf8) else {
            return .failure("Error: File appears to be binary (not valid UTF-8)")
        }

        let allLines = content.components(separatedBy: "\n")
        let startIndex = min(offset - 1, allLines.count)
        let endIndex = min(startIndex + limit, allLines.count)

        var output = ""
        var byteCount = 0

        for i in startIndex ..< endIndex {
            let lineNumber = i + 1
            let line = "\(lineNumber)\t\(allLines[i])\n"
            let lineBytes = line.utf8.count
            if byteCount + lineBytes > Self.maxOutputBytes {
                output += "... (output truncated at 50KB)\n"
                break
            }
            output += line
            byteCount += lineBytes
        }

        if endIndex < allLines.count {
            output += "... (\(allLines.count - endIndex) more lines)\n"
        }

        return .success(output)
    }

    /// List directory contents.
    private func listDirectory(at path: String) throws -> ToolResult {
        let contents: [String]
        do {
            contents = try FileManager.default.contentsOfDirectory(atPath: path)
        } catch {
            return .failure("Error listing directory: \(error.localizedDescription)")
        }

        let sorted = contents.sorted()
        let listing = sorted.joined(separator: "\n")
        return .success("Directory: \(path)\n\(listing)")
    }
}
