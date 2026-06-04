import Foundation
import Testing
@testable import Aozora

struct FileVersionStoreTests {
    private func makeStore() throws -> FileVersionStore {
        let db = try CIMSDatabase.inMemory()
        return FileVersionStore(database: db)
    }

    @Test
    func `stores version before edit`() async throws {
        let store = try makeStore()
        let path = try TestFixtures.createTempFile(content: "original content")

        await store.captureVersion(conversationId: 1, filePath: path, mutationTool: "edit")

        let count = try await store.versionCount(conversationId: 1, filePath: path)
        #expect(count == 1)
    }

    @Test
    func `undo reverts most recent`() async throws {
        let store = try makeStore()
        let path = try TestFixtures.createTempFile(content: "version 1")

        await store.captureVersion(conversationId: 1, filePath: path, mutationTool: "edit")
        try "version 2".write(toFile: path, atomically: true, encoding: .utf8)

        await store.captureVersion(conversationId: 1, filePath: path, mutationTool: "edit")
        try "version 3".write(toFile: path, atomically: true, encoding: .utf8)

        let result = await store.undoLast(conversationId: 1, filePath: path)
        #expect(result != nil)
        #expect(result?.versionsReverted == 1)

        let content = try String(contentsOfFile: path, encoding: .utf8)
        #expect(content == "version 2")
    }

    @Test
    func `undo all reverts to original`() async throws {
        let store = try makeStore()
        let path = try TestFixtures.createTempFile(content: "original")

        await store.captureVersion(conversationId: 1, filePath: path, mutationTool: "edit")
        try "after first edit".write(toFile: path, atomically: true, encoding: .utf8)

        await store.captureVersion(conversationId: 1, filePath: path, mutationTool: "edit")
        try "after second edit".write(toFile: path, atomically: true, encoding: .utf8)

        await store.captureVersion(conversationId: 1, filePath: path, mutationTool: "write")
        try "after third edit".write(toFile: path, atomically: true, encoding: .utf8)

        let result = await store.undoAll(conversationId: 1, filePath: path)
        #expect(result != nil)
        #expect(result?.versionsReverted == 3)

        let content = try String(contentsOfFile: path, encoding: .utf8)
        #expect(content == "original")
    }

    @Test
    func `undo returns nil when nothing to undo`() async throws {
        let store = try makeStore()
        let path = "/tmp/fileversion_nonexistent_\(UUID().uuidString).txt"

        let result = await store.undoLast(conversationId: 1, filePath: path)
        #expect(result == nil)
    }

    @Test
    func `pruning keeps last 50`() async throws {
        let store = try makeStore()
        let path = try TestFixtures.createTempFile(content: "base")

        for i in 0 ..< 55 {
            try "content \(i)".write(toFile: path, atomically: true, encoding: .utf8)
            await store.captureVersion(conversationId: 1, filePath: path, mutationTool: "edit")
        }

        let count = try await store.versionCount(conversationId: 1, filePath: path)
        #expect(count <= 50)
    }

    @Test
    func `version content matches original file`() async throws {
        let store = try makeStore()
        let originalContent = "hello world\nline 2\nline 3"
        let path = try TestFixtures.createTempFile(content: originalContent)

        await store.captureVersion(conversationId: 1, filePath: path, mutationTool: "write")

        let versions = try await store.versions(conversationId: 1, filePath: path)
        #expect(versions.count == 1)

        let storedContent = String(data: versions[0].content, encoding: .utf8)
        #expect(storedContent == originalContent)
    }

    @Test
    func `versions scoped by conversation ID`() async throws {
        let store = try makeStore()
        let path = try TestFixtures.createTempFile(content: "shared file")

        await store.captureVersion(conversationId: 1, filePath: path, mutationTool: "edit")
        await store.captureVersion(conversationId: 2, filePath: path, mutationTool: "edit")

        let count1 = try await store.versionCount(conversationId: 1, filePath: path)
        let count2 = try await store.versionCount(conversationId: 2, filePath: path)
        #expect(count1 == 1)
        #expect(count2 == 1)
    }

    @Test
    func `capture skips nonexistent file`() async throws {
        let store = try makeStore()
        let path = "/tmp/fileversion_missing_\(UUID().uuidString).txt"

        await store.captureVersion(conversationId: 1, filePath: path, mutationTool: "write")

        let count = try await store.versionCount(conversationId: 1, filePath: path)
        #expect(count == 0)
    }

    @Test
    func `undo last removes the version record`() async throws {
        let store = try makeStore()
        let path = try TestFixtures.createTempFile(content: "v1")

        await store.captureVersion(conversationId: 1, filePath: path, mutationTool: "edit")
        try "v2".write(toFile: path, atomically: true, encoding: .utf8)

        let beforeCount = try await store.versionCount(conversationId: 1, filePath: path)
        #expect(beforeCount == 1)

        _ = await store.undoLast(conversationId: 1, filePath: path)

        let afterCount = try await store.versionCount(conversationId: 1, filePath: path)
        #expect(afterCount == 0)
    }
}
