import Foundation

/// Execute shell commands via `/bin/zsh`.
///
/// Captures combined stdout/stderr output, enforces a configurable timeout,
/// and truncates output to prevent context bloat (50 KB or 2000 lines, whichever
/// comes first). When `background: true`, spawns the process detached and returns
/// immediately with a process ID; the ``ProcessMonitor`` streams output and posts
/// a completion event when the process exits.
///
/// Before execution, every command passes through ``DestructiveCommandGuard``. Simple
/// `rm` invocations are automatically rewritten to `trash`; complex destructive commands
/// are blocked with a clear error. Use `trash <path>` to move files to Trash instead.
///
/// Uses Foundation `Process` for execution — no dependency on external libraries.
public nonisolated struct BashTool: ToolExecutable {
    public let name = "bash"

    /// The process monitor for background process tracking. `nil` disables background mode.
    public let processMonitor: ProcessMonitor?

    /// Optional persistent shell session for foreground commands.
    ///
    /// When provided, foreground commands run in a persistent shell that preserves
    /// environment variables, working directory, and venv activations across calls.
    /// When `nil`, each command spawns a fresh `/bin/zsh -c` process (original behavior).
    public let shellSession: ShellSession?

    /// Creates a `BashTool`, optionally wired to a ``ProcessMonitor`` and ``ShellSession``.
    ///
    /// - Parameters:
    ///   - processMonitor: The monitor used to track background processes.
    ///     When `nil`, `background: true` requests return an error.
    ///   - shellSession: Persistent shell for foreground commands.
    ///     When `nil`, each command spawns a fresh process.
    public init(processMonitor: ProcessMonitor? = nil, shellSession: ShellSession? = nil) {
        self.processMonitor = processMonitor
        self.shellSession = shellSession
    }

    /// Maximum output size in bytes before truncation.
    private static let maxOutputBytes = 50_000

    /// Maximum number of output lines before truncation.
    private static let maxOutputLines = 2_000

    /// Default timeout in milliseconds (5 minutes).
    private static let defaultTimeoutMs = 300_000

    public var definition: ToolDefinition {
        ToolDefinition(
            name: "bash",
            description: """
            Execute a shell command. For commands expected to take more than a few minutes \
            (ML training, large builds, long scripts), use background: true — this returns \
            immediately with a process ID. Use check_process to monitor output, kill_process to stop. \
            IMPORTANT: rm, shred, unlink, and find -delete are not available. Use 'trash <path>' \
            to delete files and directories (moves to Trash, recoverable). 'git rm' is allowed.
            """,
            parameters: [
                ToolParameter(name: "command", type: .string, description: "The shell command to execute"),
                ToolParameter(
                    name: "timeout",
                    type: .integer,
                    description: "Timeout in milliseconds (default: 300000 = 5 min). For longer commands, use background: true instead",
                    optional: true,
                ),
                ToolParameter(
                    name: "workdir",
                    type: .string,
                    description: "Working directory for the command",
                    optional: true,
                ),
                ToolParameter(
                    name: "background",
                    type: .boolean,
                    description: "Run in background and return immediately with a process ID. Use for long-running commands. Monitor with check_process, stop with kill_process. Default: false",
                    optional: true,
                ),
            ],
        )
    }

    public func execute(parameters: sending [String: Any], workingDirectory: String) async throws -> ToolResult {
        let command = try requireString("command", from: parameters)

        var effectiveCommand = command
        switch DestructiveCommandGuard.check(command) {
        case .allowed:
            break
        case let .rewrite(safeCommand):
            Log.info("bash", "Rewriting destructive command to: \(safeCommand)")
            effectiveCommand = safeCommand
        case let .blocked(reason):
            return .failure(
                "BLOCKED: \(reason)\n\nUse 'trash <path>' to move files to Trash (recoverable). Example: trash old-build/\n\n'git rm' is allowed for tracked files.",
            )
        }

        let timeoutMs = (parameters["timeout"] as? Int) ?? Self.defaultTimeoutMs
        let workdir = (parameters["workdir"] as? String) ?? workingDirectory

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/zsh")
        process.arguments = ["-c", effectiveCommand]
        process.currentDirectoryURL = URL(fileURLWithPath: workdir)

        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe

        let background = (parameters["background"] as? Bool) ?? false

        if background {
            guard let monitor = processMonitor else {
                throw ToolError.executionFailed("Background execution not available (no ProcessMonitor configured)")
            }
            do {
                try process.run()
            } catch {
                throw ToolError.executionFailed("Failed to launch process: \(error.localizedDescription)")
            }
            let processId = "proc-\(Int(Date().timeIntervalSince1970 * 1_000))"
            await monitor.register(process, id: processId, command: String(command.prefix(200)))
            return .success(
                "Process started in background (id: \(processId)). Use check_process to monitor, kill_process to stop.",
            )
        }

        // Persistent shell path — preserves env/cd/venvs across commands
        if let shellSession {
            await ActiveToolOutput.shared.start(tool: "bash", command: String(command.prefix(200)))
            do {
                let (rawOutput, exitCode) = try await shellSession.execute(
                    command: effectiveCommand,
                    workdir: workdir,
                    timeoutMs: timeoutMs,
                )
                await ActiveToolOutput.shared.finish()

                let truncated = Self.truncateOutput(rawOutput)
                let output = """
                Exit code: \(exitCode)
                \(truncated)
                """
                return ToolResult(content: output, isError: exitCode != 0)
            } catch is ShellError {
                await ActiveToolOutput.shared.finish()
                return ToolResult(
                    content: "Command timed out after \(timeoutMs)ms",
                    isError: true,
                )
            } catch {
                await ActiveToolOutput.shared.finish()
                throw error
            }
        }

        // Fallback: per-command process spawning (original behavior)
        let outputAccumulator = OutputAccumulator()
        pipe.fileHandleForReading.readabilityHandler = { handle in
            let data = handle.availableData
            guard !data.isEmpty else { return }
            outputAccumulator.append(data)
            if let text = String(data: data, encoding: .utf8) {
                Task { await ActiveToolOutput.shared.appendOutput(text) }
            }
        }

        await ActiveToolOutput.shared.start(tool: "bash", command: String(command.prefix(200)))

        do {
            try process.run()
        } catch {
            await ActiveToolOutput.shared.finish()
            throw ToolError.executionFailed("Failed to launch process: \(error.localizedDescription)")
        }

        let timeoutNs = UInt64(timeoutMs) * 1_000_000
        let didTimeout = await waitForProcess(process, timeoutNanoseconds: timeoutNs)

        // Stop the readability handler and collect remaining output
        pipe.fileHandleForReading.readabilityHandler = nil
        await ActiveToolOutput.shared.finish()

        if didTimeout {
            process.terminate()
            return .failure("Command timed out after \(timeoutMs)ms")
        }

        // Collect any remaining data
        let remainingData = pipe.fileHandleForReading.readDataToEndOfFile()
        outputAccumulator.append(remainingData)

        let rawOutput = outputAccumulator.string
        let truncated = Self.truncateOutput(rawOutput)
        let exitCode = process.terminationStatus

        let output = """
        Exit code: \(exitCode)
        \(truncated)
        """

        if exitCode == 0 {
            return .success(output)
        } else {
            return .failure(output)
        }
    }

    /// Wait for a process to exit, with timeout and cooperative cancellation support.
    ///
    /// Returns `true` if the timeout was reached OR the Task was cancelled.
    /// In both cases, the process is terminated by the caller.
    ///
    /// Uses `terminationHandler` for completion + `Task.sleep` for timeout so
    /// the cooperative thread pool is never blocked.
    private func waitForProcess(_ process: Process, timeoutNanoseconds: UInt64) async -> Bool {
        await withTaskCancellationHandler {
            await withCheckedContinuation { (continuation: CheckedContinuation<Bool, Never>) in
                let once = _WaitOnce(continuation: continuation)

                process.terminationHandler = { _ in
                    once.resume(returning: false)
                }

                // Guard against the process having already exited before the
                // handler was installed — terminationHandler is not called retroactively.
                if !process.isRunning {
                    once.resume(returning: false)
                }

                // Timeout via a detached task so we don't inherit the caller's actor.
                Task.detached {
                    try? await Task.sleep(nanoseconds: timeoutNanoseconds)
                    once.resume(returning: true)
                }
            }
        } onCancel: {
            process.terminate()
        }
    }

    /// Truncate output to fit within size and line limits.
    public static func truncateOutput(_ output: String) -> String {
        let lines = output.components(separatedBy: "\n")
        var result: [String] = []
        var byteCount = 0

        for line in lines {
            if result.count >= maxOutputLines { break }
            let lineBytes = line.utf8.count + 1
            if byteCount + lineBytes > maxOutputBytes { break }
            result.append(line)
            byteCount += lineBytes
        }

        if result.count < lines.count {
            result.append("... (output truncated)")
        }

        return result.joined(separator: "\n")
    }
}

import os

/// Ensures a `CheckedContinuation` is resumed exactly once.
///
/// Both `terminationHandler` and the timeout task race to resume;
/// the lock guarantees only the first caller wins.
private final class _WaitOnce: Sendable {
    private let state = OSAllocatedUnfairLock<CheckedContinuation<Bool, Never>?>(initialState: nil)

    init(continuation: CheckedContinuation<Bool, Never>) {
        state.withLock { $0 = continuation }
    }

    func resume(returning value: Bool) {
        let c = state.withLock { state -> CheckedContinuation<Bool, Never>? in
            let c = state
            state = nil
            return c
        }
        c?.resume(returning: value)
    }
}

/// Thread-safe data accumulator for process output.
///
/// The pipe's `readabilityHandler` runs on arbitrary threads, so we need
/// a lock-protected buffer to collect data chunks.
private final class OutputAccumulator: Sendable {
    private let storage = OSAllocatedUnfairLock(initialState: Data())

    func append(_ chunk: Data) {
        storage.withLock { $0.append(chunk) }
    }

    var string: String {
        storage.withLock { String(data: $0, encoding: .utf8) ?? "" }
    }
}
