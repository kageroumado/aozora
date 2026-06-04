import Foundation

/// Static pricing catalog for known LLM models.
///
/// `ModelCatalog` provides prefix-based pricing lookups across major providers
/// (Anthropic, OpenAI, Google, DeepSeek). Pricing is denominated in USD per million
/// tokens. The catalog uses longest-prefix matching so versioned model names
/// (e.g., `claude-opus-4-6-20250514`) correctly resolve to their family pricing.
///
/// Model names may include a `provider/` prefix (e.g., `anthropic/claude-opus-4-6`),
/// which is stripped before matching.
///
/// Unknown models return a zero-cost ``Pricing`` with `isKnown == false` rather than
/// throwing, so cost estimates degrade gracefully when new models are deployed.
public enum ModelCatalog {
    /// Pricing metadata for a single model or model family.
    public struct Pricing: Sendable {
        /// Cost per million input tokens, in USD.
        public let inputPerMillion: Double

        /// Cost per million output tokens, in USD.
        public let outputPerMillion: Double

        /// Cost per million cache-read tokens, in USD.
        public let cacheReadPerMillion: Double

        /// Whether this model was found in the catalog (`false` means zero-cost fallback).
        public let isKnown: Bool
    }

    // MARK: - Internal Catalog

    /// Catalog entries as (prefix, pricing) pairs.
    ///
    /// Ordering within each provider is from most-specific to least-specific.
    /// ``pricing(for:)`` finds the *longest* matching prefix, so more specific
    /// entries shadow broader family entries.
    private static let catalog: [(prefix: String, pricing: Pricing)] = [
        // Anthropic — Claude 4.x
        ("claude-opus-4-6", Pricing(inputPerMillion: 15.0, outputPerMillion: 75.0, cacheReadPerMillion: 1.5, isKnown: true)),
        ("claude-opus-4-", Pricing(inputPerMillion: 15.0, outputPerMillion: 75.0, cacheReadPerMillion: 1.5, isKnown: true)),
        ("claude-sonnet-4-6", Pricing(inputPerMillion: 3.0, outputPerMillion: 15.0, cacheReadPerMillion: 0.3, isKnown: true)),
        ("claude-sonnet-4-", Pricing(inputPerMillion: 3.0, outputPerMillion: 15.0, cacheReadPerMillion: 0.3, isKnown: true)),
        ("claude-haiku-4-5", Pricing(inputPerMillion: 0.8, outputPerMillion: 4.0, cacheReadPerMillion: 0.08, isKnown: true)),
        // Anthropic — Claude 3.5.x
        ("claude-3-5-sonnet", Pricing(inputPerMillion: 3.0, outputPerMillion: 15.0, cacheReadPerMillion: 0.3, isKnown: true)),
        ("claude-3-5-haiku", Pricing(inputPerMillion: 0.8, outputPerMillion: 4.0, cacheReadPerMillion: 0.08, isKnown: true)),
        // OpenAI
        ("gpt-5", Pricing(inputPerMillion: 10.0, outputPerMillion: 30.0, cacheReadPerMillion: 2.5, isKnown: true)),
        ("gpt-4o-mini", Pricing(inputPerMillion: 0.15, outputPerMillion: 0.60, cacheReadPerMillion: 0.075, isKnown: true)),
        ("gpt-4o", Pricing(inputPerMillion: 2.50, outputPerMillion: 10.0, cacheReadPerMillion: 1.25, isKnown: true)),
        ("o3-mini", Pricing(inputPerMillion: 1.10, outputPerMillion: 4.40, cacheReadPerMillion: 0.55, isKnown: true)),
        ("o3", Pricing(inputPerMillion: 10.0, outputPerMillion: 40.0, cacheReadPerMillion: 2.5, isKnown: true)),
        // Google
        ("gemini-2.5-pro", Pricing(inputPerMillion: 1.25, outputPerMillion: 10.0, cacheReadPerMillion: 0.315, isKnown: true)),
        ("gemini-2.5-flash", Pricing(inputPerMillion: 0.15, outputPerMillion: 0.60, cacheReadPerMillion: 0.0375, isKnown: true)),
        // DeepSeek
        ("deepseek-chat", Pricing(inputPerMillion: 0.14, outputPerMillion: 0.28, cacheReadPerMillion: 0.014, isKnown: true)),
        ("deepseek-reasoner", Pricing(inputPerMillion: 0.55, outputPerMillion: 2.19, cacheReadPerMillion: 0.14, isKnown: true)),
    ]

    /// Zero-cost fallback returned for unknown models.
    private static let unknownPricing = Pricing(
        inputPerMillion: 0.0,
        outputPerMillion: 0.0,
        cacheReadPerMillion: 0.0,
        isKnown: false,
    )

    // MARK: - Public API

    /// Look up pricing for a model name, using longest-prefix matching.
    ///
    /// The `model` string may contain a `provider/` prefix (e.g., `anthropic/claude-opus-4-6-20250514`),
    /// which is stripped before matching. Matching is case-sensitive and finds the longest
    /// catalog prefix that is a prefix of the (stripped) model name.
    ///
    /// - Parameter model: The model identifier to look up.
    /// - Returns: The matching ``Pricing``, or a zero-cost entry with `isKnown == false`.
    public static func pricing(for model: String) -> Pricing {
        let name = stripProviderPrefix(from: model)

        return catalog
            .filter { name.hasPrefix($0.prefix) }
            .max(by: { $0.prefix.count < $1.prefix.count })?
            .pricing ?? unknownPricing
    }

    /// Estimate the USD cost of a single inference call.
    ///
    /// Uses the formula:
    /// ```
    /// cost = ((inputTokens - cachedTokens) * inputPerMillion
    ///       + outputTokens * outputPerMillion
    ///       + cachedTokens * cacheReadPerMillion) / 1_000_000
    /// ```
    ///
    /// - Parameters:
    ///   - model: The model identifier.
    ///   - inputTokens: Total input tokens (including any cached portion).
    ///   - outputTokens: Output tokens generated.
    ///   - cachedTokens: Input tokens served from the prompt cache (default: 0).
    /// - Returns: Estimated cost in USD.
    public static func estimateCost(
        model: String,
        inputTokens: Int,
        outputTokens: Int,
        cachedTokens: Int = 0,
    ) -> Double {
        let p = pricing(for: model)
        let nonCachedInput = max(0, inputTokens - cachedTokens)
        return (
            Double(nonCachedInput) * p.inputPerMillion
                + Double(outputTokens) * p.outputPerMillion
                + Double(cachedTokens) * p.cacheReadPerMillion,
        ) / 1_000_000
    }

    // MARK: - Helpers

    /// Strip a `provider/` prefix from a model name if present.
    ///
    /// For example, `"anthropic/claude-opus-4-6"` becomes `"claude-opus-4-6"`.
    ///
    /// - Parameter model: The raw model string.
    /// - Returns: The model name without the provider prefix.
    private static func stripProviderPrefix(from model: String) -> String {
        guard let slash = model.firstIndex(of: "/") else { return model }
        return String(model[model.index(after: slash)...])
    }
}
