import Foundation
import GRDB

// MARK: - Conversation Record

/// Persistence record for a single conversation session.
///
/// Each conversation maps 1:1 to a session identified by ``sessionKey``. The ``messageCount``
/// is denormalized for fast display without joining to the messages table.
///
/// Uses `MutablePersistableRecord` because the primary key is autoincremented — GRDB's
/// `didInsert` callback writes the database-assigned `rowID` back into the record.
public struct ConversationRecord: Codable, Sendable, FetchableRecord, MutablePersistableRecord {
    public static let databaseTableName = "conversations"

    /// Database-assigned autoincrement ID. `nil` before first insert.
    public var id: Int64?

    /// Unique session identifier linking this conversation to its originating session.
    public var sessionKey: String

    /// The user who owns this conversation.
    public var userKey: String

    /// ISO 8601 timestamp of when the conversation was created.
    public var startedAt: String

    /// ISO 8601 timestamp of the most recent message, or `nil` if no messages yet.
    public var lastMessageAt: String?

    /// Denormalized count of messages in this conversation.
    public var messageCount: Int

    public mutating func didInsert(_ inserted: InsertionSuccess) {
        id = inserted.rowID
    }
}

// MARK: - Message Record

/// Persistence record for a single message (user or assistant) within a conversation.
///
/// Messages are the atomic unit of conversation history. Each message belongs to exactly
/// one conversation and has an estimated token count for budget tracking. The optional
/// ``salienceScore`` is populated after salience scoring runs.
///
/// Uses `MutablePersistableRecord` for autoincrement ID assignment.
public struct MessageRecord: Codable, Sendable, FetchableRecord, MutablePersistableRecord {
    public static let databaseTableName = "messages"

    /// Database-assigned autoincrement ID. `nil` before first insert.
    public var id: Int64?

    /// Foreign key to the parent conversation.
    public var conversationId: Int64

    /// Message role: `"user"`, `"assistant"`, or `"system"`.
    public var role: String

    /// The full text content of the message.
    public var content: String

    /// Estimated token count for context budget tracking (`utf8.count / 4`).
    public var tokenEstimate: Int

    /// Composite salience score from ``SalienceScorer``, or `nil` if not yet scored.
    public var salienceScore: Double?

    /// ISO 8601 timestamp of when this message was created.
    public var createdAt: String

    public mutating func didInsert(_ inserted: InsertionSuccess) {
        id = inserted.rowID
    }
}

// MARK: - Message Part Record

/// Persistence record for a structured part within a message.
///
/// Messages are decomposed into ordered parts for richer storage: text blocks, tool calls,
/// tool results, reasoning traces, etc. The ``ordinal`` field preserves insertion order.
///
/// Uses `MutablePersistableRecord` for autoincrement ID assignment.
public struct MessagePartRecord: Codable, Sendable, FetchableRecord, MutablePersistableRecord {
    public static let databaseTableName = "message_parts"

    /// Database-assigned autoincrement ID. `nil` before first insert.
    public var id: Int64?

    /// Foreign key to the parent message.
    public var messageId: Int64

    /// The kind of part: `"text"`, `"toolCall"`, `"toolResult"`, `"reasoning"`, etc.
    public var partKind: String

    /// Zero-based position within the parent message's part sequence.
    public var ordinal: Int

    /// The part's content (text, JSON-encoded tool call, etc.).
    public var content: String

    /// Optional JSON metadata specific to the part kind.
    public var metadata: String?

    public mutating func didInsert(_ inserted: InsertionSuccess) {
        id = inserted.rowID
    }
}

// MARK: - LCM Node Record

