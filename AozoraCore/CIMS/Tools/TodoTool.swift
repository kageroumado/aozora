import Foundation
import GRDB

/// Session-scoped task list tool backed by GRDB.
///
/// Provides two actions:
/// - `read` — retrieve all todos for a session, formatted as a checklist.
/// - `write` — atomically replace the todo list for a session with a new set.
///
/// Todos are scoped per session via a `sessionKey` string, allowing multiple
/// concurrent sessions to maintain independent task lists without interference.
///
/// Storage is the `todos` table created by the `v3_todos` migration.
public nonisolated struct TodoTool: ToolExecutable {
    /// The database used for reading and writing todo records.
    public let db: CIMSDatabase

    public let name = "todo"

    public var definition: ToolDefinition {
        ToolDefinition(
            name: "todo",
            description: """
            Manage a session-scoped todo list. Actions:
            - "read" — show all todos for the session.
            - "write" — replace the todo list for the session with the provided todos array.
            Each todo has content (string), status (pending/in_progress/completed/cancelled), \
            and priority (low/medium/high).
            """,
            parameters: [
                ToolParameter(
                    name: "action",
                    type: .enum(["read", "write"]),
                    description: "Action to perform",
                ),
                ToolParameter(
                    name: "session",
                    type: .string,
                    description: "Session key scoping the todo list",
                ),
                ToolParameter(
                    name: "todos",
                    type: .array(.object),
                    description: "Array of todo objects with content, status, and priority fields. Required for 'write'.",
                    optional: true,
                ),
            ],
        )
    }

    /// Creates a todo tool backed by the given database.
    ///
    /// - Parameter db: The ``CIMSDatabase`` whose `todos` table will be used.
    public init(db: CIMSDatabase) {
        self.db = db
    }

    public func execute(parameters: sending [String: Any], workingDirectory _: String) async throws -> ToolResult {
        let action = try requireString("action", from: parameters)
        let session = try requireString("session", from: parameters)

        switch action {
        case "read":
            return try await readTodos(session: session)
        case "write":
            guard let rawTodos = parameters["todos"] as? [[String: Any]] else {
                throw ToolError.invalidParameters("'todos' array is required for write")
            }
            return try await writeTodos(session: session, rawTodos: rawTodos)
        default:
            return .failure("Unknown action '\(action)'. Use 'read' or 'write'.")
        }
    }

    // MARK: - Actions

    /// Read all todos for a session, formatted as a checklist.
    ///
    /// - Parameter session: The session key to query.
    /// - Returns: A formatted list of todos, or a "No todos" message if empty.
    private func readTodos(session: String) async throws -> ToolResult {
        let rows = try await db.dbPool.read { grdb in
            try Row.fetchAll(
                grdb,
                sql: "SELECT content, status, priority FROM todos WHERE sessionKey = ? ORDER BY position ASC",
                arguments: [session],
            )
        }

        if rows.isEmpty {
            return .success("No todos for session '\(session)'.")
        }

        let lines = rows.map { row -> String in
            let content: String = row["content"]
            let status: String = row["status"]
            let priority: String = row["priority"]

            let icon = switch status {
            case "completed": "[x]"
            case "in_progress": "[~]"
            case "cancelled": "[-]"
            default: "[ ]"
            }

            let priorityTag = priority == "high" ? " [!]" : ""
            return "\(icon) \(content)\(priorityTag)"
        }

        return .success(lines.joined(separator: "\n"))
    }

    /// Atomically replace todos for a session.
    ///
    /// Deletes all existing todos for the session, then inserts the provided list
    /// preserving the given order as `position`.
    ///
    /// - Parameters:
    ///   - session: The session key whose todos will be replaced.
    ///   - rawTodos: Array of dictionaries containing `content`, `status`, and `priority`.
    /// - Returns: A confirmation message with the count of todos written.
    private func writeTodos(session: String, rawTodos: [[String: Any]]) async throws -> ToolResult {
        let formatter = ISO8601DateFormatter()
        let now = formatter.string(from: Date())

        // Extract Sendable tuples before entering the @Sendable write closure.
        // [[String: Any]] is not Sendable, so we convert to typed tuples here.
        let todos: [(content: String, status: String, priority: String)] = rawTodos.map { raw in
            (
                content: raw["content"] as? String ?? "",
                status: raw["status"] as? String ?? "pending",
                priority: raw["priority"] as? String ?? "medium",
            )
        }
        let count = todos.count

        try await db.dbPool.write { grdb in
            try grdb.execute(sql: "DELETE FROM todos WHERE sessionKey = ?", arguments: [session])

            for (index, todo) in todos.enumerated() {
                try grdb.execute(
                    sql: """
                    INSERT INTO todos (sessionKey, content, status, priority, position, createdAt, updatedAt)
                    VALUES (?, ?, ?, ?, ?, ?, ?)
                    """,
                    arguments: [session, todo.content, todo.status, todo.priority, index, now, now],
                )
            }
        }

        return .success("Wrote \(count) todo(s) for session '\(session)'.")
    }
}
