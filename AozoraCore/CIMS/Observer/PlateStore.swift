import Foundation
import GRDB

/// Actor for persisting and retrieving plate vector snapshots.
///
/// Manages the `plate_snapshots` and `plate_archive` tables. Provides save/load
/// roundtrip, pruning to a retention window, and archival of cycle ranges into
/// downsampled mean vectors.
///
/// All database operations go through ``CIMSDatabase/dbPool`` without holding the
/// actor's executor during long I/O.
public actor PlateStore {
    /// The shared database backing all CIMS persistence.
    private let db: CIMSDatabase

    /// ISO 8601 date formatter shared across all formatting operations.
    private nonisolated(unsafe) static let iso8601: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()

    /// Creates a plate store backed by the given database.
    ///
    /// - Parameter database: The shared CIMS database instance.
    public init(database: CIMSDatabase) {
        self.db = database
    }

    // MARK: - Save

    /// Persist a plate snapshot to the database.
    ///
    /// - Parameter snapshot: The plate snapshot to save.
    /// - Throws: GRDB errors if the write fails.
    public func saveSnapshot(_ snapshot: PlateSnapshot) async throws {
        try await db.dbPool.write { db in
            var record = PlateSnapshotRecord(
                snapshotId: nil,
                cycleNumber: snapshot.cycleNumber,
                plateVector: snapshot.plateVector,
                plateEntropy: snapshot.plateEntropy,
                plateMagnitude: snapshot.plateMagnitude,
                generatedText: snapshot.generatedText,
                inputDigest: snapshot.inputDigest,
                capturedAt: Self.formatDate(snapshot.capturedAt),
            )
            try record.insert(db)
        }
    }

    // MARK: - Load

    /// Retrieve the most recent plate snapshot.
    ///
    /// - Returns: The latest snapshot, or `nil` if no snapshots exist.
    /// - Throws: GRDB errors if the read fails.
    public func latestSnapshot() async throws -> PlateSnapshot? {
        try await db.dbPool.read { db in
            guard let record = try PlateSnapshotRecord
                .order(Column("cycleNumber").desc)
                .fetchOne(db)
            else {
                return nil
            }
            return PlateSnapshot(
                cycleNumber: record.cycleNumber,
                plateVector: record.plateVector,
                plateEntropy: record.plateEntropy,
                plateMagnitude: record.plateMagnitude,
                generatedText: record.generatedText,
                inputDigest: record.inputDigest,
                capturedAt: Self.parseDate(record.capturedAt),
            )
        }
    }

    // MARK: - Prune

    /// Remove old snapshots, keeping only the most recent N.
    ///
    /// - Parameter keepLast: Number of most recent snapshots to retain. Defaults to
    ///   ``CIMSDefaults/maxPlateSnapshots``.
    /// - Throws: GRDB errors if the delete fails.
    public func pruneOld(keepLast: Int = CIMSDefaults.maxPlateSnapshots) async throws {
        try await db.dbPool.write { db in
            let cutoffCycle = try Int.fetchOne(
                db,
                sql: """
                SELECT cycleNumber FROM plate_snapshots
                ORDER BY cycleNumber DESC
                LIMIT 1 OFFSET ?
                """,
                arguments: [keepLast - 1],
            )

            if let cutoff = cutoffCycle {
                try db.execute(
                    sql: "DELETE FROM plate_snapshots WHERE cycleNumber < ?",
                    arguments: [cutoff],
                )
            }
        }
    }

    // MARK: - Archive

    /// Archive a range of snapshots into a single downsampled record.
    ///
    /// Computes the element-wise mean of all plate vectors in the range, along with
    /// the min/max entropy bounds. The source snapshots are not deleted — call
    /// ``pruneOld(keepLast:)`` separately to reclaim space.
    ///
    /// - Parameters:
    ///   - from: Start cycle number (inclusive).
    ///   - to: End cycle number (inclusive).
    /// - Throws: GRDB errors if the read or write fails, or if the range is empty.
    public func archiveRange(from: Int, to: Int) async throws {
        try await db.dbPool.write { db in
            let records = try PlateSnapshotRecord
                .filter(Column("cycleNumber") >= from && Column("cycleNumber") <= to)
                .order(Column("cycleNumber").asc)
                .fetchAll(db)

            guard !records.isEmpty else { return }

            let dimension = CIMSDefaults.plateDimension
            let expectedBytes = dimension * MemoryLayout<Float>.size
            var meanFloats = [Float](repeating: 0, count: dimension)
            var maxEntropy = -Double.infinity
            var minEntropy = Double.infinity

            for record in records {
                maxEntropy = max(maxEntropy, record.plateEntropy)
                minEntropy = min(minEntropy, record.plateEntropy)

                if record.plateVector.count == expectedBytes {
                    unsafe record.plateVector.withUnsafeBytes { buffer in
                        let floats = unsafe buffer.bindMemory(to: Float.self)
                        for i in 0 ..< dimension {
                            meanFloats[i] += unsafe floats[i]
                        }
                    }
                }
            }

            let count = Float(records.count)
            for i in 0 ..< dimension {
                meanFloats[i] /= count
            }

            let meanData = unsafe meanFloats.withUnsafeBufferPointer { buffer in
                unsafe Data(buffer: buffer)
            }

            var archive = PlateArchiveRecord(
                archiveId: nil,
                cycleRange: "\(from)-\(to)",
                meanVector: meanData,
                maxEntropy: maxEntropy,
                minEntropy: minEntropy,
                archivedAt: Self.formatDate(Date()),
            )
            try archive.insert(db)
        }
    }

    // MARK: - Formatting

    /// Format a date as an ISO 8601 string.
    public static func formatDate(_ date: Date) -> String {
        iso8601.string(from: date)
    }

    /// Parse an ISO 8601 string into a date, falling back to `.distantPast`.
    public static func parseDate(_ string: String) -> Date {
        iso8601.date(from: string) ?? .distantPast
    }
}
