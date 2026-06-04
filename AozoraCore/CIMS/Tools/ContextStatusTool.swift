import Foundation

/// Tool that reports current context window usage and DAG statistics.
///
/// Shows the actual assembled context size (from last API call or dry-run estimate),
/// DAG statistics, and frontier information. The model uses this to decide whether
/// to call ``CompactContextTool`` to free space.
public nonisolated struct ContextStatusTool: ToolExecutable {
    public let name = "context_status"

    /// Stable label strings used in output — reference these in tests to stay in sync.
    public enum Labels {
        public static let header = "Context Status"
        public static let messagesInDB = "Messages in DB:"
        public static let dagNodes = "DAG nodes:"
        public static let frontierSize = "Frontier size:"
        public static let coldNodes = "Cold nodes:"
    }

    /// The context pruner actor that provides DAG statistics.
    public let pruner: ContextPruner

    /// The coordinator for real API token usage.
    public let coordinator: CIMSCoordinator

    public var definition: ToolDefinition {
        ToolDefinition(
            name: "context_status",
            description: """
            Show current context window usage: assembled context tokens (from API), \
            DAG statistics, frontier size. Use this to decide whether to compact.
            """,
            parameters: [],
        )
    }

    public init(pruner: ContextPruner, coordinator: CIMSCoordinator) {
        self.pruner = pruner
        self.coordinator = coordinator
    }

    public func execute(parameters _: sending [String: Any], workingDirectory _: String) async throws -> ToolResult {
        do {
            // Get real token usage from the coordinator
            let lastInput = await coordinator.lastReportedInputTokens
            let lastOutput = await coordinator.lastReportedOutputTokens
            let contextEstimate = await coordinator.estimateContextUsage()

            let budget = contextEstimate.budget
            let used = lastInput > 0 ? lastInput : contextEstimate.used
            let utilization = budget > 0 ? Double(used) / Double(budget) * 100.0 : 0.0

            var lines: [String] = []
            lines.append("=== \(Labels.header) ===")
            lines.append("")
            lines.append("Context budget: \(formatNumber(budget)) tokens")
            lines.append("Assembled context: \(formatNumber(contextEstimate.used)) tokens (estimated)")
            if lastInput > 0 {
                lines.append("Last API input tokens: \(formatNumber(lastInput))")
                lines.append("Last API output tokens: \(formatNumber(lastOutput))")
            }
            lines.append("Utilization: \(String(format: "%.1f", utilization))%")
            lines.append("")

            // DAG statistics from pruner
            if let stats = try await pruner.statistics() {
                lines.append("\(Labels.messagesInDB) \(formatNumber(stats.totalMessages))")
                if !stats.messagesByRole.isEmpty {
                    let roles = stats.messagesByRole.sorted { $0.key < $1.key }
                    for (role, count) in roles {
                        lines.append("  \(role): \(count)")
                    }
                }
                lines.append("")

                lines.append("\(Labels.dagNodes) \(formatNumber(stats.totalNodes))")
                if !stats.nodesByKind.isEmpty {
                    let kinds = stats.nodesByKind.sorted { $0.key < $1.key }
                    for (kind, count) in kinds {
                        lines.append("  \(kind): \(count)")
                    }
                }
                lines.append("")

                lines.append("\(Labels.frontierSize) \(stats.frontierSize)")
                lines.append("\(Labels.coldNodes) \(stats.coldNodeCount)")
            }

            if utilization > 60.0 {
                lines.append("")
                lines.append("! Context utilization is high. Consider using compact_context to free space.")
            }

            return .success(lines.joined(separator: "\n"))
        } catch {
            throw ToolError.executionFailed("Failed to query context status: \(error)")
        }
    }

    private func formatNumber(_ n: Int) -> String {
        let formatter = NumberFormatter()
        formatter.numberStyle = .decimal
        return formatter.string(from: NSNumber(value: n)) ?? "\(n)"
    }
}
