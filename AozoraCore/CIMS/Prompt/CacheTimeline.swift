import Foundation

/// Tracks prompt cache freshness to gate compaction while the cache is warm.
///
/// Anthropic's prompt cache has a 5-minute TTL. Compacting messages into summaries
/// changes the summary content in system blocks, invalidating the entire system-level
/// cache (the API hashes the system array as one unit). By deferring compaction while
/// the cache is warm, we avoid unnecessary cache misses during active conversation.
///
/// Used by ``CIMSCoordinator`` to decide whether to run ``MemoryStore/compactIfNeeded()``
/// immediately or defer it via ``CIMSCoordinator/pendingCompaction``.
public struct CacheTimeline: Sendable {
    /// When the last API call was made (the cache was created/refreshed).
    public private(set) var lastCacheWrite: ContinuousClock.Instant?

    /// Anthropic's prompt cache TTL.
    public static let cacheTTL: Duration = .seconds(300)

    /// Whether the cache is still warm (within TTL of last write).
    public var isCacheWarm: Bool {
        guard let lastWrite = lastCacheWrite else { return false }
        return ContinuousClock.now - lastWrite < Self.cacheTTL
    }

    /// Time remaining until cache expires. Zero if already expired.
    public var timeUntilExpiry: Duration {
        guard let lastWrite = lastCacheWrite else { return .zero }
        let elapsed = ContinuousClock.now - lastWrite
        return max(.zero, Self.cacheTTL - elapsed)
    }

    /// Record that a cache write (API call) just happened.
    public mutating func recordCacheWrite() {
        lastCacheWrite = .now
    }

    public init() {}
}
