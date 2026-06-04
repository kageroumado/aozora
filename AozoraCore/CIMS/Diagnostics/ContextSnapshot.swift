import Foundation

/// A point-in-time snapshot of the full CIMS cognitive state for diagnostic visualization.
///
/// Captures the current state of all CIMS subsystems: memory, identity, allostasis,
/// chronoception, and the assembled context window. Used by ``ContextInspectorView``
/// to render real-time diagnostics without affecting the cognitive cycle.
///
/// Snapshots are created via ``CIMSGateway/diagnosticSnapshot(for:)`` and are intentionally
/// read-only value types — they represent a frozen moment, not a live connection.
public nonisolated struct ContextSnapshot: Sendable {
    /// When this snapshot was captured.
    public let capturedAt: Date

    // MARK: - Context Window

    /// The assembled context sections with token estimates.
    public let sections: [SectionSnapshot]

    /// Total tokens used across all sections.
    public let totalTokens: Int

    /// Total token budget for the context window.
    public let tokenBudget: Int

    /// Budget utilization as a fraction (0-1).
    public var utilization: Double {
        guard tokenBudget > 0 else { return 0 }
        return Double(totalTokens) / Double(tokenBudget)
    }

    // MARK: - Coordinator State

    /// Current allostasis mode.
    public let allostasisMode: AllostasisMode

    /// Current resource pressure (0-1).
    public let pressure: Float

    /// Current temporal mode.
    public let temporalMode: TemporalMode

    /// Number of turns currently queued.
    public let queueDepth: Int

    /// Number of turns currently being executed.
    public let activeTurns: Int

    // MARK: - Memory State

    /// Number of messages in the fresh tail.
    public let freshTailCount: Int

    /// Number of summary nodes in the DAG.
    public let summaryCount: Int

    /// Number of identity claims.
    public let identityClaimCount: Int

    /// Number of mirror claims for the inspected user.
    public let mirrorClaimCount: Int

    // MARK: - Section Snapshot

    /// A single section of the assembled context with diagnostic metadata.
    public nonisolated struct SectionSnapshot: Sendable, Identifiable {
        public var id: String {
            kind.rawValue
        }

        /// The section kind.
        public let kind: ContextSectionKind

        /// Display name for the section.
        public let displayName: String

        /// Estimated token count.
        public let tokenCount: Int

        /// The raw content of this section.
        public let content: String

        /// Whether this section was truncated to fit the budget.
        public let isTruncated: Bool

        public init(kind: ContextSectionKind, displayName: String, tokenCount: Int, content: String, isTruncated: Bool) {
            self.kind = kind
            self.displayName = displayName
            self.tokenCount = tokenCount
            self.content = content
            self.isTruncated = isTruncated
        }
    }

    /// Create an empty snapshot for initial state.
    public static let empty = ContextSnapshot(
        capturedAt: Date(),
        sections: [],
        totalTokens: 0,
        tokenBudget: 0,
        allostasisMode: .balanced,
        pressure: 0,
        temporalMode: .newSession,
        queueDepth: 0,
        activeTurns: 0,
        freshTailCount: 0,
        summaryCount: 0,
        identityClaimCount: 0,
        mirrorClaimCount: 0,
    )
}

// MARK: - Snapshot Factory

extension CIMSGateway {
    /// Capture a diagnostic snapshot of the current CIMS state.
    ///
    /// Queries all subsystems to build a comprehensive view of the cognitive architecture's
    /// current state. This is intended for diagnostic/debug UI and has no side effects.
    ///
    /// - Parameter userKey: The user key to inspect mirror claims for. Defaults to "default".
    /// - Returns: A frozen snapshot of the current state.
    public func diagnosticSnapshot(for userKey: UserKey = "default") async -> ContextSnapshot {
        // Query coordinator state
        let allostasisMode = await coordinator.currentAllostasisMode
        let pressure = await coordinator.currentPressure
        let temporalMode = await coordinator.currentTemporalMode
        let contextBudget = await coordinator.currentContextBudget
        let queueDepth = await coordinator.currentQueueDepth
        let activeTurnCount = await coordinator.activeTurnCount

        // Query identity state
        let identity = await identityStore.currentIdentity()
        let mirror = await identityStore.currentMirror(for: userKey)

        // Query memory state
        let freshTail = await memoryStore.freshTail(count: CIMSDefaults.protectedTailCount, for: 1)
        let retrieval = await memoryStore.retrieve(
            query: "",
            salienceBoost: .default,
            limit: 50,
        )

        // Assemble context to see the actual breakdown
        let assembler = ContextAssembler()
        let identityText = identity.claims.isEmpty
            ? "[No identity claims]"
            : identity.claims.map { "\($0.claimKey): \($0.value)" }.joined(separator: "\n")
        let mirrorText = mirror.claims.isEmpty
            ? "[No mirror claims]"
            : mirror.claims.map { "\($0.claimKey): \($0.value)" }.joined(separator: "\n")

        let inputs = ContextAssembler.AssemblyInputs(
            systemPrompt: "You are a helpful assistant.",
            identityText: identityText,
            mirrorText: mirrorText,
            summaries: retrieval.summaries,
            cognitiveStateText: "[Allostasis: \(allostasisMode.rawValue) | Pressure: \(Int(pressure * 100))%]",
            chronoText: "[Temporal mode: \(temporalMode.rawValue)]",
            freshTail: freshTail,
            tokenBudget: contextBudget,
        )

        let assembled = assembler.assemble(inputs)

        let sectionSnapshots = assembled.sections.map { section in
            ContextSnapshot.SectionSnapshot(
                kind: section.kind,
                displayName: displayName(for: section.kind),
                tokenCount: section.tokenEstimate,
                content: section.content,
                isTruncated: false,
            )
        }

        return ContextSnapshot(
            capturedAt: Date(),
            sections: sectionSnapshots,
            totalTokens: assembled.totalTokens,
            tokenBudget: contextBudget,
            allostasisMode: allostasisMode,
            pressure: pressure,
            temporalMode: temporalMode,
            queueDepth: queueDepth,
            activeTurns: activeTurnCount,
            freshTailCount: freshTail.count,
            summaryCount: retrieval.summaries.count,
            identityClaimCount: identity.claims.count,
            mirrorClaimCount: mirror.claims.count,
        )
    }

    /// Human-readable display name for a context section kind.
    private func displayName(for kind: ContextSectionKind) -> String {
        switch kind {
        case .systemPrompt: "System Prompt"
        case .identity: "Identity Block"
        case .mirror: "Mirror Block"
        case .summaries: "Memory Summaries"
        case .cognitiveState: "Cognitive State"
        case .chronoception: "Chronoception"
        case .bridgedContext: "Bridged Context"
        case .freshTail: "Fresh Tail"
        case .currentMessage: "Current Message"
        case .stableSummaries: "Stable Summaries"
        case .recentSummaries: "Recent Summaries"
        case .temporalGrounding: "Temporal Grounding"
        }
    }
}
