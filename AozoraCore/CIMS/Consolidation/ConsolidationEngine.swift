import Foundation
import GRDB

/// Offline identity evolution orchestrator.
///
/// Runs the full consolidation pipeline in the background without blocking the online
/// cognitive cycle. The pipeline stages execute sequentially:
///
/// 1. **Bump detection** — Scan for reminiscence bumps (topic shifts, corrections, etc.)
/// 2. **Claim extraction** — LLM-based claim generation from bump candidates
/// 3. **Claim merging** — Merge proposals into identity and mirror stores
/// 4. **DAG compaction** — Leaf and condensed passes to compress the DAG
/// 5. **Hebbian decay** — Decay claim confidences based on time since reinforcement
/// 5.5. **Hotness decay** — Exponential decay of node hotness based on time since last access
/// 6. **Cold storage demotion** — Demote low-hotness, stale nodes to compressed storage
///
/// Each run is tracked in the `consolidation_jobs` table with metrics and error state,
/// enabling auditability and resumability. The engine is idempotent — running consolidation
/// twice with the same data produces the same results.
///
/// `nothingSignificant` is a valid and common outcome. Most sessions don't produce
/// identity-level insights, and the pipeline is designed to handle this gracefully.
public actor ConsolidationEngine: ConsolidationEngineProtocol {
    /// The shared database backing all CIMS persistence.
    private let db: CIMSDatabase

    /// The identity store for reading/writing claims and applying decay.
    private let identityStore: IdentityStore

    /// The model provider for summarization and claim extraction.
    private let model: any ModelProviding

    /// The bump detector for scanning DAG nodes.
    private let bumpDetector: BumpDetector

    /// The claim extractor for LLM-based claim generation.
    private let claimExtractor: ClaimExtractor

    /// The DAG compactor for leaf and condensed passes.
    private let compactor: DAGCompactor

    /// The cold storage manager for demotion/promotion.
    private let coldStorage: ColdStorage

    /// The memory store for hotness decay during consolidation.
    private let memoryStore: MemoryStore

    /// Creates a consolidation engine with all required dependencies.
    ///
    /// - Parameters:
    ///   - database: The CIMS database instance.
    ///   - identityStore: The identity store for claim management.
    ///   - model: The model provider for LLM inference.
    ///   - memoryStore: The memory store for node hotness decay.
    public init(database: CIMSDatabase, identityStore: IdentityStore, model: any ModelProviding, memoryStore: MemoryStore) {
        self.db = database
        self.identityStore = identityStore
        self.model = model
        self.memoryStore = memoryStore
        self.bumpDetector = BumpDetector(database: database)
        self.claimExtractor = ClaimExtractor(model: model)
        self.compactor = DAGCompactor(database: database, model: model)
        self.coldStorage = ColdStorage(database: database)
    }

    /// Run the full consolidation pipeline.
    ///
    /// Creates a job record in `consolidation_jobs`, then executes each pipeline stage
    /// in sequence. Metrics (bumps detected, claims extracted, nodes compacted, nodes
    /// decayed) are accumulated and written back to the job record on completion.
    ///
    /// If any stage fails, the error is recorded on the job and the pipeline stops.
    /// Partial progress from earlier stages is retained — consolidation is designed
    /// to be resumable.
    ///
    /// - Parameter trigger: What triggered this consolidation run.
    public nonisolated func consolidate(trigger: ConsolidationTrigger) async {
        let jobId = UUID().uuidString
        let now = Self.formatDate(Date())

        do {
            try await createJobRecord(jobId: jobId, trigger: trigger, now: now)
        } catch {
            Log.error("consolidation", "Failed to create job record: \(error)")
            return
        }

        Log.info("consolidation", "Pipeline start (trigger: \(trigger), job: \(jobId.prefix(8)))")
        let pipelineStart = ContinuousClock.now

        do {
            try await markJobRunning(jobId: jobId)

            var metrics = JobMetrics()

            let bumps = try await runBumpDetection()
            metrics.bumpsDetected = bumps.count
            Log.info("consolidation", "Bumps: \(bumps.count) detected")

            let proposal = try await runClaimExtraction(bumps: bumps)
            metrics.claimsExtracted = proposal.identityProposals.count + proposal.mirrorProposals.count

            if !proposal.nothingSignificant {
                Log.info("consolidation", "Claims: \(proposal.identityProposals.count) identity, \(proposal.mirrorProposals.count) mirror")
                await mergeProposals(proposal)
            }

            let nodesCompacted = try await runCompaction()
            metrics.nodesCompacted = nodesCompacted

            await runHebbianDecay()

            await runHotnessDecay()

            let nodesDemoted = try await runColdStorageDemotion()
            metrics.nodesDecayed = nodesDemoted

            let elapsed = ContinuousClock.now - pipelineStart
            let secs = String(format: "%.1f", Double(elapsed.components.seconds) + Double(elapsed.components.attoseconds) / 1e18)
            Log.info("consolidation", "Pipeline done: \(metrics.bumpsDetected) bumps, \(metrics.claimsExtracted) claims, \(metrics.nodesCompacted) compacted, \(metrics.nodesDecayed) demoted (\(secs)s)")
            try await markJobCompleted(jobId: jobId, metrics: metrics)
        } catch {
            try? await markJobFailed(jobId: jobId, error: error)
            let elapsed = ContinuousClock.now - pipelineStart
            let secs = String(format: "%.1f", Double(elapsed.components.seconds) + Double(elapsed.components.attoseconds) / 1e18)
            Log.error("consolidation", "Pipeline failed after \(secs)s: \(error)")
        }
    }

    // MARK: - Pipeline Stages

    /// Stage 1: Scan for reminiscence bumps in recently created nodes.
    ///
    /// Looks back 24 hours for bump candidates (topic shifts, corrections,
    /// emotional intensity, novel entities).
    ///
    /// - Returns: Detected bump candidates.
    private func runBumpDetection() async throws -> [BumpCandidate] {
        let lookbackDate = Date().addingTimeInterval(-86_400)
        return try await bumpDetector.scanForBumps(since: lookbackDate)
    }

    /// Stage 2: Extract claims from bump candidates via LLM inference.
    ///
    /// - Parameter bumps: Bump candidates from stage 1.
    /// - Returns: A consolidation proposal (may be `nothingSignificant`).
    private func runClaimExtraction(bumps: [BumpCandidate]) async throws -> ConsolidationProposal {
        try await claimExtractor.extractClaims(from: bumps)
    }

    /// Stage 3: Merge claim proposals into identity and mirror stores.
    ///
    /// - Parameter proposal: The consolidation proposal with identity and mirror candidates.
    private func mergeProposals(_ proposal: ConsolidationProposal) async {
        if !proposal.identityProposals.isEmpty {
            await identityStore.mergeClaims(proposal.identityProposals, target: .identity)
        }

        if !proposal.mirrorProposals.isEmpty {
            await identityStore.mergeClaims(proposal.mirrorProposals, target: .mirror("default"))
        }
    }

    /// Stage 4: Run DAG compaction across all conversations.
    ///
    /// Executes leaf passes and condensed passes for every conversation in the database.
    ///
    /// - Returns: Total number of summary nodes created across all conversations.
    private func runCompaction() async throws -> Int {
        let conversationIds = try await db.dbPool.read { db in
            try Int64.fetchAll(db, sql: "SELECT id FROM conversations")
        }

        var total = 0
        for conversationId in conversationIds {
            let leafResult = try await compactor.leafPass(conversationId: conversationId)
            let condensedCount = try await compactor.condensedPass(conversationId: conversationId)
            total += leafResult.summariesCreated + condensedCount

            // Merge pre-compression proposals from the leaf pass into the consolidation pipeline.
            for proposal in leafResult.preCompressionProposals where !proposal.nothingSignificant {
                await mergeProposals(proposal)
            }
        }

        return total
    }

    /// Stage 5: Apply Hebbian decay to all claim confidences.
    private func runHebbianDecay() async {
        await identityStore.decayClaims()
    }

    /// Stage 5.5: Apply exponential hotness decay to DAG nodes.
    ///
    /// Runs after Hebbian claim decay and before cold storage demotion so that
    /// newly-decayed nodes become eligible for demotion in the same pipeline run.
    private func runHotnessDecay() async {
        await memoryStore.decayHotness()
    }

    /// Stage 6: Demote eligible nodes to cold storage.
    ///
    /// - Returns: Number of nodes demoted.
    private func runColdStorageDemotion() async throws -> Int {
        try await coldStorage.demoteEligibleNodes()
    }

    // MARK: - Job Tracking

    /// Accumulated metrics for a consolidation run.
    private struct JobMetrics {
        var bumpsDetected: Int = 0
        var claimsExtracted: Int = 0
        var nodesCompacted: Int = 0
        var nodesDecayed: Int = 0
    }

    /// Create the initial job record with `pending` status.
    private func createJobRecord(jobId: String, trigger: ConsolidationTrigger, now: String) async throws {
        try await db.dbPool.write { db in
            let record = ConsolidationJobRecord(
                jobId: jobId,
                trigger: trigger.rawValue,
                status: "pending",
                startedAt: nil,
                completedAt: nil,
                bumpsDetected: nil,
                claimsExtracted: nil,
                nodesCompacted: nil,
                nodesDecayed: nil,
                error: nil,
                createdAt: now,
            )
            try record.insert(db)
        }
    }

    /// Transition the job to `running` status.
    private func markJobRunning(jobId: String) async throws {
        let now = Self.formatDate(Date())
        try await db.dbPool.write { db in
            try db.execute(
                sql: "UPDATE consolidation_jobs SET status = 'running', startedAt = ? WHERE jobId = ?",
                arguments: [now, jobId],
            )
        }
    }

    /// Transition the job to `completed` status with accumulated metrics.
    private func markJobCompleted(jobId: String, metrics: JobMetrics) async throws {
        let now = Self.formatDate(Date())
        try await db.dbPool.write { db in
            try db.execute(
                sql: """
                UPDATE consolidation_jobs
                SET status = 'completed',
                    completedAt = ?,
                    bumpsDetected = ?,
                    claimsExtracted = ?,
                    nodesCompacted = ?,
                    nodesDecayed = ?
                WHERE jobId = ?
                """,
                arguments: [
                    now,
                    metrics.bumpsDetected,
                    metrics.claimsExtracted,
                    metrics.nodesCompacted,
                    metrics.nodesDecayed,
                    jobId,
                ],
            )
        }
    }

    /// Transition the job to `failed` status with the error description.
    private func markJobFailed(jobId: String, error: any Error) async throws {
        let now = Self.formatDate(Date())
        try await db.dbPool.write { db in
            try db.execute(
                sql: """
                UPDATE consolidation_jobs
                SET status = 'failed', completedAt = ?, error = ?
                WHERE jobId = ?
                """,
                arguments: [now, String(describing: error), jobId],
            )
        }
    }

    // MARK: - Helpers

    /// Format a `Date` as an ISO 8601 string with fractional seconds.
    nonisolated static func formatDate(_ date: Date) -> String {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f.string(from: date)
    }
}
