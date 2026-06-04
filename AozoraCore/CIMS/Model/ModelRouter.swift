import Foundation
import os

/// Classifies incoming messages to determine which model tier should handle them.
///
/// The router is conservative: any ambiguity routes to the executive tier. Only clearly
/// simple messages (short, conversational, no code/technical markers) are routed to
/// cheaper worker tiers. System-initiated turns (cron, heartbeat) use the lightest tier.
///
/// Classification signals:
/// - **Length**: Messages over 200 characters → executive
/// - **Code markers**: Triple backticks, file paths, code keywords → executive
/// - **Technical keywords**: debug, refactor, implement, fix, deploy → executive
/// - **Thinking requests**: "think", "analyze", "reason" → executive
/// - **Image attachments**: Always executive (vision models)
/// - **System user**: Cron/heartbeat → workerLight (cheapest)
/// - **Default short**: Short conversational messages → workerDefault
public struct ModelRouter: Sendable {
    /// The routing decision with reasoning for observability.
    public struct Decision: Sendable {
        /// The recommended model tier.
        public let tier: ModelTier

        /// Human-readable reason for the routing decision.
        public let reason: String
    }

    private static let logger = Logger(subsystem: "ai.aozora", category: "model-router")

    /// Classify a turn request to determine the appropriate model tier.
    ///
    /// - Parameter request: The incoming turn request.
    /// - Returns: A ``Decision`` with the recommended tier and reasoning.
    public func classify(_ request: TurnRequest) -> Decision {
        if request.userKey == "system" {
            return Decision(tier: .workerLight, reason: "system-initiated turn")
        }

        return classify(
            text: request.message.text,
            hasImages: !request.message.images.isEmpty,
        )
    }

    /// Classify based on message text and attachment presence.
    ///
    /// Exposed separately for testing without constructing full ``TurnRequest`` values.
    ///
    /// - Parameters:
    ///   - text: The message text.
    ///   - hasImages: Whether the message includes image attachments.
    /// - Returns: A ``Decision`` with the recommended tier and reasoning.
    public func classify(text: String, hasImages: Bool = false) -> Decision {
        if hasImages {
            return Decision(tier: .executive, reason: "image attachment requires vision model")
        }

        if text.isEmpty {
            return Decision(tier: .workerDefault, reason: "empty message")
        }

        if text.count > 200 {
            return Decision(tier: .executive, reason: "long message (\(text.count) chars)")
        }

        if containsCodeMarkers(text) {
            return Decision(tier: .executive, reason: "contains code markers")
        }

        if containsFilePath(text) {
            return Decision(tier: .executive, reason: "contains file path")
        }

        if containsTechnicalKeywords(text) {
            return Decision(tier: .executive, reason: "contains technical keywords")
        }

        if containsThinkingRequest(text) {
            return Decision(tier: .executive, reason: "explicit thinking/analysis request")
        }

        if isAmbiguous(text) {
            return Decision(tier: .executive, reason: "ambiguous request (conservative)")
        }

        return Decision(tier: .workerDefault, reason: "short conversational message")
    }

    /// Route and log the decision.
    ///
    /// - Parameter request: The incoming turn request.
    /// - Returns: The recommended ``ModelTier``.
    public func route(_ request: TurnRequest) -> ModelTier {
        let decision = classify(request)
        Self.logger.info("Routed to \(String(describing: decision.tier)): \(decision.reason)")
        return decision.tier
    }

    // MARK: - Signal Detection

    /// Check for code-related markers: backticks, braces, common syntax.
    private func containsCodeMarkers(_ text: String) -> Bool {
        let markers = [
            "```",
            "func ",
            "class ",
            "struct ",
            "import ",
            "let ",
            "var ",
            "return ",
            "if (",
            "if let",
            "for (",
            "for i in",
            "switch ",
            "guard ",
            "async ",
            "await ",
            "throws",
            "-> ",
            "=>",
            "&&",
            "||",
        ]
        return markers.contains { text.contains($0) }
    }

    /// Check for file system paths.
    private func containsFilePath(_ text: String) -> Bool {
        let patterns = [
            "/Users/",
            "/home/",
            "/tmp/",
            "/var/",
            "/etc/",
            "~/",
            "./",
            "../",
            ".swift",
            ".ts",
            ".js",
            ".py",
            ".rs",
            ".go",
            ".java",
            ".json",
            ".yaml",
            ".yml",
            ".toml",
            ".xml",
        ]
        return patterns.contains { text.contains($0) }
    }

    /// Check for technical/development keywords.
    private func containsTechnicalKeywords(_ text: String) -> Bool {
        let lower = text.lowercased()
        let keywords = [
            "debug",
            "refactor",
            "implement",
            "deploy",
            "migrate",
            "architecture",
            "performance",
            "benchmark",
            "optimize",
            "error",
            "crash",
            "bug",
            "fix",
            "patch",
            "merge",
            "database",
            "schema",
            "migration",
            "api",
            "endpoint",
            "test",
            "coverage",
            "ci/cd",
            "pipeline",
            "docker",
            "security",
            "vulnerability",
            "injection",
            "concurrency",
            "thread",
            "deadlock",
            "race condition",
            "compile",
            "build",
            "linker",
            "symbol",
        ]
        return keywords.contains { lower.contains($0) }
    }

    /// Check for explicit thinking/analysis requests.
    private func containsThinkingRequest(_ text: String) -> Bool {
        let lower = text.lowercased()
        let phrases = [
            "think about",
            "think through",
            "analyze",
            "reason about",
            "carefully",
            "step by step",
            "explain why",
            "deep dive",
            "trade-off",
            "tradeoff",
            "pros and cons",
            "compare",
        ]
        return phrases.contains { lower.contains($0) }
    }

    /// Check for ambiguous requests that should be routed conservatively.
    ///
    /// Messages containing "help", "can you", "could you", "please" with enough
    /// length to suggest a real request (not just a greeting) are treated as
    /// potentially complex.
    private func isAmbiguous(_ text: String) -> Bool {
        let lower = text.lowercased()
        let ambiguousMarkers = [
            "help me",
            "can you",
            "could you",
            "would you",
            "i need",
            "i want",
            "show me",
            "tell me about",
            "how do i",
            "how to",
            "what is",
            "what are",
        ]
        let hasMarker = ambiguousMarkers.contains { lower.contains($0) }
        return hasMarker && text.count > 30
    }
}
