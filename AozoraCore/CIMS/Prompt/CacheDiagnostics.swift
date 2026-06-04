import CryptoKit
import Foundation

/// Pure diagnostic reporter for prompt cache behavior analysis.
///
/// Computes content hashes, token estimates, and change detection for system blocks,
/// then formats the results into human-readable log lines. All methods are static and
/// side-effect-free — safe to call from any isolation domain.
public nonisolated struct CacheDiagnostics: Sendable {
    /// Build a diagnostic report from a prompt, its token usage, and optional previous-turn hashes.
    ///
    /// - Parameters:
    ///   - prompt: The prompt whose system blocks and tools are analyzed.
    ///   - usage: Token usage from the API response.
    ///   - boundaryIndex: The message index where the cache boundary was placed, or `nil`.
    ///   - previousSystemHash: The `systemHash` from the previous turn, used for change detection.
    ///   - previousBlockHashes: Per-block `contentHash` values from the previous turn.
    /// - Returns: A ``DiagnosticReport`` summarizing cache state and any detected changes.
    public static func report(
        prompt: Prompt,
        usage: TokenUsage,
        boundaryIndex: Int?,
        previousSystemHash: String?,
        previousBlockHashes: [String]?,
    ) -> DiagnosticReport {
        let blocks = prompt.system.enumerated().map { index, block in
            BlockInfo(
                index: index,
                tokenEstimate: block.text.utf8.count / 4,
                hasCacheControl: block.cacheControl != nil,
                contentHash: sha256Prefix(block.text),
            )
        }

        let systemHash = sha256Prefix(prompt.system.map(\.text).joined(separator: "\n"))

        let toolsHash: String = {
            guard !prompt.tools.isEmpty else { return "00000000" }
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
            guard let data = try? encoder.encode(prompt.tools) else { return "err00000" }
            return sha256Prefix(data)
        }()

        let systemHashChanged: Bool = if let prev = previousSystemHash {
            prev != systemHash
        } else {
            false
        }

        let changedBlockIndices: [Int] = if let prevHashes = previousBlockHashes {
            blocks.enumerated().compactMap { i, block in
                if i < prevHashes.count, prevHashes[i] != block.contentHash { return i }
                else if i >= prevHashes.count { return i }
                return nil
            }
        } else {
            []
        }

        let hitPercent = Int((usage.cacheHitRate * 100).rounded())

        return DiagnosticReport(
            inputTokens: usage.inputTokens,
            outputTokens: usage.outputTokens,
            cacheRead: usage.cacheReadTokens,
            cacheCreate: usage.cacheCreationTokens,
            hitPercent: hitPercent,
            systemHash: systemHash,
            toolsHash: toolsHash,
            blockCount: prompt.system.count,
            toolCount: prompt.tools.count,
            messageCount: prompt.messages.count,
            boundaryIndex: boundaryIndex,
            blocks: blocks,
            systemHashChanged: systemHashChanged,
            previousSystemHash: previousSystemHash,
            changedBlockIndices: changedBlockIndices,
        )
    }

    /// Format a diagnostic report as multi-line log output.
    ///
    /// Produces lines prefixed with `[tokens]` containing token counts, hashes,
    /// block summaries, and optional change warnings.
    ///
    /// - Parameter r: The report to format.
    /// - Returns: A newline-joined string suitable for logging.
    public static func format(_ r: DiagnosticReport) -> String {
        var lines: [String] = []

        let boundaryStr = r.boundaryIndex.map(String.init) ?? "null"
        let ts = timestampNow()

        lines.append(
            "\(ts) [tokens] in=\(r.inputTokens) out=\(r.outputTokens) "
                + "cache_read=\(r.cacheRead) cache_create=\(r.cacheCreate) hit=\(r.hitPercent)%",
        )
        lines.append(
            "  system_hash=\(r.systemHash) blocks=\(r.blockCount) "
                + "tools=\(r.toolCount) tools_hash=\(r.toolsHash)",
        )
        lines.append("  msgs=\(r.messageCount) boundary=\(boundaryStr)")

        let blockDescs = r.blocks.map { b in
            let cc = b.hasCacheControl ? "cc" : "no_cc"
            return "block[\(b.index)]=\(b.tokenEstimate)tok/\(cc)"
        }
        lines.append("  " + blockDescs.joined(separator: " "))

        if r.systemHashChanged, let prev = r.previousSystemHash {
            lines.append("[tokens] WARNING: system_hash changed: \(prev) → \(r.systemHash)")
            for i in r.changedBlockIndices {
                if i < r.blocks.count {
                    let b = r.blocks[i]
                    lines.append("  block[\(i)] CHANGED hash: \(b.contentHash)")
                }
            }
        }

        return lines.joined(separator: "\n")
    }

    /// Format a diagnostic report for tool-loop iterations.
    ///
    /// Replaces the `[tokens]` prefix with `[tool-loop] iter=N` to distinguish
    /// mid-loop diagnostics from initial-turn diagnostics.
    ///
    /// - Parameters:
    ///   - r: The report to format.
    ///   - iteration: The zero-based tool-loop iteration number.
    /// - Returns: A formatted string with tool-loop prefixes.
    public static func formatToolLoop(_ r: DiagnosticReport, iteration: Int) -> String {
        let base = format(r)
        return base.replacingOccurrences(of: "[tokens]", with: "[tool-loop] iter=\(iteration)")
    }

    // MARK: - Private

    private nonisolated(unsafe) static let tsFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "HH:mm:ss"
        f.timeZone = TimeZone(identifier: "Europe/Paris")
        return f
    }()

    private static func timestampNow() -> String {
        tsFormatter.string(from: Date())
    }

    private static func sha256Prefix(_ string: String) -> String {
        sha256Prefix(Data(string.utf8))
    }

    private static func sha256Prefix(_ data: Data) -> String {
        let digest = SHA256.hash(data: data)
        return digest.prefix(4).map { String(format: "%02x", $0) }.joined()
    }
}

