import Foundation

// MARK: - Type Aliases

/// Unique identifier for a single cognitive turn (UUID string).
public typealias TurnID = String

/// Identifies a conversation session — stable across reconnections within the same session.
public typealias SessionKey = String

/// Identifies a unique human user across all sessions and transport layers.
public typealias UserKey = String

/// Deterministic identifier for a DAG node: `"node_" + SHA-256(canonicalText).prefix(16)`.
public typealias NodeID = String

/// SQLite row ID for a conversation record.
public typealias ConversationID = Int64

/// Unique identifier for a delegation grant issued to a worker.
public typealias GrantID = String

/// Unique identifier for a worker execution run.
public typealias WorkerRunID = String

/// SQLite row ID for an identity or mirror version record.
public typealias VersionID = Int64

/// Union identifier that can reference either a DAG node or a large file record.
public typealias NodeOrFileID = String

// MARK: - Message Types

/// An image attachment carried through the inbound message pipeline.
///
/// Raw image data with media type metadata, ready for vision API consumption.
/// Unsupported formats (HEIC, AVIF) should be converted to JPEG before constructing
/// this type — see ``DiscordChannel/convertImageIfNeeded(data:mediaType:)``.
public struct ImageAttachment: Sendable {
    /// Raw image data (JPEG, PNG, GIF, or WebP).
    public let data: Data

    /// MIME type: `"image/jpeg"`, `"image/png"`, `"image/gif"`, or `"image/webp"`.
    public let mediaType: String

    /// Original filename, if available (e.g., from Discord attachment metadata).
    public let filename: String?

    public init(data: Data, mediaType: String, filename: String? = nil) {
        self.data = data
        self.mediaType = mediaType
        self.filename = filename
    }
}

/// A message received from a user, before processing by the cognitive cycle.
///
/// Contains the raw text plus structured parts that enable the summarizer to filter
/// by kind (e.g., exclude reasoning blocks from leaf summaries).
public struct InboundMessage: Sendable {
    /// The plain text content of the message.
    public let text: String

    /// Structured decomposition of the message content (text, tool calls, files, etc.).
    public let parts: [MessagePart]

    /// Optional metadata about the message context (reply threading, attachments).
    public let metadata: MessageMetadata?

    /// Image attachments to send as vision content blocks alongside the text.
    public let images: [ImageAttachment]

    public init(text: String, parts: [MessagePart], metadata: MessageMetadata?, images: [ImageAttachment] = []) {
        self.text = text
        self.parts = parts
        self.metadata = metadata
        self.images = images
    }
}

/// Contextual metadata attached to an inbound message.
public struct MessageMetadata: Sendable {
    /// If this message is a reply, the ID of the message being replied to.
    public let replyToMessageId: Int64?

    /// File attachment identifiers referenced by this message.
    public let attachments: [String]

    public init(replyToMessageId: Int64?, attachments: [String]) {
        self.replyToMessageId = replyToMessageId
        self.attachments = attachments
    }
}

/// A single structured part of a message, enabling kind-aware processing.
///
/// Messages are decomposed into parts so the summarizer and context assembler can
/// handle each kind differently — e.g., reasoning blocks may be excluded from summaries,
/// tool calls are paired with results, and file references link to large file storage.
public struct MessagePart: Sendable {
    /// The semantic kind of this part (text, tool call, reasoning, etc.).
    public let kind: MessagePartKind

    /// Zero-based ordering within the parent message.
    public let ordinal: Int

    /// The raw content of this part.
    public let content: String

    /// Kind-specific metadata as JSON (e.g., tool name, file path, patch format).
    public let metadata: String?

    public init(kind: MessagePartKind, ordinal: Int, content: String, metadata: String?) {
        self.kind = kind
        self.ordinal = ordinal
        self.content = content
        self.metadata = metadata
    }
}

/// Classifies a message part for kind-aware processing during summarization and assembly.
public nonisolated enum MessagePartKind: String, Sendable, CaseIterable {
    /// Plain text content — the primary content kind.
    case text

    /// Tool calls and their results — procedural records.
    case tool

    /// A single tool call from the assistant (partKind stored as "toolCall").
    /// Metadata: JSON `{"id": "<tool_use_id>", "name": "<tool_name>"}`.
    /// Content: the JSON arguments string.
    case toolCall

    /// A single tool result (partKind stored as "toolResult").
    /// Metadata: JSON `{"toolUseId": "<tool_use_id>", "isError": <bool>}`.
    /// Content: the tool output text.
    case toolResult

    /// Thinking/reasoning blocks — may be excluded from summaries.
    case reasoning

    /// File references — links to intercepted large files.
    case file

    /// Code patches — structured diffs.
    case patch

    /// Compressed worker output — coordinator-visible execution results.
    case workerSummary = "worker_summary"
}

/// A message that has been persisted in the database with its assigned ID and metadata.
///
/// This is the read-side representation of a message, as opposed to ``InboundMessage``
/// which is the write-side input.
public struct StoredMessage: Sendable {
    public let id: Int64
    public let conversationId: ConversationID
    public let role: MessageRole
    public let content: String
    public let tokenEstimate: Int
    public let salienceScore: Float?
    public let createdAt: Date
    public let parts: [MessagePart]

    public init(id: Int64, conversationId: ConversationID, role: MessageRole, content: String, tokenEstimate: Int, salienceScore: Float?, createdAt: Date, parts: [MessagePart]) {
        self.id = id
        self.conversationId = conversationId
        self.role = role
        self.content = content
        self.tokenEstimate = tokenEstimate
        self.salienceScore = salienceScore
        self.createdAt = createdAt
        self.parts = parts
    }
}

/// The role of a message participant in the conversation.
public nonisolated enum MessageRole: String, Sendable, CaseIterable {
    case user
    case assistant
    case system
    case tool
}

// MARK: - DAG Types

/// The kind of a node in the LCM memory DAG hierarchy.
///
/// Depth 0 nodes are raw verbatim turns. Higher depths are progressively more compressed
/// summaries. Each depth level uses a tailored summarization strategy.
public nonisolated enum NodeKind: String, Sendable, CaseIterable {
    /// Depth 0: verbatim message + response, created on every turn.
    case rawTurn = "raw_turn"

    /// Depth 1: narrative summary of 1-3 raw turns (~800-1200 tokens).
    case leafSummary = "leaf_summary"

    /// Depth 2+: session-level or cross-session compressed narrative.
    case condensed

    /// Depth 0: leaf summary migrated from a prior system (depth-0 stable summaries).
    case leaf
}

/// The kind of edge connecting two nodes in the LCM DAG.
///
/// Edges encode the topological relationships that enable DAG traversal,
/// frontier management, and expansion from summaries back to source material.
public nonisolated enum EdgeKind: String, Sendable, CaseIterable {
    /// Chronological ordering between same-depth nodes.
    case temporalNext = "temporal_next"

    /// Parent-to-child: this node is a summary of the target node(s).
    case summaryOf = "summary_of"

    /// Causal dependency between nodes (e.g., a correction referencing the original).
    case causal

    /// Cross-reference: this node mentions content from the target node.
    case references
}

/// A summary node from the DAG, ready for inclusion in the assembled context.
///
/// Contains the rendered summary text plus metadata that the context assembler uses
/// for XML wrapping (``ContextAssembler``) and the coordinator uses for expansion decisions.
public struct SummaryNode: Sendable {
    public let nodeId: NodeID
    public let kind: NodeKind
    public let depth: Int
    public let tokenCount: Int

