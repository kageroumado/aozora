/// Serializable tool definition for the Anthropic API `tools` field.
///
/// Converts from the internal ``ToolDefinition`` type to the API's JSON Schema
/// format with `input_schema` containing type/properties/required.
///
/// Replaces `AnthropicProvider.serializeToolDefinition()` — produces ``JSONValue``
/// instead of `[String: Any]` for deterministic, type-safe serialization.
public struct ToolSchema: Sendable, Encodable {
    /// The tool name.
    public let name: String
    /// Human-readable description of what the tool does.
    public let description: String
    /// JSON Schema object describing the tool's input parameters.
    public let inputSchema: JSONValue

    /// Create from an internal tool definition.
    ///
    /// - Parameter definition: The ``ToolDefinition`` to convert.
    public init(from definition: ToolDefinition) {
        self.name = definition.name
        self.description = definition.description
        self.inputSchema = Self.buildSchema(from: definition.parameters)
    }

    // MARK: - Encodable

    private enum CodingKeys: String, CodingKey {
        case name
        case description
        case inputSchema = "input_schema"
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(name, forKey: .name)
        try container.encode(description, forKey: .description)
        try container.encode(inputSchema, forKey: .inputSchema)
    }

    // MARK: - Schema Construction

    /// Build a JSON Schema object from a list of tool parameters.
    ///
    /// Produces `{"type":"object","properties":{...},"required":[...]}`.
    /// The `required` key is omitted when no parameters are non-optional.
    ///
    /// - Parameter parameters: The parameter definitions to convert.
    /// - Returns: A ``JSONValue`` representing the JSON Schema input object.
    static func buildSchema(from parameters: [ToolParameter]) -> JSONValue {
        if parameters.isEmpty {
            return .object([
                ("type", .string("object")),
                ("properties", .object([])),
            ])
        }

        var properties: [(String, JSONValue)] = []
        var required: [String] = []

        for param in parameters {
            properties.append((param.name, buildParameterSchema(param.type, description: param.description)))
            if !param.optional {
                required.append(param.name)
            }
        }

        var pairs: [(String, JSONValue)] = [
            ("type", .string("object")),
            ("properties", .object(properties)),
        ]
        if !required.isEmpty {
            pairs.append(("required", .array(required.map { .string($0) })))
        }

        return .object(pairs)
    }

    /// Build a JSON Schema property object for a single parameter type.
    ///
    /// - Parameters:
    ///   - type: The ``ToolParameterType`` to convert.
    ///   - description: The parameter's human-readable description.
    /// - Returns: A ``JSONValue`` object with `type`, `description`, and any type-specific fields.
    private static func buildParameterSchema(_ type: ToolParameterType, description: String) -> JSONValue {
        var pairs: [(String, JSONValue)] = [("description", .string(description))]

        switch type {
        case .string:
            pairs.append(("type", .string("string")))
        case .integer:
            pairs.append(("type", .string("integer")))
        case .boolean:
            pairs.append(("type", .string("boolean")))
        case let .array(elementType):
            pairs.append(("type", .string("array")))
            pairs.append(("items", buildTypeOnly(elementType)))
        case let .enum(values):
            pairs.append(("type", .string("string")))
            pairs.append(("enum", .array(values.map { .string($0) })))
        case .object:
            pairs.append(("type", .string("object")))
        }

        return .object(pairs)
    }

    /// Build a bare JSON Schema type object with no description — used for nested types (e.g. array items).
    ///
    /// - Parameter type: The ``ToolParameterType`` to convert.
    /// - Returns: A ``JSONValue`` object with `type` and any type-specific fields.
    private static func buildTypeOnly(_ type: ToolParameterType) -> JSONValue {
        switch type {
        case .string:
            .object([("type", .string("string"))])
        case .integer:
            .object([("type", .string("integer"))])
        case .boolean:
            .object([("type", .string("boolean"))])
        case let .array(elementType):
            .object([
                ("type", .string("array")),
                ("items", buildTypeOnly(elementType)),
            ])
        case let .enum(values):
            .object([
                ("type", .string("string")),
                ("enum", .array(values.map { .string($0) })),
            ])
        case .object:
            .object([("type", .string("object"))])
        }
    }
}
