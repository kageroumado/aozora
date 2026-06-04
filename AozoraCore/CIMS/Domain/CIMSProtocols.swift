import Foundation

// MARK: - Coordinator Protocol

/// The main entry point for the cognitive cycle.
///
/// The coordinator orchestrates the online per-turn loop: salience scoring → memory retrieval →
/// context assembly → executive inference → tool handling → persistence → compaction check.
/// It serializes turns per user and manages the turn state machine with timeouts.
///
/// The coordinator owns stateless structs (``SalienceScorer``, ``ChronoState``,
/// ``AllostasisState``, ``ContextAssembler``) and talks to actor-isolated stores
/// (``MemoryStoring``, ``IdentityStoring``) and ``WorkerSupervisor``.
public protocol CIMSCoordinating: Sendable {
    /// Run a single turn of the cognitive cycle, calling the observer for each event.
    ///
    /// This is a plain `async throws` function — when it returns, the turn is done.
    /// When it throws, the turn failed. No continuation to manage.
    ///
    /// - Parameters:
    ///   - request: The turn request containing the user's message and metadata.
    ///   - observer: Receives turn lifecycle events.
    /// - Throws: ``CIMSError/queueFull`` if the turn queue exceeds ``CIMSDefaults/maxQueuedTurns``.
    func runTurn(_ request: TurnRequest, observer: some TurnObserver) async throws

    /// Cancel an in-progress turn.
    ///
    /// Cancels any active inference, kills dispatched workers. The turn's
    /// partial state is persisted for continuity.
    ///
    /// - Parameter id: The ID of the turn to cancel.
    func cancelTurn(_ id: TurnID) async
}

// MARK: - Memory Store Protocol

/// LCM-backed memory persistence and retrieval.
///
/// The memory store manages the DAG hierarchy (raw turns → leaf summaries → condensed),
/// FTS5 full-text search, message persistence with structured parts, delegation grants
/// for worker access, and compaction/maintenance operations.
///
/// All raw messages persist verbatim at DAG depth 0. Summaries compress but raw data
/// remains accessible via expansion. Nothing is ever lost (lossless guarantee).
///
/// This is an actor protocol — implementations must be actor-isolated to protect
/// DAG traversal and database I/O from blocking the coordinator.
public protocol MemoryStoring: Sendable {
    // MARK: Persistence

    /// Persist a user message and assistant response as a new turn in the DAG.
    ///
    /// Creates a conversation if needed, inserts message records with parts,
    /// creates a depth-0 ``NodeKind/rawTurn`` node, indexes in FTS5, and updates the frontier.
    ///
    /// Node IDs are deterministic: `"node_" + SHA-256(canonicalText).prefix(16)`.
    ///
    /// - Parameters:
    ///   - message: The inbound user message.
    ///   - response: The assistant's response.
    func ingest(_ message: InboundMessage, response: AssistantResponse) async

    /// Persist a full turn with tool call history as structured message parts.
    ///
    /// Unlike ``ingest(_:response:)`` which only stores the final user + assistant text,
    /// this method persists each tool loop iteration as proper messages: assistant messages
    /// with toolCall parts and tool-role messages with toolResult parts.
    ///
    /// - Parameters:
    ///   - userMessage: The inbound user message.
    ///   - toolHistory: Ordered tool loop iterations with calls and results.
    ///   - finalResponse: The assistant's final response after all tool iterations.
    ///   - sessionKey: The session this turn belongs to.
    ///   - userKey: The user who initiated the turn.
    func ingestTurn(
        userMessage: InboundMessage,
        toolHistory: [ToolTurnRecord],
        finalResponse: AssistantResponse,
        sessionKey: String,
        userKey: String,
    ) async

    /// Batch-import pre-existing messages (e.g., during migration).
    ///
    /// - Parameter messages: Messages to import, in chronological order.
    func ingestBatch(_ messages: [StoredMessage]) async

    // MARK: Retrieval

