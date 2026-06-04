import Foundation
import Testing
@testable import Aozora

struct AllostasisStateTests {
    // MARK: - Initial State

    @Test
    func `Fresh state has exploratory mode`() {
        let state = AllostasisState()
        #expect(state.mode() == .exploratory)
    }

    @Test
    func `Fresh state has zero pressure`() {
        let state = AllostasisState()
        #expect(state.pressure() == 0)
    }

    @Test
    func `Fresh state has full context budget`() {
        let state = AllostasisState()
        #expect(state.contextBudget == CIMSDefaults.defaultContextBudget)
    }

    @Test
    func `Fresh state has full retrieval budget`() {
        let state = AllostasisState()
        #expect(state.retrievalBudget == CIMSDefaults.defaultRetrievalBudget)
    }

    // MARK: - Recording Turns

    @Test
    func `Recording a turn adds to recent turns window`() {
        var state = AllostasisState()
        state.recordTurn(tokensUsed: 1_000, latency: .seconds(1))
        #expect(state.recentTurns.count == 1)
        #expect(state.sessionTokensUsed == 1_000)
    }

    @Test
    func `Recording accumulates session token count`() {
        var state = AllostasisState()
        state.recordTurn(tokensUsed: 500, latency: .seconds(1))
        state.recordTurn(tokensUsed: 700, latency: .seconds(1))
        #expect(state.sessionTokensUsed == 1_200)
    }

    @Test
    func `Sliding window caps at 20 turns`() {
        var state = AllostasisState()
        for i in 0 ..< 25 {
            state.recordTurn(tokensUsed: 100 * (i + 1), latency: .seconds(1))
        }
        #expect(state.recentTurns.count == 20)
    }

    // MARK: - Mode Transitions Based on Pressure

    @Test
    func `Low budget usage stays exploratory`() {
        var state = AllostasisState(sessionTokenBudget: 100_000)
        state.recordTurn(tokensUsed: 5_000, latency: .seconds(1))
        #expect(state.mode() == .exploratory)
    }

    @Test
    func `Moderate budget usage transitions to balanced`() {
        var state = AllostasisState(sessionTokenBudget: 100_000)
        state.recordTurn(tokensUsed: 50_000, latency: .seconds(1))
        #expect(state.mode() == .balanced)
    }

    @Test
    func `High budget usage transitions to conservative`() {
        var state = AllostasisState(sessionTokenBudget: 100_000)
        state.recordTurn(tokensUsed: 80_000, latency: .seconds(1))
        #expect(state.mode() == .conservative)
    }

    @Test
    func `Critical budget usage transitions to recovery`() {
        var state = AllostasisState(sessionTokenBudget: 100_000)
        state.recordTurn(tokensUsed: 95_000, latency: .seconds(1))
        #expect(state.mode() == .recovery)
    }

    @Test
    func `Mode considers latency, not just budget`() {
        var state = AllostasisState(sessionTokenBudget: 1_000_000)
        for _ in 0 ..< 10 {
            state.recordTurn(tokensUsed: 100, latency: .seconds(10))
        }
        let pressure = state.pressure()
        #expect(pressure > 0)
    }

    // MARK: - Budget Scaling

    @Test
    func `Context budget always returns full budget with 1M context`() {
        var state = AllostasisState(sessionTokenBudget: 100_000)
        state.recordTurn(tokensUsed: 80_000, latency: .seconds(1))
        #expect(state.mode() == .conservative)
        // With 1M context, contextBudget is always the full default — the assembler
        // handles budget fitting internally, so allostasis doesn't throttle it.
        #expect(state.contextBudget == CIMSDefaults.defaultContextBudget)
    }

    @Test
    func `Retrieval budget scales down in recovery mode`() {
        var state = AllostasisState(sessionTokenBudget: 100_000)
        state.recordTurn(tokensUsed: 95_000, latency: .seconds(1))
        #expect(state.mode() == .recovery)
        #expect(state.retrievalBudget == max(1, Int(Double(CIMSDefaults.defaultRetrievalBudget) * 0.25)))
    }

    @Test
    func `Retrieval budget is at least 1 even in recovery`() {
        var state = AllostasisState(sessionTokenBudget: 100)
        state.recordTurn(tokensUsed: 99, latency: .seconds(100))
        #expect(state.retrievalBudget >= 1)
    }

    // MARK: - Pressure From History Not Single Turn

    @Test
    func `Pressure uses average latency across window, not single turn`() {
        var state = AllostasisState(sessionTokenBudget: 1_000_000)
        for _ in 0 ..< 9 {
            state.recordTurn(tokensUsed: 100, latency: .seconds(1))
        }
        let pressureBefore = state.pressure()

        state.recordTurn(tokensUsed: 100, latency: .seconds(20))
        let pressureAfter = state.pressure()

        #expect(pressureAfter > pressureBefore)
        #expect(pressureAfter < 1.0)
    }

    // MARK: - Zero Budget Edge Case

    @Test
    func `Zero session budget with no turns produces zero pressure`() {
        let state = AllostasisState(sessionTokenBudget: 0)
        let pressure = state.pressure()
        // No recorded turns → no latency or budget pressure signal
        #expect(pressure == 0)
    }
}
