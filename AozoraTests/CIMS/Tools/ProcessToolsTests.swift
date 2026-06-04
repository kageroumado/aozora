import Foundation
import Testing
@testable import Aozora

struct ProcessToolsTests {
    // MARK: - Helpers

    /// Launches a zsh process, registers it with `monitor`, and returns the underlying `Process`.
    @discardableResult
    private func registerProcess(
        _ command: String,
        id: String,
        monitor: ProcessMonitor,
    ) async throws -> Process {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/zsh")
        process.arguments = ["-c", command]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        try process.run()
        await monitor.register(process, id: id, command: command)
        return process
    }

    /// Terminates a process and polls until the monitor removes it from its registry.
    ///
    /// `ProcessMonitor` removes processes from its registry after the reader task detects EOF
    /// and `handleProcessExit` runs. If the test returns before that, the monitor deinits
    /// with a live `Process`, causing a crash during `NSConcreteTask dealloc`.
    private func killAndDrain(id: String, process: Process, monitor: ProcessMonitor) async {
        process.terminate()
        process.waitUntilExit()
        for _ in 0 ..< 50 {
            let list = await monitor.listProcesses()
            if !list.contains(where: { $0.id == id }) { break }
            try? await Task.sleep(for: .milliseconds(20))
        }
    }

    // MARK: - CheckProcessTool

    @Test
    func `check_process with unknown ID returns error result`() async throws {
        let monitor = ProcessMonitor()
        let tool = CheckProcessTool(monitor: monitor)
        let result = try await tool.execute(
            parameters: ["process_id": "nonexistent"],
            workingDirectory: "/tmp",
        )
        #expect(result.isError)
        #expect(result.content.contains("nonexistent"))
    }

    @Test
    func `check_process throws on missing process_id parameter`() async throws {
        let monitor = ProcessMonitor()
        let tool = CheckProcessTool(monitor: monitor)
        await #expect(throws: ToolError.self) {
            try await tool.execute(parameters: [:], workingDirectory: "/tmp")
        }
    }

    @Test
    func `check_process returns status for registered process`() async throws {
        let monitor = ProcessMonitor()
        let process = try await registerProcess("echo start; sleep 10", id: "tool-check-1", monitor: monitor)

        let tool = CheckProcessTool(monitor: monitor)
        let result = try await tool.execute(
            parameters: ["process_id": "tool-check-1"],
            workingDirectory: "/tmp",
        )
        #expect(!result.isError)
        #expect(result.content.contains("tool-check-1"))
        #expect(result.content.contains("Running"))

        await killAndDrain(id: "tool-check-1", process: process, monitor: monitor)
    }

    @Test
    func `check_process has correct tool name`() {
        let monitor = ProcessMonitor()
        let tool = CheckProcessTool(monitor: monitor)
        #expect(tool.name == "check_process")
        #expect(tool.definition.name == "check_process")
    }

    // MARK: - KillProcessTool

    @Test
    func `kill_process with unknown ID returns error result`() async throws {
        let monitor = ProcessMonitor()
        let tool = KillProcessTool(monitor: monitor)
        let result = try await tool.execute(
            parameters: ["process_id": "no-such-id"],
            workingDirectory: "/tmp",
        )
        #expect(result.isError)
    }

    @Test
    func `kill_process terminates a running process`() async throws {
        let monitor = ProcessMonitor()
        let process = try await registerProcess("echo start; sleep 10", id: "tool-kill-1", monitor: monitor)

        let tool = KillProcessTool(monitor: monitor)
        let result = try await tool.execute(
            parameters: ["process_id": "tool-kill-1"],
            workingDirectory: "/tmp",
        )
        #expect(!result.isError)
        #expect(result.content.contains("tool-kill-1"))

        // The KillProcessTool sent SIGTERM via monitor.killProcess; wait for actual exit.
        process.waitUntilExit()
        for _ in 0 ..< 50 {
            let list = await monitor.listProcesses()
            if !list.contains(where: { $0.id == "tool-kill-1" }) { break }
            try? await Task.sleep(for: .milliseconds(20))
        }
    }

    @Test
    func `kill_process throws on missing process_id parameter`() async throws {
        let monitor = ProcessMonitor()
        let tool = KillProcessTool(monitor: monitor)
        await #expect(throws: ToolError.self) {
            try await tool.execute(parameters: [:], workingDirectory: "/tmp")
        }
    }

    @Test
    func `kill_process has correct tool name`() {
        let monitor = ProcessMonitor()
        let tool = KillProcessTool(monitor: monitor)
        #expect(tool.name == "kill_process")
        #expect(tool.definition.name == "kill_process")
    }

    // MARK: - ListProcessesTool

    @Test
    func `list_processes with no processes returns empty message`() async throws {
        let monitor = ProcessMonitor()
        let tool = ListProcessesTool(monitor: monitor)
        let result = try await tool.execute(parameters: [:], workingDirectory: "/tmp")
        #expect(!result.isError)
        #expect(result.content.contains("No background processes"))
    }

    @Test
    func `list_processes shows registered processes`() async throws {
        let monitor = ProcessMonitor()
        let process = try await registerProcess("echo start; sleep 10", id: "tool-list-1", monitor: monitor)

        let tool = ListProcessesTool(monitor: monitor)
        let result = try await tool.execute(parameters: [:], workingDirectory: "/tmp")
        #expect(!result.isError)
        #expect(result.content.contains("tool-list-1"))

        await killAndDrain(id: "tool-list-1", process: process, monitor: monitor)
    }

    @Test
    func `list_processes has correct tool name`() {
        let monitor = ProcessMonitor()
        let tool = ListProcessesTool(monitor: monitor)
        #expect(tool.name == "list_processes")
        #expect(tool.definition.name == "list_processes")
    }
}
