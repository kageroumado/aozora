@testable import Aozora

/// Test observer that collects all turn events into an array.
///
/// Replaces the old pattern of iterating `AsyncThrowingStream<TurnEvent>`.
/// Thread-safe via `@unchecked Sendable` — tests are sequential within each turn.
final class CollectingObserver: TurnObserver, @unchecked Sendable {
    private(set) var events: [TurnEvent] = []

    func handleEvent(_ event: TurnEvent) async {
        events.append(event)
    }
}

/// Convenience: run a turn and collect all events.
///
/// Replaces the old two-step pattern:
/// ```swift
/// let stream = try await coordinator.runTurn(request)
/// let events = try await collectEvents(from: stream)
/// ```
///
/// With:
/// ```swift
/// let events = try await runTurnCollecting(coordinator, request)
/// ```
func runTurnCollecting(
    _ coordinator: CIMSCoordinator,
    _ request: TurnRequest,
) async throws -> [TurnEvent] {
    let observer = CollectingObserver()
    try await coordinator.runTurn(request, observer: observer)
    return observer.events
}

/// Convenience: run a turn through the gateway and collect all events.
func runTurnCollecting(
    _ gateway: CIMSGateway,
    _ request: TurnRequest,
) async throws -> [TurnEvent] {
    let observer = CollectingObserver()
    try await gateway.runTurn(request, observer: observer)
    return observer.events
}
