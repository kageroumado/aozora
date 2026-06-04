import Foundation

// MARK: - Core LSP Protocol Types

/// LSP Position — a zero-indexed line and character offset within a text document.
///
/// The LSP specification uses zero-based indexing for both line and character.
/// Agent-facing tools convert from 1-indexed user coordinates before calling LSP methods.
public struct LspPosition: Codable, Sendable, Equatable {
    /// Zero-indexed line number.
    public let line: Int

    /// Zero-indexed character offset (UTF-16 code units per LSP spec).
    public let character: Int

    /// Create a position.
    ///
    /// - Parameters:
    ///   - line: Zero-indexed line number.
    ///   - character: Zero-indexed character offset.
    public init(line: Int, character: Int) {
        self.line = line
        self.character = character
    }
}

/// LSP Range — a start and end position within a text document.
public struct LspRange: Codable, Sendable, Equatable {
    /// The range's start position (inclusive).
    public let start: LspPosition

    /// The range's end position (exclusive).
    public let end: LspPosition

    /// Create a range.
    ///
    /// - Parameters:
    ///   - start: Start position (inclusive).
    ///   - end: End position (exclusive).
    public init(start: LspPosition, end: LspPosition) {
        self.start = start
        self.end = end
    }
}

/// LSP Location — a file URI paired with a range within that document.
public struct LspLocation: Codable, Sendable, Equatable {
    /// The document URI (e.g., `file:///path/to/file.swift`).
    public let uri: String

    /// The range within the document.
    public let range: LspRange

    /// Create a location.
    ///
    /// - Parameters:
    ///   - uri: Document URI.
    ///   - range: Range within the document.
    public init(uri: String, range: LspRange) {
        self.uri = uri
        self.range = range
    }
}

// MARK: - Hover

/// Hover contents — handles both plain string and `MarkupContent` forms from LSP.
///
/// The LSP spec allows hover contents to be a plain string, a `MarkupContent` object
/// (`{ "kind": "markdown", "value": "..." }`), or a `MarkedString`. This enum normalizes
/// the first two forms; `MarkedString` arrays are collapsed into a single markdown string.
public enum HoverContents: Sendable, Equatable {
    /// Plain text hover content.
    case string(String)

    /// Structured markup content with a kind (e.g., `"markdown"` or `"plaintext"`).
    case markup(kind: String, value: String)

    /// Extract the displayable text regardless of variant.
    public var displayText: String {
        switch self {
        case let .string(text): text
        case let .markup(_, value): value
        }
    }

    /// Decode hover contents from a raw JSON dictionary.
    ///
    /// Tries `MarkupContent` shape first (`kind` + `value` keys), then falls back to
    /// treating the value as a plain string.
    ///
    /// - Parameter json: The raw JSON value from the hover result's `contents` field.
    /// - Returns: Decoded hover contents, or `nil` if the shape is unrecognized.
    static func decode(from json: Any) -> HoverContents? {
        if let dict = json as? [String: Any],
           let kind = dict["kind"] as? String,
           let value = dict["value"] as? String {
            return .markup(kind: kind, value: value)
        }

        if let str = json as? String {
            return .string(str)
        }

        // MarkedString array — collapse to single markdown string
        if let arr = json as? [[String: Any]] {
            let combined = arr.compactMap { item -> String? in
                if let value = item["value"] as? String {
                    if let lang = item["language"] as? String {
                        return "```\(lang)\n\(value)\n```"
                    }
                    return value
                }
                return nil
            }.joined(separator: "\n\n")
            if !combined.isEmpty {
                return .markup(kind: "markdown", value: combined)
            }
        }

        return nil
    }
}

// MARK: - Document Symbols

/// A hierarchical document symbol (tree structure from `textDocument/documentSymbol`).
///
/// Modern language servers return `DocumentSymbol[]` which preserves the nesting
/// structure of the source code (classes containing methods, etc.).
public struct DocumentSymbol: Codable, Sendable {
    /// The symbol name.
    public let name: String

    /// The LSP `SymbolKind` numeric value (1 = File, 5 = Class, 6 = Method, 12 = Function, etc.).
    public let kind: Int

    /// The full range of the symbol including its body.
    public let range: LspRange

    /// The range of the symbol's name (for highlighting in UI).
    public let selectionRange: LspRange

    /// Child symbols nested inside this symbol (e.g., methods inside a class).
    public let children: [DocumentSymbol]?
}

// MARK: - Diagnostics

/// Severity level of an LSP diagnostic, mapping to the `DiagnosticSeverity` enum in the spec.
///
/// Values correspond to the LSP protocol numeric encoding:
/// 1 = Error, 2 = Warning, 3 = Information, 4 = Hint.
public enum LspDiagnosticSeverity: Int, Codable, Sendable, Comparable {
    /// A compiler error or fatal issue.
    case error = 1