    /// Retrieve memory relevant to a query, ranked by FTS5 + DAG frontier + salience boost.
    ///
    /// Returns both ranked summaries and the fresh tail (last N raw messages).
    /// The salience boost is additive — if salience scoring failed, retrieval still works.
    ///
    /// - Parameters:
    ///   - query: The search query (typically the user's message text).
    ///   - salienceBoost: Salience envelope to additively boost identity-relevant results.
    ///   - limit: Maximum number of summary nodes to return.
    /// - Returns: Ranked summaries plus the fresh tail.
    func retrieve(query: String, salienceBoost: SalienceEnvelope, limit: Int) async -> MemoryRetrievalResult

    /// Retrieve all frontier summaries plus the fresh tail for context estimation.
    func retrieveFrontier() async -> MemoryRetrievalResult

    /// Search memory by keyword (FTS5) or regex pattern.
    ///
    /// - Parameters:
    ///   - pattern: The search pattern.
    ///   - mode: Whether to use full-text search or regex matching.
    ///   - scope: Which conversations to search.
    /// - Returns: Matching excerpts with scores.
    func grep(pattern: String, mode: GrepMode, scope: GrepScope) async -> [GrepMatch]

    /// Fetch the full description of a DAG node or large file.
    ///
    /// - Parameter id: The node or file ID to describe.
    /// - Returns: Full metadata and content for the referenced entity.
    func describe(id: NodeOrFileID) async -> NodeDescription

    /// Expand compressed DAG nodes to retrieve their full content.
    ///
    /// Used by the coordinator's `expand_memory` tool when a summary's
    /// "expand for details" footer is relevant.
    ///
    /// - Parameters:
    ///   - nodeIds: Node IDs to expand (from summary `id` attributes).
    ///   - tokenBudget: Maximum total tokens for all expanded content.
    /// - Returns: Expanded content, possibly truncated if budget exceeded.
    func expand(nodeIds: [NodeID], tokenBudget: Int) async -> ExpansionResult

    // MARK: Large File Access

    /// Retrieve the full content of an intercepted large file.
    ///
    /// Large files are content exceeding ``CIMSDefaults/largeFileTokenThreshold`` that were
    /// intercepted during ingestion and stored separately to prevent context budget exhaustion.
    ///
    /// - Parameter id: The file ID from the placeholder metadata.
    /// - Returns: The original full content, or `nil` if the file ID doesn't exist.
    func retrieveLargeFile(id: String) async throws -> String?

    // MARK: Delegation

    /// Create a scoped, time-limited read grant for a worker.
    ///
    /// The grant expires after ``CIMSDefaults/delegationGrantTTL`` and restricts
    /// the worker to the specified conversations and operations.
    ///
    /// - Parameter scope: The scope and constraints for the grant.
    /// - Returns: The created delegation grant.
    func createDelegationGrant(scope: DelegationScope) async -> DelegationGrant

    /// Revoke a delegation grant (on worker completion or timeout).
    ///
    /// - Parameter grantId: The grant to revoke.
    func revokeDelegationGrant(_ grantId: GrantID) async

    // MARK: Compaction

    /// Check if incremental compaction is needed and run if so.
    ///
    /// Called after each turn. Triggers leaf pass if raw tokens outside fresh tail
    /// exceed ``CIMSDefaults/leafChunkTokens``.
    func compactIfNeeded() async

    /// Run a full compaction sweep — leaf passes until stable, then condensed passes.
    ///
    /// Called during consolidation for thorough maintenance.
    func compactFull() async

    // MARK: Maintenance

    /// Apply Hebbian decay to DAG node hotness values.
    ///
    /// Nodes with hotness below ``CIMSDefaults/coldStorageHotnessThreshold``
    /// become candidates for cold storage demotion.
    func decayHotness() async

    /// Demote cold nodes to compressed storage.
    ///
    /// Nodes with `hotness < 0.1` AND `lastAccessedAt > 30 days` have their
    /// `canonicalText` compressed to `lcm_cold_payloads` as zstd/zlib blobs.
    func demoteColdNodes() async

    /// Scan for reminiscence bumps — moments where understanding shifted.
    ///
    /// - Parameter since: Only scan nodes created after this date.
    /// - Returns: Nodes flagged for claim extraction.
    func scanForBumps(since: Date) async -> [BumpCandidate]

    // MARK: Assembly Support

