import Foundation

/// Manages worker lifecycle: spawn, monitor, kill, and enforce concurrency budgets.
///
/// ``WorkerSupervisor`` enforces two hard limits from ``CIMSDefaults``:
/// - ``CIMSDefaults/maxConcurrentWorkers`` (4): total workers running across all users
/// - ``CIMSDefaults/maxWorkersPerUser`` (1): workers running for a single user
///
/// When a worker completes (successfully or via cancellation/error), it is removed from
/// the active set. The supervisor does not write to the DAG — workers are read-only
/// via delegation grants, and grants are revoked by the coordinator after completion.
public actor WorkerSupervisor {
    /// Active worker runs keyed by run ID.
    private var activeWorkers: [WorkerRunID: ActiveWorker] = [:]

    /// Tracks which user owns each active worker run.
    private var workersByUser: [UserKey: Set<WorkerRunID>] = [:]

    /// Internal bookkeeping for an active worker.
    private struct ActiveWorker {
        let runId: WorkerRunID
        let userKey: UserKey
        let task: Task<WorkerSummary, any Error>
        let grantId: GrantID
    }

    // MARK: - Dispatch

    /// Dispatch a worker task for execution.
    ///
    /// Validates that concurrency limits are not exceeded, then spawns the worker
    /// in a detached task. Blocks until the worker completes and returns its summary.
    /// The worker is tracked in the active set for the duration of execution.
    ///
    /// - Parameters:
    ///   - task: The self-contained worker task specification.
    ///   - executor: The worker executor to run the task.
    ///   - userKey: The user who owns this worker (defaults to "default").
    /// - Returns: The compressed worker summary.
    /// - Throws: ``CIMSError/workerFailed(_:_:)`` if the worker errors,
    ///           or ``CIMSError/workerBudgetExhausted(_:)`` if concurrency limits are hit.
    public func dispatch(
        task workerTask: WorkerTask,
        executor: any WorkerExecuting,
        userKey: UserKey = "default",
    ) async throws -> WorkerSummary {
        let runId = workerTask.runId

        guard activeWorkers.count < CIMSDefaults.maxConcurrentWorkers else {
            throw CIMSError.workerFailed(runId, "Max concurrent workers (\(CIMSDefaults.maxConcurrentWorkers)) reached")
        }

        let userCount = workersByUser[userKey]?.count ?? 0
        guard userCount < CIMSDefaults.maxWorkersPerUser else {
            throw CIMSError.workerFailed(runId, "Max workers per user (\(CIMSDefaults.maxWorkersPerUser)) reached")
        }

        let executionTask = Task.detached { [workerTask, executor] in
            try await executor.execute(workerTask)
        }

        let worker = ActiveWorker(
            runId: runId,
            userKey: userKey,
            task: executionTask,
            grantId: workerTask.delegationGrant.grantId,
        )

        activeWorkers[runId] = worker
        workersByUser[userKey, default: []].insert(runId)

        do {
            let summary = try await executionTask.value
            removeWorker(runId, userKey: userKey)
            return summary
        } catch {
            removeWorker(runId, userKey: userKey)
            throw CIMSError.workerFailed(runId, error.localizedDescription)
        }
    }

    // MARK: - Cancellation

    /// Cancel an active worker by its run ID.
    ///
    /// Cancels the underlying task and removes the worker from the active set.
    /// If the run ID is not found (already completed or never dispatched), this is a no-op.
    ///
    /// - Parameter runId: The worker run ID to cancel.
    public func cancel(runId: WorkerRunID) {
        guard let worker = activeWorkers[runId] else { return }
        worker.task.cancel()
        removeWorker(runId, userKey: worker.userKey)
    }

    // MARK: - Queries

    /// Information about an active worker for management/diagnostics.
    public struct ActiveWorkerInfo: Sendable {
        public let runId: WorkerRunID
        public let userKey: UserKey
        public let grantId: GrantID
    }

    /// List all currently active workers with their metadata.
    ///
    /// Used by the ``WorkerManagementTool`` to expose worker state to the coordinator.
    ///
    /// - Returns: Array of active worker info structs.
    public func listActive() -> [ActiveWorkerInfo] {
        activeWorkers.values.map { ActiveWorkerInfo(runId: $0.runId, userKey: $0.userKey, grantId: $0.grantId) }
    }

    /// The number of currently active workers across all users.
    public var activeCount: Int {
        activeWorkers.count
    }

    /// The number of currently active workers for a specific user.
    ///
    /// - Parameter userKey: The user to query.
    /// - Returns: Number of active workers for that user.
    public func activeCountForUser(_ userKey: UserKey) -> Int {
        workersByUser[userKey]?.count ?? 0
    }

    /// The grant ID associated with an active worker, if any.
    ///
    /// Used by the coordinator to revoke delegation grants after worker completion.
    ///
    /// - Parameter runId: The worker run ID.
    /// - Returns: The grant ID, or `nil` if the worker is not active.
    public func grantId(for runId: WorkerRunID) -> GrantID? {
        activeWorkers[runId]?.grantId
    }

    // MARK: - Internal

    /// Remove a worker from the active set and per-user tracking.
    private func removeWorker(_ runId: WorkerRunID, userKey: UserKey) {
        activeWorkers.removeValue(forKey: runId)
        workersByUser[userKey]?.remove(runId)
        if workersByUser[userKey]?.isEmpty == true {
            workersByUser.removeValue(forKey: userKey)
        }
    }
}
