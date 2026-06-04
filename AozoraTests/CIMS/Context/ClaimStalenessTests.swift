import Foundation
import Testing
@testable import Aozora

struct ClaimStalenessTests {
    @Test
    func `fresh claim gets no annotation`() {
        let annotation = ClaimStaleness.annotate(
            lastReinforced: Date().addingTimeInterval(-5 * 86_400),
            halfLifeDays: 90,
            now: Date(),
        )
        #expect(annotation == nil)
    }

    @Test
    func `aging claim gets mild annotation`() throws {
        let annotation = ClaimStaleness.annotate(
            lastReinforced: Date().addingTimeInterval(-20 * 86_400),
            halfLifeDays: 90,
            now: Date(),
        )
        #expect(annotation != nil)
        #expect(try #require(annotation?.contains("last confirmed")))
        #expect(try !(#require(annotation?.contains("⚠"))))
    }

    @Test
    func `stale claim gets warning annotation`() throws {
        let annotation = ClaimStaleness.annotate(
            lastReinforced: Date().addingTimeInterval(-60 * 86_400),
            halfLifeDays: 90,
            now: Date(),
        )
        #expect(annotation != nil)
        #expect(try #require(annotation?.contains("⚠")))
        #expect(try #require(annotation?.contains("may be outdated")))
    }

    @Test
    func `ancient claim gets strong warning`() throws {
        let annotation = ClaimStaleness.annotate(
            lastReinforced: Date().addingTimeInterval(-120 * 86_400),
            halfLifeDays: 90,
            now: Date(),
        )
        #expect(annotation != nil)
        #expect(try #require(annotation?.contains("verify")))
    }

    @Test
    func `mirror claims use different half-life`() throws {
        let annotation = ClaimStaleness.annotate(
            lastReinforced: Date().addingTimeInterval(-50 * 86_400),
            halfLifeDays: 60,
            now: Date(),
        )
        #expect(annotation != nil)
        #expect(try #require(annotation?.contains("may be outdated")))
    }

    @Test
    func `formats age correctly`() throws {
        // 5 days
        let a1 = ClaimStaleness.annotate(
            lastReinforced: Date().addingTimeInterval(-12 * 86_400),
            halfLifeDays: 90,
            now: Date(),
        )
        #expect(a1 != nil)
        #expect(try #require(a1?.contains("~12 days ago")))

        // 3 weeks
        let a2 = ClaimStaleness.annotate(
            lastReinforced: Date().addingTimeInterval(-21 * 86_400),
            halfLifeDays: 90,
            now: Date(),
        )
        #expect(a2 != nil)
        #expect(try #require(a2?.contains("~3 weeks ago")))
    }
}
