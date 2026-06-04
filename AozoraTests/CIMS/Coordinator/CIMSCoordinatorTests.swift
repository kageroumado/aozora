import Foundation
import Testing
@testable import Aozora

struct CIMSCoordinatorTests {
    // MARK: - Test Helpers

    /// Create a coordinator with mock dependencies for testing.
    private func makeCoordinator(
        modelProvider: (any ModelProviding)? = nil,
    ) async throws -> (CIMSCoordinator, MockMemoryStore, MockIdentityStore) {
        let provider = modelProvider ?? MockModelProvider(defaultResponse: "Hello from the coordinator.")
        let memoryStore = MockMemoryStore()
        let identityStore = MockIdentityStore()
        let supervisor = WorkerSupervisor()

        let coordinator = CIMSCoordinator(
            memoryStore: memoryStore,
            identityStore: identityStore,
            modelProvider: provider,
            workerSupervisor: supervisor,
            systemPrompt: "You are a test assistant.",
        )

        return (coordinator, memoryStore, identityStore)
    }

    // MARK: - Simple Turn

    @Test
    func `Simple turn emits acknowledged, thinking, response, and completed events`() async throws {
        let (coordinator, _, _) = try await makeCoordinator()
        let request = TestFixtures.turnRequest(text: "Hello world")

        let events = try await runTurnCollecting(coordinator, request)

        #expect(events.count >= 3)

        guard case let .acknowledged(id) = events[0] else {
            Issue.record("Expected .acknowledged, got \(events[0])")
            return
        }
        #expect(id == request.turnID)

        guard case .thinking = events[1] else {
            Issue.record("Expected .thinking, got \(events[1])")
            return
        }

        #expect(!events.responseText.isEmpty)
        #expect(events.completedText != nil)
    }

    // MARK: - Persistence

    @Test
    func `Turn persists message via memory store`() async throws {
        let (coordinator, memoryStore, _) = try await makeCoordinator()
        let request = TestFixtures.turnRequest(text: "Persist this message")

        _ = try await runTurnCollecting(coordinator, request)

        let ingestCount = await memoryStore.ingestCallCount
        #expect(ingestCount == 1)
    }

    // MARK: - Error Handling

    @Test
    func `Model error emits error event`() async throws {
        let (coordinator, _, _) = try await makeCoordinator(modelProvider: FailingModelProvider())
        let request = TestFixtures.turnRequest()

        let observer = CollectingObserver()
        do {
            try await coordinator.runTurn(request, observer: observer)
            Issue.record("Expected runTurn to throw")
        } catch {
            // Expected -- runTurn throws on model error
        }

        #expect(observer.events.hasError())
    }

    // MARK: - Queue Full

    @Test
    func `A single turn does not trigger queueFull`() async throws {
        let (coordinator, memoryStore, _) = try await makeCoordinator()
        let request = TestFixtures.turnRequest()

        _ = try await runTurnCollecting(coordinator, request)

        let ingestCount = await memoryStore.ingestCallCount
        #expect(ingestCount == 1)
    }

    // MARK: - Response Content

    @Test
    func `Custom model response text appears in stream events`() async throws {
        let provider = MockModelProvider(defaultResponse: "Custom response from the model")
        let (coordinator, _, _) = try await makeCoordinator(modelProvider: provider)
        let request = TestFixtures.turnRequest(text: "Tell me something")

        let events = try await runTurnCollecting(coordinator, request)

        #expect(events.responseText.contains("Custom response from the model"))
    }

    // MARK: - Cancel Turn

    @Test
    func `Cancel turn does not crash`() async throws {
        let (coordinator, _, _) = try await makeCoordinator()
        await coordinator.cancelTurn("nonexistent-turn-id")
    }

    // MARK: - Context Overflow Retry

