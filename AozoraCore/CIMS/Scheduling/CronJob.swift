import Foundation
import GRDB

// MARK: - CronSchedule

/// A parsed schedule specification for a cron job.
///
/// Supports three scheduling modes:
/// - **cron**: Standard 5-field cron expressions (minute, hour, day-of-month, month, day-of-week).
/// - **interval**: Recurring execution at a fixed interval (e.g., "every 30m").
/// - **once**: A one-shot delay that fires once then disables (e.g., "2h").
///
/// Use ``parse(_:)`` to create from a human-readable string, and ``nextRun(after:)``
/// to compute the next execution time.
public struct CronSchedule: Sendable {
    /// The type of schedule this represents.
    public enum Kind: String, Sendable {
        /// Standard 5-field cron expression.
        case cron
        /// Fixed-interval recurring schedule.
        case interval
        /// One-shot delayed execution.
        case once
    }

    /// The scheduling mode.
    public let kind: Kind

    /// For `.interval` schedules, the number of minutes between executions.
    public let intervalMinutes: Int?

    /// For `.cron` schedules, the raw 5-field cron expression.
    public let expression: String?

    /// For `.once` schedules, the absolute time to fire.
    public let runAt: Date?

    /// Creates a schedule with explicit field values.
    ///
    /// - Parameters:
    ///   - kind: The scheduling mode.
    ///   - intervalMinutes: Minutes between runs (`.interval` only).
    ///   - expression: Cron expression string (`.cron` only).
    ///   - runAt: Absolute fire time (`.once` only).
    public init(kind: Kind, intervalMinutes: Int? = nil, expression: String? = nil, runAt: Date? = nil) {
        self.kind = kind
        self.intervalMinutes = intervalMinutes
        self.expression = expression
        self.runAt = runAt
    }

    /// Parse a human-readable schedule string.
    ///
    /// Accepted formats:
    /// - `"every Nm"` / `"every Nh"` / `"every Nd"` — recurring interval.
    /// - `"Nm"` / `"Nh"` / `"Nd"` (without "every") — one-shot delay from now.
    /// - `"0 9 * * *"` (5 space-separated fields) — standard cron expression.
    ///
    /// - Parameter input: The schedule string to parse.
    /// - Returns: A ``CronSchedule`` if parsing succeeds, `nil` otherwise.
    public static func parse(_ input: String) -> CronSchedule? {
        let trimmed = input.trimmingCharacters(in: .whitespaces)

        if trimmed.hasPrefix("every ") {
            let durationPart = String(trimmed.dropFirst(6)).trimmingCharacters(in: .whitespaces)
            guard let minutes = parseDurationMinutes(durationPart) else { return nil }
            return CronSchedule(kind: .interval, intervalMinutes: minutes)
        }

        let fields = trimmed.split(separator: " ")
        if fields.count == 5, looksLikeCron(fields) {
            return CronSchedule(kind: .cron, expression: trimmed)
        }

        if let minutes = parseDurationMinutes(trimmed) {
            let runAt = Date().addingTimeInterval(Double(minutes) * 60)
            return CronSchedule(kind: .once, runAt: runAt)
        }

        return nil
    }

    /// Compute the next run time after the given date.
    ///
    /// - Parameter after: The reference time to compute from.
    /// - Returns: The next scheduled execution time, or `nil` if the schedule has expired.
    public func nextRun(after: Date) -> Date? {
        switch kind {
        case .interval:
            guard let minutes = intervalMinutes else { return nil }
            return after.addingTimeInterval(Double(minutes) * 60)

        case .once:
            guard let runAt else { return nil }
            return runAt > after ? runAt : nil

        case .cron:
            guard let expression else { return nil }
            return nextCronMatch(expression: expression, after: after)
        }
    }

    // MARK: - Private Helpers

    /// Parse a duration suffix string into total minutes.
    ///
    /// Supports `m` (minutes), `h` (hours), `d` (days).
    ///
    /// - Parameter input: A string like "30m", "2h", or "1d".
    /// - Returns: The equivalent number of minutes, or `nil` if unparseable.
    private static func parseDurationMinutes(_ input: String) -> Int? {
        let trimmed = input.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return nil }

        let suffix = trimmed.last!
        let numberPart = String(trimmed.dropLast())
        guard let value = Int(numberPart), value > 0 else { return nil }

