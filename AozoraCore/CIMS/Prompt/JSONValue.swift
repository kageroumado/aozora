import Foundation

/// Recursive JSON value type for deterministic API serialization.
///
/// Replaces `Any` and `[String: Any]` throughout the prompt-building pipeline.
/// `Encodable` with deterministic key ordering. `Sendable` across actor boundaries.
///
/// Objects use `[(String, JSONValue)]` (ordered pairs) instead of `OrderedDictionary`
/// because the AozoraCore Xcode target does not link swift-collections.
public enum JSONValue: Sendable, Equatable {
    /// JSON `null`.
    case null
    /// JSON boolean (`true` / `false`).
    case bool(Bool)
    /// JSON integer (stored as `Int64`).
    case int(Int64)
    /// JSON floating-point number.
    case double(Double)
    /// JSON string.
    case string(String)
    /// JSON array.
    case array([JSONValue])
    /// Ordered key-value pairs. Preserves insertion order for deterministic serialization.
    case object([(String, JSONValue)])

    // MARK: - Parsing

    /// Parse a JSON string into a `JSONValue`.
    ///
    /// Keys in objects are sorted alphabetically for canonical ordering, ensuring
    /// that identical logical content produces identical serialized bytes.
    ///
    /// - Parameter jsonString: A valid JSON string.
    /// - Returns: The parsed `JSONValue`.
    /// - Throws: If the string is not valid JSON.
    public static func parse(_ jsonString: String) throws -> JSONValue {
        let data = Data(jsonString.utf8)
        let obj = try JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed])
        return fromFoundationValue(obj)
    }

    /// Convert a Foundation JSON object (`Any` from `JSONSerialization`) to `JSONValue`.
    ///
    /// Uses `CFBooleanGetTypeID()` to distinguish actual JSON booleans from `NSNumber`-wrapped
    /// integers. Pattern matching `as Bool` is unreliable because `NSNumber(value: 0)` and
    /// `NSNumber(value: 1)` bridge to `Bool` in Swift.
    private static func fromFoundationValue(_ value: Any) -> JSONValue {
        switch value {
        case is NSNull:
            return .null
        case let n as NSNumber:
            if CFBooleanGetTypeID() == CFGetTypeID(n) {
                return .bool(n.boolValue)
            }
            let type = String(cString: n.objCType)
            if type == "d" || type == "f" {
                return .double(n.doubleValue)
            }
            return .int(n.int64Value)
        case let s as String:
            return .string(s)
        case let arr as [Any]:
            return .array(arr.map(fromFoundationValue))
        case let dict as [String: Any]:
            let sorted = dict.sorted { $0.key < $1.key }
            return .object(sorted.map { ($0.key, fromFoundationValue($0.value)) })
        default:
            return .null
        }
    }

    // MARK: - Foundation Bridge

    /// Convert back to Foundation types (`[String: Any]`, `[Any]`, etc.).
    ///
    /// Used at the `ToolExecutable` boundary where tools still accept `[String: Any]`.
    public func toFoundation() -> Any {
        switch self {
        case .null:
            return NSNull()
        case let .bool(b):
            return b
        case let .int(n):
            return n
        case let .double(d):
            return d
        case let .string(s):
            return s
        case let .array(arr):
            return arr.map { $0.toFoundation() }
        case let .object(pairs):
            var dict: [String: Any] = [:]
            for (key, value) in pairs {
                dict[key] = value.toFoundation()
            }
            return dict
        }
    }

    // MARK: - Equatable

    public static func == (lhs: JSONValue, rhs: JSONValue) -> Bool {
        switch (lhs, rhs) {
        case (.null, .null):
            return true
        case let (.bool(l), .bool(r)):
            return l == r
        case let (.int(l), .int(r)):
            return l == r
        case let (.double(l), .double(r)):
            return l == r
        case let (.string(l), .string(r)):
            return l == r
        case let (.array(l), .array(r)):
            return l == r
        case let (.object(l), .object(r)):
            guard l.count == r.count else { return false }
            for (lPair, rPair) in zip(l, r) {
                if lPair.0 != rPair.0 || lPair.1 != rPair.1 { return false }
            }
            return true
        default:
            return false
        }
    }
}

// MARK: - Encodable

extension JSONValue: Encodable {
    public func encode(to encoder: any Encoder) throws {
        switch self {
        case .null:
            var container = encoder.singleValueContainer()
            try container.encodeNil()
        case let .bool(b):
            var container = encoder.singleValueContainer()
            try container.encode(b)
        case let .int(n):
            var container = encoder.singleValueContainer()
            try container.encode(n)
        case let .double(d):
            var container = encoder.singleValueContainer()
            try container.encode(d)
        case let .string(s):
            var container = encoder.singleValueContainer()
            try container.encode(s)
        case let .array(arr):
            var container = encoder.unkeyedContainer()
            for element in arr {
                try container.encode(element)
            }
        case let .object(pairs):
            var container = encoder.container(keyedBy: DynamicCodingKey.self)
            for (key, value) in pairs {
                try container.encode(value, forKey: DynamicCodingKey(key))
            }
        }
    }
}

/// Coding key that accepts any string value, enabling dynamic key encoding for JSON objects.
private struct DynamicCodingKey: CodingKey {
    var stringValue: String
    var intValue: Int? {
        nil
    }

    init(_ string: String) {
        self.stringValue = string
    }

    init?(stringValue: String) {
        self.stringValue = stringValue
    }

    init?(intValue _: Int) {
        nil
    }
}
