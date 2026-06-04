import Foundation

/// Scans text for common prompt injection patterns that attempt to subvert the cognitive cycle.
///
/// Prompt injection is the primary attack vector against LLM-based systems. This scanner provides
/// a heuristic first line of defense by matching known injection patterns against inbound text.
/// It protects against:
/// - Tool results that try to override system instructions.
/// - User messages that try to extract system prompts.
/// - Context files with embedded instructions attempting to hijack the system role.
///
/// The scanner is a pure function with no side effects or I/O. It produces a ``ScanResult``
/// that the ``ContextAssembler`` (or caller) can use to flag, redact, or reject suspicious content.
///
/// **Design:** Pattern-based detection trades recall for precision — it won't catch novel attacks,
/// but it has near-zero false positives on conversational text. The patterns are intentionally
/// conservative: a match means the text is almost certainly adversarial.
public nonisolated struct PromptInjectionScanner: Sendable {
    // MARK: - Result Types

    /// The outcome of scanning a text for prompt injection patterns.
    public struct ScanResult: Sendable {
        /// Whether the scanned text is free of detected threats.
        public let isClean: Bool

        /// All detected threats, empty if ``isClean`` is `true`.
        public let threats: [Threat]

        public init(isClean: Bool, threats: [Threat]) {
            self.isClean = isClean
            self.threats = threats
        }
    }

    /// A single detected prompt injection threat with its classification and evidence.
    public struct Threat: Sendable {
        /// The category of injection attack detected.
        public let kind: ThreatKind

        /// The regex pattern that matched.
        public let pattern: String

        /// A short excerpt of the matched text for diagnostic logging.
        public let excerpt: String

        public init(kind: ThreatKind, pattern: String, excerpt: String) {
            self.kind = kind
            self.pattern = pattern
            self.excerpt = excerpt
        }
    }

    /// Classification of prompt injection attack vectors.
    ///
    /// Each kind maps to a distinct adversarial intent, enabling targeted response
    /// (e.g., system prompt overrides might warrant rejection, while data exfiltration
    /// attempts might just be flagged).
    public nonisolated enum ThreatKind: String, Sendable {
        /// Attempts to make the model ignore its existing instructions.
        case systemPromptOverride

        /// Attempts to inject new behavioral instructions.
        case instructionInjection

        /// Attempts to make the model assume a different identity or role.
        case roleImpersonation

        /// Attempts to extract the system prompt or internal instructions.
        case dataExfiltration

        /// Attempts to make the model repeat or copy its instructions.
        case promptLeakage
    }

    // MARK: - Pattern Definitions

    /// Pattern groups keyed by threat kind. Each group contains regex pattern strings
    /// that are compiled on demand during scanning.
    private static let standardPatternGroups: [(ThreatKind, [String])] = [
        (.systemPromptOverride, [
            #"ignore (all |any )?(previous |prior |above )?instructions"#,
            #"disregard (all |your )?instructions"#,
            #"forget (all |your )?(previous )?instructions"#,
        ]),
        (.instructionInjection, [
            #"you (must|should|will|are) now"#,
            #"new instructions:"#,
            #"(?m)^\s*system\s*:"#,
            #"<\|system\|>"#,
            #"\[INST\]"#,
            #"\[/INST\]"#,
        ]),
        (.roleImpersonation, [
            #"you are (now |actually )"#,
            #"act as (if you|a|an)"#,
            #"pretend (to be|you are)"#,
            #"I am (the |your )?(system|admin|developer)"#,
        ]),
        (.dataExfiltration, [
            #"(print|output|show|reveal|display) (your |the )?(system prompt|instructions|system message)"#,
            #"what (is|are) your (instructions|system prompt|rules)"#,
        ]),
        (.promptLeakage, [
            #"repeat (everything|all|the text) (above|before)"#,
            #"copy (the|your) (instructions|prompt)"#,
        ]),
    ]

    /// Additional patterns checked only for tool results (stricter scanning).
    /// These detect structured injection attempts specific to tool outputs.
    private static let toolOnlyPatterns: [String] = [
        #"role.*system"#,
        #"<message.*role.*system"#,
        #"</system>"#,
        #"\[/SYSTEM\]"#,
    ]

    // MARK: - Scanning

    /// Scan arbitrary text for prompt injection patterns.
    ///
    /// Checks against all standard threat categories (system prompt override, instruction
    /// injection, role impersonation, data exfiltration, prompt leakage). The scan is
    /// case-insensitive and works on partial matches within longer text.
    ///
    /// - Parameter text: The text to scan.
    /// - Returns: A ``ScanResult`` with ``ScanResult/isClean`` set to `true` if no threats found.
    public func scan(_ text: String) -> ScanResult {
        let threats = detectThreats(in: text, includeToolPatterns: false)
        return ScanResult(isClean: threats.isEmpty, threats: threats)
    }

    /// Scan tool result text with stricter detection thresholds.
    ///
    /// In addition to all standard patterns, this checks for structured injection attempts
    /// that are specific to tool outputs: XML/JSON message injection with system roles,
    /// and attempts to close and reopen the system context.
    ///
    /// Tool results are higher-risk because they come from external sources (web pages,
    /// APIs, file contents) that an attacker can control.
    ///
    /// - Parameter text: The tool result text to scan.
    /// - Returns: A ``ScanResult`` with ``ScanResult/isClean`` set to `true` if no threats found.
    public func scanToolResult(_ text: String) -> ScanResult {
        let threats = detectThreats(in: text, includeToolPatterns: true)
        return ScanResult(isClean: threats.isEmpty, threats: threats)
    }

    // MARK: - Internal

    /// Core detection logic shared by both scan methods.
    ///
    /// Compiles regex patterns on demand and matches them against the input text.
    /// Pattern compilation is lightweight (~20 patterns total) and avoids storing
    /// non-`Sendable` `Regex` values in the struct.
    ///
    /// - Parameters:
    ///   - text: The text to scan.
    ///   - includeToolPatterns: Whether to include the additional tool-result-specific patterns.
    /// - Returns: All detected threats.
    private func detectThreats(in text: String, includeToolPatterns: Bool) -> [Threat] {
        var threats: [Threat] = []

        for (kind, patterns) in Self.standardPatternGroups {
            for pattern in patterns {
                guard let regex = try? Regex(pattern).ignoresCase() else { continue }
                if let match = text.firstMatch(of: regex) {
                    let excerpt = extractExcerpt(from: text, matchRange: match.range)
                    threats.append(Threat(kind: kind, pattern: pattern, excerpt: excerpt))
                }
            }
        }

        if includeToolPatterns {
            for pattern in Self.toolOnlyPatterns {
                guard let regex = try? Regex(pattern).ignoresCase() else { continue }
                if let match = text.firstMatch(of: regex) {
                    let excerpt = extractExcerpt(from: text, matchRange: match.range)
                    threats.append(Threat(kind: .instructionInjection, pattern: pattern, excerpt: excerpt))
                }
            }
        }

        return threats
    }

    /// Extract a short excerpt around the match for diagnostic logging.
    ///
    /// Returns up to 80 characters centered on the match, with ellipsis if truncated.
    ///
    /// - Parameters:
    ///   - text: The full text that was scanned.
    ///   - matchRange: The range of the regex match within the text.
    /// - Returns: A short excerpt string.
    private func extractExcerpt(from text: String, matchRange: Range<String.Index>) -> String {
        let contextRadius = 40

        let startDistance = text.distance(from: text.startIndex, to: matchRange.lowerBound)
        let endDistance = text.distance(from: text.startIndex, to: matchRange.upperBound)

        let excerptStart = max(0, startDistance - contextRadius)
        let excerptEnd = min(text.count, endDistance + contextRadius)

        let startIdx = text.index(text.startIndex, offsetBy: excerptStart)
        let endIdx = text.index(text.startIndex, offsetBy: excerptEnd)

        var excerpt = String(text[startIdx ..< endIdx])

        if excerptStart > 0 {
            excerpt = "..." + excerpt
        }
        if excerptEnd < text.count {
            excerpt = excerpt + "..."
        }

        return excerpt
    }
}
