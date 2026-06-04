import Foundation

/// Computes the system's qualitative experience of time and manages context cooling.
///
/// ``ChronoState`` is a value type that represents the temporal dimension of the cognitive
/// architecture. It computes ``TemporalMode`` from the gap duration between sessions and
/// provides a rendering function that produces a human-readable summary for context injection.
///
/// Owned by ``CIMSCoordinator`` as a struct (no actor isolation of its own). Mutated when
/// a new session begins or interactions occur within a session.
public nonisolated struct ChronoState: Sendable {
    /// Timestamp of the most recent interaction, or `nil` for a brand-new user.
    public private(set) var lastInteractionAt: Date?

    /// When the current session began.
    public private(set) var sessionStartedAt: Date?

    /// Total number of sessions with this user.
    public private(set) var sessionCount: Int

    /// Per-topic staleness scores — keys are topic identifiers, values are staleness (0-1).
    /// Higher values mean the topic is staler and should rank lower during assembly.
    public private(set) var contextCooling: [String: Float]

    /// Creates a new chrono state.
    ///
    /// - Parameters:
    ///   - lastInteractionAt: Timestamp of the last interaction, or `nil` for first interaction.
    ///   - sessionStartedAt: When the current session started, or `nil` if not yet started.
    ///   - sessionCount: Number of previous sessions.
    ///   - contextCooling: Initial per-topic staleness map.
    public init(
        lastInteractionAt: Date? = nil,
        sessionStartedAt: Date? = nil,
        sessionCount: Int = 0,
        contextCooling: [String: Float] = [:],
    ) {
        self.lastInteractionAt = lastInteractionAt
        self.sessionStartedAt = sessionStartedAt
        self.sessionCount = sessionCount
        self.contextCooling = contextCooling
    }

    // MARK: - Temporal Mode Computation

    /// Compute the temporal mode from the gap between the last interaction and now.
    ///
    /// Thresholds:
    /// - `nil` last interaction → `newSession`
    /// - < 1 hour → `continuation`
    /// - 1–24 hours → `softReconnection`
    /// - 1–7 days → `reconnection`
    /// - > 7 days → `reunion`
    ///
    /// - Parameter now: The current timestamp (injectable for testing).
    /// - Returns: The computed temporal mode.
    public func temporalMode(at now: Date = Date()) -> TemporalMode {
        guard let last = lastInteractionAt else {
            return .newSession
        }

        let gap = now.timeIntervalSince(last)
        return Self.mode(forGapSeconds: gap)
    }

    /// Compute temporal mode from a raw gap in seconds.
    ///
    /// Factored out for direct unit testing of threshold boundaries.
    ///
    /// - Parameter seconds: The gap duration in seconds.
    /// - Returns: The corresponding temporal mode.
    public static func mode(forGapSeconds seconds: TimeInterval) -> TemporalMode {
        switch seconds {
        case ..<3_600:
            .continuation
        case ..<86_400:
            .softReconnection
        case ..<604_800:
            .reconnection
        default:
            .reunion
        }
    }

    /// The gap duration between the last interaction and now, or `nil` for a new session.
    ///
    /// - Parameter now: The current timestamp.
    /// - Returns: The gap duration, or `nil` if there's no last interaction.
    public func gapDuration(at now: Date = Date()) -> TimeInterval? {
        guard let last = lastInteractionAt else { return nil }
        return now.timeIntervalSince(last)
    }

    // MARK: - Session Management

    /// Record that a new session has started.
    ///
    /// Updates `sessionStartedAt` to `now` and increments the session count.
    ///
    /// - Parameter now: The session start timestamp.
    public mutating func beginSession(at now: Date = Date()) {
        sessionStartedAt = now
        sessionCount += 1
    }

    /// Record that an interaction occurred.
    ///
    /// Updates `lastInteractionAt` to the given timestamp.
    ///
    /// - Parameter now: The interaction timestamp.
    public mutating func recordInteraction(at now: Date = Date()) {
        lastInteractionAt = now
    }

    // MARK: - Context Cooling

    /// Apply time-based decay to all tracked topics.
    ///
    /// Each topic's staleness increases toward 1.0 based on how long since it was last
    /// mentioned. Uses exponential decay toward 1.0 with a half-life of 24 hours.
    ///
    /// - Parameter elapsed: Time since the last cooling update, in seconds.
    public mutating func applyCooling(elapsed: TimeInterval) {
        guard elapsed > 0 else { return }
        let lambda = log(2.0) / 86_400.0
        for key in contextCooling.keys {
            let current = contextCooling[key] ?? 0
            let decayed = 1.0 - (1.0 - Double(current)) * exp(-lambda * elapsed)
            contextCooling[key] = Float(min(max(decayed, 0), 1))
        }
    }

    /// Refresh a topic's staleness score, resetting it toward freshness.
    ///
    /// Called when a topic is mentioned in conversation. Sets its staleness to 0.
    ///
    /// - Parameter topic: The topic identifier to refresh.
    public mutating func refreshTopic(_ topic: String) {
        contextCooling[topic] = 0
    }

    /// Get the staleness score for a topic.
    ///
    /// Returns 0 (fresh) if the topic isn't tracked.
    ///
    /// - Parameter topic: The topic identifier.
    /// - Returns: The staleness score (0 = fresh, 1 = fully stale).
    public func staleness(of topic: String) -> Float {
        contextCooling[topic] ?? 0
    }

    // MARK: - Rendering

    /// Render the chronoception state as a context-injectable string.
    ///
    /// Produces a compact representation suitable for the chronoception section of
    /// the assembled context. Includes session duration, gap since last session, and
    /// the current temporal mode.
    ///
    /// - Parameter now: The current timestamp (injectable for testing).
    /// - Returns: A formatted string for context injection.
    public func render(at now: Date = Date()) -> String {
        let mode = temporalMode(at: now)

        let sessionDuration: String
        if let start = sessionStartedAt {
            let minutes = Int(now.timeIntervalSince(start) / 60)
            sessionDuration = "\(minutes) min"
        } else {
            sessionDuration = "not started"
        }

        let gapDescription: String = if let gap = gapDuration(at: now) {
            Self.formatGap(gap)
        } else {
            "first interaction"
        }

        return "[Session: \(sessionDuration) | Gap: \(gapDescription) (\(mode.rawValue) mode) | Sessions total: \(sessionCount)]"
    }

    /// Format a gap duration as a human-readable string.
    ///
    /// - Parameter seconds: The gap in seconds.
    /// - Returns: A formatted string like "3 hours", "2 days", etc.
    public static func formatGap(_ seconds: TimeInterval) -> String {
        let minutes = Int(seconds / 60)
        let hours = Int(seconds / 3_600)
        let days = Int(seconds / 86_400)

        if minutes < 1 {
            return "<1 min"
        } else if minutes < 60 {
            return "\(minutes) min"
        } else if hours < 24 {
            return "\(hours) hour\(hours == 1 ? "" : "s")"
        } else {
            return "\(days) day\(days == 1 ? "" : "s")"
        }
    }
}
