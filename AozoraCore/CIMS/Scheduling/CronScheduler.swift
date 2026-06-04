import Foundation
import GRDB

/// A cron job that has fired and needs execution.
public struct FiredJob: Sendable {
    /// The external job identifier.
    public let jobId: String
    /// Human-readable name.
    public let name: String
    /// The prompt text to execute.
    public let prompt: String
    /// Optional skill to invoke.
    public let skill: String?
    /// Delivery target (e.g., `"local"` or a channel name).
    public let deliverTo: String
}

/// Actor that manages CRUD operations and scheduled execution of cron jobs.
///
/// The scheduler owns no timer itself — it exposes a ``tick()`` method that the
/// ``HeartbeatScheduler`` calls every 60 seconds. On each tick, the scheduler queries
/// for enabled jobs whose `nextRunAt` is at or before the current time, updates their
/// bookkeeping, and returns the list of fired jobs for the caller to enqueue as events.
///
/// Persistence is backed by the `cron_jobs` table in ``CIMSDatabase``.
public actor CronScheduler {
    /// The database used for persisting job state.
    let db: CIMSDatabase

    /// Creates a scheduler backed by the given database.
    ///
    /// - Parameter db: The ``CIMSDatabase`` whose `cron_jobs` table will be used.
    public init(db: CIMSDatabase) {
        self.db = db
    }

    // MARK: - CRUD

    /// Create a new scheduled job.
    ///
    /// Parses the schedule string, computes the initial `nextRunAt`, and inserts
    /// a new row into the `cron_jobs` table.
    ///
    /// - Parameters:
    ///   - name: Human-readable job name.
    ///   - prompt: The prompt text to execute when the job fires.
    ///   - schedule: Schedule string (see ``CronSchedule/parse(_:)`` for formats).
    ///   - skill: Optional skill identifier to invoke.
    ///   - repeatTimes: Maximum repetitions (nil = unlimited).
    ///   - deliverTo: Delivery target. Defaults to "local".
    /// - Throws: ``ToolError/invalidParameters(_:)`` if the schedule string is unparseable,
    ///   or GRDB errors on insertion failure.
    public func createJob(
        name: String,
        prompt: String,
        schedule: String,
        skill: String? = nil,
        repeatTimes: Int? = nil,
        deliverTo: String = "local",
    ) throws {
        guard let parsed = CronSchedule.parse(schedule) else {
            throw ToolError.invalidParameters("Invalid schedule: '\(schedule)'")
        }

        let now = Date()
        let nextRun = parsed.nextRun(after: now)

        var row = CronJobRow(
            id: nil,
            jobId: UUID().uuidString,
            name: name,
            prompt: prompt,
            scheduleKind: parsed.kind.rawValue,
            scheduleExpr: scheduleExprString(for: parsed, raw: schedule),
            enabled: true,
            deliverTo: deliverTo,
            skill: skill,
            repeatTimes: repeatTimes,
            completedCount: 0,
            nextRunAt: nextRun,
            lastRunAt: nil,
            lastStatus: nil,
            lastError: nil,
            createdAt: now,
        )

        try db.dbPool.write { grdb in
            try row.insert(grdb)
        }
    }

    /// List all jobs, optionally filtered by enabled status.
    ///
    /// - Returns: All ``CronJobRow`` records ordered by creation time descending.
    /// - Throws: GRDB errors on read failure.
    public func listJobs() throws -> [CronJobRow] {
        try db.dbPool.read { grdb in
            try CronJobRow.order(Column("createdAt").desc).fetchAll(grdb)
        }
    }

    /// Pause a job by setting `enabled` to `false`.
    ///
    /// - Parameter jobId: The external job identifier.
    /// - Throws: ``ToolError/invalidParameters(_:)`` if no job matches, or GRDB errors.
    public func pauseJob(jobId: String) throws {
        try db.dbPool.write { grdb in
            guard var row = try CronJobRow.filter(Column("jobId") == jobId).fetchOne(grdb) else {
                throw ToolError.invalidParameters("No job with id '\(jobId)'")
            }
            row.enabled = false
            try row.update(grdb)
        }
    }

    /// Resume a paused job by setting `enabled` to `true`.
    ///
    /// - Parameter jobId: The external job identifier.
    /// - Throws: ``ToolError/invalidParameters(_:)`` if no job matches, or GRDB errors.
    public func resumeJob(jobId: String) throws {
        try db.dbPool.write { grdb in
            guard var row = try CronJobRow.filter(Column("jobId") == jobId).fetchOne(grdb) else {
                throw ToolError.invalidParameters("No job with id '\(jobId)'")
            }
            row.enabled = true
            try row.update(grdb)
        }
    }

    /// Remove a job permanently.
    ///
    /// - Parameter jobId: The external job identifier.
    /// - Throws: ``ToolError/invalidParameters(_:)`` if no job matches, or GRDB errors.
    public func removeJob(jobId: String) throws {
        try db.dbPool.write { grdb in
            guard let row = try CronJobRow.filter(Column("jobId") == jobId).fetchOne(grdb) else {
                throw ToolError.invalidParameters("No job with id '\(jobId)'")
            }
            _ = try row.delete(grdb)
        }
    }

    /// Trigger a job immediately, regardless of its schedule.
    ///
    /// Updates bookkeeping as if the job fired at the current time: `lastRunAt` is set,
    /// `completedCount` increments, and `nextRunAt` advances. Actual execution (spawning
    /// a worker) will be wired later.
    ///
    /// - Parameter jobId: The external job identifier.
    /// - Throws: ``ToolError/invalidParameters(_:)`` if no job matches, or GRDB errors.
    public func triggerJob(jobId: String) throws {
        let now = Date()
        try db.dbPool.write { grdb in
            guard var row = try CronJobRow.filter(Column("jobId") == jobId).fetchOne(grdb) else {
                throw ToolError.invalidParameters("No job with id '\(jobId)'")
            }
            row.lastRunAt = now
            row.completedCount += 1
            row.lastStatus = "ok"
            row.nextRunAt = computeNextRun(for: row, after: now)
            try row.update(grdb)
        }
    }

    /// Check for due jobs, update bookkeeping, and return fired jobs.
    ///
    /// Queries for all enabled jobs whose `nextRunAt <= now`, advances their schedules,
    /// and returns the list of jobs that fired. The caller is responsible for enqueuing
    /// these as events for execution (e.g., system-initiated turns).
    ///
    /// Jobs that have exhausted their `repeatTimes` are automatically disabled.
    ///
    /// - Returns: Jobs that fired on this tick, ready for execution.
    public func tick() -> [FiredJob] {
        let now = Date()
        do {
            return try db.dbPool.write { grdb in
                let dueJobs = try CronJobRow
                    .filter(Column("enabled") == true)
                    .filter(Column("nextRunAt") != nil)
                    .filter(Column("nextRunAt") <= now)
                    .fetchAll(grdb)

                var fired: [FiredJob] = []

                for var job in dueJobs {
                    job.lastRunAt = now
                    job.completedCount += 1
                    job.lastStatus = "ok"

                    if let repeatTimes = job.repeatTimes, job.completedCount >= repeatTimes {
                        job.enabled = false
                        job.nextRunAt = nil
                    } else {
                        job.nextRunAt = computeNextRun(for: job, after: now)
                    }

                    try job.update(grdb)

                    fired.append(FiredJob(
                        jobId: job.jobId,
                        name: job.name,
                        prompt: job.prompt,
                        skill: job.skill,
                        deliverTo: job.deliverTo,
                    ))
                }

                return fired
            }
        } catch {
            print("[cron] tick error: \(error)")
            return []
        }
    }

    // MARK: - Private Helpers

    /// Compute the next run time for a job based on its schedule kind.
    ///
    /// - Parameters:
    ///   - job: The job row containing schedule metadata.
    ///   - after: The reference time.
    /// - Returns: The next execution time, or `nil` for expired one-shot jobs.
    private nonisolated func computeNextRun(for job: CronJobRow, after: Date) -> Date? {
        switch job.scheduleKind {
        case "interval":
            let schedule = CronSchedule(
                kind: .interval,
                intervalMinutes: parseIntervalMinutes(from: job.scheduleExpr),
            )
            return schedule.nextRun(after: after)

        case "cron":
            let schedule = CronSchedule(kind: .cron, expression: job.scheduleExpr)
            return schedule.nextRun(after: after)

        case "once":
            return nil

        default:
            return nil
        }
    }

    /// Extract interval minutes from a stored schedule expression.
    ///
    /// The expression is stored as "every Nm" / "every Nh" / "every Nd" or just the
    /// numeric duration part.
    ///
    /// - Parameter expr: The stored schedule expression.
    /// - Returns: The interval in minutes, or `nil` if unparseable.
    private nonisolated func parseIntervalMinutes(from expr: String?) -> Int? {
        guard let expr else { return nil }
        if let parsed = CronSchedule.parse(expr) {
            return parsed.intervalMinutes
        }
        return nil
    }

    /// Derive the stored schedule expression string from a parsed schedule.
    ///
    /// For interval schedules, stores the raw input (e.g., "every 30m") so it can
    /// be re-parsed later. For cron schedules, stores the expression. For one-shot
    /// schedules, stores the raw input.
    ///
    /// - Parameters:
    ///   - schedule: The parsed schedule.
    ///   - raw: The original input string.
    /// - Returns: The string to store in the `scheduleExpr` column.
    private nonisolated func scheduleExprString(for schedule: CronSchedule, raw: String) -> String? {
        switch schedule.kind {
        case .interval: raw
        case .cron: schedule.expression
        case .once: raw
        }
    }
}
