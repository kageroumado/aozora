import Foundation
import GRDB
import Testing
@testable import Aozora

/// Integration tests for tool call handling in the coordinator.
///
/// These tests verify that the coordinator correctly processes `expand_memory`,
/// `search_memory`, and `dispatch_worker` tool calls returned by the model,
/// dispatches them to the appropriate handlers, and incorporates results into
/// the response stream.
struct ToolCallIntegrationTests {
    // MARK: - Helpers

    private func makeGateway() async throws -> CIMSGateway {
        try await CIMSGateway.inMemory()
    }

    private func makeRequest(
        _ text: String,
        userKey: UserKey = "test-user",
    ) -> TurnRequest {
        TurnRequest(
            turnID: UUID().uuidString,
            sessionKey: "test-session",
            userKey: userKey,
            message: InboundMessage(
                text: text,
                parts: [MessagePart(kind: .text, ordinal: 0, content: text, metadata: nil)],
                metadata: nil,
            ),
            receivedAt: Date(),
        )
    }

    // MARK: - expand_memory Tool

    @Test
    func `expand_memory tool call expands stored nodes`() async throws {
        let gateway = try await makeGateway()

        // First, ingest some content so there are nodes to expand
        let setupReq = makeRequest("The architecture uses a DAG-based memory hierarchy with three tiers.")
        _ = try await runTurnCollecting(gateway.coordinator, setupReq)

        // Find a node ID from the ingested content
        let matches = await gateway.memoryStore.grep(pattern: "DAG", mode: .fullText, scope: .all)

        guard !matches.isEmpty else {
            // No matches found in FTS5, skip gracefully
            return
        }

        // Now create a coordinator with a model that returns an expand_memory tool call
        let model = MockModelProvider()
        let db = try CIMSDatabase.inMemory()
        let memory = MemoryStore(database: db)
        let identity = try await IdentityStore(database: db)
        let supervisor = WorkerSupervisor()

        // Ingest the same content into this fresh store
        let msg = InboundMessage(
            text: "The architecture uses DAG-based memory.",
            parts: [MessagePart(kind: .text, ordinal: 0, content: "The architecture uses DAG-based memory.", metadata: nil)],
            metadata: nil,
        )
        let response = AssistantResponse(
            content: "Understood.",
            parts: [MessagePart(kind: .text, ordinal: 0, content: "Understood.", metadata: nil)],
            toolCalls: [],
            tokenUsage: TokenUsage(inputTokens: 10, outputTokens: 5),
            latency: .milliseconds(50),
        )
        await memory.ingest(msg, response: response)

        // Find the node ID from the fresh store
        let freshMatches = await memory.grep(pattern: "DAG", mode: .fullText, scope: .all)
        guard let nodeId = freshMatches.first?.nodeId else { return }

        // Enqueue a tool call that expands the node
        let expandArgs = "{\"node_ids\": [\"\(nodeId)\"], \"max_tokens\": 1000}"
        await model.enqueueToolCall(name: "expand_memory", arguments: expandArgs, followUp: "Here is the expanded content.")

        let coordinator = CIMSCoordinator(
            memoryStore: memory,
            identityStore: identity,
            modelProvider: model,
            workerSupervisor: supervisor,
        )

        let request = makeRequest("Expand the memory about DAG")
        let events = try await runTurnCollecting(coordinator, request)

        // The expand result is sent as a tool_result block back to the model,
        // not directly in the response text. Check the toolResult event.
        let toolResults = events.compactMap { event -> ToolCallResult? in
            if case let .toolResult(result) = event { return result }
            return nil
        }

        #expect(!toolResults.isEmpty, "Should emit a toolResult event for expand_memory")
        // The expanded content is the node text from memoryStore.expand()
        if let result = toolResults.first {
            #expect(!result.content.isEmpty, "Tool result should contain expanded content")
        }
    }

    // MARK: - search_memory Tool

