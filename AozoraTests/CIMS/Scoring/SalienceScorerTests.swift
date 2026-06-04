import Foundation
import Testing
@testable import Aozora

@Suite("SalienceScorer")
struct SalienceScorerTests {
    private let scorer = SalienceScorer()

    // MARK: - Test Helpers

    private func makeMessage(_ text: String) -> InboundMessage {
        InboundMessage(
            text: text,
            parts: [MessagePart(kind: .text, ordinal: 0, content: text, metadata: nil)],
            metadata: nil,
        )
    }

    private func makeIdentityClaim(
        key: String,
        value: String,
        confidence: Float = 0.8,
    ) -> IdentityClaim {
        IdentityClaim(
            id: 1,
            claimKey: key,
            value: value,
            confidence: confidence,
            epistemicStatus: .asserted,
            evidenceCount: 3,
            evidenceDiversity: 3,
            decayHalfLifeDays: 90,
            createdAt: Date(),
            lastReinforcedAt: Date(),
        )
    }

    private func makeMirrorClaim(
        key: String,
        value: String,
        confidence: Float = 0.8,
    ) -> MirrorClaim {
        MirrorClaim(
            id: 1,
            claimKey: key,
            value: value,
            confidence: confidence,
            epistemicStatus: .asserted,
            evidenceCount: 3,
            evidenceDiversity: 3,
            decayHalfLifeDays: 60,
            createdAt: Date(),
            lastReinforcedAt: Date(),
        )
    }

    private func makeIdentity(claims: [IdentityClaim] = []) -> IdentityBlock {
        IdentityBlock(
            versionId: 1,
            claims: claims,
            createdAt: Date(),
            createdBy: "test",
        )
    }

    private func makeMirror(claims: [MirrorClaim] = []) -> MirrorBlock {
        MirrorBlock(
            versionId: 1,
            userKey: "test_user",
            claims: claims,
            createdAt: Date(),
            createdBy: "test",
        )
    }

    // MARK: - Urgency Signal

    @Test
    func `Urgency: detects explicit urgency keywords`() {
        let message = makeMessage("This is important, please remember this")
        let envelope = scorer.score(message, identity: .empty, mirror: .empty(for: "u"))
        #expect(envelope.urgency > 0)
    }

    @Test
    func `Urgency: detects emotional language`() {
        let message = makeMessage("I am so frustrated with this approach")
        let envelope = scorer.score(message, identity: .empty, mirror: .empty(for: "u"))
        #expect(envelope.urgency > 0)
    }

    @Test
    func `Urgency: detects questions`() {
        let message = makeMessage("How can I fix this problem?")
        let envelope = scorer.score(message, identity: .empty, mirror: .empty(for: "u"))
        #expect(envelope.urgency > 0)
    }

    @Test
    func `Urgency: all three categories yields maximum urgency`() {
        let message = makeMessage("This is critical! I'm so frustrated. How do I fix it?")
        let envelope = scorer.score(message, identity: .empty, mirror: .empty(for: "u"))
        #expect(envelope.urgency == 1.0)
    }

    @Test
    func `Urgency: neutral message scores zero`() {
        let message = makeMessage("The weather is nice today")
        let envelope = scorer.score(message, identity: .empty, mirror: .empty(for: "u"))
        #expect(envelope.urgency == 0)
    }

    // MARK: - Identity Relevance Signal

    @Test
    func `Identity relevance: matches claim key overlap`() {
        let claims = [makeIdentityClaim(key: "self.communication_style", value: "direct and concise")]
        let identity = makeIdentity(claims: claims)
        let message = makeMessage("I prefer a direct communication style")
        let envelope = scorer.score(message, identity: identity, mirror: .empty(for: "u"))
        #expect(envelope.identityRelevance > 0)
    }

    @Test
    func `Identity relevance: matches claim value overlap`() {
        let claims = [makeIdentityClaim(key: "self.values", value: "depth over safety")]
        let identity = makeIdentity(claims: claims)
        let message = makeMessage("I value depth in our conversations")
        let envelope = scorer.score(message, identity: identity, mirror: .empty(for: "u"))
        #expect(envelope.identityRelevance > 0)
    }

    @Test
    func `Identity relevance: empty identity yields zero`() {
        let message = makeMessage("Some text about anything")
        let envelope = scorer.score(message, identity: .empty, mirror: .empty(for: "u"))
        #expect(envelope.identityRelevance == 0)
    }

    @Test
    func `Identity relevance: no overlap yields zero`() {
        let claims = [makeIdentityClaim(key: "self.zodiac", value: "aquarius")]
        let identity = makeIdentity(claims: claims)
        let message = makeMessage("The browser needs more features")
        let envelope = scorer.score(message, identity: identity, mirror: .empty(for: "u"))
        #expect(envelope.identityRelevance == 0)
    }

    // MARK: - Mirror Relevance Signal

    @Test
    func `Mirror relevance: matches mirror claim overlap`() {
        let claims = [makeMirrorClaim(key: "mirror.alice.expertise", value: "Swift and Apple development")]
        let mirror = makeMirror(claims: claims)
        let message = makeMessage("Let's work on the Swift implementation")
        let envelope = scorer.score(message, identity: .empty, mirror: mirror)
        #expect(envelope.mirrorRelevance > 0)
    }

    @Test
    func `Mirror relevance: empty mirror yields zero`() {
        let message = makeMessage("Some text about anything")
        let envelope = scorer.score(message, identity: .empty, mirror: .empty(for: "u"))
        #expect(envelope.mirrorRelevance == 0)
    }

    // MARK: - Temporal Recency Signal

    @Test
    func `Temporal recency is always 0.5 at scoring time`() {
        let message = makeMessage("Anything at all")
        let envelope = scorer.score(message, identity: .empty, mirror: .empty(for: "u"))
        #expect(envelope.temporalRecency == 0.5)
    }

    // MARK: - Composite Score

    @Test
    func `Composite is weighted sum of signals`() {
        let identityClaims = [makeIdentityClaim(key: "self.style", value: "depth over safety")]
        let identity = makeIdentity(claims: identityClaims)
        let mirrorClaims = [makeMirrorClaim(key: "mirror.user.expertise", value: "Swift development")]
        let mirror = makeMirror(claims: mirrorClaims)

        let message = makeMessage("This is important! I value depth in Swift development. How can we improve?")
        let envelope = scorer.score(message, identity: identity, mirror: mirror)

        let expected =
            envelope.urgency * CIMSDefaults.salienceUrgencyWeight
                + envelope.identityRelevance * CIMSDefaults.salienceIdentityWeight
                + envelope.mirrorRelevance * CIMSDefaults.salienceMirrorWeight
                + envelope.temporalRecency * CIMSDefaults.salienceRecencyWeight

        #expect(abs(envelope.composite - expected) < 0.001)
    }

    @Test
    func `Composite is bounded to 0-1`() {
        let message = makeMessage("This is urgent and critical! I'm so excited. How do I fix this?")
        let envelope = scorer.score(message, identity: .empty, mirror: .empty(for: "u"))
        #expect(envelope.composite >= 0 && envelope.composite <= 1)
    }

    @Test
    func `Default envelope has 0.5 for all signals`() {
        let d = SalienceEnvelope.default
        #expect(d.urgency == 0.5)
        #expect(d.identityRelevance == 0.5)
        #expect(d.mirrorRelevance == 0.5)
        #expect(d.temporalRecency == 0.5)
        #expect(d.composite == 0.5)
    }
}