    /// The narrative summary text for this node.
    public let summaryText: String

    /// Human-readable footer: "Expand for details about: ..." — makes DAG pointers non-opaque.
    public let expandFooter: String?

    /// Timestamp of the earliest source material covered by this summary.
    public let earliestAt: Date

    /// Timestamp of the latest source material covered by this summary.
    public let latestAt: Date

    /// Heuristic salience score (0-1) used for retrieval ranking and recency injection.
    public let salienceScore: Float

    /// Number of raw_turn nodes that this summary (transitively) covers.
    public let descendantCount: Int

    /// For condensed nodes: the IDs of the parent summaries this was condensed from.
    public let parentIds: [NodeID]

    public init(nodeId: NodeID, kind: NodeKind, depth: Int, tokenCount: Int, summaryText: String, expandFooter: String?, earliestAt: Date, latestAt: Date, salienceScore: Float, descendantCount: Int, parentIds: [NodeID]) {
        self.nodeId = nodeId
        self.kind = kind
        self.depth = depth
        self.tokenCount = tokenCount
        self.summaryText = summaryText
        self.expandFooter = expandFooter
        self.earliestAt = earliestAt
        self.latestAt = latestAt
        self.salienceScore = salienceScore
        self.descendantCount = descendantCount
        self.parentIds = parentIds
    }
}

/// Full description of a DAG node, returned by the `describe` operation.
///
/// Provides both the raw canonical text (if available) and the summary text,
/// plus the node's children for further expansion.
public struct NodeDescription: Sendable {
    public let nodeId: NodeID
    public let kind: NodeKind
    public let depth: Int
    public let tokenCount: Int

    /// The raw verbatim content. `nil` if the node has been cold-demoted.
    public let canonicalText: String?

    /// The summary text, if this is a summary node (depth > 0).
    public let summaryText: String?

    /// Footer listing what details are available via expansion.
    public let expandFooter: String?

    public let earliestAt: Date
    public let latestAt: Date

    /// IDs of child nodes that can be expanded for more detail.
    public let childIds: [NodeID]

    public init(nodeId: NodeID, kind: NodeKind, depth: Int, tokenCount: Int, canonicalText: String?, summaryText: String?, expandFooter: String?, earliestAt: Date, latestAt: Date, childIds: [NodeID]) {
        self.nodeId = nodeId
        self.kind = kind
        self.depth = depth
        self.tokenCount = tokenCount
        self.canonicalText = canonicalText
        self.summaryText = summaryText
        self.expandFooter = expandFooter
        self.earliestAt = earliestAt
        self.latestAt = latestAt
        self.childIds = childIds
    }
}

/// Result of expanding one or more DAG nodes to retrieve their full content.
///
/// The coordinator uses this when a summary's "expand for details" footer is relevant
/// and the executive wants to see the underlying material.
public struct ExpansionResult: Sendable {
    /// The expanded nodes with their full text content.
    public let nodes: [(nodeId: NodeID, text: String)]

    /// Total tokens consumed by all expanded content.
    public let totalTokens: Int

    /// Whether expansion was truncated due to the token budget.
    public let truncated: Bool

    public init(nodes: [(nodeId: NodeID, text: String)], totalTokens: Int, truncated: Bool) {
        self.nodes = nodes
        self.totalTokens = totalTokens
        self.truncated = truncated
    }
}

// MARK: - Salience Types

/// Multi-signal salience score for an inbound message.
///
/// The envelope captures four orthogonal signals and a weighted composite. It's produced
/// by ``SalienceScorer`` (a pure function) and consumed by memory retrieval (as an additive
/// boost) and by the context assembler (for recency injection of high-salience summaries).
///
/// The salience system is designed to degrade gracefully: if scoring fails, retrieval still
/// works — just without the identity-relevance boost. Salience never gates access to memory.
public struct SalienceEnvelope: Sendable {
    /// Urgency signal (0-1): pattern-matched from explicit markers, emotional language, questions.
    public let urgency: Float

    /// Identity relevance (0-1): overlap with identity block claim keys and values.
    public let identityRelevance: Float

    /// Mirror relevance (0-1): overlap with mirror block claim keys and values.
    public let mirrorRelevance: Float

    /// Temporal recency (0-1): exponential decay of message age. Always 0.5 at scoring time;
    /// real recency is computed during retrieval.
    public let temporalRecency: Float

    /// Weighted combination of all signals, normalized to 0-1.
    public let composite: Float

    public init(urgency: Float, identityRelevance: Float, mirrorRelevance: Float, temporalRecency: Float, composite: Float) {
        self.urgency = urgency
        self.identityRelevance = identityRelevance
        self.mirrorRelevance = mirrorRelevance
        self.temporalRecency = temporalRecency
        self.composite = composite
    }

    /// Fallback envelope used when salience scoring times out or fails.
    public static let `default` = SalienceEnvelope(
        urgency: 0.5,
        identityRelevance: 0.5,
        mirrorRelevance: 0.5,
        temporalRecency: 0.5,
        composite: 0.5,
    )
}

// MARK: - Identity Types

/// The system's self-knowledge: behavioral principles, values, capabilities, communication style.
///
/// Updated **only during consolidation** (offline process), never during live interaction.
/// Every update is versioned with rationale and triggering evidence, enabling rollback.
///
/// During the bootstrap period (first ~10 sessions), thresholds are lower and claim
/// generation is more aggressive, with claims carrying lower stability scores.
public struct IdentityBlock: Sendable {
    /// The version ID of this identity snapshot.
    public let versionId: VersionID

    /// All active claims in this version.
    public let claims: [IdentityClaim]

    public let createdAt: Date

    /// What created this version: "consolidation", "manual", or "bootstrap".
    public let createdBy: String

    public init(versionId: VersionID, claims: [IdentityClaim], createdAt: Date, createdBy: String) {
        self.versionId = versionId
        self.claims = claims
        self.createdAt = createdAt
        self.createdBy = createdBy
    }

    /// Sentinel value for a freshly initialized system with no identity claims.
    public static let empty = IdentityBlock(
        versionId: 0,
        claims: [],
        createdAt: .distantPast,
        createdBy: "bootstrap",
    )
}

/// A single identity claim with epistemic metadata and evidence tracking.
///
/// Claims follow strict epistemic discipline: single-observation inferences are always
/// `hypothesis`, promotion to `asserted` requires `evidenceDiversity >= 3`, and contradicting
/// evidence lowers confidence rather than silently overwriting.
public struct IdentityClaim: Sendable {
    public let id: Int64

    /// Namespaced key (e.g., `"self.communication_style"`, `"self.values.depth"`).
    public let claimKey: String

    /// The claim content.
    public let value: String

    /// How strongly evidence supports this claim (0-1). Subject to Hebbian decay.
    public let confidence: Float

    /// Epistemic status governing how the claim is treated during consolidation.
    public let epistemicStatus: EpistemicStatus

    /// Number of distinct observations supporting this claim.
    public let evidenceCount: Int

    /// Number of distinct contexts evidence comes from. Promotion to `asserted` requires >= 3.
    public let evidenceDiversity: Int

    /// Half-life for Hebbian confidence decay (days). Identity claims default to 90.
    public let decayHalfLifeDays: Float

