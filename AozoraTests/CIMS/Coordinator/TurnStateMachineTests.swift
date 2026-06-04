import Foundation
import Testing
@testable import Aozora

@Suite("TurnStateMachine")
struct TurnStateMachineTests {
    // MARK: - Initial State

    @Test("Initial state is .received by default")
    func defaultInitialState() {
        let machine = TurnStateMachine()
        #expect(machine.state == .received)
    }

    @Test("Can initialize with a custom state")
    func customInitialState() {
        let machine = TurnStateMachine(initial: .streaming)
        #expect(machine.state == .streaming)
    }

    // MARK: - Valid Transitions (Happy Path)

    @Test("received -> salience is valid")
    func receivedToSalience() {
        var machine = TurnStateMachine()
        let ok = machine.transition(to: .salience)
        #expect(ok == true)
        #expect(machine.state == .salience)
    }

    @Test("salience -> contextBuild is valid")
    func salienceToContextBuild() {
        var machine = TurnStateMachine(initial: .salience)
        let ok = machine.transition(to: .contextBuild)
        #expect(ok == true)
        #expect(machine.state == .contextBuild)
    }

    @Test("contextBuild -> executiveInfer is valid")
    func contextBuildToExecutiveInfer() {
        var machine = TurnStateMachine(initial: .contextBuild)
        let ok = machine.transition(to: .executiveInfer)
        #expect(ok == true)
        #expect(machine.state == .executiveInfer)
    }

    @Test("executiveInfer -> streaming is valid")
    func executiveInferToStreaming() {
        var machine = TurnStateMachine(initial: .executiveInfer)
        let ok = machine.transition(to: .streaming)
        #expect(ok == true)
        #expect(machine.state == .streaming)
    }

    @Test("streaming -> persist is valid")
    func streamingToPersist() {
        var machine = TurnStateMachine(initial: .streaming)
        let ok = machine.transition(to: .persist)
        #expect(ok == true)
        #expect(machine.state == .persist)
    }

    @Test("persist -> complete is valid")
    func persistToComplete() {
        var machine = TurnStateMachine(initial: .persist)
        let ok = machine.transition(to: .complete)
        #expect(ok == true)
        #expect(machine.state == .complete)
    }

    // MARK: - Worker Loop Transitions

    @Test("streaming -> workerExec is valid")
    func streamingToWorkerExec() {
        var machine = TurnStateMachine(initial: .streaming)
        let ok = machine.transition(to: .workerExec)
        #expect(ok == true)
        #expect(machine.state == .workerExec)
    }

    @Test("workerExec -> streaming is valid (loop back)")
    func workerExecToStreaming() {
        var machine = TurnStateMachine(initial: .workerExec)
        let ok = machine.transition(to: .streaming)
        #expect(ok == true)
        #expect(machine.state == .streaming)
    }

    @Test("workerExec -> persist is valid (skip back to streaming)")
    func workerExecToPersist() {
        var machine = TurnStateMachine(initial: .workerExec)
        let ok = machine.transition(to: .persist)
        #expect(ok == true)
        #expect(machine.state == .persist)
    }

    @Test("Full happy path with worker loop completes successfully")
    func fullPathWithWorkerLoop() {
        var machine = TurnStateMachine()
        var ok = machine.transition(to: .salience)
        #expect(ok)
        ok = machine.transition(to: .contextBuild)
        #expect(ok)
        ok = machine.transition(to: .executiveInfer)
        #expect(ok)
        ok = machine.transition(to: .streaming)
        #expect(ok)
        ok = machine.transition(to: .workerExec)
        #expect(ok)
        ok = machine.transition(to: .streaming)
        #expect(ok)
        ok = machine.transition(to: .persist)
        #expect(ok)
        ok = machine.transition(to: .complete)
        #expect(ok)
        #expect(machine.state == .complete)
    }

    @Test("Full happy path without workers completes successfully")
    func fullPathNoWorkers() {
        var machine = TurnStateMachine()
        var ok = machine.transition(to: .salience)
        #expect(ok)
        ok = machine.transition(to: .contextBuild)
        #expect(ok)
        ok = machine.transition(to: .executiveInfer)
        #expect(ok)
        ok = machine.transition(to: .streaming)
        #expect(ok)
        ok = machine.transition(to: .persist)
        #expect(ok)
        ok = machine.transition(to: .complete)
        #expect(ok)
        #expect(machine.state == .complete)
    }

    // MARK: - Failed Transitions (Error Path)

    @Test("Any non-terminal state can transition to .failed")
    func anyStateCanFail() {
        let nonTerminalStates: [TurnState] = [
            .received, .salience, .contextBuild, .executiveInfer,
            .streaming, .workerExec, .persist,
        ]

        for state in nonTerminalStates {
            var machine = TurnStateMachine(initial: state)
            let ok = machine.transition(to: .failed)
            #expect(ok == true, "Expected \(state) -> .failed to be valid")
            #expect(machine.state == .failed)
        }
    }

