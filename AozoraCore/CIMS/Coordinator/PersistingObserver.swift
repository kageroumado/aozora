import Foundation

/// Observer that persists tool call results incrementally during a turn.
///
/// Wraps an inner ``TurnObserver`` and writes each tool result to the
/// database as it happens. If the turn crashes mid-chain, the database
/// contains a partial but truthful record of what occurred.
///
/// Fork turns should NOT use this observer — their tool history is ephemeral.
struct PersistingObserver: TurnObserver {
    /// The inner observer to forward all events to.
    let inner: any TurnObserver

    /// The memory store used for incremental writes.
    let memoryStore: MemoryStore

    /// The session key identifying the active conversation.
    let sessionKey: String

    func handleEvent(_ event: TurnEvent) async {
        await inner.handleEvent(event)

        switch event {
        case let .toolResult(result):
            await memoryStore.persistToolResult(
                toolUseId: result.toolUseId,
                content: result.content,
                isError: result.isError,
                sessionKey: sessionKey,
            )
        default:
            break
        }
    }
}
