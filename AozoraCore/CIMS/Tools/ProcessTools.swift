import Foundation

// MARK: - CheckProcessTool

/// Retrieves the current status and recent output of a background process.
///
/// The agent uses this tool to poll a process launched with `background: true` in
/// the `bash` tool. Returns the lifecycle status, wall-clock elapsed time, and the
/// last 50 lines of combined stdout/stderr captured by ``ProcessMonitor``.
///
/// Returns an error result when no process with the given ID is registered.
public nonisolated struct CheckProcessTool: ToolExecutable {
    /// The process monitor that tracks background processes.
    private let monitor: ProcessMonitor

    /// The unique tool name used by the model to invoke this tool.
    public let name = "check_process"

    /// Creates a check process tool backed by the given monitor.
    ///
    /// - Parameter monitor: The ``ProcessMonitor`` actor to query.
    public init(monitor: ProcessMonitor) {
        self.monitor = monitor
    }

    /// The schema definition sent to the model during inference.
    public var definition: ToolDefinition {
        ToolDefinition(
            name: "check_process",
            description: """
            Check the status and recent output of a background process launched with bash \
            (background: true). Returns status, elapsed time, and the last 50 lines of output.
            """,
            parameters: [
                ToolParameter(
                    name: "process_id",
                    type: .string,
                    description: "The process ID returned when the background process was launched",
                ),
            ],
        )
    }

    /// Queries ``ProcessMonitor`` for the given process and formats its status.
    ///
    /// - Parameters:
    ///   - parameters: Must contain `process_id` (String).
    ///   - workingDirectory: Unused — process lookup is by ID only.
    /// - Returns: A ``ToolResult`` with status, elapsed time, and tail output, or an error
    ///   result if the process ID is not registered.
    /// - Throws: ``ToolError/invalidParameters(_:)`` when `process_id` is missing.
    public func execute(parameters: sending [String: Any], workingDirectory _: String) async throws -> ToolResult {
        let processId = try requireString("process_id", from: parameters)

        guard let result = await monitor.checkProcess(processId) else {
            return .failure("No process found with ID '\(processId)'")
        }

        let statusLabel = statusDescription(result.status)
        let elapsedLabel = formatDuration(result.elapsed)
        let output = result.output.isEmpty ? "(no output yet)" : result.output

        let content = """
        Process ID: \(processId)
        Status: \(statusLabel)
        Elapsed: \(elapsedLabel)
        Output (last 50 lines):
        \(output)
        """

        return .success(content)
    }
}

// MARK: - KillProcessTool

/// Sends SIGTERM to a background process and marks it as killed in the registry.
///
/// If the process does not respond to SIGTERM within 5 seconds, ``ProcessMonitor``
/// escalates to SIGKILL automatically. Returns an error result when the process ID
/// is not registered or the process is not currently running.
public nonisolated struct KillProcessTool: ToolExecutable {
    /// The process monitor that tracks background processes.
    private let monitor: ProcessMonitor

    /// The unique tool name used by the model to invoke this tool.
    public let name = "kill_process"

    /// Creates a kill process tool backed by the given monitor.
    ///
    /// - Parameter monitor: The ``ProcessMonitor`` actor to use for termination.
    public init(monitor: ProcessMonitor) {
        self.monitor = monitor
    }

    /// The schema definition sent to the model during inference.
    public var definition: ToolDefinition {
        ToolDefinition(
            name: "kill_process",
            description: """
            Terminate a background process by ID. Sends SIGTERM immediately; escalates to \
            SIGKILL after 5 seconds if the process does not exit. Returns an error if the \
            process is not found or is no longer running.
            """,
            parameters: [
                ToolParameter(
                    name: "process_id",
                    type: .string,
                    description: "The process ID of the background process to terminate",
                ),
            ],
        )
    }

    /// Terminates the process with the given ID via ``ProcessMonitor/killProcess(_:)``.
    ///
    /// - Parameters:
    ///   - parameters: Must contain `process_id` (String).
    ///   - workingDirectory: Unused — process lookup is by ID only.
    /// - Returns: A success result confirming termination, or an error result if the
    ///   process ID is not registered or the process is not running.
    /// - Throws: ``ToolError/invalidParameters(_:)`` when `process_id` is missing.
    public func execute(parameters: sending [String: Any], workingDirectory _: String) async throws -> ToolResult {
        let processId = try requireString("process_id", from: parameters)

        let killed = await monitor.killProcess(processId)

        if killed {
            return .success("Process '\(processId)' has been terminated (SIGTERM sent; SIGKILL escalation in 5s if needed).")
        } else {
            return .failure("No running process found with ID '\(processId)'. It may have already exited or the ID is invalid.")
        }
    }
}

