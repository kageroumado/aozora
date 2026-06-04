import Foundation

/// Manages automatic consolidation scheduling based on idle timeouts and session lifecycle events.
///
/// The scheduler sits between the gateway (which knows about turn completion and session
/// lifecycle) and the ``ConsolidationEngine`` (which runs the actual pipeline). It ensures
/// consolidation runs at the right times without blocking the online cognitive cycle:
///
/// - **Idle timeout** (15 min default): After each turn completes, resets a timer. If no
///   further activity occurs within the timeout, triggers consolidation.
/// - **Session end** (5 min default): When a user disconnects, starts a shorter timer
///   for session wrap-up consolidation.
/// - **Manual**: Immediate trigger, cancels any pending timers.
///
/// Only one consolidation runs at a time. If a trigger fires while a run is in progress,
/// it is silently dropped — the next scheduled trigger will pick up any remaining work.
public actor ConsolidationScheduler {
    /// The consolidation engine to invoke when a trigger fires.
    private let engine: ConsolidationEngine

    /// Duration of inactivity after a turn before idle consolidation fires.
    private let idleTimeout: Duration

    /// Duration after session end before session-end consolidation fires.
    private let sessionEndDelay: Duration

    /// The currently scheduled idle or session-end timer task.
    private var scheduledTask: Task<Void, Never>?

    /// Whether a consolidation run is currently in progress.
    private var isRunning: Bool = false

    /// Creates a consolidation scheduler wired to the given engine.
    ///
    /// - Parameters:
    ///   - engine: The consolidation engine to invoke on trigger.
    ///   - idleTimeout: Inactivity duration before idle consolidation.
    ///   - sessionEndDelay: Delay after session end before session-end consolidation.
    public init(
        engine: ConsolidationEngine,
        idleTimeout: Duration = CIMSDefaults.consolidationIdleTimeout,
        sessionEndDelay: Duration = CIMSDefaults.consolidationSessionEndDelay,
    ) {
        self.engine = engine
        self.idleTimeout = idleTimeout
        self.sessionEndDelay = sessionEndDelay
    }

    /// Called after each turn completes. Resets the idle timer.
    ///
    /// Cancels any existing scheduled task (idle or session-end) and starts a new idle
    /// timer. If no further activity occurs within ``idleTimeout``, triggers consolidation
    /// with ``ConsolidationTrigger/idleTimeout``.
    public func recordActivity() {
        scheduledTask?.cancel()
        scheduledTask = Task { [idleTimeout] in
            do {
                try await Task.sleep(for: idleTimeout)
            } catch {
                return
            }
            await runConsolidation(trigger: .idleTimeout)
        }
    }

    /// Called when a session ends (user disconnects). Starts the session-end timer.
    ///
    /// Cancels any existing idle timer and starts a session-end timer. If no further
    /// activity resets the timer within ``sessionEndDelay``, triggers consolidation
    /// with ``ConsolidationTrigger/sessionEnd``.
    public func recordSessionEnd() {
        scheduledTask?.cancel()
        scheduledTask = Task { [sessionEndDelay] in
            do {
                try await Task.sleep(for: sessionEndDelay)
            } catch {
                return
            }
            await runConsolidation(trigger: .sessionEnd)
        }
    }

    /// Force a consolidation run immediately (manual trigger).
    ///
    /// Cancels any pending timers and runs consolidation synchronously (from the
    /// caller's perspective — the actual pipeline is async). If a consolidation is
    /// already in progress, this call is a no-op.
    public func runNow() async {
        scheduledTask?.cancel()
        scheduledTask = nil
        await runConsolidation(trigger: .manual)
    }

    /// Stop all scheduled consolidation (for shutdown).
    ///
    /// Cancels any pending timer task. Does not interrupt a consolidation that is
    /// already running — that will complete naturally.
    public func stop() {
        scheduledTask?.cancel()
        scheduledTask = nil
    }

    // MARK: - Internal

    /// Execute a consolidation run if one isn't already in progress.
    ///
    /// Guards against concurrent runs — if ``isRunning`` is true, the trigger is
    /// silently dropped. This is safe because consolidation is idempotent and the
    /// next trigger will pick up any remaining work.
    ///
    /// - Parameter trigger: What triggered this consolidation run.
    private func runConsolidation(trigger: ConsolidationTrigger) async {
        guard !isRunning else {
            print("[ConsolidationScheduler] Skipping \(trigger.rawValue) — consolidation already in progress")
            return
        }

        isRunning = true
        print("[ConsolidationScheduler] Starting consolidation (trigger: \(trigger.rawValue))")

        await engine.consolidate(trigger: trigger)

        isRunning = false
        print("[ConsolidationScheduler] Consolidation complete (trigger: \(trigger.rawValue))")
    }
}
