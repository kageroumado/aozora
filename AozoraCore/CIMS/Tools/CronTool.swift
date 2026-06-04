import Foundation

/// CRUD tool for managing scheduled cron jobs.
///
/// Exposes the ``CronScheduler`` actor's methods as a tool the coordinator model can invoke.
/// Supports creating, listing, pausing, resuming, triggering, and removing jobs.
///
/// Actions:
/// - `create` — schedule a new job with a name, prompt, and schedule expression.
/// - `list` — show all scheduled jobs.
/// - `pause` — disable a job by its `job_id`.
/// - `resume` — re-enable a paused job.
/// - `trigger` — fire a job immediately regardless of schedule.
/// - `remove` — permanently delete a job.
public nonisolated struct CronTool: ToolExecutable {
    /// The tool name registered with the coordinator.
    public let name = "cron"

    /// The backing scheduler actor that owns job persistence and execution.
    let scheduler: CronScheduler

    /// Creates a cron tool backed by the given scheduler.
    ///
    /// - Parameter scheduler: The ``CronScheduler`` actor to delegate operations to.
    public init(scheduler: CronScheduler) {
        self.scheduler = scheduler
    }

    public var definition: ToolDefinition {
        ToolDefinition(
            name: "cron",
            description: """
            Manage scheduled jobs. Actions:
            - "create" — create a new job (requires name, prompt, schedule).
            - "list" — show all jobs.
            - "pause" — disable a job (requires job_id).
            - "resume" — re-enable a paused job (requires job_id).
            - "trigger" — fire a job immediately (requires job_id).
            - "remove" — delete a job (requires job_id).
            Schedule formats: "every 30m", "every 2h", "every 1d", "2h" (one-shot), "0 9 * * *" (cron).
            """,
            parameters: [
                ToolParameter(
                    name: "action",
                    type: .enum(["create", "list", "pause", "resume", "trigger", "remove"]),
                    description: "The operation to perform",
                ),
                ToolParameter(
                    name: "name",
                    type: .string,
                    description: "Human-readable name for the job (required for create)",
                    optional: true,
                ),
                ToolParameter(
                    name: "prompt",
                    type: .string,
                    description: "Prompt text to execute when the job fires (required for create)",
                    optional: true,
                ),
                ToolParameter(
                    name: "schedule",
                    type: .string,
                    description: "Schedule expression (required for create). E.g., 'every 30m', '0 9 * * *', '2h'",
                    optional: true,
                ),
                ToolParameter(
                    name: "job_id",
                    type: .string,
                    description: "Job identifier (required for pause, resume, trigger, remove)",
                    optional: true,
                ),
                ToolParameter(
                    name: "skill",
                    type: .string,
                    description: "Optional skill to invoke when the job fires",
                    optional: true,
                ),
            ],
        )
    }

    public func execute(parameters: sending [String: Any], workingDirectory _: String) async throws -> ToolResult {
        let action = try requireString("action", from: parameters)

        switch action {
        case "create":
            return try await handleCreate(parameters: parameters)
        case "list":
            return try await handleList()
        case "pause", "resume", "trigger", "remove":
            return try await handleJobAction(action, parameters: parameters)
        default:
            return .failure("Unknown action '\(action)'.")
        }
    }

    // MARK: - Action Handlers

    /// Handle the "create" action.
    private func handleCreate(parameters: [String: Any]) async throws -> ToolResult {
        let name = try requireString("name", from: parameters)
        let prompt = try requireString("prompt", from: parameters)
        let schedule = try requireString("schedule", from: parameters)
        let skill = parameters["skill"] as? String

        try await scheduler.createJob(
            name: name,
            prompt: prompt,
            schedule: schedule,
            skill: skill,
        )

        return .success("Created job '\(name)' with schedule '\(schedule)'.")
    }

    /// Handle the "list" action.
    private func handleList() async throws -> ToolResult {
        let jobs = try await scheduler.listJobs()
        if jobs.isEmpty {
            return .success("No scheduled jobs.")
        }

        let lines = jobs.map { job -> String in
            let status = job.enabled ? "enabled" : "paused"
            let nextRun = job.nextRunAt.map { formatDate($0) } ?? "none"
            let lastRun = job.lastRunAt.map { formatDate($0) } ?? "never"
            return "[\(status)] \(job.name) (id: \(job.jobId))\n  schedule: \(job.scheduleKind) \(job.scheduleExpr ?? "")\n  next: \(nextRun) | last: \(lastRun) | runs: \(job.completedCount)"
        }

        return .success(lines.joined(separator: "\n\n"))
    }

    /// Handle a job-level action (pause, resume, trigger, remove) that requires `job_id`.
    private func handleJobAction(_ action: String, parameters: [String: Any]) async throws -> ToolResult {
        let jobId = try requireString("job_id", from: parameters)

        switch action {
        case "pause":
            try await scheduler.pauseJob(jobId: jobId)
        case "resume":
            try await scheduler.resumeJob(jobId: jobId)
        case "trigger":
            try await scheduler.triggerJob(jobId: jobId)
        case "remove":
            try await scheduler.removeJob(jobId: jobId)
        default:
            return .failure("Unknown action '\(action)'.")
        }

        return .success("\(action.capitalized) job '\(jobId)'.")
    }

    /// Format a date for display in tool output.
    private func formatDate(_ date: Date) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        return formatter.string(from: date)
    }
}
