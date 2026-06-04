import Foundation
import Testing
@testable import Aozora

struct LspClientTests {
    @Test
    func `formats JSON-RPC request with Content-Length header`() throws {
        let body: [String: Any] = [
            "jsonrpc": "2.0",
            "id": 1,
            "method": "initialize",
            "params": ["rootUri": "file:///tmp"] as [String: Any],
        ]
        let json = try JSONSerialization.data(withJSONObject: body)
        let header = "Content-Length: \(json.count)\r\n\r\n"
        let full = try #require(header.data(using: .utf8)) + json
        let str = try #require(String(data: full, encoding: .utf8))
        #expect(str.contains("Content-Length:"))
        #expect(str.contains("initialize"))
    }

    @Test
    func `parses Content-Length header value`() throws {
        let header = "Content-Length: 42\r\n"
        let value = header
            .split(separator: ":").last?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        #expect(value == "42")
        #expect(try Int(#require(value)) == 42)
    }

    @Test
    func `server registry can be created`() {
        let registry = LspServerRegistry()
        _ = registry
    }

    @Test
    func `LspPosition is zero-indexed`() {
        let pos = LspPosition(line: 0, character: 0)
        #expect(pos.line == 0)
        #expect(pos.character == 0)
    }

    @Test
    func `LspPosition equality`() {
        let a = LspPosition(line: 5, character: 10)
        let b = LspPosition(line: 5, character: 10)
        let c = LspPosition(line: 5, character: 11)
        #expect(a == b)
        #expect(a != c)
    }

    @Test
    func `LspRange equality`() {
        let range1 = LspRange(
            start: LspPosition(line: 1, character: 0),
            end: LspPosition(line: 1, character: 10),
        )
        let range2 = LspRange(
            start: LspPosition(line: 1, character: 0),
            end: LspPosition(line: 1, character: 10),
        )
        #expect(range1 == range2)
    }

    @Test
    func `LspLocation round-trips through Codable`() throws {
        let location = LspLocation(
            uri: "file:///tmp/test.swift",
            range: LspRange(
                start: LspPosition(line: 10, character: 5),
                end: LspPosition(line: 10, character: 15),
            ),
        )
        let data = try JSONEncoder().encode(location)
        let decoded = try JSONDecoder().decode(LspLocation.self, from: data)
        #expect(decoded.uri == "file:///tmp/test.swift")
        #expect(decoded.range.start.line == 10)
        #expect(decoded.range.start.character == 5)
        #expect(decoded.range.end.line == 10)
        #expect(decoded.range.end.character == 15)
    }

    @Test
    func `LspLocation equality`() {
        let loc1 = LspLocation(
            uri: "file:///a.swift",
            range: LspRange(
                start: LspPosition(line: 0, character: 0),
                end: LspPosition(line: 0, character: 5),
            ),
        )
        let loc2 = LspLocation(
            uri: "file:///a.swift",
            range: LspRange(
                start: LspPosition(line: 0, character: 0),
                end: LspPosition(line: 0, character: 5),
            ),
        )
        #expect(loc1 == loc2)
    }

    @Test
    func `DocumentSymbol round-trips through Codable`() throws {
        let symbol = DocumentSymbol(
            name: "myFunction",
            kind: 12,
            range: LspRange(
                start: LspPosition(line: 5, character: 0),
                end: LspPosition(line: 10, character: 1),
            ),
            selectionRange: LspRange(
                start: LspPosition(line: 5, character: 5),
                end: LspPosition(line: 5, character: 15),
            ),
            children: nil,
        )
        let data = try JSONEncoder().encode(symbol)
        let decoded = try JSONDecoder().decode(DocumentSymbol.self, from: data)
        #expect(decoded.name == "myFunction")
        #expect(decoded.kind == 12)
    }