    public let createdAt: Date

    /// When evidence last reinforced this claim. Used for decay calculation.
    public let lastReinforcedAt: Date

    public init(id: Int64, claimKey: String, value: String, confidence: Float, epistemicStatus: EpistemicStatus, evidenceCount: Int, evidenceDiversity: Int, decayHalfLifeDays: Float, createdAt: Date, lastReinforcedAt: Date) {
        self.id = id
        self.claimKey = claimKey
        self.value = value
        self.confidence = confidence
        self.epistemicStatus = epistemicStatus
        self.evidenceCount = evidenceCount
        self.evidenceDiversity = evidenceDiversity
        self.decayHalfLifeDays = decayHalfLifeDays
        self.createdAt = createdAt
        self.lastReinforcedAt = lastReinforcedAt
    }
}

/// Per-user model: goals, emotional state, expertise, communication preferences, relationship dynamics.
///
/// Updated during consolidation, with one exception: explicit user corrections (e.g., "No, I
/// actually prefer X") are applied immediately via ``IdentityStoring/applyExplicitCorrection(_:for:)``.
/// The user is the authority on themselves.
///
/// Higher volatility expected than identity (people change faster than values). Same versioning
/// and rollback as identity. Per-user, not per-channel — one mirror per human across transport layers.
public struct MirrorBlock: Sendable {
    public let versionId: VersionID
    public let userKey: UserKey
    public let claims: [MirrorClaim]
    public let createdAt: Date
    public let createdBy: String

    public init(versionId: VersionID, userKey: UserKey, claims: [MirrorClaim], createdAt: Date, createdBy: String) {
        self.versionId = versionId
        self.userKey = userKey
        self.claims = claims
        self.createdAt = createdAt
        self.createdBy = createdBy
    }

    /// Sentinel value for a user with no mirror claims yet.
    public static func empty(for userKey: UserKey) -> MirrorBlock {
        MirrorBlock(
            versionId: 0,
            userKey: userKey,
            claims: [],
            createdAt: .distantPast,
            createdBy: "bootstrap",
        )
    }
}

/// A single mirror claim about a user, with the same epistemic structure as identity claims.
///
/// Mirror claims have a shorter default decay half-life (60 days vs 90) because
/// user preferences and state change faster than core identity.
public struct MirrorClaim: Sendable {
    public let id: Int64

    /// Namespaced key (e.g., `"mirror.user.expertise"`, `"mirror.user.communication_style"`).
    public let claimKey: String

    public let value: String
    public let confidence: Float
    public let epistemicStatus: EpistemicStatus
    public let evidenceCount: Int
    public let evidenceDiversity: Int

    /// Half-life for Hebbian confidence decay (days). Mirror claims default to 60.
    public let decayHalfLifeDays: Float

    public let createdAt: Date
    public let lastReinforcedAt: Date

    public init(id: Int64, claimKey: String, value: String, confidence: Float, epistemicStatus: EpistemicStatus, evidenceCount: Int, evidenceDiversity: Int, decayHalfLifeDays: Float, createdAt: Date, lastReinforcedAt: Date) {
        self.id = id
        self.claimKey = claimKey
        self.value = value
        self.confidence = confidence
        self.epistemicStatus = epistemicStatus
        self.evidenceCount = evidenceCount
        self.evidenceDiversity = evidenceDiversity
        self.decayHalfLifeDays = decayHalfLifeDays
        self.createdAt = createdAt
        self.lastReinforcedAt = lastReinforcedAt
    }
}

/// Epistemic status of a claim, governing how it's treated during consolidation.
public nonisolated enum EpistemicStatus: String, Sendable, CaseIterable {
    /// Initial state: single-observation inferences. Cannot be promoted without diverse evidence.
    case hypothesis

    /// Promoted after `evidenceDiversity >= 3`. Treated as established knowledge.
    case asserted

    /// Contradicted by strong, diverse evidence. Kept for audit trail — records what was learned.
    case rejected
}

/// Specifies whether a claim operation targets the identity block or a specific user's mirror.
public nonisolated enum ClaimTarget: Sendable {
    /// Target the system's self-knowledge (identity block).
    case identity

    /// Target a specific user's mirror block.
    case mirror(UserKey)
}

/// A candidate claim produced by the consolidation engine's claim extraction step.
///
/// These are proposals that go through the merge process: reinforcing existing claims,
/// creating new hypotheses, or lowering confidence on contradicted claims.
public struct ClaimCandidate: Sendable {
    public let claimKey: String
    public let value: String
    public let confidence: Float
    public let evidenceType: EvidenceType
    public let excerpt: String?
    public let nodeId: NodeID?

    public init(claimKey: String, value: String, confidence: Float, evidenceType: EvidenceType, excerpt: String?, nodeId: NodeID?) {
        self.claimKey = claimKey
        self.value = value
        self.confidence = confidence
        self.evidenceType = evidenceType
        self.excerpt = excerpt
        self.nodeId = nodeId
    }
}

/// How a piece of evidence supports or contradicts a claim.
public nonisolated enum EvidenceType: String, Sendable, CaseIterable {
    /// Verbatim quote from the user or system.
    case directQuote = "direct_quote"

    /// Inferred from observed behavior patterns.
    case behavior

    /// Logical inference from context.
    case inference

    /// User explicitly stated this about themselves.
    case explicitStatement = "explicit_statement"
}

/// An immediate correction to the mirror block, bypassing the consolidation queue.
///
/// Used when the user explicitly corrects a belief about themselves (e.g., "No, I actually
/// prefer X over Y"). The user is the authority on themselves.
public struct MirrorCorrection: Sendable {
    /// The claim key to update.
    public let claimKey: String

    /// The corrected value.
    public let newValue: String

    /// Why this correction was made (for the version audit trail).
    public let rationale: String

    public init(claimKey: String, newValue: String, rationale: String) {
        self.claimKey = claimKey
        self.newValue = newValue
        self.rationale = rationale
    }
}

// MARK: - Chronoception Types

/// The system's qualitative experience of time passing between sessions.
///
/// The difference between resuming after five minutes and reconnecting after a week is
/// qualitative, not quantitative. Each mode triggers different behavioral responses.
public nonisolated enum TemporalMode: String, Sendable, CaseIterable {
    /// Gap < 1 hour: resume naturally, no acknowledgment needed.
    case continuation

    /// Gap 1-24 hours: brief acknowledgment of the gap.
    case softReconnection

    /// Gap 1-7 days: check in, context cooling applied to stale topics.
    case reconnection

    /// Gap > 7 days: longer re-establishment, may need to rebuild context.
    case reunion

    /// First interaction ever with this user. Triggers bootstrap behavior.
    case newSession
}

// MARK: - Allostasis Types

/// The system's adaptive response mode based on resource pressure.
///
/// Computed from remaining token budget, recent API latency, error rate, and worker queue
/// pressure. Partially persists across sessions so the system remembers being under pressure.
public nonisolated enum AllostasisMode: String, Sendable, CaseIterable {
    /// Low pressure, ample budget: full retrieval, verbose responses, proactive memory search.
    case exploratory

    /// Normal operation: standard retrieval depth, normal verbosity.
    case balanced

    /// High pressure: reduced retrieval, concise responses, defer non-essential work.
    case conservative

    /// Critical: minimal retrieval, short responses, no worker dispatch.
    case recovery
}

