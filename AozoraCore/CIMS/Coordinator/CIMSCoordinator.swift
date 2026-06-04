import Foundation

/// The brain of the cognitive architecture: orchestrates the online per-turn loop.
///
/// ``CIMSCoordinator`` serializes turns per user and manages the full cognitive cycle:
/// salience scoring -> memory retrieval -> context assembly -> executive inference ->
/// tool call handling (dispatch_worker, expand_memory, search_memory) -> persistence ->
/// compaction check -> allostasis update.
///
/// It owns stateless structs (``SalienceScorer``, ``ChronoState``, ``AllostasisState``,
/// ``ContextAssembler``) and talks to actor-isolated stores (``MemoryStoring``,
/// ``IdentityStoring``) and ``WorkerSupervisor``.
///
/// The coordinator returns an `AsyncThrowingStream<TurnEvent, any Error>` so callers can
/// receive incremental events (acknowledgment, thinking, response deltas, worker status)
/// without blocking on the full turn.
public actor CIMSCoordinator: CIMSCoordinating {
    /// Heuristic salience scorer (pure function, no I/O).
    private let salienceScorer = SalienceScorer()

    /// Deterministic context construction.
    private let contextAssembler = ContextAssembler()

    /// Unified prompt builder — single entry point for all API prompt construction.
    private let promptBuilder = PromptBuilder()

    /// Tracks prompt cache freshness for compaction gating.
    private var cacheTimeline = CacheTimeline()

    /// Temporal state: session duration, gap detection, context cooling.
    private var chronoState: ChronoState

    /// Resource pressure tracking and adaptive mode selection.
    private var allostasisState: AllostasisState

    /// LCM-backed memory persistence and retrieval.
    private let memoryStore: any MemoryStoring

    /// Versioned identity and mirror block management.
    private let identityStore: any IdentityStoring

    /// LLM inference provider (real or mock).
    private let modelProvider: any ModelProviding

    /// Worker lifecycle manager.
    private let workerSupervisor: WorkerSupervisor

    /// Number of turns currently queued or in-progress.
    private var queuedTurnCount: Int = 0

    /// Active turn tasks keyed by turn ID, for cancellation support.
    private var activeTurns: [TurnID: Task<Void, Never>] = [:]

    /// Last turn's API-reported input token count.
    private(set) var lastInputTokens: Int = 0

    /// Last turn's API-reported output token count.
    private(set) var lastOutputTokens: Int = 0

    /// Consecutive turns with zero cache reads — used to detect cache breakage.
    private var consecutiveCacheMisses: Int = 0

    /// Previous system block hash for cache change detection across turns.
    private var previousSystemHash: String?

    /// Previous per-block hashes for identifying which block changed.
    private var previousBlockHashes: [String]?

    /// Cached filtered summary lists. Only re-filtered when compaction runs.
    private var cachedStableSummaries: [SummaryNode]?
    private var cachedRecentSummaries: [SummaryNode]?
    private var summariesDirty = true

    /// Frozen prompt snapshot for heartbeat replay. Updated after each real turn.
    public private(set) var promptSnapshot: PromptSnapshot?

    /// Called after compaction runs, so external systems (HeartbeatEngine) can react.
    private var onCompaction: (@Sendable () async -> Void)?

    /// Set the compaction callback. Called from daemon setup.
    public func setCompactionCallback(_ callback: @escaping @Sendable () async -> Void) {
        onCompaction = callback
    }

    /// Plugin registry for tool provider and messaging channel management.
    private let pluginRegistry: PluginRegistry?

    /// Registry for executable agent tools (bash, read, write, edit).
    private let toolRegistry: ToolRegistry?

    /// Manages tool calls that have been moved to the background.
    private let backgroundToolManager = BackgroundToolManager()

    /// Optional source for user interjections during tool loops.
    private var interjectionSource: (any InterjectionSource)?

    /// Callback invoked when a backgrounded worker completes.
    ///
    /// Set by the daemon to route completion events to the event queue.
    private var onWorkerCompleted: (@Sendable (WorkerCompletion) async -> Void)?

    /// Callback to dispatch a fork turn through the gateway.
    ///
    /// The closure runs the fork turn and returns when the fork is complete.
    /// Provided by ``CIMSGateway`` so that forks flow through the same
    /// persistence and consolidation wiring as regular turns.
    private var forkDispatcher: (@Sendable (TurnRequest, any TurnObserver) async throws -> Void)?

    /// Callback for when a fork completes.
    ///
    /// Set by the daemon to route ``ForkResult`` events to the event queue
    /// for injection back into the executive conversation.
    private var onForkCompleted: (@Sendable (ForkResult) async -> Void)?

    /// Number of currently running forks.
    private var activeForkCount: Int = 0

    /// System prompt injected into every executive inference call.
    private let systemPrompt: String

    /// Credential discriminant — tells ``PromptBuilder`` whether to prepend the OAuth identity prefix.
    private let credentialKind: CredentialKind

    /// Persistent named text blocks for agent self-knowledge, injected into context each turn.
    private let memoryBlockStore: MemoryBlockStore?

    /// Runtime configuration store for tunable thresholds.
    private let configStore: ConfigStore?

    /// Tracks when memory blocks were last injected into the conversation for re-injection.
    private var lastInjectionMessageCount: Int = 0

    /// How many messages between identity re-injections into the conversation.
    /// Memory blocks are re-injected as a user message when this many messages have elapsed.
    private let identityReinjectionThreshold: Int = 20

    /// Whether a compaction has been deferred because the prompt cache is warm.
    private var pendingCompaction: Bool = false

    /// Built-in tool definitions available to the executive model during inference.
    ///
    /// These are the coordinator's own tools — `dispatch_worker`, `expand_memory`, and
    /// `search_memory` — that enable the executive to delegate work, expand compressed
    /// summaries, and search through stored memories.
    ///
    /// Plugin tools from ``PluginRegistry`` are appended to this list at inference time.
    public nonisolated static let builtInTools: [ToolDefinition] = [
        ToolDefinition(
            name: "dispatch_worker",
            description: "Dispatch a worker agent to handle a procedural task (code writing, debugging, research). The worker operates in isolation and returns a compressed summary.",
            parameters: [
                ToolParameter(name: "goal", type: .string, description: "What the worker should accomplish"),
                ToolParameter(name: "constraints", type: .array(.string), description: "Behavioral constraints", optional: true),
            ],
        ),
        ToolDefinition(
            name: "expand_memory",
            description: "Expand compressed memory summaries to see the full detail. Use when a summary's 'expand for details' footer is relevant.",
            parameters: [
                ToolParameter(name: "node_ids", type: .array(.string), description: "DAG node IDs to expand"),
                ToolParameter(name: "max_tokens", type: .integer, description: "Maximum tokens for expanded content", optional: true),
            ],
        ),
        ToolDefinition(
            name: "search_memory",
            description: "Search through all stored memories using full-text search.",
            parameters: [
                ToolParameter(name: "query", type: .string, description: "Search query text"),
                ToolParameter(name: "mode", type: .enum(["fullText", "regex"]), description: "Search mode", optional: true),
            ],
        ),
        ToolDefinition(
            name: "fork",
            description: "Fork a parallel version of yourself with full conversation context. The fork runs independently with its own tool budget. Its final response (with all intermediate tool calls collapsed) is injected back when complete. Use for complex parallel work that needs your full context.",
            parameters: [
                ToolParameter(name: "goal", type: .string, description: "What the fork should accomplish"),
            ],
        ),
    ]

    /// Creates a coordinator with all dependencies injected.
    ///
    /// - Parameters:
    ///   - memoryStore: LCM memory persistence and retrieval.
    ///   - identityStore: Versioned identity and mirror block management.
    ///   - modelProvider: LLM inference provider.
    ///   - workerSupervisor: Worker lifecycle manager.
    ///   - pluginRegistry: Plugin registry for tool providers and messaging channels. Optional.
    ///   - systemPrompt: System prompt text for the executive model.
    ///   - credentialKind: Whether the credential is OAuth (requires identity prefix) or API key.
    ///   - chronoState: Initial temporal state (defaults to fresh).
    ///   - allostasisState: Initial resource pressure state (defaults to fresh).
    public init(
        memoryStore: any MemoryStoring,
        identityStore: any IdentityStoring,
        modelProvider: any ModelProviding,
        workerSupervisor: WorkerSupervisor,
        pluginRegistry: PluginRegistry? = nil,
        toolRegistry: ToolRegistry? = nil,
        systemPrompt: String = "You are a helpful assistant.",
        credentialKind: CredentialKind = .apiKey,
        chronoState: ChronoState = ChronoState(),
        allostasisState: AllostasisState = AllostasisState(),
        memoryBlockStore: MemoryBlockStore? = nil,
        configStore: ConfigStore? = nil,
    ) {
        self.memoryStore = memoryStore
        self.identityStore = identityStore
        self.modelProvider = modelProvider
        self.workerSupervisor = workerSupervisor
        self.pluginRegistry = pluginRegistry
        self.toolRegistry = toolRegistry
        self.systemPrompt = systemPrompt
        self.credentialKind = credentialKind
        self.chronoState = chronoState
        self.allostasisState = allostasisState
        self.memoryBlockStore = memoryBlockStore
        self.configStore = configStore
    }

    // MARK: - CIMSCoordinating

    /// Run a single turn of the cognitive cycle, calling the observer for each event.
    ///
    /// This is a plain `async throws` function — when it returns, the turn is done.
    /// When it throws, the turn failed. No continuation to manage, no `finish()` to forget.
    /// Queue count and turn registration are handled by `defer`.
    ///
    /// - Parameters:
    ///   - request: The turn request containing the user's message and metadata.
    ///   - observer: Receives turn lifecycle events (deltas, tool results, completion).
    /// - Throws: ``CIMSError/queueFull`` if the turn queue exceeds ``CIMSDefaults/maxQueuedTurns``,
    ///   or any error from the cognitive cycle.
    public func runTurn(_ request: TurnRequest, observer: some TurnObserver) async throws {
        guard queuedTurnCount < CIMSDefaults.maxQueuedTurns else {
            throw CIMSError.queueFull
        }
        incrementQueueCount()
        defer {
            decrementQueueCount()
            unregisterTurn(request.turnID)
        }
        try await executeTurn(request, observer: observer)
    }

    /// Cancel an in-progress turn.
    ///
    /// Cancels any active inference, kills dispatched workers, and the turn's stream will
    /// receive a cancellation. The turn is cleaned up from the active turn registry.
    ///
    /// - Parameter id: The ID of the turn to cancel.
    public nonisolated func cancelTurn(_ id: TurnID) async {
        await performCancelTurn(id)
    }

    // MARK: - Turn Execution

    /// Core turn execution logic, driven by the turn state machine.
    ///
    /// Runs the full cognitive cycle: salience -> retrieval -> context assembly ->
    /// model inference -> tool call handling -> persistence -> compaction check ->
    /// allostasis update. Calls the observer for each lifecycle event.
    ///
    /// When this function returns, the turn is complete. When it throws, the turn failed.
    /// Queue cleanup is handled by `defer` in ``runTurn(_:observer:)``.
    ///
    /// - Parameters:
    ///   - request: The turn request.
    ///   - observer: Receives turn lifecycle events.
    private func executeTurn(
        _ request: TurnRequest,
        observer: some TurnObserver,
    ) async throws {
        var machine = TurnStateMachine()
        var didPersist = false
        // Accumulated tool call history — declared here so the defer can persist
        // partial progress when a turn is interrupted mid-tool-loop.
        var toolHistory: [ToolTurnRecord] = []
        // Last response text from the model (may be partial if interrupted).
        var lastResponseText = ""

        // Extract channel ID from message metadata for background task routing.
        let channelId = extractChannelId(from: request) ?? ""

        // Safety net: persist the user message even if the turn is cancelled or errors.
        // Without this, cancelled turns evaporate from context — the model responds in
        // Discord but the messages aren't in the DB for future context assembly.
        // Safety net: persist progress even if the turn is cancelled or errors.
        // Without this, interrupted tool chains evaporate from context — the model
        // has to redo all the work on the next turn.
        defer {
            if !didPersist {
                let msg = request.message
                let store = memoryStore
                let history = toolHistory
                let responseText = lastResponseText

                // Build a response that captures what was accomplished
                let content = responseText.isEmpty ? "[Turn interrupted]" : responseText + "\n\n[Turn interrupted after \(history.count) tool iterations]"
                let allToolCalls = history.flatMap(\.toolCalls)

                Task {
                    let response = AssistantResponse(
                        content: content,
                        parts: [MessagePart(kind: .text, ordinal: 0, content: content, metadata: nil)],
                        toolCalls: allToolCalls,
                        tokenUsage: TokenUsage(inputTokens: 0, outputTokens: 0),
                        latency: .zero,
                    )

                    if history.isEmpty {
                        await store.ingest(msg, response: response)
                    } else {
                        // Persist the full tool history so completed iterations
                        // appear in context — the model won't redo finished work.
                        await store.ingestTurn(
                            userMessage: msg,
                            toolHistory: history,
                            finalResponse: response,
                            sessionKey: request.sessionKey,
                            userKey: request.userKey,
                        )
                    }
                }
            }
        }

        await observer.handleEvent(.acknowledged(request.turnID))

        // 0. Session lifecycle: begin a new session if there's a temporal gap
        if chronoState.temporalMode(at: request.receivedAt) != .continuation {
            chronoState.beginSession(at: request.receivedAt)
        }

        // 0.5. Run deferred compaction if cache expired
        if pendingCompaction, !cacheTimeline.isCacheWarm {
            Log.info("coordinator", "Deferred compaction firing (cache expired)")
            await memoryStore.compactIfNeeded()
            pendingCompaction = false
            summariesDirty = true
            await onCompaction?()
        }

        // 1. Salience scoring
        guard machine.transition(to: .salience) else {
            try await failTurn(
                .invalidStateTransition(from: machine.state, to: .salience),
                machine: &machine, observer: observer,
            )
        }

        let identity = await identityStore.currentIdentity()
        let mirror = await identityStore.currentMirror(for: request.userKey)
        let salience = salienceScorer.score(request.message, identity: identity, mirror: mirror)

        // 2. Context build
        guard machine.transition(to: .contextBuild) else {
            try await failTurn(
                .invalidStateTransition(from: machine.state, to: .contextBuild),
                machine: &machine, observer: observer,
            )
        }

        await observer.handleEvent(.thinking)

        let retrieval = await memoryStore.retrieve(
            query: request.message.text,
            salienceBoost: salience,
            limit: allostasisState.retrievalBudget,
        )

        let frontier = await memoryStore.retrieveFrontier()
        if summariesDirty || cachedStableSummaries == nil {
            let allSummaries = frontier.summaries
            cachedStableSummaries = allSummaries.filter { $0.kind == .condensed }
            cachedRecentSummaries = allSummaries.filter { $0.kind != .condensed }
            summariesDirty = false
        }
        let stableSummaries = cachedStableSummaries!
        let recentSummaries = cachedRecentSummaries!

        var identityText = renderIdentity(identity)

        if let memoryBlockStore {
            let memoryBlockText = await memoryBlockStore.renderForContext()
            identityText += "\n\n" + memoryBlockText
        }

        var freshTail = frontier.freshTail
        let currentMessageCount = freshTail.count
        if currentMessageCount - lastInjectionMessageCount >= identityReinjectionThreshold,
           let memoryBlockStore {
            let reminder = await memoryBlockStore.renderForContext()
            let reminderMessage = StoredMessage(
                id: -1,
                conversationId: 0,
                role: .user,
                content: "You have persistent core memory blocks that survive across sessions.\n"
                    + "Use memory_view/memory_replace/memory_append/memory_rewrite tools to update them.\n"
                    + "These blocks are YOUR memory — maintain them as you learn and experience things.\n"
                    + "Update them when you learn something significant about yourself, your user, your projects, or your story.\n\n"
                    + reminder,
                tokenEstimate: reminder.utf8.count / 4 + 50,
                salienceScore: nil,
                createdAt: Date(),
                parts: [],
            )
            freshTail.append(reminderMessage)
            lastInjectionMessageCount = currentMessageCount
        }

        let mirrorText = renderMirror(mirror)
        let chronoText = chronoState.render(at: request.receivedAt)
        let cognitiveText = renderCognitiveState()

        let assemblyInputs = ContextAssembler.AssemblyInputs(
            systemPrompt: systemPrompt,
            identityText: identityText,
            mirrorText: mirrorText,
            summaries: retrieval.summaries,
            cognitiveStateText: cognitiveText,
            chronoText: chronoText,
            stableSummaries: stableSummaries,
            recentSummaries: recentSummaries,
            freshTail: freshTail,
            currentMessage: request.message,
            tokenBudget: allostasisState.contextBudget,
        )

        var context = contextAssembler.assemble(assemblyInputs)

        let hardThreshold = await configStore?.getInt(.contextHardThreshold) ?? CIMSDefaults.hardThreshold

        if context.totalTokens > hardThreshold {
            print("[CIMSCoordinator] Context \(context.totalTokens) exceeds hard threshold \(hardThreshold), compacting...")

            for _ in 0 ..< 2 {
                await memoryStore.compactFull()

                let freshFrontier = await memoryStore.retrieveFrontier()
                let freshStable = freshFrontier.summaries.filter { $0.kind == .condensed }
                let freshRecent = freshFrontier.summaries.filter { $0.kind != .condensed }

                let freshInputs = ContextAssembler.AssemblyInputs(
                    systemPrompt: systemPrompt,
                    identityText: identityText,
                    mirrorText: mirrorText,
                    summaries: retrieval.summaries,
                    cognitiveStateText: cognitiveText,
                    chronoText: chronoText,
                    stableSummaries: freshStable,
                    recentSummaries: freshRecent,
                    freshTail: freshFrontier.freshTail,
                    currentMessage: request.message,
                    tokenBudget: allostasisState.contextBudget,
                )
                context = contextAssembler.assemble(freshInputs)

                if context.totalTokens <= hardThreshold { break }
            }
        }

        // 3. Executive inference
        guard machine.transition(to: .executiveInfer) else {
            try await failTurn(
                .invalidStateTransition(from: machine.state, to: .executiveInfer),
                machine: &machine, observer: observer,
            )
        }

        // Collect tool definitions: built-in + agent tools + plugin-provided
        var tools = Self.builtInTools
        if let toolRegistry {
            let registryTools = await toolRegistry.definitions
            tools.append(contentsOf: registryTools)
        }
        if let pluginRegistry {
            let pluginTools = await pluginRegistry.allToolDefinitions()
            tools.append(contentsOf: pluginTools)
        }

        // Build the initial prompt through the unified PromptBuilder pipeline
        let initialBuildResult = promptBuilder.build(
            context: context,
            credential: credentialKind,
            tools: tools,
        )
        let initialPrompt = initialBuildResult.prompt

        let response: ModelResponse
        let maxOverflowRetries = 1
        var inferenceContext = context
        var currentPrompt = initialPrompt
        var overflowRetries = 0

        while true {
            do {
                if request.streaming {
                    response = try await performStreamingInference(
                        prompt: currentPrompt,
                        observer: observer,
                    )
                } else {
                    response = try await modelProvider.complete(currentPrompt, tier: .executive)
                }
                break
            } catch let cimsError as CIMSError {
                if case let .contextOverflow(_, limit) = cimsError, overflowRetries < maxOverflowRetries {
                    overflowRetries += 1
                    await observer.handleEvent(.hold("Reducing context window..."))

                    let reducedBudget: Int = if limit > 0 {
                        min(
                            Int(Double(limit) * 0.8),
                            Int(Double(allostasisState.contextBudget) * 0.8),
                        )
                    } else {
                        Int(Double(allostasisState.contextBudget) * 0.8)
                    }

                    let reducedInputs = ContextAssembler.AssemblyInputs(
                        systemPrompt: systemPrompt,
                        identityText: identityText,
                        mirrorText: mirrorText,
                        summaries: retrieval.summaries,
                        cognitiveStateText: cognitiveText,
                        chronoText: chronoText,
                        stableSummaries: stableSummaries,
                        recentSummaries: recentSummaries,
                        freshTail: frontier.freshTail,
                        currentMessage: request.message,
                        tokenBudget: reducedBudget,
                    )
                    inferenceContext = contextAssembler.assemble(reducedInputs)
                    currentPrompt = promptBuilder.build(
                        context: inferenceContext,
                        credential: credentialKind,
                        tools: tools,
                    ).prompt
                    continue
                }

                try await failTurn(cimsError, machine: &machine, observer: observer)
            } catch {
                try await failTurn(.modelError(error.localizedDescription), machine: &machine, observer: observer)
            }
        }

        // Record cache write and API-reported token usage
        cacheTimeline.recordCacheWrite()
        lastInputTokens = response.tokenUsage.inputTokens
        lastOutputTokens = response.tokenUsage.outputTokens

        // Log token usage with cache diagnostics
        let diagnosticReport = CacheDiagnostics.report(
            prompt: currentPrompt,
            usage: response.tokenUsage,
            boundaryIndex: initialBuildResult.boundaryMessageIndex,
            previousSystemHash: previousSystemHash,
            previousBlockHashes: previousBlockHashes,
        )
        print(CacheDiagnostics.format(diagnosticReport))
        previousSystemHash = diagnosticReport.systemHash
        previousBlockHashes = diagnosticReport.blocks.map(\.contentHash)

        // Track consecutive cache misses
        if response.tokenUsage.cacheReadTokens == 0, response.tokenUsage.inputTokens > 4_096 {
            consecutiveCacheMisses += 1
            if consecutiveCacheMisses >= 3 {
                print("[tokens] WARNING: \(consecutiveCacheMisses) consecutive turns with 0% cache hit — possible cache breakage")
            }
        } else {
            consecutiveCacheMisses = 0
        }

        // 4. Streaming response
        guard machine.transition(to: .streaming) else {
            try await failTurn(
                .invalidStateTransition(from: machine.state, to: .streaming),
                machine: &machine, observer: observer,
            )
        }

        // In non-streaming mode, emit the full response as a single delta.
        // In streaming mode, deltas were already emitted during inference.
        if !request.streaming, !response.content.isEmpty {
            await observer.handleEvent(.responseDelta(response.content))
        }

        // 5. Tool use loop: execute tools and feed results back to the model
        //
        // Uses typed ToolExchange values to accumulate the conversation.
        // Each iteration builds the follow-up prompt via PromptBuilder.buildFollowUp(),
        // guaranteeing byte-for-byte identical system blocks and message prefix for KV cache reuse.
        var currentResponse = response
        var allToolCalls: [ToolCall] = response.toolCalls
        var totalInputTokens = response.tokenUsage.inputTokens
        var totalOutputTokens = response.tokenUsage.outputTokens
        var totalLatency = response.latency
        let maxToolIterations = 25
        var toolIteration = 0
        var exchanges: [ToolExchange] = []
        lastResponseText = response.content

        while currentResponse.stopReason == "tool_use", toolIteration < maxToolIterations {
            toolIteration += 1

            // Check for cooperative cancellation between tool iterations.
            if Task.isCancelled {
                print("[tool] Task cancelled — exiting tool loop at iteration \(toolIteration)")
                throw CancellationError()
            }

            // Convert model response tool calls to typed ToolUseBlock values
            var calls: [ToolUseBlock] = []
            for tc in currentResponse.toolCalls {
                let input: JSONValue = if let parsed = try? JSONValue.parse(tc.arguments) {
                    parsed
                } else {
                    .object([])
                }
                calls.append(ToolUseBlock(id: tc.id, name: tc.name, input: input))
            }

            // Emit all tool call events immediately so UI shows them
            for tc in currentResponse.toolCalls {
                await observer.handleEvent(.delta(ModelDelta(text: nil, toolCall: tc)))
            }

            // Execute tools and collect results
            var results: [ToolResultBlock] = []
            var currentToolResults: [ToolCallResult] = []
            for tc in currentResponse.toolCalls {
                let result = await executeToolCall(
                    tc,
                    request: request,
                    identity: identity,
                    machine: &machine,
                    observer: observer,
                    channelId: channelId,
                )
                currentToolResults.append(result)
                await observer.handleEvent(.toolResult(result))
                results.append(ToolResultBlock(
                    toolUseId: tc.id,
                    content: result.content,
                    isError: result.isError,
                ))
            }

            // Build iteration-limit warning injections
            var injections: [String] = []
            if toolIteration >= maxToolIterations - 2 {
                let warning = toolIteration >= maxToolIterations - 1
                    ? "[SYSTEM: This is your LAST tool iteration. Provide your final response now.]"
                    : "[SYSTEM: Approaching tool iteration limit (\(toolIteration)/\(maxToolIterations)). Start wrapping up.]"
                injections.append(warning)
            }

            let exchange = ToolExchange(
                assistantText: currentResponse.content,
                calls: calls,
                results: results,
                injections: injections,
            )
            exchanges.append(exchange)

            // Collect the intermediate results for persistence
            let turnRecord = ToolTurnRecord(
                assistantText: currentResponse.content,
                toolCalls: currentResponse.toolCalls,
                toolResults: currentToolResults,
            )
            toolHistory.append(turnRecord)

            // On the last iteration, omit tools to force a text response
            let iterationTools = toolIteration >= maxToolIterations - 1 ? [] as [ToolDefinition] : tools

            // Build follow-up prompt — system + message prefix IDENTICAL to initial call → cache hit
            let followUp = promptBuilder.buildFollowUp(
                basePrompt: initialPrompt,
                exchanges: exchanges,
                tools: iterationTools,
            )

            // Check cancellation before the API call — this is the most expensive
            // operation in the loop and where we'd waste the most time if already cancelled.
            if Task.isCancelled {
                print("[tool] Task cancelled — skipping API call at iteration \(toolIteration)")
                throw CancellationError()
            }

            do {
                currentResponse = try await modelProvider.complete(followUp, tier: .executive)
            } catch {
                try await failTurn(.modelError("Tool loop follow-up failed: \(error)"), machine: &machine, observer: observer)
            }

            // Record cache write for the follow-up call
            cacheTimeline.recordCacheWrite()

            // Accumulate token usage
            totalInputTokens += currentResponse.tokenUsage.inputTokens
            totalOutputTokens += currentResponse.tokenUsage.outputTokens
            totalLatency += currentResponse.latency
            allToolCalls.append(contentsOf: currentResponse.toolCalls)

            // Update stored token counts
            lastInputTokens = currentResponse.tokenUsage.inputTokens
            lastOutputTokens = currentResponse.tokenUsage.outputTokens

            // Log tool-loop cache diagnostics
            let toolLoopReport = CacheDiagnostics.report(
                prompt: followUp,
                usage: currentResponse.tokenUsage,
                boundaryIndex: initialBuildResult.boundaryMessageIndex,
                previousSystemHash: previousSystemHash,
                previousBlockHashes: previousBlockHashes,
            )
            print(CacheDiagnostics.formatToolLoop(toolLoopReport, iteration: toolIteration))
            previousSystemHash = toolLoopReport.systemHash
            previousBlockHashes = toolLoopReport.blocks.map(\.contentHash)

            // Emit the new text from the model's follow-up response
            if !currentResponse.content.isEmpty {
                lastResponseText = currentResponse.content
                await observer.handleEvent(.responseDelta(currentResponse.content))
            }

            // Re-enter streaming state if we came from worker exec
            if machine.state != .streaming {
                _ = machine.transition(to: .streaming)
            }
        }

        // Clean up background tasks before persistence
        let finalBgCompleted = await backgroundToolManager.collectCompleted()
        let abandoned = await backgroundToolManager.cancelAll()
        for (info, _) in abandoned {
            await observer.handleEvent(.toolBackgroundCancelled(
                toolCallId: info.toolCallId, reason: "Turn completed",
            ))
        }

        // Replace placeholder results in toolHistory with actual results
        // for background tasks that completed during the turn.
        for (info, result) in finalBgCompleted {
            for i in toolHistory.indices {
                if let idx = toolHistory[i].toolResults.firstIndex(where: { $0.toolUseId == info.toolCallId }) {
                    var updatedResults = toolHistory[i].toolResults
                    updatedResults[idx] = ToolCallResult(
                        toolUseId: info.toolCallId,
                        content: result.content,
                        isError: result.isError,
                    )
                    toolHistory[i] = ToolTurnRecord(
                        assistantText: toolHistory[i].assistantText,
                        toolCalls: toolHistory[i].toolCalls,
                        toolResults: updatedResults,
                    )
                }
            }
        }

        // The final response text is the model's last response after all tool iterations
        let fullResponseText = currentResponse.content

        await observer.handleEvent(.responseCompleted(fullResponseText))

        // Check if we exited due to tool iteration limit (not stop word, not natural completion)
        let hitToolLimit = toolIteration >= maxToolIterations
            && request.continuationDepth < CIMSDefaults.maxContinuationDepth
        if hitToolLimit {
            await observer.handleEvent(.continuationNeeded(depth: request.continuationDepth))
        }

        // 6. Persist
        guard machine.transition(to: .persist) else {
            try await failTurn(
                .invalidStateTransition(from: machine.state, to: .persist),
                machine: &machine, observer: observer,
            )
        }

        let combinedUsage = TokenUsage(inputTokens: totalInputTokens, outputTokens: totalOutputTokens)
        let assistantResponse = AssistantResponse(
            content: fullResponseText,
            parts: [MessagePart(kind: .text, ordinal: 0, content: fullResponseText, metadata: nil)],
            toolCalls: allToolCalls,
            tokenUsage: combinedUsage,
            latency: totalLatency,
        )

        didPersist = true
        if toolHistory.isEmpty {
            await memoryStore.ingest(request.message, response: assistantResponse)
        } else {
            await memoryStore.ingestTurn(
                userMessage: request.message,
                toolHistory: toolHistory,
                finalResponse: assistantResponse,
                sessionKey: request.sessionKey,
                userKey: request.userKey,
            )
        }

        // Capture frozen prompt snapshot for heartbeat replay
        promptSnapshot = PromptSnapshot.capture(
            from: initialBuildResult,
            assistantResponse: fullResponseText,
        )

        // 7. Compaction check with cache-aware gating
        if cacheTimeline.isCacheWarm {
            Log.debug("coordinator", "Compaction deferred (cache warm)")
            pendingCompaction = true
        } else {
            Log.info("coordinator", "Post-turn compaction running (cache not warm)")
            summariesDirty = true
            Task.detached { [memoryStore, onCompaction] in
                await memoryStore.compactIfNeeded()
                await onCompaction?()
            }
        }

        // 8. Allostasis update
        allostasisState.recordTurn(
            tokensUsed: totalInputTokens + totalOutputTokens,
            latency: totalLatency,
        )

        // 9. Chrono update
        chronoState.recordInteraction(at: request.receivedAt)

        // 10. Complete — queue cleanup handled by defer in runTurn
        _ = machine.transition(to: .complete)
    }

    // MARK: - Streaming Inference

    /// Perform streaming inference, yielding ``TurnEvent/delta(_:)`` events and accumulating
    /// the result into a ``ModelResponse``.
    ///
    /// Calls ``ModelProviding/stream(_:tier:)`` and iterates the returned delta stream.
    /// Each delta is forwarded to the turn continuation as a ``TurnEvent/delta(_:)`` event.
    /// Text deltas are accumulated into the full response content, and tool call deltas are
    /// collected for post-inference tool handling.
    ///
    /// - Parameters:
    ///   - prompt: The typed prompt to send for inference.
    ///   - continuation: The turn event continuation to yield deltas into.
    /// - Returns: A ``ModelResponse`` assembled from accumulated streaming deltas.
    /// - Throws: ``CIMSError`` if the model provider fails to start streaming.
    private func performStreamingInference(
        prompt: Prompt,
        observer: some TurnObserver,
    ) async throws -> ModelResponse {
        let inferenceStart = ContinuousClock.now

        let deltaStream = try await modelProvider.stream(prompt, tier: .executive)

        var accumulatedText = ""
        var accumulatedToolCalls: [ToolCall] = []
        var streamStopReason = "end_turn"

        for try await delta in deltaStream {
            // Capture stop reason from the sentinel delta (if present)
            if let sr = delta.stopReason {
                streamStopReason = sr
            }

            // Only forward deltas that carry content to the UI
            if delta.text != nil || delta.toolCall != nil {
                await observer.handleEvent(.delta(delta))
            }

            if let text = delta.text {
                accumulatedText += text
            }
            if let toolCall = delta.toolCall {
                accumulatedToolCalls.append(toolCall)
            }
        }

        let latency = ContinuousClock.now - inferenceStart
        let inputTokens = prompt.messages.count * 100
        let outputTokens = max(1, accumulatedText.utf8.count / 4)

        return ModelResponse(
            content: accumulatedText,
            toolCalls: accumulatedToolCalls,
            tokenUsage: TokenUsage(inputTokens: inputTokens, outputTokens: outputTokens),
            latency: latency,
            stopReason: streamStopReason,
        )
    }

    // MARK: - Tool Execution

    // MARK: - Tool Execution Racing

    /// Result of racing tool execution against a timeout and stop-word check.
    private enum ToolRaceResult {
        case completed(ToolResult)
        case backgrounded(Task<ToolResult, Never>)
        case stopped(InboundMessage)
    }

    /// Execute a tool via the registry only (no state machine, no events).
    ///
    /// This is the pure execution path used by the timeout race so the tool can run
    /// in an unstructured Task. Built-in tools (dispatch_worker, expand_memory, search_memory)
    /// are NOT supported here — they need actor-isolated state.
    private nonisolated func executeToolOnly(
        name: String,
        arguments: String,
        registry: ToolRegistry,
    ) async -> ToolResult {
        let params: [String: Any] = if let data = arguments.data(using: .utf8),
                                       let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            json
        } else {
            [:]
        }

        do {
            return try await registry.execute(name: name, parameters: params, workingDirectory: NSHomeDirectory())
        } catch {
            return ToolResult(content: "[Error: \(error.localizedDescription)]", isError: true)
        }
    }

    /// Race a tool execution against a timeout and stop-word check.
    ///
    /// Returns `.completed` if the tool finishes within the timeout,
    /// `.backgrounded` if it exceeds the timeout (the tool Task continues running),
    /// or `.stopped` if a stop word arrives during execution.
    ///
    /// The tool runs in an unstructured `Task` outside the `TaskGroup` so that
    /// `group.cancelAll()` only cancels the racer wrappers, not the tool itself.
    private func raceToolExecution(
        name: String,
        arguments: String,
        registry: ToolRegistry,
        timeout: Int,
        interjectionSource: any InterjectionSource,
    ) async -> ToolRaceResult {
        let toolTask = Task<ToolResult, Never> {
            await self.executeToolOnly(name: name, arguments: arguments, registry: registry)
        }

        return await withTaskGroup(of: ToolRaceResult.self) { group in
            group.addTask {
                let result = await toolTask.value
                return .completed(result)
            }

            group.addTask {
                try? await Task.sleep(for: .seconds(timeout))
                return .backgrounded(toolTask)
            }

            group.addTask {
                while !Task.isCancelled {
                    if let stopMsg = await interjectionSource.consumeStopWord() {
                        return .stopped(stopMsg)
                    }
                    try? await Task.sleep(for: .seconds(1))
                }
                return .completed(ToolResult(content: "", isError: false))
            }

            let winner = await group.next()!
            group.cancelAll()

            if case .stopped = winner {
                toolTask.cancel()
            }

            return winner
        }
    }

    // MARK: - Tool Call Dispatch

    /// Execute a single tool call and return the result for the tool_result block.
    ///
    /// Dispatches to the appropriate handler based on the tool name: built-in tools
    /// (dispatch_worker, expand_memory, search_memory), agent tools from the registry,
    /// or plugin tools.
    private func executeToolCall(
        _ toolCall: ToolCall,
        request: TurnRequest,
        identity: IdentityBlock,
        machine _: inout TurnStateMachine,
        observer: some TurnObserver,
        channelId: String = "",
    ) async -> ToolCallResult {
        switch toolCall.name {
        case "dispatch_worker":
            let resultText = await handleDispatchWorker(
                arguments: toolCall.arguments,
                request: request,
                identity: identity,
                observer: observer,
                channelId: channelId,
            )
            return ToolCallResult(
                toolUseId: toolCall.id,
                content: resultText,
                isError: false,
            )

        case "expand_memory":
            let expanded = await handleExpandMemory(arguments: toolCall.arguments)
            return ToolCallResult(
                toolUseId: toolCall.id,
                content: expanded ?? "No content found for the specified nodes.",
            )

        case "search_memory":
            let results = await handleSearchMemory(arguments: toolCall.arguments)
            return ToolCallResult(
                toolUseId: toolCall.id,
                content: results ?? "No matching memories found.",
            )

        case "fork":
            return await handleFork(
                toolCall: toolCall,
                request: request,
                observer: observer,
                channelId: channelId,
            )

        default:
            // Check the agent tool registry first
            if let toolRegistry, await toolRegistry.contains(toolCall.name) {
                let toolResult = await handleRegistryTool(
                    name: toolCall.name,
                    arguments: toolCall.arguments,
                    registry: toolRegistry,
                )
                return ToolCallResult(
                    toolUseId: toolCall.id,
                    content: toolResult.content,
                    isError: toolResult.isError,
                )
            } else if let pluginRegistry {
                let result = await pluginRegistry.executePluginTool(
                    name: toolCall.name,
                    arguments: toolCall.arguments,
                )
                if let result {
                    return ToolCallResult(
                        toolUseId: toolCall.id,
                        content: result.content,
                        isError: result.isError,
                    )
                }
            }

            return ToolCallResult(
                toolUseId: toolCall.id,
                content: "Unknown tool: \(toolCall.name)",
                isError: true,
            )
        }
    }

    // MARK: - Tool Handlers

    /// Handle a `dispatch_worker` tool call by creating a delegation grant and firing off a detached Task.
    ///
    /// Returns immediately with an acknowledgment string. The worker runs in the background
    /// and posts a ``WorkerCompletion`` via ``onWorkerCompleted`` when it finishes.
    ///
    /// - Parameters:
    ///   - arguments: JSON-encoded arguments from the tool call.
    ///   - request: The originating turn request.
    ///   - identity: The current identity block for the identity excerpt.
    ///   - observer: Receives the `.workerDispatched` event before this function returns.
    ///   - channelId: Discord channel ID for routing the completion event.
    /// - Returns: An immediate acknowledgment string containing the run ID.
    private func handleDispatchWorker(
        arguments: String,
        request _: TurnRequest,
        identity: IdentityBlock,
        observer: some TurnObserver,
        channelId: String,
    ) async -> String {
        let runId: WorkerRunID = UUID().uuidString

        let scope = DelegationScope(
            conversationScope: .all,
            operations: [.grep, .describe, .expand],
            tokenCap: CIMSDefaults.workerDefaultBudget,
        )
        let grant = await memoryStore.createDelegationGrant(scope: scope)

        let task = WorkerTask(
            runId: runId,
            goal: extractGoal(from: arguments),
            constraints: [],
            identityExcerpt: identity.claims.map(\.value).joined(separator: "\n"),
            memoryPointers: [],
            delegationGrant: grant,
            toolPolicy: .all,
            tokenBudget: CIMSDefaults.workerDefaultBudget,
            toolRegistry: toolRegistry,
            workingDirectory: FileManager.default.currentDirectoryPath,
            depth: 0,
            maxDepth: 3,
            parentSystemPrompt: systemPrompt,
        )

        await observer.handleEvent(.workerDispatched(runId))

        let startedAt = ContinuousClock.now
        let onCompleted = onWorkerCompleted
        let memStore = memoryStore

        Task.detached { [workerSupervisor, modelProvider] in
            do {
                let summary = try await workerSupervisor.dispatch(
                    task: task,
                    executor: WorkerExecutor(modelProvider: modelProvider, workerSupervisor: workerSupervisor),
                )
                await memStore.revokeDelegationGrant(grant.grantId)
                let elapsed = ContinuousClock.now - startedAt
                let completion = WorkerCompletion(
                    runId: runId,
                    channelId: channelId,
                    summary: summary,
                    elapsed: elapsed,
                )
                await onCompleted?(completion)
            } catch {
                await memStore.revokeDelegationGrant(grant.grantId)
                print("[worker] Worker \(runId) failed: \(error)")
            }
        }

        return "Worker dispatched (id: \(runId)). It will run in the background and results will arrive when complete."
    }

    /// Handle an `expand_memory` tool call by expanding the specified DAG nodes.
    private func handleExpandMemory(arguments: String) async -> String? {
        let nodeIds = extractNodeIds(from: arguments)
        guard !nodeIds.isEmpty else { return nil }
        let maxTokens = extractMaxTokens(from: arguments) ?? 5_000
        let result = await memoryStore.expand(nodeIds: nodeIds, tokenBudget: maxTokens)
        return result.nodes.map(\.text).joined(separator: "\n---\n")
    }

    /// Handle a `search_memory` tool call by searching memory via grep.
    private func handleSearchMemory(arguments: String) async -> String? {
        let query = extractQuery(from: arguments)
        guard !query.isEmpty else { return nil }
        let matches = await memoryStore.grep(pattern: query, mode: .fullText, scope: .all)
        return matches.map { "\($0.nodeId): \($0.excerpt)" }.joined(separator: "\n")
    }

    /// Handle a tool call by dispatching to the ``ToolRegistry``.
    private func handleRegistryTool(
        name: String,
        arguments: String,
        registry: ToolRegistry,
    ) async -> ToolResult {
        let params: [String: Any] = if let data = arguments.data(using: .utf8),
                                       let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            json
        } else {
            [:]
        }

        do {
            return try await registry.execute(
                name: name,
                parameters: params,
                workingDirectory: FileManager.default.currentDirectoryPath,
            )
        } catch {
            return ToolResult(content: "Tool execution failed: \(error)", isError: true)
        }
    }

    // MARK: - Fork Handling

    /// Handle a `fork` tool call by dispatching a parallel turn with full context.
    ///
    /// The fork inherits the parent's full conversation context (same `sessionKey`) and
    /// runs independently with its own tool budget. When it finishes, the result is
    /// collapsed into a single ``ForkResult`` and posted to the event queue.
    ///
    /// Workers cannot fork — only executive turns can. Max concurrent forks is
    /// controlled by ``CIMSDefaults/maxConcurrentForks``.
    ///
    /// - Parameters:
    ///   - toolCall: The tool call from the model.
    ///   - request: The originating turn request.
    ///   - observer: Receives the `.forkDispatched` event before this function returns.
    ///   - channelId: Discord channel ID for routing the merge notification.
    /// - Returns: An immediate acknowledgment or error result.
    private func handleFork(
        toolCall: ToolCall,
        request: TurnRequest,
        observer: some TurnObserver,
        channelId: String,
    ) async -> ToolCallResult {
        let goal = extractGoal(from: toolCall.arguments)
        guard goal != "No goal specified", !goal.isEmpty else {
            return ToolCallResult(
                toolUseId: toolCall.id,
                content: "Missing required 'goal' parameter for fork.",
                isError: true,
            )
        }

        if request.sessionKey.hasPrefix("worker:") {
            return ToolCallResult(
                toolUseId: toolCall.id,
                content: "Fork not available in worker context.",
                isError: true,
            )
        }

        guard let dispatcher = forkDispatcher else {
            return ToolCallResult(
                toolUseId: toolCall.id,
                content: "Fork not available (no dispatcher configured).",
                isError: true,
            )
        }

        guard activeForkCount < CIMSDefaults.maxConcurrentForks else {
            return ToolCallResult(
                toolUseId: toolCall.id,
                content: "Too many concurrent forks (max \(CIMSDefaults.maxConcurrentForks)). Wait for existing forks to complete.",
                isError: true,
            )
        }

        let forkId = "fork-\(Int(Date().timeIntervalSince1970 * 1_000))"
        activeForkCount += 1

        await observer.handleEvent(.forkDispatched(forkId))

        let forkRequest = TurnRequest(
            turnID: forkId,
            sessionKey: request.sessionKey,
            userKey: request.userKey,
            message: InboundMessage(
                text: goal,
                parts: [MessagePart(kind: .text, ordinal: 0, content: goal, metadata: nil)],
                metadata: nil,
            ),
            receivedAt: .now,
        )

        let onCompleted = onForkCompleted
        let startedAt = ContinuousClock.now

        Task.detached { [weak self] in
            let forkObserver = CollectingForkObserver()
            do {
                try await dispatcher(forkRequest, forkObserver)
            } catch {
                print("[fork] Fork \(forkId) failed: \(error)")
            }

            let elapsed = ContinuousClock.now - startedAt
            let result = ForkResult(
                forkId: forkId,
                goal: goal,
                channelId: channelId,
                response: forkObserver.responseText,
                toolCallCount: forkObserver.toolCallCount,
                elapsed: elapsed,
            )

            await self?.decrementForkCount()
            await onCompleted?(result)
        }

        return ToolCallResult(
            toolUseId: toolCall.id,
            content: "Fork dispatched (id: \(forkId)). It has your full conversation context and will work on: \(goal). Result will arrive when complete.",
            isError: false,
        )
    }

    /// Decrement the active fork counter when a fork completes or fails.
    private func decrementForkCount() {
        activeForkCount -= 1
    }

    // MARK: - JSON Argument Extraction

    /// Extract the "goal" string from tool call JSON arguments.
    private func extractGoal(from arguments: String) -> String {
        extractString(key: "goal", from: arguments) ?? "No goal specified"
    }

    /// Extract "node_ids" array from tool call JSON arguments.
    private func extractNodeIds(from arguments: String) -> [NodeID] {
        guard let data = arguments.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let ids = json["node_ids"] as? [String]
        else { return [] }
        return ids
    }

    /// Extract "max_tokens" integer from tool call JSON arguments.
    private func extractMaxTokens(from arguments: String) -> Int? {
        guard let data = arguments.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return nil }
        return json["max_tokens"] as? Int
    }

    /// Extract "query" string from tool call JSON arguments.
    private func extractQuery(from arguments: String) -> String {
        extractString(key: "query", from: arguments) ?? ""
    }

    /// Generic string extraction from JSON arguments by key.
    private func extractString(key: String, from arguments: String) -> String? {
        guard let data = arguments.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return nil }
        return json[key] as? String
    }

    // MARK: - Rendering Helpers

    /// Render the identity block as a text string for context injection.
    private func renderIdentity(_ identity: IdentityBlock) -> String {
        guard !identity.claims.isEmpty else { return "[No identity claims]" }
        return identity.claims.map { "\($0.claimKey): \($0.value)" }.joined(separator: "\n")
    }

    /// Render the mirror block as a text string for context injection.
    private func renderMirror(_ mirror: MirrorBlock) -> String {
        guard !mirror.claims.isEmpty else { return "[No mirror claims]" }
        return mirror.claims.map { "\($0.claimKey): \($0.value)" }.joined(separator: "\n")
    }

    /// Render the cognitive state (allostasis, memory health) for context injection.
    private func renderCognitiveState() -> String {
        let mode = allostasisState.mode()
        let pressure = allostasisState.pressure()
        let pressurePercent = Int(pressure * 100)
        return "[Allostasis: \(mode.rawValue) | Pressure: 0.\(pressurePercent)]"
    }

    // MARK: - Error Handling

    /// Transition to failed state, emit error event, and throw.
    ///
    /// Replaces the old `finishWithError` which managed a continuation.
    /// Now just emits the event and throws — `defer` in `runTurn` handles cleanup.
    private func failTurn(
        _ error: CIMSError,
        machine: inout TurnStateMachine,
        observer: some TurnObserver,
    ) async throws -> Never {
        _ = machine.transition(to: .failed)
        await observer.handleEvent(.error(error))
        throw error
    }

    // MARK: - Queue Management

    /// Increment the queued turn counter.
    private func incrementQueueCount() {
        queuedTurnCount += 1
    }

    /// Decrement the queued turn counter.
    private func decrementQueueCount() {
        queuedTurnCount = max(0, queuedTurnCount - 1)
    }

    /// Register an active turn task for cancellation support.
    private func registerTurn(_ id: TurnID, task: Task<Void, Never>) {
        activeTurns[id] = task
    }

    /// Unregister a completed turn task.
    private func unregisterTurn(_ id: TurnID) {
        activeTurns.removeValue(forKey: id)
    }

    /// Cancel and clean up an active turn.
    private func performCancelTurn(_ id: TurnID) {
        if let task = activeTurns[id] {
            task.cancel()
            activeTurns.removeValue(forKey: id)
            decrementQueueCount()
        }
    }

    // MARK: - Diagnostics

    /// Current allostasis mode for diagnostic display.
    public var currentAllostasisMode: AllostasisMode {
        allostasisState.mode()
    }

    /// Current resource pressure (0-1) for diagnostic display.
    public var currentPressure: Float {
        allostasisState.pressure()
    }

    /// Current temporal mode for diagnostic display.
    public var currentTemporalMode: TemporalMode {
        chronoState.temporalMode()
    }

    /// Current context budget in tokens for diagnostic display.
    public var currentContextBudget: Int {
        allostasisState.contextBudget
    }

    /// Number of turns currently queued or in-progress.
    public var currentQueueDepth: Int {
        queuedTurnCount
    }

    /// Set the interjection source for tool loop interactivity.
    ///
    /// When set, the tool loop checks for stop words and pending messages between
    /// iterations. Without this, tools execute synchronously (original behavior).
    public func setInterjectionSource(_ source: any InterjectionSource) {
        interjectionSource = source
    }

    /// Set the worker completion callback.
    ///
    /// Called by the daemon after a backgrounded worker finishes so it can
    /// route the ``WorkerCompletion`` event to the event queue.
    public func setWorkerCompletionHandler(_ handler: @escaping @Sendable (WorkerCompletion) async -> Void) {
        onWorkerCompleted = handler
    }

    /// Set the fork dispatcher closure (provided by the gateway).
    ///
    /// The dispatcher runs a fork turn through the gateway's ``CIMSGateway/runTurn(_:observer:)``
    /// so that forks share the same persistence and consolidation pipeline.
    public func setForkDispatcher(_ dispatcher: @escaping @Sendable (TurnRequest, any TurnObserver) async throws -> Void) {
        forkDispatcher = dispatcher
    }

    /// Set the fork completion callback.
    ///
    /// Called when a fork finishes so the daemon can route the ``ForkResult``
    /// to the event queue for injection back into the executive conversation.
    public func setForkCompletionHandler(_ handler: @escaping @Sendable (ForkResult) async -> Void) {
        onForkCompleted = handler
    }

    /// Extract the Discord channel ID from a turn request's message metadata.
    ///
    /// - Parameter request: The turn request to extract from.
    /// - Returns: The channel ID, or `nil` if not present.
    private nonisolated func extractChannelId(from request: TurnRequest) -> String? {
        guard let metadata = request.message.parts.first?.metadata,
              let data = metadata.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: String]
        else { return nil }
        return json["discord_channel_id"]
    }

    /// Number of active turns being executed.
    public var activeTurnCount: Int {
        activeTurns.count
    }

    /// Last turn's API-reported input token count (for diagnostics).
    public var lastReportedInputTokens: Int {
        lastInputTokens
    }

    /// Last turn's API-reported output token count (for diagnostics).
    public var lastReportedOutputTokens: Int {
        lastOutputTokens
    }

    /// The credential kind used by this coordinator (for diagnostic tools).
    public var diagnosticCredentialKind: CredentialKind {
        credentialKind
    }

    /// Estimate the assembled context size by doing a dry-run assembly.
    ///
    /// Gathers the same inputs as a real turn (identity, mirror, retrieval, chrono,
    /// cognitive state) and assembles them without running inference. Returns the
    /// total token count that would be sent to the API.
    public func estimateContextUsage() async -> (used: Int, budget: Int) {
        let assembled = await assembleForEstimate()
        return (assembled.totalTokens, allostasisState.contextBudget)
    }

    /// Assemble a full context for estimation/debugging purposes.
    /// Returns the actual AssembledContext with all sections.
    public func assembleForEstimate() async -> AssembledContext {
        let identity = await identityStore.currentIdentity()
        let mirror = await identityStore.currentMirror(for: "default")

        let frontier = await memoryStore.retrieveFrontier()
        let allSummaries = frontier.summaries
        let stableSummaries = allSummaries.filter { $0.kind == .condensed }
        let recentSummaries = allSummaries.filter { $0.kind != .condensed }

        var identityText = renderIdentity(identity)
        if let memoryBlockStore {
            let memoryBlockText = await memoryBlockStore.renderForContext()
            identityText += "\n\n" + memoryBlockText
        }

        let mirrorText = renderMirror(mirror)
        let chronoText = chronoState.render(at: Date())
        let cognitiveText = renderCognitiveState()

        let inputs = ContextAssembler.AssemblyInputs(
            systemPrompt: systemPrompt,
            identityText: identityText,
            mirrorText: mirrorText,
            summaries: allSummaries,
            cognitiveStateText: cognitiveText,
            chronoText: chronoText,
            stableSummaries: stableSummaries,
            recentSummaries: recentSummaries,
            freshTail: frontier.freshTail,
            tokenBudget: allostasisState.contextBudget,
        )

        return contextAssembler.assemble(inputs)
    }
}

// MARK: - CollectingForkObserver

/// Observer that collects the fork's final response and tool call count.
///
/// Used by fork turns to capture the collapsed result. The fork runs a full
/// cognitive turn, but only the final response text survives — intermediate
/// tool calls are counted for metrics but their details are discarded.
///
/// Marked `@unchecked Sendable` because mutations happen sequentially within
/// the fork turn (the coordinator calls `handleEvent` in order).
final class CollectingForkObserver: TurnObserver, @unchecked Sendable {
    /// The accumulated response text from the fork turn.
    private(set) var responseText: String = ""

    /// Number of tool calls the fork executed.
    private(set) var toolCallCount: Int = 0

    func handleEvent(_ event: TurnEvent) async {
        switch event {
        case let .responseCompleted(text):
            responseText = text
        case .toolResult:
            toolCallCount += 1
        case let .responseDelta(text):
            if responseText.isEmpty {
                responseText = text
            } else {
                responseText += text
            }
        default:
            break
        }
    }
}