    /// Fetch the last N raw messages for a conversation (the fresh tail).
    ///
    /// The fresh tail is a hard invariant: these messages are never compacted.
    ///
    /// - Parameters:
    ///   - count: Number of messages to fetch (default: ``CIMSDefaults/protectedTailCount``).
    ///   - conversationId: The conversation to fetch from.
    /// - Returns: Messages ordered by creation time.
    func freshTail(count: Int, for conversationId: ConversationID) async -> [StoredMessage]

    /// Fetch summary nodes for context assembly, respecting a token budget.
    ///
    /// - Parameters:
    ///   - conversationId: The conversation to fetch summaries for.
    ///   - tokenBudget: Maximum total tokens for summaries.
    /// - Returns: Summary nodes ordered oldest to newest.
    func summaries(for conversationId: ConversationID, tokenBudget: Int) async -> [SummaryNode]
}

// MARK: - Identity Store Protocol

/// Versioned identity and mirror block management.
///
/// Manages the system's self-knowledge (identity) and per-user models (mirrors) as
/// versioned collections of epistemic claims. Every change creates a new version with
/// rationale and triggering evidence, enabling full rollback.
///
/// Claims follow strict epistemic discipline: single observations are always hypotheses,
/// promotion requires diverse evidence, and contradictions lower confidence rather than
/// silently overwriting. Rejected claims are kept for audit trail.
///
/// This is an actor protocol — implementations must use transactional isolation to ensure
/// versioned writes don't conflict with concurrent reads.
public protocol IdentityStoring: Sendable {
    // MARK: Read

    /// Fetch the current active identity block with all claims.
    ///
    /// Returns ``IdentityBlock/empty`` if no identity has been bootstrapped yet.
    func currentIdentity() async -> IdentityBlock

    /// Fetch the current active mirror block for a specific user.
    ///
    /// Creates the user record and initial mirror version if the user hasn't been seen before.
    ///
    /// - Parameter userKey: The user to fetch the mirror for.
    /// - Returns: The active mirror block, or an empty one for new users.
    func currentMirror(for userKey: UserKey) async -> MirrorBlock

    // MARK: Write (consolidation path)

    /// Merge candidate claims into the identity or mirror block.
    ///
    /// Creates a new version, copies existing claims, and applies candidates:
    /// - **Reinforcement**: candidate matches existing → bump confidence, add evidence.
    /// - **New claim**: no match → create as `hypothesis` with evidence link.
    /// - **Contradiction**: candidate contradicts existing → lower confidence on existing,
    ///   create competing hypothesis.
    ///
    /// - Parameters:
    ///   - candidates: Proposed claims from the consolidation engine.
    ///   - target: Whether to update the identity block or a specific user's mirror.
    func mergeClaims(_ candidates: [ClaimCandidate], target: ClaimTarget) async

    // MARK: Write (escape hatch)

    /// Apply an immediate correction to a user's mirror, bypassing the consolidation queue.
    ///
    /// Used when the user explicitly corrects a belief about themselves. The user is the
    /// authority on themselves. The correction is still versioned and logged.
    ///
    /// - Parameters:
    ///   - correction: The correction to apply.
    ///   - userKey: The user whose mirror to update.
    func applyExplicitCorrection(_ correction: MirrorCorrection, for userKey: UserKey) async

    // MARK: Maintenance

    /// Apply Hebbian decay to all claim confidences.
    ///
    /// Uses the formula: `decayed = confidence × e^(-λ × daysSinceReinforced)`
    /// where `λ = ln(2) / decayHalfLifeDays`. Bounded by floor (0.05) and cap (1.0).
    ///
    /// Claims below a threshold are flagged for re-evaluation, not automatically rejected.
    func decayClaims() async

    // MARK: Rollback

    /// Roll back the identity to a previous version.
    ///
    /// Deactivates the current version and reactivates the specified version.
    ///
    /// - Parameter versionId: The version to restore.
    func rollbackIdentity(to versionId: VersionID) async

    /// Roll back a user's mirror to a previous version.
    ///
    /// - Parameters:
    ///   - userKey: The user whose mirror to roll back.
    ///   - versionId: The version to restore.
    func rollbackMirror(for userKey: UserKey, to versionId: VersionID) async
}

