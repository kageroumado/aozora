import Foundation
import os

/// Persistent shell session that preserves environment, working directory, and
/// shell state (aliases, venvs) across commands.
///
/// Instead of spawning a new `/bin/zsh -c` for each command (losing all state),
/// ``ShellSession`` keeps a single shell process alive and sends commands via stdin.
/// A unique sentinel marker after each command delimits the output boundary and
/// captures the exit code.
///
/// The session respawns transparently if the underlying shell process dies.
///
/// Thread safety: actor-isolated for all state mutations. The output buffer
/// (``ShellBuffer``) is `Sendable` and lock-protected, written from the pipe's
/// readability handler on an arbitrary thread.
///
/// → MASTER-PLAN Plan 2A
public actor ShellSession {
    /// The default working directory for new shell sessions.
    private let defaultWorkdir: String

    /// The underlying shell process.
    private var process: Process?

    /// Pipe for writing commands to the shell's stdin.
    private var stdinPipe: Pipe?

    /// Thread-safe buffer for accumulating shell output.
    private let buffer = ShellBuffer()

    /// Default timeout for commands (5 minutes).
    public static let defaultTimeoutMs = 300_000

    /// Creates a shell session rooted at the given working directory.
    ///
    /// The shell is not started until the first command is executed.
    ///
    /// - Parameter workdir: Default working directory for the shell.
    public init(workdir: String) {
        self.defaultWorkdir = workdir
    }

    /// Execute a command in the persistent shell.
    ///
    /// The command runs in the shell's current environment. If `workdir` is provided,
    /// the shell `cd`s there first (this persists for subsequent commands). Environment
    /// variables, aliases, and virtual environment activations all persist across calls.
    ///
    /// - Parameters:
    ///   - command: The shell command to execute.
    ///   - workdir: Optional working directory override for this command.
    ///   - timeoutMs: Timeout in milliseconds. Defaults to 5 minutes.
    /// - Returns: A tuple of (output, exitCode).
    /// - Throws: ``ShellError`` on timeout or shell failure.
    public func execute(
        command: String,
        workdir: String? = nil,
        timeoutMs: Int = defaultTimeoutMs,
    ) async throws -> (output: String, exitCode: Int32) {
        try ensureRunning()

        let sentinel = "AOZORA_\(UUID().uuidString.replacingOccurrences(of: "-", with: "").prefix(16))"

        buffer.beginCommand()

        // Build the command payload:
        // 1. Optional cd to workdir
        // 2. The actual command
        // 3. Sentinel with exit code capture
        var payload = ""
        if let workdir {
            payload += "cd \(shellQuote(workdir)) 2>/dev/null\n"
        }
        payload += command
        // printf ensures the sentinel is on its own line with no shell expansion
        payload += "\nprintf '\\n\(sentinel)_%d\\n' \"$?\"\n"

        guard let data = payload.data(using: .utf8) else {
            throw ShellError.internalError("Failed to encode command as UTF-8")
        }

        stdinPipe?.fileHandleForWriting.write(data)

        // Poll for sentinel with timeout
        let deadline = ContinuousClock.now + .milliseconds(timeoutMs)

        while ContinuousClock.now < deadline {
            if let result = buffer.extractResult(sentinel: sentinel) {
                return result
            }
            try await Task.sleep(for: .milliseconds(25))
        }

        // Timeout — send SIGINT to the shell's process group to kill the foreground command
        if let pid = process?.processIdentifier {
            kill(-pid, SIGINT)
        }

        // Brief grace period for the interrupt to take effect
        try? await Task.sleep(for: .milliseconds(200))

        // Check once more for output after interrupt
        if let result = buffer.extractResult(sentinel: sentinel) {
            return result
        }

        throw ShellError.timeout(timeoutMs)
    }

    /// Stop the shell process and release resources.
    public func shutdown() {
        stdinPipe?.fileHandleForWriting.closeFile()
        process?.terminate()
        process = nil
        stdinPipe = nil
    }

    /// Whether the underlying shell process is currently running.
    public var isRunning: Bool {
        process?.isRunning ?? false
    }

    // MARK: - Private

    /// Ensure the shell process is running, starting or restarting it if needed.
    private func ensureRunning() throws {
        if let process, process.isRunning { return }

        // Clean up dead process
        process = nil
        stdinPipe = nil
        buffer.reset()

        let newProcess = Process()
        newProcess.executableURL = URL(fileURLWithPath: "/bin/zsh")
        // Login shell for profile loading, but not interactive (avoids prompt/job control noise)
        newProcess.arguments = ["-l"]
        newProcess.currentDirectoryURL = URL(fileURLWithPath: defaultWorkdir)

        // Set up a new process group so we can SIGINT the foreground command
        // without killing our own process
        newProcess.qualityOfService = .userInitiated

        let stdin = Pipe()
        let stdout = Pipe()

        newProcess.standardInput = stdin
        newProcess.standardOutput = stdout
        newProcess.standardError = stdout

        // Continuous reading from the shell's output
        let buf = buffer
        stdout.fileHandleForReading.readabilityHandler = { handle in
            let data = handle.availableData
            guard !data.isEmpty else { return }
            buf.append(data)
        }

        try newProcess.run()

        process = newProcess
        stdinPipe = stdin

        // Disable prompt by sending a no-op initialization command
        let initCmd = "export PS1='' PS2='' PROMPT='' RPROMPT=''\n"
        if let initData = initCmd.data(using: .utf8) {
            stdin.fileHandleForWriting.write(initData)
        }

        // Brief pause for the shell to initialize
        // (we don't wait for output — the first real command will use sentinel-based sync)
    }

    /// Quote a string for safe use as a shell argument.
    private func shellQuote(_ str: String) -> String {
        "'" + str.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }
}

