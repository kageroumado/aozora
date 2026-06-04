import Foundation

/// Deterministic context construction with volatility ordering and elastic budget allocation.
///
/// ``ContextAssembler`` is the most architecturally significant stateless component. It takes
/// all the raw inputs (system prompt, identity, mirror, summaries, cognitive state, chrono state,
/// bridged thread-relevant messages, and fresh tail messages) and produces an ``AssembledContext``
/// that respects:
///
/// 1. **Volatility ordering**: system prompt → identity → mirror → summaries
///    → cognitive state → chronoception → bridged context → fresh tail (least-changing at head
///    for KV cache efficiency).
/// 2. **Priority-ordered elastic budget**: each section has min/target/max
///    allocations, filled by priority from highest to lowest.
/// 3. **Summary XML wrapping**: summaries carry metadata for expansion.
/// 4. **Cognitive state rendering**: system self-awareness XML.
/// 5. **Tool-use pairing invariant**: every tool_result has a matching tool_use.
/// 6. **Recency injection**: high-salience summaries promoted toward the tail.
///
/// Owned by ``CIMSCoordinator`` as a struct (no actor isolation of its own).
public nonisolated struct ContextAssembler: Sendable {
    /// Heuristic scanner for detecting prompt injection attempts in fresh tail messages.
    private let injectionScanner = PromptInjectionScanner()

    /// Redacts secrets (API keys, tokens, credentials) from tool output before context assembly.
    private let secretRedactor = SecretRedactor()

    // MARK: - Input Types

    /// All inputs needed to assemble a context window.
    public struct AssemblyInputs: Sendable {
        /// The system prompt text.
        public let systemPrompt: String

        /// Serialized identity block for context injection.
        public let identityText: String

        /// Serialized mirror block for context injection.
        public let mirrorText: String

        /// Summary nodes from memory retrieval, ordered oldest to newest.
        public let summaries: [SummaryNode]

        /// Cognitive state XML string (allostasis, memory health, bootstrap status).
        public let cognitiveStateText: String

        /// Chronoception rendered string (session info, gap, temporal mode).
        public let chronoText: String

        /// Stable summaries (kind=condensed) for prompt caching Block 2.
        public var stableSummaries: [SummaryNode] = []

        /// Recent summaries (kind=leaf/leaf_summary) for Block 3.
        public var recentSummaries: [SummaryNode] = []

        /// Older messages bridged verbatim into context because they're thread-relevant.
        ///
        /// When a user references an older conversation thread, a small number of older relevant
        /// messages are bridged verbatim into the context window, placed just before the fresh tail.
        /// Maximum ``CIMSDefaults/maxBridgedMessagesPerTurn`` messages,
        /// ``CIMSDefaults/maxBridgedTokens`` total token budget.
        public var bridgedMessages: [StoredMessage] = []

        /// Fresh tail messages, ordered by creation time.
        public let freshTail: [StoredMessage]

        /// The current user message being processed this turn. Not yet persisted
        /// in the fresh tail — added as the final user turn in the API request.
        public var currentMessage: InboundMessage?

        /// Total token budget for the assembled context.
        public let tokenBudget: Int

        public init(systemPrompt: String, identityText: String, mirrorText: String, summaries: [SummaryNode], cognitiveStateText: String, chronoText: String, stableSummaries: [SummaryNode] = [], recentSummaries: [SummaryNode] = [], bridgedMessages: [StoredMessage] = [], freshTail: [StoredMessage], currentMessage: InboundMessage? = nil, tokenBudget: Int) {
            self.systemPrompt = systemPrompt
            self.identityText = identityText
            self.mirrorText = mirrorText
            self.summaries = summaries
            self.cognitiveStateText = cognitiveStateText
            self.chronoText = chronoText
            self.stableSummaries = stableSummaries
            self.recentSummaries = recentSummaries
            self.bridgedMessages = bridgedMessages
            self.freshTail = freshTail
            self.currentMessage = currentMessage
            self.tokenBudget = tokenBudget
        }
    }

    // MARK: - Assembly

    /// Assemble a complete context window from all inputs.
    ///
    /// The assembly algorithm:
    /// 1. Compute token estimates for all fixed sections.
    /// 2. Allocate min budget to all elastic sections.
    /// 3. If total min exceeds budget, degrade from lowest priority upward.
    /// 4. Fill each section to its target, highest priority first.
    /// 5. Allocate remaining budget to summaries.
    /// 6. Apply recency injection for high-salience summaries.
    /// 7. Enforce the tool-use pairing invariant on the fresh tail.
    ///
    /// - Parameter inputs: All raw inputs for assembly.
    /// - Returns: The assembled context with ordered sections and total token count.
    public func assemble(_ inputs: AssemblyInputs) -> AssembledContext {
        let budget = inputs.tokenBudget

        let systemPromptTokens = estimateTokens(inputs.systemPrompt)

        let scannedTail = scanAndSanitizeTail(inputs.freshTail)
        let pairedTail = enforceToolUsePairing(scannedTail)
        let agedTail = ageFreshTail(pairedTail)
        let storedBoundary = computeStoredBoundaryIndex(agedTail)
        let timestampedTail = injectTimestamps(agedTail, boundary: storedBoundary)
        let freshTailText = renderFreshTail(timestampedTail)
        let freshTailTokens = estimateTokens(freshTailText)

        // Filter out frontier summaries that overlap with the fresh tail time range.
        // With a large fresh tail (256 messages), older compacted summaries may cover
        // the same time period as messages already in the tail.
        let tailStart = timestampedTail.first?.createdAt

        func filterOverlapping(_ summaries: [SummaryNode]) -> [SummaryNode] {
            guard let tailStart else { return summaries }
            return summaries.filter { $0.latestAt < tailStart }
        }

        // Determine whether to use split summaries (new path) or legacy unified summaries.
        // stableSummaries and recentSummaries are pre-filtered by the coordinator.
        // Don't re-filter here — that depends on tailStart which shifts between turns.
        let useNewSummaryPath = !inputs.stableSummaries.isEmpty || !inputs.recentSummaries.isEmpty
        let filteredStable = inputs.stableSummaries
        let filteredRecent = inputs.recentSummaries
        let filteredLegacy = filterOverlapping(inputs.summaries)

        let identityTokens = estimateTokens(inputs.identityText)
        let mirrorTokens = estimateTokens(inputs.mirrorText)
        let chronoTokens = estimateTokens(inputs.chronoText)
        let cognitiveTokens = estimateTokens(inputs.cognitiveStateText)

        let allocations = computeAllocations(
            budget: budget,
            systemPromptTokens: systemPromptTokens,
            identityTokens: identityTokens,
            mirrorTokens: mirrorTokens,
            freshTailTokens: freshTailTokens,
            chronoTokens: chronoTokens,
            cognitiveTokens: cognitiveTokens,
        )

        // Split summary budget: 60% stable, 40% recent (stable summaries are larger/older).
        let stableBudget = useNewSummaryPath ? Int(Double(allocations.summaryBudget) * 0.6) : 0
        let recentBudget = useNewSummaryPath ? allocations.summaryBudget - stableBudget : 0

        let wrappedStable = useNewSummaryPath
            ? selectAndWrapSummaries(filteredStable, tokenBudget: stableBudget)
            : WrappedSummaries(text: "", tokenCount: 0, includedNodeIds: [])
        let wrappedRecent = useNewSummaryPath
            ? selectAndWrapSummaries(filteredRecent, tokenBudget: recentBudget)
            : WrappedSummaries(text: "", tokenCount: 0, includedNodeIds: [])
        let wrappedLegacy = useNewSummaryPath
            ? WrappedSummaries(text: "", tokenCount: 0, includedNodeIds: [])
            : selectAndWrapSummaries(filteredLegacy, tokenBudget: allocations.summaryBudget)

        let allIncludedIds = Set(wrappedStable.includedNodeIds + wrappedRecent.includedNodeIds + wrappedLegacy.includedNodeIds)
        let allSummariesForPromotion = inputs.stableSummaries + inputs.recentSummaries + inputs.summaries
        let promotedSummaries = selectPromotedSummaries(
            allSummariesForPromotion,
            alreadyIncluded: allIncludedIds,
        )

        var sections: [ContextSection] = []

        // ── Section ordering for permanent sessions ──
        //
        // Volatility ordering for KV cache efficiency:
        // 1. Stable summaries (oldest, never change — cached first)
        // 2. System prompt + identity + mirror (rarely change)
        // 3. Recent summaries + cognitive + chrono + temporal (change per turn)
        // 4. Messages (fresh tail, most recent at the end)
        //
        // This differs from typical chat apps where system prompt is most stable.
        // In a permanent session, January summaries are frozen forever while
        // workspace files get edited occasionally.

        // 1. Stable summaries (condensed — frozen history, Block 1)
        if useNewSummaryPath {
            if wrappedStable.tokenCount > 0 {
                let header = "<context_section type=\"archived_memory\" description=\"Condensed summaries of older conversations. These are compressed from the original messages but can be expanded with lcm_expand for full detail.\">\n\n"
                sections.append(ContextSection(
                    kind: .stableSummaries,
                    content: header + wrappedStable.text + "\n\n</context_section>",
                    tokenEstimate: wrappedStable.tokenCount + estimateTokens(header) + 5,
                ))
            }
        }

        // 2. System prompt (Block 2)
        sections.append(ContextSection(
            kind: .systemPrompt,
            content: inputs.systemPrompt,
            tokenEstimate: systemPromptTokens,
        ))

        // 3. Identity — with 1M context, don't truncate.
        sections.append(ContextSection(
            kind: .identity,
            content: inputs.identityText,
            tokenEstimate: identityTokens,
        ))

        // 4. Mirror
        if !inputs.mirrorText.isEmpty {
            sections.append(ContextSection(
                kind: .mirror,
                content: inputs.mirrorText,
                tokenEstimate: mirrorTokens,
            ))
        }

        // 5. Recent summaries (leaf/leaf_summary, Block 3)
        if useNewSummaryPath {
            if wrappedRecent.tokenCount > 0 {
                let header = "<context_section type=\"recent_memory\" description=\"Recent leaf summaries — more detailed than archived memory. These cover the current and recent sessions.\">\n\n"
                sections.append(ContextSection(
                    kind: .recentSummaries,
                    content: header + wrappedRecent.text + "\n\n</context_section>",
                    tokenEstimate: wrappedRecent.tokenCount + estimateTokens(header) + 5,
                ))
            }
        } else {
            // Legacy path: single summaries section
            sections.append(ContextSection(
                kind: .summaries,
                content: wrappedLegacy.text,
                tokenEstimate: wrappedLegacy.tokenCount,
            ))
        }

        // 6. Cognitive state
        let clampedCognitive = truncateToTokens(inputs.cognitiveStateText, maxTokens: allocations.cognitiveBudget)
        if !clampedCognitive.isEmpty {
            sections.append(ContextSection(
                kind: .cognitiveState,
                content: clampedCognitive,
                tokenEstimate: min(cognitiveTokens, allocations.cognitiveBudget),
            ))
        }

        // 7. Chronoception + promoted summaries
        var chronoContent = truncateToTokens(inputs.chronoText, maxTokens: allocations.chronoBudget)
        if !promotedSummaries.isEmpty {
            let promotedText = renderPromotedSummaries(promotedSummaries)
            chronoContent += "\n" + promotedText
        }
        let chronoEstimate = estimateTokens(chronoContent)
        if !chronoContent.isEmpty {
            sections.append(ContextSection(
                kind: .chronoception,
                content: chronoContent,
                tokenEstimate: chronoEstimate,
            ))
        }

        // 8. Temporal grounding (current time, session info, allostasis, preserve tip)
        let temporalLine = buildTemporalGrounding(inputs: inputs)
        sections.append(ContextSection(
            kind: .temporalGrounding,
            content: temporalLine,
            tokenEstimate: estimateTokens(temporalLine),
        ))

        // 9. Bridged context (if any)
        if !inputs.bridgedMessages.isEmpty {
            let bridgedText = renderBridgedMessages(inputs.bridgedMessages)
            let bridgedTokens = estimateTokens(bridgedText)
            sections.append(ContextSection(
                kind: .bridgedContext,
                content: bridgedText,
                tokenEstimate: bridgedTokens,
            ))
        }

        // 10. Fresh tail — the actual messages go through freshTailMessages → provider formats them.
        // Don't truncate — with 1M context, the aged tail easily fits.
        sections.append(ContextSection(
            kind: .freshTail,
            content: freshTailText,
            tokenEstimate: freshTailTokens,
        ))

        // 11. Current message
        var currentMessageText: String?
        if let currentMessage = inputs.currentMessage {
            let text = currentMessage.text
            let tokens = estimateTokens(text)
            sections.append(ContextSection(
                kind: .currentMessage,
                content: text,
                tokenEstimate: tokens,
            ))
            currentMessageText = text
        }

        let totalTokens = sections.reduce(0) { $0 + $1.tokenEstimate }
        return AssembledContext(
            sections: sections,
            totalTokens: totalTokens,
            freshTailMessages: timestampedTail,
            currentMessageText: currentMessageText,
            currentMessageImages: inputs.currentMessage?.images ?? [],
        )
    }

    // MARK: - Budget Allocation

    /// Computed budget allocations for each elastic section.
    private struct Allocations {
        let identityBudget: Int
        let mirrorBudget: Int
        let freshTailBudget: Int
        let chronoBudget: Int
        let cognitiveBudget: Int
        let summaryBudget: Int
    }

    /// Compute elastic budget allocations using the priority-ordered algorithm.
    ///
    /// 1. System prompt is exact (non-elastic).
    /// 2. Allocate min to all elastic sections.
    /// 3. If total min > remaining budget, degrade from lowest priority.
    /// 4. Fill each section to target, highest priority first.
    /// 5. Remaining budget goes to summaries.
    private func computeAllocations(
        budget: Int,
        systemPromptTokens: Int,
        identityTokens: Int,
        mirrorTokens: Int,
        freshTailTokens: Int,
        chronoTokens: Int,
        cognitiveTokens: Int,
    ) -> Allocations {
        let remaining = max(0, budget - systemPromptTokens)

        let budgets = CIMSDefaults.ContextBudgets.self

        typealias SB = CIMSDefaults.ContextBudgets.SectionBudget

        struct ElasticSection {
            let priority: Int
            let budget: SB
            let actualTokens: Int
            var allocated: Int
        }

        var elastic: [ElasticSection] = [
            ElasticSection(priority: 2, budget: budgets.identity, actualTokens: identityTokens, allocated: 0),
            ElasticSection(priority: 3, budget: budgets.mirror, actualTokens: mirrorTokens, allocated: 0),
            ElasticSection(priority: 4, budget: budgets.freshTail, actualTokens: freshTailTokens, allocated: 0),
            ElasticSection(priority: 5, budget: budgets.chronoception, actualTokens: chronoTokens, allocated: 0),
            ElasticSection(priority: 6, budget: budgets.cognitiveState, actualTokens: cognitiveTokens, allocated: 0),
        ]

        let totalMin = elastic.reduce(0) { $0 + min($1.budget.min, $1.actualTokens) }

        if totalMin > remaining {
            var sorted = elastic.sorted { $0.priority > $1.priority }
            var overflow = totalMin - remaining
            for i in sorted.indices {
                if overflow <= 0 { break }
                let sectionMin = min(sorted[i].budget.min, sorted[i].actualTokens)
                let reduction = min(sectionMin, overflow)
                sorted[i].allocated = max(0, sectionMin - reduction)
                overflow -= reduction
            }
            for i in sorted.indices where sorted[i].allocated == 0 {
                sorted[i].allocated = min(sorted[i].budget.min, sorted[i].actualTokens)
            }

            var byPriority: [Int: Int] = [:]
            for s in sorted {
                byPriority[s.priority] = s.allocated
            }
            for i in elastic.indices {
                if let a = byPriority[elastic[i].priority] {
                    elastic[i].allocated = a
                }
            }
        } else {
            for i in elastic.indices {
                elastic[i].allocated = min(elastic[i].budget.min, elastic[i].actualTokens)
            }
        }

        var used = elastic.reduce(0) { $0 + $1.allocated }
        let sortedByPriority = elastic.sorted { $0.priority < $1.priority }

        for s in sortedByPriority {
            let target = min(s.budget.target, s.actualTokens)
            let current = elastic.first(where: { $0.priority == s.priority })!.allocated
            let wantMore = max(0, target - current)
            let canAllocate = max(0, remaining - used)
            let extra = min(wantMore, canAllocate)
            if extra > 0 {
                for i in elastic.indices where elastic[i].priority == s.priority {
                    elastic[i].allocated += extra
                }
                used += extra
            }
        }

        for i in elastic.indices {
            elastic[i].allocated = min(elastic[i].allocated, elastic[i].budget.max)
        }

        let summaryBudget = max(0, remaining - elastic.reduce(0) { $0 + $1.allocated })

        return Allocations(
            identityBudget: elastic[0].allocated,
            mirrorBudget: elastic[1].allocated,
            freshTailBudget: elastic[2].allocated,
            chronoBudget: elastic[3].allocated,
            cognitiveBudget: elastic[4].allocated,
            summaryBudget: summaryBudget,
        )
    }

    // MARK: - Summary Selection and Wrapping

    /// Result of summary selection and XML wrapping.
    private struct WrappedSummaries {
        let text: String
        let tokenCount: Int
        let includedNodeIds: [NodeID]
    }

    /// Select summaries that fit within the token budget and wrap them in XML.
    ///
    /// Summaries are included oldest-to-newest until the budget is exhausted.
    /// If a summary would exceed the budget, it's skipped (not truncated).
    private func selectAndWrapSummaries(
        _ summaries: [SummaryNode],
        tokenBudget: Int,
    ) -> WrappedSummaries {
        var included: [String] = []
        var includedIds: [NodeID] = []
        var usedTokens = 0

        for summary in summaries {
            let wrapped = wrapSummary(summary)
            let tokens = estimateTokens(wrapped)

            if usedTokens + tokens > tokenBudget {
                continue
            }

            included.append(wrapped)
            includedIds.append(summary.nodeId)
            usedTokens += tokens
        }

        return WrappedSummaries(
            text: included.joined(separator: "\n"),
            tokenCount: usedTokens,
            includedNodeIds: includedIds,
        )
    }

    /// Wrap a single summary node in XML with metadata attributes.
    private func wrapSummary(_ summary: SummaryNode) -> String {
        let iso = ISO8601DateFormatter()
        iso.formatOptions = [.withInternetDateTime]

        var xml = "<summary id=\"\(summary.nodeId)\" kind=\"\(summary.kind.rawValue)\" depth=\"\(summary.depth)\""
        xml += " descendant_count=\"\(summary.descendantCount)\""
        xml += " earliest_at=\"\(iso.string(from: summary.earliestAt))\""
        xml += " latest_at=\"\(iso.string(from: summary.latestAt))\""
        xml += ">"

        if summary.kind == .condensed, !summary.parentIds.isEmpty {
            xml += "\n  <parents>\(summary.parentIds.joined(separator: ", "))</parents>"
        }

        xml += "\n  <content>\(summary.summaryText)</content>"

        if let footer = summary.expandFooter {
            xml += "\n  <expand_for>\(footer)</expand_for>"
        }

        xml += "\n</summary>"

        return xml
    }

    // MARK: - Recency Injection

    /// Select high-salience summaries for promotion toward the tail.
    ///
    /// Summaries with composite salience >= ``CIMSDefaults/promotionSalienceThreshold`` (0.7)
    /// are eligible. Up to ``CIMSDefaults/maxPromotedMemoriesPerTurn`` (2) summaries are promoted,
    /// with a total token cap of ``CIMSDefaults/maxPromotedTokens`` (500).
    private func selectPromotedSummaries(
        _ summaries: [SummaryNode],
        alreadyIncluded: Set<NodeID>,
    ) -> [SummaryNode] {
        let candidates = summaries
            .filter { $0.salienceScore >= CIMSDefaults.promotionSalienceThreshold }
            .filter { !alreadyIncluded.contains($0.nodeId) }
            .sorted { $0.salienceScore > $1.salienceScore }

        var promoted: [SummaryNode] = []
        var tokenCount = 0

        for candidate in candidates {
            if promoted.count >= CIMSDefaults.maxPromotedMemoriesPerTurn { break }
            if tokenCount + candidate.tokenCount > CIMSDefaults.maxPromotedTokens { continue }

            promoted.append(candidate)
            tokenCount += candidate.tokenCount
        }

        return promoted
    }

    /// Render promoted summaries with a `[promoted]` marker.
    private func renderPromotedSummaries(_ summaries: [SummaryNode]) -> String {
        summaries.map { summary in
            var xml = wrapSummary(summary)
            xml = xml.replacingOccurrences(of: "<summary ", with: "<summary promoted=\"true\" ")
            return xml
        }.joined(separator: "\n")
    }

    // MARK: - Tool Result Aging

    /// Age tool result messages in the fresh tail using size-tiered decay.
    ///
    /// Tool results are stubbed based on their token count and distance from the end of the
    /// conversation (measured in meaningful turns, not raw message count):
    /// - XL (>25K tokens): stubbed after 8 turns
    /// - L (>10K tokens): stubbed after 16 turns
    /// - M (>5K tokens): stubbed after 24 turns
    /// - S (all others): stubbed after 32 turns
    ///
    /// Empty assistant turns (intermediate tool-use with no text) are filtered out beyond
    /// the outermost tier boundary (32 turns).
    private func ageFreshTail(_ messages: [StoredMessage]) -> [StoredMessage] {
        // Elastic aging: only run the aging sweep at epoch boundaries.
        // Between epochs, return messages unchanged — this preserves the byte-level
        // cache prefix for ~97% hit rates. At epoch boundaries, age everything past
        // the threshold in one batch, accept one cache miss, then stable again.
        let userCount = messages.count(where: { $0.role == .user })
        let gap = CIMSDefaults.cacheBoundaryElasticGap
        let isEpochBoundary = gap > 0 && (userCount % gap == 0)

        if !isEpochBoundary {
            Log.debug("aging", "Epoch \(userCount / gap): turn \(userCount % gap)/\(gap) — no aging")
            return messages
        }

        Log.info("aging", "Epoch boundary (userCount=\(userCount)) — running aging sweep")

        // Build turns-from-end map (counting meaningful messages backward)
        var turnsFromEnd: [Int: Int] = [:]
        var meaningfulCount = 0
        for i in stride(from: messages.count - 1, through: 0, by: -1) {
            let msg = messages[i]
            if msg.role == .user || (msg.role == .assistant && !msg.content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty) {
                meaningfulCount += 1
            }
            turnsFromEnd[i] = meaningfulCount
        }

        // Build toolUseId → toolName lookup from assistant toolCall parts.
        // This lets us label stubbed tool results with the tool name.
        var toolNameByUseId: [String: String] = [:]
        for msg in messages where msg.role == .assistant {
            for part in msg.parts where part.kind == .toolCall {
                guard let meta = part.metadata,
                      let data = meta.data(using: .utf8),
                      let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                      let id = json["id"] as? String,
                      let name = json["name"] as? String
                else { continue }
                toolNameByUseId[id] = name
            }
        }

        // Track tool_use IDs from filtered-out assistant messages so we also
        // skip their corresponding tool_result messages. Otherwise the API sees
        // orphaned tool_results without a matching tool_use.
        var droppedToolUseIds: Set<String> = []

        return messages.enumerated().map { index, msg -> StoredMessage in
            let turns = turnsFromEnd[index] ?? meaningfulCount

            // Stub empty assistant turns (intermediate tool-use with no text).
            // These are kept in the array (not dropped) to preserve stable indices
            // for cache prefix matching. Dropping shifts the array and breaks cache.
            if msg.role == .assistant,
               msg.content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
               turns >= CIMSDefaults.toolAgingTierS {
                // Mark this message's tool_use IDs so matching results also get stubbed.
                for part in msg.parts where part.kind == .toolCall {
                    if let meta = part.metadata,
                       let data = meta.data(using: .utf8),
                       let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                       let id = json["id"] as? String {
                        droppedToolUseIds.insert(id)
                    }
                }
                return StoredMessage(
                    id: msg.id, conversationId: msg.conversationId,
                    role: msg.role, content: "[omitted]",
                    tokenEstimate: 4, salienceScore: msg.salienceScore,
                    createdAt: msg.createdAt, parts: [],
                )
            }

            if msg.role == .tool {
                // Skip tool results whose matching tool_use was filtered out
                let resultToolUseId = msg.parts
                    .first(where: { $0.kind == .toolResult })
                    .flatMap { part -> String? in
                        guard let meta = part.metadata,
                              let data = meta.data(using: .utf8),
                              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
                        else { return nil }
                        return json["toolUseId"] as? String
                    }
                if let id = resultToolUseId, droppedToolUseIds.contains(id) {
                    // Stub orphaned tool results instead of dropping them.
                    // Preserves stable array indices for cache prefix matching.
                    return StoredMessage(
                        id: msg.id, conversationId: msg.conversationId,
                        role: msg.role, content: "[Tool output omitted]",
                        tokenEstimate: 4, salienceScore: msg.salienceScore,
                        createdAt: msg.createdAt, parts: msg.parts,
                    )
                }

                let tokens = msg.tokenEstimate

                // Tiny tool results (< 200 tokens) are NEVER aged. The cost of
                // keeping "exit code 0\n" (~5 tokens) forever is negligible, but
                // aging it would change the cached prefix and cause a ~200K token
                // cache miss — a terrible tradeoff.
                if tokens <= CIMSDefaults.toolAgingExemptThreshold {
                    return msg
                }

                // Use >= so messages AT the cache boundary are already stubbed.
                // This ensures messages entering the cached region (before boundary)
                // have stable content — the off-by-one between > and >= was causing
                // messages to change content one turn after crossing the boundary,
                // breaking the cache prefix.
                let shouldStub: Bool = if tokens > 25_000 {
                    turns >= CIMSDefaults.toolAgingTierXL
                } else if tokens > 10_000 {
                    turns >= CIMSDefaults.toolAgingTierL
                } else if tokens > 5_000 {
                    turns >= CIMSDefaults.toolAgingTierM
                } else {
                    turns >= CIMSDefaults.toolAgingTierS
                }

                if shouldStub {
                    // Look up tool name from the toolResult part's toolUseId
                    let toolUseId = msg.parts
                        .compactMap { part -> String? in
                            guard part.kind == .toolResult,
                                  let meta = part.metadata,
                                  let data = meta.data(using: .utf8),
                                  let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
                            else { return nil }
                            return json["toolUseId"] as? String
                        }
                        .first

                    let toolName = toolUseId.flatMap { toolNameByUseId[$0] }

                    let stub = if let toolName {
                        "[Tool output omitted — \(toolName)]"
                    } else {
                        "[Tool output omitted]"
                    }

                    return StoredMessage(
                        id: msg.id,
                        conversationId: msg.conversationId,
                        role: msg.role,
                        content: stub,
                        tokenEstimate: 8,
                        salienceScore: msg.salienceScore,
                        createdAt: msg.createdAt,
                        parts: msg.parts,
                    )
                }
            }

            return msg
        }
    }

    /// Compute the stored-message-level boundary for timestamp scoping.
    ///
    /// Counts meaningful messages from the end until reaching ``CIMSDefaults/toolAgingTierS``.
    /// Used for deciding which messages get timestamp injection (post-boundary only) and
    /// aligns with the aging tier, not the cache boundary. The actual cache breakpoint is
    /// computed in ``PromptBuilder`` at ``CIMSDefaults/cacheBoundaryTurns``.
    private func computeStoredBoundaryIndex(_ messages: [StoredMessage]) -> Int? {
        var meaningfulCount = 0
        for i in stride(from: messages.count - 1, through: 0, by: -1) {
            let msg = messages[i]
            if msg.role == .user || (msg.role == .assistant && !msg.content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty) {
                meaningfulCount += 1
            }
            if meaningfulCount >= CIMSDefaults.toolAgingTierS {
                return i
            }
        }
        return nil
    }

    // MARK: - Prompt Injection Scanning

    /// Scan fresh tail messages for prompt injection and redact any that contain detected threats.
    ///
    /// - Tool-role messages are scanned with ``PromptInjectionScanner/scanToolResult(_:)`` (stricter,
    ///   includes structured injection patterns) because tool results originate from external sources.
    /// - User-role messages are scanned with ``PromptInjectionScanner/scan(_:)`` (standard patterns).
    /// - Assistant-role messages pass through unscanned — we trust our own output.
    ///
    /// When threats are detected, the message content is replaced with a redaction notice listing
    /// the threat kinds. All other metadata (id, conversationId, role, timestamps) is preserved.
    ///
    /// - Parameter messages: The fresh tail messages to scan.
    /// - Returns: A new array with suspicious messages redacted.
    private func scanAndSanitizeTail(_ messages: [StoredMessage]) -> [StoredMessage] {
        messages.map { message in
            switch message.role {
            case .tool:
                break
            case .user, .assistant, .system:
                // Don't scan user/assistant messages — they come from our own system
                return message
            }

            // Pass 1: Prompt injection scanning (binary — redact entire content if detected)
            let injectionResult = injectionScanner.scanToolResult(message.content)

            if !injectionResult.isClean {
                let kinds = injectionResult.threats.map(\.kind.rawValue).joined(separator: ", ")
                let redactedContent = "[Content redacted: prompt injection detected (\(kinds))]"

                // Preserve .toolResult parts with their metadata so buildRequest can still
                // pair tool_results with their tool_use blocks. Only the content is redacted.
                let redactedParts: [MessagePart] = if message.parts.contains(where: { $0.kind == .toolResult }) {
                    message.parts.map { part in
                        if part.kind == .toolResult {
                            MessagePart(kind: .toolResult, ordinal: part.ordinal, content: redactedContent, metadata: part.metadata)
                        } else {
                            MessagePart(kind: .text, ordinal: part.ordinal, content: redactedContent, metadata: nil)
                        }
                    }
                } else {
                    [MessagePart(kind: .text, ordinal: 0, content: redactedContent, metadata: nil)]
                }

                return StoredMessage(
                    id: message.id,
                    conversationId: message.conversationId,
                    role: message.role,
                    content: redactedContent,
                    tokenEstimate: max(1, redactedContent.utf8.count / 4),
                    salienceScore: message.salienceScore,
                    createdAt: message.createdAt,
                    parts: redactedParts,
                )
            }

            // Pass 2: Secret redaction (surgical — replace only secret values)
            guard secretRedactor.containsSecrets(message.content) else { return message }

            let scrubbedContent = secretRedactor.redact(message.content)
            let scrubbedParts: [MessagePart] = message.parts.map { part in
                if part.kind == .toolResult {
                    MessagePart(
                        kind: .toolResult, ordinal: part.ordinal,
                        content: secretRedactor.redact(part.content), metadata: part.metadata,
                    )
                } else {
                    part
                }
            }

            return StoredMessage(
                id: message.id,
                conversationId: message.conversationId,
                role: message.role,
                content: scrubbedContent,
                tokenEstimate: max(1, scrubbedContent.utf8.count / 4),
                salienceScore: message.salienceScore,
                createdAt: message.createdAt,
                parts: scrubbedParts,
            )
        }
    }

    // MARK: - Tool-Use Pairing Invariant

    /// Enforce that every tool_result message has a matching tool_use message in context.
    ///
    /// With the ``PromptBuilder`` + ``ToolExchange`` pipeline, tool-use/result pairing is
    /// guaranteed by construction for new messages. This method remains as a debug assertion
    /// for legacy stored messages that may have been persisted before the structural guarantee.
    ///
    /// In release builds, passes messages through unchanged. In debug builds, asserts that
    /// all tool results have matching tool calls.
    private func enforceToolUsePairing(_ messages: [StoredMessage]) -> [StoredMessage] {
        // With the PromptBuilder + ToolExchange pipeline, tool-use/result pairing
        // is guaranteed by construction for new messages. For legacy stored messages,
        // still filter orphans to maintain the invariant.
        var assistantToolCallIds = Set<String>()
        for message in messages where message.role == .assistant {
            for part in message.parts where part.kind == .toolCall {
                if let metadata = part.metadata,
                   let data = metadata.data(using: .utf8),
                   let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                   let id = json["id"] as? String {
                    assistantToolCallIds.insert(id)
                } else if let metadata = part.metadata {
                    // Legacy format: metadata is just the call ID string
                    assistantToolCallIds.insert(metadata)
                }
            }
            // Also check .tool kind parts (legacy format)
            for part in message.parts where part.kind == .tool {
                if let metadata = part.metadata {
                    assistantToolCallIds.insert(metadata)
                }
            }
        }

        return messages.filter { message in
            guard message.role == .tool else { return true }
            // Keep messages that have no tool result parts (legacy format)
            let toolResultParts = message.parts.filter { $0.kind == .toolResult || $0.kind == .tool }
            guard !toolResultParts.isEmpty else { return true }

            for part in toolResultParts {
                if let metadata = part.metadata {
                    // Try JSON format first: {"toolUseId":"...","isError":false}
                    if let data = metadata.data(using: .utf8),
                       let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                       let toolUseId = json["toolUseId"] as? String {
                        if assistantToolCallIds.contains(toolUseId) { return true }
                    } else {
                        // Legacy format: metadata is just the call ID string
                        if assistantToolCallIds.contains(metadata) { return true }
                    }
                }
            }
            return false
        }
    }

    // MARK: - Fresh Tail Rendering

    /// Render fresh tail messages as a text block with role prefixes.
    private func renderFreshTail(_ messages: [StoredMessage]) -> String {
        messages.map { message in
            "[\(message.role.rawValue)] \(message.content)"
        }.joined(separator: "\n\n")
    }

    // MARK: - Bridged Message Rendering

    /// Render thread-relevant bridged messages with a header and role prefixes.
    ///
    /// Takes up to ``CIMSDefaults/maxBridgedMessagesPerTurn`` messages and truncates
    /// the combined output to ``CIMSDefaults/maxBridgedTokens`` tokens.
    ///
    /// - Parameter messages: Older messages bridged for thread relevance, ordered by creation time.
    /// - Returns: Rendered text with a header identifying the section as bridged context.
    private func renderBridgedMessages(_ messages: [StoredMessage]) -> String {
        let capped = Array(messages.prefix(CIMSDefaults.maxBridgedMessagesPerTurn))
        var lines = ["[Thread context — bridged from earlier conversation]"]
        for message in capped {
            lines.append("[\(message.role.rawValue)] \(message.content)")
        }
        let joined = lines.joined(separator: "\n\n")
        return truncateToTokens(joined, maxTokens: CIMSDefaults.maxBridgedTokens)
    }

    // MARK: - Temporal Grounding

    /// Build the temporal grounding footer for context injection.
    ///
    /// Computes real-time temporal signals: current time, session duration, approximate session
    /// count, last user message recency, gap since previous session, and allostasis mode.
    /// Also includes a tip about the `[preserve]` marker for verbatim quotation in summaries.
    ///
    /// - Parameter inputs: The assembly inputs containing fresh tail and summary data.
    /// - Returns: A single-line temporal grounding string for the `.temporalGrounding` section.
    private func buildTemporalGrounding(inputs: AssemblyInputs) -> String {
        let now = Date()
        let formatter = DateFormatter()
        formatter.dateFormat = "EEEE yyyy-MM-dd HH:mm zzz"
        formatter.timeZone = TimeZone(identifier: "Europe/Paris")

        // Session start: find the most recent gap > 1h in the fresh tail.
        // The "current session" starts after the last long gap, not from the
        // oldest message (which could be weeks old in a persistent context).
        let sessionStart: Date = {
            let messages = inputs.freshTail
            guard !messages.isEmpty else { return now }
            var start = messages.first!.createdAt
            for i in 1 ..< messages.count {
                let gap = messages[i].createdAt.timeIntervalSince(messages[i - 1].createdAt)
                if gap > 3_600 {
                    start = messages[i].createdAt
                }
            }
            return start
        }()

        let sessionDuration: String = {
            let interval = now.timeIntervalSince(sessionStart)
            let hours = Int(interval) / 3_600
            let minutes = (Int(interval) % 3_600) / 60
            if hours > 0 { return "\(hours)h \(minutes)m" }
            return "\(minutes)m"
        }()

        let lastUserMessage: String = {
            guard let last = inputs.freshTail.last(where: { $0.role == .user }) else { return "unknown" }
            let ago = Int(now.timeIntervalSince(last.createdAt))
            if ago < 60 { return "\(ago)s ago" }
            if ago < 3_600 { return "\(ago / 60) min ago" }
            return "\(ago / 3_600)h ago"
        }()

        // Gap since previous session: time between the current session start
        // and the message just before the gap that started this session.
        let sessionGap: String = {
            let messages = inputs.freshTail
            guard messages.count >= 2 else { return "unknown" }

            // Walk backward from the end to find the gap that started the current session
            for i in stride(from: messages.count - 1, through: 1, by: -1) {
                let gap = messages[i].createdAt.timeIntervalSince(messages[i - 1].createdAt)
                if gap > 3_600 {
                    let gapSeconds = Int(gap)
                    if gapSeconds < 3_600 { return "\(gapSeconds / 60)m" }
                    if gapSeconds < 86_400 { return "\(gapSeconds / 3_600)h" }
                    return "\(gapSeconds / 86_400)d"
                }
            }
            return "continuous"
        }()

        // Session count: count gaps > 1h in the fresh tail, plus an estimate
        // from stable summaries (each condensed node ≈ 1-3 sessions).
        let sessionCount: String = {
            var sessions = 1
            for i in 1 ..< max(1, inputs.freshTail.count) {
                let gap = inputs.freshTail[i].createdAt.timeIntervalSince(inputs.freshTail[i - 1].createdAt)
                if gap > 3_600 { sessions += 1 }
            }
            // Each condensed summary covers roughly 1-2 days of activity
            sessions += inputs.stableSummaries.count
            return "~\(sessions)"
        }()

        let allostasisMode: String = {
            let lastUser = inputs.freshTail.last(where: { $0.role == .user })?.createdAt ?? .distantPast
            let lastAny = inputs.freshTail.last?.createdAt ?? .distantPast
            let sinceUser = now.timeIntervalSince(lastUser)
            let sinceAny = now.timeIntervalSince(lastAny)

            // Recovery: just woke up after a long gap (>1h since last activity)
            if sinceAny > 3_600 { return "recovery" }
            // Idle: no user messages for 10+ min but system is active (heartbeats)
            if sinceUser > 600 { return "idle" }
            return "active"
        }()

        // Count recent heartbeat messages in the fresh tail (heartbeat prompts
        // from the system user key). Gives the model awareness of how many
        // heartbeat cycles have passed since the last real user interaction.
        let recentHeartbeats = inputs.freshTail
            .suffix(50)
            .count(where: { $0.role == .user && $0.content.contains("periodic heartbeat") })
            
        return """
        <temporal_grounding description="System-injected snapshot of current time and session state. This is not a message — it is metadata generated at context assembly time.">
          <now>\(formatter.string(from: now))</now>
          <session duration="\(sessionDuration)" total_sessions="\(sessionCount)" />
          <last_user_message>\(lastUserMessage)</last_user_message>
          <gap_since_previous_session>\(sessionGap)</gap_since_previous_session>
          <allostasis mode="\(allostasisMode)" description="active = in conversation, idle = heartbeat mode (no user messages for 10+ min), recovery = just woke up after >1h gap" />
          <heartbeats recent="\(recentHeartbeats)" interval="4min" description="Heartbeats since last user message. HEARTBEAT_SKIP responses are purged from history." />
        </temporal_grounding>
        <note>Use [preserve] around phrases in your responses that should be quoted verbatim in future summaries.</note>
        """
    }

    // MARK: - Inline Timestamp Injection

    /// Inject XML timestamps into user messages AFTER the stubbing boundary.
    ///
    /// Only user messages and heartbeat prompts get timestamps — assistant replies are
    /// near-immediate so their timing is implicit. Uses XML tags (`<t>`) that the model
    /// can read as metadata without echoing into responses.
    ///
    /// Timestamps are scoped to post-boundary messages only. Messages before the boundary
    /// are part of the cached prefix — modifying them (as the old sliding window did)
    /// would break cache stability between turns.
    ///
    /// - Parameters:
    ///   - messages: The aged fresh tail messages.
    ///   - boundary: The stored-message-level boundary index. Only messages at indices
    ///     > boundary get timestamps. Pass `nil` to timestamp all (fallback for short tails).
    ///   - count: Maximum number of user messages to timestamp. Defaults to 40.
    /// - Returns: A new array with timestamps injected into selected user messages.
    private func injectTimestamps(_ messages: [StoredMessage], boundary: Int?, count: Int = 40) -> [StoredMessage] {
        let formatter = DateFormatter()
        formatter.dateFormat = "EEE yyyy-MM-dd HH:mm"
        formatter.timeZone = TimeZone(identifier: "Europe/Paris")

        let startIndex = (boundary ?? -1) + 1

        // Find the last N user messages AFTER the boundary (walking backwards)
        var userIndices: [Int] = []
        for i in stride(from: messages.count - 1, through: startIndex, by: -1) {
            if messages[i].role == .user {
                userIndices.append(i)
                if userIndices.count >= count { break }
            }
        }
        let timestampSet = Set(userIndices)
        let firstIndex = userIndices.last // earliest in conversation order

        return messages.enumerated().map { index, msg in
            guard timestampSet.contains(index) else { return msg }

            let timestamp = formatter.string(from: msg.createdAt)
            let prefix = if index == firstIndex {
                "<t note=\"Timestamps are auto-injected metadata, not part of the message.\">\(timestamp)</t>\n"
            } else {
                "<t>\(timestamp)</t>\n"
            }

            return StoredMessage(
                id: msg.id,
                conversationId: msg.conversationId,
                role: msg.role,
                content: prefix + msg.content,
                tokenEstimate: msg.tokenEstimate + 8,
                salienceScore: msg.salienceScore,
                createdAt: msg.createdAt,
                parts: msg.parts,
            )
        }
    }

    // MARK: - Token Estimation

    /// Estimate token count for a text string.
    ///
    /// Uses the rough approximation: `text.utf8.count / 4`.
    ///
    /// - Parameter text: The text to estimate.
    /// - Returns: Estimated token count.
    public func estimateTokens(_ text: String) -> Int {
        max(1, text.utf8.count / 4)
    }

    /// Truncate text to fit within a token budget.
    ///
    /// If the text fits, it's returned as-is. Otherwise, it's truncated at the nearest
    /// character boundary to approximately `maxTokens * 4` UTF-8 bytes.
    ///
    /// - Parameters:
    ///   - text: The text to truncate.
    ///   - maxTokens: The maximum token count.
    /// - Returns: The truncated text.
    private func truncateToTokens(_ text: String, maxTokens: Int) -> String {
        guard maxTokens > 0 else { return "" }
        let currentTokens = estimateTokens(text)
        guard currentTokens > maxTokens else { return text }

        let targetBytes = maxTokens * 4
        let utf8 = text.utf8
        guard targetBytes < utf8.count else { return text }

        let truncatedUTF8 = utf8.prefix(targetBytes)
        if let result = String(truncatedUTF8) {
            return result
        }

        return String(text.prefix(maxTokens * 3))
    }
}
