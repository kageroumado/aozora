import Foundation
import Testing
@testable import Aozora

struct LSPDiagnosticInjectionTests {
    // MARK: - DiagnosticInjector Formatting

    @Test
    func `formats diagnostics with errors sorted first`() {
        let diagnostics = [
            LspDiagnostic(
                range: LspRange(
                    start: LspPosition(line: 15, character: 0),
                    end: LspPosition(line: 15, character: 10),
                ),
                severity: .warning,
                message: "unused variable 'x'",
                source: "swiftc",
            ),
            LspDiagnostic(
                range: LspRange(
                    start: LspPosition(line: 42, character: 5),
                    end: LspPosition(line: 42, character: 20),
                ),
                severity: .error,
                message: "cannot convert value of type 'String' to expected argument type 'Int'",
                source: "swiftc",
            ),
            LspDiagnostic(
                range: LspRange(
                    start: LspPosition(line: 3, character: 0),
                    end: LspPosition(line: 3, character: 5),
                ),
                severity: .hint,
                message: "consider using let",
                source: nil,
            ),
        ]

        let result = DiagnosticInjector.format(diagnostics: diagnostics, filePath: "src/Foo.swift")

        let lines = result.components(separatedBy: "\n")
        #expect(lines[0].contains("file_diagnostics"))
        #expect(lines[0].contains("src/Foo.swift"))

        #expect(lines[1].hasPrefix("Error"))
        #expect(lines[2].hasPrefix("Warning"))
        #expect(lines[3].hasPrefix("Hint"))
    }

    @Test
    func `returns nil for empty diagnostic array`() async {
        let injector = DiagnosticInjector()
        let registry = LspServerRegistry()

        let result = await injector.fetchDiagnostics(
            for: "/tmp/nonexistent_\(UUID().uuidString).xyz",
            workingDirectory: "/tmp",
            registry: registry,
        )

        #expect(result == nil)
    }

    @Test
    func `format includes one-indexed line numbers`() {
        let diagnostics = [
            LspDiagnostic(
                range: LspRange(
                    start: LspPosition(line: 41, character: 0),
                    end: LspPosition(line: 41, character: 10),
                ),
                severity: .error,
                message: "type mismatch",
                source: nil,
            ),
        ]

        let result = DiagnosticInjector.format(diagnostics: diagnostics, filePath: "test.swift")

        #expect(result.contains("(line 42)"))
        #expect(!result.contains("(line 41)"))
    }

    @Test
    func `severity labels are correct for all levels`() {
        #expect(LspDiagnosticSeverity.error.label == "Error")
        #expect(LspDiagnosticSeverity.warning.label == "Warning")
        #expect(LspDiagnosticSeverity.information.label == "Info")
        #expect(LspDiagnosticSeverity.hint.label == "Hint")
    }

    @Test
    func `format wraps output in XML tags`() {
        let diagnostics = [
            LspDiagnostic(
                range: LspRange(
                    start: LspPosition(line: 0, character: 0),
                    end: LspPosition(line: 0, character: 5),
                ),
                severity: .warning,
                message: "test warning",
                source: nil,
            ),
        ]

        let result = DiagnosticInjector.format(diagnostics: diagnostics, filePath: "/path/to/File.swift")

        #expect(result.contains("<file_diagnostics path=\"/path/to/File.swift\">"))
        #expect(result.contains("</file_diagnostics>"))
    }

    // MARK: - LspDiagnostic Parsing

    @Test
    func `decodes diagnostic from valid JSON dictionary`() {
        let dict: [String: Any] = [
            "range": [
                "start": ["line": 10, "character": 5] as [String: Any],
                "end": ["line": 10, "character": 15] as [String: Any],
            ] as [String: Any],
            "severity": 1,
            "message": "cannot find 'foo' in scope",
            "source": "sourcekit",
        ]

        let diag = LspDiagnostic.decode(from: dict)
        #expect(diag != nil)
        #expect(diag?.range.start.line == 10)
        #expect(diag?.range.start.character == 5)
        #expect(diag?.range.end.line == 10)
        #expect(diag?.range.end.character == 15)
        #expect(diag?.severity == .error)
        #expect(diag?.message == "cannot find 'foo' in scope")
        #expect(diag?.source == "sourcekit")
    }

    @Test
    func `decodes diagnostic without source field`() {
        let dict: [String: Any] = [
            "range": [
                "start": ["line": 0, "character": 0] as [String: Any],
                "end": ["line": 0, "character": 1] as [String: Any],
            ] as [String: Any],
            "severity": 2,
            "message": "warning message",
        ]

        let diag = LspDiagnostic.decode(from: dict)
        #expect(diag != nil)
        #expect(diag?.severity == .warning)
        #expect(diag?.source == nil)
    }

