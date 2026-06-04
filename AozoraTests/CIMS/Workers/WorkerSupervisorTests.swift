import Foundation
import Testing
@testable import Aozora

@Suite("WorkerSupervisor")
struct WorkerSupervisorTests {
    // MARK: - Test Helpers

    /// Create a minimal worker task for testing.
    private func makeWorkerTask(runId: String = UUID().uuidString) -> WorkerTask {
        WorkerTask(
            runId: runId,
            goal: "Test goal",
            constraints: [],
            identityExcerpt: "",
            memoryPointers: [],
            delegationGrant: DelegationGrant(
                grantId: UUID().uuidString,
                conversationScope: .all,
                tokenCap: CIMSDefaults.workerDefaultBudget,
                tokensUsed: 0,
                operations: [.grep, .describe, .expand],
                createdAt: Date(),
                expiresAt: Date().addingTimeInterval(300),
                revokedAt: nil,
                workerRunId: nil,
            ),
            toolPolicy: .all,
            tokenBudget: CIMSDefaults.workerDefaultBudget,
        )
    }

    /// A simple mock executor that returns a canned summary.
    actor SimpleExecutor: WorkerExecuting {
        /// Optional delay to simulate work.
        private let delay: Duration?

        init(delay: Duration? = nil) {
            self.delay = delay
        }

        nonisolated func execute(_ task: WorkerTask) async throws -> WorkerSummary {
            let goal = await task.goal
            if let delay = await getDelay() {
                try await Task.sleep(for: delay)
            }

            return WorkerSummary(
                narrative: "Completed: \(goal)",
                citedMemoryNodes: [],
                toolsUsed: [],
                tokensBurned: 100,
                outcome: .completed,
                failedAttempts: [],
                lessons: [],
                confidence: 0.9,
            )
        }

        func getDelay() -> Duration? {
            delay
        }
    }

    /// An executor that always throws, for error-path testing.
    actor FailingExecutor: WorkerExecuting {
        nonisolated func execute(_ task: WorkerTask) async throws -> WorkerSummary {
            let runId = await task.runId
            throw CIMSError.workerFailed(runId, "Simulated failure")
        }
    }

    // MARK: - Basic Dispatch

    @Test("Dispatch returns a worker summary on success")
    func dispatchSuccess() async throws {
        let supervisor = WorkerSupervisor()
        let task = makeWorkerTask()
        let executor = SimpleExecutor()

        let summary = try await supervisor.dispatch(task: task, executor: executor)
        #expect(summary.outcome == .completed)
        #expect(summary.narrative.contains("Test goal"))
    }

    @Test("Active count is zero after dispatch completes")
    func activeCountAfterCompletion() async throws {
        let supervisor = WorkerSupervisor()
        let task = makeWorkerTask()
        let executor = SimpleExecutor()

        _ = try await supervisor.dispatch(task: task, executor: executor)

        let count = await supervisor.activeCount
        #expect(count == 0)
    }

    // MARK: - Concurrency Limits

    @Test("Rejects dispatch when max concurrent workers reached")
    func maxConcurrentWorkers() async throws {
        let supervisor = WorkerSupervisor()
        let slowExecutor = SimpleExecutor(delay: .seconds(10))

        // Fill up to max concurrent workers
        var backgroundTasks: [Task<WorkerSummary, any Error>] = []
        for i in 0 ..< CIMSDefaults.maxConcurrentWorkers {
            let task = makeWorkerTask(runId: "worker-\(i)")
            let bgTask = Task {
                try await supervisor.dispatch(task: task, executor: slowExecutor)
            }
            backgroundTasks.append(bgTask)
        }

        // Poll until all workers register
        for _ in 0 ..< 40 {
            try await Task.sleep(for: .milliseconds(50))
            let count = await supervisor.activeCount
            if count == CIMSDefaults.maxConcurrentWorkers { break }
        }

        // The next dispatch should fail
        let overflowTask = makeWorkerTask(runId: "overflow")
        do {
            _ = try await supervisor.dispatch(task: overflowTask, executor: slowExecutor)
            Issue.record("Expected dispatch to throw when at max capacity")
        } catch {
            guard case let CIMSError.workerFailed(runId, _) = error else {
                Issue.record("Expected CIMSError.workerFailed, got \(error)")
                return
            }
            #expect(runId == "overflow")
        }

        // Cancel all background tasks
        for bgTask in backgroundTasks {
            bgTask.cancel()
        }
    }

