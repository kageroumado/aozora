import Foundation

/// Governs valid state transitions during a single cognitive turn.
///
/// The turn state machine enforces a strict transition graph: `received -> salience ->
/// contextBuild -> executiveInfer -> streaming -> persist -> complete`, with an optional
/// `workerExec` loop from `streaming` that returns to `streaming` on completion.
/// Any state can also transition to `failed`.
///
/// Invalid transitions are rejected by returning `false` from ``transition(to:)``,
/// and the machine's state remains unchanged. This prevents the coordinator from
/// accidentally skipping stages or going backwards.
public nonisolated struct TurnStateMachine: Sendable {
    /// The current state of the turn.
    public private(set) var state: TurnState

    /// Creates a new state machine in the given initial state.
    ///
    /// - Parameter initial: The starting state. Defaults to `.received`.
    public init(initial: TurnState = .received) {
        self.state = initial
    }

    /// Attempt a state transition.
    ///
    /// Returns `true` if the transition is valid and was applied, or `false` if the
    /// transition is illegal (state remains unchanged). Every state can transition
    /// to `.failed` as an escape hatch for error handling.
    ///
    /// Valid transitions:
    /// - `received` -> `salience`
    /// - `salience` -> `contextBuild`
    /// - `contextBuild` -> `executiveInfer`
    /// - `executiveInfer` -> `streaming`
    /// - `streaming` -> `workerExec`, `persist`
    /// - `workerExec` -> `streaming`, `persist`
    /// - `persist` -> `complete`
    /// - Any state -> `failed`
    ///
    /// - Parameter target: The desired next state.
    /// - Returns: `true` if the transition was applied, `false` if it was rejected.
    @discardableResult
    public mutating func transition(to target: TurnState) -> Bool {
        guard isValid(from: state, to: target) else {
            return false
        }
        state = target
        return true
    }

    /// Check whether a transition from one state to another is valid.
    ///
    /// - Parameters:
    ///   - from: The current state.
    ///   - to: The proposed next state.
    /// - Returns: `true` if the transition is permitted by the state graph.
    public func isValid(from: TurnState, to: TurnState) -> Bool {
        if to == .failed {
            return from != .complete && from != .failed
        }

        return switch (from, to) {
        case (.received, .salience):
            true
        case (.salience, .contextBuild):
            true
        case (.contextBuild, .executiveInfer):
            true
        case (.executiveInfer, .streaming):
            true
        case (.streaming, .workerExec):
            true
        case (.streaming, .persist):
            true
        case (.workerExec, .streaming):
            true
        case (.workerExec, .persist):
            true
        case (.persist, .complete):
            true
        default:
            false
        }
    }
}