// MARK: - ShellBuffer

/// Thread-safe output buffer for a persistent shell session.
///
/// Accumulates raw bytes from the shell's stdout/stderr pipe (written from
/// the readability handler on an arbitrary thread) and provides sentinel-based
/// extraction for per-command output boundaries.
final class ShellBuffer: Sendable {
    private let state = OSAllocatedUnfairLock(initialState: BufferState())

    struct BufferState {
        /// All accumulated output since the shell started.
        var data = Data()

        /// Byte offset where the current command's output begins.
        var commandStart = 0
    }

    /// Append raw output data from the shell pipe.
    func append(_ chunk: Data) {
        state.withLock { $0.data.append(chunk) }
    }

    /// Mark the start of a new command's output region.
    func beginCommand() {
        state.withLock { $0.commandStart = $0.data.count }
    }

    /// Reset the buffer (used when the shell is restarted).
    func reset() {
        state.withLock {
            $0.data = Data()
            $0.commandStart = 0
        }
    }

    /// Try to extract the command's output and exit code using the sentinel.
    ///
    /// The sentinel pattern is: `\n<sentinel>_<exitcode>\n`
    ///
    /// - Parameter sentinel: The unique sentinel string for this command.
    /// - Returns: A tuple of (output text before sentinel, exit code), or `nil` if
    ///   the sentinel hasn't appeared yet.
    func extractResult(sentinel: String) -> (String, Int32)? {
        state.withLock { state in
            let relevant = state.data[state.commandStart...]
            guard let text = String(data: Data(relevant), encoding: .utf8) else { return nil }

            // Look for the sentinel line: \n<sentinel>_<exitcode>\n
            let marker = "\n\(sentinel)_"
            guard let markerRange = text.range(of: marker) else { return nil }

            let afterMarker = text[markerRange.upperBound...]
            guard let newline = afterMarker.firstIndex(of: "\n") else { return nil }

            let exitCodeStr = afterMarker[..<newline]
            let exitCode = Int32(exitCodeStr) ?? -1

            // Output is everything from command start to the sentinel's newline
            let output = String(text[..<markerRange.lowerBound])

            return (output, exitCode)
        }
    }

    /// Get the current accumulated output size in bytes.
    var byteCount: Int {
        state.withLock { $0.data.count }
    }
}

// MARK: - ShellError

/// Errors from the persistent shell session.
public enum ShellError: Error, LocalizedError {
    /// The command timed out.
    case timeout(Int)

    /// Internal error (e.g., encoding failure).
    case internalError(String)

    public var errorDescription: String? {
        switch self {
        case let .timeout(ms): "Command timed out after \(ms)ms"
        case let .internalError(msg): "Shell error: \(msg)"
        }
    }
}
