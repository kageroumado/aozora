import Foundation
import Testing
@testable import Aozora

struct JSONValueTests {
    @Test
    func `Parse simple object from string`() throws {
        let json = """
        {"name":"test","count":42,"active":true}
        """
        let value = try JSONValue.parse(json)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        let data = try encoder.encode(value)
        let output = try #require(String(data: data, encoding: .utf8))
        #expect(output == #"{"active":true,"count":42,"name":"test"}"#)
    }

    @Test
    func `Parse produces alphabetically sorted keys`() throws {
        let json = #"{"z":"last","a":"first"}"#
        let value = try JSONValue.parse(json)
        let encoder = JSONEncoder()
        encoder.outputFormatting = .sortedKeys
        let data = try encoder.encode(value)
        let output = try #require(String(data: data, encoding: .utf8))
        #expect(output == #"{"a":"first","z":"last"}"#)
    }

    @Test
    func `Parse nested structures`() throws {
        let json = #"{"items":[1,2,3],"meta":{"key":"val"}}"#
        let value = try JSONValue.parse(json)
        guard case let .object(pairs) = value else {
            Issue.record("Expected object"); return
        }
        #expect(pairs.count == 2)
    }

    @Test
    func `Parse null, bool, int, double, string primitives`() throws {
        #expect(try JSONValue.parse("null") == .null)
        #expect(try JSONValue.parse("true") == .bool(true))
        #expect(try JSONValue.parse("42") == .int(42))
        #expect(try JSONValue.parse("3.14") == .double(3.14))
        #expect(try JSONValue.parse(#""hello""#) == .string("hello"))
    }

    @Test
    func `Parse distinguishes integer 0 and 1 from boolean true and false`() throws {
        let json = #"[0, 1, true, false]"#
        let value = try JSONValue.parse(json)
        #expect(value == .array([.int(0), .int(1), .bool(true), .bool(false)]))
    }

    @Test
    func `Parse throws on invalid JSON`() {
        #expect(throws: (any Error).self) {
            try JSONValue.parse("{invalid")
        }
    }

    @Test
    func `toFoundation round-trips through [String: Any]`() throws {
        let json = #"{"name":"test","count":42,"nested":{"key":"val"}}"#
        let value = try JSONValue.parse(json)
        let foundation = value.toFoundation()
        guard let dict = foundation as? [String: Any] else {
            Issue.record("Expected dictionary"); return
        }
        #expect(dict["name"] as? String == "test")
        #expect(dict["count"] as? Int64 == 42)
        guard let nested = dict["nested"] as? [String: Any] else {
            Issue.record("Expected nested dict"); return
        }
        #expect(nested["key"] as? String == "val")
    }

    @Test
    func `Equatable compares structurally`() throws {
        let a = try JSONValue.parse(#"{"x":1}"#)
        let b = try JSONValue.parse(#"{"x":1}"#)
        let c = try JSONValue.parse(#"{"x":2}"#)
        #expect(a == b)
        #expect(a != c)
    }

    @Test
    func `Empty object parses and encodes`() throws {
        let value = try JSONValue.parse("{}")
        let encoder = JSONEncoder()
        let data = try encoder.encode(value)
        #expect(String(data: data, encoding: .utf8) == "{}")
    }
}
