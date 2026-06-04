import Foundation
import Testing
@testable import Aozora

struct ContentBlockTests {
    private let encoder: JSONEncoder = {
        let e = JSONEncoder()
        e.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return e
    }()

    @Test
    func `Text block encodes with type discriminator`() throws {
        let block = ContentBlock.text("hello")
        let json = try jsonString(block)
        #expect(json == #"{"text":"hello","type":"text"}"#)
    }

    @Test
    func `ToolUseBlock encodes with correct shape`() throws {
        let block = ContentBlock.toolUse(ToolUseBlock(
            id: "tu_123",
            name: "read_file",
            input: .object([("path", .string("/tmp/test.txt"))]),
        ))
        let json = try jsonString(block)
        let parsed = try #require(JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any])
        #expect(parsed["type"] as? String == "tool_use")
        #expect(parsed["id"] as? String == "tu_123")
        #expect(parsed["name"] as? String == "read_file")
        #expect((parsed["input"] as? [String: Any])?["path"] as? String == "/tmp/test.txt")
    }

    @Test
    func `ToolResultBlock encodes with tool_use_id`() throws {
        let block = ContentBlock.toolResult(ToolResultBlock(
            toolUseId: "tu_123",
            content: "file contents here",
            isError: false,
        ))
        let json = try jsonString(block)
        let parsed = try #require(JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any])
        #expect(parsed["type"] as? String == "tool_result")
        #expect(parsed["tool_use_id"] as? String == "tu_123")
        #expect(parsed["is_error"] as? Bool == false)
    }

    @Test
    func `ImageBlock encodes with base64 source`() throws {
        let block = ContentBlock.image(ImageBlock(
            mediaType: "image/png",
            data: Data([0x89, 0x50, 0x4E, 0x47]),
        ))
        let json = try jsonString(block)
        let parsed = try #require(JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any])
        #expect(parsed["type"] as? String == "image")
        let source = parsed["source"] as? [String: Any]
        #expect(source?["type"] as? String == "base64")
        #expect(source?["media_type"] as? String == "image/png")
    }

    @Test
    func `SystemBlock encodes with optional cache_control`() throws {
        let withCache = SystemBlock(text: "prompt", cacheControl: .ephemeral)
        let json1 = try jsonString(withCache)
        #expect(json1.contains(#""cache_control""#))

        let withoutCache = SystemBlock(text: "prompt", cacheControl: nil)
        let json2 = try jsonString(withoutCache)
        #expect(!json2.contains(#""cache_control""#))
    }

    @Test
    func `MessageContent.text encodes as bare string`() throws {
        let content = MessageContent.text("hello world")
        let json = try jsonString(content)
        #expect(json == #""hello world""#)
    }

    @Test
    func `MessageContent.blocks encodes as array`() throws {
        let content = MessageContent.blocks([
            .text("some text"),
            .toolUse(ToolUseBlock(id: "tu_1", name: "test", input: .object([]))),
        ])
        let json = try jsonString(content)
        let parsed = try #require(JSONSerialization.jsonObject(with: Data(json.utf8)) as? [Any])
        #expect(parsed.count == 2)
    }

    @Test
    func `MessageContent.addCacheControl converts text to blocks`() throws {
        var content = MessageContent.text("hello")
        content.addCacheControl()
        let json = try jsonString(content)
        #expect(json.contains(#""cache_control""#))
        #expect(json.contains(#""type":"text""#))
    }

    @Test
    func `APIMessage encodes with role and content`() throws {
        let msg = APIMessage(role: .user, content: .text("hi"))
        let json = try jsonString(msg)
        let parsed = try #require(JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any])
        #expect(parsed["role"] as? String == "user")
        #expect(parsed["content"] as? String == "hi")
    }

    private func jsonString(_ value: some Encodable) throws -> String {
        try String(data: encoder.encode(value), encoding: .utf8)!
    }
}
