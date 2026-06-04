import Foundation

/// Unified presence management tool for controlling the agent's awareness schedule.
///
/// Provides a single interface for the agent to manage all forms of periodic presence:
/// heartbeat cache warming, scheduled wake-ups (cron jobs), and one-shot reminders.
///
/// Actions:
/// - `status` — show heartbeat state and all active scheduled jobs
/// - `heartbeat_start` — start the heartbeat timer
/// - `heartbeat_stop` — stop the heartbeat timer
/// - `heartbeat_interval` — change the heartbeat interval (minutes)
/// - `schedule` — create a new scheduled wake-up (name, prompt, schedule expression)
/// - `cancel` — cancel a scheduled job by ID
/// - `list` — list all scheduled jobs
public nonisolated struct PresenceTool: ToolExecutable {
    public let name = "presence"

    /// The cron scheduler for job management.
    let cronScheduler: CronScheduler

    /// Callbacks for heartbeat control, injected by the daemon.
    let heartbeatStart: @Sendable () async -> Void
    let heartbeatStop: @Sendable () async -> Void
    let heartbeatStatus: @Sendable () async -> (running: Bool, intervalMinutes: Int)

    /// Creates a presence tool.
    ///
    /// - Parameters:
    ///   - cronScheduler: The cron scheduler for job CRUD.
    ///   - heartbeatStart: Callback to start the heartbeat timer.
    ///   - heartbeatStop: Callback to stop the heartbeat timer.
    ///   - heartbeatStatus: Callback to query heartbeat state.
    public init(
        cronScheduler: CronScheduler,
        heartbeatStart: @escaping @Sendable () async -> Void,
        heartbeatStop: @escaping @Sendable () async -> Void,
        heartbeatStatus: @escaping @Sendable () async -> (running: Bool, intervalMinutes: Int),
    ) {
        self.cronScheduler = cronScheduler
        self.heartbeatStart = heartbeatStart
        self.heartbeatStop = heartbeatStop
        self.heartbeatStatus = heartbeatStatus
    }

    public var definition: ToolDefinition {
        ToolDefinition(
            name: "presence",
            description: """
            Manage your awareness schedule — control when and how you wake up.
            
            Actions:
            - "status" — show heartbeat state + all scheduled jobs
            - "heartbeat_start" — start periodic heartbeat (cache warming + awareness)
            - "heartbeat_stop" — stop periodic heartbeat
            - "schedule" — create a scheduled wake-up (requires name, prompt, schedule)
            - "cancel" — cancel a scheduled job (requires job_id)
            - "list" — list all scheduled jobs with status
            
            Schedule formats: "every 30m", "every 2h", "every 1d", "2h" (one-shot), "0 9 * * *" (cron).
            
            Use this to set reminders, create recurring check-ins, or control your background awareness.
            One-shot schedules (e.g., "2h") fire once then auto-disable — perfect for reminders.
            """,
            parameters: [
                ToolParameter(
                    name: "action",
                    type: .enum(["status", "heartbeat_start", "heartbeat_stop", "schedule", "cancel", "list"]),
                    description: "The operation to perform",
                ),
                ToolParameter(
                    name: "name",
                    type: .string,
                    description: "Name for the scheduled job (required for schedule)",
                    optional: true,
                ),
                ToolParameter(
                    name: "prompt",
                    type: .string,
                    description: "What to do when the job fires (required for schedule)",
                    optional: true,
                ),
                ToolParameter(
                    name: "schedule",
                    type: .string,
                    description: "Schedule expression (required for schedule). E.g., 'every 30m', '0 9 * * 1-5', '2h' (one-shot)",
                    optional: true,
                ),
                ToolParameter(
                    name: "job_id",
                    type: .string,
                    description: "Job identifier (required for cancel)",
                    optional: true,
                ),
            ],
        )
    }

    public func execute(parameters: sending [String: Any], workingDirectory _: String) async throws -> ToolResult {
        let action = try requireString("action", from: parameters)

        switch action {
        case "status":
            return await handleStatus()
        case "heartbeat_start":
            await heartbeatStart()
            return .success("Heartbeat timer started.")
        case "heartbeat_stop":
            await heartbeatStop()
            return .success("Heartbeat timer stopped.")
        case "schedule":
            return try await handleSchedule(parameters: parameters)
        case "cancel":
            let jobId = try requireString("job_id", from: parameters)
            try await cronScheduler.removeJob(jobId: jobId)
            return .success("Cancelled job '\(jobId)'.")
        case "list":
            return try await handleList()
        default:
            return .failure("Unknown action '\(action)'.")
        }
    }

    // MARK: - Handlers

    private func handleStatus() async -> ToolResult {
        let hb = await heartbeatStatus()
        var lines: [String] = []

        lines.append("## Heartbeat")
        lines.append("  Status: \(hb.running ? "running" : "stopped")")
        lines.append("  Interval: \(hb.intervalMinutes) minutes")

        lines.append("")
        lines.append("## Scheduled Jobs")

        do {
            let jobs = try await cronScheduler.listJobs()
            if jobs.isEmpty {
                lines.append("  (none)")
            } else {
                for job in jobs {
                    let status = job.enabled ? "active" : "paused"
                    let next = job.nextRunAt.map { formatDate($0) } ?? "—"
                    let last = job.lastRunAt.map { formatDate($0) } ?? "never"
                    lines.append("  [\(status)] \(job.name) (id: \(job.jobId.prefix(8)))")
                    lines.append("    Schedule: \(job.scheduleExpr ?? job.scheduleKind)")
                    lines.append("    Next: \(next) | Last: \(last) | Runs: \(job.completedCount)")
                    if let prompt = Optional(job.prompt), !prompt.isEmpty {
                        lines.append("    Prompt: \(prompt.prefix(80))")
                    }
                }
            }
        } catch {
            lines.append("  Error listing jobs: \(error)")
        }

        return .success(lines.joined(separator: "\n"))
    }

    private func handleSchedule(parameters: [String: Any]) async throws -> ToolResult {
        let name = try requireString("name", from: parameters)
        let prompt = try requireString("prompt", from: parameters)
        let schedule = try requireString("schedule", from: parameters)

        try await cronScheduler.createJob(
            name: name,
            prompt: prompt,
            schedule: schedule,
        )

        let kind = schedule.contains("every") ? "recurring" : (schedule.split(separator: " ").count >= 5 ? "cron" : "one-shot")
        return .success("Scheduled \(kind) job '\(name)' with schedule '\(schedule)'.")
    }

    private func handleList() async throws -> ToolResult {
        let jobs = try await cronScheduler.listJobs()
        if jobs.isEmpty {
            return .success("No scheduled jobs.")
        }

        var lines: [String] = []
        for job in jobs {
            let status = job.enabled ? "active" : "paused"
            let next = job.nextRunAt.map { formatDate($0) } ?? "—"
            lines.append("[\(status)] \(job.name) | id: \(job.jobId.prefix(8)) | schedule: \(job.scheduleExpr ?? job.scheduleKind) | next: \(next) | runs: \(job.completedCount)")
        }
        return .success(lines.joined(separator: "\n"))
    }

    // MARK: - Helpers

    private nonisolated func formatDate(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd HH:mm"
        formatter.timeZone = .current
        return formatter.string(from: date)
    }
}
