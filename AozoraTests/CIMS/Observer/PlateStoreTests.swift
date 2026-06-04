import Foundation
import GRDB
import Testing
@testable import Aozora

@Suite("PlateStore")
struct PlateStoreTests {
    /// Create a fresh in-memory database and plate store for each test.
    private func makeStore() throws -> (PlateStore, CIMSDatabase) {
        let db = try CIMSDatabase.inMemory()
        let store = PlateStore(database: db)
        return (store, db)
    }

    /// Helper to create a plate snapshot with a given cycle number.
    private func makeSnapshot(cycle: Int) -> PlateSnapshot {
        let dimension = CIMSDefaults.plateDimension
        var floats = [Float](repeating: Float(cycle), count: dimension)
        let data = unsafe floats.withUnsafeMutableBufferPointer { buffer in
            unsafe Data(buffer: buffer)
        }
        return PlateSnapshot(
            cycleNumber: cycle,
            plateVector: data,
            plateEntropy: Double(cycle) * 0.1,
            plateMagnitude: Double(cycle) * 1.5,
            generatedText: "Signal from cycle \(cycle)",
            inputDigest: "digest_\(cycle)",
            capturedAt: Date(),
        )
    }

    @Test("Save and load roundtrip preserves all fields")
    func saveLoadRoundtrip() async throws {
        let (store, _) = try makeStore()

        let snapshot = makeSnapshot(cycle: 1)
        try await store.saveSnapshot(snapshot)

        let loaded = try await store.latestSnapshot()
        #expect(loaded != nil)
        #expect(loaded?.cycleNumber == 1)
        #expect(loaded?.plateVector.count == CIMSDefaults.plateDimension * MemoryLayout<Float>.size)
        #expect(loaded?.plateEntropy == 0.1)
        #expect(loaded?.plateMagnitude == 1.5)
        #expect(loaded?.generatedText == "Signal from cycle 1")
        #expect(loaded?.inputDigest == "digest_1")
    }

    @Test("Latest returns nil when empty")
    func latestReturnsNilWhenEmpty() async throws {
        let (store, _) = try makeStore()

        let result = try await store.latestSnapshot()
        #expect(result == nil)
    }

    @Test("Prune keeps only N most recent snapshots")
    func pruneKeepsRecent() async throws {
        let (store, db) = try makeStore()

        for i in 1 ... 5 {
            try await store.saveSnapshot(makeSnapshot(cycle: i))
        }

        try await store.pruneOld(keepLast: 2)

        let remaining = try await db.dbPool.read { db in
            try PlateSnapshotRecord
                .order(Column("cycleNumber").asc)
                .fetchAll(db)
        }
        #expect(remaining.count == 2)
        #expect(remaining[0].cycleNumber == 4)
        #expect(remaining[1].cycleNumber == 5)
    }

    @Test("Archive range creates archive record with averaged vector and entropy bounds")
    func archiveRange() async throws {
        let (store, db) = try makeStore()

        for i in 1 ... 3 {
            try await store.saveSnapshot(makeSnapshot(cycle: i))
        }

        try await store.archiveRange(from: 1, to: 3)

        let archives = try await db.dbPool.read { db in
            try PlateArchiveRecord.fetchAll(db)
        }
        #expect(archives.count == 1)
        #expect(archives[0].cycleRange == "1-3")
        #expect(abs(archives[0].maxEntropy - 0.3) < 0.0001)
        #expect(abs(archives[0].minEntropy - 0.1) < 0.0001)
        #expect(archives[0].meanVector.count == CIMSDefaults.plateDimension * MemoryLayout<Float>.size)

        let meanFloats = unsafe archives[0].meanVector.withUnsafeBytes { buffer in
            Array(unsafe buffer.bindMemory(to: Float.self))
        }
        let expectedMean = Float(1 + 2 + 3) / 3.0
        #expect(abs(meanFloats[0] - expectedMean) < 0.001)
    }
}
