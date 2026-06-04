import Foundation
import Testing
@testable import Aozora

struct PatchToolTests {
    let tool = PatchTool()
    let workdir = "/tmp"

    @Test
    func `applies a simple single-hunk patch`() async throws {
        let dir = NSTemporaryDirectory() + "patch-test-\(UUID().uuidString)"
        try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        try "line1\nline2\nline3\n".write(toFile: dir + "/test.txt", atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(atPath: dir) }

        let patch = """
        --- a/test.txt
        +++ b/test.txt
        @@ -1,3 +1,3 @@
         line1
        -line2
        +line2_modified
         line3
        """

        let result = try await tool.execute(parameters: ["patch": patch], workingDirectory: dir)
        #expect(!result.isError)
        let content = try String(contentsOfFile: dir + "/test.txt", encoding: .utf8)
        #expect(content.contains("line2_modified"))
        #expect(!content.contains("line2\n"))
    }

    @Test
    func `applies a multi-hunk patch`() async throws {
        let dir = NSTemporaryDirectory() + "patch-test-\(UUID().uuidString)"
        try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        try "a\nb\nc\nd\ne\nf\ng\nh\n".write(toFile: dir + "/multi.txt", atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(atPath: dir) }

        let patch = """
        --- a/multi.txt
        +++ b/multi.txt
        @@ -1,3 +1,3 @@
         a
        -b
        +B
         c
        @@ -6,3 +6,3 @@
         f
        -g
        +G
         h
        """

        let result = try await tool.execute(parameters: ["patch": patch], workingDirectory: dir)
        #expect(!result.isError)
        let content = try String(contentsOfFile: dir + "/multi.txt", encoding: .utf8)
        #expect(content.contains("B"))
        #expect(content.contains("G"))
    }

    @Test
    func `creates new files`() async throws {
        let dir = NSTemporaryDirectory() + "patch-test-\(UUID().uuidString)"
        try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(atPath: dir) }

        let patch = """
        --- /dev/null
        +++ b/new.txt
        @@ -0,0 +1,2 @@
        +hello
        +world
        """

        let result = try await tool.execute(parameters: ["patch": patch], workingDirectory: dir)
        #expect(!result.isError)
        let content = try String(contentsOfFile: dir + "/new.txt", encoding: .utf8)
        #expect(content == "hello\nworld\n")
    }

    @Test
    func `reports error for non-matching context`() async throws {
        let dir = NSTemporaryDirectory() + "patch-test-\(UUID().uuidString)"
        try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        try "wrong content\n".write(toFile: dir + "/bad.txt", atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(atPath: dir) }

        let patch = """
        --- a/bad.txt
        +++ b/bad.txt
        @@ -1,1 +1,1 @@
        -expected content
        +new content
        """

        let result = try await tool.execute(parameters: ["patch": patch], workingDirectory: dir)
        #expect(result.isError)
    }

    @Test
    func `throws on missing patch parameter`() async {
        await #expect(throws: ToolError.self) {
            try await tool.execute(parameters: [:], workingDirectory: workdir)
        }
    }
}
