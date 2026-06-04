import Foundation
import GRDB

/// Persistent record of a file's content captured before a mutation (edit or write).
///
/// Each row stores the full file content as a blob, keyed by conversation and file path.
/// Records are ordered by `createdAt` to support both single-step undo and full revert
/// to the original version.
///
/// Uses `MutablePersistableRecord` (not `PersistableRecord`) because the primary key
/// is autoincremented — `didInsert` must fire on the original value.
struct FileVersionRecord: MutablePersistableRecord, FetchableRecord, Codable {
    /// Database row ID, assigned after insert.
    var id: Int64?

    /// The conversation this version belongs to.
    var conversationId: Int64

    /// Absolute path of the file that was captured.
    var filePath: String

    /// Raw file content at the time of capture.
    var content: Data

    /// The tool that triggered the capture (`"edit"`, `"write"`, `"patch"`).
    var mutationTool: String

    /// When this version was captured.
    var createdAt: Date

    static let databaseTableName = "file_versions"

    mutating func didInsert(_ inserted: InsertionSuccess) {
        id = inserted.rowID
    }
}

/// The outcome of an undo operation, describing what was restored and how far back.
public struct UndoResult: Sendable {
    /// Absolute path of the restored file.
    public let restoredPath: String

    /// Number of versions reverted (1 for single undo, N for undo-all).
    public let versionsReverted: Int

    /// Human-readable summary of what changed.
    public let diffSummary: String
}