    @Test
    func `decodes diagnostic without severity field (defaults to error)`() {
        let dict: [String: Any] = [
            "range": [
                "start": ["line": 5, "character": 0] as [String: Any],
                "end": ["line": 5, "character": 10] as [String: Any],
            ] as [String: Any],
            "message": "some message",
        ]

        let diag = LspDiagnostic.decode(from: dict)
        #expect(diag != nil)
        #expect(diag?.severity == .error)
    }

    @Test
    func `returns nil for dictionary missing range`() {
        let dict: [String: Any] = [
            "severity": 1,
            "message": "error message",
        ]

        #expect(LspDiagnostic.decode(from: dict) == nil)
    }

    @Test
    func `returns nil for dictionary missing message`() {
        let dict: [String: Any] = [
            "range": [
                "start": ["line": 0, "character": 0] as [String: Any],
                "end": ["line": 0, "character": 1] as [String: Any],
            ] as [String: Any],
            "severity": 1,
        ]

        #expect(LspDiagnostic.decode(from: dict) == nil)
    }

    @Test
    func `decodes all severity levels`() {
        for rawValue in 1 ... 4 {
            let dict: [String: Any] = [
                "range": [
                    "start": ["line": 0, "character": 0] as [String: Any],
                    "end": ["line": 0, "character": 1] as [String: Any],
                ] as [String: Any],
                "severity": rawValue,
                "message": "test",
            ]

            let diag = LspDiagnostic.decode(from: dict)
            #expect(diag != nil)
            #expect(diag?.severity.rawValue == rawValue)
        }
    }

    // MARK: - LspDiagnosticSeverity

    @Test
    func `severity comparison orders by protocol value`() {
        #expect(LspDiagnosticSeverity.error < .warning)
        #expect(LspDiagnosticSeverity.warning < .information)
        #expect(LspDiagnosticSeverity.information < .hint)
    }

    @Test
    func `severity raw values match LSP protocol`() {
        #expect(LspDiagnosticSeverity.error.rawValue == 1)
        #expect(LspDiagnosticSeverity.warning.rawValue == 2)
        #expect(LspDiagnosticSeverity.information.rawValue == 3)
        #expect(LspDiagnosticSeverity.hint.rawValue == 4)
    }

    // MARK: - LspDiagnostic Equality

    @Test
    func `diagnostics with same fields are equal`() {
        let a = LspDiagnostic(
            range: LspRange(
                start: LspPosition(line: 1, character: 2),
                end: LspPosition(line: 1, character: 10),
            ),
            severity: .warning,
            message: "unused",
            source: "swiftc",
        )
        let b = LspDiagnostic(
            range: LspRange(
                start: LspPosition(line: 1, character: 2),
                end: LspPosition(line: 1, character: 10),
            ),
            severity: .warning,
            message: "unused",
            source: "swiftc",
        )
        #expect(a == b)
    }

    @Test
    func `diagnostics with different messages are not equal`() {
        let a = LspDiagnostic(
            range: LspRange(
                start: LspPosition(line: 0, character: 0),
                end: LspPosition(line: 0, character: 1),
            ),
            severity: .error,
            message: "error A",
            source: nil,
        )
        let b = LspDiagnostic(
            range: LspRange(
                start: LspPosition(line: 0, character: 0),
                end: LspPosition(line: 0, character: 1),
            ),
            severity: .error,
            message: "error B",
            source: nil,
        )
        #expect(a != b)
    }

    // MARK: - Multiple Diagnostics Formatting

    @Test
    func `format handles multiple diagnostics of same severity`() {
        let diagnostics = [
            LspDiagnostic(
                range: LspRange(
                    start: LspPosition(line: 0, character: 0),
                    end: LspPosition(line: 0, character: 5),
                ),
                severity: .error,
                message: "first error",
                source: nil,
            ),
            LspDiagnostic(
                range: LspRange(
                    start: LspPosition(line: 9, character: 0),
                    end: LspPosition(line: 9, character: 5),
                ),
                severity: .error,
                message: "second error",
                source: nil,
            ),
        ]

        let result = DiagnosticInjector.format(diagnostics: diagnostics, filePath: "test.swift")

        #expect(result.contains("Error (line 1): first error"))
        #expect(result.contains("Error (line 10): second error"))
    }
}