// MARK: - Worker Types

/// A self-contained task dispatched from the coordinator to a worker agent.
///
/// Workers contain context explosion — they handle procedural execution (tool use, debugging,
/// code writing) so the coordinator never sees raw tool output. Workers return compressed
/// summaries (400-800 tokens) via ``WorkerSummary``.
public struct WorkerTask: Sendable {
    public let runId: WorkerRunID

    /// What the worker should accomplish (natural language goal).
    public let goal: String

    /// Behavioral constraints the worker must observe.
    public let constraints: [String]

    /// Relevant subset of the identity block for the task (not the full block).
    public let identityExcerpt: String

    /// Pre-selected DAG nodes relevant to the task (seed set for memory access).
    public let memoryPointers: [NodeID]

    /// Scoped read-only access to LCM (grep, describe, expand).
    public let delegationGrant: DelegationGrant

    /// Which tools the worker is allowed to use.
    public let toolPolicy: ToolPolicy

    /// Hard cap on token consumption — worker is killed if exceeded.
    public let tokenBudget: Int

    /// Tool registry providing executable tools for the worker's tool loop.
    /// When `nil`, the worker runs in pure inference mode (no tool execution).
    public let toolRegistry: ToolRegistry?

    /// Default working directory for file/process tool operations.
    public let workingDirectory: String

    /// Current recursion depth (0 = coordinator-spawned, increments for sub-workers).
    public let depth: Int

    /// Maximum recursion depth. Workers at `depth >= maxDepth` cannot spawn sub-workers.
    public let maxDepth: Int

    /// The parent's system prompt (identity files) so the worker maintains personality.
    public let parentSystemPrompt: String

    public init(
        runId: WorkerRunID,
        goal: String,
        constraints: [String],
        identityExcerpt: String,
        memoryPointers: [NodeID],
        delegationGrant: DelegationGrant,
        toolPolicy: ToolPolicy,
        tokenBudget: Int,
        toolRegistry: ToolRegistry? = nil,
        workingDirectory: String = NSHomeDirectory(),
        depth: Int = 0,
        maxDepth: Int = 3,
        parentSystemPrompt: String = "",
    ) {
        self.runId = runId
        self.goal = goal
        self.constraints = constraints
        self.identityExcerpt = identityExcerpt
        self.memoryPointers = memoryPointers
        self.delegationGrant = delegationGrant
        self.toolPolicy = toolPolicy
        self.tokenBudget = tokenBudget
        self.toolRegistry = toolRegistry
        self.workingDirectory = workingDirectory
        self.depth = depth
        self.maxDepth = maxDepth
        self.parentSystemPrompt = parentSystemPrompt
    }
}

/// Compressed result of a worker execution, designed to fit in coordinator context.
///
/// Contains structured fields beyond the narrative that feed consolidation:
/// `failedAttempts` provides transparency about process, and `lessons` captures
/// meta-insights that consolidation may crystallize into identity claims.
public struct WorkerSummary: Sendable {
    /// Compressed narrative of what was done and what matters (400-800 tokens).
    public let narrative: String

    /// DAG nodes the worker accessed during execution.
    public let citedMemoryNodes: [NodeID]

    /// Tool invocations with outcomes.
    public let toolsUsed: [ToolInvocation]

    /// Actual token consumption.
    public let tokensBurned: Int

    /// Whether the worker completed, partially completed, or failed.
    public let outcome: WorkerOutcome

    /// What was tried and didn't work — transparency about process.
    public let failedAttempts: [FailedAttempt]

    /// Meta-insights about what was learned during execution. Feeds consolidation with
    /// material for identity/mirror evolution (e.g., "API X requires auth header").
    public let lessons: [String]

    /// Worker's self-assessed confidence in its output (0-1).
    public let confidence: Float

    public init(narrative: String, citedMemoryNodes: [NodeID], toolsUsed: [ToolInvocation], tokensBurned: Int, outcome: WorkerOutcome, failedAttempts: [FailedAttempt], lessons: [String], confidence: Float) {
        self.narrative = narrative
        self.citedMemoryNodes = citedMemoryNodes
        self.toolsUsed = toolsUsed
        self.tokensBurned = tokensBurned
        self.outcome = outcome
        self.failedAttempts = failedAttempts
        self.lessons = lessons
        self.confidence = confidence
    }
}

/// A record of something the worker tried that didn't work.
///
/// These feed consolidation — knowing what failed is as valuable as knowing what succeeded.
public struct FailedAttempt: Sendable {
    public let description: String
    public let reason: String

    public init(description: String, reason: String) {
        self.description = description
        self.reason = reason
    }
}

/// The terminal status of a worker execution.
public nonisolated enum WorkerOutcome: Sendable {
    /// Worker achieved its goal.
    case completed

    /// Worker made progress but couldn't fully achieve the goal.
    case partial(reason: String)

    /// Worker's token budget was exhausted before completion. Partial summary returned.
    case budgetExhausted

    /// Worker encountered an unrecoverable error.
    case failed(CIMSError)
}

/// Scoped, time-limited read access to LCM, issued to a worker by the coordinator.
///
/// Workers never write to the DAG — they only read via delegation grants. The coordinator
/// creates a grant when dispatching a worker and revokes it on completion.
public struct DelegationGrant: Sendable {
    public let grantId: GrantID

    /// Which conversations the worker can search.
    public let conversationScope: ConversationScope

    /// Maximum tokens the worker can retrieve.
    public let tokenCap: Int

    /// Tokens consumed so far against the cap.
    public let tokensUsed: Int

    /// Permitted operations (grep, describe, expand).
    public let operations: [DelegationOperation]

    public let createdAt: Date

    /// Grant expires after this time (prevents stale worker access).
    public let expiresAt: Date

    /// Set when the grant is revoked (on worker completion or timeout).
    public let revokedAt: Date?

    /// The worker run that holds this grant.
    public let workerRunId: WorkerRunID?

    public init(grantId: GrantID, conversationScope: ConversationScope, tokenCap: Int, tokensUsed: Int, operations: [DelegationOperation], createdAt: Date, expiresAt: Date, revokedAt: Date?, workerRunId: WorkerRunID?) {
        self.grantId = grantId
        self.conversationScope = conversationScope
        self.tokenCap = tokenCap
        self.tokensUsed = tokensUsed
        self.operations = operations
        self.createdAt = createdAt
        self.expiresAt = expiresAt
        self.revokedAt = revokedAt
        self.workerRunId = workerRunId
    }
}

/// Scope of conversations a delegation grant permits access to.
public nonisolated enum ConversationScope: Sendable {
    /// Access to all conversations.
    case all

    /// Access restricted to specific conversation IDs.
    case conversations([ConversationID])
}

/// Read-only operations a worker can perform via a delegation grant.
public nonisolated enum DelegationOperation: String, Sendable, CaseIterable {
    /// Full-text or regex search across messages and summaries.
    case grep

    /// Fetch a node's full description (metadata + content preview).
    case describe

    /// Expand compressed nodes to see full detail.
    case expand
}

/// Specifies the scope and constraints for a new delegation grant.
public struct DelegationScope: Sendable {
    public let conversationScope: ConversationScope
    public let operations: [DelegationOperation]

    /// Optional token cap override; defaults to ``CIMSDefaults/workerDefaultBudget``.
    public let tokenCap: Int?