    @Test(".complete cannot transition to .failed")
    func completeCannotFail() {
        var machine = TurnStateMachine(initial: .complete)
        let ok = machine.transition(to: .failed)
        #expect(ok == false)
        #expect(machine.state == .complete)
    }

    @Test(".failed cannot transition to .failed")
    func failedCannotFailAgain() {
        var machine = TurnStateMachine(initial: .failed)
        let ok = machine.transition(to: .failed)
        #expect(ok == false)
        #expect(machine.state == .failed)
    }

    // MARK: - Invalid Transitions

    @Test("received -> contextBuild is invalid (skips salience)")
    func receivedToContextBuildInvalid() {
        var machine = TurnStateMachine()
        let ok = machine.transition(to: .contextBuild)
        #expect(ok == false)
        #expect(machine.state == .received)
    }

    @Test("received -> streaming is invalid")
    func receivedToStreamingInvalid() {
        var machine = TurnStateMachine()
        let ok = machine.transition(to: .streaming)
        #expect(ok == false)
        #expect(machine.state == .received)
    }

    @Test("salience -> executiveInfer is invalid (skips contextBuild)")
    func salienceToExecutiveInferInvalid() {
        var machine = TurnStateMachine(initial: .salience)
        let ok = machine.transition(to: .executiveInfer)
        #expect(ok == false)
        #expect(machine.state == .salience)
    }

    @Test("contextBuild -> streaming is invalid (skips executiveInfer)")
    func contextBuildToStreamingInvalid() {
        var machine = TurnStateMachine(initial: .contextBuild)
        let ok = machine.transition(to: .streaming)
        #expect(ok == false)
        #expect(machine.state == .contextBuild)
    }

    @Test("executiveInfer -> persist is invalid (skips streaming)")
    func executiveInferToPersistInvalid() {
        var machine = TurnStateMachine(initial: .executiveInfer)
        let ok = machine.transition(to: .persist)
        #expect(ok == false)
        #expect(machine.state == .executiveInfer)
    }

    @Test("streaming -> complete is invalid (skips persist)")
    func streamingToCompleteInvalid() {
        var machine = TurnStateMachine(initial: .streaming)
        let ok = machine.transition(to: .complete)
        #expect(ok == false)
        #expect(machine.state == .streaming)
    }

    @Test("persist -> streaming is invalid (backwards)")
    func persistToStreamingInvalid() {
        var machine = TurnStateMachine(initial: .persist)
        let ok = machine.transition(to: .streaming)
        #expect(ok == false)
        #expect(machine.state == .persist)
    }

    @Test("complete -> received is invalid (terminal state)")
    func completeToReceivedInvalid() {
        var machine = TurnStateMachine(initial: .complete)
        let ok = machine.transition(to: .received)
        #expect(ok == false)
        #expect(machine.state == .complete)
    }

    @Test("failed -> received is invalid (terminal state)")
    func failedToReceivedInvalid() {
        var machine = TurnStateMachine(initial: .failed)
        let ok = machine.transition(to: .received)
        #expect(ok == false)
        #expect(machine.state == .failed)
    }

    @Test("received -> workerExec is invalid")
    func receivedToWorkerExecInvalid() {
        var machine = TurnStateMachine()
        let ok = machine.transition(to: .workerExec)
        #expect(ok == false)
        #expect(machine.state == .received)
    }

    @Test("executiveInfer -> workerExec is invalid (must go through streaming)")
    func executiveInferToWorkerExecInvalid() {
        var machine = TurnStateMachine(initial: .executiveInfer)
        let ok = machine.transition(to: .workerExec)
        #expect(ok == false)
        #expect(machine.state == .executiveInfer)
    }

    @Test("workerExec -> complete is invalid (must go through persist)")
    func workerExecToCompleteInvalid() {
        var machine = TurnStateMachine(initial: .workerExec)
        let ok = machine.transition(to: .complete)
        #expect(ok == false)
        #expect(machine.state == .workerExec)
    }

    // MARK: - State Unchanged on Invalid Transition

    @Test("Invalid transition does not change state")
    func invalidTransitionPreservesState() {
        var machine = TurnStateMachine()
        let originalState = machine.state
        _ = machine.transition(to: .complete)
        #expect(machine.state == originalState)
    }

    // MARK: - isValid Query

    @Test("isValid returns true for valid transitions without mutating")
    func isValidDoesNotMutate() {
        let machine = TurnStateMachine()
        #expect(machine.isValid(from: .received, to: .salience) == true)
        #expect(machine.isValid(from: .streaming, to: .workerExec) == true)
        #expect(machine.isValid(from: .persist, to: .complete) == true)
        #expect(machine.state == .received)
    }

    @Test("isValid returns false for invalid transitions")
    func isValidReturnsFalseForInvalid() {
        let machine = TurnStateMachine()
        #expect(machine.isValid(from: .received, to: .complete) == false)
        #expect(machine.isValid(from: .complete, to: .received) == false)
        #expect(machine.isValid(from: .failed, to: .received) == false)
    }
}