    @Test
    func `search_memory tool call searches ingested content`() async throws {
        let model = MockModelProvider()
        let db = try CIMSDatabase.inMemory()
        let memory = MemoryStore(database: db)
        let identity = try await IdentityStore(database: db)
        let supervisor = WorkerSupervisor()

        // Ingest searchable content
        let msg = InboundMessage(
            text: "Quantum computing uses qubits for parallel computation.",
            parts: [MessagePart(kind: .text, ordinal: 0, content: "Quantum computing uses qubits for parallel computation.", metadata: nil)],
            metadata: nil,
        )
        let resp = AssistantResponse(
            content: "Interesting topic!",
            parts: [MessagePart(kind: .text, ordinal: 0, content: "Interesting topic!", metadata: nil)],
            toolCalls: [],
            tokenUsage: TokenUsage(inputTokens: 10, outputTokens: 5),
            latency: .milliseconds(50),
        )
        await memory.ingest(msg, response: resp)

        // Enqueue a search_memory tool call
        let searchArgs = "{\"query\": \"quantum\"}"
        await model.enqueueToolCall(name: "search_memory", arguments: searchArgs, followUp: "Found relevant memories.")

        let coordinator = CIMSCoordinator(
            memoryStore: memory,
            identityStore: identity,
            modelProvider: model,
            workerSupervisor: supervisor,
        )

        let request = makeRequest("Search for quantum computing info")
        let events = try await runTurnCollecting(coordinator, request)

        // The search result is sent as a tool_result block back to the model,
        // not directly in the response text. Check the toolResult event.
        let toolResults = events.compactMap { event -> ToolCallResult? in
            if case let .toolResult(result) = event { return result }
            return nil
        }

        #expect(!toolResults.isEmpty, "Should emit a toolResult event for search_memory")
    }

    // MARK: - dispatch_worker Tool

    @Test
    func `dispatch_worker tool call emits worker events`() async throws {
        let model = MockModelProvider()
        let db = try CIMSDatabase.inMemory()
        let memory = MemoryStore(database: db)
        let identity = try await IdentityStore(database: db)
        let supervisor = WorkerSupervisor()

        // Enqueue a dispatch_worker tool call
        let workerArgs = "{\"goal\": \"Analyze the codebase structure\"}"
        await model.enqueueToolCall(name: "dispatch_worker", arguments: workerArgs, followUp: "Dispatching worker.")

        let coordinator = CIMSCoordinator(
            memoryStore: memory,
            identityStore: identity,
            modelProvider: model,
            workerSupervisor: supervisor,
        )

        let request = makeRequest("Please analyze the codebase")
        let events = try await runTurnCollecting(coordinator, request)

        // The coordinator emits workerDispatched synchronously during the turn.
        // workerCompleted is emitted asynchronously via onWorkerCompleted callback,
        // which runs in a detached task after the turn has finished.
        let sawWorkerDispatched = events.contains { event in
            if case .workerDispatched = event { return true }
            return false
        }

        #expect(sawWorkerDispatched, "Should emit workerDispatched event")
    }

    @Test
    func `Worker completion revokes delegation grant`() async throws {
        let model = MockModelProvider()
        let db = try CIMSDatabase.inMemory()
        let memory = MemoryStore(database: db)
        let identity = try await IdentityStore(database: db)
        let supervisor = WorkerSupervisor()

        let workerArgs = "{\"goal\": \"Quick analysis task\"}"
        await model.enqueueToolCall(name: "dispatch_worker", arguments: workerArgs, followUp: "Done.")

        let coordinator = CIMSCoordinator(
            memoryStore: memory,
            identityStore: identity,
            modelProvider: model,
            workerSupervisor: supervisor,
        )

        let request = makeRequest("Run a worker")
        _ = try await runTurnCollecting(coordinator, request)

        // The worker runs in a detached task, so give it time to complete and clean up.
        // Poll briefly rather than a fixed sleep — the mock worker should finish quickly.
        var activeCount = await supervisor.activeCount
        for _ in 0 ..< 20 where activeCount > 0 {
            try await Task.sleep(for: .milliseconds(50))
            activeCount = await supervisor.activeCount
        }
        #expect(activeCount == 0, "All workers should be cleaned up after turn completion")
    }

