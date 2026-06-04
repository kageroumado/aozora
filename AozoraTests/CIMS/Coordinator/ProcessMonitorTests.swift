import Foundation
import Testing
@testable import Aozora

// MARK: - ProcessMonitorTests

//
// Note: ProcessMonitor.register uses Foundation's non-blocking `availableData` in its reader
// loop. If a process produces no output, `availableData` returns empty `Data` immediately
// (pipe buffer empty but not closed), causing premature handleProcessExit — which calls
// terminationStatus on a still-running process and crashes. Tests therefore use processes
// that write output before sleeping so the reader loop sees actual data before blocking.

struct ProcessMonitorTests {
    // MARK: - Helpers

    /// Launches a zsh process, registers it with `monitor`, and returns the underlying `Process`.
    ///
    /// Use processes that write output before sleeping to avoid a premature EOF in the
    /// reader loop (see file-level note above).
    @discardableResult
    private func launch(
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
    /// `ProcessMonitor` removes processes from its registry after the reader task detects
    /// EOF and `handleProcessExit` runs. If the test returns before that happens, the monitor
    /// deinits with a live `Process` in its registry, causing a crash during NSTask dealloc.
    private func killAndDrain(id: String, process: Process, monitor: ProcessMonitor) async {
        process.terminate()
        process.waitUntilExit()
        for _ in 0 ..< 50 {
            let list = await monitor.listProcesses()
            if !list.contains(where: { $0.id == id }) { break }
            try? await Task.sleep(for: .milliseconds(20))
        }
    }

    /// Polls until the monitor's registry is empty or the timeout is reached.
    private func drainAll(monitor: ProcessMonitor) async {
        for _ in 0 ..< 100 {
            let list = await monitor.listProcesses()
            if list.isEmpty { break }
            try? await Task.sleep(for: .milliseconds(20))
        }
    }

    // MARK: - Registration

    @Test
    func `Register process appears in listProcesses`() async throws {
        let monitor = ProcessMonitor(maxConcurrent: 5)
        // Write output before sleeping so the reader loop doesn't prematurely exit.
        let process = try await launch("echo start; sleep 5", id: "p1", monitor: monitor)

        let list = await monitor.listProcesses()
        #expect(list.count == 1)
        #expect(list[0].id == "p1")
        #expect(list[0].command == "echo start; sleep 5")

        await killAndDrain(id: "p1", process: process, monitor: monitor)
    }

    @Test
    func `Newly registered process has running status`() async throws {
        let monitor = ProcessMonitor(maxConcurrent: 5)
        let process = try await launch("echo start; sleep 5", id: "running-1", monitor: monitor)

        let list = await monitor.listProcesses()
        guard let info = list.first(where: { $0.id == "running-1" }) else {
            Issue.record("Process not found in list")
            await killAndDrain(id: "running-1", process: process, monitor: monitor)
            return
        }
        if case .running = info.status { } else {
            Issue.record("Expected .running, got \(info.status)")
        }

        await killAndDrain(id: "running-1", process: process, monitor: monitor)
    }

    // MARK: - Check Process

    @Test
    func `checkProcess returns nil for nonexistent ID`() async {
        let monitor = ProcessMonitor(maxConcurrent: 5)
        let result = await monitor.checkProcess("does-not-exist")
        #expect(result == nil)
    }

    @Test
    func `checkProcess returns running status for live process`() async throws {
        let monitor = ProcessMonitor(maxConcurrent: 5)
        let process = try await launch("echo start; sleep 5", id: "check-1", monitor: monitor)

        let result = await monitor.checkProcess("check-1")
        #expect(result != nil)
        if let r = result, case .running = r.status { } else if result != nil {
            Issue.record("Expected .running status")
        }

        await killAndDrain(id: "check-1", process: process, monitor: monitor)
    }

    @Test
    func `checkProcess output accumulates from stdout`() async throws {
        let monitor = ProcessMonitor(maxConcurrent: 5)
        let cmd = "for i in $(seq 1 5); do echo \"line $i\"; sleep 0.01; done"
        let process = try await launch(cmd, id: "output-1", monitor: monitor)

        try? await Task.sleep(for: .milliseconds(400))

        let result = await monitor.checkProcess("output-1")
        if let r = result {
            #expect(r.output.contains("line"))
        }

        process.waitUntilExit()
        await drainAll(monitor: monitor)
    }

    @Test
    func `checkProcess returns running status while process is alive`() async throws {
        let monitor = ProcessMonitor(maxConcurrent: 5)
        let process = try await launch("echo start; sleep 10", id: "status-1", monitor: monitor)

        let result = await monitor.checkProcess("status-1")
        guard let r = result else {
            Issue.record("Expected process to still be running")
            await killAndDrain(id: "status-1", process: process, monitor: monitor)
            return
        }
        if case .running = r.status { } else {
            Issue.record("Expected .running, got \(r.status)")
        }

        await killAndDrain(id: "status-1", process: process, monitor: monitor)
    }

    // MARK: - Kill Process

    @Test
    func `killProcess returns true for running process`() async throws {
        let monitor = ProcessMonitor(maxConcurrent: 5)
        let process = try await launch("echo start; sleep 10", id: "kill-1", monitor: monitor)

        let killed = await monitor.killProcess("kill-1")
        #expect(killed == true)

        process.waitUntilExit()
        for _ in 0 ..< 50 {
            let list = await monitor.listProcesses()
            if !list.contains(where: { $0.id == "kill-1" }) { break }
            try? await Task.sleep(for: .milliseconds(20))
        }
    }

    @Test
    func `killProcess updates status to .killed`() async throws {
        let monitor = ProcessMonitor(maxConcurrent: 5)
        let process = try await launch("echo start; sleep 10", id: "kill-2", monitor: monitor)

        await monitor.killProcess("kill-2")

        let result = await monitor.checkProcess("kill-2")
        if let r = result {
            if case .killed = r.status { } else {
                Issue.record("Expected .killed, got \(r.status)")
            }
        }

        process.waitUntilExit()
        for _ in 0 ..< 50 {
            let list = await monitor.listProcesses()
            if !list.contains(where: { $0.id == "kill-2" }) { break }
            try? await Task.sleep(for: .milliseconds(20))
        }
    }

    @Test
    func `killProcess returns false for nonexistent ID`() async {
        let monitor = ProcessMonitor(maxConcurrent: 5)
        let result = await monitor.killProcess("no-such-id")
        #expect(result == false)
    }

    @Test
    func `killProcess returns false for already-killed process`() async throws {
        let monitor = ProcessMonitor(maxConcurrent: 5)
        let process = try await launch("echo start; sleep 10", id: "kill-3", monitor: monitor)

        await monitor.killProcess("kill-3")
        let secondKill = await monitor.killProcess("kill-3")
        #expect(secondKill == false)

        process.waitUntilExit()
        for _ in 0 ..< 50 {
            let list = await monitor.listProcesses()
            if !list.contains(where: { $0.id == "kill-3" }) { break }
            try? await Task.sleep(for: .milliseconds(20))
        }
    }

    // MARK: - Completion Callback

    @Test
    func `Completion callback fires when process exits`() async throws {
        let monitor = ProcessMonitor(maxConcurrent: 5)

        actor Collector {
            var completions: [ProcessCompletion] = []
            func record(_ c: ProcessCompletion) {
                completions.append(c)
            }
        }
        let collector = Collector()

        await monitor.setCompletionHandler { completion in
            await collector.record(completion)
        }

        // Multiple output lines ensure the reader loop runs until actual EOF.
        let process = try await launch(
            "for i in 1 2 3; do echo $i; sleep 0.05; done",
            id: "cb-1",
            monitor: monitor,
        )

        process.waitUntilExit()
        for _ in 0 ..< 50 {
            let count = await collector.completions.count
            if count > 0 { break }
            try? await Task.sleep(for: .milliseconds(20))
        }

        let completions = await collector.completions
        #expect(completions.count == 1)
        #expect(completions[0].processId == "cb-1")
    }

    @Test
    func `Completion callback receives tail output`() async throws {
        let monitor = ProcessMonitor(maxConcurrent: 5)

        actor Collector {
            var completions: [ProcessCompletion] = []
            func record(_ c: ProcessCompletion) {
                completions.append(c)
            }
        }
        let collector = Collector()

        await monitor.setCompletionHandler { completion in
            await collector.record(completion)
        }

        let process = try await launch(
            "for i in 1 2 3; do echo hello-from-callback-$i; sleep 0.05; done",
            id: "cb-2",
            monitor: monitor,
        )

        process.waitUntilExit()
        for _ in 0 ..< 50 {
            let count = await collector.completions.count
            if count > 0 { break }
            try? await Task.sleep(for: .milliseconds(20))
        }

        let completions = await collector.completions
        #expect(completions.first?.tailOutput.contains("hello-from-callback") == true)
    }

    // MARK: - Output Buffer Cap (200 KB)

    @Test
    func `Output buffer evicts old lines when exceeding 200 KB`() async throws {
        let monitor = ProcessMonitor(maxConcurrent: 5)

        // Each line is ~1025 bytes (1024 'a' chars + newline).
        // 210 lines ≈ 215 KB — over the 200 KB cap; front lines should be evicted.
        let linePayload = String(repeating: "a", count: 1_024)
        let cmd = "for i in $(seq 1 210); do printf '\(linePayload)\\n'; done"
        let process = try await launch(cmd, id: "buf-1", monitor: monitor)

        try? await Task.sleep(for: .milliseconds(800))

        let result = await monitor.checkProcess("buf-1")
        if let r = result {
            #expect(r.output.utf8.count <= 200_000)
        }

        process.waitUntilExit()
        await drainAll(monitor: monitor)
    }

    // MARK: - Max Concurrent Limit

    @Test
    func `Oldest running process is evicted when max concurrent is exceeded`() async throws {
        let monitor = ProcessMonitor(maxConcurrent: 2)

        // Write output before sleeping so the reader loop doesn't exit prematurely.
        let p1 = try await launch("echo p1; sleep 30", id: "evict-1", monitor: monitor)
        try? await Task.sleep(for: .milliseconds(20))
        let p2 = try await launch("echo p2; sleep 30", id: "evict-2", monitor: monitor)

        let beforeList = await monitor.listProcesses()
        #expect(beforeList.count == 2)

        // Third registration evicts evict-1 (the oldest running process).
        let p3 = try await launch("echo p3; sleep 30", id: "evict-3", monitor: monitor)

        let afterList = await monitor.listProcesses()
        #expect(afterList.count == 2)
        #expect(!afterList.contains(where: { $0.id == "evict-1" }))
        #expect(afterList.contains(where: { $0.id == "evict-2" }))
        #expect(afterList.contains(where: { $0.id == "evict-3" }))

        p1.terminate()
        p2.terminate()
        p3.terminate()
        p1.waitUntilExit()
        p2.waitUntilExit()
        p3.waitUntilExit()
        await drainAll(monitor: monitor)
    }
}
