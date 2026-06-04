import Foundation
import Testing
@testable import Aozora

@Suite("WriteTool")
struct WriteToolTests {
    let tool = WriteTool()
    let workdir = "/tmp"

    @Test("writes content to a new file")
    func writeNewFile() async throws {
        let path = "/tmp/writetool_\(UUID().uuidString).txt"

        let result = try await tool.execute(
            parameters: ["file_path": path, "content": "hello world"],
            workingDirectory: workdir
        )

        #expect(!result.isError)
        #expect(result.content.contains("Wrote"))
        #expect(result.content.contains("bytes"))

        let written = try String(contentsOfFile: path, encoding: .utf8)
        #expect(written == "hello world")
    }

    @Test("overwrites existing file")
    func overwriteFile() async throws {
        let path = "/tmp/writetool_overwrite_\(UUID().uuidString).txt"
        try "old content".write(toFile: path, atomically: true, encoding: .utf8)

        let result = try await tool.execute(
            parameters: ["file_path": path, "content": "new content"],
            workingDirectory: workdir
        )

        #expect(!result.isError)
        let written = try String(contentsOfFile: path, encoding: .utf8)
        #expect(written == "new content")
    }

    @Test("creates parent directories automatically")
    func createsParentDirs() async throws {
        let dir = "/tmp/writetool_nested_\(UUID().uuidString)"
        let path = "\(dir)/sub/deep/file.txt"

        let result = try await tool.execute(
            parameters: ["file_path": path, "content": "nested"],
            workingDirectory: workdir
        )

        #expect(!result.isError)
        let written = try String(contentsOfFile: path, encoding: .utf8)
        #expect(written == "nested")
    }

    @Test("resolves relative path")
    func relativePath() async throws {
        let filename = "writetool_rel_\(UUID().uuidString).txt"

        let result = try await tool.execute(
            parameters: ["file_path": filename, "content": "relative"],
            workingDirectory: "/tmp"
        )

        #expect(!result.isError)
        let written = try String(contentsOfFile: "/tmp/\(filename)", encoding: .utf8)
        #expect(written == "relative")
    }

    @Test("throws on missing file_path")
    func missingFilePath() async throws {
        await #expect(throws: ToolError.self) {
            try await tool.execute(
                parameters: ["content": "data"],
                workingDirectory: workdir
            )
        }
    }

    @Test("throws on missing content")
    func missingContent() async throws {
        await #expect(throws: ToolError.self) {
            try await tool.execute(
                parameters: ["file_path": "/tmp/x.txt"],
                workingDirectory: workdir
            )
        }
    }

    @Test("definition has correct name")
    func definitionName() {
        #expect(tool.definition.name == "write")
        #expect(tool.name == "write")
    }
}
