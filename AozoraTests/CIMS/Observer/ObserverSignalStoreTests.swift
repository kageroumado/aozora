import Foundation
import GRDB
import Testing
@testable import Aozora

@Suite("ObserverSignalStore")
struct ObserverSignalStoreTests {
    /// Create a fresh in-memory database and signal store for each test.
    ///
    /// Also inserts a plate snapshot for the given cycle numbers so the foreign key
    /// constraint on `observer_signals.cycleNumber` is satisfied.
    private func makeStore(withCycles cycles: [Int] = []) throws -> (ObserverSignalStore, CIMSDatabase) {
        let db = try CIMSDatabase.inMemory()
        let store = ObserverSignalStore(database: db)

        if !cycles.isEmpty {
            let dimension = CIMSDefaults.plateDimension
            let vectorData = Data(repeating: 0, count: dimension * MemoryLayout<Float>.size)
            let now = ObserverSignalStore.formatDate(Date())

            try db.dbPool.write { dbConn in
                for cycle in cycles {
                    var record = PlateSnapshotRecord(
                        snapshotId: nil,
                        cycleNumber: cycle,
                        plateVector: vectorData,
                        plateEntropy: 0.5,
                        plateMagnitude: 1.0,
                        generatedText: "text",
                        inputDigest: nil,
                        capturedAt: now,
                    )
                    try record.insert(dbConn)
                }
            }
        }

        return (store, db)
    }

    /// Helper to create an observer signal.
    private func makeSignal(cycle: Int, text: String = "signal", promoted: Bool = false, date: Date = Date()) -> ObserverSignal {
        ObserverSignal(
            cycleNumber: cycle,
            signalText: text,
            salienceScore: 0.5,
            wasPromoted: promoted,
            createdAt: date,
            plateEntropy: 0.5,
            plateMagnitude: 1.0,
        )
    }

    @Test("Save and load roundtrip preserves fields")
    func saveLoadRoundtrip() async throws {
        let (store, _) = try makeStore(withCycles: [1])

        let signal = makeSignal(cycle: 1, text: "test signal")
        try await store.saveSignal(signal)

        let loaded = try await store.latestSignal()
        #expect(loaded != nil)
        #expect(loaded?.cycleNumber == 1)
        #expect(loaded?.signalText == "test signal")
        #expect(loaded?.salienceScore == 0.5)
        #expect(loaded?.wasPromoted == false)
    }

    @Test("Latest returns nil when empty")
    func latestReturnsNilWhenEmpty() async throws {
        let (store, _) = try makeStore()

        let result = try await store.latestSignal()
        #expect(result == nil)
    }

    @Test("signalsSince filters by date and respects limit")
    func signalsSinceFiltersAndLimits() async throws {
        let (store, _) = try makeStore(withCycles: [1, 2, 3])

        let old = Date().addingTimeInterval(-3600)
        let mid = Date().addingTimeInterval(-1800)
        let now = Date()

        try await store.saveSignal(makeSignal(cycle: 1, text: "old", date: old))
        try await store.saveSignal(makeSignal(cycle: 2, text: "mid", date: mid))
        try await store.saveSignal(makeSignal(cycle: 3, text: "recent", date: now))

        let cutoff = Date().addingTimeInterval(-900)
        let results = try await store.signalsSince(cutoff, limit: 10)
        #expect(results.count == 1)
        #expect(results[0].signalText == "recent")

        let allResults = try await store.signalsSince(Date().addingTimeInterval(-7200), limit: 2)
        #expect(allResults.count == 2)
    }

    @Test("markPromoted flips the promoted flag")
    func markPromoted() async throws {
        let (store, db) = try makeStore(withCycles: [1])

        try await store.saveSignal(makeSignal(cycle: 1, text: "signal"))

        let before = try await store.latestSignal()
        #expect(before?.wasPromoted == false)

        try await store.markPromoted(cycleNumber: 1)

        let after = try await store.latestSignal()
        #expect(after?.wasPromoted == true)
    }
}
