import Foundation

/// Extracts identity and mirror claims from bump candidates using LLM inference.
///
/// The claim extractor formats a consolidation prompt from bump candidates, calls
/// the model provider at the consolidation tier, and parses the JSON response into
/// a ``ConsolidationProposal``. The model is explicitly told that `nothingSignificant`
/// is a valid and common outcome — most sessions don't produce identity-level insights.
///
/// The extractor never hard-codes LLM calls; all inference goes through ``ModelProviding``.
public nonisolated struct ClaimExtractor: Sendable {
    /// The model provider used for claim extraction inference.
    private let model: any ModelProviding

    /// Creates a claim extractor using the given model provider.
    ///
    /// - Parameter model: The model provider to use for consolidation inference.
    public init(model: any ModelProviding) {
        self.model = model
    }

    /// Extract claims from bump candidates by prompting the consolidation model.
    ///
    /// Formats a structured prompt containing the bump candidates' content and reasons,
    /// sends it to the model at the consolidation tier, and parses the JSON response.
    /// If the model returns `nothingSignificant: true`, returns an empty proposal.
    ///
    /// The prompt explicitly instructs the model that producing no claims is preferable
    /// to producing low-quality ones.
    ///
    /// - Parameter candidates: Bump candidates detected by ``BumpDetector``.
    /// - Returns: A consolidation proposal with identity and mirror claim candidates.
    /// - Throws: ``CIMSError/modelError(_:)`` if the model response can't be parsed.
    public func extractClaims(from candidates: [BumpCandidate]) async throws -> ConsolidationProposal {
        guard !candidates.isEmpty else {
            return ConsolidationProposal(
                identityProposals: [],
                mirrorProposals: [],
                nothingSignificant: true,
                rationale: "No bump candidates to analyze.",
            )
        }

        let prompt = buildPrompt(from: candidates)

        let apiPrompt = PromptBuilder().buildWorkerPrompt(
            systemPrompt: prompt,
            goal: "Extract claims from the bump candidates above.",
            tools: [],
        )

        let response = try await model.complete(apiPrompt, tier: .consolidation)
        return parseResponse(response.content)
    }

    /// Build the consolidation prompt from bump candidates.
    ///
    /// Structures the candidates into a clear format with their content and bump reasons,
    /// and provides JSON schema for the expected response. The prompt includes the full
    /// category guidance from ``buildCategoryGuidance()`` to constrain model output.
    ///
    /// - Parameter candidates: The bump candidates to include in the prompt.
    /// - Returns: The formatted prompt string.
    private func buildPrompt(from candidates: [BumpCandidate]) -> String {
        var sections: [String] = []

        for (index, candidate) in candidates.enumerated() {
            let truncatedContent = String(candidate.content.prefix(2_000))
            sections.append("""
            --- Bump \(index + 1) (reason: \(candidate.reason.rawValue), salience: \(candidate.salienceScore)) ---
            \(truncatedContent)
            """)
        }

        let bumpsText = sections.joined(separator: "\n\n")
        let categoryGuidance = ClaimExtractor.buildCategoryGuidance()

        return """
        You are analyzing conversation excerpts to extract identity insights and user model updates.
        These excerpts were flagged as "reminiscence bumps" — moments where understanding shifted.
        
        IMPORTANT: Most sessions produce nothing significant. It is better to return nothingSignificant: true
        than to produce low-quality or speculative claims. Only extract claims when there is clear evidence.
        
        \(categoryGuidance)
        
        Analyze the following bumps and respond with a JSON object:
        
        {
            "nothingSignificant": true/false,
            "rationale": "Why these changes were proposed (or why nothing was significant)",
            "identityProposals": [
                {
                    "category": "preference",
                    "claimKey": "preference.communication.direct",
                    "value": "Prefers concise responses without trailing summaries",
                    "confidence": 0.85,
                    "evidenceType": "explicit_statement",
                    "excerpt": "stop summarizing what you just did"
                }
            ],
            "mirrorProposals": [
                {
                    "category": "relation",
                    "claimKey": "relation.person.alice",
                    "value": "The observed user trait or preference",
                    "confidence": 0.0-1.0,
                    "evidenceType": "direct_quote|behavior|inference|explicit_statement",
                    "excerpt": "relevant quote from the text"
                }
            ]
        }
        
        \(bumpsText)
        """
    }

    /// Build category guidance text for the extraction prompt.
    ///
    /// Enumerates all claim categories with descriptions and key format examples
    /// to constrain the model's output to the defined taxonomy.
    ///
    /// - Returns: A formatted multi-line string describing all ``ClaimCategory`` cases.
    public static func buildCategoryGuidance() -> String {
        """
        CLAIM CATEGORIES — use these prefixes for claimKey:
        
        identity.*  — Facts about identity: name, role, background, skills
                      Example: identity.role, identity.skill.swift
        preference.* — Preferences, tastes, style choices
                       Example: preference.communication.direct, preference.tool.neovim
        event.*     — Discrete events with dates
                      Example: event.project.aozora-launch, event.life.moved-to-tokyo
        update.*    — Corrections to previous knowledge
                      Example: update.preference.editor (supersedes older claim)
        pattern.*   — Behavioral patterns observed over multiple interactions
                      Example: pattern.work.depth-first, pattern.communication.terse
        relation.*  — Knowledge about people, projects, entities
                      Example: relation.person.alice, relation.project.aozora
        """
    }

    /// Parse the model's response into a ``ConsolidationProposal``.
    ///
    /// Attempts to parse the response as JSON. If parsing fails, falls back to
    /// treating the response as `nothingSignificant`. This ensures the consolidation
    /// pipeline never crashes on malformed model output.
    ///
    /// - Parameter content: The raw model response text.
    /// - Returns: A parsed consolidation proposal.
    private func parseResponse(_ content: String) -> ConsolidationProposal {
        let jsonString = extractJSON(from: content)

        guard let data = jsonString.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else {
            return ConsolidationProposal(
                identityProposals: [],
                mirrorProposals: [],
                nothingSignificant: true,
                rationale: "Failed to parse model response as JSON.",
            )
        }

        let nothingSignificant = json["nothingSignificant"] as? Bool ?? false
        let rationale = json["rationale"] as? String ?? "No rationale provided."

        if nothingSignificant {
            return ConsolidationProposal(
                identityProposals: [],
                mirrorProposals: [],
                nothingSignificant: true,
                rationale: rationale,
            )
        }

        let identityProposals = parseClaimCandidates(from: json["identityProposals"])
        let mirrorProposals = parseClaimCandidates(from: json["mirrorProposals"])

        return ConsolidationProposal(
            identityProposals: identityProposals,
            mirrorProposals: mirrorProposals,
            nothingSignificant: identityProposals.isEmpty && mirrorProposals.isEmpty,
            rationale: rationale,
        )
    }

    /// Extract a JSON object from a response that may contain markdown fences or other wrapping.
    ///
    /// - Parameter content: The raw response text.
    /// - Returns: The extracted JSON string.
    private func extractJSON(from content: String) -> String {
        if let start = content.range(of: "{"),
           let end = content.range(of: "}", options: .backwards) {
            return String(content[start.lowerBound ..< end.upperBound])
        }
        return content
    }

    /// Parse an array of claim candidate dictionaries from a JSON value.
    ///
    /// - Parameter value: The JSON value (expected to be an array of dictionaries).
    /// - Returns: Parsed claim candidates, silently skipping malformed entries.
    private func parseClaimCandidates(from value: Any?) -> [ClaimCandidate] {
        guard let array = value as? [[String: Any]] else { return [] }

        return array.compactMap { dict in
            guard let claimKey = dict["claimKey"] as? String,
                  let claimValue = dict["value"] as? String
            else { return nil }

            let confidence = (dict["confidence"] as? Double).map { Float($0) } ?? 0.5
            let evidenceTypeString = dict["evidenceType"] as? String ?? "inference"
            let evidenceType = EvidenceType(rawValue: evidenceTypeString) ?? .inference
            let excerpt = dict["excerpt"] as? String

            return ClaimCandidate(
                claimKey: claimKey,
                value: claimValue,
                confidence: confidence,
                evidenceType: evidenceType,
                excerpt: excerpt,
                nodeId: nil,
            )
        }
    }
}
