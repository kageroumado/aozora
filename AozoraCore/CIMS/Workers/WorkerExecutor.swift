import Foundation

/// Default implementation of ``WorkerExecuting`` that runs a full tool loop to accomplish
/// a task goal and produces a compressed ``WorkerSummary``.
///
/// ``WorkerExecutor`` takes a ``ModelProviding`` for inference, builds a minimal context
/// from the worker task's goal, constraints, identity excerpt, and delegation-granted memory,
/// then runs a tool loop (inference -> tool execution -> follow-up inference) until the model
/// returns `end_turn` or limits are reached.
///
/// Uses ``PromptBuilder`` for all prompt construction — `buildWorkerPrompt()` for the initial
/// call and `buildFollowUp()` with typed ``ToolExchange`` values for tool loop iterations.
///
/// Workers can recursively spawn sub-workers via the `dispatch_worker` tool when
/// `task.depth < task.maxDepth`. The executor holds a reference to the ``WorkerSupervisor``
/// to facilitate this recursion.
///
/// Token consumption is tracked and the worker is stopped if it exceeds the task's budget.
public actor WorkerExecutor: WorkerExecuting {
    /// Model provider for worker inference calls.
    private let modelProvider: any ModelProviding

    /// Worker supervisor for recursive sub-worker dispatch. `nil` disables recursion.
    private let workerSupervisor: WorkerSupervisor?

    /// Prompt builder for constructing typed prompts.
    private let promptBuilder = PromptBuilder()

    /// Creates a worker executor with the given model provider.
    ///
    /// - Parameters:
    ///   - modelProvider: The LLM inference provider for worker calls.
    ///   - workerSupervisor: Optional supervisor for recursive sub-worker dispatch.
    public init(modelProvider: any ModelProviding, workerSupervisor: WorkerSupervisor? = nil) {
        self.modelProvider = modelProvider
        self.workerSupervisor = workerSupervisor
    }

    /// Execute a worker task with a full tool loop and return a compressed summary.
    ///
    /// Builds a system prompt from the task specification, then runs a tool loop:
    /// 1. Send the goal as the initial user message via ``PromptBuilder/buildWorkerPrompt()``.
    /// 2. If the model returns `tool_use`, execute each tool call via the task's
    ///    ``ToolRegistry`` (or handle `dispatch_worker` for sub-worker recursion).
    /// 3. Build follow-up prompt via ``PromptBuilder/buildFollowUp()`` with typed ``ToolExchange``.
    /// 4. Repeat until `end_turn`, budget exhaustion, or iteration limit.
    ///
    /// - Parameter task: The self-contained worker task specification.
    /// - Returns: A compressed summary of the worker's execution.
    /// - Throws: ``CIMSError/workerFailed(_:_:)`` on unrecoverable error.
    public nonisolated func execute(_ task: WorkerTask) async throws -> WorkerSummary {
        let systemPrompt = buildWorkerSystemPrompt(task)
        var totalTokensBurned = 0
        var allToolInvocations: [ToolInvocation] = []
        let maxIterations = 25

        let tools = await task.toolRegistry?.definitions ?? []

        let dispatchWorkerDef = ToolDefinition(
            name: "dispatch_worker",
            description: "Dispatch a sub-worker to handle a subtask independently. Returns a summary of the sub-worker's execution.",
            parameters: [
                ToolParameter(name: "goal", type: .string, description: "What the sub-worker should accomplish"),
            ],
        )
        var allToolDefs = tools
        if task.depth < task.maxDepth, workerSupervisor != nil {
            allToolDefs.append(dispatchWorkerDef)
        }

        // Build the initial prompt through PromptBuilder
        let initialPrompt = promptBuilder.buildWorkerPrompt(
            systemPrompt: systemPrompt,
            goal: task.goal,
            tools: allToolDefs,
        )

        var currentResponse = try await modelProvider.complete(initialPrompt, tier: .workerDefault)
        totalTokensBurned += currentResponse.tokenUsage.inputTokens + currentResponse.tokenUsage.outputTokens

        var iteration = 0
        var exchanges: [ToolExchange] = []

        while currentResponse.stopReason == "tool_use", iteration < maxIterations {
            iteration += 1

            if totalTokensBurned > task.tokenBudget {
                break
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

            // Execute tools in parallel
            let toolCalls = currentResponse.toolCalls
            let toolResults: [(ToolCall, ToolCallResult)] = await withTaskGroup(
                of: (ToolCall, ToolCallResult).self,
                returning: [(ToolCall, ToolCallResult)].self,
            ) { group in
                for tc in toolCalls {
                    group.addTask { await (tc, self.executeWorkerTool(tc, task: task)) }
                }
                var collected: [(ToolCall, ToolCallResult)] = []
                for await pair in group {
                    collected.append(pair)
                }
                return collected
            }

            // Build tool result blocks preserving original order
            var results: [ToolResultBlock] = []
            for tc in toolCalls {
                guard let result = toolResults.first(where: { $0.0.id == tc.id })?.1 else { continue }
                allToolInvocations.append(ToolInvocation(
                    name: tc.name,
                    arguments: tc.arguments,
                    result: String(result.content.prefix(200)),
                    outcome: result.isError ? .failure : .success,
                ))
                results.append(ToolResultBlock(
                    toolUseId: tc.id,
                    content: result.content,
                    isError: result.isError,
                ))
            }

            // Build warning injections when approaching limits
            var injections: [String] = []
            if iteration >= maxIterations - 2 || totalTokensBurned > task.tokenBudget * 3 / 4 {
                let warning = if iteration >= maxIterations - 1 {
                    "[SYSTEM: This is your LAST tool iteration. You MUST provide your final summary now. Do NOT call any more tools.]"
                } else {
                    "[SYSTEM: You are approaching the tool iteration limit (\(iteration)/\(maxIterations)) or token budget. Start wrapping up your work and prepare a summary.]"
                }
                injections.append(warning)
            }

            let exchange = ToolExchange(
                assistantText: currentResponse.content,
                calls: calls,
                results: results,
                injections: injections,
            )
            exchanges.append(exchange)

            // On the last iteration, don't pass tools so the model is forced to give a text response
            let iterationTools = iteration >= maxIterations - 1 ? [] as [ToolDefinition] : allToolDefs

            // Build follow-up prompt — system + initial message prefix identical → cache hit
            let followUp = promptBuilder.buildFollowUp(
                basePrompt: initialPrompt,
                exchanges: exchanges,
                tools: iterationTools,
            )

            currentResponse = try await modelProvider.complete(followUp, tier: .workerDefault)
            totalTokensBurned += currentResponse.tokenUsage.inputTokens + currentResponse.tokenUsage.outputTokens
        }

        // If the loop ended with tool_use (model wanted more tools but hit limit),
        // do one final call without tools to force a text response
        if currentResponse.stopReason == "tool_use" {
            // Add a final injection telling the model to summarize
            let finalExchange = ToolExchange(
                assistantText: currentResponse.content,
                calls: currentResponse.toolCalls.map { tc in
                    ToolUseBlock(id: tc.id, name: tc.name, input: (try? JSONValue.parse(tc.arguments)) ?? .object([]))
                },
                results: currentResponse.toolCalls.map { tc in
                    ToolResultBlock(toolUseId: tc.id, content: "[SYSTEM: Tool iteration limit reached. Provide your final summary of what was accomplished.]", isError: false)
                },
                injections: [],
            )
            exchanges.append(finalExchange)

            let finalPrompt = promptBuilder.buildFollowUp(
                basePrompt: initialPrompt,
                exchanges: exchanges,
                tools: [],
            )

            let finalResponse = try await modelProvider.complete(finalPrompt, tier: .workerDefault)
            currentResponse = finalResponse
            totalTokensBurned += finalResponse.tokenUsage.inputTokens + finalResponse.tokenUsage.outputTokens
        }

        let budgetExceeded = totalTokensBurned > task.tokenBudget
        let outcome: WorkerOutcome = budgetExceeded ? .budgetExhausted : .completed
        let confidence: Float = budgetExceeded ? 0.3 : 0.8

        return WorkerSummary(
            narrative: truncateNarrative(currentResponse.content),
            citedMemoryNodes: task.memoryPointers,
            toolsUsed: allToolInvocations,
            tokensBurned: totalTokensBurned,
            outcome: outcome,
            failedAttempts: [],
            lessons: [],
            confidence: confidence,
        )
    }

    // MARK: - Tool Execution

    /// Execute a single tool call within the worker context.
    ///
    /// Handles three cases:
    /// 1. `dispatch_worker` — recursively spawns a sub-worker if depth allows.
    /// 2. Registry tools — dispatched to the task's ``ToolRegistry``.
    /// 3. Unknown tools — returns an error result.
    ///
    /// - Parameters:
    ///   - toolCall: The tool call from the model response.
    ///   - task: The worker task providing tool registry and recursion context.
    /// - Returns: The tool execution result.
    private nonisolated func executeWorkerTool(_ toolCall: ToolCall, task: WorkerTask) async -> ToolCallResult {
        if toolCall.name == "dispatch_worker" {
            return await handleSubWorkerDispatch(toolCall, task: task)
        }

        guard let registry = task.toolRegistry else {
            return ToolCallResult(toolUseId: toolCall.id, content: "No tools available", isError: true)
        }

        let params: [String: Any] = if let data = toolCall.arguments.data(using: .utf8),
                                       let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            json
        } else {
            [:]
        }

        do {
            let result = try await registry.execute(
                name: toolCall.name,
                parameters: params,
                workingDirectory: task.workingDirectory,
            )
            return ToolCallResult(toolUseId: toolCall.id, content: result.content, isError: result.isError)
        } catch {
            return ToolCallResult(toolUseId: toolCall.id, content: "Tool error: \(error.localizedDescription)", isError: true)
        }
    }

    /// Handle recursive sub-worker dispatch via the `dispatch_worker` tool.
    ///
    /// Creates a child ``WorkerTask`` with incremented depth and halved token budget,
    /// then dispatches it through the ``WorkerSupervisor``.
    private nonisolated func handleSubWorkerDispatch(_ toolCall: ToolCall, task: WorkerTask) async -> ToolCallResult {
        guard task.depth < task.maxDepth else {
            return ToolCallResult(
                toolUseId: toolCall.id,
                content: "Cannot dispatch: maximum worker depth (\(task.maxDepth)) reached",
                isError: true,
            )
        }

        guard let supervisor = workerSupervisor else {
            return ToolCallResult(
                toolUseId: toolCall.id,
                content: "Worker dispatch not available",
                isError: true,
            )
        }

        let params: [String: Any] = if let data = toolCall.arguments.data(using: .utf8),
                                       let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            json
        } else {
            [:]
        }
        let goal = (params["goal"] as? String) ?? "No goal specified"

        let childTask = WorkerTask(
            runId: UUID().uuidString,
            goal: goal,
            constraints: [],
            identityExcerpt: task.identityExcerpt,
            memoryPointers: [],
            delegationGrant: task.delegationGrant,
            toolPolicy: task.toolPolicy,
            tokenBudget: task.tokenBudget / 2,
            toolRegistry: task.toolRegistry,
            workingDirectory: task.workingDirectory,
            depth: task.depth + 1,
            maxDepth: task.maxDepth,
            parentSystemPrompt: task.parentSystemPrompt,
        )

        do {
            let summary = try await supervisor.dispatch(task: childTask, executor: self)
            return ToolCallResult(
                toolUseId: toolCall.id,
                content: "Sub-worker completed:\n\(summary.narrative)",
            )
        } catch {
            return ToolCallResult(
                toolUseId: toolCall.id,
                content: "Sub-worker failed: \(error.localizedDescription)",
                isError: true,
            )
        }
    }

    // MARK: - System Prompt

    /// Build a worker system prompt from the task specification.
    ///
    /// Workers get a focused prompt: identity context, constraints, and instructions.
    /// The goal itself is sent as the initial user message, not embedded in the system prompt.
    private nonisolated func buildWorkerSystemPrompt(_ task: WorkerTask) -> String {
        var parts: [String] = []

        if !task.parentSystemPrompt.isEmpty {
            parts.append(task.parentSystemPrompt)
            parts.append("\n---\n")
        }

        let depthLabel = task.depth == 0 ? "sub-agent" : "sub-agent (depth \(task.depth))"
        parts.append("""
        ## Worker Role
        
        You are a \(depthLabel) spawned to handle a specific task. You have the same identity \
        and capabilities as the coordinator, but your scope is focused on the task below.
        
        **Rules:**
        - Stay focused on your assigned task. Do not go on tangents.
        - Use your tools to accomplish the task. Don't just describe what you would do — do it.
        - When done, provide a clear summary of what you accomplished, what you found, \
        or what failed. Include relevant details — don't over-compress.
        - If the task is too large, you can dispatch sub-workers to handle subtasks.
        """)

        parts.append("")
        parts.append("## Available Tools")
        if task.toolRegistry != nil {
            parts.append("""
            - `bash` — Execute shell commands
            - `read` — Read file contents
            - `write` — Create or overwrite files
            - `edit` — Surgical text replacement in files
            """)
        }
        if task.depth < task.maxDepth {
            parts.append("""
            - `dispatch_worker` — Spawn a sub-worker for independent subtasks. \
            The sub-worker runs with its own tools and returns a summary. \
            Current depth: \(task.depth)/\(task.maxDepth).
            """)
        }

        if !task.constraints.isEmpty {
            parts.append("")
            parts.append("## Constraints")
            for constraint in task.constraints {
                parts.append("- \(constraint)")
            }
        }

        if !task.memoryPointers.isEmpty {
            parts.append("")
            parts.append("## Memory References")
            parts.append("Available nodes: \(task.memoryPointers.joined(separator: ", "))")
        }

        return parts.joined(separator: "\n")
    }

    // MARK: - Helpers

    /// Truncate a narrative to fit within the worker summary token limit.
    private nonisolated func truncateNarrative(_ text: String) -> String {
        let maxBytes = CIMSDefaults.workerSummaryMaxTokens * 4
        guard text.utf8.count > maxBytes else { return text }
        let truncated = text.utf8.prefix(maxBytes)
        return String(truncated) ?? String(text.prefix(CIMSDefaults.workerSummaryMaxTokens * 3))
    }
}