/// Persistence record for a node in the LCM (Lossless Context Management) DAG.
///
/// Nodes form a directed acyclic graph at varying compression depths:
/// - **Depth 0** (`rawTurn`): Verbatim user+assistant turn content.
/// - **Depth 1** (`leafSummary`): ~1200 token summaries of groups of raw turns.
/// - **Depth 2+** (`condensed`): Progressive compressions of lower-depth summaries.
///
/// The ``hotness`` value decays over time via Hebbian decay. Nodes below
/// ``CIMSDefaults/coldStorageHotnessThreshold`` with sufficient age are demoted
/// to cold storage (``ColdPayloadRecord``), with ``canonicalText`` set to `nil`
/// and ``isCold`` set to 1.
///
/// Uses `PersistableRecord` (not mutable) because the primary key ``nodeId`` is
/// deterministic (`"node_" + SHA-256(canonicalText).prefix(16)`) — no autoincrement.
public struct LCMNodeRecord: Codable, Sendable, FetchableRecord, PersistableRecord {
    public static let databaseTableName = "lcm_nodes"

    /// Deterministic node ID: `"node_" + SHA-256(canonicalText).prefix(16)`.
    public var nodeId: String

    /// Foreign key to the conversation this node belongs to.
    public var conversationId: Int64

    /// Compression depth: 0 = raw, 1 = leaf summary, 2+ = condensed.
    public var depth: Int

    /// Node kind matching ``NodeKind``: `"rawTurn"`, `"leafSummary"`, `"condensed"`.
    public var kind: String

    /// Estimated token count of the node's content.
    public var tokenCount: Int

    /// Optional SHA-256 checksum for content integrity verification.
    public var checksum: String?

    /// Composite salience score from the last scoring pass.
    public var salienceScore: Double

    /// Hebbian hotness value (0.0–1.0). Decays over time; boosted on access.
    public var hotness: Double

    /// Whether this node has been demoted to cold storage (0 = hot, 1 = cold).
    public var isCold: Int

    /// Full canonical text content. `nil` when the node is in cold storage.
    public var canonicalText: String?

    /// Summary text for non-raw nodes. Used in context assembly.
    public var summaryText: String?

    /// Footer text like "Expand for details about: ..." for UI affordance.
    public var expandFooter: String?

    /// ISO 8601 timestamp of the earliest source message covered by this node.
    public var earliestAt: String

    /// ISO 8601 timestamp of the latest source message covered by this node.
    public var latestAt: String

    /// ISO 8601 timestamp of the last time this node was accessed (for cold storage eligibility).
    public var lastAccessedAt: String

    /// Optimistic concurrency version counter. Incremented on each update.
    public var version: Int

    /// ISO 8601 timestamp of when this node was created.
    public var createdAt: String
}

// MARK: - LCM Edge Record

/// Persistence record for a directed edge in the LCM DAG.
///
/// Edges connect nodes to express hierarchical relationships:
/// - `summary_of`: A summary node summarizes one or more source nodes.
/// - `condensed_from`: A condensed node was produced from lower-depth summaries.
///
/// The composite primary key `(fromNodeId, toNodeId, edgeKind)` prevents duplicate edges.
public struct LCMEdgeRecord: Codable, Sendable, FetchableRecord, PersistableRecord {
    public static let databaseTableName = "lcm_edges"

    /// Source node ID (the summarizer/condenser).
    public var fromNodeId: String

    /// Target node ID (the node being summarized/condensed).
    public var toNodeId: String

    /// Edge kind matching ``EdgeKind``: `"summary_of"`, `"condensed_from"`.
    public var edgeKind: String
}

// MARK: - LCM Frontier Record

/// Persistence record for a node in the current DAG frontier.
///
/// The frontier is the set of nodes that represent the "current view" of memory
/// for a conversation — the nodes that would be presented in context assembly.
/// As compaction progresses, raw nodes are replaced by their summary parents
/// in the frontier.
public struct LCMFrontierRecord: Codable, Sendable, FetchableRecord, PersistableRecord {
    public static let databaseTableName = "lcm_frontier"

    /// Foreign key to the conversation this frontier entry belongs to.
    public var conversationId: Int64

    /// The DAG node that is part of the frontier.
    public var nodeId: String

    /// Ordering position within the frontier (chronological).
    public var ordinal: Int
}

// MARK: - LCM FTS Record

