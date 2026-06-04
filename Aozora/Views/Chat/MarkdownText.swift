import SwiftUI

/// Renders markdown text using ``AttributedString``.
///
/// Uses SwiftUI's built-in markdown parser for basic formatting
/// (bold, italic, code, links). Text selection is enabled.
struct MarkdownText: View {
    /// The raw markdown text to render.
    let text: String

    var body: some View {
        if let attributed = try? AttributedString(
            markdown: text,
            options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace),
        ) {
            Text(attributed)
                .textSelection(.enabled)
        } else {
            Text(text)
                .textSelection(.enabled)
        }
    }
}