// MARK: - ListProcessesTool

/// Lists all processes currently tracked by ``ProcessMonitor``.
///
/// Returns a formatted table of process IDs, commands, statuses, and elapsed times.
/// Includes processes in all states — running, completed, failed, and killed — since
/// ``ProcessMonitor`` retains completed entries until capacity eviction.
public nonisolated struct ListProcessesTool: ToolExecutable {
    /// The process monitor that tracks background processes.
    private let monitor: ProcessMonitor

    /// The unique tool name used by the model to invoke this tool.
    public let name = "list_processes"

    /// Creates a list processes tool backed by the given monitor.
    ///
    /// - Parameter monitor: The ``ProcessMonitor`` actor to query.
    public init(monitor: ProcessMonitor) {
        self.monitor = monitor
    }

    /// The schema definition sent to the model during inference.
    public var definition: ToolDefinition {
        ToolDefinition(
            name: "list_processes",
            description: """
            List all background processes currently tracked by the process monitor. \
            Shows process ID, command, status, and elapsed time for each entry.
            """,
            parameters: [],
        )
    }

    /// Retrieves all tracked processes and formats them as a readable list.
    ///
    /// - Parameters:
    ///   - parameters: No parameters required.
    ///   - workingDirectory: Unused.
    /// - Returns: A ``ToolResult`` with a formatted process list, or a message indicating
    ///   that no processes are currently tracked.
    public func execute(parameters _: sending [String: Any], workingDirectory _: String) async throws -> ToolResult {
        let processes = await monitor.listProcesses()

        if processes.isEmpty {
            return .success("No background processes are currently tracked.")
        }

        var lines = ["Background processes (\(processes.count)):"]
        for info in processes {
            let statusIcon = statusIcon(info.status)
            let statusLabel = statusDescription(info.status)
            let elapsedLabel = formatDuration(info.elapsed)
            let commandPreview = info.command.count > 60
                ? String(info.command.prefix(57)) + "..."
                : info.command
            lines.append("  \(statusIcon) [\(info.id)] \(commandPreview)")
            lines.append("     Status: \(statusLabel)  Elapsed: \(elapsedLabel)")
        }

        return .success(lines.joined(separator: "\n"))
    }
}

// MARK: - Shared Formatting Helpers

/// Returns a human-readable label for a ``ProcessMonitor/ProcessStatus``.
///
/// - Parameter status: The process lifecycle status to describe.
/// - Returns: A short label suitable for display in tool output.
private func statusDescription(_ status: ProcessMonitor.ProcessStatus) -> String {
    switch status {
    case .running:
        "Running"
    case let .completed(exitCode):
        exitCode == 0 ? "Completed (exit 0)" : "Completed (exit \(exitCode))"
    case let .failed(reason):
        "Failed: \(reason)"
    case .killed:
        "Killed"
    }
}

/// Returns a single-character status icon for compact list display.
///
/// - Parameter status: The process lifecycle status to represent.
/// - Returns: A symbol character indicating the current state.
private func statusIcon(_ status: ProcessMonitor.ProcessStatus) -> String {
    switch status {
    case .running:
        ">"
    case let .completed(exitCode):
        exitCode == 0 ? "+" : "!"
    case .failed:
        "x"
    case .killed:
        "-"
    }
}

/// Formats a `Duration` into a compact human-readable string.
///
/// Renders as seconds with one decimal place for durations under a minute,
/// and as `Xm Ys` for longer durations.
///
/// - Parameter duration: The elapsed duration to format.
/// - Returns: A short string like `"3.2s"` or `"2m 15s"`.
private func formatDuration(_ duration: Duration) -> String {
    let totalSeconds = Int(duration.components.seconds)
    if totalSeconds < 60 {
        let subsecond = Double(duration.components.attoseconds) / 1e18
        let secondsWithFraction = Double(totalSeconds) + subsecond
        return String(format: "%.1fs", secondsWithFraction)
    }
    let minutes = totalSeconds / 60
    let seconds = totalSeconds % 60
    return "\(minutes)m \(seconds)s"
}