/// Persistence record for the FTS5 (Full-Text Search) virtual table.
///
/// Each row indexes a DAG node's content for keyword search. The `content` column
/// is the only indexed column — `nodeId`, `conversationId`, `depth`, and `kind` are
/// `UNINDEXED` metadata columns used for filtering and joining after search.
///
/// FTS5 queries use SQLite's `MATCH` operator and return BM25-ranked results.
public struct LCMFTSRecord: Codable, Sendable, FetchableRecord, PersistableRecord {
    public static let databaseTableName = "lcm_fts"

    /// The full-text content indexed by FTS5 (the only searchable column).
    public var content: String

    /// The DAG node this FTS entry corresponds to (UNINDEXED metadata).
    public var nodeId: String

    /// Conversation scope for filtering (UNINDEXED metadata).
    public var conversationId: Int64

    /// Node depth for filtering (UNINDEXED metadata).
    public var depth: Int

    /// Node kind for filtering (UNINDEXED metadata).
    public var kind: String
}

// MARK: - Cold Payload Record

/// Persistence record for compressed cold-storage payloads.
///
/// When a DAG node's ``LCMNodeRecord/hotness`` drops below
/// ``CIMSDefaults/coldStorageHotnessThreshold`` and it hasn't been accessed for
/// ``CIMSDefaults/coldStorageAgeDays``, its ``LCMNodeRecord/canonicalText`` is
/// compressed (zstd/zlib) and stored here. The original node's `canonicalText`
/// is set to `nil` and `isCold` to 1.
///
/// Promotion (on access) decompresses the payload, restores `canonicalText`,
/// and deletes this record.
public struct ColdPayloadRecord: Codable, Sendable, FetchableRecord, PersistableRecord {
    public static let databaseTableName = "lcm_cold_payloads"

    /// Foreign key to the cold node. Also serves as the primary key.
    public var nodeId: String

    /// Compressed content blob (zstd or zlib).
    public var payload: Data

    /// Original uncompressed size in bytes, for pre-allocating decompression buffers.
    public var originalBytes: Int
}

// MARK: - Large File Record

/// Persistence record for file content intercepted before it enters the context.
///
/// When an inbound message contains file content exceeding
/// ``CIMSDefaults/largeFileTokenThreshold`` tokens, the content is stored
/// separately and replaced with a summary in the message. This prevents
/// a single large paste from consuming the entire context budget.
public struct LargeFileRecord: Codable, Sendable, FetchableRecord, PersistableRecord {
    public static let databaseTableName = "large_files"

    /// Unique file identifier. Also serves as the primary key.
    public var fileId: String

    /// Foreign key to the conversation this file appeared in.
    public var conversationId: Int64

    /// Foreign key to the message that contained this file.
    public var messageId: Int64

    /// Original file name, if available.
    public var fileName: String?

    /// MIME type, if detected.
    public var mimeType: String?

    /// Raw byte size of the stored content.
    public var byteSize: Int

    /// Estimated token count of the original content.
    public var tokenEstimate: Int

    /// LLM-generated summary of the file content for inline display.
    public var explorationSummary: String

    /// Filesystem path where the full content is stored.
    public var storagePath: String

    /// ISO 8601 timestamp of when this file was intercepted.
    public var createdAt: String
}

// MARK: - Context Item Record

/// Persistence record for a single item in the assembled context snapshot.
///
/// After context assembly, the ordered list of sections (identity block, mirror block,
/// summaries, fresh tail, etc.) is persisted here for diagnostic replay. Each item
/// references the source entity by kind and ID.
public struct ContextItemRecord: Codable, Sendable, FetchableRecord, PersistableRecord {
    public static let databaseTableName = "context_items"

    /// Foreign key to the conversation this context was assembled for.
    public var conversationId: Int64

    /// Ordering position within the assembled context.
    public var ordinal: Int

    /// The kind of context item: `"identity"`, `"mirror"`, `"summary"`, `"freshTail"`, etc.
    public var itemKind: String

    /// Reference to the source entity (node ID, version ID, etc.).
    public var referenceId: String

    /// Estimated token count consumed by this item.
    public var tokenEstimate: Int
}

// MARK: - Identity Version Record

