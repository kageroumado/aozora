import Foundation
import GRDB

/// Actor for persisting and retrieving observer signals.
///
/// Manages the `observer_signals` table. Provides save/load, temporal filtering,
/// and promotion marking for signals that trigger narrator wakeup.
///
/// All database operations go through ``CIMSDatabase/dbPool`` without holding the
/// actor's executor during long I/O.
public actor ObserverSignalStore {
    /// The shared database backing all CIMS persistence.
    private let db: CIMSDatabase

    /// ISO 8601 date formatter shared across all formatting operations.
    private nonisolated(unsafe) static let iso8601: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()

    /// Creates a signal store backed by the given database.
    ///
    /// - Parameter database: The shared CIMS database instance.
    public init(database: CIMSDatabase) {
        self.db = database
    }

    // MARK: - Save

    /// Persist an observer signal to the database.
    ///
    /// - Parameter signal: The observer signal to save.
    /// - Throws: GRDB errors if the write fails.
    public func saveSignal(_ signal: ObserverSignal) async throws {
        try await db.dbPool.write { db in
            var record = ObserverSignalRecord(
                signalId: nil,
                cycleNumber: signal.cycleNumber,
                signalText: signal.signalText,
                salienceScore: signal.salienceScore,
                wasPromoted: signal.wasPromoted ? 1 : 0,
                createdAt: Self.formatDate(signal.createdAt),
            )
            try record.insert(db)
        }
    }

    // MARK: - Load

    /// Retrieve the most recent observer signal.
    ///
    /// - Returns: The latest signal, or `nil` if no signals exist.
    /// - Throws: GRDB errors if the read fails.
    public func latestSignal() async throws -> ObserverSignal? {
        try await db.dbPool.read { db in
            guard let record = try ObserverSignalRecord
                .order(Column("createdAt").desc)
                .fetchOne(db)
            else {
                return nil
            }
            return Self.signalFromRecord(record)
        }
    }

    // MARK: - Query

    /// Retrieve signals created since a given date, up to a limit.
    ///
    /// - Parameters:
    ///   - date: Only return signals created after this date.
    ///   - limit: Maximum number of signals to return.
    /// - Returns: Signals ordered by creation time (oldest first).
    /// - Throws: GRDB errors if the read fails.
    public func signalsSince(_ date: Date, limit: Int) async throws -> [ObserverSignal] {
        let dateString = Self.formatDate(date)
        return try await db.dbPool.read { db in
            let records = try ObserverSignalRecord
                .filter(Column("createdAt") > dateString)
                .order(Column("createdAt").asc)
                .limit(limit)
                .fetchAll(db)
            return records.map { Self.signalFromRecord($0) }
        }
    }

    // MARK: - Promote

    /// Mark a signal as having triggered a narrator wakeup.
    ///
    /// - Parameter cycleNumber: The cycle number of the signal to promote.
    /// - Throws: GRDB errors if the update fails.
    public func markPromoted(cycleNumber: Int) async throws {
        try await db.dbPool.write { db in
            try db.execute(
                sql: "UPDATE observer_signals SET wasPromoted = 1 WHERE cycleNumber = ?",
                arguments: [cycleNumber],
            )
        }
    }

    // MARK: - Helpers

    /// Convert a record to a domain value type.
    private static func signalFromRecord(_ record: ObserverSignalRecord) -> ObserverSignal {
        ObserverSignal(
            cycleNumber: record.cycleNumber,
            signalText: record.signalText,
            salienceScore: record.salienceScore,
            wasPromoted: record.wasPromoted != 0,
            createdAt: parseDate(record.createdAt),
            plateEntropy: 0,
            plateMagnitude: 0,
        )
    }

    /// Format a date as an ISO 8601 string.
    public static func formatDate(_ date: Date) -> String {
        iso8601.string(from: date)
    }

    /// Parse an ISO 8601 string into a date, falling back to `.distantPast`.
    public static func parseDate(_ string: String) -> Date {
        iso8601.date(from: string) ?? .distantPast
    }
}
