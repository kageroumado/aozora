import Foundation

/// Protocol for receiving observer cycle notifications from the scheduler.
///
/// Conformers implement the cycle callback to process assembled input and run
/// the observer's sense → integrate → generate pipeline.
public protocol DMNCycleDelegate: AnyObject, Sendable {
    /// Called when an observer cycle is due.
    ///
    /// - Parameter input: The assembled input for this cycle.
    func observerCycleDue(input: DMNCycleInput) async
}

/// Actor that schedules periodic observer DMN cycles.
///
/// Manages the timing of the observer's background processing loop. Cycles run at
/// a configurable interval (default 5 minutes) and can be triggered early for
/// high-priority events. The scheduler delegates actual cycle execution to a
/// ``DMNCycleDelegate``.
///
/// Uses `Task.detached` for the timer loop to ensure it runs off MainActor.
public actor DMNCycleScheduler {
    /// The interval between observer cycles.
    public let cycleInterval: TimeInterval

    /// Whether the scheduler is currently running.
    private(set) var isRunning: Bool = false

    /// The delegate that receives cycle notifications.
    private weak var delegate: (any DMNCycleDelegate)?

    /// The running timer task, if any.
    private var timerTask: Task<Void, Never>?

    /// Creates a scheduler with the given interval and delegate.
    ///
    /// - Parameters:
    ///   - cycleInterval: Seconds between cycles. Defaults to ``CIMSDefaults/observerCycleInterval``.
    ///   - delegate: The delegate to notify when a cycle is due.
    public init(
        cycleInterval: TimeInterval = CIMSDefaults.observerCycleInterval,
        delegate: (any DMNCycleDelegate)? = nil,
    ) {
        self.cycleInterval = cycleInterval
        self.delegate = delegate
    }

    /// Set the delegate that receives cycle notifications.
    ///
    /// - Parameter delegate: The new delegate.
    public func setDelegate(_ delegate: any DMNCycleDelegate) {
        self.delegate = delegate
    }

    /// Start the periodic cycle scheduler.
    ///
    /// Idempotent — calling `start()` when already running has no effect.
    public func start() {
        guard !isRunning else { return }
        isRunning = true

        let interval = cycleInterval
        let delegate = delegate

        timerTask = Task.detached { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(interval))

                guard !Task.isCancelled else { break }

                let input = DMNCycleInput(
                    newMessages: [],
                    narratorResponse: nil,
                    noveltyFragment: nil,
                )

                await delegate?.observerCycleDue(input: input)

                guard let self else { break }
                guard await isRunning else { break }
            }
        }
    }

    /// Stop the periodic cycle scheduler.
    public func stop() {
        isRunning = false
        timerTask?.cancel()
        timerTask = nil
    }

    /// Trigger an immediate cycle outside the normal schedule.
    ///
    /// - Parameter reason: Why this early trigger was requested (for diagnostics).
    public func triggerEarly(reason _: String) {
        let delegate = delegate

        Task.detached {
            let input = DMNCycleInput(
                newMessages: [],
                narratorResponse: nil,
                noveltyFragment: nil,
            )
            await delegate?.observerCycleDue(input: input)
        }
    }
}
