import Foundation

/// Tracks resource pressure and adapts system behavior via allostatic modes.
///
/// ``AllostasisState`` maintains a sliding window of recent API latencies and token usage,
/// computes a pressure metric from these observations, and maps it to an ``AllostasisMode``
/// that governs retrieval depth, response verbosity, and worker dispatch decisions.
///
/// The state is designed to degrade gracefully — under pressure, the system reduces
/// retrieval scope and response length rather than failing. Pressure partially persists
/// across sessions so the system remembers being under strain.
///
/// Owned by ``CIMSCoordinator`` as a struct (no actor isolation of its own).
public nonisolated struct AllostasisState: Sendable {
    /// Maximum number of recent turns tracked in the sliding window.
    private static let windowSize = 20

    /// Baseline latency (seconds) considered "normal" for pressure calculation.
    private static let baselineLatencySeconds: Double = 2.0

    /// Token budget considered "full" for pressure normalization.
    private static let fullTokenBudget = CIMSDefaults.defaultContextBudget

    /// Recent turn records in the sliding window.
    public private(set) var recentTurns: [TurnRecord]

    /// Total tokens consumed in the current session.
    public private(set) var sessionTokensUsed: Int

    /// The total token budget for the session.
    public private(set) var sessionTokenBudget: Int

    /// A record of a single turn's resource consumption.
    public struct TurnRecord: Sendable {
        /// Tokens consumed by this turn (input + output).
        public let tokensUsed: Int

        /// Wall-clock latency for the model inference in seconds.
        public let latencySeconds: Double

        public init(tokensUsed: Int, latencySeconds: Double) {
            self.tokensUsed = tokensUsed
            self.latencySeconds = latencySeconds
        }
    }

    /// Creates a new allostasis state.
    ///
    /// - Parameters:
    ///   - recentTurns: Pre-existing turn records (e.g., restored from persistence).
    ///   - sessionTokensUsed: Tokens already consumed this session.
    ///   - sessionTokenBudget: Total token budget for the session.
    public init(
        recentTurns: [TurnRecord] = [],
        sessionTokensUsed: Int = 0,
        sessionTokenBudget: Int = CIMSDefaults.defaultContextBudget,
    ) {
        self.recentTurns = recentTurns
        self.sessionTokensUsed = sessionTokensUsed
        self.sessionTokenBudget = sessionTokenBudget
    }

    // MARK: - Recording

    /// Record a completed turn's resource consumption.
    ///
    /// Appends to the sliding window (dropping the oldest record if at capacity)
    /// and accumulates the session token count.
    ///
    /// - Parameters:
    ///   - tokensUsed: Total tokens consumed by this turn.
    ///   - latency: Wall-clock latency for the model inference.
    public mutating func recordTurn(tokensUsed: Int, latency: Duration) {
        let seconds = Double(latency.components.seconds)
            + Double(latency.components.attoseconds) / 1e18

        let record = TurnRecord(tokensUsed: tokensUsed, latencySeconds: seconds)
        recentTurns.append(record)

        if recentTurns.count > Self.windowSize {
            recentTurns.removeFirst(recentTurns.count - Self.windowSize)
        }

        sessionTokensUsed += tokensUsed
    }

    // MARK: - Pressure Computation

    /// Compute the current pressure metric from recent history.
    ///
    /// Pressure is the maximum of two independent signals:
    /// - **Latency pressure**: ratio of average recent latency to baseline, excess above baseline
    /// - **Budget pressure**: fraction of session token budget consumed
    ///
    /// Using `max` ensures that either signal alone can drive the system into
    /// conservative or recovery mode — a system running out of budget shouldn't be
    /// masked by low latency, and vice versa.
    ///
    /// The result is clamped to 0-1.
    ///
    /// - Returns: Pressure value in 0-1.
    public func pressure() -> Float {
        let latencyPressure = averageLatencyPressure()
        let budgetPressure = budgetConsumptionPressure()

        return clamp01(max(latencyPressure, budgetPressure))
    }

    /// Compute the current allostatic mode from pressure.
    ///
    /// Mode thresholds from ``CIMSDefaults``:
    /// - < `allostasisExploratoryThreshold` (0.3) → `exploratory`
    /// - < `allostasisConservativeThreshold` (0.7) → `balanced`
    /// - < `allostasisRecoveryThreshold` (0.9) → `conservative`
    /// - >= 0.9 → `recovery`
    ///
    /// - Returns: The current allostatic mode.
    public func mode() -> AllostasisMode {
        let p = pressure()

        if p < CIMSDefaults.allostasisExploratoryThreshold {
            return .exploratory
        } else if p < CIMSDefaults.allostasisConservativeThreshold {
            return .balanced
        } else if p < CIMSDefaults.allostasisRecoveryThreshold {
            return .conservative
        } else {
            return .recovery
        }
    }

    // MARK: - Budget Exposure

    /// The effective context token budget, scaled down under pressure.
    ///
    /// - `exploratory`: 100% of default budget
    /// - `balanced`: 80%
    /// - `conservative`: 50%
    /// - `recovery`: 30%
    public var contextBudget: Int {
        // With 1M context, always use the full budget. Allostasis mode switching
        // was designed for smaller windows where throttling made sense.
        // The assembler handles budget fitting internally.
        CIMSDefaults.defaultContextBudget
    }

    /// The effective retrieval budget (max summary nodes), scaled down under pressure.
    ///
    /// - `exploratory`: 100% of default budget
    /// - `balanced`: 80%
    /// - `conservative`: 50%
    /// - `recovery`: 25%
    public var retrievalBudget: Int {
        let base = CIMSDefaults.defaultRetrievalBudget
        let fraction = switch mode() {
        case .exploratory: 1.0
        case .balanced: 0.8
        case .conservative: 0.5
        case .recovery: 0.25
        }
        return max(1, Int(Double(base) * fraction))
    }

    // MARK: - Internal Metrics

    /// Average latency pressure from the sliding window.
    ///
    /// Ratio of average recent latency to baseline, clamped to 0-1.
    private func averageLatencyPressure() -> Float {
        guard !recentTurns.isEmpty else { return 0 }

        let totalLatency = recentTurns.reduce(0.0) { $0 + $1.latencySeconds }
        let avgLatency = totalLatency / Double(recentTurns.count)

        return clamp01(Float(avgLatency / Self.baselineLatencySeconds) - 1.0)
    }

    /// Budget consumption pressure.
    ///
    /// Fraction of session token budget consumed, normalized to 0-1.
    private func budgetConsumptionPressure() -> Float {
        // With a 1M context window, cumulative session token usage is not meaningful
        // for pressure — each turn assembles context independently. The per-turn
        // context assembly handles budget fitting. Only apply pressure if a single
        // turn used a very large fraction of the budget.
        guard sessionTokenBudget > 0, !recentTurns.isEmpty else { return 0 }
        let lastTurnTokens = recentTurns.last?.tokensUsed ?? 0
        return clamp01(Float(lastTurnTokens) / Float(sessionTokenBudget))
    }

    /// Clamp a float to the 0-1 range.
    private func clamp01(_ value: Float) -> Float {
        min(max(value, 0), 1)
    }
}
