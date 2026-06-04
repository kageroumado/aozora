/// Minimal turn observer for CLI commands.
///
/// Captures the final response text from `.responseCompleted` events.
/// All other turn lifecycle events are silently ignored — no Discord,
/// no streaming display, no typing indicators.
final actor CLITurnObserver: TurnObserver {
    /// The accumulated response text from the model.
    private(set) var responseText: String = ""

    func handleEvent(_ event: TurnEvent) async {
        if case let .responseCompleted(text) = event {
            responseText = text
        }
    }
}