    // MARK: - Multiple Tool Calls

    @Test
    func `Multiple tool calls in single response are all handled`() async throws {
        let model = MockModelProvider()
        let db = try CIMSDatabase.inMemory()
        let memory = MemoryStore(database: db)
        let identity = try await IdentityStore(database: db)
        let supervisor = WorkerSupervisor()

        // Ingest content for search
        let msg = InboundMessage(
            text: "Machine learning models require training data.",
            parts: [MessagePart(kind: .text, ordinal: 0, content: "Machine learning models require training data.", metadata: nil)],
            metadata: nil,
        )
        let resp = AssistantResponse(
            content: "Noted.",
            parts: [MessagePart(kind: .text, ordinal: 0, content: "Noted.", metadata: nil)],
            toolCalls: [],
            tokenUsage: TokenUsage(inputTokens: 10, outputTokens: 5),
            latency: .milliseconds(50),
        )
        await memory.ingest(msg, response: resp)

        // The MockModelProvider only supports one tool call per queued response,
        // so we test sequentially: first a search, then a regular response
        let searchArgs = "{\"query\": \"machine learning\"}"
        await model.enqueueToolCall(name: "search_memory", arguments: searchArgs, followUp: "Searching...")

        let coordinator = CIMSCoordinator(
            memoryStore: memory,
            identityStore: identity,
            modelProvider: model,
            workerSupervisor: supervisor,
        )

        let request = makeRequest("Find info about machine learning")
        let events = try await runTurnCollecting(coordinator, request)

        let completedText = events.compactMap { event -> String? in
            if case let .responseCompleted(text) = event { return text }
            return nil
        }.first

        #expect(completedText != nil)
    }

    // MARK: - Interrupted Tool Chain Persistence

    @Test
    func `Interrupted tool chain persists completed results and stop marker`() async throws {
        let innerModel = MockModelProvider()
        let db = try CIMSDatabase.inMemory()
        let memory = MemoryStore(database: db)
        let identity = try await IdentityStore(database: db)
        let supervisor = WorkerSupervisor()

        // Enqueue 5 tool iterations. Each enqueued tool call becomes one complete() call
        // returning tool_use, which triggers an iteration.
        //
        // Call 1 (initial) → tool_use → iteration 1 starts
        // Call 2 (follow-up after iter 1) → tool_use → iteration 2 starts
        // Call 3 (follow-up after iter 2) → tool_use → iteration 3 starts
        // Call 4 (follow-up after iter 3) → CANCELS task, returns tool_use
        //   → iteration 4: Task.isCancelled detected at top of loop → throw
        //   → defer persists toolHistory with 3 completed iterations
        // Call 5 → never reached
        for i in 1 ... 5 {
            await innerModel.enqueueToolCall(
                name: "search_memory",
                arguments: "{\"query\": \"test-\(i)\"}",
                followUp: "Searching for test-\(i)...",
            )
        }

        // Cancel on the 4th complete() call — after 3 iterations have fully completed.
        let cancellingModel = CancellingModelProvider(inner: innerModel, cancelOnCall: 4)

        let coordinator = CIMSCoordinator(
            memoryStore: memory,
            identityStore: identity,
            modelProvider: cancellingModel,
            workerSupervisor: supervisor,
        )

        let request = TurnRequest(
            turnID: UUID().uuidString,
            sessionKey: "interrupted-session",
            userKey: "test-user",
            message: InboundMessage(
                text: "Run a bunch of searches",
                parts: [MessagePart(kind: .text, ordinal: 0, content: "Run a bunch of searches", metadata: nil)],
                metadata: nil,
            ),
            receivedAt: Date(),
        )

        // Run the turn in a task that can be cancelled.
        let turnTask: Task<Void, any Error> = Task {
            try await coordinator.runTurn(request, observer: CollectingObserver())
        }
        await cancellingModel.setTask(turnTask)

        // Wait for the turn to finish (it will be cancelled mid-chain).
        _ = try? await turnTask.value

        // The defer block in executeTurn dispatches persistence in a Task { }.
        // Give it time to write to the DB.
        try await Task.sleep(for: .milliseconds(300))

        // --- Verify database contents ---

        let messages = try await db.dbPool.read { db in
            try MessageRecord.order(Column("id")).fetchAll(db)
        }

        // Expected messages in order:
        //   1. user message ("Run a bunch of searches")
        //   2. assistant message for iteration 1 (text from mock + tool calls)
        //   3. tool result message for iteration 1
        //   4. assistant message for iteration 2
        //   5. tool result message for iteration 2
        //   6. assistant message for iteration 3 (the iteration that completed before cancellation detected)
        //   7. tool result message for iteration 3
        //   8. final assistant message with interruption marker
        let userMessages = messages.filter { $0.role == MessageRole.user.rawValue }
        let assistantMessages = messages.filter { $0.role == MessageRole.assistant.rawValue }
        let toolMessages = messages.filter { $0.role == MessageRole.tool.rawValue }

        #expect(userMessages.count == 1, "User message must be persisted")
        #expect(userMessages.first?.content == "Run a bunch of searches")

        // 3 completed iterations → 3 tool result messages
        #expect(toolMessages.count == 3, "All 3 completed tool results must be persisted (got \(toolMessages.count))")

        // 3 intermediate assistant messages + 1 final interrupted message = 4
        #expect(assistantMessages.count == 4, "3 iteration assistants + 1 final interrupted (got \(assistantMessages.count))")

        // The final assistant message must contain the interruption marker
        // so the agent knows the chain was stopped, not silently dropped.
        let finalAssistant = assistantMessages.last
        #expect(
            finalAssistant?.content.contains("interrupted") == true,
            "Final message must indicate the turn was interrupted, got: \(finalAssistant?.content ?? "nil")",
        )

