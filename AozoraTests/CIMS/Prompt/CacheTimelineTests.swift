import Testing
@testable import Aozora

struct CacheTimelineTests {
    @Test
    func `Fresh timeline is not warm`() {
        let timeline = CacheTimeline()
        #expect(!timeline.isCacheWarm)
        #expect(timeline.timeUntilExpiry == .zero)
    }

    @Test
    func `After recording write, cache is warm`() {
        var timeline = CacheTimeline()
        timeline.recordCacheWrite()
        #expect(timeline.isCacheWarm)
        #expect(timeline.timeUntilExpiry > .seconds(299))
    }

    @Test
    func `timeUntilExpiry decreases over time`() async throws {
        var timeline = CacheTimeline()
        timeline.recordCacheWrite()
        let before = timeline.timeUntilExpiry
        try await Task.sleep(for: .milliseconds(100))
        let after = timeline.timeUntilExpiry
        #expect(after < before)
    }
}