/// Persistence record for a version in the identity block's version chain.
///
/// Every change to the identity block creates a new version with a back-pointer to the
/// previous version, enabling full rollback. Only one version is ``isActive`` at any time.
/// The ``createdBy`` field distinguishes bootstrap, consolidation, and manual edits.
///
/// Uses `MutablePersistableRecord` because the primary key is autoincremented.
public struct IdentityVersionRecord: Codable, Sendable, FetchableRecord, MutablePersistableRecord {
    public static let databaseTableName = "identity_versions"

    /// Database-assigned autoincrement version ID. `nil` before first insert.
    public var versionId: Int64?

    /// Back-pointer to the predecessor version, or `nil` for the initial version.
    public var previousVersion: Int64?

    /// Whether this version is the currently active one.
    public var isActive: Bool

    /// ISO 8601 timestamp of when this version was created.
    public var createdAt: String

    /// Creator identifier: `"bootstrap"`, `"consolidation"`, `"explicitCorrection"`, etc.
    public var createdBy: String

    /// Human-readable rationale for why this version was created.
    public var rationale: String?

    public mutating func didInsert(_ inserted: InsertionSuccess) {
        versionId = inserted.rowID
    }
}

// MARK: - Identity Claim Record

/// Persistence record for a single epistemic claim in an identity version.
///
/// Claims follow strict epistemic discipline: each has a ``confidence`` score (0.05–1.0)
/// subject to Hebbian decay, an ``epistemicStatus`` tracking its lifecycle, and evidence
/// metadata. The `(versionId, claimKey)` pair is unique — a version cannot have duplicate
/// claims for the same key.
///
/// Uses `MutablePersistableRecord` because the primary key is autoincremented.
public struct IdentityClaimRecord: Codable, Sendable, FetchableRecord, MutablePersistableRecord {
    public static let databaseTableName = "identity_claims"

    /// Database-assigned autoincrement ID. `nil` before first insert.
    public var id: Int64?

    /// Foreign key to the identity version this claim belongs to.
    public var versionId: Int64

    /// Semantic key identifying what this claim is about (e.g., `"core_values"`, `"communication_style"`).
    public var claimKey: String

    /// The claim's content — what the system believes about this aspect of itself.
    public var value: String

    /// Confidence score (0.05–1.0), subject to Hebbian decay.
    /// Bounded by ``CIMSDefaults/hebbianDecayFloor`` and ``CIMSDefaults/hebbianDecayCap``.
    public var confidence: Double

    /// Epistemic lifecycle status: `"hypothesis"`, `"established"`, `"foundational"`, or `"rejected"`.
    public var epistemicStatus: String

    /// Number of distinct evidence observations supporting this claim.
    public var evidenceCount: Int

    /// Number of distinct evidence *sources* (conversations) supporting this claim.
    public var evidenceDiversity: Int

    /// Half-life for Hebbian decay in days. Identity claims default to 90 days.
    public var decayHalfLifeDays: Double

    /// ISO 8601 timestamp of when this claim was first created.
    public var createdAt: String

    /// ISO 8601 timestamp of when this claim was last reinforced by new evidence.
    public var lastReinforcedAt: String

    public mutating func didInsert(_ inserted: InsertionSuccess) {
        id = inserted.rowID
    }
}

// MARK: - User Record

/// Persistence record for a known user.
///
/// Created on first interaction and updated on each subsequent session. The ``isBootstrap``
/// flag indicates whether the user is still in the bootstrap period (fewer than
/// ``CIMSDefaults/bootstrapSessionCount`` sessions), during which claim generation
/// thresholds are lower.
///
/// Uses `PersistableRecord` because the primary key ``userKey`` is application-provided.
public struct UserRecord: Codable, Sendable, FetchableRecord, PersistableRecord {
    public static let databaseTableName = "users"

    /// Unique user identifier. Serves as the primary key.
    public var userKey: String

    /// Optional display name for context rendering.
    public var displayName: String?

    /// ISO 8601 timestamp of the user's first interaction.
    public var firstSeenAt: String

    /// ISO 8601 timestamp of the user's most recent interaction.
    public var lastInteractionAt: String