    @Test
    func `DocumentSymbol with children round-trips through Codable`() throws {
        let child = DocumentSymbol(
            name: "innerMethod",
            kind: 6,
            range: LspRange(
                start: LspPosition(line: 7, character: 4),
                end: LspPosition(line: 9, character: 5),
            ),
            selectionRange: LspRange(
                start: LspPosition(line: 7, character: 9),
                end: LspPosition(line: 7, character: 20),
            ),
            children: nil,
        )
        let parent = DocumentSymbol(
            name: "MyClass",
            kind: 5,
            range: LspRange(
                start: LspPosition(line: 5, character: 0),
                end: LspPosition(line: 10, character: 1),
            ),
            selectionRange: LspRange(
                start: LspPosition(line: 5, character: 6),
                end: LspPosition(line: 5, character: 13),
            ),
            children: [child],
        )
        let data = try JSONEncoder().encode(parent)
        let decoded = try JSONDecoder().decode(DocumentSymbol.self, from: data)
        #expect(decoded.children?.count == 1)
        #expect(decoded.children?.first?.name == "innerMethod")
    }

    @Test
    func `HoverContents decodes markup content`() {
        let json: [String: Any] = ["kind": "markdown", "value": "# Hello"]
        let result = HoverContents.decode(from: json)
        #expect(result == .markup(kind: "markdown", value: "# Hello"))
    }

    @Test
    func `HoverContents decodes plain string`() {
        let result = HoverContents.decode(from: "plain text")
        #expect(result == .string("plain text"))
    }

    @Test
    func `HoverContents displayText extracts value`() {
        let markup = HoverContents.markup(kind: "markdown", value: "type info")
        #expect(markup.displayText == "type info")

        let plain = HoverContents.string("simple")
        #expect(plain.displayText == "simple")
    }

    @Test
    func `JsonRpcError decodes from dictionary`() {
        let dict: [String: Any] = ["code": -32_600, "message": "Invalid Request"]
        let error = JsonRpcError.decode(from: dict)
        #expect(error?.code == -32_600)
        #expect(error?.message == "Invalid Request")
    }

    @Test
    func `JsonRpcError returns nil for missing fields`() {
        let dict1: [String: Any] = ["code": -32_600]
        #expect(JsonRpcError.decode(from: dict1) == nil)

        let dict2: [String: Any] = ["message": "error"]
        #expect(JsonRpcError.decode(from: dict2) == nil)
    }

    @Test
    func `SymbolKindName maps known kinds correctly`() {
        #expect(SymbolKindName.name(for: 5) == "Class")
        #expect(SymbolKindName.name(for: 6) == "Method")
        #expect(SymbolKindName.name(for: 12) == "Function")
        #expect(SymbolKindName.name(for: 23) == "Struct")
        #expect(SymbolKindName.name(for: 99) == "Symbol")
    }

    @Test
    func `supported extensions includes common languages`() {
        let supported = LspServerRegistry.supportedExtensions
        #expect(supported.contains("swift"))
        #expect(supported.contains("py"))
        #expect(supported.contains("ts"))
        #expect(supported.contains("go"))
        #expect(supported.contains("rs"))
        #expect(supported.contains("c"))
        #expect(supported.contains("cpp"))
    }

    @Test
    func `LspTool requires operation parameter`() async {
        let registry = LspServerRegistry()
        let tool = LspTool(registry: registry)
        await #expect(throws: ToolError.self) {
            try await tool.execute(parameters: ["file": "/tmp/test.swift"], workingDirectory: "/tmp")
        }
    }

    @Test
    func `LspTool requires file parameter`() async {
        let registry = LspServerRegistry()
        let tool = LspTool(registry: registry)
        await #expect(throws: ToolError.self) {
            try await tool.execute(parameters: ["operation": "hover"], workingDirectory: "/tmp")
        }
    }

    @Test
    func `LspTool returns error for unsupported extension`() async throws {
        let registry = LspServerRegistry()
        let tool = LspTool(registry: registry)
        let result = try await tool.execute(
            parameters: ["operation": "hover", "file": "/tmp/test.xyz", "line": 1, "character": 1],
            workingDirectory: "/tmp",
        )
        #expect(result.isError)
        #expect(result.content.contains("No language server"))
    }

    @Test
    func `HoverContents decodes MarkedString array`() {
        let json: [[String: Any]] = [
            ["language": "swift", "value": "let x: Int"],
            ["language": "swift", "value": "var y: String"],
        ]
        let result = HoverContents.decode(from: json)
        if case let .markup(kind, value) = result {
            #expect(kind == "markdown")
            #expect(value.contains("let x: Int"))
            #expect(value.contains("var y: String"))
        } else {
            Issue.record("Expected .markup, got \(String(describing: result))")
        }
    }
}
