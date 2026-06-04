import Foundation
import Testing
@testable import Aozora

@Suite("BashTool")
struct BashToolTests {
    let tool = BashTool()
    let workdir = "/tmp"

    @Test("executes a simple command")
    func simpleCommand() async throws {
        let result = try await tool.execute(
            parameters: ["command": "echo hello world"],
            workingDirectory: workdir
        )

        #expect(!result.isError)
        #expect(result.content.contains("Exit code: 0"))
        #expect(result.content.contains("hello world"))
    }

    @Test("captures stderr")
    func capturesStderr() async throws {
        let result = try await tool.execute(
            parameters: ["command": "echo error >&2"],
            workingDirectory: workdir
        )

        #expect(result.content.contains("Exit code: 0"))
        #expect(result.content.contains("error"))
    }

    @Test("reports nonzero exit code as error")
    func nonzeroExitCode() async throws {
        let result = try await tool.execute(
            parameters: ["command": "exit 42"],
            workingDirectory: workdir
        )

        #expect(result.isError)
        #expect(result.content.contains("Exit code: 42"))
    }

    @Test("uses custom working directory")
    func customWorkdir() async throws {
        let result = try await tool.execute(
            parameters: ["command": "pwd", "workdir": "/usr"],
            workingDirectory: workdir
        )

        #expect(!result.isError)
        #expect(result.content.contains("/usr"))
    }

    @Test("throws on missing command parameter")
    func missingCommand() async throws {
        await #expect(throws: ToolError.self) {
            try await tool.execute(
                parameters: [:],
                workingDirectory: workdir
            )
        }
    }

    @Test("timeout kills long-running process")
    func timeoutKillsProcess() async throws {
        let result = try await tool.execute(
            parameters: ["command": "sleep 30", "timeout": 500],
            workingDirectory: workdir
        )

        #expect(result.isError)
        #expect(result.content.contains("timed out"))
    }

    @Test("truncates large output")
    func truncatesOutput() {
        let longOutput = String(repeating: "x", count: 60_000)
        let truncated = BashTool.truncateOutput(longOutput)
        #expect(truncated.utf8.count < 55_000)
    }

    @Test("definition has correct name")
    func definitionName() {
        #expect(tool.definition.name == "bash")
        #expect(tool.name == "bash")
    }
}