// MARK: - Model Provider Protocol

/// Abstraction over LLM inference with tiered model selection.
///
/// Takes a pre-built ``Prompt`` value containing system blocks, messages, and tool schemas.
/// The provider wraps this with transport config (model ID, max tokens, thinking, auth)
/// before sending. Supports both synchronous completion and streaming.
///
/// The tier system enables budget-driven downgrade: under pressure, the system uses
/// cheaper models for workers while preserving capability for the coordinator.
public protocol ModelProviding: Sendable {
    /// Run a complete inference call from a pre-built prompt.
    ///
    /// - Parameters:
    ///   - prompt: The fully constructed prompt (system blocks, messages, tools).
    ///   - tier: Which model tier to use for this inference.
    /// - Returns: The model's complete response with token usage and latency.
    /// - Throws: ``CIMSError/modelUnavailable(_:)`` or ``CIMSError/modelError(_:)``.
    func complete(_ prompt: Prompt, tier: ModelTier) async throws -> ModelResponse

    /// Run a streaming inference call from a pre-built prompt.
    ///
    /// - Parameters:
    ///   - prompt: The fully constructed prompt (system blocks, messages, tools).
    ///   - tier: Which model tier to use.
    /// - Returns: An async stream of incremental response deltas.
    /// - Throws: ``CIMSError/modelUnavailable(_:)`` or ``CIMSError/modelError(_:)``.
    func stream(
        _ prompt: Prompt, tier: ModelTier,
    ) async throws -> AsyncThrowingStream<ModelDelta, any Error>
}

// MARK: - Worker Execution Protocol

/// Contract between the coordinator and worker execution layer.
///
/// Implementations run the worker's inference loop with scoped LCM access,
/// producing a compressed ``WorkerSummary`` that fits in coordinator context.
public protocol WorkerExecuting: Sendable {
    /// Execute a worker task and return a compressed summary.
    ///
    /// The worker runs independently: tool loops, error handling, iteration. It has scoped
    /// LCM read access via the task's delegation grant. On completion, it produces a
    /// summary (400-800 tokens) of what was done, what was found, and what matters.
    ///
    /// - Parameter task: The self-contained worker task specification.
    /// - Returns: A compressed summary of the worker's execution.
    /// - Throws: ``CIMSError/workerBudgetExhausted(_:)`` or ``CIMSError/workerFailed(_:_:)``.
    func execute(_ task: WorkerTask) async throws -> WorkerSummary
}

// MARK: - Consolidation Engine Protocol

/// Offline identity evolution orchestrator.
///
/// Runs the consolidation pipeline: bump detection → claim extraction → merge into
/// identity/mirror stores → DAG compaction → Hebbian decay → cold storage demotion.
/// Never blocks the online path — runs in a background context.
public protocol ConsolidationEngineProtocol: Sendable {
    /// Run the full consolidation pipeline.
    ///
    /// Tracks the run in the `consolidation_jobs` table. `nothingSignificant` is a valid
    /// and common outcome — most sessions don't produce identity-level insights.
    ///
    /// - Parameter trigger: What triggered this consolidation run.
    func consolidate(trigger: ConsolidationTrigger) async
}

// MARK: - Assistant Response

/// The assistant's response to an inbound message, before persistence.
///
/// Contains both the final content and the structured parts for storage,
/// plus tool calls and performance metrics.
public struct AssistantResponse: Sendable {
    /// The complete response text.
    public let content: String

    /// Structured parts for persistence (text, tool calls, reasoning, etc.).
    public let parts: [MessagePart]

    /// Tool calls made during this response.
    public let toolCalls: [ToolCall]

    /// Token consumption for this inference.
    public let tokenUsage: TokenUsage

    /// Wall-clock time for the inference.
    public let latency: Duration

    public init(content: String, parts: [MessagePart], toolCalls: [ToolCall], tokenUsage: TokenUsage, latency: Duration) {
        self.content = content
        self.parts = parts
        self.toolCalls = toolCalls
        self.tokenUsage = tokenUsage
        self.latency = latency
    }
}
