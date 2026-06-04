import Foundation

/// Tracks detached background processes independently of the turn lifecycle.
///
/// Processes are registered via ``register(_:id:command:)`` which starts a reader
/// task that accumulates stdout/stderr into a rolling 200 KB buffer. When the process
/// exits, a completion event is posted via the configured callback.
///
/// The actor enforces a maximum concurrent limit (``maxConcurrent``) by evicting the
/// oldest running process when capacity is exceeded. The agent interacts with monitored
/// processes via ``checkProcess(_:)``, ``killProcess(_:)``, and ``listProcesses()``
/// which are called from the corresponding tool implementations.
///
/// **Module boundary note:** ``ProcessCompletion`` is defined in `CIMSTypes.swift` and is
/// `Sendable`. The daemon sets a completion handler after construction via
/// ``setCompletionHandler(_:)``; `AozoraCore` never imports Daemon types directly.
public actor ProcessMonitor {
    // MARK: - Public Types

    /// The lifecycle state of a monitored process.
    public enum ProcessStatus: Sendable {
        /// The process is still running.
        case running
        /// The process exited with the given exit code.
        case completed(exitCode: Int32)
        /// The process could not be launched or encountered an I/O error.
        case failed(String)
        /// The process was terminated via ``killProcess(_:)``.
        case killed
    }

    /// A point-in-time snapshot of a monitored process for tool API responses.
    public struct ProcessInfo: Sendable {
        /// The unique identifier assigned at registration.
        public let id: String
        /// The command string that was launched.
        public let command: String
        /// The current lifecycle status.
        public let status: ProcessStatus
        /// Wall-clock elapsed time since the process was registered.
        public let elapsed: Duration
    }

    // MARK: - Private State

    /// A monitored process entry in the registry.
    private struct MonitoredProcess {
        /// Unique process identifier.
        let id: String
        /// The shell command that was launched.
        let command: String
        /// Rolling stdout/stderr lines (evicted from the front when ``outputByteCount`` exceeds limit).
        var outputLines: [String]
        /// Total bytes currently stored across all lines in ``outputLines``.
        var outputByteCount: Int
        /// Monotonic start instant.
        let startedAt: ContinuousClock.Instant
        /// Current lifecycle status.
        var status: ProcessStatus
        /// The background reader task. Cancelled on kill or eviction.
        let readerTask: Task<Void, Never>
        /// Unix process identifier extracted before the Task captures it.
        let pid: pid_t
        /// The underlying Foundation process, retained by the actor for status access.
        let process: Process

        /// The most recent `n` lines of output joined by newline.
        func tail(_ n: Int = 50) -> String {
            let lines = outputLines.suffix(n)
            return lines.joined(separator: "\n")
        }
    }

    /// Maximum output buffer size per process (200 KB).
    private static let maxOutputBytes = 200_000

    /// Directory for PID files that survive daemon crashes.
    private static let pidDir = NSHomeDirectory() + "/.aozora/pids"

    /// Keyed by the process ID string assigned at registration.
    private var registry: [String: MonitoredProcess] = [:]

    /// Maximum concurrent processes tracked simultaneously.
    private let maxConcurrent: Int

    /// Optional callback invoked on the actor when a process exits.
    ///
    /// The daemon sets this after construction so `AozoraCore` never imports Daemon types.
    private var onCompletion: (@Sendable (ProcessCompletion) async -> Void)?

    // MARK: - Initialization

    /// Creates a `ProcessMonitor` with the given concurrency cap.
    ///
    /// - Parameter maxConcurrent: Maximum number of processes tracked at once.
    ///   Defaults to ``CIMSDefaults/toolBackgroundMaxConcurrent``.
    public init(maxConcurrent: Int = CIMSDefaults.toolBackgroundMaxConcurrent) {
        self.maxConcurrent = maxConcurrent
    }

    // MARK: - Orphan Reaping

    /// Kill any processes left over from a previous daemon session.
    ///
    /// Reads PID files from `~/.aozora/pids/`, sends SIGTERM to each,
    /// waits briefly, then SIGKILL any survivors. Call this once at daemon startup
    /// before any new processes are registered.
    public static func reapOrphans() {
        let fm = FileManager.default
        let dir = pidDir
        guard let entries = try? fm.contentsOfDirectory(atPath: dir) else { return }

        for file in entries where file.hasSuffix(".pid") {
            let path = "\(dir)/\(file)"
            guard let contents = fm.contents(atPath: path),
                  let pidStr = String(data: contents, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines),
                  let pid = pid_t(pidStr)
            else {
                try? fm.removeItem(atPath: path)
                continue
            }

            // Check if the process is still alive (signal 0 = probe only).
            if kill(pid, 0) == 0 {
                print("[ProcessMonitor] Reaping orphaned process \(pid) (\(file))")
                kill(pid, SIGTERM)

                // Give it 2 seconds then SIGKILL.
                DispatchQueue.global().asyncAfter(deadline: .now() + 2) {
                    if kill(pid, 0) == 0 {
                        kill(pid, SIGKILL)
                    }
                }
            }

            try? fm.removeItem(atPath: path)
        }
    }

    // MARK: - Configuration

    /// Sets the closure invoked when a tracked process exits.
    ///
    /// Called by the daemon after construction. The closure receives a ``ProcessCompletion``
    /// value and may post it to the event queue for injection into the agent's next turn.
    ///
    /// - Parameter handler: An `async` `@Sendable` closure that handles the completion event.
    public func setCompletionHandler(_ handler: @escaping @Sendable (ProcessCompletion) async -> Void) {
        onCompletion = handler
    }

    // MARK: - Registration

    /// Register an already-launched `Process` for background monitoring.
    ///
    /// Starts a reader task that accumulates stdout/stderr into a rolling 200 KB buffer.
    /// If the registry is at capacity, the oldest running process is killed before the new
    /// entry is inserted.
    ///
    /// **Sendability constraint:** `Foundation.Process` is not `Sendable`. This method
    /// extracts the `FileHandle` and `pid_t` before spawning the reader `Task`, passing
    /// only those `Sendable` values into the closure. The `Process` itself stays in the
    /// actor's registry, accessed only from within actor-isolated methods.
    ///
    /// - Parameters:
    ///   - process: An already-running `Process`. Must have a combined stdout/stderr pipe
    ///     attached before calling this method.
    ///   - id: Unique string identifier for this process (assigned by the caller).
    ///   - command: Human-readable command string used in status reports.
    public func register(_ process: Process, id: String, command: String) {
        // Evict oldest running process if at capacity.
        if registry.count >= maxConcurrent {
            evictOldest()
        }

        // Extract Sendable values before creating the Task.
        // `Process` is NOT Sendable — never capture it in a Task body.
        let handle = (process.standardOutput as! Pipe).fileHandleForReading
        let pid = process.processIdentifier
        let processId = id

        let readerTask = Task { [weak self] in
            // Read until EOF, which Foundation signals via empty Data.
            while let data = try? handle.availableData, !data.isEmpty {
                if let text = String(data: data, encoding: .utf8) {
                    for line in text.components(separatedBy: .newlines) where !line.isEmpty {
                        await self?.appendOutput(id: processId, line: line)
                    }
                }
            }
            // EOF reached — the process has exited. Notify the actor.
            await self?.handleProcessExit(id: processId)
        }

        registry[id] = MonitoredProcess(
            id: id,
            command: command,
            outputLines: [],
            outputByteCount: 0,
            startedAt: ContinuousClock.now,
            status: .running,
            readerTask: readerTask,
            pid: pid,
            process: process,
        )

        Self.writePidFile(id: id, pid: pid)
    }

    // MARK: - Tool API

    /// Returns the current status, tail output, and elapsed time for a tracked process.
    ///
    /// Returns `nil` if no process with the given ID is registered.
    ///
    /// - Parameter id: The process ID assigned at registration.
    /// - Returns: A tuple of `(status, tailOutput, elapsed)`, or `nil` if not found.
    public func checkProcess(_ id: String) -> (status: ProcessStatus, output: String, elapsed: Duration)? {
        guard let entry = registry[id] else { return nil }
        let elapsed = ContinuousClock.now - entry.startedAt
        return (entry.status, entry.tail(), elapsed)
    }

    /// Sends `SIGTERM` to the process and schedules `SIGKILL` after 5 seconds if it persists.
    ///
    /// Updates the registry status to `.killed` immediately. The process may still be
    /// alive for up to 5 seconds if it catches SIGTERM. Returns `false` if no process
    /// with the given ID is registered or if the process is not currently running.
    ///
    /// - Parameter id: The process ID assigned at registration.
    /// - Returns: `true` if a running process was signalled, `false` otherwise.
    @discardableResult
    public func killProcess(_ id: String) -> Bool {
        guard var entry = registry[id], case .running = entry.status else {
            return false
        }

        let pid = entry.pid
        kill(pid, SIGTERM)
        entry.status = .killed
        registry[id] = entry

        // Schedule SIGKILL if the process is still alive after 5 seconds.
        Task {
            try? await Task.sleep(for: .seconds(5))
            // Only send SIGKILL if the process is still in our registry and marked killed
            // (meaning it hasn't naturally exited and been removed).
            if let current = self.registry[id], case .killed = current.status {
                kill(pid, SIGKILL)
            }
        }

        return true
    }

    /// Returns a snapshot of all currently tracked processes.
    ///
    /// Includes processes in any state — running, completed, failed, or killed.
    /// Completed/failed/killed processes remain in the registry until explicitly
    /// cleared (or until eviction under capacity pressure).
    ///
    /// - Returns: An array of ``ProcessInfo`` values, one per registered process.
    public func listProcesses() -> [ProcessInfo] {
        let now = ContinuousClock.now
        return registry.values.map { entry in
            ProcessInfo(
                id: entry.id,
                command: entry.command,
                status: entry.status,
                elapsed: now - entry.startedAt,
            )
        }
    }

    // MARK: - Internal Helpers

    /// Appends a single line to the output buffer, evicting from the front if over limit.
    private func appendOutput(id: String, line: String) {
        guard var entry = registry[id] else { return }
        let lineBytes = line.utf8.count + 1 // +1 for the newline separator
        entry.outputLines.append(line)
        entry.outputByteCount += lineBytes

        // Evict from the front until within budget.
        while entry.outputByteCount > Self.maxOutputBytes, !entry.outputLines.isEmpty {
            let oldest = entry.outputLines.removeFirst()
            entry.outputByteCount -= oldest.utf8.count + 1
        }

        registry[id] = entry
    }

    /// Called by the reader task when EOF is detected on the output pipe.
    ///
    /// Reads the process's termination status (safe because the actor serializes access
    /// to the stored `Process`), updates the registry, and fires the completion callback.
    private func handleProcessExit(id: String) async {
        guard var entry = registry[id] else { return }

        // Ensure the process is fully reaped before reading terminationStatus.
        // The reader task calls this after detecting EOF, so the process has already exited —
        // waitUntilExit() returns immediately and makes terminationStatus safe to access.
        // Without this, Foundation throws NSInvalidArgumentException if waitpid has not yet
        // been called, even when the process has exited and the pipe write end is closed.
        entry.process.waitUntilExit()

        // Read termination status from the stored Process reference.
        // This is actor-safe — we're the only path that touches entry.process after launch.
        let exitCode = entry.process.terminationStatus
        let elapsed = ContinuousClock.now - entry.startedAt

        // Only transition if still marked as running — a kill() call may have set .killed.
        if case .running = entry.status {
            entry.status = .completed(exitCode: exitCode)
        }

        let tailOutput = entry.tail()
        let command = entry.command
        let currentStatus = entry.status
        registry[id] = entry

        // Post the completion event to the daemon if a callback is configured.
        if let onCompletion {
            let completion = ProcessCompletion(
                processId: id,
                command: command,
                exitCode: exitCode,
                tailOutput: tailOutput,
                elapsed: elapsed,
            )
            await onCompletion(completion)
        }

        // Remove completed/failed processes from the registry to avoid unbounded growth.
        // Killed processes are also cleaned up here.
        switch currentStatus {
        case .completed, .failed, .killed:
            registry.removeValue(forKey: id)
            Self.removePidFile(id: id)
        case .running:
            break
        }
    }

    /// Evicts the oldest running process to make room for a new registration.
    ///
    /// Prefers evicting a running process over a completed one. If no running process
    /// exists, evicts the oldest entry regardless of status.
    private func evictOldest() {
        // Prefer to evict the oldest *running* process.
        let runningEntries = registry.values.filter { if case .running = $0.status { true } else { false } }
        let target = runningEntries.min(by: { $0.startedAt < $1.startedAt })
            ?? registry.values.min(by: { $0.startedAt < $1.startedAt })

        guard let target else { return }
        target.readerTask.cancel()
        kill(target.pid, SIGTERM)
        Self.removePidFile(id: target.id)
        registry.removeValue(forKey: target.id)
    }

    // MARK: - PID File Management

    private static func writePidFile(id: String, pid: pid_t) {
        let fm = FileManager.default
        try? fm.createDirectory(atPath: pidDir, withIntermediateDirectories: true)
        let path = "\(pidDir)/\(id).pid"
        try? "\(pid)".write(toFile: path, atomically: true, encoding: .utf8)
    }

    private static func removePidFile(id: String) {
        try? FileManager.default.removeItem(atPath: "\(pidDir)/\(id).pid")
    }
}