        switch suffix {
        case "m": return value
        case "h": return value * 60
        case "d": return value * 1_440
        default: return nil
        }
    }

    /// Heuristic check for whether space-separated tokens look like cron fields.
    ///
    /// Each field must be `*`, a number, or a comma-separated list of numbers.
    private static func looksLikeCron(_ fields: [Substring]) -> Bool {
        for field in fields {
            if field == "*" { continue }
            let parts = field.split(separator: ",")
            for part in parts {
                if Int(part) == nil { return false }
            }
        }
        return true
    }

    /// Find the next minute after `after` that matches a 5-field cron expression.
    ///
    /// Iterates minute-by-minute from the start of the next minute, capped at 366 days.
    /// Each field can be `*`, a single number, or a comma-separated list.
    ///
    /// - Parameters:
    ///   - expression: The cron expression (e.g., "0 9 * * 1").
    ///   - after: The reference time.
    /// - Returns: The next matching minute, or `nil` if none found within 366 days.
    private func nextCronMatch(expression: String, after: Date) -> Date? {
        let fields = expression.split(separator: " ")
        guard fields.count == 5 else { return nil }

        let minuteSet = parseCronField(fields[0], range: 0 ... 59)
        let hourSet = parseCronField(fields[1], range: 0 ... 23)
        let domSet = parseCronField(fields[2], range: 1 ... 31)
        let monthSet = parseCronField(fields[3], range: 1 ... 12)
        let dowSet = parseCronField(fields[4], range: 0 ... 6)

        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = .current

        let startComponents = calendar.dateComponents([.year, .month, .day, .hour, .minute], from: after)
        guard var candidate = calendar.date(from: startComponents) else { return nil }
        candidate = candidate.addingTimeInterval(60)

        let maxDate = after.addingTimeInterval(366 * 24 * 3_600)

        while candidate <= maxDate {
            let comps = calendar.dateComponents([.minute, .hour, .day, .month, .weekday], from: candidate)
            let minute = comps.minute!
            let hour = comps.hour!
            let day = comps.day!
            let month = comps.month!
            let cronDow = comps.weekday! - 1

            if minuteSet.contains(minute),
               hourSet.contains(hour),
               domSet.contains(day),
               monthSet.contains(month),
               dowSet.contains(cronDow) {
                return candidate
            }

            candidate = candidate.addingTimeInterval(60)
        }

        return nil
    }

    /// Parse a single cron field into the set of matching integer values.
    ///
    /// - Parameters:
    ///   - field: The cron field string (`*`, a number, or comma-separated numbers).
    ///   - range: The valid range for this field.
    /// - Returns: The set of matching values.
    private func parseCronField(_ field: Substring, range: ClosedRange<Int>) -> Set<Int> {
        if field == "*" {
            return Set(range)
        }
        var result = Set<Int>()
        for part in field.split(separator: ",") {
            if let value = Int(part), range.contains(value) {
                result.insert(value)
            }
        }
        return result
    }
}

// MARK: - CronJobRow

/// A GRDB-backed row representing a scheduled cron job.
///
/// Maps 1:1 to the `cron_jobs` table. Uses `MutablePersistableRecord` because
/// the table has an autoincremented primary key — `didInsert` updates the `id`
/// on the original struct after insertion.
public struct CronJobRow: Sendable, Codable, FetchableRecord, MutablePersistableRecord {
    /// The database table name.
    public static let databaseTableName = "cron_jobs"

    /// Auto-incremented database primary key.
    public var id: Int64?

    /// Unique external identifier for API and tool references.
    public var jobId: String

    /// Human-readable name for the job.
    public var name: String

    /// The prompt text to execute when the job fires.
    public var prompt: String

    /// The schedule kind: "cron", "interval", or "once".
    public var scheduleKind: String

    /// The raw schedule expression (cron expression or interval string).
    public var scheduleExpr: String?

    /// Whether the job is enabled and eligible for execution.
    public var enabled: Bool

    /// Delivery target for the job's output. Defaults to "local".
    public var deliverTo: String

    /// Optional skill identifier to invoke when the job fires.
    public var skill: String?

    /// Maximum number of times to repeat (nil = unlimited for intervals/cron).
    public var repeatTimes: Int?

    /// How many times the job has completed execution.
    public var completedCount: Int

    /// The next scheduled execution time.
    public var nextRunAt: Date?

    /// The most recent execution time.
    public var lastRunAt: Date?

    /// Status of the last execution (e.g., "ok", "error").
    public var lastStatus: String?

    /// Error message from the last failed execution, if any.
    public var lastError: String?

    /// When the job was created.
    public var createdAt: Date

    /// Receives the auto-generated row ID after insertion.
    public mutating func didInsert(_ inserted: InsertionSuccess) {
        id = inserted.rowID
    }
}
