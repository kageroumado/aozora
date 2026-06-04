import Foundation

/// Fetches LSP diagnostics for a file and formats them as an XML block for tool result injection.
///
/// After a file is written or edited, the injector notifies the language server of the save,
/// waits for diagnostics, and returns a formatted XML string that can be appended to the tool
/// result. This gives the model immediate visibility into compilation errors and warnings
/// without requiring a separate tool call.
///
/// The injector is stateless and `Sendable` — it delegates to the ``LspServerRegistry`` for
/// server management and to ``LspClient`` for the LSP protocol exchange.
public struct DiagnosticInjector: Sendable {
    /// Create a diagnostic injector.
    public init() {}

    /// Fetch diagnostics for a file and format them as an XML block.
    ///
    /// Sends `textDocument/didSave` to the appropriate language server, waits for
    /// `publishDiagnostics` notifications, and formats the results. Returns `nil` if
    /// no language server is available, no diagnostics are reported, or an error occurs.
    ///
    /// - Parameters:
    ///   - filePath: Absolute path to the file to check.
    ///   - workingDirectory: The workspace root directory for the LSP server.
    ///   - registry: The LSP server registry for obtaining a client.
    /// - Returns: A formatted XML diagnostics block, or `nil` if there are no diagnostics.
    public func fetchDiagnostics(
        for filePath: String,
        workingDirectory: String,
        registry: LspServerRegistry,
    ) async -> String? {
        guard let client = try? await registry.getClient(for: filePath, rootDir: workingDirectory) else {
            return nil
        }

        await client.sendDidSave(file: filePath)
        let diagnostics = await client.diagnostics(for: filePath, timeout: 5.0)

        guard !diagnostics.isEmpty else { return nil }

        return Self.format(diagnostics: diagnostics, filePath: filePath)
    }

    /// Format an array of diagnostics into an XML block for tool result injection.
    ///
    /// Diagnostics are sorted by severity (errors first, then warnings, then info, then hints)
    /// and formatted with one-indexed line numbers for human readability.
    ///
    /// - Parameters:
    ///   - diagnostics: The diagnostics to format.
    ///   - filePath: The file path to display in the XML tag.
    /// - Returns: A formatted XML string.
    public static func format(diagnostics: [LspDiagnostic], filePath: String) -> String {
        let sorted = diagnostics.sorted { $0.severity < $1.severity }

        var lines: [String] = []
        for diag in sorted {
            let lineNum = diag.range.start.line + 1
            lines.append("\(diag.severity.label) (line \(lineNum)): \(diag.message)")
        }

        return """
        <file_diagnostics path="\(filePath)">
        \(lines.joined(separator: "\n"))
        </file_diagnostics>
        """
    }
}
