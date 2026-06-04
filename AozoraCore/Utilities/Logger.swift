import Foundation
import os

/// Structured logging facade for Aozora.
///
/// Wraps `os.Logger` for system-level logging (Console.app, unified log) and
/// ``FileLogger`` for daemon log file output. Every log line includes a category
/// tag for filtering.
///
/// Usage:
/// ```swift
/// private let log = Log.make(category: "tools")
/// log.info("Tool registered: \(name)")
/// log.error("Execution failed: \(error)")
/// ```
public enum Log {
    /// The unified log subsystem identifier.
    static let subsystem = "ai.aozora"

    /// Shared file logger instance, initialized on first use.
    ///
    /// Writes to `~/.aozora/logs/daemon.log` with automatic rotation at 10 MB.
    public nonisolated(unsafe) static var fileLogger: FileLogger?

    /// Initialize the file logger for daemon mode.
    ///
    /// Call once during daemon startup. If not called, file logging is silently skipped
    /// (appropriate for tests and the macOS app which use Console.app instead).
    ///
    /// - Parameter path: Absolute path to the log file. Defaults to `~/.aozora/logs/daemon.log`.
    public static func enableFileLogging(path: String = NSHomeDirectory() + "/.aozora/logs/daemon.log") {
        fileLogger = FileLogger(path: path)
    }

    /// Create a logger for the given category.
    ///
    /// Categories map to subsystems: `"tools"`, `"coordinator"`, `"discord"`, `"mcp"`,
    /// `"consolidation"`, `"worker"`, `"cron"`, `"lsp"`, etc.
    ///
    /// - Parameter category: The log category string used for filtering in Console.app.
    /// - Returns: An `os.Logger` scoped to the Aozora subsystem and the given category.
    public static func make(category: String) -> os.Logger {
        os.Logger(subsystem: subsystem, category: category)
    }

    /// Log an informational message to both os.Logger and the file logger.
    ///
    /// Prefer using the `os.Logger` instance directly for performance-critical paths.
    /// Use these static methods when you need guaranteed file output (daemon lifecycle events).
    ///
    /// - Parameters:
    ///   - category: The log category for filtering.
    ///   - message: The message to log.
    public static func info(_ category: String, _ message: String) {
        os.Logger(subsystem: subsystem, category: category).info("\(message, privacy: .public)")
        fileLogger?.log(level: .info, category: category, message: message)
    }

    /// Log an error message to both os.Logger and the file logger.
    ///
    /// - Parameters:
    ///   - category: The log category for filtering.
    ///   - message: The message to log.
    public static func error(_ category: String, _ message: String) {
        os.Logger(subsystem: subsystem, category: category).error("\(message, privacy: .public)")
        fileLogger?.log(level: .error, category: category, message: message)
    }

    /// Log a debug message to both os.Logger and the file logger.
    ///
    /// - Parameters:
    ///   - category: The log category for filtering.
    ///   - message: The message to log.
    public static func debug(_ category: String, _ message: String) {
        os.Logger(subsystem: subsystem, category: category).debug("\(message, privacy: .public)")
        fileLogger?.log(level: .debug, category: category, message: message)
    }

    /// Log a warning message to both os.Logger and the file logger.
    ///
    /// - Parameters:
    ///   - category: The log category for filtering.
    ///   - message: The message to log.
    public static func warning(_ category: String, _ message: String) {
        os.Logger(subsystem: subsystem, category: category).warning("\(message, privacy: .public)")
        fileLogger?.log(level: .warning, category: category, message: message)
    }
}

/// Appends structured log lines to a file with automatic size-based rotation.
///
/// Thread-safe via a serial `DispatchQueue`. Rotation truncates the file when it
/// exceeds `maxBytes`, preserving only the most recent half — preventing unbounded growth
/// while retaining recent history.
///
/// Log line format: `YYYY-MM-DDTHH:MM:SS.sssZ LEVEL [category] message`
public final class FileLogger: Sendable {
    /// Log severity levels for file output.
    public enum Level: String, Sendable {
        /// Verbose diagnostic information.
        case debug = "DEBUG"
        /// Normal operational events.
        case info = "INFO"
        /// Potentially problematic conditions.
        case warning = "WARN"
        /// Errors that require attention.
        case error = "ERROR"
    }

    /// Absolute path to the log file.
    private let path: String

    /// Maximum file size in bytes before rotation is triggered.
    private let maxBytes: Int

    /// Serial queue ensuring thread-safe file writes.
    private let queue: DispatchQueue

    /// Create a file logger.
    ///
    /// - Parameters:
    ///   - path: Absolute path to the log file. Parent directories are created if needed.
    ///   - maxBytes: Maximum file size before rotation. Defaults to 10 MB.
    public init(path: String, maxBytes: Int = 10_000_000) {
        self.path = path
        self.maxBytes = maxBytes
        self.queue = DispatchQueue(label: "ai.aozora.filelogger")

        let dir = (path as NSString).deletingLastPathComponent
        try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)

        if !FileManager.default.fileExists(atPath: path) {
            FileManager.default.createFile(atPath: path, contents: nil)
        }
    }

    /// Append a structured log line synchronously.
    ///
    /// Blocks the caller until the write completes, ensuring the log file contains
    /// the entry before returning. This makes file logger writes deterministic for tests.
    ///
    /// When the file exceeds `maxBytes`, the first half is discarded and the second half
    /// is rewritten from offset 0, keeping the file bounded.
    ///
    /// - Parameters:
    ///   - level: Severity level written as a fixed-width tag.
    ///   - category: Category tag written as `[category]`.
    ///   - message: The log message body.
    public func log(level: Level, category: String, message: String) {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let timestamp = formatter.string(from: Date())
        let line = "\(timestamp) \(level.rawValue) [\(category)] \(message)\n"

        queue.sync { [path, maxBytes] in
            guard let handle = FileHandle(forUpdatingAtPath: path) else { return }
            defer { try? handle.close() }

            handle.seekToEndOfFile()
            let currentSize = handle.offsetInFile

            if currentSize > UInt64(maxBytes) {
                let keepFrom = currentSize / 2
                handle.seek(toFileOffset: keepFrom)
                let kept = handle.readDataToEndOfFile()
                handle.seek(toFileOffset: 0)
                handle.write(kept)
                handle.truncateFile(atOffset: UInt64(kept.count))
                handle.seekToEndOfFile()
            }

            if let data = line.data(using: .utf8) {
                handle.write(data)
            }
        }
    }
}
