import Foundation
import Testing
@testable import Aozora

struct ReadToolTests {
    let tool = ReadTool()
    let workdir = "/tmp"

    @Test
    func `reads a file with line numbers`() async throws {
        let path = try TestFixtures.createTempFile(content: "line one\nline two\nline three")

        let result = try await tool.execute(
            parameters: ["file_path": path],
            workingDirectory: workdir,
        )

        #expect(!result.isError)
        #expect(result.content.contains("1\tline one"))
        #expect(result.content.contains("2\tline two"))
        #expect(result.content.contains("3\tline three"))
    }

    @Test
    func `reads with offset`() async throws {
        let path = try TestFixtures.createTempFile(content: "a\nb\nc\nd\ne")

        let result = try await tool.execute(
            parameters: ["file_path": path, "offset": 3],
            workingDirectory: workdir,
        )

        #expect(!result.isError)
        #expect(result.content.contains("3\tc"))
        #expect(!result.content.contains("1\ta"))
    }

    @Test
    func `reads with limit`() async throws {
        let path = try TestFixtures.createTempFile(content: "a\nb\nc\nd\ne")

        let result = try await tool.execute(
            parameters: ["file_path": path, "limit": 2],
            workingDirectory: workdir,
        )

        #expect(!result.isError)
        #expect(result.content.contains("1\ta"))
        #expect(result.content.contains("2\tb"))
        #expect(!result.content.contains("3\tc"))
    }

    @Test
    func `returns error for nonexistent file`() async throws {
        let result = try await tool.execute(
            parameters: ["file_path": "/tmp/does_not_exist_\(UUID().uuidString).txt"],
            workingDirectory: workdir,
        )

        #expect(result.isError)
        #expect(result.content.contains("File not found"))
    }

    @Test
    func `lists directory contents`() async throws {
        let dir = "/tmp/readtool_test_\(UUID().uuidString)"
        try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        FileManager.default.createFile(atPath: "\(dir)/alpha.txt", contents: nil)
        FileManager.default.createFile(atPath: "\(dir)/beta.txt", contents: nil)

        let result = try await tool.execute(
            parameters: ["file_path": dir],
            workingDirectory: workdir,
        )

        #expect(!result.isError)
        #expect(result.content.contains("alpha.txt"))
        #expect(result.content.contains("beta.txt"))
    }

    @Test
    func `resolves relative path from working directory`() async throws {
        let filename = "readtool_rel_\(UUID().uuidString).txt"
        try "relative content".write(toFile: "/tmp/\(filename)", atomically: true, encoding: .utf8)

        let result = try await tool.execute(
            parameters: ["file_path": filename],
            workingDirectory: "/tmp",
        )

        #expect(!result.isError)
        #expect(result.content.contains("relative content"))
    }

    @Test
    func `throws on missing file_path parameter`() async throws {
        await #expect(throws: ToolError.self) {
            try await tool.execute(
                parameters: [:],
                workingDirectory: workdir,
            )
        }
    }

    @Test
    func `definition has correct name`() {
        #expect(tool.definition.name == "read")
        #expect(tool.name == "read")
    }
}
