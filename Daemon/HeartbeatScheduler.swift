import Foundation

/// Periodic scheduler for the Aozora daemon.
///
/// Runs a single `Task.sleep` loop that fires every 60 seconds, handling three
/// responsibilities from one place:
/// 1. **Cron**: check for due jobs and enqueue them as events
/// 2. **Inspector**: broadcast telemetry snapshots to connected IPC clients
/// 3. **Heartbeat**: post cache-warming events every Nth tick (N = `intervalMinutes`)
///
/// `Task.sleep` is the correct pattern for a daemon timer — cooperative, cancellation-aware,
/// and the daemon is always-on so power scheduling (`NSBackgroundActivityScheduler`) provides
/// no benefit and would add unpredictable jitter to cache TTL timing.
actor HeartbeatScheduler {
    /// The event queue to post heartbeat and cron events to.
    private let eventQueue: AsyncQueue<DaemonEvent>

    /// Interval between heartbeats in minutes.
    let intervalMinutes: Int

    /// The single loop task. `nil` when stopped.
    private var loop: Task<Void, Never>?

    /// Whether heartbeat posting is enabled (can be toggled without stopping cron/inspector).
    private var heartbeatsEnabled = true

    /// The cron scheduler, wired after creation.
    private var cronScheduler: CronScheduler?

    /// Per-tick callback for inspector snapshots and other periodic work.
    private var onTick: (@Sendable () async -> Void)?

    /// Whether the scheduler loop is running.
    var isRunning: Bool {
        loop != nil
    }

    /// Timestamp of the most recent user message.
    /// Heartbeats are suppressed within 2 minutes of activity.
    private var lastActivityAt: Date = .distantPast

    /// Ticks elapsed since the last heartbeat was posted.
    private var ticksSinceHeartbeat = 0

    /// Creates a heartbeat scheduler.
    ///
    /// - Parameters:
    ///   - eventQueue: The daemon's central event queue.
    ///   - intervalMinutes: Minutes between heartbeats. Defaults to 4 (keeps prompt
    ///     cache warm within the 5-minute TTL).
    init(eventQueue: AsyncQueue<DaemonEvent>, intervalMinutes: Int = 4) {
        self.eventQueue = eventQueue
        self.intervalMinutes = intervalMinutes
    }

    // MARK: - Configuration

    /// Set the per-tick callback (e.g., broadcasting inspector snapshots to IPC clients).
    func setOnTick(_ callback: @escaping @Sendable () async -> Void) {
        onTick = callback
    }

    /// Wire a ``CronScheduler`` for periodic job checking.
    func setCronScheduler(_ scheduler: CronScheduler) {
        cronScheduler = scheduler
    }

    // MARK: - Lifecycle

    /// Start the 60-second loop. No-op if already running.
    func start() {
        guard loop == nil else { return }
        loop = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(60))
                guard let self else { break }
                await tick()
            }
        }
    }

    /// Stop the loop entirely (heartbeat + cron + inspector).
    func stop() {
        loop?.cancel()
        loop = nil
    }

    /// Disable heartbeat posting. Cron and inspector continue.
    func stopHeartbeats() {
        heartbeatsEnabled = false
        print("[heartbeat] Disabled")
    }

    /// Re-enable heartbeat posting.
    func restartHeartbeats() {
        heartbeatsEnabled = true
        ticksSinceHeartbeat = 0
        print("[heartbeat] Re-enabled")
    }

    /// Record user message activity — suppresses heartbeats for 2 minutes.
    func recordActivity() {
        lastActivityAt = Date()
    }

    // MARK: - Tick

    /// Single tick dispatching all periodic work.
    private func tick() async {
        // 1. Inspector snapshot push
        await onTick?()

        // 2. Cron job check
        if let scheduler = cronScheduler {
            let fired = await scheduler.tick()
            for job in fired {
                await eventQueue.enqueue(.cronJobFired(job))
            }
        }

        // 3. Heartbeat (fires every intervalMinutes ticks)
        guard heartbeatsEnabled else { return }
        ticksSinceHeartbeat += 1
        guard ticksSinceHeartbeat >= intervalMinutes else { return }
        ticksSinceHeartbeat = 0

        let secondsSinceActivity = Date().timeIntervalSince(lastActivityAt)
        if secondsSinceActivity < 120 {
            return
        }

        await eventQueue.enqueue(.heartbeat)
    }
}
