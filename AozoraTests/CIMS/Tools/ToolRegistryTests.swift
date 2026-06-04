import Foundation
import Testing
@testable import Aozora

@Suite("ToolRegistry")
struct ToolRegistryTests {
    @Test("registers and executes a tool")
    func registerAndExecute() async throws {
        let registry = ToolRegistry()
        await registry.register(BashTool())

        let result = try await registry.execute(
            name: "bash",
            parameters: ["command": "echo hello"],
            workingDirectory: "/tmp"
        )

        #expect(!result.isError)
        #expect(result.content.contains("hello"))
    }

    @Test("throws unknownTool for unregistered name")
    func unknownTool() async throws {
        let registry = ToolRegistry()

        await #expect(throws: ToolError.self) {
            try await registry.execute(
                name: "nonexistent",
                parameters: [:],
                workingDirectory: "/tmp"
            )
        }
    }

    @Test("definitions returns all registered tool schemas")
    func definitions() async {
        let registry = ToolRegistry()
        await registry.register(BashTool())
        await registry.register(ReadTool())

        let defs = await registry.definitions
        #expect(defs.count == 2)

        let names = Set(defs.map(\.name))
        #expect(names.contains("bash"))
        #expect(names.contains("read"))
    }

    @Test("contains returns true for registered tool")
    func containsRegistered() async {
        let registry = ToolRegistry()
        await registry.register(WriteTool())

        #expect(await registry.contains("write"))
        #expect(await !registry.contains("bash"))
    }

    @Test("replacing a tool with the same name")
    func replaceRegistration() async {
        let registry = ToolRegistry()
        await registry.register(BashTool())
        await registry.register(BashTool())

        let defs = await registry.definitions
        #expect(defs.count == 1)
    }
}