// MARK: - Report Types

/// Immutable snapshot of prompt cache diagnostics for a single API turn.
///
/// Contains token counts, content hashes for change detection, and block-level detail.
/// Produced by ``CacheDiagnostics/report(prompt:usage:boundaryIndex:previousSystemHash:previousBlockHashes:)``.
public struct DiagnosticReport: Sendable {
    /// Non-cached input tokens charged at full price.
    public let inputTokens: Int
    /// Output tokens generated by the model.
    public let outputTokens: Int
    /// Tokens served from the prompt cache (free input).
    public let cacheRead: Int
    /// Tokens written to the prompt cache this turn.
    public let cacheCreate: Int
    /// Cache hit percentage (0–100), rounded from ``TokenUsage/cacheHitRate``.
    public let hitPercent: Int
    /// SHA-256 prefix (8 hex chars) of all system block texts joined by newline.
    public let systemHash: String
    /// SHA-256 prefix of the JSON-encoded tools array, or `"00000000"` if empty.
    public let toolsHash: String
    /// Number of system blocks in the prompt.
    public let blockCount: Int
    /// Number of tool definitions in the prompt.
    public let toolCount: Int
    /// Number of conversation messages in the prompt.
    public let messageCount: Int
    /// Message index where the cache boundary was placed, if any.
    public let boundaryIndex: Int?
    /// Per-block diagnostic info (index, token estimate, cache control, content hash).
    public let blocks: [BlockInfo]
    /// Whether the system hash differs from the previous turn's hash.
    public let systemHashChanged: Bool
    /// The previous turn's system hash, for logging when a change is detected.
    public let previousSystemHash: String?
    /// Indices of blocks whose content hash differs from the previous turn.
    public let changedBlockIndices: [Int]
}

/// Diagnostic info for a single system block.
public struct BlockInfo: Sendable {
    /// Zero-based position in the system block array.
    public let index: Int
    /// Rough token estimate: `utf8.count / 4`.
    public let tokenEstimate: Int
    /// Whether this block has a `cache_control` annotation.
    public let hasCacheControl: Bool
    /// SHA-256 prefix (8 hex chars) of the block's text content.
    public let contentHash: String
}
