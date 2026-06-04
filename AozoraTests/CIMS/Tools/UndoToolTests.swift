import Foundation
import Testing
@testable import Aozora

struct UndoToolTests {
    private func makeToolAndStore() throws -> (UndoTool, FileVersionStore) {
        let db = try CIMSDatabase.inMemory()
        let store = FileVersionStore(database: db)
        let tool = UndoTool(versionStore: store, conversationId: 1)
        return (tool, store)
    }

    @Test
    func `undo reverts most recent edit`() async throws {
        let (tool, store) = try makeToolAndStore()
        let path = try TestFixtures.createTempFile(content: "original")

        await store.captureVersion(conversationId: 1, filePath: path, mutationTool: "edit")
        try "modified".write(toFile: path, atomically: true, encoding: .utf8)

        let result = try await tool.execute(
            parameters: ["file_path": path],
            workingDirectory: "/tmp",
        )

        #expect(!result.isError)
        #expect(result.content.contains("Undone 1 version"))

        let content = try String(contentsOfFile: path, encoding: .utf8)
        #expect(content == "original")
    }

    @Test
    func `undo all reverts to original`() async throws {
        let (tool, store) = try makeToolAndStore()
        let path = try TestFixtures.createTempFile(content: "first")

        await store.captureVersion(conversationId: 1, filePath: path, mutationTool: "edit")
        try "second".write(toFile: path, atomically: true, encoding: .utf8)

        await store.captureVersion(conversationId: 1, filePath: path, mutationTool: "edit")
        try "third".write(toFile: path, atomically: true, encoding: .utf8)

        let result = try await tool.execute(
            parameters: ["file_path": path, "mode": "all"],
            workingDirectory: "/tmp",
        )

        #expect(!result.isError)
        #expect(result.content.contains("Undone 2 version"))

        let content = try String(contentsOfFile: path, encoding: .utf8)
        #expect(content == "first")
    }

    @Test
    func `undo with no history returns message`() async throws {
        let (tool, _) = try makeToolAndStore()
        let path = "/tmp/undotool_nohistory_\(UUID().uuidString).txt"

        let result = try await tool.execute(
            parameters: ["file_path": path],
            workingDirectory: "/tmp",
        )

        #expect(!result.isError)
        #expect(result.content.contains("Nothing to undo"))
    }

    @Test
    func `undo tool returns file path`() async throws {
        let (tool, store) = try makeToolAndStore()
        let path = try TestFixtures.createTempFile(content: "content")

        await store.captureVersion(conversationId: 1, filePath: path, mutationTool: "write")
        try "new content".write(toFile: path, atomically: true, encoding: .utf8)

        let result = try await tool.execute(
            parameters: ["file_path": path],
            workingDirectory: "/tmp",
        )

        #expect(!result.isError)
        #expect(result.content.contains(path))
    }

    @Test
    func `definition has correct name and parameters`() throws {
        let db = try CIMSDatabase.inMemory()
        let store = FileVersionStore(database: db)
        let tool = UndoTool(versionStore: store)

        #expect(tool.definition.name == "undo")
        #expect(tool.name == "undo")
        #expect(tool.definition.parameters.count == 2)
    }

    @Test
    func `throws on missing file_path`() async throws {
        let (tool, _) = try makeToolAndStore()

        await #expect(throws: ToolError.self) {
            try await tool.execute(
                parameters: [:],
                workingDirectory: "/tmp",
            )
        }
    }

    @Test
    func `throws on invalid mode`() async throws {
        let (tool, _) = try makeToolAndStore()

        await #expect(throws: ToolError.self) {
            try await tool.execute(
                parameters: ["file_path": "/tmp/x.txt", "mode": "invalid"],
                workingDirectory: "/tmp",
            )
        }
    }
}
