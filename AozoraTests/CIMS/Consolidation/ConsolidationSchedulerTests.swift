import Foundation
import GRDB
import Testing
@testable import Aozora

@Suite("ConsolidationScheduler")
struct ConsolidationSchedulerTests {
    /// Create a scheduler with very short timeouts and an in-memory engine.
    ///
    /// Returns the scheduler, database (for verifying consolidation_jobs), and engine.
    private func makeScheduler(
        idleTimeout: Duration = .milliseconds(100),
        sessionEndDelay: Duration = .milliseconds(100),
    ) async throws -> (ConsolidationScheduler, CIMSDatabase) {
        let db = try CIMSDatabase.inMemory()
        let model = MockModelProvider()
        let identityStore = try await IdentityStore(database: db)
        let memoryStore = MemoryStore(database: db)
        let engine = ConsolidationEngine(
            database: db,
            identityStore: identityStore,
            model: model,
            memoryStore: memoryStore,
        )
        let scheduler = ConsolidationScheduler(
            engine: engine,
            idleTimeout: idleTimeout,
            sessionEndDelay: sessionEndDelay,
        )
        return (scheduler, db)
    }

    /// Count completed consolidation jobs in the database.
    private func completedJobCount(in db: CIMSDatabase) async throws -> Int {
        try await db.dbPool.read { dbConn in
            try ConsolidationJobRecord
                .filter(Column("status") == "completed")
                .fetchCount(dbConn)
        }
    }

    /// Count all consolidation jobs (any status) in the database.
    private func totalJobCount(in db: CIMSDatabase) async throws -> Int {
        try await db.dbPool.read { dbConn in
            try ConsolidationJobRecord.fetchCount(dbConn)
        }
    }

    /// Fetch all consolidation job records from the database.
    private func allJobs(in db: CIMSDatabase) async throws -> [ConsolidationJobRecord] {
        try await db.dbPool.read { dbConn in
            try ConsolidationJobRecord.fetchAll(dbConn)
        }
    }

    // MARK: - Idle Timeout

    @Test("Idle timeout triggers consolidation after inactivity")
    func idleTimeoutTriggersConsolidation() async throws {
        let (scheduler, db) = try await makeScheduler(idleTimeout: .milliseconds(100))

        await scheduler.recordActivity()

        try await Task.sleep(for: .milliseconds(300))

        let count = try await completedJobCount(in: db)
        #expect(count == 1, "One consolidation should have completed after idle timeout")

        let jobs = try await allJobs(in: db)
        #expect(jobs[0].trigger == "idle_timeout")
    }

    @Test("Activity resets idle timer, preventing premature consolidation")
    func activityResetsIdleTimer() async throws {
        let (scheduler, db) = try await makeScheduler(idleTimeout: .milliseconds(1_000))

        await scheduler.recordActivity()

        try await Task.sleep(for: .milliseconds(400))

        let countBefore = try await totalJobCount(in: db)
        #expect(countBefore == 0, "Consolidation should not have run yet")

        // Reset the timer
        await scheduler.recordActivity()

        try await Task.sleep(for: .milliseconds(400))

        let countMid = try await totalJobCount(in: db)
        #expect(countMid == 0, "Timer was reset — consolidation still should not have run")

        // Now wait for the full idle timeout to expire
        try await Task.sleep(for: .milliseconds(1_200))

        let countAfter = try await completedJobCount(in: db)
        #expect(countAfter == 1, "Consolidation should run after the reset timer expires")
    }

    // MARK: - Session End

    @Test("Session end triggers consolidation after delay")
    func sessionEndTriggersConsolidation() async throws {
        let (scheduler, db) = try await makeScheduler(sessionEndDelay: .milliseconds(100))

        await scheduler.recordSessionEnd()

        try await Task.sleep(for: .milliseconds(300))

        let count = try await completedJobCount(in: db)
        #expect(count == 1, "One consolidation should have completed after session-end delay")

        let jobs = try await allJobs(in: db)
        #expect(jobs[0].trigger == "session_end")
    }

    // MARK: - Manual Trigger

    @Test("Manual trigger runs consolidation immediately")
    func manualTriggerRunsImmediately() async throws {
        let (scheduler, db) = try await makeScheduler()

        await scheduler.runNow()

        let count = try await completedJobCount(in: db)
        #expect(count == 1, "Consolidation should have run immediately")

        let jobs = try await allJobs(in: db)
        #expect(jobs[0].trigger == "manual")
    }

    // MARK: - Stop

    @Test("Stop cancels scheduled consolidation")
    func stopCancelsScheduledConsolidation() async throws {
        // Use a long idle timeout so it definitely hasn't fired before we stop
        let (scheduler, db) = try await makeScheduler(idleTimeout: .seconds(10))

        await scheduler.recordActivity()

        // Wait a bit, then stop — the 10s timer should still be sleeping
        try await Task.sleep(for: .milliseconds(200))
        await scheduler.stop()

        // Wait long enough that the timer would have fired if not cancelled
        try await Task.sleep(for: .milliseconds(500))

        let count = try await totalJobCount(in: db)
        #expect(count == 0, "Consolidation should not run after stop()")
    }

    // MARK: - Concurrency Guard

    @Test("Concurrent consolidation is prevented")
    func concurrentConsolidationPrevented() async throws {
        let db = try CIMSDatabase.inMemory()
        let model = MockModelProvider(simulatedLatency: .milliseconds(200))
        let identityStore = try await IdentityStore(database: db)
        let memoryStore = MemoryStore(database: db)
        let engine = ConsolidationEngine(
            database: db,
            identityStore: identityStore,
            model: model,
            memoryStore: memoryStore,
        )
        let scheduler = ConsolidationScheduler(
            engine: engine,
            idleTimeout: .milliseconds(50),
            sessionEndDelay: .milliseconds(50),
        )

        await scheduler.runNow()

        await scheduler.recordActivity()

        try await Task.sleep(for: .milliseconds(100))

        await scheduler.runNow()

        try await Task.sleep(for: .milliseconds(500))

        let jobs = try await allJobs(in: db)
        let completedCount = jobs.count(where: { $0.status == "completed" })
        #expect(completedCount >= 1, "At least one consolidation should have completed")
        #expect(completedCount <= 3, "Concurrent runs should be bounded, not unbounded")
    }
}
