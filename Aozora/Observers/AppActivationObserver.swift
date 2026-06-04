import AppKit
import Observation

/// Observes app activation events for use by scheduled tasks.
///
/// This observer tracks when Aozora becomes the frontmost application, publishing
/// activation events via an AsyncSequence and storing the last activation timestamp.
@Observable
final class AppActivationObserver {
    // MARK: - State

    /// Whether the app is currently active (frontmost).
    ///
    /// Updated on both activation and deactivation events. Initialized to false
    /// until the first activation event is observed.
    private(set) var isAppActive: Bool = false

    /// The timestamp of the most recent app activation.
    ///
    /// `nil` until the app is activated for the first time after this observer is created.
    private(set) var lastActivationTime: Date?

    // MARK: - Private

    @ObservationIgnored
    private var continuations: [UUID: AsyncStream<Date>.Continuation] = [:]

    /// The activation notification observer token.
    @ObservationIgnored
    private var activationObserver: (any NSObjectProtocol)!

    /// The deactivation notification observer token.
    @ObservationIgnored
    private var deactivationObserver: (any NSObjectProtocol)!

    // MARK: - Initialization

    init() {
        setupObservers()
    }

    isolated deinit {
        let notificationCenter = NSWorkspace.shared.notificationCenter
        if let activationObserver {
            notificationCenter.removeObserver(activationObserver)
        }
        if let deactivationObserver {
            notificationCenter.removeObserver(deactivationObserver)
        }
    }

    private func setupObservers() {
        activationObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification,
            object: nil,
            queue: .main,
        ) { [weak self] notification in
            guard notification.isForAozora, let self else { return }

            MainActor.assumeIsolated {
                handleActivation()
            }
        }

        deactivationObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didDeactivateApplicationNotification,
            object: nil,
            queue: .main,
        ) { [weak self] notification in
            guard notification.isForAozora, let self else { return }

            MainActor.assumeIsolated {
                handleDeactivation()
            }
        }
    }
    
    // MARK: - Async Sequence

    /// An async sequence that emits when the app becomes active.
    ///
    /// Each element is the activation timestamp. Use this with `for await` to
    /// react to activation events in a structured concurrency context.
    ///
    /// - Note: Each call creates a new stream subscription. The stream finishes
    ///   when this observer is deallocated.
    func makeActivationsStream() -> AsyncStream<Date> {
        let (stream, continuation) = AsyncStream.makeStream(of: Date.self)
        let id = UUID()
        continuations[id] = continuation

        continuation.onTermination = { [weak self] _ in
            DispatchQueue.main.async { self?.continuations.removeValue(forKey: id) }
        }

        return stream
    }

    private func handleActivation() {
        isAppActive = true

        let now = Date.now
        lastActivationTime = .now
        
        for continuation in continuations.values {
            continuation.yield(now)
        }
    }

    private func handleDeactivation() {
        isAppActive = false
    }
}

private nonisolated extension Notification {
    var isForAozora: Bool {
        guard
            let userInfo,
            let app = userInfo[NSWorkspace.applicationUserInfoKey]
            as? NSRunningApplication,
            app.bundleIdentifier == Bundle.main.bundleIdentifier
        else {
            return false
        }
        return true
    }
}
