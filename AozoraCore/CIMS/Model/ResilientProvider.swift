import Foundation
import os

/// A failover-capable wrapper around multiple ``ModelProviding`` instances.
///
/// `ResilientProvider` tries providers in priority order, failing over to the next
/// when a retryable error occurs. Each provider tracks its own cooldown state
/// (exponential backoff) and health metrics (success rate over a sliding window).
///
/// The provider chain is configurable: a single provider with no fallbacks behaves
/// identically to using that provider directly. With multiple providers, transient
/// failures (429, 500, 502, 503, 529, SSE `overloaded_error`) trigger transparent
/// failover without caller intervention.
///
/// Cooldown state persists across requests within a process but resets on restart.
public actor ResilientProvider: ModelProviding {
    /// An entry in the provider chain with associated health state.
    private struct ProviderEntry {
        let provider: any ModelProviding
        let name: String
        var cooldown: CooldownState
        var health: HealthTracker
    }

    /// Exponential backoff state for a single provider.
    struct CooldownState {
        var consecutiveFailures: Int = 0
        var cooldownUntil: Date = .distantPast

        /// Whether this provider is currently in cooldown.
        var isCoolingDown: Bool {
            Date.now < cooldownUntil
        }

        /// Record a failure and advance the cooldown.
        mutating func recordFailure(retryAfter: TimeInterval? = nil) {
            consecutiveFailures += 1
            let baseDelay = retryAfter ?? pow(2.0, Double(min(consecutiveFailures, 6)))
            let jitter = Double.random(in: 0 ... 0.5)
            cooldownUntil = Date.now.addingTimeInterval(baseDelay + jitter)
        }

        /// Reset cooldown after a successful request.
        mutating func recordSuccess() {
            consecutiveFailures = 0
            cooldownUntil = .distantPast
        }
    }

    /// Sliding-window success rate tracker for a single provider.
    struct HealthTracker {
        /// Maximum number of results to track.
        let windowSize: Int

        /// Ring buffer of outcomes: `true` = success, `false` = failure.
        private var outcomes: [Bool] = []

        init(windowSize: Int = 20) {
            self.windowSize = windowSize
        }

        /// Record an outcome.
        mutating func record(success: Bool) {
            outcomes.append(success)
            if outcomes.count > windowSize {
                outcomes.removeFirst()
            }
        }

        /// Current success rate (0.0–1.0). Returns 1.0 if no data.
        var successRate: Double {
            guard !outcomes.isEmpty else { return 1.0 }
            let successes = outcomes.count(where: { $0 })
            return Double(successes) / Double(outcomes.count)
        }

        /// Whether this provider should be deprioritized (< 30% success rate with enough data).
        var isDemoted: Bool {
            outcomes.count >= 5 && successRate < 0.3
        }
    }

    /// The ordered provider chain.
    private var entries: [ProviderEntry]

    /// Maximum retries per request across the entire chain.
    private let maxRetries: Int

    /// Threshold below which a provider is deprioritized.
    private let demotionThreshold: Double

    private static let logger = Logger(subsystem: "ai.aozora", category: "resilient-provider")

    /// Create a resilient provider wrapping a chain of providers.
    ///
    /// - Parameters:
    ///   - providers: Named providers in priority order. First is primary.
    ///   - maxRetries: Maximum total attempts across the chain (default: 3).
    public init(
        providers: [(name: String, provider: any ModelProviding)],
        maxRetries: Int = 3,
    ) {
        self.entries = providers.map { entry in
            ProviderEntry(
                provider: entry.provider,
                name: entry.name,
                cooldown: CooldownState(),
                health: HealthTracker(),
            )
        }
        self.maxRetries = maxRetries
        self.demotionThreshold = 0.3
    }

    /// Convenience: wrap a single provider (passthrough, no failover).
    public init(single provider: any ModelProviding, name: String = "primary") {
        self.init(providers: [(name, provider)])
    }

    // MARK: - ModelProviding

    public nonisolated func complete(
        _ prompt: Prompt, tier: ModelTier,
    ) async throws -> ModelResponse {
        try await withRetry { provider in
            try await provider.complete(prompt, tier: tier)
        }
    }

    public nonisolated func stream(
        _ prompt: Prompt, tier: ModelTier,
    ) async throws -> AsyncThrowingStream<ModelDelta, any Error> {
        try await withRetry { provider in
            try await provider.stream(prompt, tier: tier)
        }
    }

    // MARK: - Retry Loop

    /// Execute an operation with failover across the provider chain.
    ///
    /// Tries providers in priority order (skipping cooled-down and demoted ones),
    /// retrying on transient errors up to ``maxRetries`` total attempts.
    private func withRetry<T: Sendable>(
        _ operation: @Sendable (any ModelProviding) async throws -> T,
    ) async throws -> T {
        var lastError: (any Error)?
        var attempts = 0

        let ordered = prioritizedIndices()

        for index in ordered {
            guard attempts < maxRetries else { break }

            let entry = entries[index]

            if entry.cooldown.isCoolingDown {
                Self.logger.debug("Skipping \(entry.name): cooling down")
                continue
            }

            attempts += 1

            do {
                let result = try await operation(entry.provider)
                await recordSuccess(at: index)
                return result
            } catch {
                lastError = error
                let classified = classify(error)

                Self.logger.warning(
                    "Provider \(entry.name) failed: \(String(describing: error))",
                )

                switch classified {
                case .fatal:
                    throw error

                case .retryable:
                    await recordFailure(at: index)

                case let .rateLimited(retryAfter):
                    await recordFailure(at: index, retryAfter: retryAfter)
                }
            }
        }

        throw lastError ?? CIMSError.modelError("All providers exhausted")
    }

    /// Get provider indices sorted by priority: non-demoted first, then demoted.
    /// Within each group, maintains original insertion order.
    private func prioritizedIndices() -> [Int] {
        let healthy = entries.indices.filter { !entries[$0].health.isDemoted }
        let demoted = entries.indices.filter { entries[$0].health.isDemoted }
        return healthy + demoted
    }

    // MARK: - State Updates

    private func recordSuccess(at index: Int) {
        entries[index].cooldown.recordSuccess()
        entries[index].health.record(success: true)
    }

    private func recordFailure(at index: Int, retryAfter: TimeInterval? = nil) {
        entries[index].cooldown.recordFailure(retryAfter: retryAfter)
        entries[index].health.record(success: false)
    }

    // MARK: - Error Classification

    /// Classification of provider errors for retry/failover decisions.
    enum ErrorClass {
        /// Non-recoverable: bad request, auth failure, context overflow.
        case fatal
        /// Transient: server error, overloaded. Safe to retry or failover.
        case retryable
        /// Rate limited with a suggested wait duration.
        case rateLimited(TimeInterval)
    }

    /// Classify a thrown error for retry decisions.
    func classify(_ error: any Error) -> ErrorClass {
        if let cimsError = error as? CIMSError {
            switch cimsError {
            case let .rateLimited(retryAfter, _):
                return .rateLimited(retryAfter)
            case .modelUnavailable:
                return .retryable
            case let .modelError(msg):
                if msg.contains("overloaded") || msg.contains("Server error") {
                    return .retryable
                }
                return .fatal
            case .contextOverflow:
                return .fatal
            default:
                return .fatal
            }
        }

        if let urlError = error as? URLError {
            switch urlError.code {
            case .timedOut, .networkConnectionLost, .notConnectedToInternet:
                return .retryable
            default:
                return .fatal
            }
        }

        return .fatal
    }

    // MARK: - Diagnostics

    /// Get health status for all providers in the chain.
    public func healthReport() -> [(name: String, successRate: Double, isCoolingDown: Bool, isDemoted: Bool)] {
        entries.map { entry in
            (
                name: entry.name,
                successRate: entry.health.successRate,
                isCoolingDown: entry.cooldown.isCoolingDown,
                isDemoted: entry.health.isDemoted,
            )
        }
    }

    /// Reset all cooldown and health state. Useful for testing.
    func resetAllState() {
        for i in entries.indices {
            entries[i].cooldown = CooldownState()
            entries[i].health = HealthTracker()
        }
    }
}
