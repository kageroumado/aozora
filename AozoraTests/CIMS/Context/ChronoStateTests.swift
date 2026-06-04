import Foundation
import Testing
@testable import Aozora

@Suite("ChronoState")
struct ChronoStateTests {
    // MARK: - Temporal Mode Computation

    @Test("New session when lastInteractionAt is nil")
    func newSession() {
        let state = ChronoState()
        #expect(state.temporalMode() == .newSession)
    }

    @Test("Continuation for gap < 1 hour")
    func continuation() {
        let now = Date()
        let thirtyMinutesAgo = now.addingTimeInterval(-30 * 60)
        let state = ChronoState(lastInteractionAt: thirtyMinutesAgo)
        #expect(state.temporalMode(at: now) == .continuation)
    }

    @Test("Soft reconnection for gap 1-24 hours")
    func softReconnection() {
        let now = Date()
        let sixHoursAgo = now.addingTimeInterval(-6 * 3_600)
        let state = ChronoState(lastInteractionAt: sixHoursAgo)
        #expect(state.temporalMode(at: now) == .softReconnection)
    }

    @Test("Reconnection for gap 1-7 days")
    func reconnection() {
        let now = Date()
        let threeDaysAgo = now.addingTimeInterval(-3 * 86_400)
        let state = ChronoState(lastInteractionAt: threeDaysAgo)
        #expect(state.temporalMode(at: now) == .reconnection)
    }

    @Test("Reunion for gap > 7 days")
    func reunion() {
        let now = Date()
        let tenDaysAgo = now.addingTimeInterval(-10 * 86_400)
        let state = ChronoState(lastInteractionAt: tenDaysAgo)
        #expect(state.temporalMode(at: now) == .reunion)
    }

    // MARK: - Boundary Cases

    @Test("Exactly 1 hour is soft reconnection, not continuation")
    func boundaryOneHour() {
        #expect(ChronoState.mode(forGapSeconds: 3_600) == .softReconnection)
    }

    @Test("Just under 1 hour is continuation")
    func boundaryJustUnderOneHour() {
        #expect(ChronoState.mode(forGapSeconds: 3_599) == .continuation)
    }

    @Test("Exactly 24 hours is reconnection")
    func boundaryTwentyFourHours() {
        #expect(ChronoState.mode(forGapSeconds: 86_400) == .reconnection)
    }

    @Test("Exactly 7 days is reunion")
    func boundarySevenDays() {
        #expect(ChronoState.mode(forGapSeconds: 604_800) == .reunion)
    }

    // MARK: - Gap Duration

    @Test("Gap duration returns nil for new session")
    func gapDurationNil() {
        let state = ChronoState()
        #expect(state.gapDuration() == nil)
    }

    @Test("Gap duration computes correctly")
    func gapDurationComputed() throws {
        let now = Date()
        let twoHoursAgo = now.addingTimeInterval(-7_200)
        let state = ChronoState(lastInteractionAt: twoHoursAgo)
        let gap = state.gapDuration(at: now)
        #expect(gap != nil)
        #expect(try abs(#require(gap) - 7_200) < 1)
    }

    // MARK: - Session Management

    @Test("Begin session increments count and sets start time")
    func beginSession() {
        var state = ChronoState(sessionCount: 5)
        let now = Date()
        state.beginSession(at: now)
        #expect(state.sessionCount == 6)
        #expect(state.sessionStartedAt == now)
    }

    @Test("Record interaction updates lastInteractionAt")
    func recordInteraction() {
        var state = ChronoState()
        let now = Date()
        state.recordInteraction(at: now)
        #expect(state.lastInteractionAt == now)
    }

    // MARK: - Context Cooling

    @Test("Refresh topic sets staleness to zero")
    func refreshTopic() {
        var state = ChronoState(contextCooling: ["swift": 0.8])
        state.refreshTopic("swift")
        #expect(state.staleness(of: "swift") == 0)
    }

    @Test("Unknown topic has zero staleness")
    func unknownTopicStaleness() {
        let state = ChronoState()
        #expect(state.staleness(of: "nonexistent") == 0)
    }

    @Test("Apply cooling increases staleness toward 1.0")
    func applyCoolingStalenessIncreases() {
        var state = ChronoState(contextCooling: ["swift": 0.0])
        state.applyCooling(elapsed: 86_400)
        let staleness = state.staleness(of: "swift")
        #expect(staleness > 0)
        #expect(staleness <= 1.0)
    }

    @Test("Apply cooling with zero elapsed does nothing")
    func applyCoolingZeroElapsed() {
        var state = ChronoState(contextCooling: ["swift": 0.3])
        state.applyCooling(elapsed: 0)
        #expect(state.staleness(of: "swift") == 0.3)
    }

    @Test("Cooling after 24 hours produces approximately 0.5 staleness from fresh")
    func coolingHalfLife() {
        var state = ChronoState(contextCooling: ["topic": 0.0])
        state.applyCooling(elapsed: 86_400)
        let staleness = state.staleness(of: "topic")
        #expect(abs(staleness - 0.5) < 0.05)
    }

    // MARK: - Rendering

    @Test("Render produces expected format for new session")
    func renderNewSession() {
        let state = ChronoState(sessionCount: 0)
        let rendered = state.render()
        #expect(rendered.contains("first interaction"))
        #expect(rendered.contains("newSession"))
        #expect(rendered.contains("Sessions total: 0"))
    }

    @Test("Render includes session duration when started")
    func renderWithSession() {
        let now = Date()
        let thirtyMinutesAgo = now.addingTimeInterval(-1_800)
        let twoHoursAgo = now.addingTimeInterval(-7_200)
        let state = ChronoState(
            lastInteractionAt: twoHoursAgo,
            sessionStartedAt: thirtyMinutesAgo,
            sessionCount: 5,
        )
        let rendered = state.render(at: now)
        #expect(rendered.contains("30 min"))
        #expect(rendered.contains("softReconnection"))
        #expect(rendered.contains("Sessions total: 5"))
    }

    // MARK: - Gap Formatting

    @Test("Format gap under 1 minute")
    func formatGapUnderMinute() {
        #expect(ChronoState.formatGap(30) == "<1 min")
    }

    @Test("Format gap in minutes")
    func formatGapMinutes() {
        #expect(ChronoState.formatGap(300) == "5 min")
    }

    @Test("Format gap in hours (singular)")
    func formatGapOneHour() {
        #expect(ChronoState.formatGap(3_600) == "1 hour")
    }

    @Test("Format gap in hours (plural)")
    func formatGapHours() {
        #expect(ChronoState.formatGap(7_200) == "2 hours")
    }

    @Test("Format gap in days")
    func formatGapDays() {
        #expect(ChronoState.formatGap(172_800) == "2 days")
    }
}
