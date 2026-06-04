import Foundation

/// Scores inbound messages on identity/mirror relevance, urgency, and temporal signals.
///
/// The scorer is a pure function with no side effects or I/O. It produces a ``SalienceEnvelope``
/// that additively boosts retrieval ranking — a bad score degrades ranking slightly but never
/// blocks access to relevant memory.
///
/// Owned by ``CIMSCoordinator`` as a struct (no actor isolation of its own).
public nonisolated struct SalienceScorer: Sendable {
    // MARK: - Urgency Patterns

    /// Explicit urgency markers — words/phrases that signal the message is important.
    private static let urgencyKeywords: [String] = [
        "important", "urgent", "critical", "remember this", "don't forget",
        "do not forget", "please note", "asap", "immediately", "priority",
        "emergency", "crucial", "vital", "essential",
    ]

    /// Emotional intensity markers — suggest heightened significance.
    private static let emotionalKeywords: [String] = [
        "frustrated", "annoyed", "angry", "excited", "thrilled", "worried",
        "anxious", "confused", "struggling", "love", "hate", "amazing",
        "terrible", "wonderful", "awful",
    ]

    /// Question markers — questions often carry implicit urgency (the user wants an answer).
    private static let questionMarkers: [String] = [
        "?", "how do", "how can", "what is", "what are", "why does",
        "why is", "can you", "could you", "would you", "should i",
        "do you know", "is there",
    ]

    // MARK: - Scoring

    /// Score an inbound message against the current identity and mirror blocks.
    ///
    /// Each signal is scored independently (0-1), then combined via weighted sum using
    /// weights from ``CIMSDefaults``. Temporal recency is always 0.5 at scoring time;
    /// real recency is computed during retrieval.
    ///
    /// - Parameters:
    ///   - message: The inbound message to score.
    ///   - identity: The current identity block for relevance matching.
    ///   - mirror: The current mirror block for relevance matching.
    /// - Returns: A salience envelope with per-signal and composite scores.
    public func score(
        _ message: InboundMessage,
        identity: IdentityBlock,
        mirror: MirrorBlock,
    ) -> SalienceEnvelope {
        let text = message.text
        let lowered = text.lowercased()

        let urgency = scoreUrgency(lowered)
        let identityRelevance = scoreIdentityRelevance(lowered, identity: identity)
        let mirrorRelevance = scoreMirrorRelevance(lowered, mirror: mirror)
        let temporalRecency: Float = 0.5

        let composite = clamp01(
            urgency * CIMSDefaults.salienceUrgencyWeight
                + identityRelevance * CIMSDefaults.salienceIdentityWeight
                + mirrorRelevance * CIMSDefaults.salienceMirrorWeight
                + temporalRecency * CIMSDefaults.salienceRecencyWeight,
        )

        return SalienceEnvelope(
            urgency: urgency,
            identityRelevance: identityRelevance,
            mirrorRelevance: mirrorRelevance,
            temporalRecency: temporalRecency,
            composite: composite,
        )
    }

    // MARK: - Signal Scoring

    /// Score urgency from explicit markers, emotional language, and question patterns.
    ///
    /// The score is the proportion of matched pattern categories (urgency keywords,
    /// emotional keywords, question markers), so a message hitting all three categories
    /// scores 1.0.
    ///
    /// - Parameter lowered: The lowercased message text.
    /// - Returns: Urgency signal in 0-1.
    private func scoreUrgency(_ lowered: String) -> Float {
        var signals: Float = 0
        let totalCategories: Float = 3

        if Self.urgencyKeywords.contains(where: { lowered.contains($0) }) {
            signals += 1
        }

        if Self.emotionalKeywords.contains(where: { lowered.contains($0) }) {
            signals += 1
        }

        if Self.questionMarkers.contains(where: { lowered.contains($0) }) {
            signals += 1
        }

        return clamp01(signals / totalCategories)
    }

    /// Score identity relevance by checking overlap between message text and claim keys/values.
    ///
    /// Tokenizes the message into words and checks how many identity claim keys or values
    /// contain at least one matching word. The score is the proportion of claims that match,
    /// capped at 1.0.
    ///
    /// - Parameters:
    ///   - lowered: The lowercased message text.
    ///   - identity: The identity block to match against.
    /// - Returns: Identity relevance signal in 0-1.
    private func scoreIdentityRelevance(_ lowered: String, identity: IdentityBlock) -> Float {
        guard !identity.claims.isEmpty else { return 0 }
        let words = tokenize(lowered)
        guard !words.isEmpty else { return 0 }

        var matchCount = 0
        for claim in identity.claims {
            let keyWords = tokenize(claim.claimKey.lowercased())
            let valueWords = tokenize(claim.value.lowercased())
            let claimWords = Set(keyWords).union(valueWords)
            if !words.isDisjoint(with: claimWords) {
                matchCount += 1
            }
        }

        return clamp01(Float(matchCount) / Float(identity.claims.count))
    }

    /// Score mirror relevance by checking overlap between message text and mirror claim keys/values.
    ///
    /// Uses the same word-overlap strategy as identity relevance scoring.
    ///
    /// - Parameters:
    ///   - lowered: The lowercased message text.
    ///   - mirror: The mirror block to match against.
    /// - Returns: Mirror relevance signal in 0-1.
    private func scoreMirrorRelevance(_ lowered: String, mirror: MirrorBlock) -> Float {
        guard !mirror.claims.isEmpty else { return 0 }
        let words = tokenize(lowered)
        guard !words.isEmpty else { return 0 }

        var matchCount = 0
        for claim in mirror.claims {
            let keyWords = tokenize(claim.claimKey.lowercased())
            let valueWords = tokenize(claim.value.lowercased())
            let claimWords = Set(keyWords).union(valueWords)
            if !words.isDisjoint(with: claimWords) {
                matchCount += 1
            }
        }

        return clamp01(Float(matchCount) / Float(mirror.claims.count))
    }

    // MARK: - Utilities

    /// Tokenize text into a set of lowercase words, stripping punctuation and short noise words.
    private func tokenize(_ text: String) -> Set<String> {
        let separators = CharacterSet.alphanumerics.inverted
        let words = text.components(separatedBy: separators)
            .map { $0.lowercased() }
            .filter { $0.count >= 3 }
        return Set(words)
    }

    /// Clamp a float to the 0-1 range.
    private func clamp01(_ value: Float) -> Float {
        min(max(value, 0), 1)
    }
}
