import Foundation
import Testing
@testable import Aozora

struct GlobToolTests {
    let tool = GlobTool()
    let workdir = "/tmp"

    @Test
    func `finds files matching pattern`() async throws {
        let dir = NSTemporaryDirectory() + "glob-test-\(UUID().uuidString)"
        try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        FileManager.default.createFile(atPath: dir + "/foo.swift", contents: nil)
        FileManager.default.createFile(atPath: dir + "/bar.swift", contents: nil)
        FileManager.default.createFile(atPath: dir + "/baz.txt", contents: nil)
        defer { try? FileManager.default.removeItem(atPath: dir) }

        let result = try await tool.execute(parameters: ["pattern": "*.swift", "path": dir], workingDirectory: dir)
        #expect(!result.isError)
        #expect(result.content.contains("foo.swift"))
        #expect(result.content.contains("bar.swift"))
        #expect(!result.content.contains("baz.txt"))
    }

    @Test
    func `supports recursive glob`() async throws {
        let dir = NSTemporaryDirectory() + "glob-test-\(UUID().uuidString)"
        let sub = dir + "/sub"
        try FileManager.default.createDirectory(atPath: sub, withIntermediateDirectories: true)
        FileManager.default.createFile(atPath: dir + "/a.swift", contents: nil)
        FileManager.default.createFile(atPath: sub + "/b.swift", contents: nil)
        defer { try? FileManager.default.removeItem(atPath: dir) }

        let result = try await tool.execute(parameters: ["pattern": "**/*.swift", "path": dir], workingDirectory: dir)
        #expect(!result.isError)
        #expect(result.content.contains("a.swift"))
        #expect(result.content.contains("b.swift"))
    }

    @Test
    func `throws on missing pattern parameter`() async throws {
        await #expect(throws: ToolError.self) {
            try await tool.execute(parameters: [:], workingDirectory: workdir)
        }
    }

    @Test
    func `definition has correct name`() {
        #expect(tool.name == "glob")
    }
}