    @Test
    func `Context overflow retry succeeds on second attempt`() async throws {
        let provider = MockModelProvider(defaultResponse: "Recovered response")
        await provider.enqueueError(.contextOverflow(10_000, 8_000))

        let (coordinator, _, _) = try await makeCoordinator(modelProvider: provider)
        let request = TestFixtures.turnRequest(text: "Trigger overflow")

        let events = try await runTurnCollecting(coordinator, request)

        #expect(events.hasHold(containing: "Reducing context window"))
        #expect(events.completedText?.contains("Recovered response") == true)
    }

    @Test
    func `Context overflow retry exhausted emits error`() async throws {
        let provider = MockModelProvider()
        await provider.enqueueError(.contextOverflow(10_000, 8_000))
        await provider.enqueueError(.contextOverflow(8_000, 6_000))

        let (coordinator, _, _) = try await makeCoordinator(modelProvider: provider)
        let request = TestFixtures.turnRequest(text: "Trigger double overflow")

        let observer = CollectingObserver()
        do {
            try await coordinator.runTurn(request, observer: observer)
            Issue.record("Expected runTurn to throw on exhausted retries")
        } catch {
            // Expected -- runTurn throws after retries are exhausted
        }

        #expect(observer.events.hasHold(containing: "Reducing context window"))
        #expect(observer.events.hasError { error in
            if case .contextOverflow = error { return true }
            return false
        })
    }

    // MARK: - Streaming Inference

    @Test
    func `Streaming turn yields delta events with accumulated text`() async throws {
        let provider = MockModelProvider(defaultResponse: "Hello streaming")
        let (coordinator, _, _) = try await makeCoordinator(modelProvider: provider)
        let request = TestFixtures.turnRequest(text: "Stream this", streaming: true)

        let events = try await runTurnCollecting(coordinator, request)

        #expect(events.deltaText == "Hello streaming")
        #expect(events.completedText?.contains("Hello streaming") == true)
    }

    @Test
    func `Streaming turn does not emit responseDelta events`() async throws {
        let provider = MockModelProvider(defaultResponse: "Streamed response")
        let (coordinator, _, _) = try await makeCoordinator(modelProvider: provider)
        let request = TestFixtures.turnRequest(text: "Stream test", streaming: true)

        let events = try await runTurnCollecting(coordinator, request)

        #expect(events.responseText.isEmpty, "Streaming turn should not emit .responseDelta events")
    }

    @Test
    func `Non-streaming turn does not emit delta events (regression)`() async throws {
        let provider = MockModelProvider(defaultResponse: "Non-streamed response")
        let (coordinator, _, _) = try await makeCoordinator(modelProvider: provider)
        let request = TestFixtures.turnRequest(text: "No streaming", streaming: false)

        let events = try await runTurnCollecting(coordinator, request)

        #expect(events.deltaText.isEmpty, "Non-streaming turn should not emit .delta events")
        #expect(!events.responseText.isEmpty, "Non-streaming turn should emit .responseDelta events")
    }

    @Test
    func `Streaming turn persists message via memory store`() async throws {
        let provider = MockModelProvider(defaultResponse: "Persisted stream")
        let (coordinator, memoryStore, _) = try await makeCoordinator(modelProvider: provider)
        let request = TestFixtures.turnRequest(text: "Persist streaming", streaming: true)

        _ = try await runTurnCollecting(coordinator, request)

        let ingestCount = await memoryStore.ingestCallCount
        #expect(ingestCount == 1, "Streaming turn should persist like non-streaming")
    }

    @Test
    func `Streaming context overflow retry succeeds on second attempt`() async throws {
        let provider = MockModelProvider(defaultResponse: "Recovered stream")
        await provider.enqueueError(.contextOverflow(10_000, 8_000))

        let (coordinator, _, _) = try await makeCoordinator(modelProvider: provider)
        let request = TestFixtures.turnRequest(text: "Trigger streaming overflow", streaming: true)

        let events = try await runTurnCollecting(coordinator, request)

        #expect(events.hasHold(containing: "Reducing context window"))
        #expect(events.completedText?.contains("Recovered stream") == true)
    }
}
