import Foundation

/// Scans and redacts secrets (API keys, tokens, credentials, private keys) from text.
///
/// Secrets in tool output are dangerous in two ways: they can leak to the LLM context
/// (where they might be echoed in responses) and they can leak to external channels
/// (Discord, IPC) in assistant responses. ``SecretRedactor`` provides defense-in-depth
/// by operating at both boundaries.
///
/// The redactor is a pure function with no side effects or I/O. Each match is replaced
/// with a typed placeholder (`[REDACTED:api_key]`, `[REDACTED:bearer_token]`, etc.)
/// that preserves semantic context while eliminating the secret value.
///
/// **Design:** Patterns are intentionally specific — they match known secret formats
/// with structural prefixes (e.g., `sk-ant-`, `AKIA`, `ghp_`) rather than guessing
/// at arbitrary strings. This minimizes false positives on code that merely *discusses*
/// keys or contains variable names like `apiKey`.
public nonisolated struct SecretRedactor: Sendable {
    // MARK: - Pattern Definitions

    /// A redaction rule: a regex pattern paired with the replacement label.
    private struct Rule {
        let pattern: String
        let label: String
    }

    /// All redaction rules, ordered from most specific to least specific.
    ///
    /// More specific patterns (e.g., `sk-ant-`) come before broader ones (e.g., `sk-`)
    /// so the first match wins with the most precise label.
    private static let rules: [Rule] = [
        // -- API Keys (provider-specific prefixes) --
        Rule(pattern: #"sk-ant-[A-Za-z0-9_-]{20,}"#, label: "api_key"),
        Rule(pattern: #"sk-proj-[A-Za-z0-9_-]{20,}"#, label: "api_key"),
        Rule(pattern: #"sk-[A-Za-z0-9_-]{40,}"#, label: "api_key"),
        Rule(pattern: #"gsk_[A-Za-z0-9_-]{20,}"#, label: "api_key"),
        Rule(pattern: #"xai-[A-Za-z0-9_-]{20,}"#, label: "api_key"),
        Rule(pattern: #"ghp_[A-Za-z0-9]{36,}"#, label: "api_key"),
        Rule(pattern: #"gho_[A-Za-z0-9]{36,}"#, label: "api_key"),
        Rule(pattern: #"github_pat_[A-Za-z0-9_]{20,}"#, label: "api_key"),
        Rule(pattern: #"glpat-[A-Za-z0-9_-]{20,}"#, label: "api_key"),
        Rule(pattern: #"pypi-[A-Za-z0-9_-]{20,}"#, label: "api_key"),
        Rule(pattern: #"xoxb-[A-Za-z0-9-]{20,}"#, label: "api_key"),
        Rule(pattern: #"xoxp-[A-Za-z0-9-]{20,}"#, label: "api_key"),
        Rule(pattern: #"xoxo-[A-Za-z0-9-]{20,}"#, label: "api_key"),

        // -- AWS Access Key --
        Rule(pattern: #"AKIA[0-9A-Z]{16}"#, label: "aws_key"),

        // -- Bearer / Basic auth (match credential only, preserve "Authorization:" prefix) --
        Rule(pattern: #"(?i)Bearer\s+[A-Za-z0-9._~+/=-]{20,}"#, label: "bearer_token"),
        Rule(pattern: #"(?i)Basic\s+[A-Za-z0-9+/=]{8,}"#, label: "basic_auth"),

        // -- Private keys (multiline) --
        Rule(pattern: #"-----BEGIN[A-Z\s]*PRIVATE KEY-----[\s\S]*?-----END[A-Z\s]*PRIVATE KEY-----"#, label: "private_key"),
        // Partial private key header (key may be truncated in tool output)
        Rule(pattern: #"-----BEGIN[A-Z\s]*PRIVATE KEY-----[^\n]*"#, label: "private_key"),

        // -- Connection strings with embedded credentials --
        Rule(pattern: #"(?i)(postgresql|mysql|mongodb|mongodb\+srv|redis|amqp)://[^\s@]+:[^\s@]+@[^\s]+"#, label: "connection_string"),

        // -- Environment variable assignments with secret-like names --
        Rule(pattern: #"(?i)(?:export\s+)?(?:API_KEY|SECRET_KEY|SECRET|ACCESS_TOKEN|AUTH_TOKEN|TOKEN|PASSWORD|PRIVATE_KEY|DATABASE_URL|DB_PASSWORD)=[^\s]+"#, label: "env"),

        // -- JSON fields with secret-like keys --
        Rule(pattern: #"(?i)"(?:api_key|apiKey|secret|secret_key|secretKey|password|token|access_token|auth_token)":\s*"[^"]+""#, label: "json_field"),
    ]

    /// Compiled regex cache — built lazily on first use.
    ///
    /// We compile all patterns once rather than per-call. The `nonisolated(unsafe)` is
    /// safe because the array is written exactly once (in the lazy initializer) and only
    /// read thereafter.
    private nonisolated(unsafe) static var compiledRules: [(Regex<AnyRegexOutput>, String)]?

    /// Returns compiled rules, building the cache on first access.
    private static func getCompiledRules() -> [(Regex<AnyRegexOutput>, String)] {
        if let cached = compiledRules {
            return cached
        }
        let compiled = rules.compactMap { rule -> (Regex<AnyRegexOutput>, String)? in
            guard let regex = try? Regex(rule.pattern) else { return nil }
            return (regex, rule.label)
        }
        compiledRules = compiled
        return compiled
    }

    // MARK: - Public API

    /// Redact all detected secrets in the given text.
    ///
    /// Each secret is replaced with `[REDACTED:<label>]` where `<label>` describes the
    /// secret type (e.g., `api_key`, `bearer_token`, `aws_key`). Non-secret text is
    /// passed through unchanged.
    ///
    /// - Parameter text: The text to scan and redact.
    /// - Returns: The text with all detected secrets replaced by redaction markers.
    public func redact(_ text: String) -> String {
        guard !text.isEmpty else { return text }

        let rules = Self.getCompiledRules()
        var result = text

        for (regex, label) in rules {
            result = result.replacing(regex) { _ in
                "[REDACTED:\(label)]"
            }
        }

        return result
    }

    /// Whether the text contains any detectable secrets.
    ///
    /// Cheaper than ``redact(_:)`` when you only need a yes/no answer —
    /// short-circuits on first match.
    ///
    /// - Parameter text: The text to scan.
    /// - Returns: `true` if at least one secret pattern matches.
    public func containsSecrets(_ text: String) -> Bool {
        guard !text.isEmpty else { return false }

        let rules = Self.getCompiledRules()
        for (regex, _) in rules {
            if text.contains(regex) {
                return true
            }
        }
        return false
    }
}