    public init(conversationScope: ConversationScope, operations: [DelegationOperation], tokenCap: Int?) {
        self.conversationScope = conversationScope
        self.operations = operations
        self.tokenCap = tokenCap
    }
}

/// Controls which tools a worker is allowed to use during execution.
public nonisolated enum ToolPolicy: Sendable {
    /// Worker can use any available tool.
    case all

    /// Worker can only use the named tools.
    case allowed([String])

    /// Worker has no tool access (pure inference only).
    case none
}

/// Record of a single tool invocation during worker execution.
public struct ToolInvocation: Sendable {
    public let name: String
    public let arguments: String?
    public let result: String?
    public let outcome: ToolOutcome

    public init(name: String, arguments: String?, result: String?, outcome: ToolOutcome) {
        self.name = name
        self.arguments = arguments
        self.result = result
        self.outcome = outcome
    }
}

/// Result of a tool invocation.
public nonisolated enum ToolOutcome: String, Sendable {
    case success
    case failure
    case timeout
}

// MARK: - Model Types

/// Capability tier for model selection, enabling budget-driven downgrade.
///
/// Different components use different tiers: the coordinator uses `executive` (highest
/// capability), workers use `workerDefault` or `workerLight`, and offline processes use
/// `consolidation`. Under budget pressure, the system downgrades progressively.
public nonisolated enum ModelTier: Sendable {
    /// T0: coordinator inference — highest capability, long context (Opus-class).
    case executive

    /// T1: standard worker tasks — capable, cost-effective for tool loops (Sonnet-class).
    case workerDefault

    /// T2: simple/repetitive worker tasks — lighter model.
    case workerLight

    /// T3: offline claim extraction and summarization — reflective, doesn't need speed.
    case consolidation

    /// T4: future — if salience ever moves from heuristics to model-based scoring.
    case salience
}

/// Complete response from a model inference call.
public struct ModelResponse: Sendable {
    public let content: String
    public let toolCalls: [ToolCall]
    public let tokenUsage: TokenUsage
    public let latency: Duration

    /// The API stop reason: `"end_turn"`, `"tool_use"`, or `"max_tokens"`.
    public let stopReason: String

    public init(
        content: String,
        toolCalls: [ToolCall],
        tokenUsage: TokenUsage,
        latency: Duration,
        stopReason: String = "end_turn",
    ) {
        self.content = content
        self.toolCalls = toolCalls
        self.tokenUsage = tokenUsage
        self.latency = latency
        self.stopReason = stopReason
    }
}

/// A single incremental update during streaming model inference.
public struct ModelDelta: Sendable {
    /// Incremental text content, if this delta contains text.
    public let text: String?

    /// A tool call, if this delta contains a tool invocation.
    public let toolCall: ToolCall?

    /// Stop reason from the `message_delta` event, if this is a sentinel delta.
    /// Only set on the final delta of a streaming response.
    public let stopReason: String?

    public init(text: String?, toolCall: ToolCall?, stopReason: String? = nil) {
        self.text = text
        self.toolCall = toolCall
        self.stopReason = stopReason
    }
}

/// A tool call requested by the model during inference.
public struct ToolCall: Sendable {
    /// The tool_use block ID from the API, used for tool_result correlation.
    public let id: String

    public let name: String

    /// JSON-encoded arguments for the tool.
    public let arguments: String

    public init(id: String = "", name: String, arguments: String) {
        self.id = id
        self.name = name
        self.arguments = arguments
    }
}

/// Token consumption breakdown for a model inference call.
///
/// Includes Anthropic prompt caching stats when available. Cache tokens
/// indicate how much of the input prefix was served from KV cache
/// (`cacheReadTokens`) versus freshly computed and stored (`cacheCreationTokens`).
public struct TokenUsage: Sendable {
    public let inputTokens: Int
    public let outputTokens: Int

    /// Tokens read from the prompt cache (prefix match — free input).
    public let cacheReadTokens: Int

    /// Tokens computed and written to the prompt cache for future reuse.
    public let cacheCreationTokens: Int

    public init(inputTokens: Int, outputTokens: Int, cacheReadTokens: Int = 0, cacheCreationTokens: Int = 0) {
        self.inputTokens = inputTokens
        self.outputTokens = outputTokens
        self.cacheReadTokens = cacheReadTokens
        self.cacheCreationTokens = cacheCreationTokens
    }

    /// Combined input + output tokens.
    public var total: Int {
        inputTokens + outputTokens
    }

    /// Fraction of total input tokens served from cache (0.0–1.0).
    ///
    /// Total = inputTokens + cacheReadTokens + cacheCreationTokens.
    /// `inputTokens` only counts non-cached tokens; cache tokens are separate.
    public var cacheHitRate: Double {
        let total = inputTokens + cacheReadTokens + cacheCreationTokens
        guard total > 0 else { return 0 }
        return Double(cacheReadTokens) / Double(total)
    }
}

/// The result of executing a tool call, used to send `tool_result` blocks back to the API.
public struct ToolCallResult: Sendable {
    /// The `tool_use` block ID this result corresponds to.
    public let toolUseId: String

    /// The textual content of the result.
    public let content: String

    /// Whether the tool execution encountered an error.
    public let isError: Bool

    public init(toolUseId: String, content: String, isError: Bool = false) {
        self.toolUseId = toolUseId
        self.content = content
        self.isError = isError
    }
}

/// A single iteration of the tool loop: the assistant's response (with tool calls)
/// and the corresponding tool results.
///
/// Collected during the coordinator's tool loop and passed to ``MemoryStoring/ingestTurn``
/// for persisting the full tool call history as structured message parts.
public struct ToolTurnRecord: Sendable {
    /// The assistant's text content for this iteration (may be empty).
    public let assistantText: String

    /// The tool calls the assistant made in this iteration.
    public let toolCalls: [ToolCall]

    /// The results from executing each tool call.
    public let toolResults: [ToolCallResult]

    public init(assistantText: String, toolCalls: [ToolCall], toolResults: [ToolCallResult]) {
        self.assistantText = assistantText
        self.toolCalls = toolCalls
        self.toolResults = toolResults
    }
}

/// The fully assembled context ready for model inference.
///
/// Produced by ``ContextAssembler``, ordered by volatility (least-changing content at the
/// head for KV cache efficiency, most-changing at the tail).
public struct AssembledContext: Sendable {
    /// Ordered sections from head (system prompt) to tail (fresh tail).
    public let sections: [ContextSection]

    /// Total estimated tokens across all sections.
    public let totalTokens: Int

    /// Raw fresh tail messages for providers that need structured message arrays
    /// (e.g., Anthropic's alternating user/assistant turns). Populated alongside the
    /// rendered `.freshTail` section so both token estimation and structured access work.
    public let freshTailMessages: [StoredMessage]

    /// The current user message text, if present. This is the message being processed
    /// in the current turn — it's not yet in the fresh tail (which contains history).
    public let currentMessageText: String?

    /// Image attachments from the current user message, for vision API content blocks.
    public let currentMessageImages: [ImageAttachment]

    public init(sections: [ContextSection], totalTokens: Int, freshTailMessages: [StoredMessage] = [], currentMessageText: String? = nil, currentMessageImages: [ImageAttachment] = []) {
        self.sections = sections
        self.totalTokens = totalTokens
        self.freshTailMessages = freshTailMessages
        self.currentMessageText = currentMessageText
        self.currentMessageImages = currentMessageImages
    }

