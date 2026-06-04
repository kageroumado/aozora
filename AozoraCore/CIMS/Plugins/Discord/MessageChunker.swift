import Foundation

/// Splits text into chunks respecting a maximum length while preserving Markdown code fence integrity.
///
/// When a split point falls inside an open code fence, the chunker closes the fence
/// at the end of the current chunk and reopens it (with the original language annotation)
/// at the start of the next chunk. This prevents Discord from rendering broken code blocks.
///
/// The chunker prefers splitting on newlines, then spaces, falling back to hard character
/// splits only when no natural boundary exists. Code fence overhead (closing/reopening markers)
/// is accounted for by reserving a small margin from the maximum length.
public nonisolated struct MessageChunker: Sendable {
    /// Maximum characters reserved for fence close/reopen markers.
    ///
    /// Closing: `"\n```"` = 4 chars. Reopening: `"```swift\n"` up to ~15 chars.
    /// 20 chars is a conservative reserve that covers any language annotation.
    private static let fenceOverhead = 20

    /// Split text into chunks that fit within `maxLength`, preserving code fence integrity.
    ///
    /// - Parameters:
    ///   - text: The text to split.
    ///   - maxLength: Maximum character count per chunk (e.g., 2000 for Discord).
    /// - Returns: An array of chunks, each at most `maxLength` characters.
    public static func split(_ text: String, maxLength: Int) -> [String] {
        guard text.count > maxLength else { return [text] }

        // Only reserve overhead if the text contains code fences
        let hasFences = text.contains("```")
        let effectiveMax = hasFences
            ? max(maxLength - fenceOverhead, maxLength * 3 / 4)
            : maxLength
        let rawChunks = naiveSplit(text, maxLength: effectiveMax)

        guard hasFences else { return rawChunks }
        return fixCodeFences(rawChunks)
    }

    // MARK: - Naive Splitting

    /// Split text into chunks without code fence awareness.
    ///
    /// Prefers splitting on newlines, then spaces, falling back to hard character splits.
    private static func naiveSplit(_ text: String, maxLength: Int) -> [String] {
        var chunks: [String] = []
        var remaining = text[...]

        while !remaining.isEmpty {
            if remaining.count <= maxLength {
                chunks.append(String(remaining))
                break
            }

            let searchRange = remaining.prefix(maxLength)

            // Try to split at a newline
            if let newlineIndex = searchRange.lastIndex(of: "\n") {
                chunks.append(String(remaining[remaining.startIndex ... newlineIndex]))
                remaining = remaining[remaining.index(after: newlineIndex)...]
            }
            // Try to split at a space
            else if let spaceIndex = searchRange.lastIndex(of: " ") {
                chunks.append(String(remaining[remaining.startIndex ..< spaceIndex]))
                remaining = remaining[remaining.index(after: spaceIndex)...]
            }
            // Hard split
            else {
                let splitIndex = remaining.index(remaining.startIndex, offsetBy: maxLength)
                chunks.append(String(remaining[remaining.startIndex ..< splitIndex]))
                remaining = remaining[splitIndex...]
            }
        }

        return chunks
    }

    // MARK: - Code Fence Post-Processing

    /// Post-process raw chunks to close and reopen code fences at chunk boundaries.
    private static func fixCodeFences(_ chunks: [String]) -> [String] {
        guard chunks.count > 1 else { return chunks }

        var result: [String] = []
        var fenceOpen = false
        var fenceLang = ""

        for (i, chunk) in chunks.enumerated() {
            var output = ""

            // Reopen fence from previous chunk
            if fenceOpen {
                output = "```\(fenceLang)\n"
            }
            output += chunk

            // Scan this chunk's lines to update fence state.
            // We scan the *original* chunk (not the prepended output) because
            // the prepended opening is already represented by fenceOpen being true.
            updateFenceState(scanning: chunk, fenceOpen: &fenceOpen, fenceLang: &fenceLang)

            // If fence is still open and this isn't the last chunk, close it
            if fenceOpen, i < chunks.count - 1 {
                output += "\n```"
            }

            result.append(output)
        }

        return result
    }

    /// Scan text line-by-line and update fence state.
    ///
    /// A line starting with ``` (possibly with leading whitespace) toggles the fence.
    /// When opening, the language annotation (e.g., "swift" from "```swift") is captured.
    private static func updateFenceState(
        scanning text: String,
        fenceOpen: inout Bool,
        fenceLang: inout String,
    ) {
        for line in text.split(separator: "\n", omittingEmptySubsequences: false) {
            let trimmed = line.drop(while: { $0 == " " || $0 == "\t" })
            guard trimmed.hasPrefix("```") else { continue }

            if fenceOpen {
                // Closing fence
                fenceOpen = false
                fenceLang = ""
            } else {
                // Opening fence — capture language annotation
                fenceOpen = true
                let afterBackticks = trimmed.dropFirst(3)
                fenceLang = String(afterBackticks.prefix(while: { !$0.isWhitespace }))
            }
        }
    }
}
