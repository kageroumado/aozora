import Foundation

/// Configuration constants for the CIMS cognitive architecture.
///
/// These are the default values used throughout the system. They're defined as static
/// constants for easy reference and potential future configurability. All values are
/// derived from the engineering spec with consideration for practical performance.
public nonisolated enum CIMSDefaults {
    // MARK: - Memory / LCM

    /// Minimum number of meaningful messages (user + non-empty assistant) that are
    /// never compacted. Tool result messages within this window are also preserved.
    public static let protectedTailCount = 200

    /// τ_soft: frontier token count above which async leaf compaction triggers after each turn.
    public static let softThreshold = 300_000

    /// τ_hard: assembled context token count above which blocking full sweep runs before inference.
    public static let hardThreshold = 500_000

    /// Raw token threshold that triggers leaf compaction (depth 0 → 1).
    /// When raw tokens outside the fresh tail exceed this, a leaf pass runs.
    public static let leafChunkTokens = 20_000

    /// Maximum token budget for leaf summaries (actual size is dynamic, 1500-4000).
    public static let leafTargetTokensMax = 4_000

    /// Target token count for condensed summaries (~1500-2000 tokens).
    public static let condensedTargetTokens = 2_000

    /// Size-tiered tool result aging: turns before stubbing based on token count.
    /// Larger results decay faster — a 25K file read is dead weight after ~10 turns,
    /// but small command outputs (100-500 tokens) are cheap to keep a bit longer.
    ///
    /// **Elastic cache design:** Aging tiers are set ABOVE the cache boundary by
    /// ``cacheBoundaryElasticGap`` turns. Messages get aged *before* they reach the
    /// boundary, so by the time they enter the cached prefix their content is already
    /// stable. The boundary stays at a fixed position for `elasticGap` turns, then
    /// jumps forward in a batch. This gives ~100% cache hits between jumps.
    ///
    /// Example with gap=6, boundary=32: aging at 38, boundary at 32.
    /// Turns 1-6: boundary stays put, new messages accumulate, cache hits.
    /// Turn 7: boundary jumps, one cache miss, then stable again.
    public static let toolAgingTierXL = 16 // > 25K tokens
    public static let toolAgingTierL = 22 // > 10K tokens
    public static let toolAgingTierM = 30 // > 5K tokens
    public static let toolAgingTierS = 38 // > 200 tokens (small results)

    /// Token threshold below which tool results are NEVER aged.
    ///
    /// Tiny results like `echo hi` → `"hi\n"` cost ~5 tokens to keep but would cause
    /// a cache miss (~200K tokens re-written) if aged. The cost of keeping them forever
    /// is negligible; the cost of aging them is enormous.
    public static let toolAgingExemptThreshold = 200

    /// The cache boundary position: meaningful turns from the end where the main
    /// `cache_control` breakpoint is placed. Content before this is the cached prefix.
    ///
    /// Set below ``toolAgingTierS`` by ``cacheBoundaryElasticGap`` so messages are
    /// fully aged before entering the cached region. The boundary only moves when
    /// the gap is consumed by new turns.
    public static let cacheBoundaryTurns = 32

    /// Gap between aging and cache boundary. Determines how many turns the boundary
    /// stays stable before jumping. Higher = more cache hits, but more un-aged content
    /// sitting between the aging tier and the boundary.
    public static let cacheBoundaryElasticGap = 6

    /// Third cache breakpoint: placed this many meaningful turns from the end.
    /// Content between the aging boundary and this point is stable between
    /// consecutive turns — already aged, no timestamps, same content. Only the last
    /// few turns are truly fresh. Anthropic allows up to 4 breakpoints.
    public static let cacheNearEndTurns = 4

    /// Token threshold above which file content is intercepted and stored separately.
    /// Prevents a single large paste from consuming the entire context budget.
    public static let largeFileTokenThreshold = 25_000

    // MARK: - Workers

    /// Maximum tokens for a worker's compressed summary narrative.
    public static let workerSummaryMaxTokens = 4_000

    /// Default token budget allocated to a worker task.
    public static let workerDefaultBudget = 50_000

    /// Maximum number of workers running concurrently across all users.
    public static let maxConcurrentWorkers = 4

    /// Maximum number of concurrent workers per individual user.
    public static let maxWorkersPerUser = 1

    /// Time-to-live for delegation grants. Prevents stale worker access to LCM.
    public static let delegationGrantTTL: Duration = .seconds(300)

    // MARK: - Consolidation

    /// Idle time after the last message before routine consolidation triggers.
    public static let consolidationIdleTimeout: Duration = .seconds(900)

    /// Delay after the last response before session-end consolidation triggers.
    public static let consolidationSessionEndDelay: Duration = .seconds(300)

    // MARK: - Hebbian Decay

    /// Minimum confidence floor — claims never decay below this.
    /// Ensures claims remain discoverable even without reinforcement.
    public static let hebbianDecayFloor: Float = 0.05

    /// Maximum confidence cap — claims never exceed this.
    public static let hebbianDecayCap: Float = 1.0

    /// Hotness threshold below which nodes become cold storage candidates.
    public static let coldStorageHotnessThreshold: Float = 0.1

    /// Age threshold (days) for cold storage eligibility. Nodes must also be below
    /// ``coldStorageHotnessThreshold`` to be demoted.
    public static let coldStorageAgeDays = 30

    /// Half-life for node hotness decay in days. After this many days without access,
    /// a node's hotness drops to half its previous value via exponential decay.
    public static let hotnessDecayHalfLifeDays: Double = 30

    /// Minimum floor for hotness decay. Nodes never decay below this value,
    /// ensuring they remain discoverable for cold storage eligibility checks.
    public static let hotnessDecayFloor: Double = 0.01

    /// Hotness increment applied when a node is accessed (retrieved, expanded, or described).
    /// Capped at 1.0 to prevent unbounded growth.
    public static let hotnessAccessBump: Double = 0.1

    /// Default decay half-life for identity claims (days). Identity changes slowly.
    public static let identityClaimDecayHalfLifeDays: Float = 90

    /// Default decay half-life for mirror claims (days). People change faster than values.
    public static let mirrorClaimDecayHalfLifeDays: Float = 60

    // MARK: - Salience Weights

    /// Weight for the urgency signal in composite salience scoring.
    public static let salienceUrgencyWeight: Float = 0.3

    /// Weight for the identity relevance signal in composite salience scoring.
    public static let salienceIdentityWeight: Float = 0.3

    /// Weight for the mirror relevance signal in composite salience scoring.
    public static let salienceMirrorWeight: Float = 0.2

    /// Weight for the temporal recency signal in composite salience scoring.
    public static let salienceRecencyWeight: Float = 0.2

    // MARK: - Allostasis

    /// Pressure threshold below which the system enters exploratory mode.
    public static let allostasisExploratoryThreshold: Float = 0.3

    /// Pressure threshold above which the system enters conservative mode.
    public static let allostasisConservativeThreshold: Float = 0.7

    /// Pressure threshold above which the system enters recovery mode.
    public static let allostasisRecoveryThreshold: Float = 0.9

    // MARK: - Bootstrap

    /// Number of sessions before the system exits the bootstrap period.
    /// During bootstrap, claim generation thresholds are lower and claims carry
    /// lower stability scores.
    public static let bootstrapSessionCount = 10

    // MARK: - Turn Queue

    /// Maximum number of turns that can be queued globally.
    /// Prevents unbounded memory growth under load.
    public static let maxQueuedTurns = 128

    // MARK: - Context Budget

    /// Default total token budget for the assembled context.
    /// Opus 4.6 and Sonnet 4.6 support 1M context windows.
    public static let defaultContextBudget = 1_000_000

    /// Default maximum number of summary nodes to retrieve.
    public static let defaultRetrievalBudget = 100

    // MARK: - Context Section Budgets

    /// Token allocation budgets for each context section.
    ///
    /// Each section has min/target/max allocations. The assembler fills in priority order:
    /// system prompt (highest) → identity → mirror → fresh tail → chronoception →
    /// cognitive state → summaries (lowest, absorbs remaining budget).
    public enum ContextBudgets {
        /// Min/target/max token allocation for a context section.
        public struct SectionBudget: Sendable {
            /// Minimum tokens — always allocated. If total min > budget, degrade from lowest priority.
            public let min: Int

            /// Target tokens — allocated in priority order from highest to lowest.
            public let target: Int

            /// Maximum tokens — hard cap for this section.
            public let max: Int

            public init(min: Int, target: Int, max: Int) {
                self.min = min
                self.target = target
                self.max = max
            }
        }

        /// Priority 2: Identity block — changes only on consolidation.
        public static let identity = SectionBudget(min: 2_000, target: 15_000, max: 30_000)

        /// Priority 3: Mirror block — changes on consolidation + corrections.
        public static let mirror = SectionBudget(min: 500, target: 5_000, max: 10_000)

        /// Priority 4: Fresh tail — last N raw messages, changes every turn.
        /// With 1M context, we can afford to keep the full recent conversation.
        public static let freshTail = SectionBudget(min: 50_000, target: 400_000, max: 600_000)

        /// Priority 5: Chronoception — session duration, temporal mode.
        public static let chronoception = SectionBudget(min: 200, target: 500, max: 1_000)

        /// Priority 6: Cognitive state — allostasis, memory health, bootstrap status.
        public static let cognitiveState = SectionBudget(min: 100, target: 300, max: 600)
    }

    // MARK: - Recency Injection

    /// Maximum number of high-salience summaries promoted toward the tail per turn.
    /// Fights "lost-in-the-middle" attention degradation.
    public static let maxPromotedMemoriesPerTurn = 2

    /// Maximum total tokens for promoted (recency-injected) content.
    public static let maxPromotedTokens = 500

    /// Minimum composite salience score for a summary to be eligible for promotion.
    public static let promotionSalienceThreshold: Float = 0.7

    // MARK: - Compaction Escalation

    /// Temperature for normal LLM summarization (standard compaction).
    public static let normalSummarizationTemperature: Float = 0.2

    /// Temperature for aggressive summarization (tighter prompt, reduced target tokens).
    public static let aggressiveSummarizationTemperature: Float = 0.1

    /// Token limit for deterministic truncation fallback (third escalation tier).
    /// Guarantees progress — compaction can never get stuck.
    public static let deterministicTruncationTokens = 512

    /// Maximum number of full compaction sweeps during budget-targeted compaction.
    public static let maxCompactionSweeps = 10

    // MARK: - Thread-Relevant Bridging

    /// Maximum number of older messages bridged verbatim per turn for thread relevance.
    public static let maxBridgedMessagesPerTurn = 2

    /// Maximum total tokens for bridged messages.
    public static let maxBridgedTokens = 500

    // MARK: - Background Tool Execution

    /// Seconds before a tool call is moved to the background.
    public static let toolBackgroundTimeout = 30

    /// Maximum number of concurrent background tasks per turn.
    public static let toolBackgroundMaxConcurrent = 5

    /// Maximum number of concurrent fork turns.
    public static let maxConcurrentForks = 3

    /// Maximum auto-continuation depth (each continuation = 25 more tool calls).
    public static let maxContinuationDepth = 5

    // MARK: - Observer / DMN

    /// Default interval between observer cycles in seconds (5 minutes).
    public static let observerDefaultCycleInterval = 300

    /// Cycle interval as TimeInterval for scheduling.
    public static let observerCycleInterval: TimeInterval = .init(observerDefaultCycleInterval)

    /// Maximum number of plate snapshots to retain (24 hours at 5-min intervals).
    public static let maxPlateSnapshots = 288

    /// Maximum age for observer signals before pruning (24 hours).
    public static let maxObserverSignalAge: TimeInterval = 86_400

    /// Dimensionality of the plate vector (Qwen3-1.7B hidden size).
    public static let plateDimension = 2_048

    /// Maximum tokens for observer signal text.
    public static let observerSignalMaxTokens = 128

    /// Inject novelty every Nth observer cycle for anti-collapse.
    public static let noveltyInjectionFrequency = 3

    /// Alias for config: novelty cycle interval matches injection frequency.
    public static let observerNoveltyCycleInterval = noveltyInjectionFrequency

    /// Default plate injection strength (β parameter).
    public static let observerInjectionStrength: Double = 30.0
}