    /// Create a minimal context for testing — just a system prompt and user message.
    ///
    /// Bypasses the full context assembly pipeline. Useful for CLI diagnostics
    /// and API connectivity tests.
    public static func minimal(systemPrompt: String, userMessage: String) -> AssembledContext {
        AssembledContext(
            sections: [ContextSection(kind: .systemPrompt, content: systemPrompt, tokenEstimate: systemPrompt.count / 4)],
            totalTokens: (systemPrompt.count + userMessage.count) / 4,
            currentMessageText: userMessage,
        )
    }
}

/// A single section of the assembled context with its kind and token cost.
public struct ContextSection: Sendable {
    public let kind: ContextSectionKind
    public let content: String
    public let tokenEstimate: Int

    public init(kind: ContextSectionKind, content: String, tokenEstimate: Int) {
        self.kind = kind
        self.content = content
        self.tokenEstimate = tokenEstimate
    }
}

/// Identifies the kind of a context section for ordering and budget allocation.
///
/// ``PromptBuilder`` places sections into three cache tiers based on volatility:
///
/// **System blocks** (stable — entire array cached as one unit):
/// - `stableSummaries` / `summaries` — condensed DAG nodes, frozen history
/// - `recentSummaries` — leaf/leaf_summary nodes, change on compaction
/// - `systemPrompt` — SOUL.md, IDENTITY.md, etc. (last system block)
///
/// **First user message** (slow-changing — cached by message-level breakpoint):
/// - `identity` — serialized identity claims, change on consolidation
/// - `mirror` — serialized mirror claims, change on consolidation
/// - `cognitiveState` — allostasis mode, memory health
///
/// **Current user message** (per-turn — never cached):
/// - `chronoception` — session duration, gap, temporal mode (contains timestamps)
/// - `temporalGrounding` — current time, session info (contains timestamps)
public nonisolated enum ContextSectionKind: String, Sendable {
    /// The system prompt — changes never after initialization. Last system block.
    case systemPrompt

    /// Serialized identity claims — changes on consolidation. Injected into first user message.
    case identity

    /// Serialized mirror claims — changes on consolidation. Injected into first user message.
    case mirror

    /// Memory summaries, oldest to newest — changes on compaction. System block.
    case summaries

    /// System self-awareness: allostasis mode, memory health. Injected into first user message.
    case cognitiveState

    /// Temporal state with timestamps — changes every turn. Injected into current user message.
    case chronoception

    /// Older messages bridged verbatim into context because they're thread-relevant.
    case bridgedContext

    /// Last N raw messages — changes every turn.
    case freshTail

    /// The current user message being processed — the final user turn in the messages array.
    case currentMessage

    /// Stable (old) summaries — condensed DAG nodes. System block.
    case stableSummaries

    /// Recent summaries — leaf/leaf_summary nodes. System block.
    case recentSummaries

    /// Temporal grounding with timestamps — changes every turn. Injected into current user message.
    case temporalGrounding
}

// MARK: - Turn Types

/// A request to run a single turn of the cognitive cycle.
///
/// Submitted to ``CIMSCoordinating/runTurn(_:)`` and flows through the turn state machine.
public struct TurnRequest: Sendable {
    public let turnID: TurnID
    public let sessionKey: SessionKey
    public let userKey: UserKey
    public let message: InboundMessage
    public let receivedAt: Date

    /// Whether to stream response deltas during inference.
    ///
    /// When `true`, the coordinator calls ``ModelProviding/stream(_:tier:tools:)`` and yields
    /// ``TurnEvent/delta(_:)`` events for each incremental model delta. The full response is
    /// still accumulated and yielded as ``TurnEvent/responseCompleted(_:)`` at the end.
    ///
    /// When `false` (the default), the coordinator calls ``ModelProviding/complete(_:tier:tools:)``
    /// and yields the full response as a single ``TurnEvent/responseDelta(_:)`` event.
    public let streaming: Bool

    /// Current auto-continuation depth. 0 for normal turns.
    /// Continuation turns set this to `parentDepth + 1`.
    public let continuationDepth: Int

    /// Creates a turn request with all parameters.
    ///
    /// - Parameters:
    ///   - turnID: Unique identifier for this turn.
    ///   - sessionKey: Identifies the conversation session.
    ///   - userKey: Identifies the human user.
    ///   - message: The inbound user message.
    ///   - receivedAt: When the message was received.
    ///   - streaming: Whether to stream response deltas. Defaults to `false`.
    ///   - continuationDepth: Auto-continuation depth. Defaults to `0`.
    public nonisolated init(
        turnID: TurnID,
        sessionKey: SessionKey,
        userKey: UserKey,
        message: InboundMessage,
        receivedAt: Date,
        streaming: Bool = false,
        continuationDepth: Int = 0,
    ) {
        self.turnID = turnID
        self.sessionKey = sessionKey
        self.userKey = userKey
        self.message = message
        self.receivedAt = receivedAt
        self.streaming = streaming
        self.continuationDepth = continuationDepth
    }
}

/// Events emitted during a cognitive turn, delivered via `AsyncThrowingStream`.
///
/// The coordinator emits these as the turn progresses: acknowledgment, thinking indicator,
/// streaming response deltas, worker dispatches/completions, and final response.
public nonisolated enum TurnEvent: Sendable {
    /// Turn has been received and queued for processing.
    case acknowledged(TurnID)

    /// Coordinator is thinking (context assembly, retrieval in progress).
    case thinking

    /// Incremental response text from the coordinator's inference.
    case responseDelta(String)

    /// A worker has been dispatched for procedural execution.
    case workerDispatched(WorkerRunID)

    /// A worker has completed and returned its summary.
    case workerCompleted(WorkerRunID, WorkerSummary)

    /// The complete final response text.
    case responseCompleted(String)

    /// A partial response delta during streaming inference.
    ///
    /// Only emitted when ``TurnRequest/streaming`` is `true`. Each delta contains either
    /// incremental text or a tool call from the model's streaming output. Callers can use
    /// these for real-time display while the full response is still being generated.
    case delta(ModelDelta)

    /// A hold signal indicating latency (e.g., "Let me check..." during cold storage retrieval).
    case hold(String)

    /// A tool call has completed with a result.
    case toolResult(ToolCallResult)

    /// A tool call was moved to the background after exceeding the timeout.
    case toolBackgrounded(BackgroundToolInfo)

    /// A previously backgrounded tool completed.
    case toolBackgroundCompleted(toolCallId: String, content: String, elapsed: Duration)

    /// A previously backgrounded tool was cancelled (stop word, hang, or turn end).
    case toolBackgroundCancelled(toolCallId: String, reason: String)

    /// The turn hit the tool iteration limit and needs auto-continuation.
    case continuationNeeded(depth: Int)

    /// A fork was dispatched for parallel execution.
    case forkDispatched(String)

    /// An error occurred during the turn.
    case error(CIMSError)
}

/// A tool call that exceeded its timeout and continues running in the background.
public struct BackgroundToolInfo: Sendable {
    /// The original tool call ID for correlation.
    public let toolCallId: String

    /// Human-readable tool name.
    public let toolName: String

    /// A summary of what the tool was asked to do (e.g., first 100 chars of bash command).
    public let taskSummary: String

