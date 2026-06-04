import Foundation

/// Temporal freshness annotation for epistemic claims.
///
/// Computes human-readable staleness markers based on time since last reinforcement.
/// Thresholds are derived from the existing Hebbian decay half-lives configured in
/// `CIMSDefaults`, ensuring that annotation boundaries correspond to actual confidence
/// decay levels:
///
/// - **Fresh** (< half-life × 0.1): Confidence > ~93%. No annotation.
/// - **Aging** (< half-life × 0.5): Confidence > ~71%. Mild note.
/// - **Stale** (< half-life × 1.0): Confidence > ~50%. Warning marker.
/// - **Ancient** (> half-life × 1.0): Confidence < 50%. Strong warning.
///
/// For identity claims (half-life = 90 days): fresh < 9d, aging < 45d, stale < 90d.
/// For mirror claims (half-life = 60 days): fresh < 6d, aging < 30d, stale < 60d.
///
/// Zero LLM cost — pure timestamp arithmetic injected at context assembly time.
public enum ClaimStaleness {
    static let freshFraction: Double = 0.1
    static let agingFraction: Double = 0.5
    static let staleFraction: Double = 1.0

    /// Generate a staleness annotation, or nil if the claim is fresh.
    ///
    /// - Parameters:
    ///   - lastReinforced: When the claim was last confirmed by evidence.
    ///   - halfLifeDays: The Hebbian decay half-life for this claim type.
    ///   - now: Current time (injectable for testing).
    /// - Returns: A staleness annotation string, or nil if the claim is fresh.
    public static func annotate(lastReinforced: Date, halfLifeDays: Int, now: Date = Date()) -> String? {
        let age = now.timeIntervalSince(lastReinforced)
        let halfLife = Double(halfLifeDays) * 86_400

        let freshThreshold = halfLife * freshFraction
        let agingThreshold = halfLife * agingFraction
        let staleThreshold = halfLife * staleFraction

        if age < freshThreshold { return nil }

        let description = formatAge(age)

        if age < agingThreshold {
            return "(last confirmed: \(description))"
        } else if age < staleThreshold {
            return "⚠ (last confirmed: \(description) — may be outdated)"
        } else {
            return "⚠ (unconfirmed for \(description) — verify before relying on this)"
        }
    }

    /// Format a time interval as a human-readable age string.
    private static func formatAge(_ seconds: TimeInterval) -> String {
        let days = Int(seconds / 86_400)
        if days < 14 { return "~\(days) days ago" }
        let weeks = days / 7
        if weeks < 8 { return "~\(weeks) weeks ago" }
        let months = days / 30
        return "~\(months) months ago"
    }
}
