import Foundation
import Testing
@testable import Aozora

struct GrepToolTests {
    let tool = GrepTool()
    let workdir = "/tmp"

    @Test
    func `finds matching lines`() async throws {
        let dir = NSTemporaryDirectory() + "grep-test-\(UUID().uuidString)"
        try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        try "hello world\nfoo bar\nhello again".write(toFile: dir + "/test.txt", atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(atPath: dir) }

        let result = try await tool.execute(parameters: ["pattern": "hello", "path": dir], workingDirectory: dir)
        #expect(!result.isError)
        #expect(result.content.contains("hello world"))
        #expect(result.content.contains("hello again"))
        #expect(!result.content.contains("foo bar"))
    }

    @Test
    func `supports regex patterns`() async throws {
        let dir = NSTemporaryDirectory() + "grep-test-\(UUID().uuidString)"
        try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        try "func doSomething() {\n}\nfunc doOther() {".write(toFile: dir + "/code.swift", atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(atPath: dir) }

        let result = try await tool.execute(parameters: ["pattern": "func\\s+do\\w+", "path": dir], workingDirectory: dir)
        #expect(!result.isError)
        #expect(result.content.contains("doSomething"))
        #expect(result.content.contains("doOther"))
    }

    @Test
    func `supports file type filter`() async throws {
        let dir = NSTemporaryDirectory() + "grep-test-\(UUID().uuidString)"
        try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        try "needle".write(toFile: dir + "/a.swift", atomically: true, encoding: .utf8)
        try "needle".write(toFile: dir + "/b.txt", atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(atPath: dir) }

        let result = try await tool.execute(parameters: ["pattern": "needle", "path": dir, "include": "*.swift"], workingDirectory: dir)
        #expect(!result.isError)
        #expect(result.content.contains("a.swift"))
        #expect(!result.content.contains("b.txt"))
    }

    @Test
    func `includes context lines`() async throws {
        let dir = NSTemporaryDirectory() + "grep-test-\(UUID().uuidString)"
        try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        try "line1\nline2\ntarget\nline4\nline5".write(toFile: dir + "/ctx.txt", atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(atPath: dir) }

        let result = try await tool.execute(parameters: ["pattern": "target", "path": dir, "context": 1], workingDirectory: dir)
        #expect(!result.isError)
        #expect(result.content.contains("line2"))
        #expect(result.content.contains("line4"))
    }

    @Test
    func `reports no matches gracefully`() async throws {
        let dir = NSTemporaryDirectory() + "grep-test-\(UUID().uuidString)"
        try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        try "nothing here".write(toFile: dir + "/empty.txt", atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(atPath: dir) }

        let result = try await tool.execute(parameters: ["pattern": "nonexistent", "path": dir], workingDirectory: dir)
        #expect(!result.isError)
        #expect(result.content.contains("No matches"))
    }

    @Test
    func `throws on missing pattern`() async {
        await #expect(throws: ToolError.self) {
            try await tool.execute(parameters: [:], workingDirectory: workdir)
        }
    }
}
