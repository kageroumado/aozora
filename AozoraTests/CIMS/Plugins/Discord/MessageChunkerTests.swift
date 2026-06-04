import Foundation
import Testing
@testable import Aozora

/// Tests for ``MessageChunker`` — code fence-aware message splitting.
///
/// Verifies that Markdown code fences are never left unclosed at chunk boundaries,
/// that language annotations are preserved across splits, and that non-fenced content
/// is split identically to the previous naive implementation.
struct MessageChunkerTests {
    // MARK: - Basic Splitting (preserves existing behavior)

    @Test
    func `Short message is not split`() {
        let chunks = MessageChunker.split("Hello!", maxLength: 100)
        #expect(chunks == ["Hello!"])
    }

    @Test
    func `Long message splits on newline`() {
        let line1 = String(repeating: "a", count: 50)
        let line2 = String(repeating: "b", count: 50)
        let text = "\(line1)\n\(line2)"

        let chunks = MessageChunker.split(text, maxLength: 80)
        #expect(chunks.count == 2)
        #expect(chunks[0].contains(line1))
        #expect(chunks[1].contains(line2))
    }

    @Test
    func `Long message splits on space when no newline`() {
        let text = "Hello World This Is A Test Of Splitting"
        let chunks = MessageChunker.split(text, maxLength: 25)

        #expect(chunks.count > 1)
        // Reassembled text should contain all words
        let reassembled = chunks.joined(separator: " ")
        for word in ["Hello", "World", "This", "Is", "A", "Test"] {
            #expect(reassembled.contains(word))
        }
    }

    @Test
    func `No fences: normal split behavior preserved`() {
        let text = String(repeating: "word ", count: 600) // ~3000 chars
        let chunks = MessageChunker.split(text, maxLength: 2_000)

        #expect(chunks.count >= 2)
        for chunk in chunks {
            #expect(chunk.count <= 2_000)
        }
        // No fence markers should appear
        for chunk in chunks {
            #expect(!chunk.hasPrefix("```"))
        }
    }

    // MARK: - Code Fence Integrity

    @Test
    func `Short code fence is not split`() {
        let text = """
        Hello
        ```swift
        let x = 42
        ```
        World
        """
        let chunks = MessageChunker.split(text, maxLength: 500)
        #expect(chunks.count == 1)
    }

    @Test
    func `Long code fence is closed at split and reopened`() {
        let before = "Some text before\n```swift\n"
        let code = (0 ..< 50).map { "let x\($0) = \($0)" }.joined(separator: "\n")
        let after = "\n```\nSome text after"
        let text = before + code + after

        let chunks = MessageChunker.split(text, maxLength: 500)

        #expect(chunks.count >= 2)

        // First chunk should end with closing fence
        #expect(chunks[0].hasSuffix("```"))

        // Second chunk should start with reopened fence with language
        #expect(chunks[1].hasPrefix("```swift\n"))

        // All chunks should have balanced fences
        for chunk in chunks {
            assertBalancedFences(chunk)
        }
    }

    @Test
    func `Language annotation is preserved across split`() {
        let text = "Intro\n```python\n" + String(repeating: "print('hello')\n", count: 200) + "```\nDone"
        let chunks = MessageChunker.split(text, maxLength: 500)

        #expect(chunks.count >= 2)

        // Find chunks that reopen a fence — they should use "python"
        for chunk in chunks.dropFirst() {
            if chunk.hasPrefix("```") {
                #expect(chunk.hasPrefix("```python\n"))
            }
        }
    }

    @Test
    func `Multiple code blocks in message handled independently`() {
        let text = """
        Block 1:
        ```swift
        let a = 1
        ```
        
        Block 2:
        ```python
        x = 2
        ```
        
        Block 3:
        ```rust
        let b = 3;
        ```
        """
        let chunks = MessageChunker.split(text, maxLength: 2_000)
        #expect(chunks.count == 1) // Should fit in one chunk

        // All fences balanced
        assertBalancedFences(chunks[0])
    }

    @Test
    func `Multiple code blocks spanning a split`() {
        var text = "Start\n"
        // First block — will be in chunk 1
        text += "```swift\nlet x = 1\n```\n"
        // Filler to push toward split
        text += String(repeating: "filler line\n", count: 30)
        // Second block — may span the split
        text += "```python\n"
        text += String(repeating: "print('hello')\n", count: 30)
        text += "```\n"
        text += "End"

        let chunks = MessageChunker.split(text, maxLength: 500)
        for chunk in chunks {
            assertBalancedFences(chunk)
        }
    }

    @Test
    func `Code fence without language annotation`() {
        let text = "Intro\n```\n" + String(repeating: "line\n", count: 200) + "```\nDone"
        let chunks = MessageChunker.split(text, maxLength: 500)

        #expect(chunks.count >= 2)

        // Reopened fence should have no language
        for chunk in chunks.dropFirst() {
            if chunk.hasPrefix("```") {
                // Should be just ``` followed by newline, not ```\n``` (empty block)
                let firstLine = chunk.prefix(while: { $0 != "\n" })
                #expect(firstLine == "```")
            }
        }
    }

    @Test
    func `Backticks inside code don't confuse fence tracking`() {
        // Inline backticks (not at start of line) shouldn't toggle
        let text = "```swift\nlet s = \"use ``` for code\"\nlet y = 42\n```"
        let chunks = MessageChunker.split(text, maxLength: 2_000)
        #expect(chunks.count == 1)
        assertBalancedFences(chunks[0])
    }

    // MARK: - Edge Cases

    @Test
    func `Empty string returns single empty chunk`() {
        let chunks = MessageChunker.split("", maxLength: 100)
        #expect(chunks == [""])
    }

    @Test
    func `Exactly maxLength string not split`() {
        let text = String(repeating: "a", count: 100)
        let chunks = MessageChunker.split(text, maxLength: 100)
        #expect(chunks.count == 1)
    }

    @Test
    func `Content after split reassembles correctly`() {
        let lines = (0 ..< 100).map { "Line \($0): some content here" }
        let text = lines.joined(separator: "\n")
        let chunks = MessageChunker.split(text, maxLength: 500)

        // Strip any fence markers added by the chunker
        let reassembled = chunks.joined()
        for i in 0 ..< 100 {
            #expect(reassembled.contains("Line \(i):"))
        }
    }

    // MARK: - Helpers

    /// Assert that all code fences in the text are balanced (equal opens and closes).
    private func assertBalancedFences(_ text: String) {
        var depth = 0
        for line in text.split(separator: "\n", omittingEmptySubsequences: false) {
            let trimmed = line.drop(while: { $0 == " " || $0 == "\t" })
            if trimmed.hasPrefix("```") {
                if depth > 0 {
                    depth -= 1
                } else {
                    depth += 1
                }
            }
        }
        #expect(depth == 0, "Unbalanced fences: depth = \(depth) in:\n\(text.prefix(200))")
    }
}
