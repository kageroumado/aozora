import Foundation

/// Pure automaton for heartbeat cache warming.
///
/// Replays a frozen ``PromptSnapshot`` with only the heartbeat message changing.
/// No CIMS pipeline, no DB writes, no state mutations on skip. When the model
/// decides to act (tool calls or non-skip text), escalates to a full CIMS turn
/// through the gateway.
///
/// Cache health is asserted on every tick — a cache miss without preceding
/// compaction is fatal (Discord alert + daemon shutdown).
actor HeartbeatEngine {
    /// Result of a cache health check.
    enum CacheHealthResult: Equatable {
        case ok
        case warning
        case fatal
    }

    /// Result of a heartbeat tick.
    enum TickResult {
        case skip
        case acted(text: String)
        case alert(text: String)
        case cacheFailure(diagnostic: String)
        case noSnapshot
    }

    private let provider: any ModelProviding
    private let promptBuilder = PromptBuilder()
    private let gateway: CIMSGateway
    private var heartbeatCount: Int = 0
    private var compactionSinceSnapshot: Bool = false
    private var lastRealTurnAt: Date?
    private var lastUserMessageAt: Date?
    private var consecutiveCacheMisses: Int = 0
    private var consecutiveErrors: Int = 0

    /// Maximum consecutive cache misses before fatal shutdown.
    private static let maxConsecutiveCacheMisses = 2

    /// Maximum consecutive API errors before stopping heartbeats.
    /// Each error wastes full-price tokens if the cache is stale.
    private static let maxConsecutiveErrors = 3

    /// Current heartbeat count (exposed for status command).
    var currentHeartbeatCount: Int {
        heartbeatCount
    }

    init(provider: any ModelProviding, gateway: CIMSGateway) {
        self.provider = provider
        self.gateway = gateway
    }

    /// Called by compaction callback to mark that summaries may have changed.
    func markCompaction() {
        compactionSinceSnapshot = true
    }

    /// Called when a real turn completes — resets all counters.
    func onRealTurnComplete() {
        heartbeatCount = 0
        compactionSinceSnapshot = false
        consecutiveCacheMisses = 0
        consecutiveErrors = 0
        lastRealTurnAt = Date()
    }

    /// Record when the last user message arrived (for idle duration).
    func recordUserActivity(at date: Date = Date()) {
        lastUserMessageAt = date
    }

    /// Execute a single heartbeat tick.
    ///
    /// 1. Build heartbeat prompt from frozen snapshot
    /// 2. Send to API
    /// 3. Assert cache health
    /// 4. Handle response: skip, act, or alert
    func tick() async -> TickResult {
        guard let snapshot = await gateway.promptSnapshot else {
            log("[heartbeat] No snapshot — bootstrapping with a full turn to prime cache")
            await bootstrapSnapshot()
            return .noSnapshot
        }

        heartbeatCount += 1
        let now = Date()
        let temporal = PromptBuilder.HeartbeatTemporalState(
            heartbeatCount: heartbeatCount,
            now: now,
            idleDuration: lastUserMessageAt.map { .seconds(now.timeIntervalSince($0)) },
            sinceLastTurn: lastRealTurnAt.map { .seconds(now.timeIntervalSince($0)) },
        )
        let prompt = promptBuilder.buildHeartbeatPrompt(from: snapshot, temporal: temporal)

        let response: ModelResponse
        do {
            response = try await provider.complete(prompt, tier: .executive)
            consecutiveErrors = 0
        } catch {
            consecutiveErrors += 1
            log("[heartbeat] API error (\(consecutiveErrors)/\(Self.maxConsecutiveErrors)): \(error)")
            if consecutiveErrors >= Self.maxConsecutiveErrors {
                return .cacheFailure(
                    diagnostic: "[heartbeat] FATAL: \(consecutiveErrors) consecutive API errors — "
                        + "each retry wastes full-price tokens. Shutting down.",
                )
            }
            return .skip
        }

        // Assert cache health
        let health = Self.checkCacheHealth(
            usage: response.tokenUsage,
            compactionSinceSnapshot: compactionSinceSnapshot,
        )

        let diagnosticReport = CacheDiagnostics.report(
            prompt: prompt,
            usage: response.tokenUsage,
            boundaryIndex: nil,
            previousSystemHash: nil,
            previousBlockHashes: nil,
        )
        log("[heartbeat] \(CacheDiagnostics.format(diagnosticReport))")

        switch health {
        case .fatal:
            consecutiveCacheMisses += 1
            let msg = "[heartbeat] FATAL: cache_read=\(response.tokenUsage.cacheReadTokens) "
                + "input=\(response.tokenUsage.inputTokens) — cache broken without compaction "
                + "(\(consecutiveCacheMisses)/\(Self.maxConsecutiveCacheMisses))"
            print(msg)
            if consecutiveCacheMisses >= Self.maxConsecutiveCacheMisses {
                return .cacheFailure(diagnostic: msg)
            }
            return .skip

        case .warning:
            consecutiveCacheMisses += 1
            log("[heartbeat] WARNING: cache miss (\(consecutiveCacheMisses)) — compaction or re-warming")
            compactionSinceSnapshot = false

        case .ok:
            consecutiveCacheMisses = 0
        }

        let text = response.content.trimmingCharacters(in: .whitespacesAndNewlines)

        // SKIP: pure automaton, no side effects
        if text == "HEARTBEAT_SKIP" || text.isEmpty || text == "HEARTBEAT_OK" || text == "NO_REPLY" {
            log("[heartbeat] Skip (count=\(heartbeatCount))")
            return .skip
        }

        // ACT: model wants to do something — escalate to full CIMS turn
        if !response.toolCalls.isEmpty {
            log("[heartbeat] Active — \(response.toolCalls.count) tool calls")
            return await runActiveTurn()
        }

        // TEXT: model has something to say
        log("[heartbeat] Alert: \(text.prefix(80))")
        return .alert(text: text)
    }

    /// Bootstrap a snapshot by running one full CIMS turn.
    ///
    /// After a fresh daemon start, there's no snapshot (no real turn has completed).
    /// This runs a heartbeat through the full pipeline to prime the cache and capture
    /// the initial snapshot. Subsequent heartbeats use the frozen replay path.
    private func bootstrapSnapshot() async {
        let bootstrapText = """
        <heartbeat n="0" bootstrap="true" />
        This is the first heartbeat after daemon start. Reply HEARTBEAT_SKIP.
        """

        let message = InboundMessage(
            text: bootstrapText,
            parts: [MessagePart(kind: .text, ordinal: 0, content: bootstrapText, metadata: nil)],
            metadata: nil,
        )

        let request = TurnRequest(
            turnID: "heartbeat-bootstrap-\(Int(Date().timeIntervalSince1970))",
            sessionKey: "heartbeat-active",
            userKey: "system",
            message: message,
            receivedAt: Date(),
        )

        do {
            let observer = SilentTurnObserver()
            try await gateway.runTurn(request, observer: observer)
            log("[heartbeat] Bootstrap complete — snapshot captured")
        } catch {
            log("[heartbeat] Bootstrap failed: \(error)")
        }
    }

    /// When the model decides to act during a heartbeat, escalate to a full CIMS turn.
    ///
    /// Runs the complete pipeline — tools, persistence, allostasis, the works.
    /// The coordinator recaptures the ``PromptSnapshot`` at the end, so subsequent
    /// heartbeats reflect any changes the agent made.
    private func runActiveTurn() async -> TickResult {
        let heartbeatPromptText = """
        <heartbeat n="\(heartbeatCount)" active="true" />
        This is a periodic heartbeat. You decided to act — full tools are available.
        Follow your HEARTBEAT.md protocol: orient, exist, close the loop.
        """

        let message = InboundMessage(
            text: heartbeatPromptText,
            parts: [MessagePart(kind: .text, ordinal: 0, content: heartbeatPromptText, metadata: nil)],
            metadata: nil,
        )

        let request = TurnRequest(
            turnID: "heartbeat-active-\(heartbeatCount)",
            sessionKey: "heartbeat-active",
            userKey: "system",
            message: message,
            receivedAt: Date(),
        )

        do {
            let observer = SilentTurnObserver()
            try await gateway.runTurn(request, observer: observer)
            let responseText = await observer.responseText.trimmingCharacters(in: .whitespacesAndNewlines)
            if responseText.isEmpty || responseText == "HEARTBEAT_OK" || responseText == "NO_REPLY" {
                return .skip
            }
            return .acted(text: responseText)
        } catch {
            log("[heartbeat] Active turn failed: \(error)")
            return .skip
        }
    }

    /// Check cache health from API response token usage.
    ///
    /// - Parameters:
    ///   - usage: Token usage from the API response.
    ///   - compactionSinceSnapshot: Whether compaction ran since the snapshot was captured.
    /// - Returns: Health status — `.fatal` if cache is broken without compaction excuse.
    static func checkCacheHealth(
        usage: TokenUsage,
        compactionSinceSnapshot: Bool,
    ) -> CacheHealthResult {
        // If input tokens are very low, this might be a minimal prompt — don't assert
        guard usage.inputTokens > 4_096 else { return .ok }

        if usage.cacheReadTokens == 0 {
            return compactionSinceSnapshot ? .warning : .fatal
        }

        // Check hit ratio — warn if less than 50%
        let total = usage.inputTokens + usage.cacheReadTokens + usage.cacheCreationTokens
        let ratio = Double(usage.cacheReadTokens) / Double(max(1, total))
        if ratio < 0.5 {
            return .warning
        }

        return .ok
    }
}

/// Minimal observer that collects the final response text.
///
/// Used by ``HeartbeatEngine`` for active heartbeat turns. The coordinator
/// calls `handleEvent` from its own isolation; the engine reads `responseText`
/// after the turn completes.
actor SilentTurnObserver: TurnObserver {
    var responseText: String = ""
    func handleEvent(_ event: TurnEvent) {
        if case let .responseCompleted(text) = event {
            responseText = text
        }
    }
}
