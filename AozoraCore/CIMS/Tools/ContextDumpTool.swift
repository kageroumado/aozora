import Foundation

/// Diagnostic tool that dumps the actual assembled context to a debug file.
///
/// Intercepts the **real pipeline** — same code path as inference — and writes a structured
/// summary to `~/.aozora/debug-context.txt`. The dump shows:
/// - Assembled context sections with token counts
/// - The exact system blocks the API would receive (with cache_control breakpoints)
/// - Messages array with stubbing boundary and role breakdown
/// - Frontier summary node listing
/// - Fresh tail message previews
public nonisolated struct ContextDumpTool: ToolExecutable {
    public let name = "dump_context"
    public let coordinator: CIMSCoordinator
    public let memoryStore: any MemoryStoring

    public var definition: ToolDefinition {
        ToolDefinition(
            name: "dump_context",
            description: """
            Dump the actual assembled context to ~/.aozora/debug-context.txt for inspection. \
            Shows exactly what would be sent to the API: system blocks with cache_control, \
            messages array, stubbing boundary, frontier summaries, and token statistics.
            """,
            parameters: [],
        )
    }

    public init(coordinator: CIMSCoordinator, memoryStore: any MemoryStoring) {
        self.coordinator = coordinator
        self.memoryStore = memoryStore
    }

    public func execute(parameters _: sending [String: Any], workingDirectory _: String) async throws -> ToolResult {
        // Step 1: Real assembly — same code path as a turn
        let assembled = await coordinator.assembleForEstimate()
        let contextBudget = CIMSDefaults.defaultContextBudget
        let lastInput = await coordinator.lastReportedInputTokens
        let lastOutput = await coordinator.lastReportedOutputTokens

        // Step 2: Build a typed Prompt through the same PromptBuilder pipeline
        let promptBuilder = PromptBuilder()
        let credentialKind = await coordinator.diagnosticCredentialKind
        let dumpResult = promptBuilder.build(
            context: assembled,
            credential: credentialKind,
            tools: CIMSCoordinator.builtInTools,
        )
        let prompt = dumpResult.prompt

        // Step 3: Also get raw frontier for summary listing
        let retrieval = await memoryStore.retrieveFrontier()
        let tailStart = retrieval.freshTail.first?.createdAt ?? Date.distantFuture
        let filteredSummaries = retrieval.summaries.filter { $0.latestAt < tailStart }
        let droppedCount = retrieval.summaries.count - filteredSummaries.count

        // Build the dump
        var lines: [String] = []
        lines.append("# Aozora Context Dump (Real Pipeline)")
        lines.append("# Generated: \(ISO8601DateFormatter().string(from: Date()))")
        lines.append("")

        // Section 1: Assembled context overview
        lines.append("## Assembled Context")
        lines.append("  Total tokens: \(assembled.totalTokens)")
        lines.append("  Budget: \(contextBudget)")
        lines.append("  Utilization: \(String(format: "%.1f", Double(assembled.totalTokens) / Double(contextBudget) * 100))%")
        if let boundary = dumpResult.boundaryMessageIndex {
            lines.append("  Stubbing boundary: message index \(boundary)")
        }
        if lastInput > 0 {
            lines.append("  Last API input: \(lastInput) tokens")
            lines.append("  Last API output: \(lastOutput) tokens")
        }
        lines.append("")

        // Section 2: Assembled sections breakdown
        lines.append("## Assembled Sections")
        for section in assembled.sections {
            lines.append("  \(section.kind.rawValue): \(section.tokenEstimate) tokens")
        }
        lines.append("  TOTAL: \(assembled.sections.reduce(0) { $0 + $1.tokenEstimate }) tokens")
        lines.append("")

        // Section 3: System blocks from typed Prompt
        lines.append("## System Blocks (what Anthropic API receives)")
        for (i, block) in prompt.system.enumerated() {
            let hasCacheControl = block.cacheControl != nil
            let cacheLabel = hasCacheControl ? "cache_control: ephemeral" : "no cache"
            let tokenEst = max(1, block.text.utf8.count / 4)

            lines.append("  Block \(i + 1) [\(cacheLabel)]: ~\(tokenEst) tokens")
            lines.append("    Preview: \(String(block.text.prefix(120)).replacingOccurrences(of: "\n", with: " "))")
        }
        lines.append("")

        // Section 4: Messages array from typed Prompt
        lines.append("## Messages Array")
        var totalMessageTokens = 0
        var roleBreakdown: [String: (count: Int, tokens: Int)] = [:]

        for (_, msg) in prompt.messages.enumerated() {
            let role = msg.role.rawValue
            let contentTokens: Int = switch msg.content {
            case let .text(text):
                max(1, text.utf8.count / 4)
            case let .blocks(blocks):
                blocks.reduce(0) { acc, block in
                    switch block {
                    case let .text(t): acc + max(1, t.utf8.count / 4)
                    case let .toolResult(r): acc + max(1, r.content.utf8.count / 4)
                    case let .cacheableText(ct): acc + max(1, ct.text.utf8.count / 4)
                    default: acc + 1
                    }
                }
            }

            totalMessageTokens += contentTokens
            var entry = roleBreakdown[role] ?? (count: 0, tokens: 0)
            entry.count += 1
            entry.tokens += contentTokens
            roleBreakdown[role] = entry
        }

        lines.append("  Total: \(prompt.messages.count) messages, ~\(totalMessageTokens) tokens")
        lines.append("")
        lines.append("  Role breakdown:")
        for role in ["user", "assistant"] {
            if let entry = roleBreakdown[role] {
                lines.append("    \(role): \(entry.count) messages, ~\(entry.tokens) tokens")
            }
        }
        lines.append("")

        // Section 5: Cache stats
        lines.append("## Cache Stats")
        let cachedBlocks = prompt.system.enumerated().filter { $0.element.cacheControl != nil }
        let uncachedBlocks = prompt.system.enumerated().filter { $0.element.cacheControl == nil }
        lines.append("  System blocks with cache_control: \(cachedBlocks.count) of \(prompt.system.count)")
        for (i, _) in cachedBlocks {
            lines.append("    Block \(i + 1): cached (ephemeral)")
        }
        for (i, _) in uncachedBlocks {
            lines.append("    Block \(i + 1): not cached (volatile)")
        }
        lines.append("")

        // Section 6: Frontier summaries
        let stableSummaries = filteredSummaries.filter { $0.kind == .condensed }
        let recentSummaries = filteredSummaries.filter { $0.kind != .condensed }
        let stableTokens = stableSummaries.reduce(0) { $0 + $1.tokenCount }
        let recentTokens = recentSummaries.reduce(0) { $0 + $1.tokenCount }

        lines.append("## Frontier Summaries (\(filteredSummaries.count) nodes)")
        lines.append("  Stable (kind=condensed): \(stableSummaries.count) nodes, \(stableTokens) tokens -> Block 2")
        lines.append("  Recent (kind=leaf/leaf_summary): \(recentSummaries.count) nodes, \(recentTokens) tokens -> Block 3")
        if droppedCount > 0 {
            lines.append("  Filtered (overlap with fresh tail): \(droppedCount) nodes")
        }
        lines.append("")

        let timeFmt = DateFormatter()
        timeFmt.dateFormat = "MM/dd HH:mm"
        for (i, summary) in filteredSummaries.enumerated() {
            let preview = String(summary.summaryText.prefix(120)).replacingOccurrences(of: "\n", with: " ")
            let timeRange = "\(timeFmt.string(from: summary.earliestAt)) -> \(timeFmt.string(from: summary.latestAt))"
            lines.append("  [\(i)] d\(summary.depth) \(summary.kind.rawValue) ~\(summary.tokenCount)tok (\(timeRange))")
            lines.append("      \(preview)")
        }
        lines.append("")

        // Section 7: Fresh tail (last 10 messages)
        let tail = retrieval.freshTail
        let lastN = tail.suffix(10)
        lines.append("## Fresh Tail (last \(lastN.count) of \(tail.count) messages)")
        for msg in lastN {
            let firstLine = String(msg.content.prefix(120)).replacingOccurrences(of: "\n", with: " ")
            let time = timeFmt.string(from: msg.createdAt)
            lines.append("  \(msg.role.rawValue) ~\(msg.tokenEstimate)tok \(time)")
            if !firstLine.isEmpty {
                lines.append("    \(firstLine)")
            }
        }
        lines.append("")

        // Section 8: Temporal grounding (if present in assembled sections)
        for section in assembled.sections where section.kind == .temporalGrounding {
            lines.append("## Temporal Grounding")
            lines.append("  \(section.content)")
            lines.append("")
        }

        // Section 9: Tool definitions
        lines.append("## Tools (\(prompt.tools.count) definitions)")
        for tool in prompt.tools {
            lines.append("  - \(tool.name)")
        }
        lines.append("")

        let output = lines.joined(separator: "\n")
        let basePath = NSHomeDirectory() + "/.aozora"
        let summaryPath = basePath + "/debug-context.txt"
        let fullPath = basePath + "/debug-context-full.json"
        try output.write(toFile: summaryPath, atomically: true, encoding: .utf8)

        // Write the full prompt as pretty-printed JSON in declaration order.
        // NOT .sortedKeys — declaration order (system → messages → tools) is more readable
        // than alphabetical (content → messages → role → system → tools).
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.withoutEscapingSlashes, .prettyPrinted]
        var fullDumpSize = "n/a"
        if let jsonData = try? encoder.encode(prompt) {
            try jsonData.write(to: URL(fileURLWithPath: fullPath))
            let mb = Double(jsonData.count) / 1_000_000.0
            fullDumpSize = String(format: "%.1fMB", mb)
        }

        let tailTokenTotal = tail.reduce(0) { $0 + $1.tokenEstimate }
        let filteredTokens = filteredSummaries.reduce(0) { $0 + $1.tokenCount }
        let filteredNote = droppedCount > 0 ? " (\(droppedCount) filtered)" : ""
        let summary = "Context dump written to \(summaryPath)\n"
            + "  Full prompt JSON: \(fullPath) (\(fullDumpSize))\n"
            + "  \(filteredSummaries.count) frontier nodes (\(filteredTokens) tokens)\(filteredNote)\n"
            + "  \(tail.count) fresh tail messages (\(tailTokenTotal) tokens)\n"
            + "  Assembled: \(assembled.totalTokens) / \(contextBudget) tokens (\(String(format: "%.1f", Double(assembled.totalTokens) / Double(contextBudget) * 100))%)"

        return .success(summary)
    }
}