    /// Total number of sessions with this user.
    public var sessionCount: Int

    /// Whether this user is still in the bootstrap period.
    public var isBootstrap: Bool
}

// MARK: - Mirror Version Record

/// Persistence record for a version in a user's mirror block version chain.
///
/// Mirrors are per-user models of the user's preferences, communication style,
/// and relationship dynamics. Like identity versions, every change creates a new
/// version with rollback capability. The ``userKey`` scopes the version chain
/// to a specific user.
///
/// Uses `MutablePersistableRecord` because the primary key is autoincremented.
public struct MirrorVersionRecord: Codable, Sendable, FetchableRecord, MutablePersistableRecord {
    public static let databaseTableName = "mirror_versions"

    /// Database-assigned autoincrement version ID. `nil` before first insert.
    public var versionId: Int64?

    /// The user this mirror version belongs to.
    public var userKey: String

    /// Back-pointer to the predecessor version, or `nil` for the initial version.
    public var previousVersion: Int64?

    /// Whether this version is the currently active one for this user.
    public var isActive: Bool

    /// ISO 8601 timestamp of when this version was created.
    public var createdAt: String

    /// Creator identifier: `"bootstrap"`, `"consolidation"`, `"explicitCorrection"`, etc.
    public var createdBy: String

    /// Human-readable rationale for why this version was created.
    public var rationale: String?

    public mutating func didInsert(_ inserted: InsertionSuccess) {
        versionId = inserted.rowID
    }
}

// MARK: - Mirror Claim Record

/// Persistence record for a single epistemic claim in a mirror version.
///
/// Mirror claims model the system's beliefs about a specific user — their preferences,
/// communication patterns, expertise areas, and relationship dynamics. They follow the
/// same epistemic discipline as identity claims but with a shorter default decay half-life
/// (60 days vs 90) because people change faster than core values.
///
/// Uses `MutablePersistableRecord` because the primary key is autoincremented.
public struct MirrorClaimRecord: Codable, Sendable, FetchableRecord, MutablePersistableRecord {
    public static let databaseTableName = "mirror_claims"

    /// Database-assigned autoincrement ID. `nil` before first insert.
    public var id: Int64?

    /// Foreign key to the mirror version this claim belongs to.
    public var versionId: Int64

    /// Semantic key identifying what this claim is about (e.g., `"expertise"`, `"communication_preference"`).
    public var claimKey: String

    /// The claim's content — what the system believes about this aspect of the user.
    public var value: String

    /// Confidence score (0.05–1.0), subject to Hebbian decay.
    public var confidence: Double

    /// Epistemic lifecycle status: `"hypothesis"`, `"established"`, `"foundational"`, or `"rejected"`.
    public var epistemicStatus: String

    /// Number of distinct evidence observations supporting this claim.
    public var evidenceCount: Int

    /// Number of distinct evidence *sources* (conversations) supporting this claim.
    public var evidenceDiversity: Int

    /// Half-life for Hebbian decay in days. Mirror claims default to 60 days.
    public var decayHalfLifeDays: Double

    /// ISO 8601 timestamp of when this claim was first created.
    public var createdAt: String

    /// ISO 8601 timestamp of when this claim was last reinforced by new evidence.
    public var lastReinforcedAt: String

    public mutating func didInsert(_ inserted: InsertionSuccess) {
        id = inserted.rowID
    }
}

// MARK: - Claim Evidence Record

/// Persistence record linking an epistemic claim to its supporting evidence.
///
/// Evidence records create an audit trail from claims back to the DAG nodes that
/// produced them. The ``claimTable`` field (`"identity_claims"` or `"mirror_claims"`)
/// combined with ``claimId`` forms a polymorphic foreign key, since evidence can
/// support either type of claim.
///
/// Uses `MutablePersistableRecord` because the primary key is autoincremented.
public struct ClaimEvidenceRecord: Codable, Sendable, FetchableRecord, MutablePersistableRecord {
    public static let databaseTableName = "claim_evidence"

    /// Database-assigned autoincrement ID. `nil` before first insert.
    public var id: Int64?