    /// When the tool started executing.
    public let startedAt: ContinuousClock.Instant

    public init(toolCallId: String, toolName: String, taskSummary: String, startedAt: ContinuousClock.Instant) {
        self.toolCallId = toolCallId
        self.toolName = toolName
        self.taskSummary = taskSummary
        self.startedAt = startedAt
    }
}

/// Result of a background process completing.
///
/// Posted to the event queue by ``ProcessMonitor`` when a tracked process exits.
/// The EventLoop injects the result into the agent's next turn as context.
public struct ProcessCompletion: Sendable {
    /// Unique process identifier assigned at spawn time.
    public let processId: String

    /// The command that was executed (for display).
    public let command: String

    /// Process exit code (0 = success).
    public let exitCode: Int32

    /// Last 50 lines of stdout/stderr output.
    public let tailOutput: String

    /// Wall-clock duration from spawn to exit.
    public let elapsed: Duration

    public init(processId: String, command: String, exitCode: Int32, tailOutput: String, elapsed: Duration) {
        self.processId = processId
        self.command = command
        self.exitCode = exitCode
        self.tailOutput = tailOutput
        self.elapsed = elapsed
    }
}

/// Result of a fork completing — the collapsed final response.
///
/// Posted to the event queue when a fork turn finishes. Only the final
/// response text survives — intermediate tool calls are ephemeral.
public struct ForkResult: Sendable {
    /// Unique fork identifier.
    public let forkId: String

    /// The goal the fork was dispatched to accomplish.
    public let goal: String

    /// Discord channel ID for routing the merge notification.
    public let channelId: String

    /// The fork's final response text (collapsed — no tool history).
    public let response: String

    /// Number of tool calls the fork made (metrics only).
    public let toolCallCount: Int

    /// Wall-clock duration of the fork turn.
    public let elapsed: Duration

    public init(forkId: String, goal: String, channelId: String, response: String, toolCallCount: Int, elapsed: Duration) {
        self.forkId = forkId
        self.goal = goal
        self.channelId = channelId
        self.response = response
        self.toolCallCount = toolCallCount
        self.elapsed = elapsed
    }
}

/// Result of a backgrounded worker completing.
///
/// Posted to the event queue when a worker finishes. The EventLoop
/// injects the summary into the agent's next turn as context.
public struct WorkerCompletion: Sendable {
    /// Worker run identifier.
    public let runId: String

    /// Discord channel ID for routing.
    public let channelId: String

    /// The worker's compressed summary.
    public let summary: WorkerSummary

    /// Wall-clock duration of the worker.
    public let elapsed: Duration

    public init(runId: String, channelId: String, summary: WorkerSummary, elapsed: Duration) {
        self.runId = runId
        self.channelId = channelId
        self.summary = summary
        self.elapsed = elapsed
    }
}

/// Protocol for receiving user interjections during active tool loops.
///
/// The coordinator checks this between tool iterations for stop words
/// and pending messages to inject into the conversation.
/// Observer for turn lifecycle events.
///
/// Replaces `AsyncThrowingStream<TurnEvent>` — the coordinator calls `handleEvent`
/// directly instead of managing a continuation. When `executeTurn` returns, the turn
/// is done. No `finish()` to forget.
///
/// Observers compose: `ConsolidatingObserver` wraps another observer to trigger
/// consolidation scheduling. `DiscordTurnObserver` handles Discord I/O.
public protocol TurnObserver: Sendable {
    /// Called by the coordinator for each turn lifecycle event.
    ///
    /// Events arrive in order: `.acknowledged` → `.thinking` → deltas/tool results →
    /// `.responseCompleted`. The observer should not throw — handle errors internally.
    func handleEvent(_ event: TurnEvent) async
}

public protocol InterjectionSource: Sendable {
    /// Check for and consume a stop-word message. Returns nil if no stop word pending.
    func consumeStopWord() async -> InboundMessage?

    /// Consume all pending messages for injection as interjections.
    func consumePending() async -> [InboundMessage]
}

/// States of the turn state machine that governs the cognitive cycle.
///
/// Transitions are validated — invalid transitions are rejected. Each state has a
/// timeout that triggers graceful degradation rather than hanging.
public nonisolated enum TurnState: String, Sendable, CaseIterable {
    /// Turn received, not yet processed. Immediate transition to `salience`.
    case received

    /// Heuristic salience scoring in progress. Timeout: 500ms → fallback to default envelope.
    case salience

    /// Context assembly from memory + identity + chrono + fresh tail. Timeout: 1s → minimal context.
    case contextBuild

    /// Executive model inference. Timeout: model-dependent → retry once, then error.
    case executiveInfer

    /// Streaming response to the caller. Timeout: 30s inactivity → finalize partial response.
    case streaming

    /// Optional: executing dispatched workers. Timeout: per-worker budget → kill, partial summary.
    case workerExec

    /// Persisting message + DAG updates. Timeout: 2s → log warning, continue.
    case persist

    /// Turn completed successfully.
    case complete

    /// Turn failed with an error.
    case failed
}

// MARK: - Retrieval Types

/// Result of a memory retrieval query, containing summaries and fresh tail messages.
///
/// Produced by ``MemoryStoring/retrieve(query:salienceBoost:limit:)`` and consumed
/// by ``ContextAssembler`` to build the assembled context.
public struct MemoryRetrievalResult: Sendable {
    /// Ranked summary nodes from FTS5 + DAG frontier + salience boost.
    public let summaries: [SummaryNode]

    /// The last N raw messages for conversational continuity.
    public let freshTail: [StoredMessage]

    /// Total tokens across all summaries and fresh tail.
    public let totalTokens: Int

    public init(summaries: [SummaryNode], freshTail: [StoredMessage], totalTokens: Int) {
        self.summaries = summaries
        self.freshTail = freshTail
        self.totalTokens = totalTokens
    }
}

/// Mode for searching memory content.
public nonisolated enum GrepMode: String, Sendable {
    /// FTS5 full-text search with tokenization and ranking.
    case fullText

    /// Raw regex pattern matching against canonical text.
    case regex
}

/// Scope restriction for memory search operations.
public nonisolated enum GrepScope: Sendable {
    /// Search across all conversations.
    case all

    /// Search within a single conversation.
    case conversation(ConversationID)

    /// Search within multiple specific conversations.
    case conversations([ConversationID])
}

/// A single match from a memory search (grep) operation.
public struct GrepMatch: Sendable {
    public let nodeId: NodeID

    /// The matching text excerpt.
    public let excerpt: String

    /// Relevance score from the search engine.
    public let score: Float

    public init(nodeId: NodeID, excerpt: String, score: Float) {
        self.nodeId = nodeId
        self.excerpt = excerpt
        self.score = score
    }
}

// MARK: - Consolidation Types

/// What triggered a consolidation run.
public nonisolated enum ConsolidationTrigger: String, Sendable {
    /// 15 minutes after the last message — routine maintenance.
    case idleTimeout = "idle_timeout"

    /// 5 minutes after the last response — session wrap-up.
    case sessionEnd = "session_end"

    /// Explicitly requested (debugging / forced maintenance).
    case manual

    /// Nightly deep consolidation.
    case scheduled
}

