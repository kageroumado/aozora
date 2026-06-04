import Foundation

/// Timestamped logging for the daemon. Prefixes each line with `HH:mm:ss`.
///
/// Use instead of `print()` for log lines that benefit from timestamps.
/// Existing `print()` calls can be migrated incrementally.
func log(_ message: String) {
    let now = Date()
    let formatter = DaemonLog.formatter
    let timestamp = formatter.string(from: now)
    print("\(timestamp) \(message)")
}

/// Shared formatter to avoid repeated allocation.
private enum DaemonLog {
    nonisolated(unsafe) static let formatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "HH:mm:ss"
        f.timeZone = TimeZone(identifier: "Europe/Paris")
        return f
    }()
}
