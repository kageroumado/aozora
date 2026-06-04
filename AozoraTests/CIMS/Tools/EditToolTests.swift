import Foundation
import Testing
@testable import Aozora

struct EditToolTests {
    let tool = EditTool()
    let workdir = "/tmp"

    @Test
    func `replaces unique occurrence`() async throws {
        let path = try TestFixtures.createTempFile(content: "hello world\ngoodbye world")

        let result = try await tool.execute(
            parameters: [
                "file_path": path,
                "old_string": "hello world",
                "new_string": "hi world",
            ],
            workingDirectory: workdir,
        )

        #expect(!result.isError)
        #expect(result.content.contains("replaced 1 occurrence"))

        let content = try String(contentsOfFile: path, encoding: .utf8)
        #expect(content == "hi world\ngoodbye world")
    }

    @Test
    func `errors when old_string not found`() async throws {
        let path = try TestFixtures.createTempFile(content: "hello world")

        let result = try await tool.execute(
            parameters: [
                "file_path": path,
                "old_string": "nonexistent",
                "new_string": "replacement",
            ],
            workingDirectory: workdir,
        )

        #expect(result.isError)
        #expect(result.content.contains("not found"))
    }

    @Test
    func `errors when multiple matches found`() async throws {
        let path = try TestFixtures.createTempFile(content: "foo bar foo")

        let result = try await tool.execute(
            parameters: [
                "file_path": path,
                "old_string": "foo",
                "new_string": "baz",
            ],
            workingDirectory: workdir,
        )

        #expect(result.isError)
        #expect(result.content.contains("2 matches"))

        let content = try String(contentsOfFile: path, encoding: .utf8)
        #expect(content == "foo bar foo")
    }

    @Test
    func `errors for nonexistent file`() async throws {
        let result = try await tool.execute(
            parameters: [
                "file_path": "/tmp/edittool_nonexistent_\(UUID().uuidString).txt",
                "old_string": "a",
                "new_string": "b",
            ],
            workingDirectory: workdir,
        )

        #expect(result.isError)
        #expect(result.content.contains("File not found"))
    }

    @Test
    func `preserves whitespace exactly`() async throws {
        let path = try TestFixtures.createTempFile(content: "    indented line\n    another line")

        let result = try await tool.execute(
            parameters: [
                "file_path": path,
                "old_string": "    indented line",
                "new_string": "        double indented",
            ],
            workingDirectory: workdir,
        )

        #expect(!result.isError)
        let content = try String(contentsOfFile: path, encoding: .utf8)
        #expect(content == "        double indented\n    another line")
    }

    @Test
    func `throws on missing parameters`() async throws {
        await #expect(throws: ToolError.self) {
            try await tool.execute(
                parameters: ["file_path": "/tmp/x"],
                workingDirectory: workdir,
            )
        }
    }

    @Test
    func `definition has correct name`() {
        #expect(tool.definition.name == "edit")
        #expect(tool.name == "edit")
    }
}
