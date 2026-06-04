import Foundation

/// A tool that the CIMS coordinator can execute in response to model tool calls.
///
/// Conforming types provide a name, a ``ToolDefinition`` schema (sent to the model so it
/// knows how to invoke the tool), and an async `execute` method that performs the work.
///
/// All implementations must be `Sendable` since they're stored in the actor-isolated
/// ``ToolRegistry`` and invoked from the coordinator's turn loop.
public nonisolated protocol ToolExecutable: Sendable {
    /// The unique name of this tool, matching the ``ToolDefinition/name``.
    var name: String { get }

    /// The schema definition sent to the model during inference.
    var definition: ToolDefinition { get }

    /// Execute the tool with the given parameters.
    ///
    /// - Parameters:
    ///   - parameters: Parsed JSON arguments from the model's tool call.
    ///   - workingDirectory: The default working directory for file/process operations.
    /// - Returns: A ``ToolResult`` containing the output text and error status.
    /// - Throws: ``ToolError`` if execution fails.
    func execute(parameters: sending [String: Any], workingDirectory: String) async throws -> ToolResult
}

// MARK: - Shared Helpers

extension ToolExecutable {
    /// Resolve a path relative to the working directory if it is not absolute.
    ///
    /// - Parameters:
    ///   - path: A file path that may be relative or absolute.
    ///   - workingDirectory: The base directory for resolving relative paths.
    /// - Returns: An absolute path.
    func resolvePath(_ path: String, workingDirectory: String) -> String {
        if path.hasPrefix("/") { return path }
        return (workingDirectory as NSString).appendingPathComponent(path)
    }

    /// Extract a required string parameter, throwing ``ToolError/invalidParameters(_:)`` if missing.
    ///
    /// - Parameters:
    ///   - key: The parameter key to extract.
    ///   - parameters: The tool call parameters dictionary.
    /// - Returns: The string value.
    /// - Throws: ``ToolError/invalidParameters(_:)`` if the key is missing or not a string.
    func requireString(_ key: String, from parameters: [String: Any]) throws -> String {
        guard let value = parameters[key] as? String else {
            throw ToolError.invalidParameters("'\(key)' parameter is required and must be a string")
        }
        return value
    }
}

/// Errors that can occur during tool resolution and execution.
public enum ToolError: Error, Sendable {
    /// No tool registered with the given name.
    case unknownTool(String)

    /// The model provided invalid or missing parameters.
    case invalidParameters(String)

    /// The tool's underlying operation failed.
    case executionFailed(String)

    /// The tool exceeded its time limit.
    case timeout
}
