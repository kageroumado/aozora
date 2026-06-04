import Foundation

/// Tracks file reads and validates that files are read before being edited or overwritten.
///
/// When ``ReadTool`` successfully reads a file, it records the path and the file's modification
/// date via ``recordRead(path:modificationDate:)``. When ``EditTool`` or ``WriteTool`` attempts
/// to modify an existing file, it calls ``validateAccess(path:fileExists:)`` which checks:
///
/// 1. The file was previously read (recorded in the tracker).
/// 2. The read hasn't expired (default 30-minute window).
/// 3. The file hasn't been modified externally since the read.
///
/// New file creation (file doesn't exist on disk) bypasses all checks.
public actor FileAccessTracker {
    /// A record of a file read operation.
    struct ReadRecord {
        /// The file's modification date at the time it was read.
        let modificationDate: Date

        /// When the read was recorded.
        let readAt: Date
    }

    /// Read records keyed by resolved absolute file path.
    private var records: [String: ReadRecord] = [:]

    /// How long a read remains valid before requiring a re-read.
    private let expiryInterval: TimeInterval

    /// Create a tracker with the given expiry interval.
    ///
    /// - Parameter expiryInterval: Seconds before a read record expires. Default 1800 (30 minutes).
    public init(expiryInterval: TimeInterval = 1_800) {
        self.expiryInterval = expiryInterval
    }

    /// Record that a file was successfully read.
    ///
    /// Overwrites any previous record for the same path. Periodically prunes expired records
    /// when the record count exceeds 100.
    ///
    /// - Parameters:
    ///   - path: Resolved absolute path of the file that was read.
    ///   - modificationDate: The file's modification date at read time.
    public func recordRead(path: String, modificationDate: Date) {
        records[path] = ReadRecord(modificationDate: modificationDate, readAt: Date())
        pruneExpiredIfNeeded()
    }

    /// Validate that a file can be edited or written to.
    ///
    /// Returns `nil` if access is allowed, or a human-readable error message if not.
    /// New file creation (where `fileExists` is `false`) always passes.
    ///
    /// - Parameters:
    ///   - path: Resolved absolute path of the file to modify.
    ///   - fileExists: Whether the file currently exists on disk.
    /// - Returns: `nil` if access is permitted, or an error message string describing why access was denied.
    public func validateAccess(path: String, fileExists: Bool) -> String? {
        guard fileExists else { return nil }

        guard let record = records[path] else {
            return "You must read '\(path)' before editing it. Use the read tool first."
        }

        let elapsed = Date().timeIntervalSince(record.readAt)
        if elapsed > expiryInterval {
            let minutes = Int(elapsed / 60)
            records[path] = nil
            return "Your read of '\(path)' expired (\(minutes) minutes ago). Read it again before editing."
        }

        let currentModDate = fileModificationDate(path)
        if let currentModDate, currentModDate != record.modificationDate {
            records[path] = nil
            return "File '\(path)' was modified externally since you last read it. Read it again to get the current content."
        }

        return nil
    }

    /// Get the file's modification date, if it exists.
    private nonisolated func fileModificationDate(_ path: String) -> Date? {
        try? FileManager.default.attributesOfItem(atPath: path)[.modificationDate] as? Date
    }

    /// Prune expired records when the collection grows beyond 100 entries.
    private func pruneExpiredIfNeeded() {
        guard records.count > 100 else { return }
        let now = Date()
        records = records.filter { now.timeIntervalSince($0.value.readAt) < expiryInterval }
    }
}
