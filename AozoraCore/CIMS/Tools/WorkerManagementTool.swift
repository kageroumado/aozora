import Foundation

/// Tool for managing active workers: listing and killing.
///
/// Registered on the gateway's tool registry so the coordinator's executive model
/// can inspect and control running workers. Supports two actions:
/// - `list`: Returns information about all active workers.
/// - `kill`: Cancels a specific worker by its run ID.
public nonisolated struct WorkerManagementTool: ToolExecutable {
    /// The worker supervisor to query and control.
    private let supervisor: WorkerSupervisor

    public let name = "workers"

    /// Creates a worker management tool backed by the given supervisor.
    ///
    /// - Parameter supervisor: The worker supervisor to manage.
    public init(supervisor: WorkerSupervisor) {
        self.supervisor = supervisor
    }

    public var definition: ToolDefinition {
        ToolDefinition(
            name: "workers",
            description: "Manage active workers. Use 'list' to see active workers, 'kill' to cancel a worker by run ID.",
            parameters: [
                ToolParameter(
                    name: "action",
                    type: .enum(["list", "kill"]),
                    description: "Action to perform: 'list' shows active workers, 'kill' cancels a worker",
                ),
                ToolParameter(
                    name: "run_id",
                    type: .string,
                    description: "Worker run ID (required for 'kill' action)",
                    optional: true,
                ),
            ],
        )
    }

    public func execute(parameters: sending [String: Any], workingDirectory _: String) async throws -> ToolResult {
        let action = try requireString("action", from: parameters)

        switch action {
        case "list":
            let workers = await supervisor.listActive()
            if workers.isEmpty {
                return .success("No active workers.")
            }
            var lines = ["Active workers (\(workers.count)):"]
            for w in workers {
                lines.append("  - \(w.runId) (user: \(w.userKey), grant: \(w.grantId))")
            }
            return .success(lines.joined(separator: "\n"))

        case "kill":
            let runId = try requireString("run_id", from: parameters)
            await supervisor.cancel(runId: runId)
            return .success("Cancelled worker \(runId).")

        default:
            throw ToolError.invalidParameters("Unknown action '\(action)'. Use 'list' or 'kill'.")
        }
    }
}
