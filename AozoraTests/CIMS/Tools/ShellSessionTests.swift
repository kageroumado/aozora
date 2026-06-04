import Foundation
import Testing
@testable import Aozora

/// Tests for ``ShellSession`` — persistent shell with environment/state preservation.
///
/// These tests verify that the shell session correctly:
/// - Preserves environment variables across commands
/// - Preserves working directory across commands
/// - Reports exit codes accurately
/// - Handles timeouts without killing the session
/// - Respawns after the shell process dies
/// - Serializes concurrent commands
struct ShellSessionTests {
    // MARK: - Basic Execution

    @Test
    func `Simple command produces output`() async throws {
        let session = ShellSession(workdir: "/tmp")
        defer { Task { await session.shutdown() } }

        let (output, exitCode) = try await session.execute(command: "echo hello")
        #expect(exitCode == 0)
        #expect(output.trimmingCharacters(in: .whitespacesAndNewlines) == "hello")
    }

    @Test
    func `Exit code reported correctly`() async throws {
        let session = ShellSession(workdir: "/tmp")
        defer { Task { await session.shutdown() } }

        let (_, exitCode) = try await session.execute(command: "false")
        #expect(exitCode == 1)
    }

    @Test
    func `Nonzero exit code from exit command`() async throws {
        let session = ShellSession(workdir: "/tmp")
        defer { Task { await session.shutdown() } }

        // Use a subshell so exit doesn't kill the persistent shell
        let (_, exitCode) = try await session.execute(command: "(exit 42)")
        #expect(exitCode == 42)
    }

    // MARK: - State Persistence

    @Test
    func `Environment variables persist across commands`() async throws {
        let session = ShellSession(workdir: "/tmp")
        defer { Task { await session.shutdown() } }

        _ = try await session.execute(command: "export TEST_SHELL_VAR=persistent_value")
        let (output, exitCode) = try await session.execute(command: "echo $TEST_SHELL_VAR")

        #expect(exitCode == 0)
        #expect(output.trimmingCharacters(in: .whitespacesAndNewlines) == "persistent_value")
    }

    @Test
    func `Working directory persists via cd`() async throws {
        let session = ShellSession(workdir: "/tmp")
        defer { Task { await session.shutdown() } }

        _ = try await session.execute(command: "cd /usr")
        let (output, exitCode) = try await session.execute(command: "pwd")

        #expect(exitCode == 0)
        #expect(output.trimmingCharacters(in: .whitespacesAndNewlines) == "/usr")
    }

    @Test
    func `Workdir parameter changes directory for command`() async throws {
        let session = ShellSession(workdir: "/tmp")
        defer { Task { await session.shutdown() } }

        let (output, exitCode) = try await session.execute(command: "pwd", workdir: "/usr")

        #expect(exitCode == 0)
        #expect(output.trimmingCharacters(in: .whitespacesAndNewlines) == "/usr")
    }

    @Test
    func `Multiple env vars accumulate`() async throws {
        let session = ShellSession(workdir: "/tmp")
        defer { Task { await session.shutdown() } }

        _ = try await session.execute(command: "export A=1")
        _ = try await session.execute(command: "export B=2")
        let (output, exitCode) = try await session.execute(command: "echo $A-$B")

        #expect(exitCode == 0)
        #expect(output.trimmingCharacters(in: .whitespacesAndNewlines) == "1-2")
    }

    // MARK: - Timeout

    @Test
    func `Timeout kills command but shell survives`() async throws {
        let session = ShellSession(workdir: "/tmp")
        defer { Task { await session.shutdown() } }

        // Use a short timeout — sleep should be interrupted
        do {
            _ = try await session.execute(command: "sleep 30", timeoutMs: 500)
            Issue.record("Expected ShellError.timeout")
        } catch is ShellError {
            // Expected
        }

        // Shell should still be alive — run another command
        let (output, exitCode) = try await session.execute(command: "echo still_alive")
        #expect(exitCode == 0)
        #expect(output.trimmingCharacters(in: .whitespacesAndNewlines) == "still_alive")
    }

    // MARK: - Respawn

    @Test
    func `Shell respawns after crash`() async throws {
        let session = ShellSession(workdir: "/tmp")
        defer { Task { await session.shutdown() } }

        // Run a command to start the shell
        _ = try await session.execute(command: "echo warmup")

        // Verify shell is running
        let running = await session.isRunning
        #expect(running)

        // Kill the shell process by sending exit to it
        // (this terminates the persistent shell, not a subshell)
        _ = try? await session.execute(command: "kill $$", timeoutMs: 1_000)

        // Brief pause for process to die
        try await Task.sleep(for: .milliseconds(200))

        // Next command should trigger respawn
        let (output, exitCode) = try await session.execute(command: "echo respawned")
        #expect(exitCode == 0)
        #expect(output.trimmingCharacters(in: .whitespacesAndNewlines) == "respawned")
    }

    // MARK: - Output Handling

    @Test
    func `Multi-line output captured correctly`() async throws {
        let session = ShellSession(workdir: "/tmp")
        defer { Task { await session.shutdown() } }

        let (output, exitCode) = try await session.execute(command: "echo line1; echo line2; echo line3")
        #expect(exitCode == 0)
        let lines = output.trimmingCharacters(in: .whitespacesAndNewlines).components(separatedBy: "\n")
        #expect(lines == ["line1", "line2", "line3"])
    }

    @Test
    func `Command with stderr output captured`() async throws {
        let session = ShellSession(workdir: "/tmp")
        defer { Task { await session.shutdown() } }

        let (output, exitCode) = try await session.execute(command: "echo err >&2; echo out")
        #expect(exitCode == 0)
        #expect(output.contains("err"))
        #expect(output.contains("out"))
    }

    @Test
    func `Empty command produces minimal output`() async throws {
        let session = ShellSession(workdir: "/tmp")
        defer { Task { await session.shutdown() } }

        let (output, exitCode) = try await session.execute(command: "true")
        #expect(exitCode == 0)
        #expect(output.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
    }

    // MARK: - Cleanup

    @Test
    func `Shutdown terminates shell process`() async throws {
        let session = ShellSession(workdir: "/tmp")

        _ = try await session.execute(command: "echo warmup")
        #expect(await session.isRunning)

        await session.shutdown()

        // Brief pause for process to terminate
        try await Task.sleep(for: .milliseconds(100))

        #expect(await !session.isRunning)
    }
}
