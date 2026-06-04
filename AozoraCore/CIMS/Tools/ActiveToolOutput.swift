import Foundation

/// Shared buffer for the currently running tool's live output.
///
/// Tools write output here as it streams in. Status commands read
/// the last N lines to show what's happening right now. Thread-safe
/// via actor isolation.
public actor ActiveToolOutput {
    /// Singleton — one active tool at a time.
    public static let shared = ActiveToolOutput()

    private var currentTool: String?
    private var currentCommand: String?
    private var lines: [String] = []
    private var startedAt: ContinuousClock.Instant?
    private let maxLines = 50

    /// Mark a tool as active and start capturing output.
    public func start(tool: String, command: String) {
        currentTool = tool
        currentCommand = command
        lines = []
        startedAt = .now
    }

    /// Append raw output text (may contain multiple lines).
    public func appendOutput(_ text: String) {
        let newLines = text.components(separatedBy: "\n")
        for line in newLines where !line.isEmpty {
            lines.append(line)
            if lines.count > maxLines {
                lines.removeFirst()
            }
        }
    }

    /// Clear the active tool state.
    public func finish() {
        currentTool = nil
        currentCommand = nil
        lines = []
        startedAt = nil
    }

    /// Snapshot of the current state for status display.
    public func snapshot(lastLineCount: Int = 8) -> ToolOutputSnapshot? {
        guard let tool = currentTool else { return nil }
        let elapsed = startedAt.map { ContinuousClock.now - $0 }
        return ToolOutputSnapshot(
            tool: tool,
            command: currentCommand ?? "",
            lastLines: Array(lines.suffix(lastLineCount)),
            totalLines: lines.count,
            elapsed: elapsed,
        )
    }
}

/// Immutable snapshot of the active tool's output.
public struct ToolOutputSnapshot: Sendable {
    public let tool: String
    public let command: String
    public let lastLines: [String]
    public let totalLines: Int
    public let elapsed: Duration?

    /// Format for display (CLI or Discord).
    public func formatted() -> String {
        var parts: [String] = []
        let elapsedStr = elapsed.map { "\(Int($0.components.seconds))s" } ?? "?"
        parts.append("**\(tool)** (\(elapsedStr))")

        if !command.isEmpty {
            parts.append("```\n\(command.prefix(120))\n```")
        }

        if lastLines.isEmpty {
            parts.append("_(no output yet)_")
        } else {
            let output = lastLines.joined(separator: "\n")
            parts.append("```\n\(output.prefix(800))\n```")
            if totalLines > lastLines.count {
                parts.append("_(\(totalLines - lastLines.count) earlier lines truncated)_")
            }
        }

        return parts.joined(separator: "\n")
    }
}
