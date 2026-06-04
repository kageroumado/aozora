import ArgumentParser
import Foundation

/// Show the daemon's current status — what it's doing right now.
///
/// Reads the daemon log to determine the current state: idle, processing
/// a turn (with tool details), heartbeating, or not running. This is a
/// read-only diagnostic — it doesn't interact with the conversation.
struct StatusSubcommand: AsyncParsableCommand {
    nonisolated static let configuration = CommandConfiguration(
        commandName: "status",
        abstract: "Show what the daemon is currently doing.",
    )

    @Option(name: .long, help: "Number of recent log lines to scan.")
    var lines: Int = 50

    func run() async throws {
        let logPath = NSHomeDirectory() + "/.aozora/logs/daemon.log"
        let pidRunning = isDaemonRunning()

        guard pidRunning else {
            print("Status: not running")
            return
        }

        guard let logData = FileManager.default.contents(atPath: logPath),
              let logText = String(data: logData, encoding: .utf8)
        else {
            print("Status: running (no logs)")
            return
        }

        let allLines = logText.components(separatedBy: "\n")
        let recentLines = Array(allLines.suffix(lines))

        // Find the last state-indicating log line
        var lastTool: (name: String, args: String, iteration: String)?
        var lastToolDone: String?
        var lastHeartbeat: String?
        var lastReady = false
        var lastStreamStop: String?
        var lastIncoming: String?

        for line in recentLines {
            if line.contains("[tool]"), !line.contains("done") {
                // [tool] 3/25 bash: cd ~/Developer && ls
                let parts = line.components(separatedBy: "[tool] ").last ?? ""
                let segments = parts.components(separatedBy: " ")
                if segments.count >= 2 {
                    let iter = segments[0]
                    let nameAndArgs = segments.dropFirst().joined(separator: " ")
                    let colonIdx = nameAndArgs.firstIndex(of: ":")
                    if let idx = colonIdx {
                        lastTool = (
                            name: String(nameAndArgs[nameAndArgs.startIndex ..< idx]),
                            args: String(nameAndArgs[nameAndArgs.index(after: idx)...]).trimmingCharacters(in: .whitespaces),
                            iteration: iter,
                        )
                    } else {
                        lastTool = (name: nameAndArgs, args: "", iteration: iter)
                    }
                    lastToolDone = nil
                }
            }
            if line.contains("[tool]"), line.contains("done") {
                lastToolDone = line
                lastTool = nil
            }
            if line.contains("[heartbeat]") {
                lastHeartbeat = line
            }
            if line.contains("Aozora daemon ready") {
                lastReady = true
            }
            if line.contains("stop=") {
                lastStreamStop = line
            }
            if line.contains("[→]") {
                lastIncoming = line
            }
        }

        // Determine status
        if let tool = lastTool {
            print("Status: processing turn")
            print("  Tool: \(tool.name) (iteration \(tool.iteration))")
            if !tool.args.isEmpty {
                print("  Args: \(tool.args.prefix(100))")
            }
        } else if let stop = lastStreamStop, stop.contains("stop=tool_use"), lastToolDone == nil {
            print("Status: processing turn (awaiting API response)")
        } else if let hb = lastHeartbeat, hb.contains("Alert:") || (!hb.contains("OK") && !hb.contains("Skipped")) {
            print("Status: heartbeating")
        } else {
            print("Status: idle")
        }

        // Show last activity
        if let incoming = lastIncoming {
            let msg = incoming.components(separatedBy: "[→] ").last ?? ""
            print("  Last message: \(msg.prefix(80))")
        }

        // Show recent tool completions
        let recentToolDone = recentLines.filter { $0.contains("[tool]") && $0.contains("done") }.suffix(3)
        if !recentToolDone.isEmpty {
            print("  Recent tools:")
            for line in recentToolDone {
                let parts = line.components(separatedBy: "[tool] ").last ?? ""
                print("    \(parts.prefix(100))")
            }
        }
    }

    private func isDaemonRunning() -> Bool {
        let binaryPath = NSHomeDirectory() + "/.aozora/bin/aozora"
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/usr/bin/pgrep")
        task.arguments = ["-f", binaryPath]
        let pipe = Pipe()
        task.standardOutput = pipe
        task.standardError = pipe
        try? task.run()
        task.waitUntilExit()
        return task.terminationStatus == 0
    }
}
