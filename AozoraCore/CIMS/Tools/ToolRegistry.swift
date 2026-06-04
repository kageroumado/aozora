import Foundation

// MARK: - Approval Handler

/// Protocol for handling interactive tool call approval requests.
///
/// When a permission rule evaluates to `.ask`, the registry invokes the approval handler
/// to request user confirmation before executing the tool. Implementations bridge to
/// the active messaging channel (e.g., Discord reactions, IPC prompts).
///
/// If no handler is set, approval-required tools return an error immediately.
public nonisolated protocol ApprovalHandler: Sendable {
    /// Request approval for a tool call, suspending until the user responds.
    ///
    /// - Parameters:
    ///   - tool: The tool name requesting approval.
    ///   - command: The bash command string, if applicable.
    ///   - prompt: Human-readable description of what's being requested.
    /// - Returns: `true` if the user approved, `false` if denied or timed out.
    func requestApproval(tool: String, command: String?, prompt: String) async -> Bool
}

/// Registry that maps tool names to their ``ToolExecutable`` implementations.
///
/// The coordinator calls ``execute(name:parameters:workingDirectory:)`` to dispatch
/// tool calls from the model. The registry also exposes ``definitions`` so tool schemas
/// can be sent to the model during inference.
///
/// When a ``PermissionEngine`` is attached, every tool call is checked against the
/// permission rule set before dispatching to the tool implementation. Permission checks
/// happen *above* tool-specific guards like ``DestructiveCommandGuard``.
public actor ToolRegistry {
    /// Registered tools keyed by name.
    private var tools: [String: any ToolExecutable] = [:]

    /// Optional permission engine for tool call authorization.
    private var permissionEngine: PermissionEngine?

    /// Optional approval handler for interactive permission requests.
    private var approvalHandler: (any ApprovalHandler)?

    /// Register a tool implementation.
    ///
    /// If a tool with the same name already exists, it is replaced.
    ///
    /// - Parameter tool: The tool to register.
    public func register(_ tool: any ToolExecutable) {
        tools[tool.name] = tool
    }

    /// Attach a permission engine for tool call authorization.
    ///
    /// When set, every ``execute(name:parameters:workingDirectory:)`` call checks
    /// permissions before dispatching. Pass `nil` to disable permission checks.
    ///
    /// - Parameter engine: The permission engine to use, or `nil` to disable.
    public func setPermissionEngine(_ engine: PermissionEngine?) {
        permissionEngine = engine
    }

    /// Attach an approval handler for interactive permission requests.
    ///
    /// When set and a tool call requires approval, the handler is invoked to request
    /// user confirmation. If the user approves, the tool call proceeds and a session
    /// grant is recorded. If denied or no handler is set, the tool returns an error.
    ///
    /// - Parameter handler: The approval handler, or `nil` to disable interactive approval.
    public func setApprovalHandler(_ handler: (any ApprovalHandler)?) {
        approvalHandler = handler
    }

    /// Execute a tool by name with the given parameters.
    ///
    /// When a ``PermissionEngine`` is attached, the tool call is checked against
    /// the permission rule set first. Denied calls return an error ``ToolResult``;
    /// calls requiring approval either invoke the ``ApprovalHandler`` (if set) or
    /// return a prompt ``ToolResult``. Only allowed calls proceed to the tool's
    /// ``ToolExecutable/execute(parameters:workingDirectory:)`` method.
    ///
    /// Permission checks are *above* tool-specific guards (e.g., ``DestructiveCommandGuard``
    /// in ``BashTool``), so a denied-at-permission-level call never reaches the tool.
    ///
    /// - Parameters:
    ///   - name: The tool name from the model's tool call.
    ///   - parameters: Parsed JSON arguments.
    ///   - workingDirectory: Default working directory for file/process operations.
    /// - Returns: The tool's execution result.
    /// - Throws: ``ToolError/unknownTool(_:)`` if no tool is registered with the given name,
    ///   or any error thrown by the tool's ``ToolExecutable/execute(parameters:workingDirectory:)`` method.
    public func execute(name: String, parameters: sending [String: Any], workingDirectory: String) async throws -> ToolResult {
        guard let tool = tools[name] else {
            throw ToolError.unknownTool(name)
        }

        if let engine = permissionEngine {
            let command = name == "bash" ? (parameters["command"] as? String) : nil
            let decision = await engine.evaluate(tool: name, command: command)
            switch decision {
            case .allowed:
                break
            case let .denied(reason):
                return ToolResult(content: "Permission denied: \(reason)", isError: true)
            case let .requiresApproval(prompt):
                if let handler = approvalHandler {
                    let approved = await handler.requestApproval(
                        tool: name,
                        command: command,
                        prompt: prompt,
                    )
                    if approved {
                        await engine.grantSession(tool: name, pattern: command)
                    } else {
                        return ToolResult(content: "Permission denied: user rejected approval for \(name)", isError: true)
                    }
                } else {
                    return ToolResult(content: "Approval required: \(prompt)", isError: true)
                }
            }
        }

        return try await tool.execute(parameters: parameters, workingDirectory: workingDirectory)
    }

    /// All registered tool definitions, for sending to the model during inference.
    public var definitions: [ToolDefinition] {
        tools.values.map(\.definition)
    }

    /// Whether a tool with the given name is registered.
    public func contains(_ name: String) -> Bool {
        tools[name] != nil
    }
}