/// Output of the consolidation engine's claim extraction step.
///
/// `nothingSignificant: true` is a valid and common output — most sessions don't produce
/// identity-level insights. The consolidation model should not feel compelled to produce changes.
public struct ConsolidationProposal: Sendable {
    /// Proposed new or updated identity claims.
    public let identityProposals: [ClaimCandidate]

    /// Proposed new or updated mirror claims.
    public let mirrorProposals: [ClaimCandidate]

    /// True when the consolidation model determines nothing is worth crystallizing.
    public let nothingSignificant: Bool

    /// Why these changes were proposed (for the audit trail).
    public let rationale: String

    public init(identityProposals: [ClaimCandidate], mirrorProposals: [ClaimCandidate], nothingSignificant: Bool, rationale: String) {
        self.identityProposals = identityProposals
        self.mirrorProposals = mirrorProposals
        self.nothingSignificant = nothingSignificant
        self.rationale = rationale
    }
}

/// A DAG node flagged during reminiscence bump detection as a moment where understanding shifted.
public struct BumpCandidate: Sendable {
    public let nodeId: NodeID

    /// What made this node stand out.
    public let reason: BumpReason

    /// The salience score at the time of the interaction.
    public let salienceScore: Float

    /// Full content of the node for claim extraction.
    public let content: String

    public init(nodeId: NodeID, reason: BumpReason, salienceScore: Float, content: String) {
        self.nodeId = nodeId
        self.reason = reason
        self.salienceScore = salienceScore
        self.content = content
    }
}

/// Heuristic indicators that a DAG node represents a shift in understanding.
public nonisolated enum BumpReason: String, Sendable {
    /// Topic change combined with high salience score.
    case topicShiftHighSalience = "topic_shift_high_salience"

    /// Evidence of correction or discovery ("I was wrong about...", "I just realized...").
    case correctionOrDiscovery = "correction_or_discovery"

    /// Emotional intensity markers in the interaction.
    case emotionalIntensity = "emotional_intensity"

    /// A new entity (person, concept, project) introduced for the first time.
    case novelEntity = "novel_entity"
}

// MARK: - Error Types

/// Errors that can occur during the CIMS cognitive cycle.
///
/// Designed for graceful degradation — each error case maps to a specific fallback
/// behavior in the turn state machine.
public nonisolated enum CIMSError: Error, Sendable {
    /// A turn state timed out (includes which state for targeted fallback).
    case turnTimeout(TurnState)

    /// The requested model tier is unavailable (API error, rate limit).
    case modelUnavailable(ModelTier)

    /// The model returned an error during inference.
    case modelError(String)

    /// Rate limited (HTTP 429) — credential should be rotated if alternatives exist.
    ///
    /// Carries the `Retry-After` duration in seconds (from the header, or a default)
    /// so the rotation logic knows how long to cool down this credential.
    case rateLimited(retryAfter: TimeInterval, message: String)

    /// A worker exceeded its allocated token budget and was killed.
    case workerBudgetExhausted(WorkerRunID)

    /// A worker encountered an unrecoverable error.
    case workerFailed(WorkerRunID, String)

    /// A delegation grant has expired (TTL exceeded).
    case delegationExpired(GrantID)

    /// A delegation grant was revoked (worker completed or was killed).
    case delegationRevoked(GrantID)

    /// The turn queue is full (exceeds ``CIMSDefaults/maxQueuedTurns``).
    case queueFull

    /// A database operation failed.
    case databaseError(String)

    /// The assembled context exceeds the model's context window (actual, limit).
    case contextOverflow(Int, Int)

    /// An invalid state transition was attempted in the turn state machine.
    case invalidStateTransition(from: TurnState, to: TurnState)

    /// The consolidation engine encountered an error.
    case consolidationFailed(String)

    /// An error occurred during cold storage operations (node ID, description).
    case coldStorageError(NodeID, String)

    /// Prompt cache integrity check failed — cache broken without compaction excuse.
    case cacheIntegrityFailure(String)
}

// MARK: - Tool Definition Types

/// Schema definition for a tool that the coordinator model can invoke during inference.
public nonisolated struct ToolDefinition: Sendable {
    public let name: String
    public let description: String
    public let parameters: [ToolParameter]

    public init(name: String, description: String, parameters: [ToolParameter]) {
        self.name = name
        self.description = description
        self.parameters = parameters
    }
}

/// A single parameter in a tool definition schema.
public nonisolated struct ToolParameter: Sendable {
    public let name: String
    public let type: ToolParameterType
    public let description: String
    public let optional: Bool

    public init(name: String, type: ToolParameterType, description: String, optional: Bool = false) {
        self.name = name
        self.type = type
        self.description = description
        self.optional = optional
    }
}

/// JSON Schema types for tool parameter definitions.
public indirect nonisolated enum ToolParameterType: Sendable {
    case string
    case integer
    /// A JSON boolean (`true`/`false`).
    case boolean
    case array(ToolParameterType)
    case `enum`([String])
    /// A JSON object (unstructured). Used for parameters that accept arbitrary key-value data.
    case object
}

// MARK: - Claim Categories

/// Taxonomy of claim categories for structured knowledge extraction.
///
/// Categories partition the knowledge space into non-overlapping domains that
/// enable targeted retrieval: a preference query need only scan `.preference` claims,
/// an event query need only scan `.event` claims.
public enum ClaimCategory: String, Codable, Sendable, CaseIterable {
    /// Facts about identity: name, role, background, skills, relationships.
    /// Keys: `identity.role`, `identity.background`, `identity.skill.*`
    case identity

    /// Preferences, tastes, and style choices.
    /// Keys: `preference.communication.*`, `preference.tool.*`, `preference.aesthetic.*`
    case preference

    /// Discrete events that happened at a specific time.
    /// Keys: `event.project.*`, `event.life.*`, `event.work.*`
    case event

    /// Corrections or supersessions of previous knowledge.
    /// Keys: `update.*` (mirrors the key of the claim being updated)
    case update

    /// Behavioral patterns observed over multiple interactions.
    /// Keys: `pattern.work.*`, `pattern.communication.*`, `pattern.decision.*`
    case pattern

    /// Relational knowledge about people, projects, or entities.
    /// Keys: `relation.person.*`, `relation.project.*`, `relation.org.*`
    case relation
}

public extension ClaimCategory {
    /// Derive category from a claim key prefix.
    ///
    /// Handles both new taxonomy keys (`preference.communication.direct`) and legacy
    /// keys (`self.communication_style`, `mirror.expertise.swift`).
    ///
    /// - Parameter key: The claim key string (e.g., `"preference.tool.neovim"`).
    /// - Returns: The inferred category, or `nil` if the prefix is unrecognized.
    static func from(key: String) -> ClaimCategory? {
        let segments = key.split(separator: ".").map(String.init)
        guard let first = segments.first else { return nil }

        // New taxonomy: first segment is the category directly
        if let direct = ClaimCategory(rawValue: first) {
            return direct
        }

        // Legacy "self.*" keys
        if first == "self" {
            guard segments.count >= 2 else { return .identity }
            let second = segments[1].lowercased()
            if ["preference", "likes", "dislikes", "taste"].contains(second) { return .preference }
            if ["communication", "communication_style", "style", "behavior"].contains(second) { return .pattern }
            if ["values", "traits", "personality"].contains(second) { return .identity }
            return .identity // safe default
        }

        // Legacy "mirror.*" keys
        if first == "mirror" { return .relation }

        return nil
    }
}
