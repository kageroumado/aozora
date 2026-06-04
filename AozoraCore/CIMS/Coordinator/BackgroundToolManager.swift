import Foundation

/// Manages tool calls that have been moved to the background after exceeding
/// their execution timeout.
///
/// Tracks running background tasks and collects completed results for injection
/// into the next tool loop iteration. Tasks are never force-cancelled by the manager
/// itself — only by stop words or turn completion. Instead, escalating warnings are
/// emitted at 5min, 15min, then every 30min to inform the model.
///
/// **Completion detection:** Each registered task gets a wrapper `Task` that writes
/// the result to the actor when the tool completes. `collectCompleted()` checks
/// `result != nil` for non-blocking detection. There may be a one-iteration delay
/// between actual completion and detection — this is by design and harmless.
actor BackgroundToolManager {
    /// A running background tool task with completion signal.
    struct RunningTask {
        let info: BackgroundToolInfo
        let task: Task<Void, Never>
        var result: ToolResult?
        var lastWarningAt: ContinuousClock.Instant?
    }

    /// Warning thresholds: warn at 5min, 15min, then every 30min.
    private static let warningSchedule: [Duration] = [
        .seconds(300), // 5 min
        .seconds(900), // 15 min
    ]

    /// After the initial schedule, warn every 30 minutes.
    private static let recurringWarningInterval: Duration = .seconds(1_800)

    private var tasks: [String: RunningTask] = [:]
    private let maxConcurrent: Int

    init(maxConcurrent: Int = CIMSDefaults.toolBackgroundMaxConcurrent) {
        self.maxConcurrent = maxConcurrent
    }

    /// Register a backgrounded tool task.
    ///
    /// Creates a wrapper Task that awaits the tool result and writes it to the actor.
    /// If the concurrent limit is exceeded, the oldest task is cancelled.
    func register(_ info: BackgroundToolInfo, toolTask: Task<ToolResult, Never>) {
        if tasks.count >= maxConcurrent,
           let oldest = tasks.values.min(by: { $0.info.startedAt < $1.info.startedAt }) {
            oldest.task.cancel()
            tasks.removeValue(forKey: oldest.info.toolCallId)
        }

        let wrappedTask = Task { [weak self] in
            let result = await toolTask.value
            await self?.setResult(for: info.toolCallId, result: result)
        }
        tasks[info.toolCallId] = RunningTask(info: info, task: wrappedTask, result: nil)
    }

    private func setResult(for id: String, result: ToolResult) {
        tasks[id]?.result = result
    }

    /// Collect results from completed background tasks (non-blocking).
    ///
    /// Returns completed results and removes them from tracking.
    func collectCompleted() -> [(info: BackgroundToolInfo, result: ToolResult)] {
        var completed: [(BackgroundToolInfo, ToolResult)] = []
        var toRemove: [String] = []

        for (id, running) in tasks {
            if let result = running.result {
                completed.append((running.info, result))
                toRemove.append(id)
            }
        }

        for id in toRemove {
            tasks.removeValue(forKey: id)
        }
        return completed
    }

    /// Number of currently running (not yet completed) background tasks.
    var activeCount: Int {
        tasks.values.count { $0.result == nil }
    }

    /// Status summary of all running background tasks for context injection.
    ///
    /// Includes escalating warnings for long-running tasks. Warning schedule:
    /// 5 min, 15 min, then every 30 min thereafter.
    func statusSummary() -> String? {
        let now = ContinuousClock.now
        var lines: [String] = []

        for (id, running) in tasks {
            guard running.result == nil else { continue }
            let elapsed = now - running.info.startedAt
            let secs = Int(elapsed.components.seconds)
            var line = "- \(running.info.toolName)(\(running.info.taskSummary)) — \(secs)s"

            if let warning = nextWarningIfDue(for: running, now: now) {
                line += " ⚠️ \(warning)"
                tasks[id]?.lastWarningAt = now
            }

            lines.append(line)
        }

        guard !lines.isEmpty else { return nil }
        return "Background tasks:\n\(lines.joined(separator: "\n"))"
    }

    /// Determine if a warning is due for this task, and return the warning text.
    private func nextWarningIfDue(for running: RunningTask, now: ContinuousClock.Instant) -> String? {
        let elapsed = now - running.info.startedAt

        // Find which warning threshold we've crossed
        for (i, threshold) in Self.warningSchedule.enumerated() {
            if elapsed >= threshold {
                let prevThreshold = i > 0 ? Self.warningSchedule[i - 1] : .zero
                // Only warn if we haven't warned since crossing this threshold
                if let lastWarning = running.lastWarningAt {
                    let sinceLast = now - lastWarning
                    if i == Self.warningSchedule.count - 1 {
                        // Last scheduled threshold — switch to recurring
                        if sinceLast >= Self.recurringWarningInterval {
                            return "Running for \(Int(elapsed.components.seconds / 60))min — still going"
                        }
                    }
                    // Already warned for this threshold
                    if lastWarning > running.info.startedAt + prevThreshold {
                        continue
                    }
                }
                let mins = Int(elapsed.components.seconds / 60)
                return "Running for \(mins)min — consider checking if it's stuck"
            }
        }

        // Past all scheduled thresholds — recurring warnings
        if elapsed > Self.warningSchedule.last ?? .zero {
            if let lastWarning = running.lastWarningAt {
                if now - lastWarning >= Self.recurringWarningInterval {
                    return "Running for \(Int(elapsed.components.seconds / 60))min — still going"
                }
            } else {
                let mins = Int(elapsed.components.seconds / 60)
                return "Running for \(mins)min — consider checking if it's stuck"
            }
        }

        return nil
    }

    /// Cancel all running background tasks. Called on turn end or stop word.
    func cancelAll() -> [(info: BackgroundToolInfo, reason: String)] {
        var cancelled: [(BackgroundToolInfo, String)] = []
        for (_, running) in tasks {
            running.task.cancel()
            cancelled.append((running.info, "cancelled"))
        }
        tasks.removeAll()
        return cancelled
    }
}