    /// Foreign key to the claim this evidence supports (in ``claimTable``).
    public var claimId: Int64

    /// Which claims table this evidence references: `"identity_claims"` or `"mirror_claims"`.
    public var claimTable: String

    /// Foreign key to the DAG node that provided this evidence.
    public var nodeId: String

    /// How this evidence relates to the claim: `"supporting"`, `"contradicting"`, `"neutral"`.
    public var evidenceType: String

    /// Optional excerpt from the source node that constitutes the evidence.
    public var excerpt: String?

    /// ISO 8601 timestamp of when this evidence link was created.
    public var createdAt: String

    public mutating func didInsert(_ inserted: InsertionSuccess) {
        id = inserted.rowID
    }
}

// MARK: - Delegation Grant Record

/// Persistence record for a scoped, time-limited worker access grant.
///
/// Workers need read access to the LCM to perform their tasks, but this access is
/// constrained by delegation grants that limit scope (which conversations), operations
/// (read-only, search, expand), token budget, and time-to-live. Grants are revoked
/// on worker completion or timeout.
///
/// Uses `PersistableRecord` because the primary key ``grantId`` is application-provided (UUID).
public struct DelegationGrantRecord: Codable, Sendable, FetchableRecord, PersistableRecord {
    public static let databaseTableName = "delegation_grants"

    /// Unique grant identifier (UUID string). Serves as the primary key.
    public var grantId: String

    /// JSON-encoded conversation scope restricting which conversations the worker can access.
    public var conversationScope: String

    /// Maximum tokens the worker can consume under this grant.
    public var tokenCap: Int

    /// Tokens consumed so far under this grant.
    public var tokensUsed: Int

    /// JSON-encoded list of permitted operations (e.g., `["read", "search"]`).
    public var operations: String

    /// ISO 8601 timestamp of when this grant was created.
    public var createdAt: String

    /// ISO 8601 timestamp of when this grant expires (TTL from ``CIMSDefaults/delegationGrantTTL``).
    public var expiresAt: String

    /// ISO 8601 timestamp of when this grant was explicitly revoked, or `nil` if still active.
    public var revokedAt: String?

    /// The worker run that owns this grant, for correlation in logs and traces.
    public var workerRunId: String?
}

// MARK: - Consolidation Job Record

/// Persistence record for an offline consolidation pipeline run.
///
/// The consolidation engine tracks each run — its trigger, progress metrics, and outcome —
/// in this table. Jobs progress through states: `"pending"` → `"running"` → `"completed"` or
/// `"failed"`. Metrics (bumps detected, claims extracted, nodes compacted/decayed) are
/// populated as each pipeline stage completes.
///
/// Uses `PersistableRecord` because the primary key ``jobId`` is application-provided (UUID).
public struct ConsolidationJobRecord: Codable, Sendable, FetchableRecord, PersistableRecord {
    public static let databaseTableName = "consolidation_jobs"

    /// Unique job identifier (UUID string). Serves as the primary key.
    public var jobId: String

    /// What triggered this consolidation run: `"idle"`, `"sessionEnd"`, `"manual"`.
    public var trigger: String

    /// Current job status: `"pending"`, `"running"`, `"completed"`, `"failed"`.
    public var status: String

    /// ISO 8601 timestamp of when the job started executing, or `nil` if still pending.
    public var startedAt: String?

    /// ISO 8601 timestamp of when the job finished, or `nil` if still running.
    public var completedAt: String?

    /// Number of reminiscence bumps detected during this run.
    public var bumpsDetected: Int?

    /// Number of epistemic claims extracted from bumps.
    public var claimsExtracted: Int?

    /// Number of DAG nodes compacted during this run.
    public var nodesCompacted: Int?

    /// Number of DAG nodes that had their hotness decayed.
    public var nodesDecayed: Int?

    /// Error message if the job failed.
    public var error: String?

    /// ISO 8601 timestamp of when this job record was created.
    public var createdAt: String
}

// MARK: - Chrono State Record