    @Test("Rejects dispatch when max workers per user reached")
    func maxWorkersPerUser() async throws {
        let supervisor = WorkerSupervisor()
        let slowExecutor = SimpleExecutor(delay: .seconds(10))
        let userKey = "test_user"

        // Dispatch one worker for the user (maxWorkersPerUser is 1)
        let task1 = makeWorkerTask(runId: "user-worker-1")
        let bgTask = Task {
            try await supervisor.dispatch(task: task1, executor: slowExecutor, userKey: userKey)
        }

        // Poll until the worker registers
        for _ in 0 ..< 40 {
            try await Task.sleep(for: .milliseconds(50))
            let count = await supervisor.activeCountForUser(userKey)
            if count == 1 { break }
        }

        // The next dispatch for the same user should fail
        let task2 = makeWorkerTask(runId: "user-worker-2")
        do {
            _ = try await supervisor.dispatch(task: task2, executor: slowExecutor, userKey: userKey)
            Issue.record("Expected dispatch to throw when user at max capacity")
        } catch {
            guard case let CIMSError.workerFailed(runId, _) = error else {
                Issue.record("Expected CIMSError.workerFailed, got \(error)")
                return
            }
            #expect(runId == "user-worker-2")
        }

        bgTask.cancel()
    }

    @Test("Different users can dispatch concurrently")
    func differentUsersCanDispatch() async throws {
        let supervisor = WorkerSupervisor()
        let executor = SimpleExecutor()

        let task1 = makeWorkerTask(runId: "user1-worker")
        let task2 = makeWorkerTask(runId: "user2-worker")

        async let summary1 = supervisor.dispatch(task: task1, executor: executor, userKey: "user1")
        async let summary2 = supervisor.dispatch(task: task2, executor: executor, userKey: "user2")

        let (s1, s2) = try await (summary1, summary2)
        #expect(s1.outcome == .completed)
        #expect(s2.outcome == .completed)
    }

    // MARK: - Cancellation

    @Test("Cancel removes worker from active set")
    func cancelRemovesWorker() async throws {
        let supervisor = WorkerSupervisor()
        let slowExecutor = SimpleExecutor(delay: .seconds(60))
        let runId = "cancel-me"

        let bgTask = Task {
            try await supervisor.dispatch(
                task: makeWorkerTask(runId: runId),
                executor: slowExecutor,
            )
        }

        // Poll until the worker registers (up to 2 seconds)
        var countBefore = 0
        for _ in 0 ..< 40 {
            try await Task.sleep(for: .milliseconds(50))
            countBefore = await supervisor.activeCount
            if countBefore == 1 { break }
        }

        // Worker should be active
        #expect(countBefore == 1)

        // Cancel it
        await supervisor.cancel(runId: runId)

        let countAfter = await supervisor.activeCount
        #expect(countAfter == 0)

        bgTask.cancel()
    }

    @Test("Cancel nonexistent run ID is a no-op")
    func cancelNonexistent() async {
        let supervisor = WorkerSupervisor()
        await supervisor.cancel(runId: "does-not-exist")
        let count = await supervisor.activeCount
        #expect(count == 0)
    }

    // MARK: - Error Handling

    @Test("Failed worker execution propagates as CIMSError.workerFailed")
    func failedWorker() async throws {
        let supervisor = WorkerSupervisor()
        let task = makeWorkerTask(runId: "failing-worker")
        let executor = FailingExecutor()

        do {
            _ = try await supervisor.dispatch(task: task, executor: executor)
            Issue.record("Expected dispatch to throw")
        } catch {
            guard case let CIMSError.workerFailed(runId, _) = error else {
                Issue.record("Expected CIMSError.workerFailed, got \(error)")
                return
            }
            #expect(runId == "failing-worker")
        }

        // Worker should be cleaned up after failure
        let count = await supervisor.activeCount
        #expect(count == 0)
    }

    // MARK: - Per-User Count

    @Test("activeCountForUser returns correct count")
    func activeCountForUser() async throws {
        let supervisor = WorkerSupervisor()
        let slowExecutor = SimpleExecutor(delay: .seconds(10))

        let task = makeWorkerTask(runId: "tracked-worker")
        let bgTask = Task {
            try await supervisor.dispatch(task: task, executor: slowExecutor, userKey: "tracked_user")
        }

        // Poll until the worker registers
        var userCount = 0
        for _ in 0 ..< 40 {
            try await Task.sleep(for: .milliseconds(50))
            userCount = await supervisor.activeCountForUser("tracked_user")
            if userCount == 1 { break }
        }
        #expect(userCount == 1)

        let otherCount = await supervisor.activeCountForUser("other_user")
        #expect(otherCount == 0)

        bgTask.cancel()
    }
}

// MARK: - WorkerOutcome Equatable

/// Equatable conformance for test assertions.
extension WorkerOutcome: Equatable {
    nonisolated public static func == (lhs: WorkerOutcome, rhs: WorkerOutcome) -> Bool {
        switch (lhs, rhs) {
        case (.completed, .completed):
            true
        case (.budgetExhausted, .budgetExhausted):
            true
        case let (.partial(a), .partial(b)):
            a == b
        case let (.failed(a), .failed(b)):
            a.localizedDescription == b.localizedDescription
        default:
            false
        }
    }
}
