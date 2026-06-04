import Foundation
import Testing
@testable import Aozora

struct TodoToolTests {
    @Test
    func `writes and reads todos`() async throws {
        let db = try CIMSDatabase.inMemory()
        let tool = TodoTool(db: db)

        let writeResult = try await tool.execute(
            parameters: [
                "action": "write",
                "session": "test-session",
                "todos": [
                    ["content": "First task", "status": "pending", "priority": "high"],
                    ["content": "Second task", "status": "in_progress", "priority": "medium"],
                ] as [[String: Any]],
            ],
            workingDirectory: "/tmp",
        )
        #expect(!writeResult.isError)

        let readResult = try await tool.execute(
            parameters: ["action": "read", "session": "test-session"],
            workingDirectory: "/tmp",
        )
        #expect(!readResult.isError)
        #expect(readResult.content.contains("First task"))
        #expect(readResult.content.contains("Second task"))
        #expect(readResult.content.contains("[!]"))
    }

    @Test
    func `write replaces existing todos`() async throws {
        let db = try CIMSDatabase.inMemory()
        let tool = TodoTool(db: db)

        _ = try await tool.execute(
            parameters: [
                "action": "write", "session": "s1",
                "todos": [["content": "old", "status": "pending", "priority": "low"]] as [[String: Any]],
            ],
            workingDirectory: "/tmp",
        )

        _ = try await tool.execute(
            parameters: [
                "action": "write", "session": "s1",
                "todos": [["content": "new", "status": "completed", "priority": "high"]] as [[String: Any]],
            ],
            workingDirectory: "/tmp",
        )

        let result = try await tool.execute(
            parameters: ["action": "read", "session": "s1"],
            workingDirectory: "/tmp",
        )
        #expect(result.content.contains("new"))
        #expect(!result.content.contains("old"))
    }

    @Test
    func `empty read returns no tasks message`() async throws {
        let db = try CIMSDatabase.inMemory()
        let tool = TodoTool(db: db)

        let result = try await tool.execute(
            parameters: ["action": "read", "session": "empty"],
            workingDirectory: "/tmp",
        )
        #expect(!result.isError)
        #expect(result.content.contains("No todos"))
    }
}