/// Persistence record for per-user temporal perception state.
///
/// Tracks the user's interaction timeline for chronoception — the system's sense of time.
/// The ``gapHistory`` stores recent inter-session gap durations (JSON array) used by
/// ``ChronoState`` to compute ``TemporalMode`` (continuation, reconnection, reunion, etc.).
///
/// Uses `PersistableRecord` because the primary key ``userKey`` is application-provided.
public struct ChronoStateRecord: Codable, Sendable, FetchableRecord, PersistableRecord {
    public static let databaseTableName = "chrono_state"

    /// The user this chrono state belongs to. Serves as the primary key (FK to users).
    public var userKey: String

    /// ISO 8601 timestamp of the user's last interaction.
    public var lastInteractionAt: String

    /// ISO 8601 timestamp of when the user's last session ended, or `nil` if this is the first.
    public var lastSessionEndAt: String?

    /// Total number of sessions with this user.
    public var sessionCount: Int

    /// JSON-encoded array of recent inter-session gap durations (seconds).
    public var gapHistory: String?
}

// MARK: - Allostatic State Record

/// Persistence record for the global allostatic (resource pressure) state.
///
/// This is a **singleton row** (enforced by a `CHECK(id == 1)` constraint). It tracks
/// the system's current resource pressure mode, recent API latencies, error rates,
/// and token budget consumption. ``AllostasisState`` reads this on startup and writes
/// back after each turn.
///
/// Uses `PersistableRecord` because the primary key is a fixed constant (always 1).
public struct AllostaticStateRecord: Codable, Sendable, FetchableRecord, PersistableRecord {
    public static let databaseTableName = "allostatic_state"

    /// Always 1 — enforced by a CHECK constraint. Ensures singleton semantics.
    public var id: Int64

    /// Current allostasis mode: `"exploratory"`, `"balanced"`, `"conservative"`, `"recovery"`.
    public var mode: String

    /// JSON-encoded array of recent API call latencies in milliseconds.
    public var recentLatencyMs: String?

    /// Rolling error rate (0.0–1.0) computed from recent API calls.
    public var recentErrorRate: Double

    /// Total tokens consumed in the current budget period.
    public var tokenBudgetUsed: Int

    /// ISO 8601 timestamp of the last update to this record.
    public var updatedAt: String
}

// MARK: - Cognitive Trace Record

/// Persistence record for a per-turn diagnostic snapshot of the cognitive cycle.
///
/// Every turn through the coordinator produces a trace capturing what happened at each
/// stage: salience scoring results, memory retrieval decisions, context budget allocation,
/// tool calls, worker dispatches, and any degradation flags. Traces enable post-hoc analysis
/// of why the system behaved a certain way.
///
/// Uses `MutablePersistableRecord` because the primary key is autoincremented.
public struct CognitiveTraceRecord: Codable, Sendable, FetchableRecord, MutablePersistableRecord {
    public static let databaseTableName = "cognitive_traces"

    /// Database-assigned autoincrement ID. `nil` before first insert.
    public var id: Int64?

    /// The turn this trace corresponds to (matches ``TurnRequest/id``).
    public var turnId: String

    /// Foreign key to the conversation this turn occurred in.
    public var conversationId: Int64

    /// JSON-encoded ``SalienceEnvelope`` produced by the salience scorer.
    public var salienceEnvelope: String

    /// JSON-encoded memory retrieval results (node IDs, scores, token counts).
    public var memoryRetrieval: String

    /// JSON-encoded context budget allocation (section → tokens).
    public var contextBudget: String

    /// JSON-encoded list of executive tool calls made during this turn, or `nil` if none.
    public var executiveTools: String?

    /// JSON-encoded list of worker dispatches triggered by this turn, or `nil` if none.
    public var workerDispatches: String?

    /// JSON-encoded degradation flags (what was dropped or truncated), or `nil` if none.
    public var degradationFlags: String?

    /// Allostasis mode at the time of this turn.
    public var allostasisMode: String

    /// ISO 8601 timestamp of when this trace was recorded.
    public var createdAt: String

    public mutating func didInsert(_ inserted: InsertionSuccess) {
        id = inserted.rowID
    }
}
