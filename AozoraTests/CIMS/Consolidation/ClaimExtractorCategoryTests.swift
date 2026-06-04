import Testing
@testable import Aozora

struct ClaimExtractorCategoryTests {
    @Test
    func `claimKey prefix maps to category`() {
        #expect(ClaimCategory.from(key: "identity.role") == .identity)
        #expect(ClaimCategory.from(key: "preference.communication.direct") == .preference)
        #expect(ClaimCategory.from(key: "event.project.aozora-launch") == .event)
        #expect(ClaimCategory.from(key: "update.preference.editor") == .update)
        #expect(ClaimCategory.from(key: "pattern.work.depth-first") == .pattern)
        #expect(ClaimCategory.from(key: "relation.person.alice") == .relation)
    }

    @Test
    func `legacy self.* keys map to identity by default`() {
        #expect(ClaimCategory.from(key: "self.values.depth") == .identity)
        #expect(ClaimCategory.from(key: "self.communication_style") == .pattern)
        #expect(ClaimCategory.from(key: "self.preference.editor") == .preference)
        #expect(ClaimCategory.from(key: "self.random.thing") == .identity)
    }

    @Test
    func `legacy mirror.* keys map to relation`() {
        #expect(ClaimCategory.from(key: "mirror.expertise.swift") == .relation)
    }

    @Test
    func `truly unknown prefix returns nil`() {
        #expect(ClaimCategory.from(key: "xyz.unknown") == nil)
    }

    @Test
    func `prompt includes all categories with examples`() {
        let prompt = ClaimExtractor.buildCategoryGuidance()
        for category in ClaimCategory.allCases {
            #expect(prompt.contains(category.rawValue))
        }
    }
}
