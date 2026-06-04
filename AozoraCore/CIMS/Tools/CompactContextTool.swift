import Foundation

/// Tool that compacts a range of messages into a summary node in the DAG.
///
/// Gated: refuses to compact unless context utilization exceeds 60% of the budget.
/// The model should only call this when context_status reports high utilization.
/// Compacted content can be recovered via `expand_memory`.
public nonisolated struct CompactContextTool: ToolExecutable {
    public let name = "compact_context"

    /// Stable label strings used in output — reference these in tests to stay in sync.
    public enum Labels {
        public static let noCompactionNeeded = "no compaction needed"
        public static let compactedMessages = "Compacted messages"
    }

    public let pruner: ContextPruner
    public let coordinator: CIMSCoordinator

    public var definition: ToolDefinition {
        ToolDefinition(
            name: "compact_context",
            description: """
            Compact a range of messages into a summary node. Only works when context \
            utilization is above 60%. Check context_status first. \
            Compacted content can be recovered with expand_memory.
            """,
            parameters: [
                ToolParameter(name: "start_index", type: .integer, description: "Start message index (0-based)"),
                ToolParameter(name: "end_index", type: .integer, description: "End message index (exclusive)"),
                ToolParameter(name: "summary", type: .string, description: "Brief summary of what was compacted"),
            ],
        )
    }

    public init(pruner: ContextPruner, coordinator: CIMSCoordinator) {
        self.pruner = pruner
        self.coordinator = coordinator
    }

    public func execute(parameters: sending [String: Any], workingDirectory _: String) async throws -> ToolResult {
        // Gate: check context utilization before allowing compaction
        let estimate = await coordinator.estimateContextUsage()
        let utilization = estimate.budget > 0
            ? Double(estimate.used) / Double(estimate.budget)
            : 0.0

        if utilization < 0.6 {
            return .success(
                "Context utilization is \(Int(utilization * 100))% — \(Labels.noCompactionNeeded). "
                    + "Compaction is only available when utilization exceeds 60%. "
                    + "Current: \(estimate.used) / \(estimate.budget) tokens.",
            )
        }

        guard let startIndex = parameters["start_index"] as? Int else {
            throw ToolError.invalidParameters("'start_index' is required")
        }
        guard let endIndex = parameters["end_index"] as? Int else {
            throw ToolError.invalidParameters("'end_index' is required")
        }
        guard let summary = parameters["summary"] as? String, !summary.isEmpty else {
            throw ToolError.invalidParameters("'summary' is required")
        }

        do {
            let result = try await pruner.compactMessages(startIndex: startIndex, endIndex: endIndex, summary: summary)
            return .success(
                "\(Labels.compactedMessages) \(startIndex)-\(endIndex). Node: \(result.nodeId), saved ~\(result.tokensSaved) tokens. "
                    + "Use expand_memory(node_ids: [\"\(result.nodeId)\"]) to recover.",
            )
        } catch let error as ToolError {
            throw error
        } catch {
            throw ToolError.executionFailed("Compaction failed: \(error)")
        }
    }
}