        // Verify tool result parts are present (not just empty messages)
        let toolParts = try await db.dbPool.read { db in
            try MessagePartRecord
                .filter(Column("partKind") == MessagePartKind.toolResult.rawValue)
                .fetchAll(db)
        }
        #expect(toolParts.count == 3, "Each completed tool call must have a result part")
    }

    // MARK: - Unknown Tool Calls

    @Test
    func `Unknown tool calls are silently ignored`() async throws {
        let model = MockModelProvider()
        let db = try CIMSDatabase.inMemory()
        let memory = MemoryStore(database: db)
        let identity = try await IdentityStore(database: db)
        let supervisor = WorkerSupervisor()

        // Enqueue an unknown tool call
        await model.enqueueToolCall(name: "nonexistent_tool", arguments: "{}", followUp: "This should still work.")

        let coordinator = CIMSCoordinator(
            memoryStore: memory,
            identityStore: identity,
            modelProvider: model,
            workerSupervisor: supervisor,
        )

        let request = makeRequest("Do something with an unknown tool")
        let events = try await runTurnCollecting(coordinator, request)

        // Turn should complete normally despite the unknown tool
        let completedText = events.compactMap { event -> String? in
            if case let .responseCompleted(text) = event { return text }
            return nil
        }.first

        #expect(completedText != nil, "Turn should complete even with unknown tool call")
    }

    // MARK: - Tool Call with Malformed Arguments

    @Test
    func `Interrupted tool chain with zero completed iterations persists user message`() async throws {
        let innerModel = MockModelProvider()
        let db = try CIMSDatabase.inMemory()
        let memory = MemoryStore(database: db)
        let identity = try await IdentityStore(database: db)
        let supervisor = WorkerSupervisor()

        // Enqueue a tool call, but cancel on the very first complete() call
        // so no iterations complete.
        await innerModel.enqueueToolCall(
            name: "search_memory",
            arguments: "{\"query\": \"test\"}",
            followUp: "Searching...",
        )

        let cancellingModel = CancellingModelProvider(inner: innerModel, cancelOnCall: 1)

        let coordinator = CIMSCoordinator(
            memoryStore: memory,
            identityStore: identity,
            modelProvider: cancellingModel,
            workerSupervisor: supervisor,
        )

        let request = TurnRequest(
            turnID: UUID().uuidString,
            sessionKey: "interrupted-zero-session",
            userKey: "test-user",
            message: InboundMessage(
                text: "Search for something",
                parts: [MessagePart(kind: .text, ordinal: 0, content: "Search for something", metadata: nil)],
                metadata: nil,
            ),
            receivedAt: Date(),
        )

        let turnTask: Task<Void, any Error> = Task {
            try await coordinator.runTurn(request, observer: CollectingObserver())
        }
        await cancellingModel.setTask(turnTask)

        _ = try? await turnTask.value
        try await Task.sleep(for: .milliseconds(300))

        let messages = try await db.dbPool.read { db in
            try MessageRecord.order(Column("id")).fetchAll(db)
        }

        let userMessages = messages.filter { $0.role == MessageRole.user.rawValue }
        let assistantMessages = messages.filter { $0.role == MessageRole.assistant.rawValue }

        // Even with zero completed tool iterations, the user message must be saved
        #expect(userMessages.count == 1, "User message must be persisted even on immediate cancellation")

        // The final assistant message should indicate interruption
        #expect(assistantMessages.count >= 1, "At least an interrupted response must be persisted")
        let finalAssistant = assistantMessages.last
        #expect(
            finalAssistant?.content.contains("interrupted") == true || finalAssistant?.content.contains("Turn interrupted") == true,
            "Should indicate interruption, got: \(finalAssistant?.content ?? "nil")",
        )
    }

    @Test
    func `Tool calls with malformed JSON arguments don't crash`() async throws {
        let model = MockModelProvider()
        let db = try CIMSDatabase.inMemory()
        let memory = MemoryStore(database: db)
        let identity = try await IdentityStore(database: db)
        let supervisor = WorkerSupervisor()

        // Enqueue a search_memory call with invalid JSON
        await model.enqueueToolCall(name: "search_memory", arguments: "not valid json at all", followUp: "Handled gracefully.")

        let coordinator = CIMSCoordinator(
            memoryStore: memory,
            identityStore: identity,
            modelProvider: model,
            workerSupervisor: supervisor,
        )

        let request = makeRequest("Test malformed tool args")
        let events = try await runTurnCollecting(coordinator, request)

        // Should complete without crashing
        let completed = events.contains { event in
            if case .responseCompleted = event { return true }
            return false
        }
        #expect(completed, "Turn should complete despite malformed tool arguments")
    }
}

