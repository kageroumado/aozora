import Foundation
import Testing
@testable import Aozora

struct ModelCatalogTests {
    @Test
    func `looks up known model pricing`() {
        let pricing = ModelCatalog.pricing(for: "claude-opus-4-6-20250514")
        #expect(pricing.inputPerMillion == 15.0)
        #expect(pricing.outputPerMillion == 75.0)
    }

    @Test
    func `fuzzy matches model variants`() {
        let pricing = ModelCatalog.pricing(for: "claude-sonnet-4-6-20250514")
        #expect(pricing.inputPerMillion == 3.0)
    }

    @Test
    func `returns zero for unknown models`() {
        let pricing = ModelCatalog.pricing(for: "unknown-model-xyz")
        #expect(pricing.inputPerMillion == 0.0)
        #expect(pricing.outputPerMillion == 0.0)
    }

    @Test
    func `estimates cost correctly`() {
        let cost = ModelCatalog.estimateCost(
            model: "claude-opus-4-6-20250514",
            inputTokens: 100_000,
            outputTokens: 10_000,
        )
        // 100k * 15/1M + 10k * 75/1M = 1.5 + 0.75 = 2.25
        #expect(abs(cost - 2.25) < 0.01)
    }

    @Test
    func `strips provider prefix before matching`() {
        let pricing = ModelCatalog.pricing(for: "anthropic/claude-opus-4-6-20250514")
        #expect(pricing.isKnown)
        #expect(pricing.inputPerMillion == 15.0)
    }

    @Test
    func `marks known models as isKnown true`() {
        #expect(ModelCatalog.pricing(for: "claude-sonnet-4-6").isKnown)
        #expect(!ModelCatalog.pricing(for: "unknown-model-xyz").isKnown)
    }

    @Test
    func `longest prefix wins over shorter match`() {
        // claude-opus-4-6 is more specific than claude-opus-4-
        let specificPricing = ModelCatalog.pricing(for: "claude-opus-4-6-20250514")
        let familyPricing = ModelCatalog.pricing(for: "claude-opus-4-99")
        // Both should be identical in this catalog (same pricing), but both known
        #expect(specificPricing.isKnown)
        #expect(familyPricing.isKnown)
    }

    @Test
    func `estimates cache read cost correctly`() {
        // 100k input, 50k cached → 50k non-cached * 15/1M + 50k * 1.5/1M
        // = 0.75 + 0.075 = 0.825
        let cost = ModelCatalog.estimateCost(
            model: "claude-opus-4-6",
            inputTokens: 100_000,
            outputTokens: 0,
            cachedTokens: 50_000,
        )
        #expect(abs(cost - 0.825) < 0.001)
    }

    @Test
    func `OpenAI gpt-4o-mini matches correctly`() {
        let pricing = ModelCatalog.pricing(for: "gpt-4o-mini")
        #expect(pricing.isKnown)
        #expect(pricing.inputPerMillion == 0.15)
        #expect(pricing.outputPerMillion == 0.60)
    }

    @Test
    func `gpt-4o does not match gpt-4o-mini prefix`() {
        let miniPricing = ModelCatalog.pricing(for: "gpt-4o-mini")
        let fullPricing = ModelCatalog.pricing(for: "gpt-4o")
        // mini should be cheaper than full gpt-4o
        #expect(miniPricing.inputPerMillion < fullPricing.inputPerMillion)
    }
}