/// Tracks file content before mutations and provides undo capabilities.
///
/// The store captures a snapshot of a file's content just before an edit or write tool
/// modifies it. This enables single-step undo (revert the most recent change) and
/// full revert (restore to the state before any mutations in the current conversation).
///
/// Auto-prunes when the version count for a given (conversation, file) pair exceeds 50,
/// keeping only the most recent 50 versions.
///
/// Backed by GRDB `DatabasePool` for concurrent read access during writes.
public actor FileVersionStore {
    /// The database pool for persistence.
    private let dbPool: DatabasePool

    /// Maximum versions to retain per (conversation, file) pair before pruning.
    private let maxVersionsPerFile = 50

    /// Create a store backed by the given database.
    ///
    /// - Parameter database: The CIMS database instance (must have run v5 migration).
    public init(database: CIMSDatabase) {
        self.dbPool = database.dbPool
    }

    /// Capture the current content of a file before it is mutated.
    ///
    /// Reads the file at `filePath`, stores its content as a blob in the database,
    /// and auto-prunes if the version count exceeds the threshold.
    ///
    /// If the file does not exist (i.e., a new file creation), no version is captured.
    ///
    /// - Parameters:
    ///   - conversationId: The conversation context for this mutation.
    ///   - filePath: Absolute path to the file about to be mutated.
    ///   - mutationTool: Name of the tool performing the mutation (e.g., `"edit"`, `"write"`).
    public func captureVersion(
        conversationId: Int64,
        filePath: String,
        mutationTool: String,
    ) async {
        guard FileManager.default.fileExists(atPath: filePath) else { return }

        guard let data = FileManager.default.contents(atPath: filePath) else { return }

        do {
            try await dbPool.write { db in
                var record = FileVersionRecord(
                    conversationId: conversationId,
                    filePath: filePath,
                    content: data,
                    mutationTool: mutationTool,
                    createdAt: Date(),
                )
                try record.insert(db)
            }
            await pruneVersions(conversationId: conversationId, filePath: filePath, keepLast: maxVersionsPerFile)
        } catch {
            // Capture failures are non-fatal — log but don't block the mutation.
        }
    }

    /// Revert a file to its state before the most recent mutation.
    ///
    /// Finds the newest version record for the given (conversation, file) pair,
    /// writes its content back to disk, and deletes the record.
    ///
    /// - Parameters:
    ///   - conversationId: The conversation context.
    ///   - filePath: Absolute path to the file to restore.
    /// - Returns: An ``UndoResult`` describing what was restored, or `nil` if no versions exist.
    public func undoLast(conversationId: Int64, filePath: String) async -> UndoResult? {
        do {
            let record: FileVersionRecord? = try await dbPool.read { db in
                try FileVersionRecord
                    .filter(Column("conversationId") == conversationId)
                    .filter(Column("filePath") == filePath)
                    .order(Column("createdAt").desc)
                    .fetchOne(db)
            }

            guard let record else { return nil }

            let currentContent = (try? Data(contentsOf: URL(fileURLWithPath: filePath))) ?? Data()
            try record.content.write(to: URL(fileURLWithPath: filePath))

            _ = try await dbPool.write { db in
                try FileVersionRecord
                    .filter(Column("id") == record.id)
                    .deleteAll(db)
            }

            let summary = diffSummary(
                original: record.content,
                current: currentContent,
                path: filePath,
            )

            return UndoResult(
                restoredPath: filePath,
                versionsReverted: 1,
                diffSummary: summary,
            )
        } catch {
            return nil
        }
    }

    /// Revert a file to its state before any mutations in the current conversation.
    ///
    /// Finds the oldest version record for the given (conversation, file) pair,
    /// writes its content back to disk, and deletes all version records for that pair.
    ///
    /// - Parameters:
    ///   - conversationId: The conversation context.
    ///   - filePath: Absolute path to the file to restore.
    /// - Returns: An ``UndoResult`` describing what was restored, or `nil` if no versions exist.
    public func undoAll(conversationId: Int64, filePath: String) async -> UndoResult? {
        do {
            let records: [FileVersionRecord] = try await dbPool.read { db in
                try FileVersionRecord
                    .filter(Column("conversationId") == conversationId)
                    .filter(Column("filePath") == filePath)
                    .order(Column("createdAt").asc)
                    .fetchAll(db)
            }

            guard let oldest = records.first else { return nil }

            let currentContent = (try? Data(contentsOf: URL(fileURLWithPath: filePath))) ?? Data()
            try oldest.content.write(to: URL(fileURLWithPath: filePath))

            _ = try await dbPool.write { db in
                try FileVersionRecord
                    .filter(Column("conversationId") == conversationId)
                    .filter(Column("filePath") == filePath)
                    .deleteAll(db)
            }

            let summary = diffSummary(
                original: oldest.content,
                current: currentContent,
                path: filePath,
            )

            return UndoResult(
                restoredPath: filePath,
                versionsReverted: records.count,
                diffSummary: summary,
            )
        } catch {
            return nil
        }
    }

    /// Remove old versions, keeping only the most recent `keepLast` entries.
    ///
    /// - Parameters:
    ///   - conversationId: The conversation context.
    ///   - filePath: Absolute path of the file.
    ///   - keepLast: Number of most recent versions to retain.
    public func pruneVersions(conversationId: Int64, filePath: String, keepLast: Int) async {
        do {
            try await dbPool.write { db in
                let count = try FileVersionRecord
                    .filter(Column("conversationId") == conversationId)
                    .filter(Column("filePath") == filePath)
                    .fetchCount(db)

                guard count > keepLast else { return }

                let toDelete = count - keepLast
                let oldestIds = try FileVersionRecord
                    .filter(Column("conversationId") == conversationId)
                    .filter(Column("filePath") == filePath)
                    .order(Column("createdAt").asc)
                    .limit(toDelete)
                    .fetchAll(db)
                    .compactMap(\.id)

                try FileVersionRecord
                    .filter(oldestIds.contains(Column("id")))
                    .deleteAll(db)
            }
        } catch {
            // Prune failures are non-fatal.
        }
    }

    /// Count the number of stored versions for a given (conversation, file) pair.
    ///
    /// - Parameters:
    ///   - conversationId: The conversation context.
    ///   - filePath: Absolute path of the file.
    /// - Returns: The number of stored versions.
    public func versionCount(conversationId: Int64, filePath: String) async throws -> Int {
        try await dbPool.read { db in
            try FileVersionRecord
                .filter(Column("conversationId") == conversationId)
                .filter(Column("filePath") == filePath)
                .fetchCount(db)
        }
    }

    /// Fetch all version records for a given (conversation, file) pair, ordered oldest-first.
    ///
    /// - Parameters:
    ///   - conversationId: The conversation context.
    ///   - filePath: Absolute path of the file.
    /// - Returns: All version records, ordered by creation date ascending.
    func versions(conversationId: Int64, filePath: String) async throws -> [FileVersionRecord] {
        try await dbPool.read { db in
            try FileVersionRecord
                .filter(Column("conversationId") == conversationId)
                .filter(Column("filePath") == filePath)
                .order(Column("createdAt").asc)
                .fetchAll(db)
        }
    }

    /// Build a brief human-readable summary comparing two file versions.
    private func diffSummary(original: Data, current: Data, path: String) -> String {
        let originalStr = String(data: original, encoding: .utf8) ?? ""
        let currentStr = String(data: current, encoding: .utf8) ?? ""

        let originalLines = originalStr.components(separatedBy: "\n").count
        let currentLines = currentStr.components(separatedBy: "\n").count
        let lineDiff = currentLines - originalLines

        let sizeChange = current.count - original.count
        let sizeDesc = if sizeChange > 0 {
            "+\(sizeChange) bytes"
        } else if sizeChange < 0 {
            "\(sizeChange) bytes"
        } else {
            "same size"
        }

        let lineDesc = if lineDiff > 0 {
            "+\(lineDiff) lines"
        } else if lineDiff < 0 {
            "\(lineDiff) lines"
        } else {
            "same line count"
        }

        return "Reverted \(path): \(sizeDesc), \(lineDesc)"
    }
}