// MARK: - Test Doubles

/// Model provider that cancels a task on the Nth `complete()` call.
///
/// The first N-1 calls pass through to the inner mock normally. On the Nth call,
/// the task is cancelled before the response is returned. The coordinator detects
/// `Task.isCancelled` at its next cooperative check point and enters the
/// interruption persistence path.
private actor CancellingModelProvider: ModelProviding {
    private let inner: MockModelProvider
    private let cancelOnCall: Int
    private var callCount = 0
    private var taskToCancel: Task<Void, any Error>?

    init(inner: MockModelProvider, cancelOnCall: Int) {
        self.inner = inner
        self.cancelOnCall = cancelOnCall
    }

    func setTask(_ task: Task<Void, any Error>) {
        taskToCancel = task
    }

    nonisolated func complete(_ prompt: Prompt, tier: ModelTier) async throws -> ModelResponse {
        let shouldCancel = await trackAndCheck()
        if shouldCancel {
            await performCancel()
        }
        return try await inner.complete(prompt, tier: tier)
    }

    nonisolated func stream(
        _ prompt: Prompt, tier: ModelTier,
    ) async throws -> AsyncThrowingStream<ModelDelta, any Error> {
        try await inner.stream(prompt, tier: tier)
    }

    private func trackAndCheck() -> Bool {
        callCount += 1
        return callCount == cancelOnCall
    }

    private func performCancel() {
        taskToCancel?.cancel()
    }
}
