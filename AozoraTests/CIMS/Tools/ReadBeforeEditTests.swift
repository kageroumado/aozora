import Foundation
import Testing
@testable import Aozora

struct ReadBeforeEditTests {
    let workdir = "/tmp"

    @Test
    func `edit without prior read fails`() async throws {
        let tracker = FileAccessTracker()
        let editTool = EditTool(tracker: tracker)

        let path = try TestFixtures.createTempFile(content: "hello world")

        let result = try await editTool.execute(
            parameters: [
                "file_path": path,
                "old_string": "hello",
                "new_string": "hi",
            ],
            workingDirectory: workdir,
        )

        #expect(result.isError)
        #expect(result.content.contains("read"))

        let content = try String(contentsOfFile: path, encoding: .utf8)
        #expect(content == "hello world")
    }

    @Test
    func `edit after read succeeds`() async throws {
        let tracker = FileAccessTracker()
        let readTool = ReadTool(tracker: tracker)
        let editTool = EditTool(tracker: tracker)

        let path = try TestFixtures.createTempFile(content: "hello world")

        let readResult = try await readTool.execute(
            parameters: ["file_path": path],
            workingDirectory: workdir,
        )
        #expect(!readResult.isError)

        let editResult = try await editTool.execute(
            parameters: [
                "file_path": path,
                "old_string": "hello",
                "new_string": "hi",
            ],
            workingDirectory: workdir,
        )

        #expect(!editResult.isError)
        let content = try String(contentsOfFile: path, encoding: .utf8)
        #expect(content == "hi world")
    }

    @Test
    func `edit after external modification fails`() async throws {
        let tracker = FileAccessTracker()
        let readTool = ReadTool(tracker: tracker)
        let editTool = EditTool(tracker: tracker)

        let path = try TestFixtures.createTempFile(content: "hello world")

        let readResult = try await readTool.execute(
            parameters: ["file_path": path],
            workingDirectory: workdir,
        )
        #expect(!readResult.isError)

        try await Task.sleep(for: .milliseconds(50))
        try "hello world modified".write(toFile: path, atomically: true, encoding: .utf8)

        let editResult = try await editTool.execute(
            parameters: [
                "file_path": path,
                "old_string": "hello",
                "new_string": "hi",
            ],
            workingDirectory: workdir,
        )

        #expect(editResult.isError)
        #expect(editResult.content.contains("modified"))
    }

    @Test
    func `write existing file after read succeeds`() async throws {
        let tracker = FileAccessTracker()
        let readTool = ReadTool(tracker: tracker)
        let writeTool = WriteTool(tracker: tracker)

        let path = try TestFixtures.createTempFile(content: "original")

        let readResult = try await readTool.execute(
            parameters: ["file_path": path],
            workingDirectory: workdir,
        )
        #expect(!readResult.isError)

        let writeResult = try await writeTool.execute(
            parameters: ["file_path": path, "content": "replaced"],
            workingDirectory: workdir,
        )

        #expect(!writeResult.isError)
        let content = try String(contentsOfFile: path, encoding: .utf8)
        #expect(content == "replaced")
    }

    @Test
    func `write new file skips read check`() async throws {
        let tracker = FileAccessTracker()
        let writeTool = WriteTool(tracker: tracker)

        let path = "/tmp/rbe_new_\(UUID().uuidString).txt"

        let result = try await writeTool.execute(
            parameters: ["file_path": path, "content": "brand new"],
            workingDirectory: workdir,
        )

        #expect(!result.isError)
        let content = try String(contentsOfFile: path, encoding: .utf8)
        #expect(content == "brand new")
    }

    @Test
    func `read tracking expires`() async throws {
        let tracker = FileAccessTracker(expiryInterval: 0.1)
        let readTool = ReadTool(tracker: tracker)
        let editTool = EditTool(tracker: tracker)

        let path = try TestFixtures.createTempFile(content: "hello world")

        let readResult = try await readTool.execute(
            parameters: ["file_path": path],
            workingDirectory: workdir,
        )
        #expect(!readResult.isError)

        try await Task.sleep(for: .milliseconds(200))

        let editResult = try await editTool.execute(
            parameters: [
                "file_path": path,
                "old_string": "hello",
                "new_string": "hi",
            ],
            workingDirectory: workdir,
        )

        #expect(editResult.isError)
        #expect(editResult.content.contains("expired"))
    }

    @Test
    func `glob does not count as read`() async throws {
        let tracker = FileAccessTracker()
        let globTool = GlobTool()
        let editTool = EditTool(tracker: tracker)

        let path = try TestFixtures.createTempFile(content: "hello world")
        let filename = (path as NSString).lastPathComponent

        let globResult = try await globTool.execute(
            parameters: ["pattern": filename],
            workingDirectory: workdir,
        )
        #expect(!globResult.isError)

        let editResult = try await editTool.execute(
            parameters: [
                "file_path": path,
                "old_string": "hello",
                "new_string": "hi",
            ],
            workingDirectory: workdir,
        )

        #expect(editResult.isError)
        #expect(editResult.content.contains("read"))
    }

    @Test
    func `write existing file without prior read fails`() async throws {
        let tracker = FileAccessTracker()
        let writeTool = WriteTool(tracker: tracker)

        let path = try TestFixtures.createTempFile(content: "original")

        let result = try await writeTool.execute(
            parameters: ["file_path": path, "content": "overwrite attempt"],
            workingDirectory: workdir,
        )

        #expect(result.isError)
        #expect(result.content.contains("read"))

        let content = try String(contentsOfFile: path, encoding: .utf8)
        #expect(content == "original")
    }
}
