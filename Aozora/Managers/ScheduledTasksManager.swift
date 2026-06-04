import AozoraCore
import Foundation
import Observation

/// Coordinates periodic background tasks for archive expiration and auto-archive rules.
///
/// This manager uses `NSBackgroundActivityScheduler` for energy-efficient hourly task
/// execution, plus app activation triggers for immediate execution after idle periods.
///
/// ## Overview
///
/// Registered tasks run:
/// - Hourly via system-optimized scheduler (with ±10 minute tolerance for batching)
/// - On app activation if 60+ minutes have elapsed since last run
/// - Immediately on startup
///
/// ```swift
/// let scheduler = ScheduledTasksManager(activationObserver: observer)
///
/// scheduler.registerTask { [weak archiveManager] in
///     await archiveManager?.clearExpired()
/// }
///
/// scheduler.start()
/// ```
///
/// ## Power Efficiency
///
/// `NSBackgroundActivityScheduler` allows the system to defer, batch, or skip tasks
/// based on battery state, thermal conditions, and CPU load. The 10-minute tolerance
/// enables meaningful power savings while remaining imperceptible to users.
@Observable
final class ScheduledTasksManager {
    // MARK: - State

    /// Timestamp of the last successful task run.
    ///
    /// Used to determine if tasks should run immediately on app activation.
    private(set) var lastTaskRun: Date?

    // MARK: - Configuration

    /// Minimum interval between task runs (60 minutes).
    private let minimumInterval: TimeInterval = 3_600

    /// Tolerance for scheduler flexibility (10 minutes).
    private let schedulerTolerance: TimeInterval = 600
    
    // MARK: - Dependencies

    @ObservationIgnored
    private let activationObserver: AppActivationObserver

    // MARK: - Private State

    @ObservationIgnored
    private let scheduler = NSBackgroundActivityScheduler(
        identifier: AppConstants.backgroundActivitySchedulerID,
    )

    @ObservationIgnored
    private var registeredTasks: [@Sendable @isolated(any) () async -> Void] = []

    @ObservationIgnored
    private var activationTask: Task<Void, any Error>?

    @ObservationIgnored
    private var isRunning = false
    
    // MARK: - Initialization

    /// Creates a scheduled tasks manager.
    ///
    /// - Parameter activationObserver: Observer for app activation events.
    init(activationObserver: AppActivationObserver) {
        self.activationObserver = activationObserver
    }

    // MARK: - Task Registration

    /// Registers a task to run on the hourly schedule.
    ///
    /// Tasks are executed sequentially in registration order.
    /// Registration must happen before calling ``start()``.
    ///
    /// - Parameter task: An async closure to execute on schedule.
    func registerTask(_ task: @Sendable @escaping @isolated(any) () async -> Void) {
        registeredTasks.append(task)
    }

    // MARK: - Lifecycle

    /// Starts the scheduled task system.
    ///
    /// Safe to call multiple times; subsequent calls are no-ops.
    func start() {
        guard !isRunning else { return }
        isRunning = true

        setupScheduler()
        startActivationListener()
    }

    /// Stops the scheduled task system.
    func stop() {
        guard isRunning else { return }
        isRunning = false

        activationTask?.cancel()
        activationTask = nil

        scheduler.invalidate()
    }

    /// Manually triggers task execution.
    func runNow() async {
        await runTasks()
    }

    // MARK: - Private
    
    private func setupScheduler() {
        scheduler.interval = minimumInterval
        scheduler.tolerance = schedulerTolerance
        scheduler.repeats = true
        scheduler.qualityOfService = .background
        scheduler.schedule { [weak self] completionHandler in
            guard let self else {
                completionHandler(.finished)
                return
            }
            Task { @MainActor [self] in
                if scheduler.shouldDefer == true {
                    completionHandler(.deferred)
                    return
                }

                await runTasks()
                completionHandler(.finished)
            }
        }
    }

    private func startActivationListener() {
        activationTask = Task { [weak self] in
            guard let self else { return }

            for await _ in activationObserver.makeActivationsStream() {
                try Task.checkCancellation()

                if let lastRun = lastTaskRun {
                    let elapsed = Date.now.timeIntervalSince(lastRun)
                    guard elapsed >= minimumInterval else { continue }
                }

                await runTasks()
            }
        }
    }

    private func runTasks() async {
        lastTaskRun = .now

        await withTaskGroup { group in
            for task in registeredTasks {
                group.addTask(operation: task)
            }
        }
    }
}