    /// A compiler warning or potential issue.
    case warning = 2

    /// An informational message.
    case information = 3

    /// A hint or suggestion.
    case hint = 4

    /// Human-readable label for display in diagnostic output.
    public var label: String {
        switch self {
        case .error: "Error"
        case .warning: "Warning"
        case .information: "Info"
        case .hint: "Hint"
        }
    }

    public static func < (lhs: LspDiagnosticSeverity, rhs: LspDiagnosticSeverity) -> Bool {
        lhs.rawValue < rhs.rawValue
    }
}

/// A single diagnostic reported by the language server for a file.
///
/// Represents an error, warning, or informational message at a specific location in a document.
/// Diagnostics arrive via `textDocument/publishDiagnostics` notifications from the server.
public struct LspDiagnostic: Sendable, Equatable {
    /// The range in the document where the diagnostic applies.
    public let range: LspRange

    /// The severity of the diagnostic.
    public let severity: LspDiagnosticSeverity

    /// The human-readable diagnostic message.
    public let message: String

    /// The source of the diagnostic (e.g., `"sourcekit"`, `"swiftc"`).
    public let source: String?

    /// Create a diagnostic.
    ///
    /// - Parameters:
    ///   - range: The affected range in the document.
    ///   - severity: The diagnostic severity level.
    ///   - message: The diagnostic message text.
    ///   - source: Optional source identifier for the diagnostic producer.
    public init(range: LspRange, severity: LspDiagnosticSeverity, message: String, source: String?) {
        self.range = range
        self.severity = severity
        self.message = message
        self.source = source
    }

    /// Decode a diagnostic from a raw JSON dictionary.
    ///
    /// - Parameter dict: Dictionary with `range`, `severity`, `message`, and optional `source` keys.
    /// - Returns: The parsed diagnostic, or `nil` if required keys are missing.
    public static func decode(from dict: [String: Any]) -> LspDiagnostic? {
        guard let rangeDict = dict["range"] as? [String: Any],
              let startDict = rangeDict["start"] as? [String: Any],
              let endDict = rangeDict["end"] as? [String: Any],
              let startLine = startDict["line"] as? Int,
              let startChar = startDict["character"] as? Int,
              let endLine = endDict["line"] as? Int,
              let endChar = endDict["character"] as? Int,
              let message = dict["message"] as? String
        else { return nil }

        let severityRaw = dict["severity"] as? Int ?? 1
        let severity = LspDiagnosticSeverity(rawValue: severityRaw) ?? .error
        let source = dict["source"] as? String

        return LspDiagnostic(
            range: LspRange(
                start: LspPosition(line: startLine, character: startChar),
                end: LspPosition(line: endLine, character: endChar),
            ),
            severity: severity,
            message: message,
            source: source,
        )
    }
}

// MARK: - JSON-RPC

/// JSON-RPC 2.0 error object returned in error responses.
public struct JsonRpcError: Sendable {
    /// Numeric error code (LSP-defined or JSON-RPC standard).
    public let code: Int

    /// Human-readable error message.
    public let message: String

    /// Decode from a raw JSON dictionary.
    ///
    /// - Parameter dict: Dictionary with `code` and `message` keys.
    /// - Returns: Decoded error, or `nil` if required keys are missing.
    static func decode(from dict: [String: Any]) -> JsonRpcError? {
        guard let code = dict["code"] as? Int,
              let message = dict["message"] as? String
        else { return nil }
        return JsonRpcError(code: code, message: message)
    }
}

// MARK: - Symbol Kind Names

/// Human-readable names for LSP `SymbolKind` values.
///
/// Maps the numeric SymbolKind enum (1-26) from the LSP specification to display strings.
/// Uses O(1) array lookup; unknown kinds fall back to `"Symbol"`.
enum SymbolKindName {
    /// LSP SymbolKind names indexed by their numeric value (1-based).
    private static let names: [String] = [
        "File", "Module", "Namespace", "Package", "Class",
        "Method", "Property", "Field", "Constructor", "Enum",
        "Interface", "Function", "Variable", "Constant", "String",
        "Number", "Boolean", "Array", "Object", "Key",
        "Null", "EnumMember", "Struct", "Event", "Operator",
        "TypeParameter",
    ]

    /// Convert a numeric LSP SymbolKind to a human-readable name.
    ///
    /// - Parameter kind: The numeric SymbolKind value from the LSP response.
    /// - Returns: A display string like `"Function"`, `"Class"`, etc.
    static func name(for kind: Int) -> String {
        let index = kind - 1
        guard names.indices.contains(index) else { return "Symbol" }
        return names[index]
    }
}
